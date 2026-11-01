-- Profile loader used by the future nota.vim plugin.
--
-- Profiles are JSON files. The plugin reads them through
-- `nota.assets.read()` and decodes them through `nota.json.decode()`.
local M = {}

local IDs = {
  "classic-bsd-vi",
  "modern-vim",
}

local function clone(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[clone(key)] = clone(item)
  end
  return out
end

local function merge(base, overlay)
  local out = clone(base)
  for key, value in pairs(overlay) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = merge(out[key], value)
    else
      out[key] = clone(value)
    end
  end
  return out
end

local function decode(path)
  local text = nota.assets.read(path)
  local value, why = nota.json.decode(text)
  if value == nil then
    error("Cannot decode " .. path .. ": " .. tostring(why), 3)
  end
  return value
end

local function loadOne(id, seen)
  if seen[id] then
    error("Vim profile inheritance cycle at " .. id, 2)
  end
  seen[id] = true
  local profile = decode("profiles/" .. id .. ".json")
  if type(profile) ~= "table" or profile.schema ~= 1 then
    error("Vim profile " .. id .. " is not schema 1", 2)
  end
  if profile.extends then
    profile = merge(loadOne(profile.extends, seen), profile)
    profile.extends = nil
  end
  seen[id] = nil
  return profile
end

function M.ids()
  return clone(IDs)
end

function M.load(id)
  if not id or id == "" then
    id = "modern-vim"
  end
  return loadOne(id, {})
end

return M
