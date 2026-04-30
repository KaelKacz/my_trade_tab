local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
typedef uint64_t UniverseID;
UniverseID GetPlayerID(void);
]]

local MODE = "trade_data"
local TAB_ICON = "mapst_fs_trade"

local tradeTab = {
  menuMap = nil,
  menuMapConfig = nil,
  stationCache = {},
  cachedDataset = nil,
  datasetDirty = true,
  tableState = {
    topRow = nil,
  },
  filters = {
    mode = "best",
    ware = "__all__",
    sector = "__all__",
  },
}

local function debug(msg)
  if type(DebugError) == "function" then
    DebugError("TradeDataTab: " .. msg)
  end
end

local function safeName(component)
  local name = GetComponentData(component, "name")
  return (name and name ~= "") and name or tostring(component)
end

local function safeSector(component)
  local sector = GetComponentData(component, "sector")
  return (sector and sector ~= "") and sector or "Unknown Sector"
end

local function wareName(ware)
  local name = GetWareData(ware, "name")
  return (name and name ~= "") and name or tostring(ware)
end

local function fixedMoneyNumber(value)
  local credits = tonumber(value) or 0
  local negative = credits < 0
  credits = math.abs(credits)

  local whole = math.floor(credits)
  local fraction = math.floor((credits - whole) * 100 + 0.5)
  if fraction >= 100 then
    whole = whole + 1
    fraction = fraction - 100
  end

  local wholeText = tostring(whole)
  wholeText = wholeText:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  local result = string.format("%s.%02d", wholeText, fraction)
  if negative then
    return "-" .. result
  end
  return result
end

local function moneyText(value)
  return fixedMoneyNumber(value) .. " " .. ReadText(1001, 101)
end

local function compactMoneyText(value)
  return fixedMoneyNumber(value)
end

local function amountText(value)
  return ConvertIntegerString(math.floor(value or 0), true, 0, true)
end

local function demandPercentValue(ware, price)
  local avgPrice = tonumber(GetWareData(ware, "avgprice")) or 0
  local numericPrice = tonumber(price) or 0
  if avgPrice == 0 then
    return 0
  end
  return ((numericPrice / avgPrice) - 1) * 100
end

local function demandValueText(ware, price, isbuyoffer)
  local demandPct = demandPercentValue(ware, price)
  if demandPct == 0 then
    return "0.0%"
  end

  local rounded
  if isbuyoffer then
    rounded = math.floor(demandPct * 10 + 0.0001) / 10
  else
    rounded = math.ceil(demandPct * 10 - 0.0001) / 10
  end

  return string.format("%+.1f%%", rounded)
end

local function demandColor(ware, price, isbuyoffer)
  local demandPct = demandPercentValue(ware, price)
  if demandPct == 0 then
    return Color["text_normal"]
  end

  if isbuyoffer then
    return (demandPct > 0) and Color["text_price_good"] or Color["text_price_bad"]
  end

  return (demandPct > 0) and Color["text_price_bad"] or Color["text_price_good"]
end

local function percentText(buyPrice, sellPrice)
  local buy = tonumber(buyPrice) or 0
  local sell = tonumber(sellPrice) or 0
  if buy <= 0 or sell <= buy then
    return "+0%"
  end
  local pct = ((sell - buy) / buy) * 100
  return string.format("+%.0f%%", pct)
end

local function profitPerUnitText(buyPrice, sellPrice)
  local buy = tonumber(buyPrice) or 0
  local sell = tonumber(sellPrice) or 0
  return compactMoneyText(math.max(0, sell - buy))
end

local function profitPercentValue(buyPrice, sellPrice)
  local buy = tonumber(buyPrice) or 0
  local sell = tonumber(sellPrice) or 0
  if buy <= 0 or sell <= buy then
    return 0
  end
  return ((sell - buy) / buy) * 100
end

local function movableAmountText(sourceAmount, targetAmount)
  local sellAmount = tonumber(sourceAmount) or 0
  local buyAmount = tonumber(targetAmount) or 0
  return amountText(math.min(sellAmount, buyAmount))
