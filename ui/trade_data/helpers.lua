local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function debug(msg)
  if type(DebugError) == "function" then
    DebugError("TradeDataTab: " .. msg)
  end
end

function safeName(component)
  local name = GetComponentData(component, "name")
  return (name and name ~= "") and name or tostring(component)
end

function safeSector(component)
  local sector = GetComponentData(component, "sector")
  return (sector and sector ~= "") and sector or "Unknown Sector"
end

function normalizeLuaID(value)
  if value == nil or value == 0 then
    return nil
  end

  local numeric = tonumber(value)
  if numeric and numeric ~= 0 then
    return numeric
  end

  local text = tostring(value)
  local digits = string.match(text, "(%d+)")
  if digits then
    numeric = tonumber(digits)
    if numeric and numeric ~= 0 then
      return numeric
    end
  end

  return nil
end

function getSectorID(component)
  local component64 = ConvertIDTo64Bit(component)
  if component64 and component64 ~= 0 then
    local ok, sector64 = pcall(C.GetContextByClass, component64, "sector", false)
    if ok and sector64 and sector64 ~= 0 then
      local sectorLuaId = normalizeLuaID(ConvertStringToLuaID(tostring(sector64)))
      if sectorLuaId and sectorLuaId ~= 0 then
        return sectorLuaId
      end
    end
  end

  local sectorId = normalizeLuaID(GetComponentData(component, "sectorid"))
  if sectorId and sectorId ~= 0 then
    return sectorId
  end

  return nil
end

function safeSectorNameFromID(sectorId)
  if not sectorId or sectorId == 0 then
    return "Unknown Sector"
  end

  local name = GetComponentData(sectorId, "name")
  return (name and name ~= "") and name or tostring(sectorId)
end

function getPlayerSectorID()
  local ok, sector64 = pcall(C.GetContextByClass, C.GetPlayerID(), "sector", false)
  if not ok or not sector64 or sector64 == 0 then
    return nil
  end

  local sectorId = normalizeLuaID(ConvertStringToLuaID(tostring(sector64)))
  if sectorId and sectorId ~= 0 then
    return sectorId
  end

  return nil
end

function getSelectedPlayerShipID()
  local menu = tradeTab.menuMap
  if not menu then
    return nil
  end

  if type(menu.selectedcomponents) == "table" then
    for id in pairs(menu.selectedcomponents) do
      local shipId = normalizeLuaID(ConvertStringToLuaID(tostring(id))) or normalizeLuaID(id)
      if shipId then
        local isPlayerOwned, isDeployable, classid = GetComponentData(shipId, "isplayerowned", "isdeployable", "classid")
        if isPlayerOwned and (not isDeployable) and Helper.isComponentClass(classid, "ship") then
          return shipId
        end
      end
    end
  end

  if type(menu.selectedplayerships) == "table" and #menu.selectedplayerships > 0 then
    return normalizeLuaID(ConvertStringToLuaID(tostring(menu.selectedplayerships[1]))) or normalizeLuaID(menu.selectedplayerships[1])
  end

  if menu.currentplayership and menu.currentplayership ~= 0 then
    return normalizeLuaID(ConvertStringToLuaID(tostring(menu.currentplayership))) or normalizeLuaID(menu.currentplayership)
  end

  return nil
end

function getShipFreeCargoVolume(shipId)
  if not shipId then
    return nil
  end

  local ship64 = ConvertIDTo64Bit(shipId)
  if not ship64 or ship64 == 0 then
    return nil
  end

  local ok, count = pcall(C.GetNumCargoTransportTypes, ship64, true)
  if not ok or not count or count <= 0 then
    return nil
  end

  local storage = ffi.new("StorageInfo[?]", count)
  ok, count = pcall(C.GetCargoTransportTypes, storage, count, ship64, true, true)
  if not ok or not count or count <= 0 then
    return nil
  end

  local bestFree = 0
  for i = 0, count - 1 do
    local free = math.max(0, tonumber(storage[i].capacity) - tonumber(storage[i].spaceused))
    bestFree = math.max(bestFree, free)
  end

  if bestFree <= 0 then
    return nil
  end
  return bestFree
end

function applySelectedShipCargoVolume()
  local shipId = getSelectedPlayerShipID()
  local volume = getShipFreeCargoVolume(shipId)
  if not volume then
    return false
  end

  tradeTab.filters.cargoVolume = normalizeCargoVolume(volume)
  return true
