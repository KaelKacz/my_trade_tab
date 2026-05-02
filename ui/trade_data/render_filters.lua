local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function buildFilterOptions(dataset)
  local playerSectorId = getPlayerSectorID()
  if (tradeTab.filters.originSector == nil) and playerSectorId then
    tradeTab.filters.originSector = tostring(playerSectorId)
  end

  local wareOptions = {}
  local sectorOptions = {}
  local factionOptions = {}
  local illegalOptions = {
    { id = "hide", text = "Hide Illegal", icon = "", displayremoveoption = false },
    { id = "show", text = "Show Illegal", icon = "", displayremoveoption = false },
    { id = "only", text = "Only Illegal", icon = "", displayremoveoption = false },
  }
  local originSectorOptions = {}
  for _, entry in ipairs(dataset.wareOptions) do
    table.insert(wareOptions, entry)
  end
  for _, entry in ipairs(dataset.sectorOptions) do
    table.insert(sectorOptions, entry)
  end
  for _, entry in ipairs(dataset.factionOptions) do
    table.insert(factionOptions, entry)
  end
  for _, entry in ipairs(dataset.originSectorOptions) do
    table.insert(originSectorOptions, entry)
  end
  local validWares = {}
  for _, entry in ipairs(dataset.wareOptions) do
    validWares[entry.id] = true
  end
  for id in pairs(tradeTab.filters.wareSelection or {}) do
    if not validWares[id] then
      tradeTab.filters.wareSelection[id] = nil
    end
  end

  local validSectors = {}
  for _, entry in ipairs(dataset.sectorOptions) do
    validSectors[entry.id] = true
  end
  for id in pairs(tradeTab.filters.sectorSelection or {}) do
    if not validSectors[id] then
      tradeTab.filters.sectorSelection[id] = nil
    end
  end

  local validFactions = {}
  for _, entry in ipairs(dataset.factionOptions) do
    validFactions[entry.id] = true
  end
  for id in pairs(tradeTab.filters.factionSelection or {}) do
    if not validFactions[id] then
      tradeTab.filters.factionSelection[id] = nil
    end
  end

  if tradeTab.filters.illegal ~= "hide" and tradeTab.filters.illegal ~= "show" and tradeTab.filters.illegal ~= "only" then
    tradeTab.filters.illegal = "hide"
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

  return
    buildMultiSelectOptions("__all__", "All Wares", wareOptions, tradeTab.filters.wareSelection),
    buildMultiSelectOptions("__all__", "All Sectors", sectorOptions, tradeTab.filters.sectorSelection),
    buildMultiSelectOptions("__all__", "All Factions", factionOptions, tradeTab.filters.factionSelection),
    illegalOptions,
    originSectorOptions,
    wareOptions,
    sectorOptions,
    factionOptions
end

