local M = {}

function M.build(api)
  local is_error = api.is_error
  local is_blank = api.is_blank
  local error_value = api.error_value
  local to_number = api.to_number
  local to_text = api.to_text
  local to_boolean = api.to_boolean
  local compare_values = api.compare_values
  local apply_binary = api.apply_binary
  local normalize_range = api.normalize_range

  local functions = {}

  functions.SUM = function(engine, args, environment)
    local numbers = engine:numeric_arguments(args, environment, false)
    if is_error(numbers) then
      return numbers
    end
    local total = 0
    for _, number in ipairs(numbers) do
      total = total + number
    end
    return total
  end

  functions.AVERAGE = function(engine, args, environment)
    local numbers = engine:numeric_arguments(args, environment, false)
    if is_error(numbers) then
      return numbers
    end
    if #numbers == 0 then
      return error_value("#DIV/0!")
    end
    local total = 0
    for _, number in ipairs(numbers) do
      total = total + number
    end
    return total / #numbers
  end

  functions.MIN = function(engine, args, environment)
    local numbers = engine:numeric_arguments(args, environment, false)
    if is_error(numbers) then
      return numbers
    end
    if #numbers == 0 then
      return 0
    end
    local result = numbers[1]
    for index = 2, #numbers do
      result = math.min(result, numbers[index])
    end
    return result
  end

  functions.MAX = function(engine, args, environment)
    local numbers = engine:numeric_arguments(args, environment, false)
    if is_error(numbers) then
      return numbers
    end
    if #numbers == 0 then
      return 0
    end
    local result = numbers[1]
    for index = 2, #numbers do
      result = math.max(result, numbers[index])
    end
    return result
  end

  functions.COUNT = function(engine, args, environment)
    local values = engine:arguments(args, environment)
    local count = 0
    for _, value in ipairs(values) do
      if is_error(value) then
        return value
      end
      if type(value) == "number" then
        count = count + 1
      end
    end
    return count
  end

  functions.COUNTA = function(engine, args, environment)
    local values = engine:arguments(args, environment)
    local count = 0
    for _, value in ipairs(values) do
      if is_error(value) then
        return value
      end
      if not is_blank(value) then
        count = count + 1
      end
    end
    return count
  end

  functions.IF = function(engine, args, environment)
    if #args < 2 then
      return error_value("#VALUE!")
    end
    local condition = to_boolean(engine:evaluate_node(args[1], environment))
    if is_error(condition) then
      return condition
    end
    if condition then
      return engine:evaluate_node(args[2], environment)
    elseif args[3] then
      return engine:evaluate_node(args[3], environment)
    end
    return false
  end

  functions.IFERROR = function(engine, args, environment)
    if #args < 2 then
      return error_value("#VALUE!")
    end
    local value = engine:evaluate_node(args[1], environment)
    if is_error(value) then
      return engine:evaluate_node(args[2], environment)
    end
    return value
  end

  functions.AND = function(engine, args, environment)
    for _, node in ipairs(args) do
      local value = to_boolean(engine:evaluate_node(node, environment))
      if is_error(value) then
        return value
      end
      if not value then
        return false
      end
    end
    return true
  end

  functions.OR = function(engine, args, environment)
    for _, node in ipairs(args) do
      local value = to_boolean(engine:evaluate_node(node, environment))
      if is_error(value) then
        return value
      end
      if value then
        return true
      end
    end
    return false
  end

  functions.NOT = function(engine, args, environment)
    if #args ~= 1 then
      return error_value("#VALUE!")
    end
    local value = to_boolean(engine:evaluate_node(args[1], environment))
    if is_error(value) then
      return value
    end
    return not value
  end

  local function unary_number(engine, args, environment)
    if #args < 1 then
      return error_value("#VALUE!")
    end
    return to_number(engine:evaluate_node(args[1], environment))
  end

  functions.ABS = function(engine, args, environment)
    local value = unary_number(engine, args, environment)
    return is_error(value) and value or math.abs(value)
  end

  local function round_away(value, digits)
    local factor = 10 ^ digits
    local scaled = value * factor
    if scaled >= 0 then
      return math.floor(scaled + 0.5) / factor
    end
    return math.ceil(scaled - 0.5) / factor
  end

  functions.ROUND = function(engine, args, environment)
    local value = unary_number(engine, args, environment)
    if is_error(value) then
      return value
    end
    local digits = args[2] and to_number(engine:evaluate_node(args[2], environment)) or 0
    if is_error(digits) then
      return digits
    end
    return round_away(value, math.floor(digits))
  end

  functions.ROUNDUP = function(engine, args, environment)
    local value = unary_number(engine, args, environment)
    if is_error(value) then
      return value
    end
    local digits = args[2] and to_number(engine:evaluate_node(args[2], environment)) or 0
    if is_error(digits) then
      return digits
    end
    digits = math.floor(digits)
    local factor = 10 ^ digits
    local scaled = value * factor
    return (scaled >= 0 and math.ceil(scaled) or math.floor(scaled)) / factor
  end

  functions.ROUNDDOWN = function(engine, args, environment)
    local value = unary_number(engine, args, environment)
    if is_error(value) then
      return value
    end
    local digits = args[2] and to_number(engine:evaluate_node(args[2], environment)) or 0
    if is_error(digits) then
      return digits
    end
    digits = math.floor(digits)
    local factor = 10 ^ digits
    local scaled = value * factor
    return (scaled >= 0 and math.floor(scaled) or math.ceil(scaled)) / factor
  end

  functions.INT = function(engine, args, environment)
    local value = unary_number(engine, args, environment)
    return is_error(value) and value or math.floor(value)
  end

  functions.MOD = function(engine, args, environment)
    if #args ~= 2 then
      return error_value("#VALUE!")
    end
    local dividend = to_number(engine:evaluate_node(args[1], environment))
    local divisor = to_number(engine:evaluate_node(args[2], environment))
    if is_error(dividend) then
      return dividend
    end
    if is_error(divisor) then
      return divisor
    end
    if divisor == 0 then
      return error_value("#DIV/0!")
    end
    return dividend - divisor * math.floor(dividend / divisor)
  end

  functions.POWER = function(engine, args, environment)
    if #args ~= 2 then
      return error_value("#VALUE!")
    end
    return apply_binary(
      "^",
      engine:evaluate_node(args[1], environment),
      engine:evaluate_node(args[2], environment)
    )
  end

  functions.SQRT = function(engine, args, environment)
    local value = unary_number(engine, args, environment)
    if is_error(value) then
      return value
    end
    if value < 0 then
      return error_value("#VALUE!")
    end
    return math.sqrt(value)
  end

  local function concatenate(values)
    local parts = {}
    for _, value in ipairs(values) do
      if is_error(value) then
        return value
      end
      parts[#parts + 1] = tostring(to_text(value))
    end
    return table.concat(parts)
  end

  functions.CONCAT = function(engine, args, environment)
    return concatenate(engine:arguments(args, environment))
  end

  local function text_length(text)
    return utf8.len(text) or #text
  end

  local function text_slice(text, start, count)
    if start < 1 then
      count = count + start - 1
      start = 1
    end
    if count <= 0 then
      return ""
    end
    local first = utf8.offset(text, start)
    if not first then
      return ""
    end
    local last = utf8.offset(text, start + count)
    if last then
      return text:sub(first, last - 1)
    end
    return text:sub(first)
  end

  functions.LEFT = function(engine, args, environment)
    local text = to_text(engine:evaluate_node(args[1], environment))
    if is_error(text) then
      return text
    end
    local count = args[2] and to_number(engine:evaluate_node(args[2], environment)) or 1
    if is_error(count) then
      return count
    end
    return text_slice(text, 1, math.max(0, math.floor(count)))
  end

  functions.RIGHT = function(engine, args, environment)
    local text = to_text(engine:evaluate_node(args[1], environment))
    if is_error(text) then
      return text
    end
    local count = args[2] and to_number(engine:evaluate_node(args[2], environment)) or 1
    if is_error(count) then
      return count
    end
    count = math.max(0, math.floor(count))
    return text_slice(text, math.max(1, text_length(text) - count + 1), count)
  end

  functions.MID = function(engine, args, environment)
    if #args < 3 then
      return error_value("#VALUE!")
    end
    local text = to_text(engine:evaluate_node(args[1], environment))
    local start = to_number(engine:evaluate_node(args[2], environment))
    local count = to_number(engine:evaluate_node(args[3], environment))
    if is_error(text) then
      return text
    end
    if is_error(start) then
      return start
    end
    if is_error(count) then
      return count
    end
    return text_slice(text, math.floor(start), math.floor(count))
  end

  functions.LEN = function(engine, args, environment)
    if #args ~= 1 then
      return error_value("#VALUE!")
    end
    local text = to_text(engine:evaluate_node(args[1], environment))
    return is_error(text) and text or text_length(text)
  end

  functions.TRIM = function(engine, args, environment)
    if #args ~= 1 then
      return error_value("#VALUE!")
    end
    local text = to_text(engine:evaluate_node(args[1], environment))
    if is_error(text) then
      return text
    end
    text = text:gsub("[\r\n\t ]+", " "):gsub("^ ", ""):gsub(" $", "")
    return text
  end

  local function range_values(engine, node, environment)
    if not node or node.kind ~= "range" then
      return nil
    end
    local range = normalize_range(node.first, node.last)
    local rows = {}
    for row = range.top, range.bottom do
      local values = {}
      for column = range.left, range.right do
        values[#values + 1] = engine:cell(row, column, environment.stack)
      end
      rows[#rows + 1] = values
    end
    return rows
  end

  functions.VLOOKUP = function(engine, args, environment)
    if #args < 3 then
      return error_value("#VALUE!")
    end
    local needle = engine:evaluate_node(args[1], environment)
    local rows = range_values(engine, args[2], environment)
    local column = to_number(engine:evaluate_node(args[3], environment))
    if is_error(needle) then
      return needle
    end
    if not rows then
      return error_value("#VALUE!")
    end
    if is_error(column) then
      return column
    end
    column = math.floor(column)
    if column < 1 then
      return error_value("#REF!")
    end
    local approximate = false
    if args[4] then
      local value = to_boolean(engine:evaluate_node(args[4], environment))
      if is_error(value) then
        return value
      end
      approximate = value
    end
    local candidate = nil
    for _, row in ipairs(rows) do
      local comparison = compare_values(row[1], needle)
      if is_error(comparison) then
        return comparison
      end
      if comparison == 0 then
        return row[column] or error_value("#REF!")
      end
      if approximate and comparison < 0 then
        candidate = row
      end
    end
    if candidate then
      return candidate[column] or error_value("#REF!")
    end
    return error_value("#N/A")
  end

  functions.INDEX = function(engine, args, environment)
    if #args < 2 then
      return error_value("#VALUE!")
    end
    local rows = range_values(engine, args[1], environment)
    if not rows then
      return error_value("#VALUE!")
    end
    local row = to_number(engine:evaluate_node(args[2], environment))
    local column = args[3] and to_number(engine:evaluate_node(args[3], environment)) or 1
    if is_error(row) then
      return row
    end
    if is_error(column) then
      return column
    end
    local selected = rows[math.floor(row)]
    if not selected then
      return error_value("#REF!")
    end
    return selected[math.floor(column)] or error_value("#REF!")
  end

  functions.MATCH = function(engine, args, environment)
    if #args < 2 then
      return error_value("#VALUE!")
    end
    local needle = engine:evaluate_node(args[1], environment)
    local rows = range_values(engine, args[2], environment)
    if is_error(needle) then
      return needle
    end
    if not rows then
      return error_value("#VALUE!")
    end
    local mode = args[3] and to_number(engine:evaluate_node(args[3], environment)) or 1
    if is_error(mode) then
      return mode
    end
    mode = math.floor(mode)
    local candidate = nil
    local index = 0
    for _, row in ipairs(rows) do
      for _, value in ipairs(row) do
        index = index + 1
        local comparison = compare_values(value, needle)
        if is_error(comparison) then
          return comparison
        end
        if comparison == 0 then
          return index
        end
        if mode ~= 0 then
          if (mode > 0 and comparison < 0) or (mode < 0 and comparison > 0) then
            candidate = index
          end
        end
      end
    end
    return candidate or error_value("#N/A")
  end

  return functions
end

return M
