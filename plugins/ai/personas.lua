-- Imported persona presets. Persona data is explicit system context, never
-- document content. The active persona is stored as a plugin setting.

local store = require("store")
local util = require("util")

local M = {}
local T = function(s) return s end

function M.bind_text(f)
  T = f
end

local FILE = "personas.txt"
local VERSION = "nota-ai-personas/1"
local ACTIVE = "persona_active"
local EDITING = "persona_editing"
local CUSTOM = "__custom__"
local CUSTOM_PROMPT = "persona_custom_prompt"
local MAX_PERSONAS = 64
local MAX_PROMPT = 50000

local function slug(value, fallback)
  local out = string.lower(tostring(value or "")):gsub("[^a-z0-9_-]+", "-")
  out = out:gsub("^-+", ""):gsub("-+$", "")
  if out == "" then out = fallback end
  return out
end

local function text_of(value)
  return type(value) == "string" and util.trim(value) or ""
end

local function normalise_one(value, index)
  if type(value) ~= "table" then
    return nil
  end
  local label = text_of(value.label) or ""
  if label == "" then label = text_of(value.name) end
  if label == "" then label = text_of(value.title) end
  local prompt = text_of(value.system) or ""
  if prompt == "" then prompt = text_of(value.prompt) end
  if prompt == "" then prompt = text_of(value.persona) end
  if prompt == "" then prompt = text_of(value.instructions) end
  if prompt == "" then prompt = text_of(value.content) end
  if label == "" or prompt == "" then
    return nil
  end
  local id = slug(value.id or label, "persona-" .. tostring(index))
  return {
    id = id,
    label = label,
    prompt = util.cut(prompt, MAX_PROMPT),
  }
end

