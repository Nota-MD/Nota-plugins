local backlinks = require("backlinks")

local M = {}
local T = function(s) return s end

local PANEL_ID = "backlinks"
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

local cache, cache_error, dirty = nil, nil, true

local function path_join(parent, name)
  if parent == "" or parent == "." then return name end
  return parent .. "/" .. name
end

local function walk(nota, directory, depth, records, skipped)
  if depth > MAX_DEPTH or #records >= MAX_FILES then return end
  local ok, entries = pcall(nota.fs.list, directory)
  if not ok or type(entries) ~= "table" then return end
  for _, name in ipairs(entries) do
    if #records >= MAX_FILES then return end
    if name:sub(1, 1) ~= "." and not SKIP_DIRS[name] then
      local rel = path_join(directory, name)
      if backlinks.is_markdown(name) then
        local read_ok, text = pcall(nota.fs.read, rel)
        if read_ok and type(text) == "string" then
          if #text <= MAX_FILE_BYTES then
            records[#records + 1] = {
              path = backlinks.normalize(rel),
              text = text,
              title = backlinks.title_of(rel, text),
              aliases = backlinks.aliases_of(rel, text),
            }
          else
            skipped.large = skipped.large + 1
          end
        end
      else
        walk(nota, rel, depth + 1, records, skipped)
      end
    end
  end
end

local function current_path(nota)
  if not nota.document or not nota.document.get_path then return nil end
  local path = nota.document.get_path()
  if not path or path == "" then return nil end
  local ok, rel = pcall(nota.fs.relative, path)
  if ok and type(rel) == "string" and rel ~= "" then return backlinks.normalize(rel) end
  return nil
end

local function load_data(nota)
  local focus = current_path(nota)
  if not focus then
    cache, cache_error, dirty = nil, T("Save the current Markdown document before reading backlinks."), false
    return nil
  end
  local root_ok = pcall(nota.fs.root)
  if not root_ok then
    cache, cache_error, dirty = nil, T("Open a workspace or save the current document."), false
    return nil
  end
  local records, skipped = {}, { large = 0 }
  walk(nota, ".", 0, records, skipped)
  local result = backlinks.analyze(records, focus)
  result.focus = focus
  result.skipped_large = skipped.large
  result.truncated_files = #records >= MAX_FILES
  cache, cache_error, dirty = result, nil, false
  return result
end

local function data_now(nota)
  if dirty or not cache then return load_data(nota) end
  return cache
end

local function open_buttons(items, limit)
  local buttons = {}
  for index, item in ipairs(items) do
    if index > limit then break end
    local label = string.format("%s · %s:%d", item.title, item.path, item.line)
    buttons[#buttons + 1] = {
      label = label,
      command = "open_note",
      args = { path = item.path },
    }
  end
  return buttons
end

local function panel_blocks(nota)
  local data = data_now(nota)
  if not data then
    return {
      { kind = "hero", title = T("Backlinks"), subtitle = cache_error or "" },
      { kind = "buttons", items = { { label = T("Try again"), command = "refresh", style = "primary" } } },
    }
  end
  local blocks = {
    {
      kind = "fields",
      items = {
        { label = T("Incoming"), value = tostring(#data.inbound), tone = #data.inbound > 0 and "success" or "muted" },
        { label = T("Outgoing"), value = tostring(#data.outbound), tone = "normal" },
        { label = T("Unresolved"), value = tostring(#data.unresolved), tone = #data.unresolved > 0 and "warn" or "muted" },
      },
    },
  }
  if #data.inbound > 0 then
    blocks[#blocks + 1] = { kind = "heading", text = T("Notes linking here") }
    blocks[#blocks + 1] = { kind = "buttons", items = open_buttons(data.inbound, 60) }
  else
    blocks[#blocks + 1] = { kind = "text", tone = "muted", text = T("No note links to this document yet.") }
  end
  if #data.outbound > 0 then
    blocks[#blocks + 1] = { kind = "heading", text = T("Links from this note") }
    blocks[#blocks + 1] = { kind = "buttons", items = open_buttons(data.outbound, 60) }
  end
  if #data.unresolved > 0 then
    blocks[#blocks + 1] = { kind = "heading", text = T("Unresolved links") }
    local names = {}
    for index, item in ipairs(data.unresolved) do
      if index > 60 then break end
      names[#names + 1] = string.format("%s:%d", item.target, item.line)
    end
    blocks[#blocks + 1] = { kind = "text", tone = "warn", text = table.concat(names, " · ") }
  end
  if data.truncated_files or data.skipped_large > 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T(
        "Large workspace: scanned the first %d notes and skipped %d large files.",
        MAX_FILES,
        data.skipped_large
      ),
    }
  end
  blocks[#blocks + 1] = {
    kind = "buttons",
    items = { { label = T("Refresh backlinks"), command = "refresh", style = "primary" } },
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
    nota.ui.show(PANEL_ID)
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("refresh", function()
    dirty = true
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("open_note", function(args)
    local path = args and args.path
    if type(path) ~= "string" or path == "" then return { ok = false } end
    local ok, err = pcall(nota.fs.open, path)
    if not ok then
      nota.ui.notify(T("Could not open %s: %s", path, tostring(err)), "warn")
      return { ok = false, error = tostring(err) }
    end
    return { ok = true }
  end)

  nota.ui.register_panel({
    id = PANEL_ID,
    title = T("Backlinks"),
    location = "right",
    render = function() return panel_blocks(nota) end,
  })

  nota.ui.register_menu({
    label = T("Open backlinks"),
    command = "open",
    menu = "plugins",
  })
end

function M.on_unload() cache, cache_error, dirty = nil, nil, true end

return M

