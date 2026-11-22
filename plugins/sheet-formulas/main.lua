local formulas = require("formula")

local M = {}
local T = function(text) return text end

local function formula_display(snapshot)
  if not snapshot or type(snapshot.rows) ~= "table" then
    return nil
  end
  local _, displays = formulas.evaluate(snapshot.rows)
  local rendered = {}
  for row = 1, #snapshot.rows do
    local cells = snapshot.rows[row]
    for column = 1, #cells do
      local source = tostring(cells[column] or "")
      if formulas.is_formula_source(source) then
        rendered[formulas.cell_name(row, column)] = displays[row][column]
      end
    end
  end
  return rendered
end

local function render_snapshot(nota, snapshot)
  local rendered = formula_display(snapshot)
  if rendered then
    nota.table.render(rendered)
  end
end

function M.on_load(nota)
  T = function(text)
    return nota.i18n.text(text) or text
  end

  nota.table.on_snapshot(function(snapshot)
    render_snapshot(nota, snapshot)
  end)

  nota.command.register("keep-values", function()
    local snapshot = nota.table.snapshot()
    if not snapshot or type(snapshot.rows) ~= "table" then
      nota.ui.notify(T("Select a table first."), "warn")
      return { ok = false }
    end

    local values, displays = formulas.evaluate(snapshot.rows)
    local selection = snapshot.selection or { top = 1, left = 1, bottom = #snapshot.rows, right = 1 }
    local updates = {}
    for row = selection.top, selection.bottom do
      local cells = snapshot.rows[row] or {}
      for column = selection.left, selection.right do
        local source = tostring(cells[column] or "")
        if formulas.is_formula_source(source) then
          updates[#updates + 1] = {
            ref = formulas.cell_name(row, column),
            value = formulas.display(values[row][column]),
          }
        end
      end
    end

    if #updates == 0 then
      nota.ui.notify(T("The selected cells contain no formulas."), "info")
      return { ok = true, changed = 0 }
    end
    nota.table.replace_cells({ cells = updates })
    return { ok = true, changed = #updates }
  end)

  nota.table.register_action({
    id = "keep-values",
    label = T("Keep Values"),
    command = "keep-values",
  })

  render_snapshot(nota, nota.table.snapshot())
end

function M.on_unload() end

return M