function renderFilters(objecttable, dataset, maxIcons)
  local totalCols = 4 + maxIcons
  local rowHeight = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapRowHeight) or Helper.standardTextHeight
  local fontSize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize

  local wareOptions, sectorOptions, factionOptions, illegalOptions, originSectorOptions, rawWareOptions, rawSectorOptions, rawFactionOptions = buildFilterOptions(dataset)

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

  local rowWare = objecttable:addRow("trade_filters_ware", { fixed = true })
  rowWare[1]:setColSpan(2):createText("Ware", { fontsize = fontSize, mouseOverText = "Filter results to a specific ware, or show all wares." })
  rowWare[3]:setColSpan(totalCols - 3):createDropDown(wareOptions, {
    startOption = "__all__",
    active = true,
    height = rowHeight,
    textOverride = filterSummary(tradeTab.filters.wareSelection, "All Wares", rawWareOptions, "Ware", "Wares"),
  }):setTextProperties({ fontsize = fontSize })
  rowWare[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    toggleSelection("wareSelection", id)
    refresh()
  end
  rowWare[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end
  rowWare[10]:createButton({
    active = selectionCount(tradeTab.filters.wareSelection) > 0,
    height = rowHeight,
    mouseOverText = "Reset Ware filter to All Wares.",
  }):setText("X", { fontsize = fontSize })
  rowWare[10].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    clearSelection("wareSelection")
    refresh()
  end

  local row2 = objecttable:addRow("trade_filters_sector", { fixed = true })
  row2[1]:setColSpan(2):createText("Sector", { fontsize = fontSize, mouseOverText = "Limit results to stations in one displayed sector name, or show all sectors." })
  row2[3]:setColSpan(totalCols - 3):createDropDown(sectorOptions, {
    startOption = "__all__",
    active = true,
    height = rowHeight,
    textOverride = filterSummary(tradeTab.filters.sectorSelection, "All Sectors", rawSectorOptions, "Sector", "Sectors"),
  }):setTextProperties({ fontsize = fontSize })
  row2[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    toggleSelection("sectorSelection", id)
    refresh()
  end
  row2[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end
  row2[10]:createButton({
    active = selectionCount(tradeTab.filters.sectorSelection) > 0,
    height = rowHeight,
    mouseOverText = "Reset Sector filter to All Sectors.",
  }):setText("X", { fontsize = fontSize })
  row2[10].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    clearSelection("sectorSelection")
    refresh()
  end

  local rowFaction = objecttable:addRow("trade_filters_faction", { fixed = true })
  rowFaction[1]:setColSpan(2):createText("Faction", { fontsize = fontSize, mouseOverText = "Limit offers to stations owned by one faction. Best Trades match either seller or buyer." })
  rowFaction[3]:setColSpan(totalCols - 3):createDropDown(factionOptions, {
    startOption = "__all__",
    active = true,
    height = rowHeight,
    textOverride = filterSummary(tradeTab.filters.factionSelection, "All Factions", rawFactionOptions, "Faction", "Factions"),
  }):setTextProperties({ fontsize = fontSize })
  rowFaction[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    toggleSelection("factionSelection", id)
    refresh()
  end
  rowFaction[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
  end
  rowFaction[10]:createButton({
    active = selectionCount(tradeTab.filters.factionSelection) > 0,
    height = rowHeight,
    mouseOverText = "Reset Faction filter to All Factions.",
  }):setText("X", { fontsize = fontSize })
  rowFaction[10].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    clearSelection("factionSelection")
    refresh()
  end

  local rowIllegal = objecttable:addRow("trade_filters_illegal", { fixed = true })
  rowIllegal[1]:setColSpan(2):createText("Illegal Wares", { fontsize = fontSize, mouseOverText = "Filter wares illegal to the station sector police faction." })
  rowIllegal[3]:setColSpan(totalCols - 2):createDropDown(illegalOptions, {
    startOption = tradeTab.filters.illegal,
    active = true,
    height = rowHeight,
  }):setTextProperties({ fontsize = fontSize })
  rowIllegal[3].handlers.onDropDownConfirmed = function(_, id)
    tradeTab.menuMap.noupdate = false
    tradeTab.filters.illegal = id
    refresh()
  end
  rowIllegal[3].handlers.onDropDownActivated = function()
    tradeTab.menuMap.noupdate = true
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
  row6[3]:setColSpan(totalCols - 6):createEditBox({
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
  end
  row6[7]:setColSpan(2):createButton({
    active = tradeTab.filters.mode == "best",
    height = rowHeight,
    mouseOverText = "Apply the typed Cargo Volume value and refresh Best Trades.",
  }):setText("Apply", { fontsize = fontSize })
  row6[7].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    refresh()
  end
  row6[9]:setColSpan(2):createButton({
    active = tradeTab.filters.mode == "best",
    height = rowHeight,
    mouseOverText = "Use the selected player ship's largest free cargo storage volume.",
  }):setText("Apply Ship", { fontsize = fontSize })
  row6[9].handlers.onClick = function()
    tradeTab.menuMap.noupdate = false
    if applySelectedShipCargoVolume() then
      refresh()
    end
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

function renderSettingsMockup(objecttable, maxIcons)
  local totalCols = 4 + maxIcons
  local fontSize = (tradeTab.menuMapConfig and tradeTab.menuMapConfig.mapFontSize) or Helper.standardFontSize

  local title = objecttable:addRow("trade_settings_title", {
    fixed = true,
    bgColor = Color["row_background_unselectable"],
    interactive = false,
  })
  title[1]:setColSpan(totalCols):createText("Settings", {
    color = Color["text_normal"],
    fontsize = fontSize,
    font = Helper.standardFontBold,
  })

  local sortRow = objecttable:addRow("trade_settings_sort", { fixed = true, interactive = false })
  sortRow[1]:setColSpan(3):createText("Best Trades Sort", { fontsize = fontSize })
  sortRow[4]:setColSpan(totalCols - 3):createText("$/Jump, Trip Profit, Trip Amount, Route Distance", {
    fontsize = fontSize,
    color = Color["text_inactive"] or Color["text_normal"],
  })

  local columnsTitle = objecttable:addRow("trade_settings_columns_title", {
    fixed = true,
    bgColor = Color["row_background_unselectable"],
    interactive = false,
  })
  columnsTitle[1]:setColSpan(totalCols):createText("Column Visibility", {
    color = Color["text_normal"],
    fontsize = fontSize,
    font = Helper.standardFontBold,
  })

  local columnsRow = objecttable:addRow("trade_settings_columns", { fixed = true, interactive = false })
  columnsRow[1]:setColSpan(2):createText("Trip", { fontsize = fontSize })
  columnsRow[3]:setColSpan(2):createText("Jumps", { fontsize = fontSize })
  columnsRow[5]:setColSpan(2):createText("Buy/Sell", { fontsize = fontSize })
  columnsRow[7]:setColSpan(2):createText("Profit", { fontsize = fontSize })
  columnsRow[9]:setColSpan(2):createText("$/Jump", { fontsize = fontSize })

  local noteRow = objecttable:addRow("trade_settings_note", { fixed = true, interactive = false })
  noteRow[1]:setColSpan(totalCols):createText("Mockup only: these controls are placeholders for the next pass.", {
    fontsize = fontSize,
    color = Color["text_inactive"] or Color["text_normal"],
  })

  return 5
end

