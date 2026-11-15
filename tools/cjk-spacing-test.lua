local pass = 0
local fail = 0

local function check(condition, message)
  if condition then
    pass = pass + 1
    print("  ok " .. message)
  else
    fail = fail + 1
    print("  FAIL " .. message)
  end
end

local function equal(actual, expected, message)
  check(actual == expected, message .. " (expected [" .. expected .. "], got [" .. actual .. "])")
end

package.path = "plugins/cjk-spacing/?.lua;" .. package.path
local spacing = require("spacing")

print("[CJK spacing]")
equal(spacing.space_line("用Nota写作"), "用 Nota 写作", "spaces Chinese and Latin")
equal(spacing.space_line("用Nota写作", { cjk_to_latin = 0, latin_to_cjk = 0 }), "用Nota写作", "zero removes both directions")
equal(spacing.space_line("用   Nota", { cjk_to_latin = 2 }), "用  Nota", "normalizes CJK-to-Latin spaces")
equal(spacing.space_line("用Nota", { cjk_to_latin = 0, latin_to_cjk = 1 }), "用Nota", "directions are independent")
equal(spacing.space_line("Nota 用写作", { latin_to_cjk = 3 }), "Nota   用写作", "normalizes Latin-to-CJK spaces")
equal(spacing.space_line("共3个，完成50%的"), "共 3 个，完成 50% 的", "spaces digits and percentages")
equal(spacing.space_line("Textusで書く"), "Textus で書く", "spaces Japanese and Latin")
equal(
  spacing.space_line("Textusで書く", { include_japanese = false }),
  "Textusで書く",
  "Japanese kana can be excluded"
)
equal(
  spacing.space_line("第1章 完成50%", { include_numbers = false }),
  "第1章 完成50%",
  "digits and percentages can be excluded"
)
equal(spacing.space_line("用 Nota 写作"), "用 Nota 写作", "keeps existing spaces")
equal(spacing.space_line("한국어English"), "한국어English", "does not treat Korean as CJK")
equal(spacing.space_line("**中文**English"), "**中文**English", "does not cross markup")

equal(spacing.space_line("见`中文A`和$x中Y$"), "见`中文A`和$x中Y$", "keeps inline code and math")
equal(
  spacing.space_line("[链接](https://例子.com/中文A)"),
  "[链接](https://例子.com/中文A)",
  "keeps link text and target"
)
equal(spacing.space_line("[[笔记A]] [^注1]"), "[[笔记A]] [^注1]", "keeps wiki links and footnotes")
equal(
  spacing.space_line("<span title='中文A'>中文B</span>"),
  "<span title='中文A'>中文 B</span>",
  "keeps HTML tags but spaces visible text"
)
equal(
  spacing.space_line("访问https://例子.com/中文A后"),
  "访问https://例子.com/中文A后",
  "keeps bare URLs"
)
equal(
  spacing.space_line("  [ref]: ./文件a.md"),
  "  [ref]: ./文件a.md",
  "keeps indented reference definitions"
)

local document = table.concat({
  "---",
  "title: 中文Title",
  "---",
  "",
  "# 标题A",
  "",
  "用Nota写作",
  "",
  "```js",
  "const 中文A = 1",
  "```",
  "",
  "$$",
  "\\text{中文A}",
  "$$",
  "",
  "    中文A = 1",
  "",
}, "\n")
local expected = table.concat({
  "---",
  "title: 中文Title",
  "---",
  "",
  "# 标题 A",
  "",
  "用 Nota 写作",
  "",
  "```js",
  "const 中文A = 1",
  "```",
  "",
  "$$",
  "\\text{中文A}",
  "$$",
  "",
  "    中文A = 1",
  "",
}, "\n")
equal(spacing.space_document(document), expected, "protects front matter, fences, and block math")

local restored = spacing.space_document(
  "用 Nota 写作，今天 20 分钟。\n",
  { cjk_to_latin = 0, latin_to_cjk = 0 }
)
equal(restored, "用Nota写作，今天20分钟。\n", "zero restores text without inserted spacing")

local commands, menus, written = {}, {}, nil
local settings = {
  cjk_to_latin = 2,
  latin_to_cjk = 3,
  include_japanese = true,
  include_numbers = true,
}
local nota = {
  i18n = { text = function(s) return s end },
  settings = { get = function(key) return settings[key] end },
  document = {
    get_text = function() return written or "用Nota写作" end,
    set_text = function(text) written = text end,
  },
  command = { register = function(name, fn) commands[name] = fn end },
  ui = {
    register_menu = function(spec) menus[#menus + 1] = spec end,
    notify = function() end,
  },
}
local plugin = dofile("plugins/cjk-spacing/main.lua")
plugin.on_load(nota)
check(commands.space ~= nil, "spacing command is registered")
equal(#menus, 1, "spacing menu is registered")
local result = commands.space()
equal(result.changed, 2, "both configured directions are changed")
equal(written, "用  Nota   写作", "plugin applies independent configured spacing")

settings.cjk_to_latin = 0
settings.latin_to_cjk = 0
commands.space()
equal(written, "用Nota写作", "zero settings remove spacing in both directions")

print(string.format("\nALL PASS (%d assertions)", pass))
if fail > 0 then error(string.format("%d CJK spacing assertions failed", fail)) end