end

local function trimText(text, maxLen)
  text = tostring(text or "")
  if string.len(text) <= maxLen then
    return text
  end
  return string.sub(text, 1, math.max(0, maxLen - 3)) .. "..."
end

local function refresh()
  if tradeTab.menuMap and tradeTab.menuMap.refreshInfoFrame then
    local tableId = tradeTab.menuMap.infoTable
    if tableId then
      local topRow = GetTopRow(tableId)
      tradeTab.tableState.topRow = topRow
      tradeTab.menuMap.settoprow = topRow
    end
    tradeTab.menuMap.refreshInfoFrame()
  end
end

local function openStationContextMenu(stationId)
  local menu = tradeTab.menuMap
  if not menu or not stationId then
    return
  end

  local station64 = ConvertIDTo64Bit(stationId)
  if not station64 or station64 == 0 then
    return
  end

  menu.closeContextMenu()

  local playerships, otherobjects, playerdeployables = menu.getSelectedComponentCategories()
  local mousepos = C.GetCenteredMousePos()
  Helper.openInteractMenu(menu, {
    component = station64,
    playerships = playerships,
    otherobjects = otherobjects,
    playerdeployables = playerdeployables,
    mouseX = mousepos.x,
    mouseY = mousepos.y,
    behaviourInspectionComponent = menu.behaviourInspectionComponent,
  })
end

local function indentText(level, text)
  local result = tostring(text or "")
  for _ = 1, level do
    result = "    " .. result
  end
  return result
end

local function collectTradeOffers(stationId)
  local stationLua = stationId
  local currentShip = nil
  if tradeTab.menuMap and tradeTab.menuMap.currentplayership and tradeTab.menuMap.currentplayership ~= 0 then
    currentShip = ConvertStringToLuaID(tostring(tradeTab.menuMap.currentplayership))
  end

  local ok, offers
  if currentShip then
    ok, offers = pcall(GetTradeList, stationLua, currentShip, false)
  else
    ok, offers = pcall(GetTradeList, stationLua)
  end
  if not ok or type(offers) ~= "table" then
    return {}
  end
  return offers
end

local function collectPlayerStationIDs()
  local stationIds = {}
  if not (Helper and Helper.ffiVLA and C and C.GetNumAllFactionStations and C.GetAllFactionStations) then
    return stationIds
  end

  local stations = {}
  local ok = pcall(function()
    Helper.ffiVLA(stations, "UniverseID", C.GetNumAllFactionStations, C.GetAllFactionStations, "player")
  end)
  if not ok then
    debug("failed to enumerate player stations directly")
    return stationIds
  end

  for _, station64 in ipairs(stations) do
    local stationId = ConvertStringToLuaID(tostring(station64))
    if stationId and stationId ~= 0 then
      table.insert(stationIds, stationId)
    end
  end

  return stationIds
end

local function collectRegistryStationIDs()
  local stationIds = {}
  local playerId64 = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  if not playerId64 or playerId64 == 0 then
    return stationIds
  end

  local registry = GetNPCBlackboard(playerId64, "$my_trade_tab_station_registry")
  if type(registry) ~= "table" then
    return stationIds
  end

  for _, stationRef in ipairs(registry) do
    if stationRef and stationRef ~= 0 then
      local stationId = ConvertStringToLuaID(tostring(stationRef))
      if stationId and stationId ~= 0 then
        table.insert(stationIds, stationId)
      end
    end
  end

  return stationIds
end

local function getStationTradeState(stationId)
  local isKnown, isPlayerOwned, canTrade, inLiveView, hasTradeSubscription = GetComponentData(
    stationId,
    "isknown",
    "isplayerowned",
    "canhavetradeoffers",
    "isinliveview",
    "tradesubscription"
  )

  return {
    isKnown = isKnown and true or false,
    isPlayerOwned = isPlayerOwned and true or false,
    canTrade = canTrade and true or false,
    inLiveView = inLiveView and true or false,
    hasTradeSubscription = hasTradeSubscription and true or false,
  }
end

