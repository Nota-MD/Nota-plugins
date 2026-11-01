local M = {}
local profiles = require("profiles")

local T = function(s) return s end
local PANEL_ID = "vim"
local INDEX_FILE = "imported-profiles.txt"

local function safe_id(id)
  return type(id) == "string"
    and id ~= ""
    and string.match(id, "^[A-Za-z0-9_.-]+$") ~= nil
end

local function built_in_ids()
  return profiles.ids()
end

local function imported_ids(nota)
  local raw = nota.data.read(INDEX_FILE)
  if not raw then
    return {}
  end
  local out = {}
  local seen = {}
  for line in string.gmatch(raw, "[^\r\n]+") do
    if safe_id(line) and not seen[line] then
      seen[line] = true
      out[#out + 1] = line
    end
  end
  return out
end

local function write_imported_ids(nota, ids)
  nota.data.write(INDEX_FILE, table.concat(ids, "\n"))
end

local function imported_profile(nota, id)
  if not safe_id(id) then
    return nil
  end
  local raw = nota.data.read("profile-" .. id .. ".json")
  if not raw then
    return nil
  end
  local value = nota.json.decode(raw)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

local function all_profiles(nota)
  local out = {}
  for _, id in ipairs(built_in_ids()) do
    out[#out + 1] = profiles.load(id)
  end
  for _, id in ipairs(imported_ids(nota)) do
    local profile = imported_profile(nota, id)
    if profile then
      out[#out + 1] = profile
    end
  end
  return out
end

local function enabled(nota)
  return nota.settings.get("enabled") == true
end

local function selected(nota)
  local saved = nota.settings.get("profile")
  local available = all_profiles(nota)
  if saved == nil or saved == "" then
    return "modern-vim"
  end
  for _, profile in ipairs(available) do
    if profile.id == saved then
      return profile.id
    end
  end
  return "modern-vim"
end

local function validate_import(value)
  if type(value) ~= "table" or value.schema ~= 1 then
    error("Profile must be a schema 1 JSON object")
  end
  if not safe_id(value.id) then
    error("Profile id may contain only ASCII letters, digits, dot, dash and underscore")
  end
  for _, built_in in ipairs(built_in_ids()) do
    if value.id == built_in then
      error("A built-in profile cannot be replaced")
    end
  end
  if type(value.label) ~= "string" or value.label == "" then
    error("Profile label is required")
  end
  if type(value.features) ~= "table" or type(value.mappings) ~= "table" then
    error("Profile features and mappings tables are required")
  end
  return value
end

local function panel(nota)
  local options = {}
  for _, profile in ipairs(all_profiles(nota)) do
    options[#options + 1] = {
      label = profile.label,
      value = profile.id,
    }
  end
  return {
    {
      kind = "text",
      tone = "muted",
      text = T("Vim starts in Normal mode. Press i to type; press Escape to return to Normal."),
    },
    {
      kind = "toggle",
      label = T("Vim mode"),
      value = enabled(nota),
      command = "set_enabled",
      arg = "enabled",
    },
    {
      kind = "select",
      label = T("Profile"),
      value = selected(nota),
      options = options,
      command = "select_profile",
      arg = "profile",
    },
    {
      kind = "buttons",
      items = {
        {
          label = T("Edit key mappings…"),
          command = "edit_mappings",
          style = "normal",
          prompt = {
            arg = "mappings",
            label = T("Key mappings"),
            placeholder = "inoremap jj <Esc>",
            hint = T("One mapping per line. map, noremap, nnoremap, inoremap and vnoremap are supported."),
          },
        },
      },
    },
    {
      kind = "file",
      label = T("Profile file"),
      buttonLabel = T("Import…"),
      accept = ".json,application/json",
      command = "import_profile",
      arg = "file",
    },
  }
end

local function emit_profile(nota)
  nota.event.emit("editor-input-profile", {
    kind = "vim",
    enabled = enabled(nota),
    profile = profiles.load(selected(nota)),
    mappingsText = tostring(nota.settings.get("mappings") or ""),
  })
end

function M.on_load(nota)
  T = function(s, ...)
    local value = nota.i18n.text(s) or s
    if select("#", ...) == 0 then
      return value
    end
    return string.format(value, ...)
  end

  nota.command.register("set_enabled", function(args)
    local value = type(args) == "table" and args.enabled == true
    nota.settings.set("enabled", value)
    emit_profile(nota)
    nota.ui.refresh(PANEL_ID)
  end)

  nota.command.register("select_profile", function(args)
    local wanted = type(args) == "table" and args.profile or nil
    for _, profile in ipairs(all_profiles(nota)) do
      if profile.id == wanted then
        nota.settings.set("profile", wanted)
        emit_profile(nota)
        nota.ui.refresh(PANEL_ID)
        return
      end
    end
    error("Unknown Vim profile")
  end)

  nota.command.register("import_profile", function(args)
    local file = type(args) == "table" and args.file or nil
    if type(file) ~= "table" or type(file.text) ~= "string" then
      error("No profile file received")
    end
    local value, why = nota.json.decode(file.text)
    if value == nil then
      error("Invalid JSON: " .. tostring(why))
    end
    value = validate_import(value)

    nota.data.write("profile-" .. value.id .. ".json", file.text)
    local ids = imported_ids(nota)
    local found = false
    for _, id in ipairs(ids) do
      found = found or id == value.id
    end
    if not found then
      ids[#ids + 1] = value.id
      write_imported_ids(nota, ids)
    end
    nota.settings.set("profile", value.id)
    emit_profile(nota)
    nota.ui.refresh(PANEL_ID)
  end)

  nota.command.register("edit_mappings", function(args)
    local mappings = type(args) == "table" and args.mappings or nil
    if type(mappings) ~= "string" then
      error("No key mappings received")
    end
    nota.settings.set("mappings", mappings)
    emit_profile(nota)
    nota.ui.refresh(PANEL_ID)
  end)

  nota.command.register("editor_input_profile", function()
    return {
      kind = "vim",
      enabled = enabled(nota),
      profile = profiles.load(selected(nota)),
      mappingsText = tostring(nota.settings.get("mappings") or ""),
    }
  end)

  nota.ui.register_panel({
    id = PANEL_ID,
    title = T("Vim"),
    render = function()
      return panel(nota)
    end,
  })
  emit_profile(nota)
end

return M
