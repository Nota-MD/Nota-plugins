local M = {}
local syntax = require("syntax")

local ERROR_KEY = "__nota_sheet_error"

local function error_value(code)
  return { [ERROR_KEY] = code }
end

local function is_error(value)
  return type(value) == "table" and value[ERROR_KEY] ~= nil
end

local function error_code(value)
  return is_error(value) and value[ERROR_KEY] or nil
end

local parse_reference = syntax.parse_reference
local cell_name = syntax.cell_name

local function is_blank(value)
  return value == nil or value == ""
end

local function formula_body(source)
  local text = tostring(source or ""):match("^%s*(.-)%s*$")
  if not text or text:sub(1, 1) ~= "=" or text:sub(1, 2) == "==" then
    return nil
  end
  return text:sub(2)
end

local function is_formula_source(source)
  return formula_body(source) ~= nil
end

local function to_number(value)
  if is_error(value) then
    return value
  end
  if type(value) == "number" then
    return value
  end
  if type(value) == "boolean" then
    return value and 1 or 0
  end
  if is_blank(value) then
    return 0
  end
  if type(value) == "string" then
    local number = tonumber(value)
    if number then
      return number
    end
  end
  return error_value("#VALUE!")
end

local function to_text(value)
  if is_error(value) then
    return value
  end
  if value == nil then
    return ""
  end
  if type(value) == "boolean" then
    return value and "TRUE" or "FALSE"
  end
  if type(value) == "number" then
    return M.format_number(value)
  end
  return tostring(value)
end

local function to_boolean(value)
  if is_error(value) then
    return value
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if value == nil or value == "" then
    return false
  end
  local upper = tostring(value):upper()
  if upper == "TRUE" then
    return true
  elseif upper == "FALSE" then
    return false
  end
  return error_value("#VALUE!")
end

local function normalize_range(first, last)
  return {
    top = math.min(first.row, last.row),
    bottom = math.max(first.row, last.row),
    left = math.min(first.column, last.column),
    right = math.max(first.column, last.column),
  }
end

local function compare_values(left, right)
  if is_error(left) then
    return left
  end
  if is_error(right) then
    return right
  end
  if type(left) == "number" or type(right) == "number" then
    local a = to_number(left)
    local b = to_number(right)
    if is_error(a) then
      return a
    end
    if is_error(b) then
      return b
    end
    if a < b then
      return -1
    elseif a > b then
      return 1
    end
    return 0
  end
  local a = to_text(left)
  local b = to_text(right)
  if is_error(a) then
    return a
  end
  if is_error(b) then
    return b
  end
  a = a:lower()
  b = b:lower()
  if a < b then
    return -1
  elseif a > b then
    return 1
  end
  return 0
end

local function apply_binary(operator, left, right)
  if is_error(left) then
    return left
  end
  if is_error(right) then
    return right
  end
  if operator == "&" then
    return tostring(to_text(left)) .. tostring(to_text(right))
  end
  if operator == "=" or operator == "<>" or operator == "<"
    or operator == ">" or operator == "<=" or operator == ">=" then
    local comparison = compare_values(left, right)
    if is_error(comparison) then
      return comparison
    end
    if operator == "=" then
      return comparison == 0
    elseif operator == "<>" then
      return comparison ~= 0
    elseif operator == "<" then
      return comparison < 0
    elseif operator == ">" then
      return comparison > 0
    elseif operator == "<=" then
      return comparison <= 0
    end
    return comparison >= 0
  end

  local a = to_number(left)
  local b = to_number(right)
  if is_error(a) then
    return a
  end
  if is_error(b) then
    return b
  end
  if operator == "+" then
    return a + b
  elseif operator == "-" then
    return a - b
  elseif operator == "*" then
    return a * b
  elseif operator == "/" then
    if b == 0 then
      return error_value("#DIV/0!")
    end
    return a / b
  elseif operator == "^" then
    local result = a ^ b
    if result ~= result then
      return error_value("#VALUE!")
    end
    return result
  end
  return error_value("#VALUE!")
end

local Engine = {}
Engine.__index = Engine

