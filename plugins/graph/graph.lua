-- Pure graph construction for the knowledge-graph plugin.
--
-- File walking and frontmatter are deliberately kept in main.lua. This module
-- receives already-read note records and turns wiki links and relative
-- Markdown links into a bounded node/edge dataset for the host renderer.

local M = {}

local MAX_TARGETS = 1200

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
  return path:lower():match("%.md$") ~= nil or path:lower():match("%.markdown$") ~= nil
end

local function clean_target(raw)
  local target = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  target = target:gsub("^<", ""):gsub(">$", "")
  target = target:match("^[^%s]+") or ""
  target = target:gsub("|.*$", "")
  target = target:gsub("#.*$", "")
  target = target:gsub("%?.*$", "")
  return normalize(target)
end

local function resolve_target(source, target)
  if target == "" then return "" end
  if target:sub(1, 1) == "/" then return normalize(target) end
  local parent = dirname(source)
  if parent == "" then return normalize(target) end
  return normalize(parent .. "/" .. target)
end

local function strip_code(text)
  local lines = {}
  local fenced = false
  local fence_mark = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local clean_line = line:gsub("\r$", "")
    local fence = clean_line:match("^%s*(```)") or clean_line:match("^%s*(~~~)")
    if fence then
      if not fenced then
        fenced = true
        fence_mark = fence:sub(1, 1)
      elseif fence:sub(1, 1) == fence_mark then
        fenced = false
        fence_mark = nil
      end
      lines[#lines + 1] = ""
    elseif not fenced then
      -- Inline code must not create graph links.
      lines[#lines + 1] = clean_line:gsub("`[^`]*`", "")
    else
      lines[#lines + 1] = ""
    end
  end
  return table.concat(lines, "\n")
end

local function collect_targets(text)
  local body = strip_code(text)
  local targets = {}

  for raw in body:gmatch("%[%[([^%]]+)%]%]") do
    targets[#targets + 1] = clean_target(raw)
  end

  -- Images are not note links.
  body = body:gsub("!%[[^%]]*%]%([^%)]+%)", "")
  for raw in body:gmatch("%]%(([^%)]+)%)") do
    local target = clean_target(raw)
    if target ~= "" and not target:match("^[A-Za-z][A-Za-z0-9+.-]*:") then
      targets[#targets + 1] = target
    end
  end
  return targets
end

local function add_index(index, key, path)
  key = key:lower()
  if key ~= "" and not index[key] then index[key] = path end
end

local function build_index(records)
  local index = {}
  for _, record in ipairs(records) do
    local path = record.path
    local lower = path:lower()
    add_index(index, lower, path)
    add_index(index, without_markdown(lower), path)
    local base = basename(lower)
    add_index(index, base, path)
    add_index(index, without_markdown(base), path)
  end
  return index
end

local function resolve_record(index, source, target)
  if target == "" then return nil end
  local joined = resolve_target(source, target)
  local exact = index[joined:lower()]
  if exact then return exact end
  local no_ext = index[without_markdown(joined):lower()]
  if no_ext then return no_ext end
  return index[without_markdown(basename(joined)):lower()]
end

local function group_of(path)
  return path:match("^([^/]+)/") or ""
end

--- Build graph facts from note records.
---@param records table[] each item has `path`, `text`, `title`
---@param focus string|nil workspace-relative active-document path
function M.build(records, focus)
  table.sort(records, function(a, b) return a.path < b.path end)
  local index = build_index(records)
  local nodes = {}
  local node_by_id = {}
  local edges = {}
  local edge_seen = {}
  local missing = {}
  local target_count = 0

  local function add_node(path, title, kind)
    if node_by_id[path] then return false end
    local node = {
      id = path,
      label = title,
      kind = kind,
      group = group_of(path),
      focus = focus == path,
    }
    node_by_id[path] = node
    nodes[#nodes + 1] = node
    return true
  end

  for _, record in ipairs(records) do
    add_node(record.path, record.title, "note")
  end

  for _, record in ipairs(records) do
    for _, target in ipairs(collect_targets(record.text)) do
      target_count = target_count + 1
      if target_count > MAX_TARGETS then break end
      local resolved = resolve_record(index, record.path, target)
      if not resolved then
        local missing_id = "missing:" .. target
        if add_node(missing_id, basename(target), "missing") then
          missing[missing_id] = true
        end
        resolved = missing_id
      end
      if resolved and resolved ~= record.path then
        local key = record.path .. "\0" .. resolved
        if not edge_seen[key] then
          edge_seen[key] = true
          edges[#edges + 1] = {
            source = record.path,
            target = resolved,
            both = edge_seen[resolved .. "\0" .. record.path] == true,
          }
        end
      end
    end
    if target_count > MAX_TARGETS then break end
  end

  for _, edge in ipairs(edges) do
    if edge_seen[edge.target .. "\0" .. edge.source] then edge.both = true end
  end

  return {
    nodes = nodes,
    edges = edges,
    note_count = #records,
    missing_count = (function()
      local n = 0
      for _ in pairs(missing) do n = n + 1 end
      return n
    end)(),
    truncated = target_count > MAX_TARGETS,
  }
end

M.clean_target = clean_target
M.collect_targets = collect_targets
M.is_markdown = is_markdown
M.normalize = normalize

return M
