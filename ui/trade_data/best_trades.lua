local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function bestTradeSortOptions()
  return {
    { id = "profitPerJump", text = "$/Jump", icon = "", displayremoveoption = false },
    { id = "totalProfit", text = "Trip Profit", icon = "", displayremoveoption = false },
    { id = "tripAmount", text = "Trip Amount", icon = "", displayremoveoption = false },
    { id = "routeDistance", text = "Route Distance", icon = "", displayremoveoption = false },
  }
end

function normalizeBestTradeSettings()
  tradeTab.settings = tradeTab.settings or {}
  tradeTab.settings.bestColumns = tradeTab.settings.bestColumns or {}

  local validSort = false
  for _, option in ipairs(bestTradeSortOptions()) do
    if tradeTab.settings.bestSort == option.id then
      validSort = true
      break
    end
  end
  if not validSort then
    tradeTab.settings.bestSort = "profitPerJump"
  end

  local columns = tradeTab.settings.bestColumns
  if columns.trip == nil then columns.trip = true end
  if columns.jumps == nil then columns.jumps = true end
  if columns.buySell == nil then columns.buySell = true end
  if columns.profit == nil then columns.profit = true end
  if columns.profitPerJump == nil then columns.profitPerJump = true end
end

function isBestColumnVisible(key)
  normalizeBestTradeSettings()
  return tradeTab.settings.bestColumns[key] and true or false
end

function bestTradeVisibleValueColumnCount()
  local count = 0
  if isBestColumnVisible("trip") then count = count + 1 end
  if isBestColumnVisible("jumps") then count = count + 1 end
  if isBestColumnVisible("buySell") then count = count + 2 end
  if isBestColumnVisible("profit") then count = count + 1 end
  if isBestColumnVisible("profitPerJump") then count = count + 1 end
  return count
end

function toggleBestColumn(key)
  normalizeBestTradeSettings()
  local columns = tradeTab.settings.bestColumns
  local visibleCount = 0
  for _, columnKey in ipairs({ "trip", "jumps", "buySell", "profit", "profitPerJump" }) do
    if columns[columnKey] then
      visibleCount = visibleCount + 1
    end
  end

  if columns[key] and visibleCount <= 1 then
    return
  end
  columns[key] = not columns[key]
end

local function bestTradeSortValue(row, sortId)
  if not row then
    return nil
  end
  if sortId == "totalProfit" then
    return tonumber(row.totalProfit) or 0
  elseif sortId == "tripAmount" then
    return tonumber(row.tripAmount) or 0
  elseif sortId == "routeDistance" then
    return tonumber(row.routeDistance) or 999999
  end
  return tonumber(row.profitPerJump) or 0
end

local function compareBestTradeNumber(a, b, sortId)
  if a == b then
    return nil
  end
  if sortId == "routeDistance" then
    return a < b
  end
  return a > b
end

function compareBestTradeRows(a, b)
  normalizeBestTradeSettings()
  if not a then
    return false
  end
  if not b then
    return true
  end

  local sortId = tradeTab.settings.bestSort
  local primary = compareBestTradeNumber(bestTradeSortValue(a, sortId), bestTradeSortValue(b, sortId), sortId)
  if primary ~= nil then
    return primary
  end

  for _, fallbackSortId in ipairs({ "profitPerJump", "totalProfit", "tripAmount", "routeDistance" }) do
    if fallbackSortId ~= sortId then
      local fallback = compareBestTradeNumber(bestTradeSortValue(a, fallbackSortId), bestTradeSortValue(b, fallbackSortId), fallbackSortId)
      if fallback ~= nil then
        return fallback
      end
    end
  end

  return wareName(a.ware) < wareName(b.ware)
end

function bestTradeRowPassesFilter(row)
  if (tonumber(row.tripAmount) or 0) <= 0 then
    return false
  end

  local maxTradeDistance = tradeTab.filters.maxTradeDistance
  local limit = tonumber(maxTradeDistance)
  if limit == nil then
    return tradeRowPassesCommonFilters(row)
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

  return (routeDistance ~= nil) and (routeDistance <= limit) and tradeRowPassesCommonFilters(row)
end