local function collectRenderedStationIDs()
  local stationIds = {}
  local menu = tradeTab.menuMap
  if not menu or type(menu.updateRenderedComponents) ~= "function" then
    return stationIds
  end

  menu.updateRenderedComponents()
  for _, entry in ipairs(menu.renderedComponents or {}) do
    local id64 = entry.id
    if id64 and id64 ~= 0 then
      local classid = GetComponentData(id64, "classid")
      if Helper.isComponentClass(classid, "station") or Helper.isComponentClass(classid, "buildstorage") then
        local stationId = ConvertStringToLuaID(tostring(id64))
        if stationId and stationId ~= 0 then
          table.insert(stationIds, stationId)
        end
      end
    end
  end

  return stationIds
end

local function collectCandidateStationIDs()
  local stationIds = {}
  local seen = {}

  local function addStationId(id)
    if id and id ~= 0 and not seen[id] then
      seen[id] = true
      table.insert(stationIds, id)
    end
  end

  for _, id in ipairs(collectPlayerStationIDs()) do
    addStationId(id)
  end
  for _, id in ipairs(collectRegistryStationIDs()) do
    addStationId(id)
  end
  for _, id in ipairs(collectRenderedStationIDs()) do
    addStationId(id)
  end
  for _, cached in pairs(tradeTab.stationCache) do
    addStationId(cached.id)
  end

  return stationIds
end