local function decode_file(nota, file)
  local text = type(file) == "table" and file.text or nil
  if type(text) ~= "string" or util.trim(text) == "" then
    return nil, T("The selected persona file is empty.")
  end
  local first = util.trim(text):sub(1, 1)
  local values = nil
  if first == "{" or first == "[" then
    local decoded, why = nota.json.decode(text)
    if decoded == nil then
      return nil, T("Invalid persona JSON: %s", tostring(why or "unknown error"))
    end
    if type(decoded) == "table" and type(decoded.personas) == "table" then
      values = decoded.personas
    elseif type(decoded) == "table" and decoded[1] ~= nil then
      values = decoded
    else
      values = { decoded }
    end
  else
    local title = string.match(text, "^%s*#%s*([^\r\n]+)") or T("Imported persona")
    values = { { label = title, prompt = text } }
  end
  local output = {}
  for index, value in ipairs(values) do
    local persona = normalise_one(value, index)
    if persona then output[#output + 1] = persona end
  end
  if #output == 0 then
    return nil, T("No valid personas were found in the selected file.")
  end
  return output
end

local function encode(items)
  local lines = { VERSION }
  for _, item in ipairs(items) do
    lines[#lines + 1] = "persona " .. item.id .. " " .. store.enc(item.label)
    lines[#lines + 1] = "prompt " .. store.enc(item.prompt)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function decode(text)
  local items = {}
  local current = nil
  local first = true
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if first then
      if line ~= VERSION then return {} end
      first = false
    elseif line ~= "" then
      local id, label = string.match(line, "^persona ([%w_-]+) (.*)$")
      if id then
        current = { id = id, label = store.dec(label), prompt = "" }
        items[#items + 1] = current
      else
        local prompt = string.match(line, "^prompt (.*)$")
        if prompt and current then current.prompt = store.dec(prompt) end
      end
    end
  end
  return items
end

function M.load(nota)
  if not (nota.data and nota.data.read) then return {} end
  local ok, text = pcall(function() return nota.data.read(FILE) end)
  if not ok or type(text) ~= "string" or text == "" then return {} end
  return decode(text)
end

local function save(nota, items)
  if not (nota.data and nota.data.write) then
    return nil, T("This host build cannot store imported personas.")
  end
  local ok, err = pcall(function() nota.data.write(FILE, encode(items)) end)
  if not ok then return nil, util.clean_error(err) end
  return true
end

function M.active_id(nota)
  return util.read_setting(nota, ACTIVE, "")
end

function M.active(nota)
  local label = util.read_setting(nota, util.KEY_PERSONA_LABEL, "")
  local prompt = util.trim(util.read_setting(nota, util.KEY_PERSONA_PROMPT, ""))
  local wanted = M.active_id(nota)
  if wanted == CUSTOM then
    return {
      id = CUSTOM,
      label = T("Custom persona"),
      prompt = prompt,
    }
  end
  if wanted ~= "" then
    for _, item in ipairs(M.load(nota)) do
      if item.id == wanted then
        local editing = util.read_setting(nota, EDITING, "")
        return {
          id = item.id,
          label = item.label,
          prompt = editing == item.id and prompt or item.prompt,
        }
      end
    end
  end
  if util.trim(prompt) ~= "" then
    return {
      id = "settings",
      label = util.trim(label) ~= "" and util.trim(label) or T("My preset"),
      prompt = prompt,
    }
  end
  return nil
end

--- Always return editable values for the preset form. An empty active id
--- represents a draft that will be created on first save.
function M.editor_state(nota)
  return M.active(nota) or { id = "", label = T("My preset"), prompt = "" }
end

function M.set_active(nota, id)
  local wanted = tostring(id or "")
  local items = M.load(nota)
  local prompt = util.read_setting(nota, util.KEY_PERSONA_PROMPT, "")
  if wanted == "" then
    nota.settings.set(ACTIVE, "")
    nota.settings.set(EDITING, "")
    nota.settings.set(util.KEY_PERSONA_LABEL, "")
    nota.settings.set(util.KEY_PERSONA_PROMPT, "")
    return true
  end
  if wanted == CUSTOM then
    local saved = util.trim(util.read_setting(nota, CUSTOM_PROMPT, ""))
    if saved == "" then saved = util.trim(prompt) end
    nota.settings.set(ACTIVE, CUSTOM)
    nota.settings.set(EDITING, CUSTOM)
    nota.settings.set(util.KEY_PERSONA_LABEL, T("Custom persona"))
    nota.settings.set(util.KEY_PERSONA_PROMPT, saved)
    return true
  end
  for _, item in ipairs(items) do
    if item.id == wanted then
      nota.settings.set(ACTIVE, item.id)
      nota.settings.set(EDITING, item.id)
      nota.settings.set(util.KEY_PERSONA_LABEL, item.label)
      nota.settings.set(util.KEY_PERSONA_PROMPT, item.prompt)
      return true
    end
  end
  return nil, T("Unknown persona: %s", wanted)
end

function M.options(nota)
  local options = {
    { value = "", label = T("Built-in assistant"), editable = false, deletable = false },
    { value = CUSTOM, label = T("Custom persona"), editable = false, deletable = false },
  }
  for _, item in ipairs(M.load(nota)) do
    options[#options + 1] = {
      value = item.id,
      label = item.label,
      editable = true,
      deletable = true,
    }
  end
  return options
end

function M.select_from_settings(nota, value)
  local editing = util.read_setting(nota, EDITING, "")
  if editing == CUSTOM then
    nota.settings.set(CUSTOM_PROMPT, util.read_setting(nota, util.KEY_PERSONA_PROMPT, ""))
  elseif editing ~= "" then
    local prompt = util.read_setting(nota, util.KEY_PERSONA_PROMPT, "")
    local items = M.load(nota)
    for _, item in ipairs(items) do
      if item.id == editing then
        item.prompt = util.cut(prompt, MAX_PROMPT)
        local ok, err = save(nota, items)
        if not ok then return nil, err end
        break
      end
    end
  end
  return M.set_active(nota, value)
end

function M.migrate(nota)
  local prompt = util.read_setting(nota, util.KEY_PERSONA_PROMPT, "")
  if M.active_id(nota) == "" and util.read_setting(nota, EDITING, "") == "" and util.trim(prompt) ~= "" then
    nota.settings.set(ACTIVE, CUSTOM)
    nota.settings.set(EDITING, CUSTOM)
    nota.settings.set(CUSTOM_PROMPT, prompt)
  end
end

function M.import(nota, file)
  local incoming, why = decode_file(nota, file)
  if not incoming then return nil, why end
  local items = M.load(nota)
  local by_id = {}
  for index, item in ipairs(items) do by_id[item.id] = index end
  for _, item in ipairs(incoming) do
    local index = by_id[item.id]
    if index then
      items[index] = item
    elseif #items < MAX_PERSONAS then
      items[#items + 1] = item
      by_id[item.id] = #items
    end
  end
  local ok, err = save(nota, items)
  if not ok then return nil, err end
  local selected, select_error = M.select_from_settings(nota, incoming[1].id)
  if not selected then return nil, select_error end
  return { ok = true, count = #incoming, active = incoming[1].id }
end

function M.remove(nota, id)
  local wanted = tostring(id or "")
  local kept = {}
  for _, item in ipairs(M.load(nota)) do
    if item.id ~= wanted then kept[#kept + 1] = item end
  end
  local ok, err = save(nota, kept)
  if not ok then return nil, err end
  if M.active_id(nota) == wanted then
    nota.settings.set(ACTIVE, "")
    nota.settings.set(EDITING, "")
    nota.settings.set(util.KEY_PERSONA_LABEL, "")
    nota.settings.set(util.KEY_PERSONA_PROMPT, "")
  end
  return true
end

local function unique_id(items, label)
  local base = slug(label, "custom")
  local wanted = base
  local number = 2
  local used = {}
  for _, item in ipairs(items) do used[item.id] = true end
  while used[wanted] do
    wanted = base .. "-" .. tostring(number)
    number = number + 1
  end
  return wanted
end

local function create(nota, items, label, prompt)
  local item = {
    id = unique_id(items, label),
    label = util.trim(label or "") ~= "" and util.trim(label) or T("My preset"),
    prompt = util.trim(prompt or ""),
  }
  items[#items + 1] = item
  local saved, save_error = save(nota, items)
  if not saved then return nil, save_error end
  nota.settings.set(ACTIVE, item.id)
  nota.settings.set(EDITING, item.id)
  nota.settings.set(util.KEY_PERSONA_LABEL, item.label)
  nota.settings.set(util.KEY_PERSONA_PROMPT, item.prompt)
  return item
end

function M.create_named(nota, label)
  local value = util.trim(label or "")
  if value == "" then return nil, T("Persona name cannot be empty") end
  local items = M.load(nota)
  if #items >= MAX_PERSONAS then
    return nil, T("The persona limit has been reached")
  end
  local item, err = create(nota, items, value, "")
  if not item then return nil, err end
  return { ok = true, id = item.id }
end

function M.rename(nota, id, label)
  local wanted = tostring(id or "")
  local value = util.trim(label or "")
  if value == "" then return nil, T("Persona name cannot be empty") end
  local items = M.load(nota)
  for _, item in ipairs(items) do
    if item.id == wanted then
      item.label = value
      local ok, err = save(nota, items)
      if not ok then return nil, err end
      if M.active_id(nota) == wanted then
        nota.settings.set(util.KEY_PERSONA_LABEL, value)
      end
      return true
    end
  end
  return nil, T("Unknown persona: %s", wanted)
end

local function update_active(nota, update)
  local active = M.active(nota)
  local items = M.load(nota)
  if not active then
    local created, err = create(nota, items, T("My preset"), "")
    if not created then return nil, err end
    active = created
  end
  for _, item in ipairs(items) do
    if item.id == active.id then
      local ok, err = update(item)
      if not ok then return nil, err end
      local saved, save_error = save(nota, items)
      if not saved then return nil, save_error end
      return true
    end
  end
  return nil, T("Unknown persona")
end

function M.update_label(nota, label)
  local value = util.trim(label or "")
  if value == "" then return nil, T("Persona name cannot be empty") end
  if not M.active(nota) then
    local items = M.load(nota)
    local created, err = create(nota, items, value, "")
    if not created then return nil, err end
    return true
  end
  return update_active(nota, function(item)
    item.label = value
    return true
  end)
end

function M.update_prompt(nota, prompt)
  local value = util.cut(tostring(prompt or ""), MAX_PROMPT)
  local wanted = M.active_id(nota)
  if wanted == CUSTOM then
    nota.settings.set(EDITING, CUSTOM)
    nota.settings.set(CUSTOM_PROMPT, value)
    nota.settings.set(util.KEY_PERSONA_PROMPT, value)
    return true
  end
  if wanted ~= "" then
    local items = M.load(nota)
    for _, item in ipairs(items) do
      if item.id == wanted then
        item.prompt = value
        nota.settings.set(util.KEY_PERSONA_LABEL, item.label)
        nota.settings.set(EDITING, item.id)
        nota.settings.set(util.KEY_PERSONA_PROMPT, value)
        return save(nota, items)
      end
    end
  end
  if not M.active(nota) then
    local items = M.load(nota)
    local created, err = create(nota, items, T("My preset"), value)
    if not created then return nil, err end
    return true
  end
  nota.settings.set(EDITING, "")
  nota.settings.set(util.KEY_PERSONA_PROMPT, value)
  return true
end

return M
