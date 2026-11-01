-- Knowledge Graph: inspect Markdown files in the current workspace and draw
-- their [[wiki links]] and relative Markdown links in an editor-wide panel.

local graph = require("graph")

local M = {}
local T = function(s) return s end

local PANEL_ID = "graph"
local MAX_FILES = 800
local MAX_FILE_BYTES = 1000000
local MAX_DEPTH = 12
local SKIP_DIRS = {
  [".git"] = true,
  [".obsidian"] = true,
  [".trash"] = true,
  ["node_modules"] = true,
  ["target"] = true,
  ["dist"] = true,
  ["build"] = true,
}

local cache = nil
local cache_error = nil
local dirty = true

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function path_join(parent, name)
  if parent == "" or parent == "." then return name end
  return parent .. "/" .. name
end

local function title_from(path, text)
  local body = (text or ""):gsub("^\239\187\191", "")
  local front = body:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-")
  if front then
    for line in front:gmatch("[^\r\n]+") do
      local title = trim(line:match("^[ \t]*title[ \t]*:[ \t]*(.-)[ \t]*$") or "")
      title = title:gsub("^([\"'])(.-)%1$", "%2")
      if title ~= "" then return title end
    end
  end
  for line in body:gmatch("[^\r\n]+") do
    local heading = line:match("^%s#%s+(.+)$")
    if heading then return trim(heading:gsub("%s+#+%s*$", "")) end
  end
  local base = path:match("([^/]+)$") or path
  return (base:gsub("%.markdown$", ""):gsub("%.md$", ""))
end

local function walk(nota, directory, depth, records, stats)
  if depth > MAX_DEPTH or #records >= MAX_FILES then return end
  local ok, entries = pcall(nota.fs.list, directory)
  if not ok or type(entries) ~= "table" then return end

  for _, name in ipairs(entries) do
    if #records >= MAX_FILES then return end
    local rel = path_join(directory, name)
    local hidden = name:sub(1, 1) == "."
    local skip = SKIP_DIRS[name]
    if not hidden and not skip then
      if graph.is_markdown(name) then
        local read_ok, text = pcall(nota.fs.read, rel)
        if read_ok and type(text) == "string" then
          if #text <= MAX_FILE_BYTES then
            records[#records + 1] = {
              path = graph.normalize(rel),
              text = text,
              title = title_from(rel, text),
            }
          else
            stats.skipped_large = stats.skipped_large + 1
          end
        end
      else
        -- `nota.fs` has no stat call. Trying list is the only portable way to
        -- distinguish a directory from an ordinary file using the current ABI.
        walk(nota, rel, depth + 1, records, stats)
      end
    end
  end
end

local function relative_focus(nota)
  if not nota.document or not nota.document.get_path then return nil end
  local path = nota.document.get_path()
  if not path or path == "" then return nil end
  local ok, rel = pcall(nota.fs.relative, path)
  if ok and type(rel) == "string" and rel ~= "" then
    return graph.normalize(rel)
  end
  return nil
end

local function load_graph(nota)
  local root_ok, root = pcall(nota.fs.root)
  if not root_ok or not root then
    cache = nil
    cache_error = T("Open a folder or a saved Markdown document to build the graph.")
    dirty = false
    return nil
  end

  local records = {}
  local stats = { skipped_large = 0 }
  walk(nota, ".", 0, records, stats)
  local result = graph.build(records, relative_focus(nota))
  result.truncated_files = #records >= MAX_FILES
  result.skipped_large = stats.skipped_large
  result.root = root
  cache = result
  cache_error = nil
  dirty = false
  return result
end

local function current_graph(nota)
  if dirty or not cache then return load_graph(nota) end
  return cache
end

local function graph_blocks(nota)
  local data = current_graph(nota)
  if not data then
    return {
      { kind = "hero", title = T("Knowledge graph"), subtitle = cache_error or "" },
      {
        kind = "buttons",
        items = {
          { label = T("Try again"), command = "refresh", style = "primary" },
        },
      },
    }
  end

  local nodes = {}
  for _, node in ipairs(data.nodes) do
    local action = nil
    if node.kind == "note" then
      action = {
        command = "open_note",
        args = { path = node.id },
        title = T("Open %s", node.label),
      }
    end
    nodes[#nodes + 1] = {
      id = node.id,
      label = node.label,
      kind = node.kind,
      group = node.group,
      focus = node.focus,
      action = action,
    }
  end

  local blocks = {
    {
      kind = "fields",
      items = {
        { label = T("Notes"), value = tostring(data.note_count), tone = "normal" },
        { label = T("Links"), value = tostring(#data.edges), tone = "normal" },
        { label = T("Unresolved"), value = tostring(data.missing_count), tone = data.missing_count > 0 and "warn" or "muted" },
      },
    },
    { kind = "network", nodes = nodes, edges = data.edges },
  }

  if data.truncated or data.truncated_files or data.skipped_large > 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("Large workspace: showing the first %d notes; %d large files were skipped.", MAX_FILES, data.skipped_large),
    }
  end

  blocks[#blocks + 1] = {
    kind = "buttons",
    items = {
      { label = T("Refresh graph"), command = "refresh", style = "primary" },
    },
  }
  return blocks
end

function M.on_load(nota)
  T = function(fmt, ...)
    local translated = nota.i18n and nota.i18n.text(fmt) or nil
    translated = translated or fmt
    if select("#", ...) > 0 then return string.format(translated, ...) end
    return translated
  end

  nota.command.register("open", function()
    dirty = true
    nota.ui.refresh(PANEL_ID)
    nota.ui.show(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("refresh", function()
    dirty = true
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("open_note", function(args)
    local path = args and args.path
    if type(path) ~= "string" or path == "" then
      return { ok = false, error = "missing path" }
    end
    local ok, err = pcall(nota.fs.open, path)
    if not ok then
      nota.ui.notify(T("Could not open %s: %s", path, tostring(err)), "warn")
      return { ok = false, error = tostring(err) }
    end
    nota.ui.review(nil)
    return { ok = true }
  end)

  nota.ui.register_panel({
    id = PANEL_ID,
    title = T("Graph"),
    location = "right",
    wide = true,
    render = function() return graph_blocks(nota) end,
  })

  nota.ui.register_menu({
    label = T("Open knowledge graph"),
    command = "open",
    menu = "plugins",
  })
end

function M.on_unload() end

return M
