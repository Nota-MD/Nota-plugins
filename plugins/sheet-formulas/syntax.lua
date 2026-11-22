local M = {}

function M.parse_reference(text)
  if type(text) ~= "string" then
    return nil
  end
  local compact = text:gsub("%$", "")
  local letters, number = compact:match("^([A-Za-z]+)([1-9][0-9]*)$")
  if not letters or not number then
    return nil
  end
  local column = 0
  for index = 1, #letters do
    local code = letters:sub(index, index):upper():byte()
    if code < 65 or code > 90 then
      return nil
    end
    column = column * 26 + code - 64
  end
  return tonumber(number), column
end

function M.cell_name(row, column)
  local letters = {}
  local value = column
  while value > 0 do
    local digit = (value - 1) % 26
    table.insert(letters, 1, string.char(65 + digit))
    value = math.floor((value - 1) / 26)
  end
  return table.concat(letters) .. tostring(row)
end

function M.tokenize(source)
  local tokens = {}
  local position = 1
  local length = #source

  local function push(kind, value)
    tokens[#tokens + 1] = { kind = kind, value = value }
  end

  while position <= length do
    local char = source:sub(position, position)
    if char:match("%s") then
      position = position + 1
    elseif char:match("[0-9]") or (char == "." and source:sub(position + 1, position + 1):match("[0-9]")) then
      local start = position
      local seen_dot = false
      while position <= length do
        local current = source:sub(position, position)
        if current:match("[0-9]") then
          position = position + 1
        elseif current == "." and not seen_dot then
          seen_dot = true
          position = position + 1
        else
          break
        end
      end
      local exponent = source:sub(position, position)
      if exponent == "e" or exponent == "E" then
        local next_char = source:sub(position + 1, position + 1)
        local offset = 1
        if next_char == "+" or next_char == "-" then
          offset = 2
        end
        local exponent_start = position + offset
        local exponent_text = source:sub(exponent_start, exponent_start)
        if exponent_text:match("[0-9]") then
          position = exponent_start + 1
          while position <= length and source:sub(position, position):match("[0-9]") do
            position = position + 1
          end
        end
      end
      local raw = source:sub(start, position - 1)
      local number = tonumber(raw)
      if not number then
        return nil, "#VALUE!"
      end
      push("number", number)
    elseif char == '"' then
      position = position + 1
      local parts = {}
      local closed = false
      while position <= length do
        local current = source:sub(position, position)
        if current == '"' then
          if source:sub(position + 1, position + 1) == '"' then
            parts[#parts + 1] = '"'
            position = position + 2
          else
            position = position + 1
            closed = true
            break
          end
        else
          parts[#parts + 1] = current
          position = position + 1
        end
      end
      if not closed then
        return nil, "#VALUE!"
      end
      push("string", table.concat(parts))
    elseif char:match("[A-Za-z_%$]") then
      local start = position
      while position <= length and source:sub(position, position):match("[A-Za-z0-9_%$%.]") do
        position = position + 1
      end
      push("word", source:sub(start, position - 1))
    else
      local pair = source:sub(position, position + 1)
      if pair == "<=" or pair == ">=" or pair == "<>" then
        push("operator", pair)
        position = position + 2
      elseif char == "+" or char == "-" or char == "*" or char == "/" or char == "^"
        or char == "%" or char == "&" or char == "=" or char == "<" or char == ">"
        or char == ":" then
        push("operator", char)
        position = position + 1
      elseif char == "(" or char == ")" or char == "," then
        push(char, char)
        position = position + 1
      else
        return nil, "#VALUE!"
      end
    end
  end
  tokens[#tokens + 1] = { kind = "eof", value = "" }
  return tokens
end

function M.parser(tokens)
  local index = 1

  local function peek()
    return tokens[index]
  end

  local function take(kind, value)
    local token = tokens[index]
    if token.kind ~= kind or (value ~= nil and token.value ~= value) then
      return nil
    end
    index = index + 1
    return token
  end

  local parse_compare

  local function parse_primary()
    local token = peek()
    if token.kind == "number" then
      index = index + 1
      return { kind = "literal", value = token.value }
    end
    if token.kind == "string" then
      index = index + 1
      return { kind = "literal", value = token.value }
    end
    if token.kind == "(" then
      index = index + 1
      local node = parse_compare()
      if not node or not take(")") then
        return nil
      end
      return node
    end
    if token.kind ~= "word" then
      return nil
    end
    index = index + 1
    local word = token.value
    if peek().kind == "(" then
      index = index + 1
      local args = {}
      if peek().kind ~= ")" then
        while true do
          local argument = parse_compare()
          if not argument then
            return nil
          end
          args[#args + 1] = argument
          if take(",") then
          elseif take(")") then
            break
          else
            return nil
          end
        end
      else
        index = index + 1
      end
      return { kind = "call", name = word:upper(), args = args }
    end

    local row, column = M.parse_reference(word)
    if row then
      local node = { kind = "ref", row = row, column = column }
      if take("operator", ":") then
        local last = peek()
        if last.kind ~= "word" then
          return nil
        end
        index = index + 1
        local end_row, end_column = M.parse_reference(last.value)
        if not end_row then
          return nil
        end
        return {
          kind = "range",
          first = { row = row, column = column },
          last = { row = end_row, column = end_column },
        }
      end
      return node
    end

    local upper = word:upper()
    if upper == "TRUE" then
      return { kind = "literal", value = true }
    elseif upper == "FALSE" then
      return { kind = "literal", value = false }
    elseif upper == "PI" then
      return { kind = "literal", value = math.pi }
    end
    return { kind = "name_error", name = word }
  end

  local function parse_unary()
    local token = peek()
    if token.kind == "operator" and (token.value == "+" or token.value == "-") then
      index = index + 1
      local operand = parse_unary()
      if not operand then
        return nil
      end
      return { kind = "unary", operator = token.value, operand = operand }
    end
    return parse_primary()
  end

  local function parse_power()
    local node = parse_unary()
    if not node then
      return nil
    end
    if take("operator", "^") then
      local right = parse_power()
      if not right then
        return nil
      end
      return { kind = "binary", operator = "^", left = node, right = right }
    end
    return node
  end

  local function parse_postfix()
    local node = parse_power()
    if not node then
      return nil
    end
    while take("operator", "%") do
      node = { kind = "unary", operator = "%", operand = node }
    end
    return node
  end

  local function parse_multiply()
    local node = parse_postfix()
    if not node then
      return nil
    end
    while peek().kind == "operator" and (peek().value == "*" or peek().value == "/") do
      local operator = peek().value
      index = index + 1
      local right = parse_postfix()
      if not right then
        return nil
      end
      node = { kind = "binary", operator = operator, left = node, right = right }
    end
    return node
  end

  local function parse_add()
    local node = parse_multiply()
    if not node then
      return nil
    end
    while peek().kind == "operator" and (peek().value == "+" or peek().value == "-") do
      local operator = peek().value
      index = index + 1
      local right = parse_multiply()
      if not right then
        return nil
      end
      node = { kind = "binary", operator = operator, left = node, right = right }
    end
    return node
  end

  local function parse_concat()
    local node = parse_add()
    if not node then
      return nil
    end
    while take("operator", "&") do
      local right = parse_add()
      if not right then
        return nil
      end
      node = { kind = "binary", operator = "&", left = node, right = right }
    end
    return node
  end

  parse_compare = function()
    local node = parse_concat()
    if not node then
      return nil
    end
    while peek().kind == "operator" and
      (peek().value == "=" or peek().value == "<>" or peek().value == "<"
        or peek().value == ">" or peek().value == "<=" or peek().value == ">=") do
      local operator = peek().value
      index = index + 1
      local right = parse_concat()
      if not right then
        return nil
      end
      node = { kind = "binary", operator = operator, left = node, right = right }
    end
    return node
  end

  return {
    parse = function()
      local node = parse_compare()
      if not node or peek().kind ~= "eof" then
        return nil
      end
      return node
    end,
    position = function()
      return index
    end,
  }
end

return M
