local spacing = require("spacing")

local M = {}
local T = function(s) return s end

local function setting(nota, key)
  if not nota.settings or not nota.settings.get then return nil end
  local ok, value = pcall(nota.settings.get, key)
  return ok and value or nil
end

function M.on_load(nota)
  T = function(fmt, ...)
    local translated = nota.i18n and nota.i18n.text(fmt) or nil
    translated = translated or fmt
    if select("#", ...) > 0 then return string.format(translated, ...) end
    return translated
  end

  nota.command.register("space", function()
    local ok, text = pcall(nota.document.get_text)
    if not ok or type(text) ~= "string" or text == "" then
      nota.ui.notify(T("There is no document to adjust."), "warn")
      return { ok = false }
    end
    local adjusted, changes = spacing.space_document(text, {
      cjk_to_latin = setting(nota, "cjk_to_latin"),
      latin_to_cjk = setting(nota, "latin_to_cjk"),
      include_japanese = setting(nota, "include_japanese"),
      include_numbers = setting(nota, "include_numbers"),
    })
    if adjusted == text then
      nota.ui.notify(T("The CJK spacing already matches the configured values."), "info")
      return { ok = true, changed = 0 }
    end
    local write_ok, err = pcall(nota.document.set_text, adjusted)
    if not write_ok then
      nota.ui.notify(T("Could not update the document: %s", tostring(err)), "warn")
      return { ok = false, error = tostring(err) }
    end
    nota.ui.notify(T("Adjusted %d CJK-Latin boundaries.", changes), "success")
    return { ok = true, changed = changes }
  end)

  nota.ui.register_menu({
    label = T("Add spaces between CJK and Latin"),
    command = "space",
    menu = "plugins",
  })
end

function M.on_unload() end

return M

