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

package.path = "plugins/graph/?.lua;" .. package.path
local graph = require("graph")

print("[graph parsing]")
local links = graph.collect_targets([=[
Link to [[Second]] and [[Folder/Third|alias]].
[relative](notes/fourth.md#part)
![image](image.png)
`[[inline-code]]` and [web](https://example.com)
```md
[[fenced]]
```
]=])
equal(#links, 3, "only wikilinks and relative Markdown links are collected")
equal(links[1], "Second", "wikilink target")
equal(links[2], "Folder/Third", "wikilink alias and heading are removed")
equal(links[3], "notes/fourth.md", "relative Markdown path")

local records = {
  { path = "Index.md", title = "Index", text = "[[Second]]\n[Fourth](notes/fourth.md)\n[[Missing]]" },
  { path = "Second.md", title = "Second", text = "[[Index]]" },
  { path = "notes/fourth.md", title = "Fourth", text = "[[Second|back]]" },
}
local built = graph.build(records, "Index.md")
equal(built.note_count, 3, "three existing notes")
equal(built.missing_count, 1, "one unresolved target")
equal(#built.nodes, 4, "three notes and one missing node")
equal(#built.edges, 5, "five directed links")

local index = nil
local fourth = nil
for _, node in ipairs(built.nodes) do
  if node.id == "Index.md" then index = node end
  if node.id == "notes/fourth.md" then fourth = node end
end
check(index and index.focus, "active document receives focus")
equal(index and index.group, "", "root note has no folder group")
equal(fourth and fourth.group, "notes", "nested note uses its first folder as group")

local bidirectional = 0
for _, edge in ipairs(built.edges) do
  if edge.both then bidirectional = bidirectional + 1 end
end
check(bidirectional >= 2, "reciprocal links are marked bidirectional")

local duplicate = graph.build({
  { path = "a/Note.md", title = "A", text = "" },
  { path = "b/Note.md", title = "B", text = "" },
  { path = "Index.md", title = "Index", text = "[[Note]]" },
}, "Index.md")
local linked_to = nil
for _, edge in ipairs(duplicate.edges) do
  if edge.source == "Index.md" then linked_to = edge.target end
end
equal(linked_to, "a/Note.md", "duplicate basenames resolve deterministically to the first sorted path")

print(string.format("\nALL PASS (%d assertions)", pass))
if fail > 0 then
  error(string.format("%d graph assertions failed", fail))
end
