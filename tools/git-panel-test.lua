-- Git 插件：**面板渲染与选择状态的无头测试**（跑的是 `plugins/git/main.lua` 与
-- `plugins/git/diff.lua` 的真身）。
--
-- 跑法（在仓库根目录，**要用容器里的 lua**）：
--
-- ```sh
-- podman exec -u 1000 -w "$PWD" tauri-dev lua tools/git-panel-test.lua
-- ```
--
-- # 为什么要它
--
-- 2026-10-09 用户甩了一张截图：点开提交树，整个 Git 面板变成一屏报错——
--
-- ```text
-- Lua 出错（拓展 nota.git）：面板 `git` 渲染失败：
--   ...:484: attempt to get length of a nil value (global 'picked')
-- ```
--
-- 根因：2026-09-29 拆 `diff.lua` 时，`show_diff` / `show_graph` / `picked` /
-- `compared` 四个模块级声明写在**同一个块**里被整块删掉了，而该跟着搬走的
-- 只有第一个。剩下三个成了"没声明的全局"——一个插件一个 Lua 状态，
-- 名字撞不到别人，读写全通，于是这个错**撑了十天**。露头的那一下是
-- `picked` 从来没人赋过初值：它是个 `nil`，而 `#nil` 当场抛错。
--
-- 这一份把那天的现场摆出来：桩掉宿主，`on_load` → 开提交树 → 点树 → 选两个
-- → 清空 → 提交 → 编辑区那一份，全走一遍真代码。
--
-- ⚠️ **它抓的东西别处一条都看不见**：`lua/tests.rs` 那两条只做到"编译一遍 /
-- 把 `require` 链求一遍值"，一行都不真跑；`docs/13` §14.1 那张行号表也只是张表。
--
-- ⚠️ 断言里的中文来自 `plugins/git/lang/zh-CN.toml`（桩真读那张表，见下面
-- `read_lang`），所以**改英语原文或改译文必须同批改这里**——与
-- `tools/stats-state-test.lua` 同一条规矩。
--
-- ⚠️ 标识符一律 ASCII（中文标识符是 Lua 的语法错误，`main.lua` 头上记着这个坑）。
-- ⚠️ 路径**按脚本自己的位置算**（`arg[0]`），所以**必须从仓库根目录跑**。

local HERE = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local DIR = HERE .. "/../plugins/git"

-- 真 Lua 的 `require`（沙箱里那个由宿主接管、只在插件目录里找；这里是普通的
-- `require`，所以要自己把插件目录塞进 `package.path`）。
package.path = DIR .. "/?.lua;" .. package.path

-- ── 中文表 ────────────────────────────────────────────────────────────────
--
-- ⚠️ 只认 `"原文" = "译文"` 这一种行（那份表就是这个形状）。
local function read_lang()
  local fh = io.open(DIR .. "/lang/zh-CN.toml", "r")
  if not fh then
    error("读不到 plugins/git/lang/zh-CN.toml")
  end
  local map = {}
  for line in fh:lines() do
    local k, v = line:match('^"(.+)" = "(.+)"$')
    if k then
      map[k] = v
    end
  end
  fh:close()
  return map
end

local LANG = read_lang()

--- 取一句译文；表里没有就**当场报错**（别静默退回原文——那会让"表里缺一条"
--- 变成"断言在测英语"，而那份表正是这里要一起钉住的东西）。
local function zh(key)
  local s = LANG[key]
  if not s then
    error("zh-CN.toml 里没有这条键：" .. key)
  end
  return s
end

local fails, checks = 0, 0
local function eq(actual, want, what)
  checks = checks + 1
  if actual == want then
    print("  ok   " .. what)
  else
    fails = fails + 1
    print("  FAIL " .. what .. "\n         want [" .. tostring(want) .. "]\n         got  [" .. tostring(actual) .. "]")
  end
end

-- ── 桩宿主 ────────────────────────────────────────────────────────────────
--
-- 形状**照 `src-tauri/src/lua/api/git.rs` 抄**：`status` 给 `{code, raw, stderr}`、
-- `run` 给 `{code, stdout, stderr, ok}`、`log_graph` 给 `{ok, rows, stderr}`、
-- `parse_status` 给 `{branch, entries}`、`diff` 给 `{code, text, stderr}`。

