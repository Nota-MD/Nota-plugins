package.path = "plugins/sheet-formulas/?.lua;" .. package.path

local formula = require("formula")
local count = 0

local function equal(actual, expected, message)
  count = count + 1
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
  end
end

local rows = {
  { "A", "B", "C", "D" },
  { "2", "3", "4", "=B2*C2" },
  { "5", "6", "7", "=SUM(A2:C3)" },
  { "10", "20", "30", "=D2+D3" },
}

local values, displays = formula.evaluate(rows)
equal(displays[2][4], "12", "multiplication")
equal(displays[3][4], "27", "sum range")
equal(displays[4][4], "39", "dependent formulas")
equal(formula.is_formula_source("=A1+1"), true, "single equals starts a formula")
equal(formula.is_formula_source("  =A1+1  "), true, "leading whitespace still starts a formula")
equal(formula.is_formula_source("="), true, "a lone equals is an incomplete formula")
equal(formula.is_formula_source("==notice=="), false, "Markdown highlight is not a formula")
equal(formula.is_formula_source("== notice =="), false, "spaced Markdown highlight is not a formula")
equal(formula.is_formula_source("===notice==="), false, "triple equals are not a formula")
equal(formula.is_formula_source("\\=A1"), false, "escaped equals are not a formula")
equal(formula.is_formula_source("`=A1`"), false, "inline code is not a formula")
equal(formula.is_formula_source("plain"), false, "plain text is not a formula")
equal(formula.formula_body("  =SUM(A1:A2)  "), "SUM(A1:A2)", "formula body is normalized")

local classification = formula.evaluate({
  { "  =1+2  ", "==notice==", "\\=A1", "`=A1`" },
})
equal(formula.display(classification[1][1]), "3", "whitespace formula evaluates")
equal(formula.display(classification[1][2]), "==notice==", "highlight stays text")
equal(formula.display(classification[1][3]), "\\=A1", "escaped equals stays text")
equal(formula.display(classification[1][4]), "`=A1`", "inline code stays text")

local functions = {
  { "=AVERAGE(A2:A3)", "3.5" },
  { "=MIN(A2:A3)", "2" },
  { "=MAX(A2:A3)", "5" },
  { "=COUNT(A2:C3)", "6" },
  { "=COUNTA(A2:D2)", "4" },
  { "=IF(A2=2,\"yes\",\"no\")", "yes" },
  { "=AND(A2=2,B2=3)", "TRUE" },
  { "=OR(FALSE,A2=2)", "TRUE" },
  { "=NOT(FALSE)", "TRUE" },
  { "=ROUND(12.345,2)", "12.35" },
  { "=ROUNDUP(12.341,2)", "12.35" },
  { "=ROUNDDOWN(12.349,2)", "12.34" },
  { "=MOD(10,3)", "1" },
  { "=POWER(2,8)", "256" },
  { "=SQRT(81)", "9" },
  { "=CONCAT(LEFT(\"Nota\",2),RIGHT(\"Editor\",2))", "Noor" },
  { "=MID(\"spreadsheet\",7,5)", "sheet" },
  { "=LEN(\"公式\")", "2" },
  { "=TRIM(\"  a   b  \")", "a b" },
}

for _, item in ipairs(functions) do
  local value = formula.evaluate({
    { "A", "B", "C", "D" },
    { "2", "3", "4", "x" },
    { "5", "6", "7", "x" },
    { item[1] },
  })
  equal(formula.display(value[4][1]), item[2], item[1])
end

local lookup = formula.evaluate({
  { "Key", "Name", "Score" },
  { "a", "Alpha", "10" },
  { "b", "Beta", "20" },
  { "c", "Gamma", "30" },
  { "=VLOOKUP(\"b\",A2:C4,2,FALSE)" },
  { "=INDEX(C2:C4,MATCH(\"c\",A2:A4,0))" },
})
equal(formula.display(lookup[5][1]), "Beta", "VLOOKUP")
equal(formula.display(lookup[6][1]), "30", "INDEX and MATCH")

local cycle = formula.evaluate({
  { "=B1", "=A1" },
})
equal(formula.display(cycle[1][1]), "#CYCLE!", "cycle detection")

local main = dofile("plugins/sheet-formulas/main.lua")
local rendered = nil
local replaced = nil
local command = nil
local action = nil
local snapshot_callback = nil
local snapshot = {
  rows = {
    { "A", "B" },
    { "2", "=A2*3" },
    { "4", "==notice==" },
  },
  selection = { top = 2, left = 1, bottom = 3, right = 2 },
}

local nota = {
  i18n = { text = function(text) return text end },
  ui = { notify = function() end },
  command = {
    register = function(_, callback)
      command = callback
    end,
  },
  table = {
    on_snapshot = function(callback)
      snapshot_callback = callback
    end,
    register_action = function(value)
      action = value
    end,
    render = function(value)
      rendered = value
    end,
    snapshot = function()
      return snapshot
    end,
    replace_cells = function(value)
      replaced = value
    end,
  },
}

main.on_load(nota)
snapshot_callback(snapshot)
equal(rendered.B2, "6", "extension display map")
equal(rendered.B3, nil, "Markdown highlight is not rendered as a formula")
equal(action.label, "Keep Values", "context action")

local result = command()
equal(result.changed, 1, "keep values count")
equal(replaced.cells[1].ref, "B2", "keep values first reference")
equal(replaced.cells[1].value, "6", "keep values first value")

print(string.format("ALL PASS (%d assertions)", count))