function Engine.new(rows)
  local maximum_columns = 0
  for _, row in ipairs(rows) do
    maximum_columns = math.max(maximum_columns, #row)
  end
  return setmetatable({
    rows = rows,
    height = #rows,
    width = maximum_columns,
    values = {},
    states = {},
  }, Engine)
end

function Engine:source(row, column)
  local source = self.rows[row] and self.rows[row][column]
  if source == nil then
    return ""
  end
  return tostring(source)
end

function Engine:flatten(node, environment)
  if node and node.kind == "range" then
    local range = normalize_range(node.first, node.last)
    local values = {}
    for row = range.top, range.bottom do
      for column = range.left, range.right do
        values[#values + 1] = self:cell(row, column, environment.stack)
      end
    end
    return values
  end
  local value = self:evaluate_node(node, environment)
  return { value }
end

function Engine:arguments(args, environment)
  local values = {}
  for _, node in ipairs(args) do
    local expanded = self:flatten(node, environment)
    for _, value in ipairs(expanded) do
      values[#values + 1] = value
    end
  end
  return values
end

function Engine:numeric_arguments(args, environment, count_blank)
  local numbers = {}
  for _, value in ipairs(self:arguments(args, environment)) do
    if is_error(value) then
      return value
    end
    if type(value) == "number" then
      numbers[#numbers + 1] = value
    elseif count_blank and is_blank(value) then
      numbers[#numbers + 1] = 0
    end
  end
  return numbers
end

local functions = require("functions").build({
  is_error = is_error,
  is_blank = is_blank,
  error_value = error_value,
  to_number = to_number,
  to_text = to_text,
  to_boolean = to_boolean,
  compare_values = compare_values,
  apply_binary = apply_binary,
  normalize_range = normalize_range,
})

function Engine:evaluate_call(node, environment)
  local function_value = functions[node.name]
  if not function_value then
    return error_value("#NAME?")
  end
  return function_value(self, node.args, environment)
end

function Engine:evaluate_node(node, environment)
  if not node then
    return error_value("#VALUE!")
  end
  if node.kind == "literal" then
    return node.value
  elseif node.kind == "name_error" then
    return error_value("#NAME?")
  elseif node.kind == "ref" then
    return self:cell(node.row, node.column, environment.stack)
  elseif node.kind == "range" then
    return self:flatten(node, environment)
  elseif node.kind == "call" then
    return self:evaluate_call(node, environment)
  elseif node.kind == "unary" then
    local value = self:evaluate_node(node.operand, environment)
    if is_error(value) then
      return value
    end
    if node.operator == "+" then
      return to_number(value)
    elseif node.operator == "-" then
      local number = to_number(value)
      return is_error(number) and number or -number
    elseif node.operator == "%" then
      local number = to_number(value)
      return is_error(number) and number or number / 100
    end
  elseif node.kind == "binary" then
    local left = self:evaluate_node(node.left, environment)
    local right = self:evaluate_node(node.right, environment)
    return apply_binary(node.operator, left, right)
  end
  return error_value("#VALUE!")
end

function Engine:cell(row, column, stack)
  if row < 1 or column < 1 or row > self.height or column > self.width then
    return error_value("#REF!")
  end
  if self.states[row] and self.states[row][column] == "done" then
    return self.values[row][column]
  end
  if self.states[row] and self.states[row][column] == "visiting" then
    return error_value("#CYCLE!")
  end

  self.values[row] = self.values[row] or {}
  self.states[row] = self.states[row] or {}
  self.states[row][column] = "visiting"

  local source = self:source(row, column)
  local body = formula_body(source)
  local value
  if body == nil then
    value = tonumber(source)
    if value == nil then
      if source == "" then
        value = ""
      elseif source:upper() == "TRUE" then
        value = true
      elseif source:upper() == "FALSE" then
        value = false
      else
        value = source
      end
    end
  else
    local tokens, token_error = syntax.tokenize(body)
    if not tokens then
      value = error_value(token_error or "#VALUE!")
    else
      local parse = syntax.parser(tokens)
      local node = parse.parse()
      if not node then
        value = error_value("#VALUE!")
      else
        value = self:evaluate_node(node, { stack = stack })
      end
    end
  end

  self.states[row][column] = "done"
  self.values[row][column] = value
  return value
end

local function round_away(value, digits)
  local factor = 10 ^ digits
  local scaled = value * factor
  if scaled >= 0 then
    return math.floor(scaled + 0.5) / factor
  end
  return math.ceil(scaled - 0.5) / factor
end

function M.format_number(value)
  if value ~= value or value == math.huge or value == -math.huge then
    return "#VALUE!"
  end
  local rounded = round_away(value, 12)
  if math.abs(rounded - math.floor(rounded)) < 1e-12 then
    return string.format("%.0f", rounded)
  end
  local text = string.format("%.12g", rounded)
  return text
end

function M.display(value)
  if is_error(value) then
    return error_code(value)
  end
  if value == nil then
    return ""
  end
  if type(value) == "number" then
    return M.format_number(value)
  end
  if type(value) == "boolean" then
    return value and "TRUE" or "FALSE"
  end
  return tostring(value)
end

function M.evaluate(rows)
  local engine = Engine.new(rows)
  local values = {}
  local displays = {}
  for row = 1, engine.height do
    values[row] = {}
    displays[row] = {}
    for column = 1, engine.width do
      local value = engine:cell(row, column, {})
      values[row][column] = value
      displays[row][column] = M.display(value)
    end
  end
  return values, displays
end

function M.is_error(value)
  return is_error(value)
end

function M.is_formula_source(source)
  return is_formula_source(tostring(source or ""))
end

function M.formula_body(source)
  return formula_body(source)
end

function M.cell_name(row, column)
  return cell_name(row, column)
end

return M
