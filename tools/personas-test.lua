package.path = "plugins/ai/?.lua;" .. package.path

local personalities = require("personas")
local prompt = require("prompt")
personalities.bind_text(function(s, ...)
  if select("#", ...) == 0 then return s end
  return string.format(s, ...)
end)

local passed = 0
local failed = 0

local function test(name, body)
  local ok, err = pcall(body)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name)
    print("       " .. tostring(err))
  end
end

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
  end
end

local function assert_value(value, label)
  if not value then error(label) end
end

local files = {}
local settings = {}
local nota = {
  data = {
    read = function(name) return files[name] end,
    write = function(name, value) files[name] = value; return true end,
  },
  settings = {
    get = function(key) return settings[key] end,
    set = function(key, value) settings[key] = value end,
  },
  json = {
    decode = function(text)
      local marker = string.match(text, '"marker"%s*:%s*"([^"]+)"')
      if marker then
        return { label = "Imported", prompt = marker }
      end
      return {
        personas = {
          { id = "editor", name = "Editor", system = "Edit carefully." },
          { id = "tutor", name = "Tutor", prompt = "Teach clearly." },
        },
      }
    end,
  },
}

print("(1) JSON persona bundles import, replace and activate")
test("two personas are stored and the first becomes active", function()
  local result, err = personalities.import(nota, { text = '{"personas":[]}' })
  assert_value(result, tostring(err))
  local items = personalities.load(nota)
  equal(#items, 2, "persona count")
  equal(items[1].label, "Editor", "first label")
  equal(items[2].prompt, "Teach clearly.", "second prompt")
  equal(personalities.active(nota).id, "editor", "active persona")
end)

print("(2) Markdown or plain text becomes a single persona")
test("first heading is used as the label", function()
  local result, err = personalities.import(nota, {
    text = "# Court Editor\nUse restrained language.",
  })
  assert_value(result, tostring(err))
  local active = personalities.active(nota)
  equal(active.label, "Court Editor", "heading label")
  equal(active.prompt, "# Court Editor\nUse restrained language.", "full prompt")
end)

print("(3) Persona selection can be cleared and deleted")
test("clear selection and remove only the active persona", function()
  local ok = personalities.set_active(nota, "")
  assert_value(ok, "clear failed")
  local active = personalities.active_id(nota)
  equal(active, "", "cleared active id")
  local target = personalities.load(nota)[1].id
  assert_value(personalities.remove(nota, target), "remove failed")
  local items = personalities.load(nota)
  equal(#items, 2, "remaining persona count")
  for _, item in ipairs(items) do
    assert_value(item.id ~= target, "removed persona is still present")
  end
end)

print("(4) Invalid JSON is rejected")
test("invalid persona object reports an error", function()
  nota.json.decode = function() return nil, "bad json" end
  local result, err = personalities.import(nota, { text = '{"bad":' })
  equal(result, nil, "result")
  assert_value(string.find(tostring(err), "bad json", 1, true), "missing JSON reason: " .. tostring(err))
end)

print("(5) Active persona fields can be edited in place")
test("name and instructions are saved without changing identity", function()
  local target = personalities.load(nota)[1]
  local ok, err = personalities.set_active(nota, target.id)
  assert_value(ok, tostring(err))
  assert_value(personalities.update_label(nota, "Strict editor"), "label update failed")
  assert_value(personalities.update_prompt(nota, "Use concise English."), "prompt update failed")
  local active = personalities.active(nota)
  equal(active.id, target.id, "identity")
  equal(active.label, "Strict editor", "edited label")
  equal(active.prompt, "Use concise English.", "edited prompt")
end)

print("(6) A custom preset can be created without importing a file")
test("first save creates and activates a preset", function()
  files = {}
  settings = {}
  local draft = personalities.editor_state(nota)
  equal(draft.label, "My preset", "draft label")
  equal(draft.prompt, "", "draft prompt")
  local ok, err = personalities.update_prompt(nota, "Be precise.")
  assert_value(ok, tostring(err))
  local active = personalities.active(nota)
  assert_value(active, "created persona is not active")
  equal(active.prompt, "Be precise.", "created prompt")
  equal(personalities.load(nota)[1].id, active.id, "created persona persisted")
end)

print("(7) Settings-page preset overrides imported persona selection")
test("label and multiline prompt are read from extension settings", function()
  settings = {
    persona_label = "Settings preset",
    persona_prompt = "  Use restrained terminology.  ",
  }
  local active = personalities.active(nota)
  equal(active.id, "settings", "settings source")
  equal(active.label, "Settings preset", "settings label")
  equal(active.prompt, "Use restrained terminology.", "settings prompt")

  settings.persona_prompt = "   "
  settings.persona_active = personalities.load(nota)[1].id
  assert_value(personalities.active(nota), "empty settings prompt should fall back")
end)

print("(8) Runtime model identity comes only from the configured model")
test("the mandatory system prompt carries the runtime model id", function()
  local prompt_nota = {
    settings = {
      get = function(key)
        if key == "model" then return "deepseek-flash" end
        return nil
      end,
    },
    document = {
      get_text = function() return "Document body" end,
      get_title = function() return "Document" end,
      get_path = function() return "/tmp/document.md" end,
      get_revision = function() return 1 end,
    },
  }
  local system = prompt.system(prompt_nota)
  assert_value(
    string.find(system, "runtime model id: deepseek-flash", 1, true),
    "runtime model id is missing"
  )
  assert_value(
    string.find(system, "Never infer or disclose a provider or model name", 1, true),
    "provider identity guard is missing"
  )
  equal(string.find(system, "Claude", 1, true), nil, "hardcoded Claude identity")
  equal(string.find(system, "Anthropic", 1, true), nil, "hardcoded Anthropic identity")
end)

print("(9) Settings can select and edit imported personas")
test("selection loads the prompt and switching preserves edits", function()
  files = {}
  settings = {}
  nota.json.decode = function()
    return {
      personas = {
        { id = "editor", name = "Editor", system = "Edit carefully." },
        { id = "tutor", name = "Tutor", prompt = "Teach clearly." },
      },
    }
  end
  assert_value(personalities.import(nota, { text = '{"personas":[]}' }), "import failed")
  local options = personalities.options(nota)
  equal(#options, 4, "built-in, custom and two imported options")
  equal(options[1].value, "", "built-in value")
  equal(options[2].value, "__custom__", "custom value")
  equal(options[3].label, "Editor", "first imported label")
  equal(options[3].editable, true, "imported persona editable")
  equal(options[3].deletable, true, "imported persona deletable")

  assert_value(personalities.select_from_settings(nota, "editor"), "select editor failed")
  equal(settings.persona_prompt, "Edit carefully.", "editor prompt loaded")
  settings.persona_prompt = "Edit with restraint."
  settings.persona_active = "tutor"
  assert_value(personalities.select_from_settings(nota, "tutor"), "select tutor failed")
  equal(settings.persona_prompt, "Teach clearly.", "tutor prompt loaded")
  assert_value(personalities.select_from_settings(nota, "editor"), "reselect editor failed")
  equal(settings.persona_prompt, "Edit with restraint.", "editor edit persisted")
  equal(personalities.active(nota).prompt, "Edit with restraint.", "active edited prompt")

  assert_value(personalities.select_from_settings(nota, "__custom__"), "select custom failed")
  settings.persona_prompt = "Use a neutral custom voice."
  assert_value(personalities.select_from_settings(nota, "tutor"), "switch away from custom failed")
  assert_value(personalities.select_from_settings(nota, "__custom__"), "reselect custom failed")
  equal(settings.persona_prompt, "Use a neutral custom voice.", "custom prompt persisted")

  local created = personalities.create_named(nota, "Reviewer")
  assert_value(created, "new persona failed")
  equal(settings.persona_active, created.id, "new persona selected")
  assert_value(personalities.rename(nota, created.id, "Strict reviewer"), "rename failed")
  equal(personalities.active(nota).label, "Strict reviewer", "renamed persona label")
  assert_value(personalities.remove(nota, created.id), "delete failed")
  equal(personalities.active_id(nota), "", "deleted persona no longer selected")
end)

print(string.format("\nALL PASS (%d assertions)", passed))
if failed > 0 then os.exit(1) end
