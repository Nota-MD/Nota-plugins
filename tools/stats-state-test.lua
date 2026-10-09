-- 写作统计（原名「写作心电图」）：**无头状态机测试**（跑的是 `plugins/stats/main.lua`）。
--
-- 跑法（在仓库根目录，**要用容器里的 lua**）：
--
-- ```sh
-- podman exec -u 1000 -w "$PWD" tauri-dev lua tools/stats-state-test.lua
-- ```
--
-- 为什么要它：这一批的行为全在"时间怎么走"上（采样、断档、暂停、结算、冻结），
-- 而**开窗点按钮只能看到某一瞬间的画面**——`GAP_MS`（15 秒）与 `MIN_SPAN_MS`
-- （10 秒）那两条分支靠手点几乎摆不出来。这里桩掉 `nota`，时钟由测试自己推，
-- 每条分支都能精确摆到，而且几毫秒跑完。
--
-- ⚠️ **它抓过一个真 bug**：大数字在暂停时本该冻住，第一版却在暂停期间继续往下
-- 掉（69 → 53）——开窗那一帧看着"正常"，只有把两条时间线摆开才看得出来。
-- 第 (10) 段就是它的回归测试。
--
-- ⚠️ 断言里写的是**中文**，它来自 `plugins/stats/lang/zh-CN.toml`（桩真读那张表，
-- 见下面 `read_lang`）。所以**改文案必须同批改这里**：改了 `main.lua` 里的英语原文
-- 或改了译文，这一份都会红。
--
-- ⚠️⚠️ **标识符一律 ASCII**：中文标识符是 Lua 的语法错误（`main.lua` 头上记着
-- 同一个坑），这份文件第一版就栽在上面。
--
-- ⚠️ 路径**按脚本自己的位置算**（`arg[0]`），不写死仓库绝对路径：谁 clone 到
-- 哪儿都能跑。所以**必须从仓库根目录跑**（上面那条命令就是）。
--
-- ⚠️ 桩里那个 `time` / `data` 得是 `pcall` 收得住的形状：插件那两处都包了
-- `pcall`（"拿不到就别说"，与 `document.stats()` 同规矩）。
--
-- # 两份实例，两条路
--
-- 2026-09-27 加了"今日那本账"（`nota.time` ＋ `nota.data`）之后，插件有了**两条
-- 分支**，而这两条都得测：
--
-- * **第一份实例**（(1)~(11)）：桩里**没有** `time` / `data` —— 就是"拿不到时间
--   来源"那条路。整套"今日"都不该出现（面板上没有那一行、也没有那颗按钮），
--   而本轮照记不误。
-- * **第二份实例**（(12)~）：桩里**有** `time`（假的墙上时间，起点 2026-09-27
--   22:00）与 `data`（假磁盘）。这里测两本账同口径、跨天翻页、两个分享图上的
--   刻度、以及落盘/读回/只留最近七天。
-- * **第三份实例**（(23)）：只讲一件事——刚「继续」那一下的大数该是什么。它单独开一份
--   是因为那一条要**静置 90 秒**才摆得出来，插进前两份的时间线里会把它们的断言全推歪。
-- * **第四份实例**（(24)）：Δt 窗口那一格（2026-10-04 加，用户要的"按某个
--   德尔塔 t 内的打字量算，t 在设置页上拖"）。它要的桩是 `opts.settings`——
--   前面几份**都没有**那一号对象，那正好是 (24d) 那条"读不到就按默认 5 秒"。

local HERE = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local MAIN = HERE .. "/../plugins/stats/main.lua"

-- ⚠️⚠️ **中文表要从 `lang/zh-CN.toml` 真读进来**（2026-10-04 修，见文件头那条）。
-- 桩里那句 `i18n.text` 以前一律返回 `nil`，于是 `T()` 全都退回**英语原文**——而
-- 下面这些断言写的是中文。2026-09-28 插件翻成"代码里写英语、中文进 lang 表"之后，
-- 这份测试就**整份静默地烂掉了**（67 条 FAIL，一直没人发现：它不在那四道闸里）。
--
-- 现在桩**真读那张表**：断言里的中文同时是两件事的证据——"这句原文在表里"和
-- "译文就是这句"。表里缺哪一条，这里当场红。
--
-- ⚠️ 只认 `"原文" = "译文"` 这一种行（那份表就是这一个形状）。⚠️ 键值里那些引号
-- 都是**中文的** `“「`，没有一个 ASCII 的 `"`，所以下面那个贪心匹配不会切歪。
local function read_lang()
  local fh = io.open(HERE .. "/../plugins/stats/lang/zh-CN.toml", "r")
  if not fh then
    error("读不到 plugins/stats/lang/zh-CN.toml")
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

-- ⚠️ `main.lua` 2026-09-27 起会 `require("ticks")`（插件多文件）。在**沙箱里**那个 require
-- 由宿主接管、只在插件自己那个目录里找（`lua/mod.rs` 的 `装require`）；这里是**真的 Lua
-- `require`**，所以得自己把那个目录塞进 `package.path`（默认那条 `./?.lua` 是相对**当前
-- 工作目录**的，从仓库根跑就找不到 `plugins/stats/ticks.lua`）。
package.path = HERE .. "/../plugins/stats/?.lua;" .. package.path

local fails = 0
-- ⚠️ 顺带数一下**真的跑过了几条**：`docs/06` §5.29b 一直写着"24 组 / N 条"，
-- 而那个 N 以前是**人数的**（数法各不相同，改一次就得靠猜）。从 2026-10-07 起由
-- 这里自己报——照着最后那行抄，不会再有第二种数法。
local checks = 0
local function eq(actual, want, what)
  checks = checks + 1
  if actual == want then
    print("  ok   " .. what .. " = " .. tostring(actual))
  else
    fails = fails + 1
    print("  FAIL " .. what .. ": want [" .. tostring(want) .. "] got [" .. tostring(actual) .. "]")
  end
end

-- 假的墙上时间：起点 2026-09-27 22:00，`ms` 是插件那个**单调**时钟的读数。
-- ⚠️ 只在 9 月里推（这份测试用不到月末）。
local function wall(ms)
  local total = 22 * 60 + math.floor(ms / 60000)
  local day, mi = math.floor(total / 1440), total % 1440
  return {
    now_ms = ms,
    ymd = string.format("2026-09-%02d", 27 + day),
    y = 2026,
    mo = 9,
    d = 27 + day,
    hh = math.floor(mi / 60),
    mi = mi % 60,
  }
end

