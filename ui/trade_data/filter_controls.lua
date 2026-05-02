local moduleEnv = MyTradeTab
setfenv(1, moduleEnv)
function selectionCount(selection)
  local count = 0
  for _ in pairs(selection or {}) do
    count = count + 1
  end
  return count
end

function selectionPasses(selection, value)
  if next(selection or {}) == nil then
    return true
  end
  return selection[value] and true or false
end

function toggleSelection(selectionKey, id)
  local selection = tradeTab.filters[selectionKey] or {}
  tradeTab.filters[selectionKey] = selection

  if id == "__all__" then
    for key in pairs(selection) do
      selection[key] = nil
    end
    return
  end

  if selection[id] then
    selection[id] = nil
  else
    selection[id] = true
  end
end

function clearSelection(selectionKey)
  local selection = tradeTab.filters[selectionKey] or {}
  for key in pairs(selection) do
    selection[key] = nil
  end
  tradeTab.filters[selectionKey] = selection
end

function filterSummary(selection, allText, options, singular, plural)
  local count = selectionCount(selection)
  if count == 0 then
    return allText
  end
  if count == 1 then
    for _, option in ipairs(options or {}) do
      if selection[option.id] then
        return option.text
      end
    end
    return "1 " .. singular
  end
  return tostring(count) .. " " .. plural
end

function buildMultiSelectOptions(allId, allText, options, selection)
  local result = {
    { id = allId, text = ((selectionCount(selection) == 0) and "[x] " or "[ ] ") .. allText, icon = "", displayremoveoption = false },
  }

  for _, option in ipairs(options or {}) do
    local selected = selection and selection[option.id]
    table.insert(result, {
      id = option.id,
      text = (selected and "[x] " or "[ ] ") .. option.text,
      icon = option.icon or "",
      displayremoveoption = false,
    })
  end

  return result
end