local RUNS = {}      -- 跑过的每条 argv（拼成一行），断言"点这一下真去问 git 了吗"
local COMMANDS = {}  -- 注册过的命令
local PANELS = {}    -- 声明过的面板
local MENUS = {}     -- 声明过的菜单项
local NOTIFY = {}    -- 弹过的提示
local REFRESHES = 0  -- `nota.ui.refresh` 的次数
local REVIEWS = {}   -- `nota.ui.review` 的参数（`nil` 记成 "<nil>"）
local EMITS = {}     -- 广播过的事件通道
local LOGS = {}      -- `nota.log.warn` 的字
local STATUSES = 0   -- `nota.git.status` 问了几次

-- 假仓库：三个提交，`c1` 最早。`--is-ancestor` 的判据就是这张表里的次序。
local HISTORY = { "c1", "c2", "c3" }
local function index_of(h)
  for i, x in ipairs(HISTORY) do
    if x == h then
      return i
    end
  end
  return nil
end

local SC = {
  repo = true,      -- 是不是 git 仓库
  identity = true,  -- `git var GIT_AUTHOR_IDENT` 算不算得出来
  branch = "main",
  entries = {},     -- `parse_status` 回的那张清单
}

local function res(code, stdout, stderr)
  return { code = code, stdout = stdout or "", stderr = stderr or "", ok = code == 0 }
end

local function ran(prefix)
  for _, line in ipairs(RUNS) do
    if line:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