end

function getPlayerBlackboardID()
  local playerId64 = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  if playerId64 and playerId64 ~= 0 then
    return playerId64
  end
  return nil
end

function normalizeBlackboardRef(value)
  local normalized = normalizeLuaID(value)
  if normalized and normalized ~= 0 then
    return normalized
  end

  local asLuaId = ConvertStringToLuaID(tostring(value))
  normalized = normalizeLuaID(asLuaId)
  if normalized and normalized ~= 0 then
    return normalized
  end

  return nil
end

function wareName(ware)
  local name = GetWareData(ware, "name")
  return (name and name ~= "") and name or tostring(ware)
end

function wareVolume(ware)
  local key = tostring(ware)
  if wareVolumeCache[key] ~= nil then
    return wareVolumeCache[key]
  end

  local volume = tonumber(GetWareData(ware, "volume")) or 1
  volume = math.max(1, volume)
  wareVolumeCache[key] = volume
  return volume
end

function safeFactionName(faction)
  if not faction or faction == "" then
    return "Unknown Faction"
  end

  local ok, name = pcall(GetFactionData, faction, "name")
  if not ok then
    name = nil
  end
  return (name and name ~= "") and name or tostring(faction)
end

function isWareIllegalAtSector(ware, sectorId)
  if not ware or not sectorId or sectorId == 0 or type(IsWareIllegalTo) ~= "function" then
    return false
  end

  local policeFaction = GetComponentData(sectorId, "policefaction")
  if not policeFaction or policeFaction == "" then
    return false
  end

  local ok, illegal = pcall(IsWareIllegalTo, ware, "player", policeFaction)
  return ok and illegal and true or false
end

function tradeRowPassesFactionFilter(row)
  local factions = tradeTab.filters.factionSelection or {}
  if next(factions) == nil then
    return true
  end

  return factions[row.owner] or factions[row.sourceOwner] or factions[row.targetOwner]
end

function tradeRowPassesIllegalFilter(row)
  local illegalFilter = tradeTab.filters.illegal
  if illegalFilter == "show" then
    return true
  end

  local isIllegal = row.isIllegal and true or false
  if illegalFilter == "only" then
    return isIllegal
  end

  return not isIllegal
end

function tradeRowPassesCommonFilters(row)
  local wares = tradeTab.filters.wareSelection or {}
  if next(wares) ~= nil and not wares[row.ware] then
    return false
  end

  return tradeRowPassesFactionFilter(row) and tradeRowPassesIllegalFilter(row)
end

function fixedMoneyNumber(value)
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

function compactNumberText(value, decimals)
  local numeric = tonumber(value) or 0
  local negative = numeric < 0
  local absolute = math.abs(numeric)
  local suffix = ""
  local scaled = absolute

  if absolute >= 1000000000 then
    scaled = absolute / 1000000000
    suffix = "b"
  elseif absolute >= 1000000 then
    scaled = absolute / 1000000
    suffix = "m"
  elseif absolute >= 1000 then
    scaled = absolute / 1000
    suffix = "k"
  end

  if suffix == "" then
    local whole = math.floor(absolute + 0.5)
    return (negative and "-" or "") .. ConvertIntegerString(whole, true, 0, true)
  end

  local precision = decimals or 1
  local text = string.format("%." .. tostring(precision) .. "f", scaled)
  text = text:gsub("%.?0+$", "")
  return (negative and "-" or "") .. text .. suffix
end

function compactMoneyText(value)
  return compactNumberText(value, 1)
end

function amountText(value)
  return compactNumberText(value, 1)
end

function exactMoneyText(value)
  return fixedMoneyNumber(value)
end

function exactAmountText(value)
  return ConvertIntegerString(math.floor((tonumber(value) or 0) + 0.5), true, 0, true)
end

function demandPercentValue(ware, price)
  local avgPrice = tonumber(GetWareData(ware, "avgprice")) or 0
  local numericPrice = tonumber(price) or 0
  if avgPrice == 0 then
    return 0
  end
  return ((numericPrice / avgPrice) - 1) * 100
end

function demandValueText(ware, price, isbuyoffer)
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

function demandColor(ware, price, isbuyoffer)
  local demandPct = demandPercentValue(ware, price)
  if demandPct == 0 then
    return Color["text_normal"]
  end

  if isbuyoffer then
    return (demandPct > 0) and Color["text_price_good"] or Color["text_price_bad"]
  end

  return (demandPct > 0) and Color["text_price_bad"] or Color["text_price_good"]
