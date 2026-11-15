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
  check(actual == expected, message .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

package.path = "plugins/backlinks/?.lua;" .. package.path
local backlinks = require("backlinks")

print("[backlinks]")
local links = backlinks.collect_links([=[
[[Second]]
[Folder](notes/fourth.md#part)
[Web](https://example.com)
![image](image.png)
`[[inline-code]]`
```md
[[fenced]]
```
]=])
equal(#links, 2, "only wiki and relative Markdown links are collected")
equal(links[1].target, "Second", "wiki target")
equal(links[1].line, 1, "wiki line number")
equal(links[2].target, "notes/fourth.md", "Markdown target without heading")

local records = {
  {
    path = "Index.md",
    title = "Index",
    text = "[[Second]]\n[Fourth](notes/fourth.md)\n[[Missing Note]]",
  },
  {
    path = "Second.md",
    title = "Second",
    text = "# Second\n\n[Home](Index.md)",
  },
  {
    path = "notes/fourth.md",
    title = "Fourth",
    aliases = { "Fourth Alias" },
    text = "[[Index|home]]\n[[Fourth Alias]]",
  },
}
local result = backlinks.analyze(records, "Index.md")
equal(#result.inbound, 2, "both inbound links are found")
equal(result.inbound[1].title, "Second", "inbound notes keep their titles")
equal(result.inbound[2].title, "Fourth", "relative inbound note is resolved")
equal(#result.outbound, 2, "outbound links are resolved")
equal(result.outbound[1].title, "Second", "wiki outbound title")
equal(result.outbound[2].title, "Fourth", "relative outbound title")
equal(#result.unresolved, 1, "one unresolved target is reported")
equal(result.unresolved[1].target, "Missing Note", "unresolved target keeps its name")

local alias_result = backlinks.analyze(records, "notes/fourth.md")
local self_links = 0
for _, item in ipairs(alias_result.outbound) do
  if item.path == "notes/fourth.md" then self_links = self_links + 1 end
end
equal(self_links, 0, "links to the current note are not listed as outbound")
equal(#alias_result.inbound, 1, "outgoing links from the current note become inbound elsewhere")

local title = backlinks.title_of("nested/Note.md", "---\ntitle: From Front Matter\naliases: [Alias One, Alias Two]\n---\n")
equal(title, "From Front Matter", "front matter title is preferred")

print(string.format("\nALL PASS (%d assertions)", pass))
if fail > 0 then error(string.format("%d backlink assertions failed", fail)) end

