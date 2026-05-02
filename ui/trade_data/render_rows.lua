local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function renderStationRow(objecttable, station, maxIcons, numDisplayed, frameCache)
  local totalCols = 4 + maxIcons
  local detailRows = getVisibleRows(station, frameCache)
  local detailRowIndex = 0
  local stationSelected = isMapComponentSelected(station.id)
  local stationBgColor = stationSelected and sellerRowColors.selected or Color["row_background_blue"]

  local row = objecttable:addRow({ "trade_station", station.id }, {
    bgColor = stationBgColor,
  })
  local stationLabel = station.name
  if station.sector and station.sector ~= "" then
    stationLabel = stationLabel .. " - " .. station.sector
  end
  row[1]:setColSpan(totalCols):createButton({
    bgColor = stationBgColor,
    highlightColor = Color["button_highlight_hidden"],
  }):setText(trimText(stationLabel, 90), { halign = "left" })
  row[1].handlers.onClick = function()
    selectMapComponent(station.id)
  end
  row[1].handlers.onDoubleClick = function()
    selectMapComponent(station.id)
    focusMapComponent(station.id)
  end
  row[1].handlers.onRightClick = function()
    openStationContextMenu(station.id)
  end
  numDisplayed = numDisplayed + 1

  if tradeTab.filters.mode == "best" then
    local buyerGroups = buildBuyerGroups(station, frameCache)
    for _, buyerGroup in ipairs(buyerGroups) do
      local buyerSelected = isMapComponentSelected(buyerGroup.id)
      local buyerBgColor = buyerSelected and buyerRowColors.selected or buyerRowColors.background
      local buyerRow = objecttable:addRow({ "trade_buyer", buyerGroup.id, station.id }, {
        bgColor = buyerBgColor,
      })
      local buyerLabel = buyerGroup.name
      if buyerGroup.sector and buyerGroup.sector ~= "" then
        buyerLabel = buyerLabel .. " - " .. buyerGroup.sector
      end
      buyerRow[1]:setColSpan(totalCols):createButton({
        bgColor = buyerBgColor,
        highlightColor = Color["button_highlight_hidden"],
      }):setText(trimText(indentText(1, buyerLabel), 72), { halign = "left" })
      buyerRow[1].handlers.onClick = function()
        selectMapComponent(buyerGroup.id)
      end
      buyerRow[1].handlers.onDoubleClick = function()
        selectMapComponent(buyerGroup.id)
        focusMapComponent(buyerGroup.id)
      end
      buyerRow[1].handlers.onRightClick = function()
        openStationContextMenu(buyerGroup.id)
      end
      numDisplayed = numDisplayed + 1

      for _, tradeRow in ipairs(buyerGroup.rows) do
        detailRowIndex = detailRowIndex + 1
        local wareRow = objecttable:addRow(false, {
          interactive = false,
          bgColor = wareRowBackground(detailRowIndex),
        })
        wareRow[1]:setColSpan(4):createText(
          trimText(indentText(2, wareName(tradeRow.ware)), 40),
          {
            color = tradeRow.isIllegal and (Color["text_illegal"] or Color["text_warning"]) or Color["text_normal"],
            mouseOverText = tradeRow.isIllegal and "Illegal ware in at least one endpoint sector." or nil,
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
      detailRowIndex = detailRowIndex + 1
      local child = objecttable:addRow(false, {
        interactive = false,
        bgColor = wareRowBackground(detailRowIndex),
      })
      child[1]:setColSpan(7):createText(
        trimText(indentText(1, wareName(tradeRow.ware)), 68),
        {
          color = tradeRow.isIllegal and (Color["text_illegal"] or Color["text_warning"]) or Color["text_normal"],
          mouseOverText = tradeRow.isIllegal and "Illegal ware in this station sector." or nil,
        }
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

function countVisibleStations(dataset, filterContext, frameCache)
  local count = 0
  for _, station in ipairs(dataset.stations) do
    if stationPassesFilter(station, filterContext, frameCache) then
      count = count + 1
    end
  end
  return count
end

function countCachedTradeOffers(dataset)
  local stationCount = 0
  local offerCount = 0

  for _, station in ipairs(dataset.stations) do
    stationCount = stationCount + 1
    offerCount = offerCount + #station.buys + #station.sells
  end

  return stationCount, offerCount
end

function getBestStationScore(station, frameCache)
  local rows = getVisibleRows(station, frameCache)
  local bestRow = rows[1]
  if not bestRow then
    return -1, -1, -1
  end

  return bestRow.profitPerJump or -1, bestRow.totalProfit or -1, bestRow.tripAmount or -1
end

function getBestDemandStationScore(station, frameCache)
  local rows = getVisibleRows(station, frameCache)
  local bestRow = rows[1]
  if not bestRow then
    return nil, nil
  end

  return demandPercentValue(bestRow.ware, bestRow.price), bestRow.price
end

function restoreTableState(objecttable, side)
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
