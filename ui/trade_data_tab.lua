local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
typedef uint64_t UniverseID;
UniverseID GetPlayerID(void);
UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);
]]

local MODE = "trade_data"
local TAB_ICON = "mapst_fs_trade"
local tradeTab = {
  menuMap = nil,
  menuMapConfig = nil,
  stationCache = {},
  cachedDataset = nil,
  datasetDirty = true,
  gateDistanceFilterPending = false,
  tradeDistanceCachePending = {},
  exactTradeDistanceCache = {},
  tradeDistanceRequestsRemaining = 0,
  tableState = {
    leftTopRow = nil,
    rightTopRow = nil,
  },
  filters = {
    mode = "best",
    ware = "__all__",
    sector = "__all__",
    originSector = nil,
    maxGateDistance = "0",
    maxTradeDistance = "0",
    cargoVolume = "5000",
  },
}

local getReachableSectors
local wareVolumeCache = {}

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

local function normalizeLuaID(value)
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

local function getSectorID(component)
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

local function safeSectorNameFromID(sectorId)
  if not sectorId or sectorId == 0 then
    return "Unknown Sector"
  end

  local name = GetComponentData(sectorId, "name")
  return (name and name ~= "") and name or tostring(sectorId)
end

local function getPlayerSectorID()
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

local function getPlayerBlackboardID()
  local playerId64 = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  if playerId64 and playerId64 ~= 0 then
    return playerId64
  end
  return nil
end

local function normalizeBlackboardRef(value)
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

local function wareName(ware)
  local name = GetWareData(ware, "name")
  return (name and name ~= "") and name or tostring(ware)
end

local function wareVolume(ware)
  local key = tostring(ware)
  if wareVolumeCache[key] ~= nil then
    return wareVolumeCache[key]
  end

  local volume = tonumber(GetWareData(ware, "volume")) or 1
  volume = math.max(1, volume)
  wareVolumeCache[key] = volume
  return volume
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

local function compactNumberText(value, decimals)
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

local function compactMoneyText(value)
  return compactNumberText(value, 1)
end

local function amountText(value)
  return compactNumberText(value, 1)
end

local function exactMoneyText(value)
  return fixedMoneyNumber(value)
end

local function exactAmountText(value)
  return ConvertIntegerString(math.floor((tonumber(value) or 0) + 0.5), true, 0, true)
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

local function totalProfitValue(buyPrice, sellPrice, amount)
  local buy = tonumber(buyPrice) or 0
  local sell = tonumber(sellPrice) or 0
  local moveAmount = math.max(0, tonumber(amount) or 0)
  return math.max(0, sell - buy) * moveAmount
end

local function totalProfitText(buyPrice, sellPrice, amount)
  return compactMoneyText(totalProfitValue(buyPrice, sellPrice, amount))
end

local function profitPerJumpText(buyPrice, sellPrice, amount, routeDistance)
  local jumps = tonumber(routeDistance)
  if jumps == nil then
    return "-"
  end

  local profit = totalProfitValue(buyPrice, sellPrice, amount)
  local divisor = math.max(1, math.floor(jumps))
  return compactMoneyText(profit / divisor)
end

local function profitPerJumpValue(buyPrice, sellPrice, amount, routeDistance)
  local jumps = tonumber(routeDistance)
  if jumps == nil then
    return -1
  end

  local profit = totalProfitValue(buyPrice, sellPrice, amount)
  local divisor = math.max(1, math.floor(jumps))
  return profit / divisor
end

local function jumpsText(routeDistance)
  local jumps = tonumber(routeDistance)
  if jumps == nil then
    return "-"
  end
  return tostring(math.max(0, math.floor(jumps)))
end

local function tripAmountValue(ware, amount)
  local fullAmount = math.max(0, tonumber(amount) or 0)
  local availableVolume = tonumber(tradeTab.filters.cargoVolume)
  if availableVolume == nil or availableVolume <= 0 then
    return fullAmount
  end

  local unitsPerTrip = math.floor(availableVolume / wareVolume(ware))
  return math.max(0, math.min(fullAmount, unitsPerTrip))
end

local function tripAmountText(tripAmount, fullAmount)
  local trip = math.max(0, tonumber(tripAmount) or 0)
  local full = math.max(0, tonumber(fullAmount) or 0)
  if trip >= full then
    return amountText(full)
  end
  return amountText(trip) .. "/" .. amountText(full)
end

local function tripAmountMouseOverText(tripAmount, fullAmount)
  local trip = math.max(0, tonumber(tripAmount) or 0)
  local full = math.max(0, tonumber(fullAmount) or 0)
  if trip >= full then
    return exactAmountText(full)
  end
  return exactAmountText(trip) .. "/" .. exactAmountText(full)
end

local function normalizeCargoVolume(value)
  local numericValue = tonumber(value) or 0
  return tostring(math.max(0, math.min(100000, math.floor(numericValue + 0.5))))
end

local function trimText(text, maxLen)
  text = tostring(text or "")
  if string.len(text) <= maxLen then
    return text
  end
  return string.sub(text, 1, math.max(0, maxLen - 3)) .. "..."
end

local function getTradeTableId(side)
  local menu = tradeTab.menuMap
  if not menu then
    return nil
  end

  if side == "right" then
    return menu.infoTableRight
  end

  return menu.infoTable
end

local function rememberTableState(side)
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

local function refresh(side)
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
  local playerId64 = getPlayerBlackboardID()
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
      stationId = normalizeLuaID(stationId)
      if stationId and stationId ~= 0 then
        table.insert(stationIds, stationId)
      end
    end
  end

  return stationIds
end