end

function totalProfitValue(buyPrice, sellPrice, amount)
  local buy = tonumber(buyPrice) or 0
  local sell = tonumber(sellPrice) or 0
  local moveAmount = math.max(0, tonumber(amount) or 0)
  return math.max(0, sell - buy) * moveAmount
end

function totalProfitText(buyPrice, sellPrice, amount)
  return compactMoneyText(totalProfitValue(buyPrice, sellPrice, amount))
end

function profitPerJumpText(buyPrice, sellPrice, amount, routeDistance)
  local jumps = tonumber(routeDistance)
  if jumps == nil then
    return "-"
  end

  local profit = totalProfitValue(buyPrice, sellPrice, amount)
  local divisor = math.max(1, math.floor(jumps))
  return compactMoneyText(profit / divisor)
end

function profitPerJumpValue(buyPrice, sellPrice, amount, routeDistance)
  local jumps = tonumber(routeDistance)
  if jumps == nil then
    return -1
  end

  local profit = totalProfitValue(buyPrice, sellPrice, amount)
  local divisor = math.max(1, math.floor(jumps))
  return profit / divisor
end

function jumpsText(routeDistance)
  local jumps = tonumber(routeDistance)
  if jumps == nil then
    return "-"
  end
  return tostring(math.max(0, math.floor(jumps)))
end

function tripAmountValue(ware, amount)
  local fullAmount = math.max(0, tonumber(amount) or 0)
  local availableVolume = tonumber(tradeTab.filters.cargoVolume)
  if availableVolume == nil or availableVolume <= 0 then
    return fullAmount
  end

  local unitsPerTrip = math.floor(availableVolume / wareVolume(ware))
  return math.max(0, math.min(fullAmount, unitsPerTrip))
end

function tripAmountText(tripAmount, fullAmount)
  local trip = math.max(0, tonumber(tripAmount) or 0)
  local full = math.max(0, tonumber(fullAmount) or 0)
  if trip >= full then
    return amountText(full)
  end
  return amountText(trip) .. "/" .. amountText(full)
end

function tripAmountMouseOverText(tripAmount, fullAmount)
  local trip = math.max(0, tonumber(tripAmount) or 0)
  local full = math.max(0, tonumber(fullAmount) or 0)
  if trip >= full then
    return exactAmountText(full)
  end
  return exactAmountText(trip) .. "/" .. exactAmountText(full)
end

normalizeCargoVolume = function(value)
  local numericValue = tonumber(value) or 0
  return tostring(math.max(0, math.min(100000, math.floor(numericValue + 0.5))))
end

function trimText(text, maxLen)
  text = tostring(text or "")
  if string.len(text) <= maxLen then
    return text
  end
  return string.sub(text, 1, math.max(0, maxLen - 3)) .. "..."
end

function getTradeTableId(side)
  local menu = tradeTab.menuMap
  if not menu then
    return nil
  end

  if side == "right" then
    return menu.infoTableRight
  end

  return menu.infoTable
end

function rememberTableState(side)
  local menu = tradeTab.menuMap
  local tableId = getTradeTableId(side)
  if not menu or not tableId then
    return
  end

  local topRow = GetTopRow(tableId)
  if side == "right" then
    tradeTab.tableState.rightTopRow = topRow
  else
    tradeTab.tableState.leftTopRow = topRow
    menu.settoprow = topRow
  end
end

function refresh(side)
  local menu = tradeTab.menuMap
  if not menu then
    return
  end

  local leftOpen = menu.infoTableMode == MODE
  local rightOpen = menu.searchTableMode == MODE

  if side == "left" or (side == nil and leftOpen) then
    rememberTableState("left")
  end
  if side == "right" or (side == nil and rightOpen) then
    rememberTableState("right")
  end

  if leftOpen and menu.refreshInfoFrame then
    menu.refreshInfoFrame()
  elseif rightOpen and menu.refreshInfoFrame2 then
    menu.refreshInfoFrame2()
  end
end


function openStationContextMenu(stationId)
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

function indentText(level, text)
  local result = tostring(text or "")
  for _ = 1, level do
    result = "    " .. result
  end
  return result
end

function wareRowBackground(rowIndex)
  if (rowIndex % 2) == 0 then
    return wareRowColors.darkGray
  end
  return wareRowColors.black
end