-- 一个桩。`opts.time` / `opts.data` 为假时**不给**那两个 API：那正是第一份实例
-- 要走的"拿不到时间来源"那条路。`opts.store` 可以塞一份预先写好的"磁盘"进去。
local function make_nota(opts)
  local box = { cmds = {}, store = opts.store or {}, writes = 0, now = 0, words = 100, path = "A" }
  local n = {
    i18n = { text = function(s) return LANG[s] end },
    ui = {
      register_panel = function(spec)
        box.panel, box.id = spec, spec.id
        return spec.id
      end,
      refresh = function() end,
      notify = function() end,
    },
    command = { register = function(name, fn) box.cmds[name] = fn end },
    document = {
      stats = function()
        return { words = box.words, lines = 1, clock_ms = box.now, path = box.path }
      end,
    },
  }
  if opts.time then
    n.time = { now = function() return wall(box.now) end }
  end
  -- ⚠️ 设置的桩（2026-10-04 加）：`opts.settings` 就是「设置 → 拓展」那一页上
  -- 那根滑杆背后的值。**不给这一号对象**（`opts.settings` 为假）也是一条要测的路
  -- ——插件得退回默认 5 秒（见 (24d)）。⚠️ 表由调用方拿着，改它就是"用户拖了一下"。
  if opts.settings then
    n.settings = { get = function(k) return opts.settings[k] end }
  end
  if opts.data then
    n.data = {
      read = function(name) return box.store[name] end,
      write = function(name, text)
        box.store[name] = text
        box.writes = box.writes + 1
        return true
      end,
      remove = function(name) box.store[name] = nil; return true end,
      dir = function() return "/tmp/nota-stats-test" end,
    }
  end
  return n, box
end

local function load(opts)
  local n, box = make_nota(opts)
  -- ⚠️ 清掉那几个**模块级缓存**：沙箱里**每加载一份插件就是一份新的 Lua**（`lua/mod.rs`
  -- 里一次 `硬化的_lua()`），模块缓存本来就不跨实例。不清的话第二份实例拿到的是第一份
  -- 那个已经绑好译文的 `ticks` / `long` / `cards`（三个都有 `T`），"两份实例互相串味"这类问题就
  -- 测不出来了。⚠️ `ledger` 没有 `T`，但它跟另外几个一样是"每份插件一份"，一起清掉省得
  -- 以后往它里面加状态时忘了这一行。⚠️ `cards`（2026-10-04 加）也是——它自己那份 `T`
  -- 的桩不清的话，第二份实例的 ②④ 两块会拿第一份的取用器画画。⚠️ `share`（同一天
  -- 第二批拆出来的）同理：③ 那几颗按钮与三张分享卡都在它里面。
  package.loaded.ticks = nil
  package.loaded.long = nil
  package.loaded.ledger = nil
  package.loaded.cards = nil
  package.loaded.share = nil
  local mod = dofile(MAIN)
  mod.on_load(n)
  return mod, box
end

-- 推时钟 / 改字数 / 换文档，然后拉一次面板（就是宿主那一拍做的事）
local function step(box, t, c, p)
  box.now, box.words = t, c
  if p then box.path = p end
  return box.panel.render()
end

local function blk(blocks, kind)
  for _, b in ipairs(blocks) do
    if b.kind == kind then return b end
  end
end

local function fields(blocks)
  local b, out = blk(blocks, "fields"), {}
  if b then
    for _, it in ipairs(b.items) do out[it.label] = it.value end
  end
  return out
end

--- 面板上**每一组**按钮。
-- ⚠️ 2026-10-04 起面板上有**两处**按钮：③ 控制这一轮那颗开关（＋「终止」）、
-- ④ 记录卡底下那三颗做分享图的。组内用 `+` 连、组间用 ` | ` 隔。
-- ⚠️ **不能只取第一组**：那样"④ 那三颗该出现的时候出现了没有"就测不到，
-- 而它们恰恰是"有东西可分享吗"（`needs`）那条判据唯一的观测点。
local function buttons(blocks)
  local groups = {}
  for _, b in ipairs(blocks) do
    if b.kind == "buttons" then
      local one = {}
      for _, it in ipairs(b.items) do table.insert(one, it.label) end
      table.insert(groups, table.concat(one, "+"))
    end
  end
  return table.concat(groups, " | ")
end

--- 那一块记录卡列表（`kind = "cards"`，2026-10-04 加）。没有就给 `nil`。
local function cards(blocks)
  return blk(blocks, "cards")
end

--- 记录卡列表里**某一条**。按图标认：`round`（本轮）/ `today`（今天）/ `long`（长期）。
local function card(blocks, icon)
  local b = blk(blocks, "cards")
  if not b then return nil end
  for _, it in ipairs(b.items) do
    if it.icon == icon then return it end
  end
end

--- 某一条记录卡写成一行字：`20 字（今天 · 1 轮）`。没有那一条就给 `(no today card)`。
-- ⚠️ 把大字、单位、小字**一起**比：这三样是这一块的全部信息，拆开比会漏掉
-- "字数对但小字写错了"那种。
local function record(blocks, icon)
  local c = card(blocks, icon)
  if not c then return "(no " .. icon .. " card)" end
  return c.value .. " " .. c.unit .. "（" .. c.caption .. "）"
end

--- 底下那行汇总（`整篇文档 140 字` → `"140 字"`）。没有那行就给 `(no total)`。
local function total(blocks)
  local b = blk(blocks, "cards")
  if not b or not b.total then return "(no total)" end
  return b.total.value .. " " .. b.total.unit
end

--- 本轮那条记录卡上那个大字（原来那块独立曲线的 `bignum`，2026-10-04 折进卡里）。
--- ⚠️ 空串在渲染层画破折号，这里跟着标成 `-`（同那条规矩）。
local function bignum(blocks)
  local c = card(blocks, "round")
  if not c then return "(no round card)" end
  if c.value == "" then return "-" end
  return c.value
end

--- 本轮那条卡上曲线有几个点。
local function npoints(blocks)
  local c = card(blocks, "round")
  if not c then return -1 end
  return #c.points
end

local function hasText(blocks, want)
  for _, b in ipairs(blocks) do
    if b.kind == "text" and b.text == want then return true end
  end
  return false
end

-- 一块图上的刻度写成 "位置=标签|位置=标签"（位置留三位小数），方便一眼比对。
local function ticks(blocks, kind)
  local b = blk(blocks, kind or "chart")
  if not b or not b.x_ticks then return "(no ticks)" end
  local out = {}
  for _, t in ipairs(b.x_ticks) do
    table.insert(out, string.format("%.3f=%s", t.at, t.label))
  end
  return table.concat(out, "|")