local function getGateDistanceSectorFilter()
  if not tradeTab.filters.originSector then
    return nil
  end

  if tradeTab.gateDistanceFilterPending then
    return nil
  end

  local playerId64 = getPlayerBlackboardID()
  if not playerId64 then
    return nil
  end

  local currentOriginSector = normalizeLuaID(tradeTab.filters.originSector)
  local currentMaxGateDistance = tonumber(tradeTab.filters.maxGateDistance)
  local storedOriginSector = normalizeBlackboardRef(GetNPCBlackboard(playerId64, "$my_trade_tab_origin_sector"))
  local storedMaxGateDistance = tonumber(GetNPCBlackboard(playerId64, "$my_trade_tab_max_gate_distance"))
  if currentOriginSector ~= storedOriginSector or currentMaxGateDistance ~= storedMaxGateDistance then
    return nil
  end

  local sectors = GetNPCBlackboard(playerId64, "$my_trade_tab_gate_distance_sectors")
  if type(sectors) ~= "table" then
    return nil
  end

  local allowed = {}
  local count = 0
  for _, sectorRef in ipairs(sectors) do
    if sectorRef and sectorRef ~= 0 then
      local sectorId = ConvertStringToLuaID(tostring(sectorRef))
      sectorId = normalizeLuaID(sectorId)
      if sectorId and sectorId ~= 0 then
        allowed[tostring(sectorId)] = true
        count = count + 1
      end
    end
  end

  if count == 0 then
    debug("getGateDistanceSectorFilter returned empty sector list")
    return nil
  end

  return allowed
end

local function buildFilterContext()
  local context = {
    allowedSectors = getGateDistanceSectorFilter(),
    originSectorId = nil,
    reachable = nil,
  }

  if tradeTab.filters.originSector then
    context.originSectorId = normalizeLuaID(tradeTab.filters.originSector)
    if context.originSectorId and (not context.allowedSectors) then
      local maxGateDistance = tonumber(tradeTab.filters.maxGateDistance) or 0
      context.reachable = getReachableSectors(
        context.originSectorId,
        maxGateDistance,
        tradeTab.cachedDataset and tradeTab.cachedDataset.sectorGraph or {}
      )
    end
  end

  return context
end

local function syncTradeDistanceCacheFromBlackboard()
  local playerId64 = getPlayerBlackboardID()
  if not playerId64 then
    return tradeTab.exactTradeDistanceCache
  end

  local rawCache = GetNPCBlackboard(playerId64, "$my_trade_tab_trade_distance_cache")
  if type(rawCache) ~= "table" then
    return tradeTab.exactTradeDistanceCache
  end

  local parsedCache = {}
  for sourceRef, distanceTable in pairs(rawCache) do
    local sourceSectorId = normalizeBlackboardRef(sourceRef)
    if sourceSectorId and type(distanceTable) == "table" then
      local sourceKey = tostring(sourceSectorId)
      parsedCache[sourceKey] = parsedCache[sourceKey] or {}

      for targetRef, distanceValue in pairs(distanceTable) do
        local targetSectorId = normalizeBlackboardRef(targetRef)
        local distance = tonumber(distanceValue)
        if targetSectorId and distance ~= nil and distance >= 0 then
          parsedCache[sourceKey][tostring(targetSectorId)] = distance
        end
      end
    end
  end

  tradeTab.exactTradeDistanceCache = parsedCache
  return tradeTab.exactTradeDistanceCache
end

local function requestTradeDistanceCacheUpdate(sourceSectorId)
  local normalizedSource = normalizeLuaID(sourceSectorId)
  if (not normalizedSource) or normalizedSource == 0 then
    return
  end

  if (tradeTab.tradeDistanceRequestsRemaining or 0) <= 0 then
    return
  end

  local sourceKey = tostring(normalizedSource)
  local exactCache = tradeTab.exactTradeDistanceCache or {}
  if exactCache[sourceKey] then
    return
  end

  if tradeTab.tradeDistanceCachePending[sourceKey] then
    return
  end

  tradeTab.tradeDistanceCachePending[sourceKey] = true
  tradeTab.tradeDistanceRequestsRemaining = math.max(0, (tradeTab.tradeDistanceRequestsRemaining or 0) - 1)
  AddUITriggeredEvent("MapMenu", "my_trade_tab_trade_distance_cache_changed", normalizedSource)
end

tradeTab.requestGateDistanceFilterUpdate = function()
  local playerId64 = getPlayerBlackboardID()
  if not playerId64 then
    refresh()
    return
  end

  if not tradeTab.filters.originSector then
    tradeTab.gateDistanceFilterPending = false
    SetNPCBlackboard(playerId64, "$my_trade_tab_origin_sector", nil)
    SetNPCBlackboard(playerId64, "$my_trade_tab_max_gate_distance", nil)
    SetNPCBlackboard(playerId64, "$my_trade_tab_gate_distance_sectors", {})
    refresh()
    return
  end

  local originSectorId = normalizeLuaID(tradeTab.filters.originSector)
  local maxGateDistance = tonumber(tradeTab.filters.maxGateDistance)
  if (not originSectorId) or (maxGateDistance == nil) then
    tradeTab.gateDistanceFilterPending = false
    SetNPCBlackboard(playerId64, "$my_trade_tab_gate_distance_sectors", {})
    refresh()
    return
  end

  tradeTab.gateDistanceFilterPending = true
  SetNPCBlackboard(playerId64, "$my_trade_tab_origin_sector", originSectorId)
  SetNPCBlackboard(playerId64, "$my_trade_tab_max_gate_distance", maxGateDistance)
  AddUITriggeredEvent("MapMenu", "my_trade_tab_gate_distance_filter_changed", originSectorId)
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
        stationId = normalizeLuaID(stationId)
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

