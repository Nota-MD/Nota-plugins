-- Pure backlink indexing and resolution for Markdown notes.

local M = {}

local function slash(path)
  return (path:gsub("\\", "/"))
end

local function normalize(path)
  local parts = {}
  for part in slash(path):gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function without_markdown(path)
  return (path:gsub("%.markdown$", ""):gsub("%.md$", ""))
end

local function is_markdown(path)
  local lower = path:lower()
  return lower:match("%.md$") ~= nil or lower:match("%.markdown$") ~= nil
end

local function clean_target(raw, allow_spaces)
  local target = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  target = target:gsub("^<", ""):gsub(">$", "")
  if not allow_spaces then target = target:match("^[^%s]+") or "" end
  target = target:gsub("|.*$", "")
  target = target:gsub("#.*$", "")
  target = target:gsub("%?.*$", "")
  return normalize(target)
end

local function resolve_relative(source, target)
  if target == "" then return "" end
  if target:sub(1, 1) == "/" then return normalize(target) end
  local parent = dirname(source)
  if parent == "" then return normalize(target) end
  return normalize(parent .. "/" .. target)
end

local function strip_code_line(line)
  return line:gsub("`+[^`]*`+", "")
end

local function collect_links(text)
  local links = {}
  local fenced = false
  local fence_mark = nil
  local line_number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    line = line:gsub("\r$", "")
    local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if marker then
      if not fenced then
        fenced = true
        fence_mark = marker:sub(1, 1)
      elseif marker:sub(1, 1) == fence_mark then
        fenced = false
        fence_mark = nil
      end
    elseif not fenced then
      local clean = strip_code_line(line)
      for raw in clean:gmatch("%[%[([^%]]+)%]%]") do
        local target = clean_target(raw, true)
        if target ~= "" then links[#links + 1] = { target = target, line = line_number } end
      end
      local without_images = clean:gsub("!%[[^%]]*%]%([^%)]+%)", "")
      for raw in without_images:gmatch("%]%(([^%)]+)%)") do
        local target = clean_target(raw)
        if target ~= "" and not target:match("^[A-Za-z][A-Za-z0-9+.-]*:") then
          links[#links + 1] = { target = target, line = line_number }
        end
      end
    end
  end
  return links
end

local function quoted(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^([\"'])(.-)%1$", "%2")
end

local function metadata(path, text)
  local title, aliases = nil, {}
  local body = (text or ""):gsub("^\239\187\191", "")
  local front = body:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-")
  if front then
    for line in front:gmatch("[^\r\n]+") do
      local value = line:match("^[ \t]*title[ \t]*:[ \t]*(.-)[ \t]*$")
      if value then title = quoted(value) end
      local alias_line = line:match("^[ \t]*aliases[ \t]*:[ \t]*(.-)[ \t]*$")
      if alias_line then
        alias_line = alias_line:gsub("^%[", ""):gsub("%]$", "")
        for item in alias_line:gmatch("[^,]+") do
          local alias = quoted(item)
          if alias ~= "" then aliases[#aliases + 1] = alias end
        end
      end
    end
  end
  if not title or title == "" then
    for line in body:gmatch("[^\r\n]+") do
      local heading = line:match("^%s#%s+(.+)$")
      if heading then
        title = heading:gsub("%s+#+%s*$", "")
        title = title:gsub("^%s+", ""):gsub("%s+$", "")
        break
      end
    end
  end
  if not title or title == "" then title = without_markdown(basename(path or "")) end
  return title, aliases
end

local function add_index(index, key, path)
  key = (key or ""):lower()
  if key ~= "" and not index[key] then index[key] = path end
end

local function build_index(records)
  local index = {}
  for _, record in ipairs(records) do
    local lower = record.path:lower()
    add_index(index, lower, record.path)
    add_index(index, without_markdown(lower), record.path)
    add_index(index, basename(lower), record.path)
    add_index(index, without_markdown(basename(lower)), record.path)
    add_index(index, record.title, record.path)
    for _, alias in ipairs(record.aliases or {}) do add_index(index, alias, record.path) end
  end
  return index
end

local function resolve(index, source, target)
  if target == "" then return nil end
  local joined = resolve_relative(source, target)
  return index[joined:lower()]
    or index[without_markdown(joined):lower()]
    or index[without_markdown(basename(joined)):lower()]
    or index[target:lower()]
end

local function analyze(records, focus)
  table.sort(records, function(a, b) return a.path < b.path end)
  local index = build_index(records)
  local by_path = {}
  for _, record in ipairs(records) do by_path[record.path] = record end
  local current = by_path[focus]
  local result = { inbound = {}, outbound = {}, unresolved = {} }
  if not current then return result end

  for _, link in ipairs(collect_links(current.text)) do
    local target = resolve(index, current.path, link.target)
    if target and target ~= current.path then
      local record = by_path[target]
      result.outbound[#result.outbound + 1] = {
        path = target,
        title = record and record.title or without_markdown(basename(target)),
        line = link.line,
      }
    elseif not target then
      result.unresolved[#result.unresolved + 1] = {
        target = link.target,
        line = link.line,
      }
    end
  end

  for _, record in ipairs(records) do
    if record.path ~= current.path then
      for _, link in ipairs(collect_links(record.text)) do
        if resolve(index, record.path, link.target) == current.path then
          result.inbound[#result.inbound + 1] = {
            path = record.path,
            title = record.title,
            line = link.line,
          }
        end
      end
    end
  end
  return result
end

local function title_of(path, text)
  local title = metadata(path, text)
  if not title or title == "" then title = without_markdown(basename(path or "")) end
  return title
end

local function aliases_of(path, text)
  local _, aliases = metadata(path, text)
  return aliases
end

M.analyze = analyze
M.aliases_of = aliases_of
M.collect_links = collect_links
M.is_markdown = is_markdown
M.normalize = normalize
M.title_of = title_of

return M