function buildBestTradeRowsForStation(station, frameCache)
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
          sourceOwner = station.owner,
          targetOwner = targetStation and targetStation.owner or nil,
          sourceSectorId = station.sectorId,
          targetSectorId = targetStation and targetStation.sectorId or nil,
          routeDistance = routeDistance,
          buyPrice = offer.price,
          sellPrice = candidate.price,
          totalProfit = totalProfitValue(offer.price, candidate.price, tripAmount),
          profitPerJump = profitPerJumpValue(offer.price, candidate.price, tripAmount, routeDistance),
          amount = amount,
          tripAmount = tripAmount,
          isIllegal = isWareIllegalAtSector(offer.ware, station.sectorId) or isWareIllegalAtSector(offer.ware, targetStation and targetStation.sectorId or nil),
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

  table.sort(rows, compareBestTradeRows)

  if frameCache then
    frameCache.bestTradeRowsByStation[tostring(station.id)] = rows
  end

  return rows
end

function stationPassesFilter(station, filterContext, frameCache)
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

  if not selectionPasses(tradeTab.filters.sectorSelection, station.sector) then
    return false
  end

  if next(tradeTab.filters.wareSelection or {}) == nil then
    if tradeTab.filters.mode == "best" then
      for _, row in ipairs(buildBestTradeRowsForStation(station, frameCache)) do
        if row then
          return true
        end
      end
      return false
    elseif tradeTab.filters.mode == "sells" then
      for _, row in ipairs(station.sells) do
        if tradeRowPassesCommonFilters({
          ware = row.ware,
          owner = station.owner,
          isIllegal = isWareIllegalAtSector(row.ware, station.sectorId),
        }) then
          return true
        end
      end
      return false
    else
      for _, row in ipairs(station.buys) do
        if tradeRowPassesCommonFilters({
          ware = row.ware,
          owner = station.owner,
          isIllegal = isWareIllegalAtSector(row.ware, station.sectorId),
        }) then
          return true
        end
      end
      return false
    end
  end

  if tradeTab.filters.mode == "best" then
    for _, row in ipairs(buildBestTradeRowsForStation(station, frameCache)) do
      if tradeRowPassesCommonFilters(row) then
        return true
      end
    end
  elseif tradeTab.filters.mode == "sells" then
    for _, row in ipairs(station.sells) do
      if tradeRowPassesCommonFilters({
        ware = row.ware,
        owner = station.owner,
        isIllegal = isWareIllegalAtSector(row.ware, station.sectorId),
      }) then
        return true
      end
    end
  else
    for _, row in ipairs(station.buys) do
      if tradeRowPassesCommonFilters({
        ware = row.ware,
        owner = station.owner,
        isIllegal = isWareIllegalAtSector(row.ware, station.sectorId),
      }) then
        return true
      end
    end
  end

  return false
end

function getVisibleRows(station, frameCache)
  local rows = {}

  if tradeTab.filters.mode == "best" then
    for _, row in ipairs(buildBestTradeRowsForStation(station, frameCache)) do
      if tradeRowPassesCommonFilters(row) then
        table.insert(rows, row)
      end
    end
    return rows
  end

  if tradeTab.filters.mode == "sells" then
    for _, offer in ipairs(station.sells) do
      local row = {
          ware = offer.ware,
          amount = offer.amount,
          price = offer.price,
          isbuyoffer = false,
          owner = station.owner,
          isIllegal = isWareIllegalAtSector(offer.ware, station.sectorId),
        }
      if tradeRowPassesCommonFilters(row) then
        table.insert(rows, row)
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
      local row = {
          ware = offer.ware,
          amount = offer.amount,
          price = offer.price,
          isbuyoffer = true,
          owner = station.owner,
          isIllegal = isWareIllegalAtSector(offer.ware, station.sectorId),
        }
      if tradeRowPassesCommonFilters(row) then
        table.insert(rows, row)
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

function buildBuyerGroups(station, frameCache)
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
          sector = safeSector(buyerId),
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
    table.sort(group.rows, compareBestTradeRows)
  end

  table.sort(order, function(a, b)
    if not a.rows[1] or not b.rows[1] then
      return a.name < b.name
    end
    if not compareBestTradeRows(a.rows[1], b.rows[1]) and not compareBestTradeRows(b.rows[1], a.rows[1]) then
      return a.name < b.name
    end
    return compareBestTradeRows(a.rows[1], b.rows[1])
  end)

  return order
end