local function buildSectorGraph(sectorIds)
  local graph = {}

  local function ensureNode(sectorId)
    local key = tostring(sectorId)
    graph[key] = graph[key] or {
      id = sectorId,
      neighbors = {},
    }
    return graph[key]
  end

  local function addEdge(a, b)
    if (not a) or (not b) or a == 0 or b == 0 or a == b then
      return
    end

    local aNode = ensureNode(a)
    local bNode = ensureNode(b)
    aNode.neighbors[tostring(b)] = b
    bNode.neighbors[tostring(a)] = a
  end

  for _, sectorId in ipairs(sectorIds) do
    ensureNode(sectorId)

    if type(GetContainedObjects) == "function" then
      local ok, objects = pcall(GetContainedObjects, sectorId)
      if ok and type(objects) == "table" then
        for _, objectId in ipairs(objects) do
          local classid, destination = GetComponentData(objectId, "classid", "destination")
          local isSectorConnection =
            Helper.isComponentClass(classid, "gate") or
            Helper.isComponentClass(classid, "highwayentrygate") or
            Helper.isComponentClass(classid, "highway")

          if isSectorConnection and destination and destination ~= 0 then
            local destinationSectorId = nil
            local destinationSpace = nil
            if Helper and type(Helper.getDisplayableGateDestinationSpace) == "function" then
              destinationSpace = Helper.getDisplayableGateDestinationSpace(objectId)
            end
            if destinationSpace then
              destinationSectorId = getSectorID(destinationSpace)
            end
            if not destinationSectorId then
              local okSector, destinationSector64 = pcall(C.GetContextByClass, ConvertIDTo64Bit(destination), "sector", false)
              if okSector and destinationSector64 and destinationSector64 ~= 0 then
                destinationSectorId = normalizeLuaID(ConvertStringToLuaID(tostring(destinationSector64)))
              end
            end
            if not destinationSectorId then
              destinationSectorId = getSectorID(destination)
            end
            if destinationSectorId and destinationSectorId ~= 0 then
              addEdge(sectorId, destinationSectorId)
            end
          end
        end
      end
    end
  end

  return graph
end

getReachableSectors = function(originSectorId, maxGateDistance, sectorGraph)
  local reachable = {}
  if (not originSectorId) or originSectorId == 0 then
    return reachable
  end

  reachable[tostring(originSectorId)] = 0
  if maxGateDistance <= 0 then
    return reachable
  end

  local queue = {
    { id = originSectorId, gateDistance = 0 },
  }
  local index = 1

  while index <= #queue do
    local entry = queue[index]
    index = index + 1

    local node = sectorGraph[tostring(entry.id)]
    if node and entry.gateDistance < maxGateDistance then
      for neighborKey, neighborId in pairs(node.neighbors) do
        if reachable[neighborKey] == nil then
          local gateDistance = entry.gateDistance + 1
          reachable[neighborKey] = gateDistance
          table.insert(queue, { id = neighborId, gateDistance = gateDistance })
        end
      end
    end
  end

  return reachable
end

local function getSectorGateDistance(sourceSectorId, targetSectorId, sectorGraph, distanceCache)
  if (not sourceSectorId) or (not targetSectorId) or sourceSectorId == 0 or targetSectorId == 0 then
    return nil
  end

  if sourceSectorId == targetSectorId then
    return 0
  end

  local exactCache = tradeTab.exactTradeDistanceCache or {}
  local sourceKey = tostring(sourceSectorId)
  local targetKey = tostring(targetSectorId)
  if exactCache[sourceKey] and exactCache[sourceKey][targetKey] ~= nil then
    return exactCache[sourceKey][targetKey]
  end

  requestTradeDistanceCacheUpdate(sourceSectorId)

  local cacheKey = sourceKey .. ">" .. targetKey
  if distanceCache and distanceCache[cacheKey] ~= nil then
    return distanceCache[cacheKey]
  end

  local reachable = getReachableSectors(sourceSectorId, 99, sectorGraph or {})
  local distance = reachable[targetKey]
  if distanceCache then
    distanceCache[cacheKey] = distance
    distanceCache[tostring(targetSectorId) .. ">" .. tostring(sourceSectorId)] = distance
  end

  return distance
end

