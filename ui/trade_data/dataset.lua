local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function collectTradeOffers(stationId)
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

function collectPlayerStationIDs()
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

function collectRegistryStationIDs()
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

function getGateDistanceSectorFilter()
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
    return nil
  end

  return allowed
end

function buildFilterContext()
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

function syncTradeDistanceCacheFromBlackboard()
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

function requestTradeDistanceCacheUpdate(sourceSectorId)
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

function getStationTradeState(stationId)
  local isKnown, isPlayerOwned, canTrade, inLiveView, hasTradeSubscription, classid = GetComponentData(
    stationId,
    "isknown",
    "isplayerowned",
    "canhavetradeoffers",
    "isinliveview",
    "tradesubscription",
    "classid"
  )
  local isOperational = true
  if type(IsComponentOperational) == "function" then
    local station64 = ConvertIDTo64Bit(stationId)
    local ok, operational = pcall(IsComponentOperational, station64)
    isOperational = ok and operational and true or false
  end

  return {
    isStation = Helper.isComponentClass(classid, "station"),
    isOperational = isOperational,
    isKnown = isKnown and true or false,
    isPlayerOwned = isPlayerOwned and true or false,
    canTrade = canTrade and true or false,
    inLiveView = inLiveView and true or false,
    hasTradeSubscription = hasTradeSubscription and true or false,
  }
end

function collectRenderedStationIDs()
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
      if Helper.isComponentClass(classid, "station") then
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

function collectCandidateStationIDs()
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

function buildSectorGraph(sectorIds)
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

function getSectorGateDistance(sourceSectorId, targetSectorId, sectorGraph, distanceCache)
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

function buildTradeDataset()
  local stationIds = collectCandidateStationIDs()
  local stations = {}
  local buyOffersByWare = {}
  local wares = {}
  local sectors = {}
  local factions = {}
  local sectorIds = {}
  local seenSectorIds = {}

  for _, stationId in ipairs(stationIds) do
    local state = getStationTradeState(stationId)
    local shouldInspect = state.isStation and state.isOperational and state.canTrade and (state.isPlayerOwned or state.inLiveView or state.hasTradeSubscription)
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
        local owner, ownerName = GetComponentData(stationId, "owner", "ownername")
        ownerName = (ownerName and ownerName ~= "") and ownerName or safeFactionName(owner)
        sectors[sectorName] = sectorName
        if owner and owner ~= "" and owner ~= "ownerless" then
          factions[owner] = ownerName
        end
        if sectorId and (not seenSectorIds[sectorId]) then
          seenSectorIds[sectorId] = true
          table.insert(sectorIds, sectorId)
        end
        stations[tostring(stationId)] = {
          id = stationId,
          name = safeName(stationId),
          owner = owner,
          ownerName = ownerName,
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

  local factionOptions = {}
  for faction, name in pairs(factions) do
    table.insert(factionOptions, { id = faction, text = name, icon = "", displayremoveoption = false })
  end
  table.sort(factionOptions, function(a, b) return a.text < b.text end)

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
    factionOptions = factionOptions,
    originSectorOptions = originSectorOptions,
    sectorGraph = sectorGraph,
    routeDistanceCache = routeDistanceCache,
  }
end

function getTradeDataset(forceRefresh)
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