local nota = {
  log = { warn = function(m) LOGS[#LOGS + 1] = m end },
  i18n = { text = function(fmt) return LANG[fmt] end },
  event = { emit = function(chan) EMITS[#EMITS + 1] = chan end },
  command = { register = function(id, fn) COMMANDS[id] = fn end },
  ui = {
    register_panel = function(spec) PANELS[spec.id] = spec end,
    register_menu = function(spec) MENUS[#MENUS + 1] = spec end,
    notify = function(msg, tone) NOTIFY[#NOTIFY + 1] = { msg = msg, tone = tone } end,
    refresh = function() REFRESHES = REFRESHES + 1 end,
    review = function(what) REVIEWS[#REVIEWS + 1] = what == nil and "<nil>" or tostring(what) end,
    stream = function() end,
  },
  git = {
    run = function(argv)
      RUNS[#RUNS + 1] = table.concat(argv, " ")
      local c = argv[1]
      if c == "merge-base" then
        -- `merge-base --is-ancestor <前者> <后者>`：退出码 0 = 前者是后者的祖先。
        local a, b = index_of(argv[3]), index_of(argv[4])
        return res((a and b and a <= b) and 0 or 1)
      end
      if c == "var" then
        if SC.identity then
          return res(0, "Nota <you@example.com> 1 +0000\n")
        end
        return res(1, "", "fatal: unable to auto-detect email address")
      end
      if c == "rev-parse" then
        if argv[2] == "--verify" then
          -- "还没提交过" —— 这份桩按"有提交"答（另一支在 (7) 里摆）。
          return res(SC.repo and 0 or 128, "c3\n")
        end
        return res(0, "/tmp/nota-stub\n")
      end
      return res(0, "")
    end,
    status = function()
      STATUSES = STATUSES + 1
      if not SC.repo then
        return { code = 128, raw = "", stderr = "fatal: not a git repository" }
      end
      return { code = 0, raw = "<porcelain -z>", stderr = "" }
    end,
    parse_status = function()
      return { branch = SC.branch, entries = SC.entries }
    end,
    log_graph = function()
      if not SC.repo then
        return { ok = false, code = 128, stderr = "fatal: not a git repository", rows = {} }
      end
      local rows = {
        { art = "*", hash = "c3", parent = "c2", refs = "HEAD -> main", subject = "第三个" },
        { art = "|" },                                   -- 纯连接线行
        { art = "*", hash = "c2", parent = "c1", refs = "", subject = "第二个" },
        { art = "*", hash = "c1", parent = "", refs = "", subject = "第一个" },
      }
      return { ok = true, code = 0, stderr = "", rows = rows }
    end,
    diff = function()
      return { code = 0, text = "", stderr = "" }
    end,
    repo_root = function()
      return "/tmp/nota-stub"
    end,
  },
  -- 差异那一半是**宿主**解的（`nota.diff.parse_unified`，`src-tauri/src/lua/
  -- api/unified_diff.rs`），这里给一份固定的解：一份文件两行。⚠️ 给空表的话
  -- "差异块画出来了没有"这条就永远为假，那一族断言全成了同义反复。
  diff = {
    parse_unified = function()
      return {
        {
          path = "a.md",
          lines = {
            { op = "del", text = "-旧的那一行" },
            { op = "add", text = "+新的那一行" },
          },
        },
      }
    end,
  },
}

-- ── 拉面板 / 拉编辑区那一份 ────────────────────────────────────────────────

local function render(id)
  local spec = PANELS[id]
  if not spec then
    error("没有注册 id = " .. id .. " 的面板")
  end
  return spec.render()
end

local function kinds(blocks)
  local out = {}
  for _, b in ipairs(blocks) do
    out[#out + 1] = b.kind
  end
  return table.concat(out, ",")
end

local function has_kind(blocks, kind)
  for _, b in ipairs(blocks) do
    if b.kind == kind then
      return true
    end
  end
  return false
end

local function has_text(blocks, want)
  for _, b in ipairs(blocks) do
    -- ⚠️ 看的是**所有**带 `text` 的块，不是只有 `kind = "text"` 那一种：
    -- 标题（`heading`）也带 `text`，而这里争辩的好几句正是标题
    --（「差异」「%s → %s 之间」「这里不是 git 仓库」）。
    if b.text == want then
      return true
    end
  end
  return false
end

--- 按钮 / 图线上那颗东西的**标字**（`label`）。面板上那几颗按钮的文案在这儿。
local function has_label(blocks, want)
  for _, b in ipairs(blocks) do
    if b.items then
      for _, item in ipairs(b.items) do
        if item.label == want then
          return true
        end
      end
    end
  end
  return false
end

--- 面板里那块图的每一行字（提交那一栏）。
local function graph_texts(blocks)
  for _, b in ipairs(blocks) do
    if b.kind == "graph" then
      local out = {}
      for _, item in ipairs(b.items) do
        out[#out + 1] = item.text
      end
      return out
    end
  end
  return nil
end

local M = dofile(DIR .. "/main.lua")

-- ── (1) 加载：on_load 那一次刷新是**静默**的 ───────────────────────────────
print("(1) 加载：还没开文件夹时不许弹警告")
SC.repo = false
M.on_load(nota)
eq(#NOTIFY, 0, "on_load 时不是仓库 ⇒ 一声不响（silent）")
eq(#LOGS, 0, "on_load 也没报错")
eq(STATUSES, 1, "on_load 真问过 git 一次")

-- ── (2) ★ 用户 2026-10-09 那张截图：开提交树之后面板照样渲染 ────────────────
print("(2) ★ 开提交树（那张截图的回归测试）")
SC.repo = true
COMMANDS.toggle_graph({})
do
  local ok, blocks = pcall(render, "git")
  eq(ok, true, "★ 面板渲染没抛错（原来这里炸在 `#picked`）")
  eq(has_kind(blocks, "graph"), true, "提交树那一块画出来了")
  local rows = graph_texts(blocks)
  eq(rows ~= nil and #rows, 4, "四行（三个提交 + 一行纯连接线）")
  eq(rows[1], "c3  HEAD -> main · 第三个", "第一行：短哈希 + 分支标签 + 标题")
  eq(has_text(blocks, zh("Selected: %s"):format("c3")), false, "一个都没选 ⇒ 不画「已选」那一行")
end

-- ── (3) 选两个：写出来、方向理正、底下摊开那一对 ───────────────────────────
print("(3) 选两个提交：方向理正（早的在前）")
COMMANDS.pick_commit({ hash = "c3" })
do
  local blocks = render("git")
  eq(has_text(blocks, zh("Selected: %s"):format("c3")), true, "选一个就写出来")
  eq(has_text(blocks, zh("Between %s → %s"):format("c3", "c2")), false,
     "只选了一个 ⇒ 不画「某一对」那一屏（自相矛盾的那一半）")
end

COMMANDS.pick_commit({ hash = "c2" })
do
  local blocks = render("git")
  eq(has_text(blocks, zh("Selected: %s"):format("c3、c2")), true, "「已选」按点击顺序写")
  eq(has_text(blocks, zh("Between %s → %s"):format("c2", "c3")), true,
     "点的是 3、2，画出来的是 c2 → c3（方向理正）")
  eq(has_kind(blocks, "diff"), true, "选了两个 ⇒ 底下摊开那一对")
end

-- ── (4) 取消 / 满了挤掉最早的 ──────────────────────────────────────────────
print("(4) 取消一个 ⇒ 那一对也收掉；满了再点 ⇒ 挤掉最早的")
COMMANDS.pick_commit({ hash = "c3" })
do
  local blocks = render("git")
  eq(has_text(blocks, zh("Selected: %s"):format("c2")), true, "取消 c3 之后只剩 c2")
  eq(has_text(blocks, zh("Between %s → %s"):format("c2", "c3")), false,
     "不成对 ⇒ 底下那一对收掉")
end

COMMANDS.clear_pick({})
COMMANDS.pick_commit({ hash = "c2" })
COMMANDS.pick_commit({ hash = "c3" })
COMMANDS.pick_commit({ hash = "c1" })
do
  local blocks = render("git")
  eq(has_text(blocks, zh("Selected: %s"):format("c3、c1")), true, "满了再点 = 挤掉最早那个")
  eq(has_text(blocks, zh("Between %s → %s"):format("c1", "c3")), true, "留下的两个照样理正方向")
end

-- ── (5) 点树上的键：看这一次提交与它父提交的差异 ───────────────────────────
print("(5) 点左边的键 ⇒ 看「父 → 它」；编辑区那一份摊的是同一对")
COMMANDS.clear_pick({})
COMMANDS.bond_diff({ hash = "c2", parent = "c1" })
do
  local blocks = render("git")
  eq(has_text(blocks, zh("Between %s → %s"):format("c1", "c2")), true, "右栏摊的是 c1 → c2")
  eq(has_kind(blocks, "buttons"), true, "那一屏带「清空选择」那颗按钮")
  local ok, review = pcall(render, "review")
  eq(ok, true, "编辑区那一份渲染得出来")
  eq(has_text(review, zh("Between %s → %s"):format("c1", "c2")), true, "编辑区摊的**就是**同一对")
end

-- ── (6) 清空选择 ⇒ 编辑区回到工作区那份 ────────────────────────────────────
print("(6) 清空选择 ⇒ 编辑区回到「工作区 vs 最后一次提交」")
COMMANDS.clear_pick({})
do
  local review = render("review")
  eq(has_text(review, zh("Diff")), true, "标题回到「差异」")
  eq(has_text(review, zh("(red = removed, green = added, blue = where, grey = file info)")), true,
     "颜色说明那句也画着")
end

-- ── (7) 根提交的键 ⇒ `git show`（跟空树比） ────────────────────────────────
print("(7) 根提交没有父 ⇒ 走 git show")
RUNS = {}
COMMANDS.bond_diff({ hash = "c1", parent = "" })
do
  local blocks = render("git")
  eq(has_text(blocks, zh("The first commit %s (everything counts as newly added)"):format("c1")), true,
     "那一屏说的是「第一次提交（全部都算新加的）」")
  eq(ran("show --no-color -U3 --format= c1"), true, "真跑了 git show（`--format=` 是空格式）")
end

-- ── (8) 提交：身份那道闸在 add 之后 ────────────────────────────────────────
print("(8) 提交两半：正常提交 / 身份没配就不跑那条注定失败的 commit")
COMMANDS.clear_pick({})
RUNS, REVIEWS = {}, {}
do
  local r = COMMANDS.commit({ message = "改一下" })
  eq(r.ok, true, "提交成功")
  eq(ran("add -A"), true, "先 add -A")
  eq(ran("commit -m 改一下"), true, "再 commit -m")
  eq(REVIEWS[#REVIEWS], "<nil>", "提交完把编辑区那一份收掉（nota.ui.review(nil)）")
end

do
  SC.identity = false
  RUNS, NOTIFY = {}, {}
  local r = COMMANDS.commit({ message = "改一下" })
  eq(r.ok, false, "身份没配 ⇒ 不提交")
  eq(ran("commit -m"), false, "★ 那条注定失败的 commit 一次都不跑")
  eq(ran("add -A"), true, "但 add 已经跑过了（判据：身份那道闸在 add 之后）")
  -- ⚠️ `M.commit` 只**返回** `{ok = false, error = …}`；弹提示是命令那一层
  -- （`nota.command.register("commit", …)`）干的——两件事别混。
  eq(#NOTIFY, 1, "命令那一层说了一句")
  eq(NOTIFY[1].tone, "error", "语气是错误")
  eq(NOTIFY[1].msg, zh("Set the Git identity (name and email) first — git will not commit without it."),
     "说的就是「先填身份」那句（译文）")
  SC.identity = true
end

do
  local r = COMMANDS.commit({ message = "" })
  eq(r.ok, false, "空提交信息 ⇒ 直接拒绝")
  eq(r.error, zh("The commit message cannot be empty"), "那句拒绝是译文")
end

-- ── (9) 不是仓库：面板给一条出路，主动刷新时才说一声 ───────────────────────
print("(9) 不是仓库那一屏")
SC.repo = false
NOTIFY = {}
do
  local blocks = render("git")
  eq(has_text(blocks, zh("This is not a git repository")), true, "画「这里不是 git 仓库」")
  eq(has_kind(blocks, "buttons"), true, "那一屏里有出路（初始化仓库 / 再试一次）")
end

COMMANDS.refresh({})
eq(#NOTIFY, 1, "用户主动点刷新 ⇒ 说一声")
eq(NOTIFY[1].tone, "warn", "语气是警示")

do
  local review = render("review")
  eq(has_text(review, zh("This is not a git repository")), true, "编辑区那一屏共用同一份")
end
SC.repo = true

-- ── (10) 差异那个开关：只改显示，两处一起变 ────────────────────────────────
print("(10) 收起 / 展开差异：只改显示，不碰 git")
COMMANDS.clear_pick({})
do
  eq(has_kind(render("git"), "diff"), true, "默认面板里画着差异")
  eq(has_label(render("git"), zh("Hide diff")), true, "按钮写着「收起差异」")
  COMMANDS.toggle_diff({})
  eq(has_kind(render("git"), "diff"), false, "收起之后面板里不画了")
  eq(has_label(render("git"), zh("Show diff")), true, "那颗按钮改成「看差异」")
  -- ⚠️ **编辑区那一份不受这个开关管**：它是用户按「在编辑区看」摊开的，
  -- 摊着就该一直摊着（`review_blocks` 里没有 `diff.show()` 那一条，这是有意的）。
  eq(has_kind(render("review"), "diff"), true, "编辑区那一份照旧画着")
  COMMANDS.toggle_diff({})
  eq(has_kind(render("git"), "diff"), true, "再点一次又画回来")
end

-- ── (11) 广播：改动清单发给别的插件，界面那一句是另一条 ────────────────────
print("(11) 刷新会广播 `git:status`，并让界面重拉")
EMITS, REFRESHES = {}, 0
SC.entries = { { state = "modified", path = "a.md" } }
COMMANDS.refresh({})
eq(EMITS[#EMITS], "git:status", "广播的通道名")
eq(REFRESHES > 0, true, "也让界面重拉了一次")
do
  local blocks = render("git")
  eq(blocks[1].kind, "heading", "第一块是分支名")
  eq(blocks[1].text, "main", "分支名就是 git 报的那个")
  eq(blocks[2].kind, "list", "第二块是改动清单")
  eq(blocks[2].items[1].title, "a.md", "清单里那一条的路径写在 `title` 上")
  eq(blocks[2].items[1].badge, zh("modified"), "那一条的状态是译文")
  eq(blocks[2].items[1].tone, "warn", "语气跟着状态走（已修改 = 警示色）")
  eq(blocks[2].items[1].subtitle, "", "不是重命名 ⇒ 副标题是空串（不是 nil）")
end

-- ── 汇总 ──────────────────────────────────────────────────────────────────
print("")
if fails == 0 then
  print(("ALL PASS（%d 条断言）"):format(checks))
  os.exit(0)
end
print(("%d 条 FAIL（共 %d 条断言）"):format(fails, checks))
os.exit(1)