local function buildTradeDataset()
  local stationIds = collectCandidateStationIDs()
  local stations = {}
  local buyOffersByWare = {}
  local wares = {}
  local sectors = {}
  local sectorIds = {}
  local seenSectorIds = {}

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
            buyOffersByWare[entry.ware] = buyOffersByWare[entry.ware] or {}
            table.insert(buyOffersByWare[entry.ware], {
              stationId = stationId,
              price = entry.price,
              amount = entry.amount,
            })
          elseif entry.isselloffer then
            table.insert(sells, entry)
          end
        end
      end

      if (#buys > 0) or (#sells > 0) then
        local sectorId = getSectorID(stationId)
        local sectorName = sectorId and safeSectorNameFromID(sectorId) or safeSector(stationId)
        sectors[sectorName] = sectorName
        if sectorId and (not seenSectorIds[sectorId]) then
          seenSectorIds[sectorId] = true
          table.insert(sectorIds, sectorId)
        end
        stations[tostring(stationId)] = {
          id = stationId,
          name = safeName(stationId),
          state = state,
          sectorId = sectorId,
          sector = sectorName,
          buys = buys,
          sells = sells,
        }
      end
    end
  end

  local sectorGraph = buildSectorGraph(sectorIds)
  local routeDistanceCache = {}

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

  local playerSectorId = getPlayerSectorID()
  if playerSectorId and (not seenSectorIds[playerSectorId]) then
    seenSectorIds[playerSectorId] = true
    table.insert(sectorIds, playerSectorId)
  end

  local originSectorOptions = {}
  local seenOriginSectors = {}
  local seenOriginSectorNames = {}
  for _, sectorId in ipairs(sectorIds) do
    local key = tostring(sectorId)
    local sectorName = safeSectorNameFromID(sectorId)
    if (not seenOriginSectors[key]) and (not seenOriginSectorNames[sectorName]) then
      seenOriginSectors[key] = true
      seenOriginSectorNames[sectorName] = true
      table.insert(originSectorOptions, {
        id = key,
        text = sectorName,
        icon = "",
        displayremoveoption = false,
      })
    end
  end
  table.sort(originSectorOptions, function(a, b) return a.text < b.text end)

  local stationList = {}
  for _, station in pairs(stations) do
    table.insert(stationList, station)
  end
  table.sort(stationList, function(a, b) return a.name < b.name end)

  return {
    stations = stationList,
    stationById = stations,
    buyOffersByWare = buyOffersByWare,
    wareOptions = wareOptions,
    sectorOptions = sectorOptions,
    originSectorOptions = originSectorOptions,
    sectorGraph = sectorGraph,
    routeDistanceCache = routeDistanceCache,
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

local function bestTradeRowPassesFilter(row)
  if (tonumber(row.tripAmount) or 0) <= 0 then
    return false
  end

  local maxTradeDistance = tradeTab.filters.maxTradeDistance
  local limit = tonumber(maxTradeDistance)
  if limit == nil then
    return true
  end

  local routeDistance = row.routeDistance
  if routeDistance == nil then
    routeDistance = getSectorGateDistance(
      row.sourceSectorId,
      row.targetSectorId,
      tradeTab.cachedDataset and tradeTab.cachedDataset.sectorGraph or {},
      tradeTab.cachedDataset and tradeTab.cachedDataset.routeDistanceCache or nil
    )
    row.routeDistance = routeDistance
  end

  return (routeDistance ~= nil) and (routeDistance <= limit)
end

local function buildBestTradeRowsForStation(station, frameCache)
  if frameCache then
    frameCache.bestTradeRowsByStation = frameCache.bestTradeRowsByStation or {}
    local cacheKey = tostring(station.id)
    if frameCache.bestTradeRowsByStation[cacheKey] then
      return frameCache.bestTradeRowsByStation[cacheKey]
    end
  end

  local dataset = tradeTab.cachedDataset
  if not dataset then
    return {}
  end

  local rows = {}
  for _, offer in ipairs(station.sells) do
    local candidates = dataset.buyOffersByWare[offer.ware] or {}
    local bestRow = nil

    for _, candidate in ipairs(candidates) do
      if candidate.stationId ~= station.id and candidate.price > offer.price then
        local targetStation = dataset.stationById[tostring(candidate.stationId)]
        local amount = math.min(offer.amount, candidate.amount or offer.amount)
        local tripAmount = tripAmountValue(offer.ware, amount)
        local routeDistance = getSectorGateDistance(
          station.sectorId,
          targetStation and targetStation.sectorId or nil,
          dataset.sectorGraph,
          dataset.routeDistanceCache
        )
        local row = {
          kind = "sell",
          ware = offer.ware,
          sourceId = station.id,
          targetId = candidate.stationId,
          sourceSectorId = station.sectorId,
          targetSectorId = targetStation and targetStation.sectorId or nil,
          routeDistance = routeDistance,
          buyPrice = offer.price,
          sellPrice = candidate.price,
          totalProfit = totalProfitValue(offer.price, candidate.price, tripAmount),
          profitPerJump = profitPerJumpValue(offer.price, candidate.price, tripAmount, routeDistance),
          amount = amount,
          tripAmount = tripAmount,
        }

        if bestTradeRowPassesFilter(row) then
          if (not bestRow)
            or row.profitPerJump > bestRow.profitPerJump
            or (row.profitPerJump == bestRow.profitPerJump and row.totalProfit > bestRow.totalProfit)
            or (row.profitPerJump == bestRow.profitPerJump and row.totalProfit == bestRow.totalProfit and row.tripAmount > bestRow.tripAmount) then
            bestRow = row
          end
        end
      end
    end

    if bestRow then
      table.insert(rows, bestRow)
    end
  end

  table.sort(rows, function(a, b)
    if a.profitPerJump == b.profitPerJump then
      if a.totalProfit == b.totalProfit then
        if a.tripAmount == b.tripAmount then
          return wareName(a.ware) < wareName(b.ware)
        end
        return a.tripAmount > b.tripAmount
      end
      return a.totalProfit > b.totalProfit
    end
    return a.profitPerJump > b.profitPerJump
  end)

  if frameCache then
    frameCache.bestTradeRowsByStation[tostring(station.id)] = rows
  end

  return rows
end

local function stationPassesFilter(station, filterContext, frameCache)
  local allowedSectors = filterContext and filterContext.allowedSectors or getGateDistanceSectorFilter()
  if allowedSectors then
    local stationSectorKey = station.sectorId and tostring(station.sectorId) or nil
    if (not stationSectorKey) or (not allowedSectors[stationSectorKey]) then
      return false
    end
  end

  if tradeTab.filters.originSector then
    local originSectorId = filterContext and filterContext.originSectorId or normalizeLuaID(tradeTab.filters.originSector)
    local stationSectorKey = station.sectorId and tostring(station.sectorId) or nil
    if (not originSectorId) or (not stationSectorKey) then
      return false
    end

    if not allowedSectors then
      local reachable = filterContext and filterContext.reachable
      if not reachable then
        local maxGateDistance = tonumber(tradeTab.filters.maxGateDistance) or 0
        reachable = getReachableSectors(originSectorId, maxGateDistance, tradeTab.cachedDataset and tradeTab.cachedDataset.sectorGraph or {})
      end
      if reachable[stationSectorKey] == nil then
        return false
      end
    end
  end

  if tradeTab.filters.sector ~= "__all__" and station.sector ~= tradeTab.filters.sector then
    return false
  end

  if tradeTab.filters.ware == "__all__" then
    if tradeTab.filters.mode == "best" then
      for _, row in ipairs(buildBestTradeRowsForStation(station, frameCache)) do
        if row then
          return true
        end
      end
      return false
    elseif tradeTab.filters.mode == "sells" then
      return #station.sells > 0
    else
      return #station.buys > 0
    end
  end

  local targetWare = tradeTab.filters.ware
  if tradeTab.filters.mode == "best" then
    for _, row in ipairs(buildBestTradeRowsForStation(station, frameCache)) do
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

local function getVisibleRows(station, frameCache)
  local rows = {}

  if tradeTab.filters.mode == "best" then
    for _, row in ipairs(buildBestTradeRowsForStation(station, frameCache)) do
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

local function buildBuyerGroups(station, frameCache)
  local groups = {}
  local order = {}

  for _, row in ipairs(getVisibleRows(station, frameCache)) do
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
      if row.profitPerJump > group.bestProfit then
        group.bestProfit = row.profitPerJump
      end
    end
  end

  for _, group in ipairs(order) do
    table.sort(group.rows, function(a, b)
      if a.profitPerJump == b.profitPerJump then
        if a.totalProfit == b.totalProfit then
          if a.tripAmount == b.tripAmount then
            return wareName(a.ware) < wareName(b.ware)
          end
          return a.tripAmount > b.tripAmount
        end
        return a.totalProfit > b.totalProfit
      end
      return a.profitPerJump > b.profitPerJump
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
  local playerSectorId = getPlayerSectorID()
  if (tradeTab.filters.originSector == nil) and playerSectorId then
    tradeTab.filters.originSector = tostring(playerSectorId)
  end

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
  local originSectorOptions = {}
  for _, entry in ipairs(dataset.wareOptions) do
    table.insert(wareOptions, entry)
  end
  for _, entry in ipairs(dataset.sectorOptions) do
    table.insert(sectorOptions, entry)
  end
  for _, entry in ipairs(dataset.originSectorOptions) do
    table.insert(originSectorOptions, entry)
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

  local validOriginSector = false
  for _, entry in ipairs(dataset.originSectorOptions) do
    if entry.id == tradeTab.filters.originSector then
      validOriginSector = true
      break
    end
  end
  if not validOriginSector then
    if playerSectorId then
      tradeTab.filters.originSector = tostring(playerSectorId)
    else
      local fallbackOrigin = dataset.originSectorOptions[1]
      tradeTab.filters.originSector = fallbackOrigin and fallbackOrigin.id or nil
    end
  end

  local numericMaxGateDistance = tonumber(tradeTab.filters.maxGateDistance)
  if numericMaxGateDistance == nil then
    tradeTab.filters.maxGateDistance = "0"
  else
    numericMaxGateDistance = math.max(0, math.min(10, math.floor(numericMaxGateDistance + 0.5)))
    tradeTab.filters.maxGateDistance = tostring(numericMaxGateDistance)
  end

  local numericMaxTradeDistance = tonumber(tradeTab.filters.maxTradeDistance)
  if numericMaxTradeDistance == nil then
    tradeTab.filters.maxTradeDistance = "0"
  else
    numericMaxTradeDistance = math.max(0, math.min(10, math.floor(numericMaxTradeDistance + 0.5)))
    tradeTab.filters.maxTradeDistance = tostring(numericMaxTradeDistance)
  end

  local numericCargoVolume = tonumber(tradeTab.filters.cargoVolume)
  if numericCargoVolume == nil then
    tradeTab.filters.cargoVolume = "5000"
  else
    tradeTab.filters.cargoVolume = normalizeCargoVolume(numericCargoVolume)
  end

  return modeOptions, wareOptions, sectorOptions, originSectorOptions
end

local function renderFilters(objecttable, dataset, maxIcons)
  local totalCols = 4 + maxIcons
  local rowHeight = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight
  local fontSize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize

  local modeOptions, wareOptions, sectorOptions, originSectorOptions = buildFilterOptions(dataset)

  local refreshRow = objecttable:addRow("trade_refresh", {
    fixed = true,
    bgColor = tradeTab.datasetDirty and Color["row_background_red"] or Color["row_background_blue"],
  })
  refreshRow[1]:setColSpan(totalCols):createButton({
    bgColor = tradeTab.datasetDirty and Color["button_background_warning"] or Color["button_background_default"],
    highlightColor = Color["button_highlight_default"],
    active = true,
    height = rowHeight + Helper.scaleY(8),
  }):setText("Refresh Trade Data", {
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
  row[1]:setColSpan(2):createText("Mode", { fontsize = fontSize, mouseOverText = "Switch between Best Trades, Sell Offers, and Buy Offers." })
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
  rowWare[1]:setColSpan(2):createText("Ware", { fontsize = fontSize, mouseOverText = "Filter results to a specific ware, or show all wares." })
  rowWare[3]:setColSpan(totalCols - 3):createDropDown(wareOptions, {
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
  rowWare[10]:createButton({
    active = tradeTab.filters.ware ~= "__all__",
    height = rowHeight,
    mouseOverText = "Reset Ware filter to All Wares.",
  }):setText("X", { fontsize = fontSize })
  rowWare[10].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.ware = "__all__"
    refresh()
  end

  local row2 = objecttable:addRow("trade_filters_sector", { fixed = true })
  row2[1]:setColSpan(2):createText("Sector", { fontsize = fontSize, mouseOverText = "Limit results to stations in one displayed sector name, or show all sectors." })
  row2[3]:setColSpan(totalCols - 3):createDropDown(sectorOptions, {
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
  row2[10]:createButton({
    active = tradeTab.filters.sector ~= "__all__",
    height = rowHeight,
    mouseOverText = "Reset Sector filter to All Sectors.",
  }):setText("X", { fontsize = fontSize })
  row2[10].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.sector = "__all__"
    refresh()
  end

  local row3 = objecttable:addRow("trade_filters_origin_sector", { fixed = true })
  row3[1]:setColSpan(2):createText("Search Origin", { fontsize = fontSize, mouseOverText = "Starting sector used for the Search Area filter." })
  row3[3]:setColSpan(totalCols - 2):createDropDown(originSectorOptions, {
    startOption = tradeTab.filters.originSector,
    active = true,
    height = rowHeight,
  }):setTextProperties({ fontsize = fontSize })
  row3[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.originSector = id
    tradeTab.requestGateDistanceFilterUpdate()
  end
  row3[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end

  local row4 = objecttable:addRow("trade_filters_max_gate_distance", { fixed = true })
  row4[1]:setColSpan(2):createText("Search Area", { fontsize = fontSize, mouseOverText = "How many gate jumps away from Search Origin stations may be included." })
  row4[3]:setColSpan(totalCols - 2):createSliderCell({
    min = 0,
    max = 10,
    start = tonumber(tradeTab.filters.maxGateDistance) or 0,
    step = 1,
    height = rowHeight,
    mouseOverText = "How many gate jumps away from Search Origin stations may be included.",
  }):setText("", { fontsize = fontSize })
  row4[3].handlers.onSliderCellChanged = function(_, value)
    tradeTab.filters.maxGateDistance = tostring(math.max(0, math.min(10, math.floor((tonumber(value) or 0) + 0.5))))
  end
  row4[3].handlers.onSliderCellConfirm = function()
    tradeTab.menuMap.noupdate = false
    tradeTab.requestGateDistanceFilterUpdate()
  end
  row4[3].handlers.onSliderCellActivated = function()
    tradeTab.menuMap.noupdate = true
  end
  row4[3].handlers.onSliderCellDeactivated = function()
    tradeTab.menuMap.noupdate = false
  end

  local row5 = objecttable:addRow("trade_filters_max_trade_distance", { fixed = true })
  row5[1]:setColSpan(2):createText("Max Trade Distance", { fontsize = fontSize, mouseOverText = "Maximum route distance allowed between seller and buyer in Best Trades." })
  row5[3]:setColSpan(totalCols - 2):createSliderCell({
    min = 0,
    max = 10,
    start = tonumber(tradeTab.filters.maxTradeDistance) or 0,
    step = 1,
    height = rowHeight,
    readOnly = tradeTab.filters.mode ~= "best",
    mouseOverText = "Maximum route distance allowed between seller and buyer in Best Trades.",
  }):setText("", { fontsize = fontSize })
  row5[3].handlers.onSliderCellChanged = function(_, value)
    tradeTab.filters.maxTradeDistance = tostring(math.max(0, math.min(10, math.floor((tonumber(value) or 0) + 0.5))))
  end
  row5[3].handlers.onSliderCellConfirm = function()
    tradeTab.menuMap.noupdate = false
    refresh()
  end
  row5[3].handlers.onSliderCellActivated = function()
    tradeTab.menuMap.noupdate = true
  end
  row5[3].handlers.onSliderCellDeactivated = function()
    tradeTab.menuMap.noupdate = false
  end

  local row6 = objecttable:addRow("trade_filters_cargo_volume", { fixed = true })
  row6[1]:setColSpan(2):createText("Cargo Volume", { fontsize = fontSize, mouseOverText = "One-trip cargo volume used to estimate trip amount and trip profit in Best Trades. 0 means Full Offer." })
  row6[3]:setColSpan(totalCols - 5):createEditBox({
    active = tradeTab.filters.mode == "best",
    height = rowHeight,
    description = "0-100000",
    defaultText = "0",
    maxChars = 6,
    mouseOverText = "Sets one-trip cargo volume for Best Trades. 0 means Full Offer with no one-trip cargo limit.",
  }):setText(tostring(tonumber(tradeTab.filters.cargoVolume) or 5000), { fontsize = fontSize, halign = "left", x = Helper.standardTextOffsetx })
  row6[3].handlers.onEditBoxActivated = function()
    tradeTab.menuMap.noupdate = true
  end
  row6[3].handlers.onTextChanged = function(_, text)
    tradeTab.filters.cargoVolume = normalizeCargoVolume(text)
  end
  row6[3].handlers.onEditBoxDeactivated = function(_, text)
    tradeTab.filters.cargoVolume = normalizeCargoVolume(text)
    tradeTab.menuMap.noupdate = false
    refresh()
  end
  row6[8]:setColSpan(3):createButton({
    active = tradeTab.filters.mode == "best",
    height = rowHeight,
    mouseOverText = "Apply the typed Cargo Volume value and refresh Best Trades.",
  }):setText("Apply", { fontsize = fontSize })
  row6[8].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    refresh()
  end

  local rowsAdded = 9
  if tradeTab.filters.mode == "best" then
    local labelRow = objecttable:addRow("trade_best_labels", {
      fixed = true,
      bgColor = Color["row_background_unselectable"],
      interactive = false,
    })
    labelRow[1]:setColSpan(4):createText("From/To", { color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Ware and destination station for the best matching one-trip sale from this source station." })
    labelRow[5]:createText("Trip", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "How many units fit in one trip with the current Cargo Volume setting. Shows trip amount, or trip/full amount if the full offer exceeds one trip." })
    labelRow[6]:createText("Jumps", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Gate jumps from the source station sector to the buyer sector." })
    labelRow[7]:createText("Buy Cr", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Price paid at the source station." })
    labelRow[8]:createText("Sell Cr", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Price offered by the destination buyer." })
    labelRow[9]:createText("Trip Profit", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Profit for one trip: (Sell Cr - Buy Cr) x Trip amount." })
    labelRow[10]:createText("$/Jump", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "One-trip profit divided by route jumps. Higher values favor strong nearby trades." })
    rowsAdded = rowsAdded + 1
  elseif tradeTab.filters.mode == "sells" then
    local labelRow = objecttable:addRow("trade_sell_labels", {
      fixed = true,
      bgColor = Color["row_background_unselectable"],
      interactive = false,
    })
    labelRow[1]:setColSpan(7):createText("Ware", { color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Ware sold by this station." })
    labelRow[8]:createText("Qty", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Quantity currently offered by this station." })
    labelRow[9]:createText("Price", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Current sell price at this station." })
    labelRow[10]:createText("Demand", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Game pricing detail derived from current supply and demand pressure." })
    rowsAdded = rowsAdded + 1
  else
    local labelRow = objecttable:addRow("trade_buy_labels", {
      fixed = true,
      bgColor = Color["row_background_unselectable"],
      interactive = false,
    })
    labelRow[1]:setColSpan(7):createText("Ware", { color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Ware bought by this station." })
    labelRow[8]:createText("Qty", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Quantity currently requested by this station." })
    labelRow[9]:createText("Price", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Current buy price at this station." })
    labelRow[10]:createText("Demand", { halign = "right", color = Color["text_normal"], fontsize = fontSize, mouseOverText = "Game pricing detail derived from current supply and demand pressure." })
    rowsAdded = rowsAdded + 1
  end

  return rowsAdded
end

local function renderStationRow(objecttable, station, maxIcons, numDisplayed, frameCache)
  local totalCols = 4 + maxIcons
  local detailRows = getVisibleRows(station, frameCache)

  local row = objecttable:addRow({ "trade_station", station.id }, {
    bgColor = Color["row_background_blue"],
  })
  row[1]:setColSpan(totalCols):createButton({
    bgColor = Color["button_background_hidden"],
    highlightColor = Color["button_highlight_hidden"],
  }):setText(trimText(station.name, 70), { halign = "left" })
  row[1].handlers.onRightClick = function()
    openStationContextMenu(station.id)
  end
  numDisplayed = numDisplayed + 1

  if tradeTab.filters.mode == "best" then
    local buyerGroups = buildBuyerGroups(station, frameCache)
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
          tripAmountText(tradeRow.tripAmount, tradeRow.amount),
          { halign = "right", color = Color["text_normal"], mouseOverText = tripAmountMouseOverText(tradeRow.tripAmount, tradeRow.amount) }
        )
        wareRow[6]:createText(
          jumpsText(tradeRow.routeDistance),
          { halign = "right", color = Color["text_normal"] }
        )
        wareRow[7]:createText(
          compactMoneyText(tradeRow.buyPrice),
          { halign = "right", color = Color["text_normal"], mouseOverText = exactMoneyText(tradeRow.buyPrice) }
        )
        wareRow[8]:createText(
          compactMoneyText(tradeRow.sellPrice),
          { halign = "right", color = Color["text_normal"], mouseOverText = exactMoneyText(tradeRow.sellPrice) }
        )
        wareRow[9]:createText(
          totalProfitText(tradeRow.buyPrice, tradeRow.sellPrice, tradeRow.tripAmount),
          { halign = "right", color = Color["text_positive"], mouseOverText = exactMoneyText(totalProfitValue(tradeRow.buyPrice, tradeRow.sellPrice, tradeRow.tripAmount)) }
        )
        wareRow[10]:createText(
          profitPerJumpText(tradeRow.buyPrice, tradeRow.sellPrice, tradeRow.tripAmount, tradeRow.routeDistance),
          { halign = "right", color = Color["text_positive"], mouseOverText = ((tonumber(tradeRow.routeDistance) == nil) and "-" or exactMoneyText(profitPerJumpValue(tradeRow.buyPrice, tradeRow.sellPrice, tradeRow.tripAmount, tradeRow.routeDistance))) }
        )
        numDisplayed = numDisplayed + 1
      end
    end
  else
    for _, tradeRow in ipairs(detailRows) do
      local child = objecttable:addRow(false, {
        interactive = false,
      })
      child[1]:setColSpan(7):createText(
        trimText(indentText(1, wareName(tradeRow.ware)), 68),
        { color = Color["text_warning"] }
      )
      child[8]:createText(
        amountText(tradeRow.amount),
        { halign = "right", color = Color["text_normal"], mouseOverText = exactAmountText(tradeRow.amount) }
      )
      child[9]:createText(
        compactMoneyText(tradeRow.price),
        { halign = "right", color = Color["text_normal"], mouseOverText = exactMoneyText(tradeRow.price) }
      )
      child[10]:createText(
        demandValueText(tradeRow.ware, tradeRow.price, tradeRow.isbuyoffer),
        { halign = "right", color = demandColor(tradeRow.ware, tradeRow.price, tradeRow.isbuyoffer) }
      )
      numDisplayed = numDisplayed + 1
    end
  end

  return numDisplayed
end

local function countVisibleStations(dataset, filterContext, frameCache)
  local count = 0
  for _, station in ipairs(dataset.stations) do
    if stationPassesFilter(station, filterContext, frameCache) then
      count = count + 1
    end
  end
  return count
end

local function countCachedTradeOffers(dataset)
  local stationCount = 0
  local offerCount = 0

  for _, station in ipairs(dataset.stations) do
    stationCount = stationCount + 1
    offerCount = offerCount + #station.buys + #station.sells
  end

  return stationCount, offerCount
end

local function getBestStationScore(station, frameCache)
  local rows = getVisibleRows(station, frameCache)
  local bestRow = rows[1]
  if not bestRow then
    return -1, -1, -1
  end

  return bestRow.profitPerJump or -1, bestRow.totalProfit or -1, bestRow.tripAmount or -1
end

local function getBestDemandStationScore(station, frameCache)
  local rows = getVisibleRows(station, frameCache)
  local bestRow = rows[1]
  if not bestRow then
    return nil, nil
  end

  return demandPercentValue(bestRow.ware, bestRow.price), bestRow.price
end

local function restoreTableState(objecttable, side)
  local menu = tradeTab.menuMap
  if not objecttable or not menu then
    return
  end

  local topRow
  if side == "right" then
    topRow = tradeTab.tableState.rightTopRow
  else
    topRow = menu.settoprow or tradeTab.tableState.leftTopRow
  end

  if topRow then
    objecttable:setTopRow(topRow)
    if side == "right" then
      tradeTab.tableState.rightTopRow = topRow
    else
      tradeTab.tableState.leftTopRow = topRow
    end
  end
end

local function addTradeBarEntry(bar)
  local tradeDataEntry = {
    name = "Trade Data",
    icon = TAB_ICON,
    mode = MODE,
    helpOverlayID = "help_sidebar_trade_data",
    helpOverlayText = "Known stations with trade data and best trade opportunities",
  }

  if not bar then
    return
  end

  if bar[#bar] and bar[#bar].mode == MODE then
    return
  end

  for i = #bar, 1, -1 do
    if bar[i].mode == MODE then
      table.remove(bar, i)
      if bar[i - 1] and bar[i - 1].spacing then
        table.remove(bar, i - 1)
      end
    end
  end

  bar[#bar + 1] = { spacing = true }
  bar[#bar + 1] = tradeDataEntry
end

local function createSideBar(config)
  addTradeBarEntry(config.leftBar)
end

local function createRightBar(config)
  addTradeBarEntry(config.rightBar)
end

local function createTradeFrame(frame, side)
  local menu = tradeTab.menuMap
  if not menu or not frame then
    return false
  end
  if side == "right" then
    if menu.searchTableMode ~= MODE then
      return false
    end
  elseif menu.infoTableMode ~= MODE then
    return false
  end

  local ok, err = pcall(function()
    tradeTab.tradeDistanceRequestsRemaining = 1
    syncTradeDistanceCacheFromBlackboard()

    rememberTableState(side)

    local objecttable = frame:addTable(10, {
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

    local titleRow = objecttable:addRow("trade_data_title", {
      fixed = true,
      bgColor = Color["row_title_background"],
    })
    titleRow[1]:setColSpan(6):createText("Trade Data", {
      color = Color["text_normal"],
      halign = "left",
      fontsize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize,
    })

    local dataset = getTradeDataset(false)
    local filterContext = buildFilterContext()
    local frameCache = {
      bestTradeRowsByStation = {},
    }
    local stationsToRender = dataset.stations
    if tradeTab.filters.mode == "best" then
      stationsToRender = {}
      for _, station in ipairs(dataset.stations) do
        table.insert(stationsToRender, station)
      end
      table.sort(stationsToRender, function(a, b)
        local aPpj, aProfit, aTrip = getBestStationScore(a, frameCache)
        local bPpj, bProfit, bTrip = getBestStationScore(b, frameCache)
        if aPpj == bPpj then
          if aProfit == bProfit then
            if aTrip == bTrip then
              return a.name < b.name
            end
            return aTrip > bTrip
          end
          return aProfit > bProfit
        end
        return aPpj > bPpj
      end)
    elseif (tradeTab.filters.mode == "sells") or (tradeTab.filters.mode == "buys") then
      stationsToRender = {}
      for _, station in ipairs(dataset.stations) do
        table.insert(stationsToRender, station)
      end
      table.sort(stationsToRender, function(a, b)
        local aDemand, aPrice = getBestDemandStationScore(a, frameCache)
        local bDemand, bPrice = getBestDemandStationScore(b, frameCache)

        if aDemand == nil then
          return false
        end
        if bDemand == nil then
          return true
        end

        if aDemand == bDemand then
          if aPrice == bPrice then
            return a.name < b.name
          end
          if tradeTab.filters.mode == "sells" then
            return aPrice < bPrice
          end
          return aPrice > bPrice
        end

        if tradeTab.filters.mode == "sells" then
          return aDemand < bDemand
        end
        return aDemand > bDemand
      end)
    end
    local visibleStations = countVisibleStations(dataset, filterContext, frameCache)
    local cachedStations, cachedOffers = countCachedTradeOffers(dataset)

    local maxIcons = 6
    local topRows = renderFilters(objecttable, dataset, maxIcons)
    local numDisplayed = topRows
    local renderedAny = false
    for _, station in ipairs(stationsToRender) do
      if stationPassesFilter(station, filterContext, frameCache) then
        numDisplayed = renderStationRow(objecttable, station, maxIcons, numDisplayed, frameCache)
        renderedAny = true
      end
    end

    if not renderedAny then
      local empty = objecttable:addRow(false, { interactive = false })
      empty[1]:setColSpan(4 + maxIcons):createText("-- No matching trade stations found --")
    end

    local detailRowsRendered = math.max(0, numDisplayed - topRows)
    titleRow[7]:setColSpan(4):createText(
      string.format("Shown %d/%d | Rows %d | Offers %d", visibleStations, cachedStations, detailRowsRendered, cachedOffers),
      {
        color = Color["text_normal"],
        halign = "right",
        fontsize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize,
      }
    )

    restoreTableState(objecttable, side)
    if side ~= "right" then
      menu.settoprow = nil
    end
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
    return true
  end

  return true
end

local function onStationRegistryUpdated()
  if tradeTab.menuMap and ((tradeTab.menuMap.infoTableMode == MODE) or (tradeTab.menuMap.searchTableMode == MODE)) then
    rememberTableState("left")
    rememberTableState("right")
    tradeTab.datasetDirty = true
  end
end

local function onGateDistanceFilterUpdated()
  tradeTab.gateDistanceFilterPending = false
  if tradeTab.menuMap and ((tradeTab.menuMap.infoTableMode == MODE) or (tradeTab.menuMap.searchTableMode == MODE)) then
    refresh()
  end
end

local function onTradeDistanceUpdated(_, sourceSectorRef)
  local sourceSectorId = normalizeBlackboardRef(sourceSectorRef)
  if sourceSectorId then
    tradeTab.tradeDistanceCachePending[tostring(sourceSectorId)] = nil
  end
  syncTradeDistanceCacheFromBlackboard()
end

local function createTradeFrameLeft(frame)
  return createTradeFrame(frame, "left")
end

local function createTradeFrameRight(frame)
  return createTradeFrame(frame, "right")
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
  menuMap.registerCallback("createRightBar_on_start", createRightBar, "my_trade_tab_rightbar")
  menuMap.registerCallback("createInfoFrame_on_menu_infoTableMode", createTradeFrameLeft, "my_trade_tab_infoframe")
  menuMap.registerCallback("createInfoFrame2_on_menu_infoModeRight", createTradeFrameRight, "my_trade_tab_infoframe_right")
  RegisterEvent("my_trade_tab.station_registry_updated", onStationRegistryUpdated)
  RegisterEvent("my_trade_tab.gate_distance_updated", onGateDistanceFilterUpdated)
  RegisterEvent("my_trade_tab.trade_distance_updated", onTradeDistanceUpdated)

  debug("trade data sidebar tab initialised")
end

Register_OnLoad_Init(Init)
