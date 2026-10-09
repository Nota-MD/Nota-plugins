-- 插件里**不许出现"没声明就赋值"的名字**（每个 `.lua` 文件单独过一遍）。
--
-- 用法（在仓库根目录）：
--
-- ```sh
-- podman exec -u 1000 -w "$PWD" tauri-dev lua tools/undeclared-globals.lua plugins/git/main.lua
-- ```
--
-- 退出码：0 = 干净；1 = 这个文件里出现了没声明就赋值的名字（并列出是哪几行）。
--
-- # 为什么要它
--
-- 2026-10-09 用户那张截图（`attempt to get length of a nil value (global 'picked')`）：
-- 2026-09-29 拆 `diff.lua` 时，`show_diff` / `show_graph` / `picked` / `compared`
-- 四个模块级 `local` 声明写在同一个块里被整块删掉了。**没声明的名字不是语法错误**
-- ——它只是一次全局赋值，而一个插件一个 Lua 状态，名字撞不到别人，读写全通。
-- 于是这个错**撑了十天**，露头的方式是用户点开提交树时 `#nil` 当场抛错。
--
-- 运行期那一半由 `tools/git-panel-test.lua` 按着（它真跑 `on_load` 与面板渲染）；
-- 这一份管的是**静态那一半**：名字在源码里有没有 `local`。
--
-- # 判据（写清楚它的边界，别当它是个完整的 Lua 分析器）
--
-- 扫 `^%s*名字 =` 这种行（后面不是 `=`，排除 `==`），三层过滤：
--
-- 1. **不在 `{}` 里**。Lua 里 `{` 只可能是表构造器（代码块走 `do…end`），
--    所以深度 > 0 的行是字段、不是语句——`kind = "text"` 那种整片整片的字段
--    就是这么排掉的。
-- 2. 名字在**同一份文件**里被 `local` 过（`local a, 名字` / `local 名字 = …` /
--    `local function 名字`）**或**是某个函数的形参，就算过——**不按作用域**核对。
-- 3. 不是 Lua 的关键字（`for` / `if` / `return` 那几张脸）。
--
-- ⚠️ 所以它是**松的**：一个在别的函数里 `local` 过的名字，在这里被当全局写也不会报。
-- 松是有意的——宁可不报，也不要为了报一次而写一个 Lua 词法分析器。它对
-- 2026-10-09 那种"整个声明块一起没了"的错**够用**（那种情况下全文件都没有那三个 `local`）。
-- ⚠️ 它不查**读**未声明的全局（那要运行期才知道，见上面 `git-panel-test.lua` 那一句）。

local path = arg and arg[1]
if not path or path == "" then
  io.stderr:write("用法：lua tools/undeclared-globals.lua <某个 .lua 文件>\n")
  os.exit(2)
end

local fh = io.open(path, "r")
if not fh then
  io.stderr:write("读不到 " .. path .. "\n")
  os.exit(2)
end

--- Lua 的关键字（`local if = …` 这种写法本身就不合法，但别让它进"已声明"那张表）。
local KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

local declared = {}
local assigns = {} -- { line = 行号, name = 名字 }
local depth = 0    -- 当前在几层 `{}` 里

local function note_declared(snippet)
  for name in snippet:gmatch("([A-Za-z_][A-Za-z0-9_]*)") do
    declared[name] = true
  end
end

--- 把这一行变成"只剩代码"的样子：字符串、注释都抹掉（表字段与赋值都藏在
--- 那两种东西后面，抹掉之后剩下的括号才数得准）。
--- ⚠️ 字符串在这里**不可能跨行**（Lua 只有长字符串能跨，而本仓的插件里没有把
--- `{}` 写进长字符串的写法）——所以按行处理是够的。
local function strip(code)
  return (code:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"):gsub("%-%-.*$", ""))
end

local line_no = 0
for line in fh:lines() do
  line_no = line_no + 1
  local code = strip(line)

  -- 声明：`local function 名字` / `local 名字 [, 名字…] [= …]`，以及形参表。
  local fname = code:match("^%s*local%s+function%s+([A-Za-z_][A-Za-z0-9_]*)")
  if fname then
    note_declared(fname)
  else
    local names = code:match("^%s*local%s+(.-)=") or code:match("^%s*local%s+(.+)$")
    if names then
      note_declared(names)
    end
  end
  for params in code:gmatch("function%s*[%w_.:]*%s*%((.-)%)") do
    note_declared(params)
  end

  -- 赋值：`名字 =`，且后面不是 `=`（那只可能是 `==`）。`名字.字段 =` 与
  -- `名字[键] =` 都不匹配（名字后面紧跟的不是等号）。
  local target, rest = code:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=(.*)$")
  if depth == 0 and target and rest:sub(1, 1) ~= "=" and not KEYWORDS[target] then
    assigns[#assigns + 1] = { line = line_no, name = target }
  end

  for _ in code:gmatch("{") do
    depth = depth + 1
  end
  for _ in code:gmatch("}") do
    depth = depth - 1
  end
end
fh:close()

local bad = {}
for _, a in ipairs(assigns) do
  if not declared[a.name] then
    bad[#bad + 1] = a
  end
end

if #bad == 0 then
  print("ok   " .. path)
  os.exit(0)
end

print("FAIL " .. path .. " —— 这些名字没声明就赋值（成了全局）")
for _, a in ipairs(bad) do
  print(("       第 %d 行：`%s = …`"):format(a.line, a.name))
end
print("       改成 `local " .. bad[1].name .. "` 再赋（模块级状态要写在文件顶上）")
os.exit(1)