end

-- 数一数账本里有几天（`d ` 行的条数）。
-- ⚠️ 不认日期长什么样：(19) 后半段那 405 天用的是**假日期**（`1000-0001` 这种），
--    它们只要够多、够排得开就行——那一段考的是"排序后丢最老的"，日期真不真无关。
local function day_lines(text)
  local n = 0
  for _ in text:gmatch("d %S+ ") do n = n + 1 end
  return n
end

-- `n` → `YYYY-MM-DD`（Howard Hinnant 的 `civil_from_days`，与 `tk.day_number` 互逆）。
-- ⚠️ 测试这一份**故意自己写一遍**：拿 `tk.day_number` 反推的话，那个函数里错一个符号
--    会两边一起错、什么也测不出来。下面 (21) 里那几个硬写死的数字来自另一套实现
--    （Python 的 `datetime.date`），两边对得上才算真的对。
local function civil_text(n)
  local z = n + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  return string.format("%04d-%02d-%02d", y, m, d)
end

-- ============ 第一份实例：桩里没有 time / data ==========================

local _, box1 = load({})
local panel, cmds = box1.panel, box1.cmds

print("-- (1) idle --")
assert(panel ~= nil, "panel not registered")
-- ⚠️ 面板 id 是 `stats`：2026-09-27 跟着插件改名一起从 `heartbeat` 换掉了
--    （当时还没有用户，所以没写一次性搬家，见 `plugins/stats/plugin.toml` 头上那段）。
assert(box1.id == "stats", "panel id")
assert(panel.live == true, "live is not true")
local s = step(box1, 0, 100)
eq(buttons(s), "开始记录", "buttons (no time source -> nothing to share either)")
eq(total(s), "100 字", "the summary row carries the whole document")
-- ⚠️ **2026-10-07 起 idle 那一屏也画本轮卡**（用户原话「默认手表界面哦」）：
-- 面板打开就该是运动手表那块表盘——大数字写 0、曲线是空的、小字写"本轮 · 0 字 · 0 秒"。
-- 所以这里从 `(no round card)` 改成"有一条、而且是全 0 的那一条"。
eq(#cards(s).items, 1, "the idle screen carries the round card (and only it, without a time source)")
eq(
  record(s, "round"),
  "0 字 / 分钟（本轮 · 0 字 · 0 秒）",
  "the idle round card reads zero, not a dash"
)
eq(bignum(s), "0", "bignum on the idle screen is 0 (a dash is for 'running but no sample yet')")

print("-- (2) start -> sampling --")
cmds.start()
s = step(box1, 2000, 100)
eq(buttons(s), "暂停+终止", "buttons")
eq(fields(s)["本轮写了"], "0 字", "written right after start")
s = step(box1, 4000, 110)
s = step(box1, 6000, 125)
s = step(box1, 8000, 140)
eq(fields(s)["本轮写了"], "40 字", "written")
eq(fields(s)["记录时长"], "6 秒", "elapsed")
eq(total(s), "140 字", "whole doc (the summary row under the records)")
eq(npoints(s), 3, "plot points")

print("-- (3) switch document -> auto pause --")
s = step(box1, 10000, 5, "B")
eq(buttons(s), "继续+终止", "buttons")
eq(fields(s)["本轮写了"], "40 字", "written (unchanged)")
eq(fields(s)["记录时长"], "6 秒", "elapsed (unchanged)")
eq(hasText(s, "已暂停。这期间打的字不算进这一轮——按「继续」接着算。"), true, "pause notice")

print("-- (4) typing while paused does not count --")
s = step(box1, 14000, 60, "B")
eq(fields(s)["本轮写了"], "40 字", "written (55 words typed while paused)")
eq(fields(s)["记录时长"], "6 秒", "elapsed")

print("-- (5) resume --")
cmds.resume()
s = step(box1, 16000, 60, "B")
s = step(box1, 18000, 70, "B")
eq(buttons(s), "暂停+终止", "buttons")
eq(fields(s)["本轮写了"], "50 字", "written (only the 10 after resume)")
eq(fields(s)["记录时长"], "8 秒", "elapsed")
eq(npoints(s), 4, "plot points")

print("-- (6) gap -> accumulate but no point, no peak --")
-- The gap deliberately carries a HUGE delta (+1000): "accumulate only" and
-- "also plot it" differ only in the peak, so a small delta would not test it.
s = step(box1, 60000, 1070, "B")
eq(fields(s)["本轮写了"], "1050 字", "written (gap counted)")
eq(fields(s)["记录时长"], "50 秒", "elapsed (gap counted)")
eq(npoints(s), 4, "plot points (this tick left no point)")
eq(fields(s)["峰值速度"], "450 字/分钟", "peak (would be 1428 if the gap were plotted)")

print("-- (7) stop -> summary --")
cmds.stop()
s = step(box1, 62000, 1070, "B")
eq(buttons(s), "再来一轮 | 制作本轮分享图", "buttons (round card offered, day card not)")
eq(bignum(s), "1260", "the round card's big number = round average (1050 words / 50 s)")
eq(card(s, "round").unit, "字 / 分钟", "…and its unit")
eq(card(s, "round").caption, "本轮 · 1,050 字 · 50 秒", "small print: the round's own tally")
eq(total(s), "1,070 字", "the summary row (with the thousands separator)")

print("-- (8) done accumulates nothing (and doc switch does not pause) --")
s = step(box1, 120000, 9999, "B")
eq(fields(s)["本轮写了"], "1050 字", "written (frozen)")
eq(fields(s)["记录时长"], "50 秒", "elapsed (frozen)")
s = step(box1, 200000, 9999, "C")
eq(buttons(s), "再来一轮 | 制作本轮分享图", "buttons (done + doc switch is not a pause)")

print("-- (9) start another round -> reset --")
cmds.start()
s = step(box1, 202000, 9999, "C")
eq(fields(s)["本轮写了"], "0 字", "written")
eq(fields(s)["记录时长"], "0 秒", "elapsed")
eq(bignum(s), "-", "bignum (not enough samples yet)")

print("-- (10) bignum freezes while paused (regression: it used to keep sliding) --")
-- NOTE: start from 9999, the length step (9) left behind. Starting from a smaller
-- number makes the first tick look like a deletion (clamped to 0) and the count
-- comes out one sample short.
local t, c = 202000, 9999
for _ = 1, 8 do
  t, c = t + 2000, c + 20
  s = step(box1, t, c, "C")
end
eq(bignum(s), "600", "live reading (20 words every 2 s)")
cmds.pause()
s = step(box1, t + 2000, c, "C")
eq(bignum(s), "600", "right after pause")
s = step(box1, t + 22000, c, "C")
eq(bignum(s), "600", "still 600 twenty seconds later")

print("-- (11) still does not count while paused; resume counts only new --")
s = step(box1, t + 40000, c + 100, "C")
eq(fields(s)["本轮写了"], "160 字", "written (the 100 typed while paused do not count)")
cmds.resume()
s = step(box1, t + 42000, c + 100, "C")
s = step(box1, t + 44000, c + 130, "C")
eq(fields(s)["本轮写了"], "190 字", "written (the 30 after resume count)")

-- ============ 第二份实例：有 time ＋ data（今日那本账、分享图、刻度）======

local _, box2 = load({ time = true, data = true })
local cmds2 = box2.cmds

print("-- (12) 今日那本账：同一支代码、同一口径 --")
s = step(box2, 0, 100)
eq(card(s, "today"), nil, "0 字的今天不占地方（那条记录已经建好了）")
cmds2.start()
eq(box2.writes, 1, "start flushes once (rounds +1)")
s = step(box2, 10000, 110) -- ⚠️ 这一枪只是重新立基线（「开始」把基线清了），+10 不算
s = step(box2, 20000, 130) -- +20，同一分钟（22:00）
eq(record(s, "today"), "20 字（今天 · 1 轮）", "today's record card")
eq(fields(s)["本轮写了"], "20 字", "round total is the same number")
eq(box2.writes, 1, "plain ticks do not write to disk")
s = step(box2, 440000, 190) -- 断档 7 分钟：+60 只累加
eq(record(s, "today"), "80 字（今天 · 1 轮）", "gap still counts into today")
s = step(box2, 450000, 200) -- +10，22:07
s = step(box2, 460000, 210) -- +10，22:07
eq(record(s, "today"), "100 字（今天 · 1 轮）", "today total")
eq(fields(s)["本轮写了"], "100 字", "round total (same accrual)")

print("-- (13) 暂停期间今日那本账也不动 --")
cmds2.pause()
s = step(box2, 470000, 310) -- 暂停里打 100 字
eq(record(s, "today"), "100 字（今天 · 1 轮）", "today unchanged while paused")
cmds2.resume()
cmds2.stop()

print("-- (14) 落盘：days.txt 的格式与内容 --")
local f = box2.store["days.txt"]
eq(type(f) == "string", true, "days.txt written")
eq(f:match("^v1\n") ~= nil, true, "first line is the version")
eq(f:match("d 2026%-09%-27 100 450000 120 1\n") ~= nil, true, "d line: ymd words ms peak rounds")
eq(f:match("m 2026%-09%-27 1320 20\n") ~= nil, true, "m line: 22:00 -> 20 words")
eq(f:match("m 2026%-09%-27 1327 20\n") ~= nil, true, "m line: 22:07 -> 20 words")

print("-- (15) 本轮分享图：字段、点数、刻度 --")
cmds2.share_round()
s = step(box2, 460000, 210)
local sh = blk(s, "share")
eq(card ~= nil, true, "share screen is up")
eq(buttons(s), "返回", "share screen has one button")
eq(sh.title, "写作统计", "title")
eq(sh.subtitle, "Writing Stats", "subtitle")
eq(sh.date, "2026年9月27日 22:07", "date line")
eq(sh.label, "本轮平均速度", "big number label")
eq(sh.value, "13", "round average (100 words / 450 s)")
eq(sh.unit, "字 / 分钟", "unit")
eq(#sh.points, 8, "8 round-minutes (0..7)")
eq(sh.points[1], 20, "minute 0")
eq(sh.points[2], 0, "minute 1 is a zero, not skipped")
eq(sh.points[8], 20, "minute 7")
eq(ticks(s, "share"), "0.000=开始|0.571=4 分|1.000=结束", "round card x ticks")
eq(sh.stats[1].k .. sh.stats[1].v .. sh.stats[1].small, "总字数100字", "stat 1")
eq(sh.stats[2].k .. sh.stats[2].v, "时长7:30", "stat 2 (colon clock, not 7 分 30 秒)")
eq(sh.stats[3].k .. sh.stats[3].v .. sh.stats[3].small, "峰值120字/分钟", "stat 3")
eq(sh.foot, "这一轮，你写下了 100 个字", "foot")
eq(sh.file, "nota-stats-round-20260927-2207.png", "file name")

print("-- (16) 今日分享图：钟点刻度、补 0、文件名带日期 --")
cmds2.share_close()
cmds2.share_day()
s = step(box2, 460000, 210)
sh = blk(s, "share")
eq(sh.label, "今日平均速度", "big number label")
eq(sh.value, "13", "today average")
eq(#sh.points, 8, "8 numbers of the day (22:00..22:07)")
eq(sh.points[1], 20, "22:00")
eq(sh.points[2], 0, "22:01 is a zero (the panel was not open)")
eq(sh.points[8], 20, "22:07")
eq(ticks(s, "share"), "0.000=22:00|0.571=22:04|1.000=22:07", "day card x ticks are clock times")
eq(sh.stats[1].k .. sh.stats[1].v .. sh.stats[1].small, "今日写了100字", "stat 1")
eq(sh.stats[3].k .. sh.stats[3].v .. sh.stats[3].small, "今日峰值120字/分钟", "stat 3")
eq(sh.foot, "今天，你写下了 100 个字", "foot")
eq(sh.file, "nota-stats-day-2026-09-27.png", "file name carries the date")
cmds2.share_close()
s = step(box2, 460000, 210)
eq(buttons(s), "再来一轮 | 制作本轮分享图+制作今日分享图", "back to the done screen")

print("-- (17) 跨天：翻页不是清零 --")
cmds2.start() -- 新一轮（此刻还是 09-27，所以那一轮记在 09-27 头上）
s = step(box2, 470000, 210) -- 这一枪只是重新立基线
eq(record(s, "today"), "100 字（今天 · 2 轮）", "rounds counter went up on the day it started")
s = step(box2, 7260000, 240) -- 2026-09-28 00:01（断档 1 小时 53 分）：+30 记到新的一天
eq(record(s, "today"), "30 字（今天 · 0 轮）", "the new day starts its own account")
eq(fields(s)["本轮写了"], "30 字", "the round carried over midnight")
cmds2.stop()
f = box2.store["days.txt"]
eq(f:match("d 2026%-09%-27 100 450000 120 2\n") ~= nil, true, "yesterday's line is still there")
eq(f:match("d 2026%-09%-28 30 ") ~= nil, true, "and today's line is appended")
eq(f:match("^v1\nd 2026%-09%-27") ~= nil, true, "days are written in date order")

print("-- (18) 重新加载：账读得回来（含分钟格）--")
local _, box3 = load({ time = true, data = true, store = box2.store })
s = box3.panel.render() -- 这个实例的时钟又回到 2026-09-27 22:00
eq(record(s, "today"), "100 字（今天 · 2 轮）", "yesterday's account came back from disk")
box3.cmds.share_day()
s = box3.panel.render()
sh = blk(s, "share")
eq(#sh.points, 8, "the minute buckets came back too")
eq(sh.points[1], 20, "22:00")
eq(sh.points[8], 20, "22:07")

print("-- (19) 账本的两刀：日账留 400 天，分钟账只留最近 7 天 --")
-- ⚠️ 2026-09-27 之前是"整天只留 7 天"。热力图要的是长期（用户：「记录长期数据」），
--    所以日账那一行改留 400 天，而**分钟账**（一天最多 1440 行）仍然只留 7 天——
--    两刀分开算，常量与理由在 `ledger.lua` 头上。
local lines, seed = { "v1" }, {}
for day = 1, 9 do
  table.insert(lines, string.format("d 2026-09-%02d 10 60000 60 1", day))
  -- 每天都塞一格分钟账：这样才看得出哪几天被抹掉了。
  table.insert(lines, string.format("m 2026-09-%02d 600 5", day))
end
seed["days.txt"] = table.concat(lines, "\n") .. "\n"
local _, box4 = load({ time = true, data = true, store = seed })
box4.panel.render() -- 立"今天"那条（09-27）
box4.cmds.start() -- 脏了 → 落盘
local f4 = box4.store["days.txt"]
eq(day_lines(f4), 10, "day rows are all kept (ten days is far below 400)")
eq(f4:match("d 2026%-09%-01") ~= nil, true, "the oldest seeded day still has its day row")
eq(f4:match("d 2026%-09%-27") ~= nil, true, "today is there too")
-- 分钟账那一刀：`keys` 升序排完只留最后 7 天（09-04..09-09 ＋ 09-27），前面三天
-- **只丢分钟账、日账留着**（那句"那天写了多少字"在 `d` 行里，热力图还要用）。
eq(f4:match("m 2026%-09%-03") == nil, true, "an old day's minute buckets are dropped")
eq(f4:match("m 2026%-09%-04") ~= nil, true, "the newest seven days keep theirs")
eq(f4:match("m 2026%-09%-09") ~= nil, true, "09-09 keeps its minute bucket")
eq(f4:match("d 2026%-09%-03") ~= nil, true, "…and that old day's day row survives")

-- 日账那一刀的另一半：超过 400 天时从**最老**那头丢。⚠️ 这一段用**假日期**
-- （`1000-0001`）：它只考"排完序丢掉最老的几个"，而真造 405 个真日期要在测试里
-- 再写一遍日历；假日期全排在 `2026-09-27` 前面（字典序），该丢的必然是最老那头。
local lines400 = { "v1" }
for k = 1, 405 do
  table.insert(lines400, string.format("d 1000-%04d 10 60000 60 1", k))
end
local _, box4b = load({
  time = true,
  data = true,
  store = { ["days.txt"] = table.concat(lines400, "\n") .. "\n" },
})
box4b.panel.render()
box4b.cmds.start()
local f4b = box4b.store["days.txt"]
eq(day_lines(f4b), 400, "the day rows are capped at 400")
eq(f4b:match("d 1000%-0001") == nil, true, "the oldest rows are the ones dropped")
eq(f4b:match("d 1000%-0405") ~= nil, true, "the newest seeded row survives")
eq(f4b:match("d 2026%-09%-27") ~= nil, true, "and today is there too")

print("-- (20) 全天：横轴变整点标尺（大一号），并且带上小格 --")
-- 用户 2026-09-27：「如果是全天的话，那就一个小时为一个单位的横坐标标尺」＋「到小时就用
-- 稍微大一点的字体标出来是几小时」。这里摆一个**十小时**的一天（09:00~19:00，每 10 秒
-- 十个字）——装的是 `ticks.day_ticks` 那条分支，也是"整点"唯一摆得出来的跨度。
-- ⚠️ `wall()` 的起点是 09-27 22:00，所以"第二天早上九点" = (1440+540-1320) 分钟。
-- ⚠️ **一枪只推 10 秒**（不是半小时）：两次采样隔得比 `GAP_MS`（15 秒）久就是断档，
--    那种枪只累加总数、**不落分钟格**（`take_sample` 里那条分支）——半小时一枪的话，
--    这一整天的分钟账全是空的，图也就画不出来。第一版就是这么摆错的。
local _, box5 = load({ time = true, data = true })
box5.cmds.start()
local nine_am = (1440 + 540 - 1320) * 60000
for k = 0, 3600 do -- 3600 × 10 秒 = 10 小时
  step(box5, nine_am + k * 10000, 100 + 10 * k) -- 每 10 秒 +10 字
end
box5.cmds.stop()
box5.cmds.share_day()
s = box5.panel.render()
sh = blk(s, "share")
eq(sh.x_ticks[1].at, 0, "the first hour tick sits at the left edge")
eq(sh.x_ticks[1].label, "09:00", "hour labels are clock times")
eq(sh.x_ticks[1].big, true, "and they are marked big (大单位)")
eq(#sh.x_ticks, 11, "09:00..19:00 is 11 ticks (<= 13, the host's cap)")
eq(sh.x_ticks[11].label, "19:00", "the last tick is the last whole hour")
eq(sh.x_minor, 4, "quarter-hour minor ticks between the hours")
-- ⚠️ 每一档都必须是整点：有一条不整就说明 `day_ticks` 是从 `first` 起数的（那样每一档
--    都是 09:07 这种数，读起来全是噪音）。
local all_whole = true
for _, t in ipairs(sh.x_ticks) do
  if not t.label:match("^%d%d:00$") then all_whole = false end
end
eq(all_whole, true, "every tick lands on a whole hour")
-- 本轮那张卡片也带小格（那半同样是"仪器的标尺"）。
box5.cmds.share_round()
s = box5.panel.render()
eq(blk(s, "share").x_minor, 4, "the round card has minor ticks too")

print("-- (21) 长期那本账：窗口、三个数、热力图那张卡 --")
-- 先单独验两个纯算术的工具（`ticks.lua` 尾巴上那一段）。⚠️ 期望值**硬写死**，
-- 来自另一套实现（Python 的 `datetime.date`）：2026-09-27 是周日、距 1970-01-01
-- 20723 天，本周周一是 09-21（20717）。
-- ⚠️ 名字叫 `tk` 不叫 `ticks`：上面那个同名辅助函数（读 `x_ticks`）会被**遮蔽**，
-- 而症状是"从这一行往后，所有 `ticks(...)` 调用都变成对模块表取下标"（静默失效，
-- 报的错还指向别处）。2026-10-04 顺手改了名。
local tk = require("ticks")
eq(tk.day_number(2026, 9, 27), 20723, "day_number agrees with Python's calendar")
eq(tk.day_number(2000, 2, 29), 11016, "leap day")
eq(tk.day_number(1970, 1, 1), 0, "the epoch itself")
eq(tk.day_number(2026, 13, 1), nil, "month 13 is not a date")
eq(tk.day_number(2026, 0, 1), nil, "month 0 is not a date")
eq(tk.ymd_number("2026-09-27"), 20723, "ymd_number reads the ledger's format")
eq(tk.ymd_number("2026-9-27"), nil, "but the ledger's format is fixed-width")
eq(tk.ymd_number(20723), nil, "and it only takes strings")
eq(tk.monday_of(20723), 20717, "2026-09-27 is a Sunday — its Monday is 09-21")
eq(tk.monday_of(20719), 20717, "Wednesday 09-23 is in the same week")
eq(tk.monday_of(20717), 20717, "a Monday is its own Monday")
eq(civil_text(tk.day_number(2026, 9, 27)), "2026-09-27", "…and the round trip closes")
eq(tk.group_text(128400), "128,400", "thousands separators")
eq(tk.group_text(999), "999", "no leading comma when the digits divide by three")
eq(tk.group_text(1000), "1,000", "four digits")
eq(tk.group_text(0), "0", "zero")

-- 一本**像真的**账：从 2026-05-11（周一）写到 09-26，五天里有四天动笔，工作日多、
-- 周末少。五天里有四天动笔 → 139 天里 105 天有字。
--
-- ⚠️ 另外塞一条**老账**（2026-01-01，9999 字）：这一条把两件事一起考了——
--
--   1. 窗口按"**最早那条有字的记录**"起算，于是它一路顶到 26 周那个**天花板**
--      （用户要的是"长期"，但半年那张图铺满一屏就到头了）；
--   2. 顶到天花板之后，这条老账**自己反倒落在窗口外**：它一个数都不许进
--      （账本留 400 天，比 26 周长得多）。"图上有几格"与"总字数算哪些天"
--      必须是同一段窗口,不然数对不上图。
local rows21, lines21 = {}, { "v1" }
local FIRST_N, TODAY_N = 20584, 20723 -- 2026-05-11 … 2026-09-27（硬写死的两个端点）
local WINDOW_N = 20542 -- 2026-03-30：26 周那个上限下窗口的第一天
for k = 0, 138 do
  local n = FIRST_N + k
  local words
  if k % 4 == 3 then
    words = 0
  elseif k % 7 >= 5 then
    words = 200 + (k * 7) % 300
  else
    words = 1200 + (k * 37) % 1800
  end
  table.insert(rows21, { n = n, words = words })
  table.insert(lines21, string.format("d %s %d 600000 60 1", civil_text(n), words))
end
table.insert(lines21, "d 2026-01-01 9999 600000 60 1")
local _, box6 = load({
  time = true,
  data = true,
  store = { ["days.txt"] = table.concat(lines21, "\n") .. "\n" },
})
local s6 = box6.panel.render()

local want_total, want_held, want_max = 0, 0, 0
for _, row in ipairs(rows21) do
  want_total = want_total + row.words
  if row.words > 0 then want_held = want_held + 1 end
  if row.words > want_max then want_max = row.words end
end

local view = blk(s6, "heatmap")
eq(view ~= nil, true, "the panel shows the long-term block")
eq(view.weeks, 26, "the window tops out at 26 weeks (half a year)")
eq(view.to, "2026-09-27", "…and ends today")
eq(view.title, "长期记录", "the block's title")
eq(view.unit, "字", "the block's unit (the cell tooltips use it)")
eq(view.days:sub(1, 10), civil_text(FIRST_N), "the string starts at the first day of the window")
eq(view.days:find(civil_text(FIRST_N) .. ":" .. rows21[1].words, 1, true) ~= nil, true, "…with that day's count")
eq(view.days:find(civil_text(FIRST_N + 3) .. ":0", 1, true) ~= nil, true, "zero days are sent too")
eq(view.days:find("2026-01-01", 1, true) == nil, true, "a row outside the window is not")
eq(select(2, view.days:gsub(":%d+", "")), 140, "140 days in the window (139 + today)")
eq(view.days:sub(-12), "2026-09-27:0", "and the last one is today")
eq(WINDOW_N < FIRST_N, true, "the window starts before the first row we seeded (that is the point)")
eq(tk.ymd_number("2026-01-01") < WINDOW_N, true, "…and the stray January row falls before it")

-- 那一句人话（面板上那行字与卡片页脚是**同一份**）。
eq(
  hasText(s6, string.format("最近 26 周，你在 %d 天里写下了 %s 个字", want_held, tk.group_text(want_total))),
  true,
  "the panel says the same numbers the grid draws"
)

-- 面板 ④ 那一条**长期**记录卡（2026-10-04 加）。
-- ⚠️ 门槛与分享按钮那条判据是**同一个**（`st.days >= 2`）：一处松一处紧的话会出现
-- "卡上有长期、按钮里没有"或者反过来，而那种不一致在界面上看着像两件事。
-- ⚠️ 这一份实例**没按过开始**（phase 恒 idle）：**本轮那条现在照画**（2026-10-07 起
-- idle 也摆成表盘，全 0），今日那条仍然不该有（今天一个字都没写）。
eq(record(s6, "long"), tk.group_text(want_total) .. " 字（最近 26 周 · 105 天有字）", "the long record card")
eq(record(s6, "round"), "0 字 / 分钟（本轮 · 0 字 · 0 秒）", "the idle round card is there, at zero")
eq(card(s6, "today"), nil, "no today card (today has nothing written yet)")
eq(total(s6), "100 字", "…but the summary row is there (the whole document)")
eq(buttons(s6), "开始记录 | 制作长期分享图", "③ the toggle, ④ the long card's share button")

box6.cmds.share_long()
s6 = box6.panel.render()
local heat = blk(s6, "share")
eq(heat.shape, "heat", "the long card is the heatmap shape")
eq(heat.weeks, 26, "…with the same window")
eq(heat.days == view.days, true, "the card and the panel use one window, not two")
eq(heat.less, "少", "the low end of the legend")
eq(heat.more, "多", "the high end of the legend")
eq(heat.label, "长期总字数", "the big number's label")
eq(heat.value, tk.group_text(want_total), "the total is the window's total")
eq(heat.unit, "字", "…in 字")
eq(heat.stats[1].v, tostring(want_held), "days with writing")
eq(heat.stats[2].v, tk.group_text(math.floor(want_total / want_held + 0.5)), "daily average")
eq(heat.stats[3].v, tk.group_text(want_max), "busiest day")
eq(heat.foot, string.format("最近 26 周，你在 %d 天里写下了 %s 个字", want_held, tk.group_text(want_total)), "the footer")
eq(heat.file, "nota-stats-long-2026-09-27.png", "the file name carries today")
-- ⚠️ 极值是 0 字那一天之前算出来的：那一天的格子仍然是**空格**（不是最浅那一档），
--    所以档位是拿"有字那些天"的最大值分的——由宿主那边分档（`ui/heatmap.ts`）。
eq(want_max > 0, true, "the fixture really does have writing")

print("-- (22) 账本刚开张：窗口兜底 8 周；**空格子照画**（2026-10-07 改）--")
local _, box7 = load({
  time = true,
  data = true,
  store = { ["days.txt"] = "v1\nd 2026-09-26 0 0 0 0\n" },
})
local s7 = box7.panel.render()
-- ⚠️ **2026-10-07 改了口径**（用户原话：「"长期记录"也要默认显示哦」）：以前"一个字没写"
-- 连**那一块**都不发，刚装上的机器打开面板根本看不到「长期记录」这四个字。现在空账本
-- **照画一整片空格子**，那句人话也照说（只是全是 0）——表盘上的格子本来就该一直在。
local hv7 = blk(s7, "heatmap")
eq(hv7 ~= nil, true, "an empty ledger still draws the long-term block")
eq(hv7.title, "长期记录", "…with its title (that is the whole point of this change)")
eq(hv7.weeks, 8, "…over the 8-week fallback window")
eq(hasText(s7, "最近 8 周，你在 0 天里写下了 0 个字"), true, "…and the saying reads zero, not nothing")
eq(card(s7, "long"), nil, "the long record card still needs two days of writing (it is tied to the share button)")
eq(buttons(s7), "开始记录", "…so no long share button either")
eq(hasText(s7, "还没开始。按「开始记录」，这一轮写了多少字、用了多久、什么速度，就都算起来了。"), true, "the idle notice is still there")
eq(total(s7), "100 字", "the summary row survives on an otherwise empty screen")
-- ⚠️ 空账本 ＋ 没按过开始：**只剩本轮那条 0**（2026-10-07 起 idle 也画它），
-- 所以标题也回来了（有框就得有标题）。今日/长期两条仍然一条都不画。
eq(#cards(s7).items, 1, "…with only the idle round card above the summary")
eq(cards(s7).title, "写作记录", "and the heading is back (there is a card to head)")
box7.cmds.share_long() -- needs = "long" 不成立 → 不进那一屏
s7 = box7.panel.render()
eq(blk(s7, "share") == nil, true, "and the long card does not open")

local two = {}
for k = 0, 1 do
  two[#two + 1] = string.format("d 2026-09-%02d 800 60000 60 1", 25 + k)
end
local _, box8 = load({
  time = true,
  data = true,
  store = { ["days.txt"] = "v1\n" .. table.concat(two, "\n") .. "\n" },
})
local s8 = box8.panel.render()
local v8 = blk(s8, "heatmap")
eq(v8 ~= nil, true, "two days of writing is enough for the long block")
eq(v8.weeks, 8, "a brand-new ledger still gets the 8-week floor")
eq(v8.to, "2026-09-27", "…ending today")
eq(select(2, v8.days:gsub(":%d+", "")), 3, "and only three days have rows in it")
box8.cmds.share_long()
s8 = box8.panel.render()
local small = blk(s8, "share")
eq(small.shape, "heat", "the long card opens once two days have writing")
eq(small.value, "1,600", "both days counted")
eq(small.stats[1].v, "2", "two days with writing")

print("-- (23) 刚「继续」时的大数：旧的冻结值必须作废（2026-10-04 开窗目检抓出来的） --")
-- ⚠️ 这一条是**开窗看出来的**，不是想出来的：那天在 `:96` 上按下「继续」、当场打了 13 个字，
-- 卡上却写着 **0 字/分钟**。根因是 `shown = live or frozen_rate`——刚「继续」时样本还没攒够
-- `MIN_SPAN_MS`（10 秒），`average_rate` 返回 `nil`（Lua 里 `0` 是**真**、`nil` 才是假，所以
-- 兜底一定拿到那个冻结值）。「开始」那一支靠 `reset_round()` 早就清了同一个值，**只有
-- 「继续」漏了**——两颗按钮通向同一个 `running` 屏，屏幕上的数就该是同一个来路。
-- ⚠️ 摆出这一条的关键是**静置超过 60 秒**（比 `WINDOW_MS` 长）：窗口里一个样本都不剩，
-- `average_rate` 必然返回 `nil`，兜底那条路才走得出来（暂停 18 秒是摆不出来的）。
local _, box9 = load({ time = true, data = true })
local cmds9 = box9.cmds
cmds9.start()
local t9, c9 = 0, 100
t9, c9 = t9 + 2000, c9 + 20
step(box9, t9, c9) -- 立基线
local s9
for _ = 1, 8 do
  t9, c9 = t9 + 2000, c9 + 20
  s9 = step(box9, t9, c9)
end
eq(bignum(s9), "600", "跑着的时候是实读数（20 字 / 2 秒）")
cmds9.pause()
s9 = step(box9, t9, c9)
eq(bignum(s9), "600", "暂停那一屏：冻住的那个数")
cmds9.resume()
t9 = t9 + 90000 -- 静置 90 秒（> 60 秒的窗口）
c9 = c9 + 30 -- ⚠️ 这一格要**跟着走**：`step` 只改桩里的字数，不改上面这个变量
s9 = step(box9, t9, c9) -- 这一枪只立基线（「继续」把基线清了），那 30 个字不算
eq(bignum(s9), "-", "刚「继续」：还没有结论 → 破折号（**不是**暂停前那个 600）")
for _ = 1, 6 do
  t9, c9 = t9 + 2000, c9 + 10
  s9 = step(box9, t9, c9)
end
eq(bignum(s9), "300", "样本攒够之后才是真读数（60 字 / 12 秒）")

print("-- (24) Δt 窗口：拖一下滑杆，下一枪就换算法（2026-10-04 加） --")
-- 用户 2026-10-04：「统计打字速度，不要统计全局的，应该统计某一个德尔塔t内的
-- 打字数量。这个德尔塔t可以在拓展的设置页面更改，默认为5秒。应该是一个托条，
-- 从1秒到1分钟可选。」
-- 那根滑杆长在「设置 → 拓展」上（`plugin.toml` 的 `[[settings]]`，形状见 `docs/11`），
-- 值由**宿主**写进 `plugin-settings/nota.stats.toml`；插件这一侧是从
-- `nota.settings.get("window_seconds")` **现读**的（这里桩的就是那个读数）。
--
-- ⚠️ `knobs` 这张表由**测试自己拿着**，改它就是"用户在设置页拖了一下"。
-- 这同时是"每一枪现读、不缓存"唯一的观测点：缓存了的话，第二次那两条断言
-- 会原封不动地拿到第一次的数——而那正是"拖完没反应"。

print("-- (24a) 窗口就按设置走，停了手它就是 0 --")
local knobs = {}
local _, box10 = load({ time = true, data = true, settings = knobs })
local cmds10 = box10.cmds
cmds10.start()
local t10, c10 = 2000, 120
s = step(box10, t10, c10) -- 立基线
for _ = 1, 4 do -- 每 2 秒 20 个字，跑 8 秒
  t10, c10 = t10 + 2000, c10 + 20
  s = step(box10, t10, c10)
end
eq(fields(s)["速度窗口"], "最近 5 秒", "没设过就是默认 5 秒（桩里那张表还是空的）")
eq(bignum(s), "600", "窗口里那 6 秒的平均速度（60 字 / 6 秒 → 600 字/分钟）")
-- 停手 20 秒：字数一个不动，面板照开着（采样照收，只是每一枪 +0）。
-- ⚠️ 这一段是这一格**存在的理由**：用户要的是"此刻的手速"，不是"整整一分钟的平均"。
for _ = 1, 10 do
  t10 = t10 + 2000
  s = step(box10, t10, c10)
end
eq(bignum(s), "0", "停了手就是 0（有结论、就是没在打——不是破折号）")
knobs.window_seconds = 60
s = step(box10, t10 + 2000, c10) -- 拖完滑杆之后的**下一枪**
eq(fields(s)["速度窗口"], "最近 60 秒", "小字那一行当场跟着变了")
eq(bignum(s), "160", "同一支采样序列，换个窗口就是另一个数（80 字 / 30 秒）")

print("-- (24b) 外面来的怪数字一律夹回去（面板那一行是唯一观测点） --")
knobs.window_seconds = 0
eq(fields(step(box10, t10 + 4000, c10))["速度窗口"], "最近 1 秒", "0 夹到下限 1")
knobs.window_seconds = 999
eq(fields(step(box10, t10 + 6000, c10))["速度窗口"], "最近 60 秒", "999 夹到上限 60")
knobs.window_seconds = "五秒"
eq(fields(step(box10, t10 + 8000, c10))["速度窗口"], "最近 5 秒", "不是数 → 退回默认 5 秒")
knobs.window_seconds = 12.4
eq(fields(step(box10, t10 + 10000, c10))["速度窗口"], "最近 12 秒", "带小数的舍到整秒（12.4 → 12）")
knobs.window_seconds = 20.6
eq(fields(step(box10, t10 + 12000, c10))["速度窗口"], "最近 21 秒", "…而且是四舍五入（20.6 → 21）")
knobs.window_seconds = nil
eq(fields(step(box10, t10 + 14000, c10))["速度窗口"], "最近 5 秒", "键没了也是默认 5 秒")

print("-- (24c) 够不够出数是 min(Δt, 10 秒)，不是拿 10 秒卡 --")
-- ⚠️ 拿 10 秒去卡的话：默认那 5 秒档上大数字会**白白空 5 秒**（窗口都回看满了，
-- 却还不给数）；反过来，60 秒那一档也不会真的等满 60 秒才出数。
local _, box11 = load({ time = true, data = true, settings = { window_seconds = 60 } })
box11.cmds.start()
local t11, c11 = 0, 100
s = step(box11, t11, c11) -- 立基线
t11, c11 = t11 + 2000, c11 + 20
s = step(box11, t11, c11)
eq(bignum(s), "-", "60 秒的窗口也不会等满 60 秒（够不够看的是 min(Δt, 10 秒)）")
for _ = 1, 4 do
  t11, c11 = t11 + 2000, c11 + 20
  s = step(box11, t11, c11)
end
eq(bignum(s), "600", "攒到 10 秒就出数（100 字 / 10 秒）")

-- 默认那 5 秒档（空表 → 5 秒）：攒够 5 秒就该出数，不用等 10 秒。
local _, box12 = load({ time = true, data = true, settings = {} })
box12.cmds.start()
local t12, c12 = 0, 100
s = step(box12, t12, c12)
t12, c12 = t12 + 2000, c12 + 20
s = step(box12, t12, c12)
eq(bignum(s), "-", "默认 5 秒档：只攒了 2 秒，还不够")
t12, c12 = t12 + 2000, c12 + 20
s = step(box12, t12, c12)
eq(bignum(s), "-", "4 秒也还不够（要回看满 Δt）")
t12, c12 = t12 + 2000, c12 + 20
s = step(box12, t12, c12)
eq(bignum(s), "600", "满 5 秒就出数了（60 字 / 6 秒的窗口 → 600 字/分钟）")

print("-- (24d) 连 nota.settings 都没有（老宿主 / 老 api）→ 默认 5 秒 --")
local _, box13 = load({ time = true, data = true })
box13.cmds.start()
s = step(box13, 2000, 100)
eq(fields(s)["速度窗口"], "最近 5 秒", "读不到那一号对象也照常按默认 5 秒算")
eq(next(fields(s)) ~= nil, true, "小字那一块照发（不是整块消失）")

print("")
if fails == 0 then
  print("ALL PASS（" .. checks .. " 条断言）")
else
  print(fails .. " FAILED")
  os.exit(1)
end
