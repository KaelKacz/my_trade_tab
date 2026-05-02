local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function addTradeBarEntry(bar)
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

function createSideBar(config)
  addTradeBarEntry(config.leftBar)
end

function createRightBar(config)
  addTradeBarEntry(config.rightBar)
end

function renderTradeTabs(frame)
  local menu = tradeTab.menuMap
  local rowHeight = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight
  local fallbackTabSize = Helper.sidebarWidth and Helper.scaleX(Helper.sidebarWidth) or Helper.scaleY(rowHeight * 3)
  local tabSize = (menu and menu.sideBarWidth) or fallbackTabSize
  local tabs = {
    { id = "best", text = "Best Trades", icon = "my_trade_tab_best" },
    { id = "sells", text = "Sell Offers", icon = "my_trade_tab_sells" },
    { id = "buys", text = "Buy Offers", icon = "my_trade_tab_buys" },
    { id = "settings", text = "Settings", icon = "my_trade_tab_settings" },
  }

  local tabtable = frame:addTable(#tabs, {
    tabOrder = 1,
    reserveScrollBar = false,
    highlightMode = "off",
  })
  tabtable:setDefaultCellProperties("button", { height = rowHeight })
  for index = 1, #tabs do
    tabtable:setColWidth(index, tabSize, false)
  end

  local row = tabtable:addRow("trade_data_tabs", { fixed = true })
  for index, tab in ipairs(tabs) do
    local selected = (tradeTab.activeTab or tradeTab.filters.mode) == tab.id
    row[index]:createButton({
      bgColor = selected and Color["row_background_selected"] or Color["row_title_background"],
      highlightColor = Color["button_highlight_default"],
      height = tabSize,
      width = tabSize,
      scaling = false,
      mouseOverText = tab.text,
    }):setIcon(tab.icon, { color = Color["icon_normal"] or Color["text_normal"] })
    row[index].handlers.onClick = function()
      tradeTab.menuMap.noupdate = false
      tradeTab.activeTab = tab.id
      if tab.id ~= "settings" then
        tradeTab.filters.mode = tab.id
      end
      if menu and menu.refreshInfoFrame then
        menu.refreshInfoFrame(1, index)
      else
        refresh()
      end
    end
  end

  return tabtable
end

function createTradeFrame(frame, side)
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

    tradeTab.activeTab = tradeTab.activeTab or tradeTab.filters.mode or "best"
    if tradeTab.activeTab ~= "settings" then
      tradeTab.filters.mode = tradeTab.activeTab
    end

    local tabtable = renderTradeTabs(frame)
    local objecttable = frame:addTable(10, {
      tabOrder = 2,
      skipTabChange = true,
      reserveScrollBar = false,
      highlightMode = "off",
    })
    objecttable.properties.y = tabtable.properties.y + tabtable:getFullHeight() + Helper.borderSize
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

    if tradeTab.activeTab == "settings" then
      renderSettingsMockup(objecttable, 6)
      titleRow[7]:setColSpan(4):createText("Settings", {
        color = Color["text_normal"],
        halign = "right",
        fontsize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize,
      })
      restoreTableState(objecttable, side)
      if side ~= "right" then
        menu.settoprow = nil
      end
      return
    end

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

function onStationRegistryUpdated()
  if tradeTab.menuMap and ((tradeTab.menuMap.infoTableMode == MODE) or (tradeTab.menuMap.searchTableMode == MODE)) then
    rememberTableState("left")
    rememberTableState("right")
    tradeTab.datasetDirty = true
  end
end

function onGateDistanceFilterUpdated()
  tradeTab.gateDistanceFilterPending = false
  if tradeTab.menuMap and ((tradeTab.menuMap.infoTableMode == MODE) or (tradeTab.menuMap.searchTableMode == MODE)) then
    refresh()
  end
end

function onTradeDistanceUpdated(_, sourceSectorRef)
  local sourceSectorId = normalizeBlackboardRef(sourceSectorRef)
  if sourceSectorId then
    tradeTab.tradeDistanceCachePending[tostring(sourceSectorId)] = nil
  end
  syncTradeDistanceCacheFromBlackboard()
end

function createTradeFrameLeft(frame)
  return createTradeFrame(frame, "left")
end

function createTradeFrameRight(frame)
  return createTradeFrame(frame, "right")
end

function onRefreshInfoFrame2Start()
  if tradeTab.menuMap and tradeTab.menuMap.searchTableMode == MODE then
    rememberTableState("right")
  end
  return false
end

function Init()
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
  menuMap.registerCallback("refreshInfoFrame2_on_start", onRefreshInfoFrame2Start, "my_trade_tab_infoframe_right_scroll")
  RegisterEvent("my_trade_tab.station_registry_updated", onStationRegistryUpdated)
  RegisterEvent("my_trade_tab.gate_distance_updated", onGateDistanceFilterUpdated)
  RegisterEvent("my_trade_tab.trade_distance_updated", onTradeDistanceUpdated)

  debug("trade data sidebar tab initialised")
end