local function buildTradeDataset()
  local stationIds = collectCandidateStationIDs()
  local stations = {}
  local bestBuyByWare = {}
  local wares = {}
  local sectors = {}

  for _, stationId in ipairs(stationIds) do
    local state = getStationTradeState(stationId)
    local shouldInspect = state.canTrade and (state.isPlayerOwned or state.inLiveView or state.hasTradeSubscription)
    if shouldInspect then
      local offers = collectTradeOffers(stationId)
      local buys = {}
      local sells = {}

      for _, offer in pairs(offers) do
        if offer.ware and offer.amount and offer.amount > 0 then
          local entry = {
            id = offer.id,
            ware = offer.ware,
            price = tonumber(offer.price) or 0,
            amount = offer.amount or 0,
            isbuyoffer = offer.isbuyoffer,
            isselloffer = offer.isselloffer,
          }

          wares[entry.ware] = wareName(entry.ware)

          if entry.isbuyoffer then
            table.insert(buys, entry)
            local best = bestBuyByWare[entry.ware]
            if (not best) or (entry.price > best.price) then
              bestBuyByWare[entry.ware] = {
                stationId = stationId,
                price = entry.price,
                amount = entry.amount,
              }
            end
          elseif entry.isselloffer then
            table.insert(sells, entry)
          end
        end
      end

      if (#buys > 0) or (#sells > 0) then
        local sectorName = safeSector(stationId)
        sectors[sectorName] = sectorName
        stations[tostring(stationId)] = {
          id = stationId,
          name = safeName(stationId),
          state = state,
          sector = sectorName,
          buys = buys,
          sells = sells,
          bestProfit = 0,
          rows = {},
        }
      end
    end
  end

  for _, station in pairs(stations) do
    for _, offer in ipairs(station.sells) do
      local bestBuy = bestBuyByWare[offer.ware]
      if bestBuy and bestBuy.stationId ~= station.id and bestBuy.price > offer.price then
        local profit = bestBuy.price - offer.price
        local amount = math.min(offer.amount, bestBuy.amount or offer.amount)
        table.insert(station.rows, {
          kind = "sell",
          ware = offer.ware,
          sourceId = station.id,
          targetId = bestBuy.stationId,
          buyPrice = offer.price,
          sellPrice = bestBuy.price,
          profit = profit,
          profitPct = profitPercentValue(offer.price, bestBuy.price),
          amount = amount,
          sourceAmount = offer.amount,
          targetAmount = bestBuy.amount or offer.amount,
        })
        if station.rows[#station.rows].profitPct > station.bestProfit then
          station.bestProfit = station.rows[#station.rows].profitPct
        end
      end
    end

    table.sort(station.rows, function(a, b)
      if a.profitPct == b.profitPct then
        if a.profit == b.profit then
          return wareName(a.ware) < wareName(b.ware)
        end
        return a.profit > b.profit
      end
      return a.profitPct > b.profitPct
    end)
  end

  local wareOptions = {}
  for ware, name in pairs(wares) do
    table.insert(wareOptions, { id = ware, text = name, icon = "", displayremoveoption = false })
  end
  table.sort(wareOptions, function(a, b) return a.text < b.text end)

  local sectorOptions = {}
  for sectorName in pairs(sectors) do
    table.insert(sectorOptions, { id = sectorName, text = sectorName, icon = "", displayremoveoption = false })
  end
  table.sort(sectorOptions, function(a, b) return a.text < b.text end)

  local stationList = {}
  for _, station in pairs(stations) do
    table.insert(stationList, station)
  end
  table.sort(stationList, function(a, b)
    if a.bestProfit == b.bestProfit then
      return a.name < b.name
    end
    return a.bestProfit > b.bestProfit
  end)

  return {
    stations = stationList,
    wareOptions = wareOptions,
    sectorOptions = sectorOptions,
  }
end

local function getTradeDataset(forceRefresh)
  if forceRefresh or tradeTab.datasetDirty or (tradeTab.cachedDataset == nil) then
    tradeTab.cachedDataset = buildTradeDataset()
    tradeTab.datasetDirty = false

    local refreshedCache = {}
    for _, station in ipairs(tradeTab.cachedDataset.stations) do
      refreshedCache[tostring(station.id)] = station
    end
    tradeTab.stationCache = refreshedCache
  end

  return tradeTab.cachedDataset
end

local function stationPassesFilter(station)
  if tradeTab.filters.sector ~= "__all__" and station.sector ~= tradeTab.filters.sector then
    return false
  end

  if tradeTab.filters.ware == "__all__" then
    if tradeTab.filters.mode == "best" then
      return #station.rows > 0
    elseif tradeTab.filters.mode == "sells" then
      return #station.sells > 0
    else
      return #station.buys > 0
    end
  end

  local targetWare = tradeTab.filters.ware
  if tradeTab.filters.mode == "best" then
    for _, row in ipairs(station.rows) do
      if row.ware == targetWare then
        return true
      end
    end
  elseif tradeTab.filters.mode == "sells" then
    for _, row in ipairs(station.sells) do
      if row.ware == targetWare then
        return true
      end
    end
  else
    for _, row in ipairs(station.buys) do
      if row.ware == targetWare then
        return true
      end
    end
  end

  return false
end

local function getVisibleRows(station)
  local rows = {}

  if tradeTab.filters.mode == "best" then
    for _, row in ipairs(station.rows) do
      if tradeTab.filters.ware == "__all__" or row.ware == tradeTab.filters.ware then
        table.insert(rows, row)
      end
    end
    return rows
  end

  if tradeTab.filters.mode == "sells" then
    for _, offer in ipairs(station.sells) do
      if tradeTab.filters.ware == "__all__" or offer.ware == tradeTab.filters.ware then
        table.insert(rows, {
          ware = offer.ware,
          amount = offer.amount,
          price = offer.price,
          isbuyoffer = false,
        })
      end
    end

    table.sort(rows, function(a, b)
      local aDemand = demandPercentValue(a.ware, a.price)
      local bDemand = demandPercentValue(b.ware, b.price)
      if aDemand == bDemand then
        if a.price == b.price then
          return wareName(a.ware) < wareName(b.ware)
        end
        return a.price < b.price
      end
      return aDemand < bDemand
    end)
  else
    for _, offer in ipairs(station.buys) do
      if tradeTab.filters.ware == "__all__" or offer.ware == tradeTab.filters.ware then
        table.insert(rows, {
          ware = offer.ware,
          amount = offer.amount,
          price = offer.price,
          isbuyoffer = true,
        })
      end
    end

    table.sort(rows, function(a, b)
      local aDemand = demandPercentValue(a.ware, a.price)
      local bDemand = demandPercentValue(b.ware, b.price)
      if aDemand == bDemand then
        if a.price == b.price then
          return wareName(a.ware) < wareName(b.ware)
        end
        return a.price > b.price
      end
      return aDemand > bDemand
    end)
  end

  return rows
end

local function profitColor(buyPrice, sellPrice)
  local buy = tonumber(buyPrice) or 0
  local sell = tonumber(sellPrice) or 0
  if sell > buy then
    return Color["text_positive"]
  end
  return Color["text_normal"]
end

local function buildBuyerGroups(station)
  local groups = {}
  local order = {}

  for _, row in ipairs(getVisibleRows(station)) do
    local buyerId = row.targetId
    if buyerId then
      local key = tostring(buyerId)
      local group = groups[key]
      if not group then
        group = {
          id = buyerId,
          name = safeName(buyerId),
          bestProfit = 0,
          rows = {},
        }
        groups[key] = group
        table.insert(order, group)
      end

      table.insert(group.rows, row)
      if row.profitPct > group.bestProfit then
        group.bestProfit = row.profitPct
      end
    end
  end

  for _, group in ipairs(order) do
    table.sort(group.rows, function(a, b)
      if a.profitPct == b.profitPct then
        if a.profit == b.profit then
          return wareName(a.ware) < wareName(b.ware)
        end
        return a.profit > b.profit
      end
      return a.profitPct > b.profitPct
    end)
  end

  table.sort(order, function(a, b)
    if a.bestProfit == b.bestProfit then
      return a.name < b.name
    end
    return a.bestProfit > b.bestProfit
  end)

  return order
end

local function buildFilterOptions(dataset)
  local modeOptions = {
    { id = "best", text = "Best Trades", icon = "", displayremoveoption = false },
    { id = "sells", text = "Sell Offers", icon = "", displayremoveoption = false },
    { id = "buys", text = "Buy Offers", icon = "", displayremoveoption = false },
  }
  local wareOptions = {
    { id = "__all__", text = "All Wares", icon = "", displayremoveoption = false },
  }
  local sectorOptions = {
    { id = "__all__", text = "All Sectors", icon = "", displayremoveoption = false },
  }

  for _, entry in ipairs(dataset.wareOptions) do
    table.insert(wareOptions, entry)
  end
  for _, entry in ipairs(dataset.sectorOptions) do
    table.insert(sectorOptions, entry)
  end

  local validWare = tradeTab.filters.ware == "__all__"
  for _, entry in ipairs(dataset.wareOptions) do
    if entry.id == tradeTab.filters.ware then
      validWare = true
      break
    end
  end
  if not validWare then
    tradeTab.filters.ware = "__all__"
  end

  local validSector = tradeTab.filters.sector == "__all__"
  for _, entry in ipairs(dataset.sectorOptions) do
    if entry.id == tradeTab.filters.sector then
      validSector = true
      break
    end
  end
  if not validSector then
    tradeTab.filters.sector = "__all__"
  end

  return modeOptions, wareOptions, sectorOptions
end

local function renderFilters(objecttable, dataset, maxIcons)
  local totalCols = 4 + maxIcons
  local rowHeight = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight
  local fontSize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize

  local modeOptions, wareOptions, sectorOptions = buildFilterOptions(dataset)

  local refreshRow = objecttable:addRow("trade_refresh", {
    fixed = true,
    bgColor = tradeTab.datasetDirty and Color["row_background_red"] or Color["row_background_blue"],
  })
  refreshRow[1]:setColSpan(totalCols):createButton({
    bgColor = tradeTab.datasetDirty and Color["button_background_warning"] or Color["button_background_default"],
    highlightColor = Color["button_highlight_default"],
    active = true,
    height = rowHeight + Helper.scaleY(8),
  }):setText(tradeTab.datasetDirty and "Refresh *" or "Refresh", {
    halign = "center",
    fontsize = fontSize + 2,
    font = Helper.standardFontBold,
    color = tradeTab.datasetDirty and Color["text_warning"] or Color["text_normal"],
  })
  refreshRow[1].handlers.onClick = function()
    tradeTab.datasetDirty = true
    refresh()
  end

  local row = objecttable:addRow("trade_filters_mode", { fixed = true })
  row[1]:setColSpan(2):createText("Mode", { fontsize = fontSize })
  row[3]:setColSpan(totalCols - 2):createDropDown(modeOptions, {
    startOption = tradeTab.filters.mode,
    active = true,
    height = rowHeight,
  }):setTextProperties({ fontsize = fontSize })
  row[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.mode = id
    refresh()
  end
  row[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end

  local rowWare = objecttable:addRow("trade_filters_ware", { fixed = true })
  rowWare[1]:setColSpan(2):createText("Ware", { fontsize = fontSize })
  rowWare[3]:setColSpan(totalCols - 2):createDropDown(wareOptions, {
    startOption = tradeTab.filters.ware,
    active = true,
    height = rowHeight,
  }):setTextProperties({ fontsize = fontSize })
  rowWare[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.ware = id
    refresh()
  end
  rowWare[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end

  local row2 = objecttable:addRow("trade_filters_sector", { fixed = true })
  row2[1]:setColSpan(2):createText("Sector", { fontsize = fontSize })
  row2[3]:setColSpan(totalCols - 2):createDropDown(sectorOptions, {
    startOption = tradeTab.filters.sector,
    active = true,
    height = rowHeight,
  }):setTextProperties({ fontsize = fontSize })
  row2[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.sector = id
    refresh()
  end
  row2[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end

  local rowsAdded = 5
  if tradeTab.filters.mode == "best" then
    local labelRow = objecttable:addRow("trade_best_labels", {
      fixed = true,
      bgColor = Color["row_background_unselectable"],
      interactive = false,
    })
    labelRow[1]:setColSpan(4):createText("From/To", { color = Color["text_normal"], fontsize = fontSize })
    labelRow[5]:createText("Move", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[6]:createText("Buy Cr", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[7]:createText("Sell Cr", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[8]:createText("PPU", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[9]:createText("%", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    rowsAdded = rowsAdded + 1
  elseif tradeTab.filters.mode == "sells" then
    local labelRow = objecttable:addRow("trade_sell_labels", {
      fixed = true,
      bgColor = Color["row_background_unselectable"],
      interactive = false,
    })
    labelRow[1]:setColSpan(6):createText("Ware", { color = Color["text_normal"], fontsize = fontSize })
    labelRow[7]:createText("Qty", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[8]:createText("Price", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[9]:createText("Demand", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    rowsAdded = rowsAdded + 1
  else
    local labelRow = objecttable:addRow("trade_buy_labels", {
      fixed = true,
      bgColor = Color["row_background_unselectable"],
      interactive = false,
    })
    labelRow[1]:setColSpan(6):createText("Ware", { color = Color["text_normal"], fontsize = fontSize })
    labelRow[7]:createText("Qty", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[8]:createText("Price", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    labelRow[9]:createText("Demand", { halign = "right", color = Color["text_normal"], fontsize = fontSize })
    rowsAdded = rowsAdded + 1
  end

  return rowsAdded
end

local function renderStationRow(objecttable, station, maxIcons, numDisplayed)
  local totalCols = 4 + maxIcons
  local detailRows = getVisibleRows(station)

  local row = objecttable:addRow({ "trade_station", station.id }, {
    bgColor = Color["row_background_blue"],
  })
  if tradeTab.filters.mode == "best" then
    row[1]:setColSpan(totalCols):createButton({
      bgColor = Color["button_background_hidden"],
      highlightColor = Color["button_highlight_hidden"],
    }):setText(trimText(station.name, 70), { halign = "left" })
    row[1].handlers.onRightClick = function()
      openStationContextMenu(station.id)
    end
  else
    row[1]:setColSpan(totalCols):createButton({
      bgColor = Color["button_background_hidden"],
      highlightColor = Color["button_highlight_hidden"],
    }):setText(trimText(station.name, 70), { halign = "left" })
    row[1].handlers.onRightClick = function()
      openStationContextMenu(station.id)
    end
  end
  numDisplayed = numDisplayed + 1

  if tradeTab.filters.mode == "best" then
    local buyerGroups = buildBuyerGroups(station)
    for _, buyerGroup in ipairs(buyerGroups) do
      local buyerRow = objecttable:addRow({ "trade_buyer", buyerGroup.id, station.id }, {})
      buyerRow[1]:setColSpan(totalCols):createButton({
        bgColor = Color["button_background_hidden"],
        highlightColor = Color["button_highlight_hidden"],
      }):setText(trimText(indentText(1, buyerGroup.name), 72), { halign = "left" })
      buyerRow[1].handlers.onRightClick = function()
        openStationContextMenu(buyerGroup.id)
      end
      numDisplayed = numDisplayed + 1

      for _, tradeRow in ipairs(buyerGroup.rows) do
        local wareRow = objecttable:addRow(false, {
          interactive = false,
        })
        wareRow[1]:setColSpan(4):createText(
          trimText(indentText(2, wareName(tradeRow.ware)), 40),
          {
            color = Color["text_warning"]
          }
        )
        wareRow[5]:createText(
          movableAmountText(tradeRow.sourceAmount or tradeRow.amount, tradeRow.targetAmount or tradeRow.amount),
          { halign = "right", color = Color["text_normal"] }
        )
        wareRow[6]:createText(
          compactMoneyText(tradeRow.buyPrice),
          { halign = "right", color = Color["text_normal"] }
        )
        wareRow[7]:createText(
          compactMoneyText(tradeRow.sellPrice),
          { halign = "right", color = Color["text_normal"] }
        )
        wareRow[8]:createText(
          profitPerUnitText(tradeRow.buyPrice, tradeRow.sellPrice),
          { halign = "right", color = Color["text_positive"] }
        )
        wareRow[9]:createText(
          percentText(tradeRow.buyPrice, tradeRow.sellPrice),
          { halign = "right", color = profitColor(tradeRow.buyPrice, tradeRow.sellPrice) }
        )
        numDisplayed = numDisplayed + 1
      end
    end
  else
    for _, tradeRow in ipairs(detailRows) do
      local child = objecttable:addRow(false, {
        interactive = false,
      })
      child[1]:setColSpan(6):createText(
        trimText(indentText(1, wareName(tradeRow.ware)), 68),
        { color = Color["text_warning"] }
      )
      child[7]:createText(
        amountText(tradeRow.amount),
        { halign = "right", color = Color["text_normal"] }
      )
      child[8]:createText(
        compactMoneyText(tradeRow.price),
        { halign = "right", color = Color["text_normal"] }
      )
      child[9]:createText(
        demandValueText(tradeRow.ware, tradeRow.price, tradeRow.isbuyoffer),
        { halign = "right", color = demandColor(tradeRow.ware, tradeRow.price, tradeRow.isbuyoffer) }
      )
      numDisplayed = numDisplayed + 1
    end
  end

  return numDisplayed
end

local function restoreTableState(objecttable)
  local menu = tradeTab.menuMap
  if not objecttable or not menu then
    return
  end

  local topRow = menu.settoprow or tradeTab.tableState.topRow
  if topRow then
    debug("restoreTableState applying topRow=" .. tostring(topRow))
    objecttable:setTopRow(topRow)
    tradeTab.tableState.topRow = topRow
  else
    debug("restoreTableState found no topRow")
  end
end

local function createSideBar(config)
  local tradeDataEntry = {
    name = "Trade Data",
    icon = TAB_ICON,
    mode = MODE,
    helpOverlayID = "help_sidebar_trade_data",
    helpOverlayText = "Known stations with trade data and best trade opportunities",
  }

  if config.leftBar[#config.leftBar].mode ~= MODE then
    for i = #config.leftBar - 1, 1, -1 do
      if config.leftBar[i + 1].mode == MODE then
        table.remove(config.leftBar, i + 1)
        table.remove(config.leftBar, i)
      end
    end
    config.leftBar[#config.leftBar + 1] = { spacing = true }
    config.leftBar[#config.leftBar + 1] = tradeDataEntry
  end
end

local function createTradeFrame(frame)
  local menu = tradeTab.menuMap
  if not menu or menu.infoTableMode ~= MODE or not frame then
    return
  end

  local ok, err = pcall(function()
    local previousTableId = menu.infoTable
    local previousTopRow = nil
    if previousTableId then
      previousTopRow = GetTopRow(previousTableId)
    end
    debug("createTradeFrame begin previousTableId=" .. tostring(previousTableId) .. " previousTopRow=" .. tostring(previousTopRow) .. " menuSetTopRow=" .. tostring(menu.settoprow) .. " savedTopRow=" .. tostring(tradeTab.tableState.topRow))

    if menu.infoTable then
      tradeTab.tableState.topRow = GetTopRow(menu.infoTable)
    end

    local objecttable = frame:addTable(9, {
      tabOrder = 1,
      skipTabChange = true,
      reserveScrollBar = false,
      highlightMode = "off",
    })
    objecttable:setDefaultCellProperties("text", {
      minRowHeight = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight,
      fontsize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize,
      color = Color["text_normal"],
    })
    objecttable:setDefaultCellProperties("button", {
      height = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight,
    })
    objecttable:setDefaultCellProperties("dropdown", {
      height = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight,
    })
    objecttable:setDefaultComplexCellProperties("button", "text", {
      fontsize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize,
      color = Color["text_normal"],
    })

    local debugRow = objecttable:addRow("trade_data_debug", {
      fixed = true,
      bgColor = Color["row_title_background"],
    })
    debugRow[1]:setColSpan(9):createText("Trade Data", {
      color = Color["text_normal"],
      halign = "center",
      fontsize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize,
    })

    local dataset = getTradeDataset(false)

    local maxIcons = 5
    local topRows = renderFilters(objecttable, dataset, maxIcons)
    local numDisplayed = topRows

    local renderedAny = false
    for _, station in ipairs(dataset.stations) do
      if stationPassesFilter(station) then
        numDisplayed = renderStationRow(objecttable, station, maxIcons, numDisplayed)
        renderedAny = true
      end
    end

    if not renderedAny then
      local empty = objecttable:addRow(false, { interactive = false })
      empty[1]:setColSpan(4 + maxIcons):createText("-- No matching trade stations found --")
    end

    restoreTableState(objecttable)
    menu.settoprow = nil
    debug("createTradeFrame end restoredTopRow=" .. tostring(tradeTab.tableState.topRow))
  end)

  if not ok then
    debug("trade data frame error: " .. tostring(err))
    local errtable = frame:addTable(1, {
      tabOrder = 1,
      reserveScrollBar = false,
      highlightMode = "off",
    })
    local row = errtable:addRow(false, { interactive = false })
    row[1]:createText("Trade Data error: " .. tostring(err), { color = Color["text_error"], wordwrap = true })
    return
  end

  debug("rendered trade data sidebar tab")
end

local function onStationRegistryUpdated()
  if tradeTab.menuMap and tradeTab.menuMap.infoTableMode == MODE then
    if tradeTab.menuMap.infoTable then
      local topRow = GetTopRow(tradeTab.menuMap.infoTable)
      tradeTab.tableState.topRow = topRow
      tradeTab.menuMap.settoprow = topRow
    end
    tradeTab.datasetDirty = true
  end
end

local function Init()
  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("MapMenu not found")
    return
  end

  tradeTab.menuMap = menuMap
  tradeTab.menuMapConfig = menuMap.uix_getConfig() or {}

  menuMap.registerCallback("createSideBar_on_start", createSideBar, "my_trade_tab_sidebar")
  menuMap.registerCallback("createInfoFrame_on_menu_infoTableMode", createTradeFrame, "my_trade_tab_infoframe")
  RegisterEvent("my_trade_tab.station_registry_updated", onStationRegistryUpdated)

  debug("trade data sidebar tab initialised")
end

Register_OnLoad_Init(Init)
