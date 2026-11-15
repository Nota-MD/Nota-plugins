-- Pure CJK/Latin spacing rules for Markdown.

local M = {}

local FENCE = "^%s*(```+)"
local TILDE_FENCE = "^%s*(~~~+)"

local function count(text, needle)
  local total = 0
  local from = 1
  while true do
    local at = text:find(needle, from, true)
    if not at then return total end
    total = total + 1
    from = at + #needle
  end
end

local function is_cjk(cp)
  return (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0x3040 and cp <= 0x30FF)
    or (cp >= 0x31F0 and cp <= 0x31FF)
    or (cp >= 0x2E80 and cp <= 0x2EFF)
end

local function is_japanese(cp)
  return (cp >= 0x3040 and cp <= 0x30FF)
    or (cp >= 0x31F0 and cp <= 0x31FF)
end

local function is_letter(cp)
  return (cp >= 0x41 and cp <= 0x5A)
    or (cp >= 0x61 and cp <= 0x7A)
end

local function is_numeric(cp)
  return (cp >= 0x30 and cp <= 0x39)
    or cp == 0x25
end

local function is_latin(cp)
  return is_letter(cp) or is_numeric(cp)
end

local function gap(cp)
  return cp == 0x20 or cp == 0xA0
end

local function clamped(value, fallback)
  value = tonumber(value)
  if value == nil or value ~= value then return fallback end
  value = math.floor(value)
  if value < 0 then return 0 end
  if value > 4 then return 4 end
  return value
end

local function enabled(options, key, fallback)
  local value = options and options[key]
  if value == nil then return fallback end
  return value == true
end

local function spaced_plain(text, options)
  local cjk_to_latin = clamped(options and options.cjk_to_latin, 1)
  local latin_to_cjk = clamped(options and options.latin_to_cjk, 1)
  local include_japanese = enabled(options, "include_japanese", true)
  local include_numbers = enabled(options, "include_numbers", true)
  local function cjk(cp)
    return is_cjk(cp) and (include_japanese or not is_japanese(cp))
  end
  local function latin(cp)
    return is_letter(cp) or (include_numbers and is_numeric(cp))
  end
  local chars = {}
  local ok = pcall(function()
    for _, cp in utf8.codes(text) do chars[#chars + 1] = cp end
  end)
  if not ok then return text, 0 end
  local out = {}
  local changes = 0
  local index = 1
  while index <= #chars do
    local cp = chars[index]
    out[#out + 1] = utf8.char(cp)
    local next_index = index + 1
    while next_index <= #chars and gap(chars[next_index]) do next_index = next_index + 1 end
    local next_cp = chars[next_index]
    if next_cp and cjk(cp) and latin(next_cp) then
      out[#out + 1] = string.rep(" ", cjk_to_latin)
      local old_gap = next_index - index - 1
      local ordinary = true
      for gap_index = index + 1, next_index - 1 do
        if chars[gap_index] ~= 0x20 then ordinary = false end
      end
      if old_gap ~= cjk_to_latin or not ordinary then changes = changes + 1 end
      index = next_index - 1
    elseif next_cp and latin(cp) and cjk(next_cp) then
      out[#out + 1] = string.rep(" ", latin_to_cjk)
      local old_gap = next_index - index - 1
      local ordinary = true
      for gap_index = index + 1, next_index - 1 do
        if chars[gap_index] ~= 0x20 then ordinary = false end
      end
      if old_gap ~= latin_to_cjk or not ordinary then changes = changes + 1 end
      index = next_index - 1
    end
    index = index + 1
  end
  return table.concat(out), changes
end

local function next_protected(line, at)
  local ch = line:sub(at, at)
  if ch == "`" then
    local run = line:match("^(`+)", at)
    local close = line:find(run, at + #run, true)
    if close then return close + #run end
  elseif ch == "$" then
    local close = line:find("$", at + 1, true)
    if close then return close + 1 end
  elseif line:sub(at, at + 1) == "](" then
    local close = line:find(")", at + 2, true)
    if close then return close + 1 end
  elseif line:sub(at, at + 1) == "[[" then
    local close = line:find("]]", at + 2, true)
    if close then return close + 2 end
  elseif line:sub(at, at + 1) == "[^" then
    local close = line:find("]", at + 2, true)
    if close then return close + 1 end
  elseif line:sub(at, at + 7) == "http://" or line:sub(at, at + 7) == "https://" then
    local finish = line:find("[%s)]", at) or (#line + 1)
    return finish
  elseif ch == "<" then
    local close = line:find(">", at + 1, true)
    if close then return close + 1 end
  elseif ch == "#" and (at == 1 or line:sub(at - 1, at - 1):match("%s")) then
    local finish = line:find("%s", at + 1)
    if finish then return finish end
    return #line + 1
  elseif ch == "[" and line:sub(1, at - 1):match("^%s*$") then
    local definition = line:match("^%s*%[[^%]]+%]:")
    if definition then return #line + 1 end
  end
  return nil
end

local function space_line(line, options)
  local out = {}
  local cursor = 1
  local at = 1
  local changes = 0
  while at <= #line do
    local finish = next_protected(line, at)
    if finish then
      if cursor < at then
        local text, count = spaced_plain(line:sub(cursor, at - 1), options)
        out[#out + 1] = text
        changes = changes + count
      end
      out[#out + 1] = line:sub(at, finish - 1)
      cursor = finish
      at = finish
    else
      at = at + 1
    end
  end
  if cursor <= #line then
    local text, count = spaced_plain(line:sub(cursor), options)
    out[#out + 1] = text
    changes = changes + count
  end
  return table.concat(out), changes
end

local function space_document(text, options)
  local lines = {}
  local changes = 0
  local front = text:match("^%-%-%-\r?\n") ~= nil
  local fence = nil
  local math_block = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local check = line:gsub("\r$", "")
    if front and #lines > 0 and (check == "---" or check == "...") then
      front = false
      lines[#lines + 1] = line
    elseif front then
      lines[#lines + 1] = line
    else
      local marker = line:match(FENCE) or line:match(TILDE_FENCE)
      if line:match("^    ") or line:match("^\t") then
        lines[#lines + 1] = line
      elseif marker then
        if not fence then
          fence = marker:sub(1, 1)
        elseif marker:sub(1, 1) == fence then
          fence = nil
        end
        lines[#lines + 1] = line
      elseif fence then
        lines[#lines + 1] = line
      else
        local doubles = count(line, "$$")
        if math_block then
          lines[#lines + 1] = line
          if doubles % 2 == 1 then math_block = false end
        elseif line:match("^%s*%$%$") then
          lines[#lines + 1] = line
          if doubles % 2 == 1 then math_block = true end
        else
          local adjusted, count = space_line(line, options)
          lines[#lines + 1] = adjusted
          changes = changes + count
        end
      end
    end
  end
  return table.concat(lines, "\n"), changes
end

M.is_cjk = is_cjk
M.is_japanese = is_japanese
M.is_latin = is_latin
M.clamped = clamped
M.space_line = space_line
M.space_document = space_document

return M

