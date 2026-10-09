-- 写作统计的**按钮与分享屏**：③ 那颗开关、④ 那三颗"做分享图"，以及三张分享图
-- （本轮 / 今日 / 长期）的字段（2026-10-04 从 `main.lua` 拆出）。
--
-- 拆它的尺子与 `ticks.lua` / `cards.lua` 那两次**同一条**：Δt 窗口那一批改完
-- `main.lua` 顶到了 1065 行，而 `.lua` 的硬上限是 1000（`docs/09` §4）。
--
-- ⚠️ 挑中这一截的理由和挑 `cards.lua` 时一样：它**只读**——每一处都是"读别人算好的
-- 数、往外发一张卡或一串按钮"，一个字段都不往回写。它靠 `ctx`（一张显式递进来的表）
-- 读状态，而**不** `require("main")`：Lua 的 `require` 是单向的，反过来引就是一个环。
-- ⚠️ `ctx` 里**只有读**：这几个函数一个字段都不往回写（写了就成了藏在参数里的状态）。
--
-- ⚠️ 这里**没有** `require("ticks")`：要用到的刻度函数（`three_ticks` / `day_ticks` /
-- `num_text` …）都由 `ctx` 递进来——与 `cards.lua` 同一条规矩，好处是"这几个函数到底
-- 认识哪几样东西"写在调用处那几行字上，而不是散在模块头的一堆 `require` 里。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里**（同 `main.lua` 顶上那一条）：
-- Lua 的标识符不许有非 ASCII 字符，写了是**语法错误**，症状是整份插件加载失败、
-- 面板和菜单一起消失。这一批就栽过一次（`average_rate` 的形参写成了中文）。
--
-- ⚠️ 译文那一侧晚一步（`nota` 要到 `on_load` 才到手），所以 `T` 先给一个"原样返回"的
-- 桩、由 `bind_text` 换掉（同 `ticks.lua` / `cards.lua` / `long.lua`）。

local M = {}

--- 文案取用器。默认原样返回——模块级的字符串本来就不该等 `nota`。
local T = function(s) return s end

--- 把真取用器接进来。`main.lua` 在 `on_load` 里调（那时 `nota` 才到手）。
function M.bind_text(f)
  T = f
end

-- ── 按钮 ─────────────────────────────────────────────────────────────────
--
-- 面板上那几颗按钮（**2026-10-04 收成一颗开关**）。
--
-- 用户那天甩来两张运动手表的截图当参考，并给了一句：「合成一颗开关：
-- 『开始/暂停/继续』一颗按钮加『结束』」。于是：
--
-- | 状态 | 开关那颗 | 「结束」那颗 |
-- |---|---|---|
-- | `idle` | 「开始记录」 | 不出现 |
-- | `running` | 「暂停」 | 「终止」 |
-- | `paused` | 「继续」 | 「终止」 |
-- | `done` | 「再来一轮」 | 不出现 |
--
-- ⚠️ 合并的好处不只是少一颗按钮：原来「开始记录」与「再来一轮」是两句不同的话、
-- 走的却是同一支代码（`start`）——它们在状态图上本来就是**同一个动作的两个名字**。
-- 收成一颗开关之后，"这一颗把这一轮往前推一格"这件事在表上就是一行字。
-- ⚠️ 「终止」仍然**只在跑着/暂停时出现**、且恒在**最右**：它是唯一不可逆的动作，
-- 位置固定比好看重要（这条从第一版起没变）。
local TOGGLE = {
  idle = { label = "Start recording", command = "start", style = "primary" },
  running = { label = "Pause", command = "pause" },
  paused = { label = "Resume", command = "resume", style = "primary" },
  done = { label = "Start another round", command = "start", style = "primary" },
}

--- 「终止」那颗。⚠️ **没有状态**（表里那一行不肯写死相位）：它在 `running` 与
--- `paused` 里是同一个东西，写两遍就有了两个能对不上的副本。
local STOP = { label = "Stop", command = "stop", style = "danger" }

local BUTTONS = {
  idle = { TOGGLE.idle },
  running = { TOGGLE.running, STOP },
  paused = { TOGGLE.paused, STOP },
  done = { TOGGLE.done },
  -- 分享那一屏只有一颗「返回」：这一屏是**看**的，动作全在卡片下面（前端那两颗）。
  share = {
    { label = "Back", command = "share_close" },
  },
}

-- 「做一张分享图」那三颗（2026-10-04 从上面那组里搬出来，挪到**记录卡底下**）。
--
-- ⚠️ 它们不属于"控制这一轮"（上面那组才是），而是"把这一条记录带走"——和记录卡
-- 摆在一起，用户看到的顺序才是"这是记录 → 可以做成图"。⚠️ 反过来说，**面板上
-- 只有这两处按钮**：③ 控制这一轮、④ 带走那一条记录。
-- ⚠️ `needs` 是**插件自己用的**（不发给前端）：没东西可分享时那颗按钮就不出现
-- ——一颗"点了只得到一句空话"的按钮比灰按钮更坏。
local SHARE_BUTTONS = {
  { label = "Make this round's card", command = "share_round", needs = "round" },
  { label = "Make today's card", command = "share_day", needs = "day" },
  { label = "Make the long-term card", command = "share_long", needs = "long" },
}

--- 此刻有没有东西可分享。`round` = 刚跑完的那一轮；`day` = 今天有账；`long` = 长期那本账值得画。
function M.can_share(ctx, needs)
  if needs == "round" then
    return ctx.phase == "done" and ctx.total_add > 0
  end
  if needs == "long" then
    -- ⚠️ 至少要**两天**有字：一天的账在半年那张图上就是孤零零一格，而"这颗按钮
    -- 点下去得到一张像坏了的图"比"这颗按钮暂时不出现"更糟（同上面 `needs` 那条）。
    local st = ctx.long_stats and ctx.long_stats() or nil
    return st ~= nil and st.days >= 2
  end
  return ctx.today ~= nil and ctx.today.words > 0
end

--- 一串按钮定义 → 发得出去的那串（带 `needs` 的先过一遍 `can_share`）。
--- ⚠️ `T()` 要晚于模块加载（译文是 `on_load` 才接上的），所以**现译**，不在表里写死。
local function buttons_of(ctx, list)
  local out = {}
  for _, b in ipairs(list or {}) do
    if not b.needs or M.can_share(ctx, b.needs) then
      table.insert(out, { label = T(b.label), command = b.command, style = b.style })
    end
  end
  return out
end

--- ③ 那一组（当前状态的那一档）。
function M.buttons_for(ctx, now_phase)
  return buttons_of(ctx, BUTTONS[now_phase])
end

--- ④ 底下那一组（做分享图那三颗）。**一颗都发不出去就返回空表**（调用方会省掉那一块）。
function M.share_buttons(ctx)
  return buttons_of(ctx, SHARE_BUTTONS)
end

-- ── 三张分享图 ───────────────────────────────────────────────────────────
--
-- ⚠️ 这一段**只数数、只写字段**，一个像素都不画（画的是 `src/ui/share-card.ts`）。
-- 这里产出的东西就是 `kind = "share"` 那一块的全部内容。
--
-- ⚠️ **"数怎么写、刻度摆哪儿"那一半 2026-09-27 搬去了 `ticks.lua`**：那几个是整份
-- 插件里唯一**不碰状态**的一截，搬走只为把 `main.lua` 压回 1000 行以内。这里经
-- `ctx` 拿到 `num_text` / `group_text` / `three_ticks` / `day_ticks` 那几个名字。

--- 今日的平均速度（字/分钟）。太短就是 `nil`（理由同 `main.lua` 的 `MIN_SPAN_MS`）。
local function day_rate(ctx)
  if not ctx.today or ctx.today.ms < ctx.min_span_ms then
    return nil
  end
  return math.floor(ctx.today.words / ctx.today.ms * 60000 + 0.5)
end

--- 本轮记到第几分钟（`round_mins` 里最大的那个键，从 0 起算）。一个字没记就 0。
--- ⚠️ 抽出来是因为**两处**都要它：分享图那张卡（整轮每分钟）与面板上那张记录卡
--- （结算之后的曲线，见 `cards.lua::round_points`）。两处各算一遍就是两个能对不上的
--- "这一轮到哪儿了"。⚠️ 它是**纯函数**（拿 `round_mins` 那张表，不碰状态），
--- 所以 `main.lua` 那边也直接调它。
function M.round_last_minute(mins)
  local to_i = 0
  for mi in pairs(mins) do
    if mi > to_i then
      to_i = mi
    end
  end
  return to_i
end

--- 「这一轮」那张卡片的字段。
function M.round_card(ctx)
  local series = ctx.spread(ctx.round_mins, 0, M.round_last_minute(ctx.round_mins))
  return {
    kind = "share",
    title = T("Writing Stats"),
    subtitle = "Writing Stats",
    date = ctx.date_text(ctx.nowinfo),
    label = T("Round average"),
    value = ctx.num_text(ctx.round_rate()),
    unit = T("words / min"),
    points = series.pts,
    x_ticks = ctx.three_ticks(0, series.bucket, #series.pts, ctx.round_tick),
    x_minor = ctx.minor_per_gap(),
    stats = {
      { k = T("Total"), v = ctx.group_text(ctx.total_add), small = T("words") },
      { k = T("Duration"), v = ctx.clock_span(ctx.elapsed_ms), small = "" },
      { k = T("Peak"), v = tostring(math.floor(ctx.peak_rate + 0.5)), small = T("words/min") },
    },
    foot = string.format(T("This round you wrote %s words"), ctx.group_text(ctx.total_add)),
    file = "nota-stats-round-" .. ctx.stamp_text(ctx.nowinfo) .. ".png",
  }
end

--- 「今日」那张卡片的字段。今天没账就没这张卡（调用方会拦在前面）。
function M.day_card(ctx)
  local r = ctx.today
  local series = ctx.spread(r.mins, r.first or 0, r.last or 0)
  -- ⚠️ 今日这张**不用三档**：它的横轴就是**钟点**，用户 2026-09-27 要的是「一个小时为一个
  -- 单位的横坐标标尺」＋「到小时就用稍微大一点的字体」——`ticks.day_ticks` 按跨度自己挑
  -- 1/2/3/4/6/8/12 小时一档，每一档都是整点、都放大一号。
  -- ⚠️ **摆不满两档就退回三档钟点**（起/中/末）：今天只写了七八分钟的时候，整点标尺上
  -- 只有一个"22:00"，比刻度还难读——那种跨度下"从几点到几点"才是这张图要说的。
  local axis = ctx.day_ticks(r.first or 0, series.bucket, #series.pts)
  if #axis < 2 then
    axis = ctx.three_ticks(r.first or 0, series.bucket, #series.pts, ctx.clock_tick)
  end
  return {
    kind = "share",
    title = T("Writing Stats"),
    subtitle = "Writing Stats",
    date = ctx.date_text(ctx.nowinfo),
    label = T("Today's average"),
    value = ctx.num_text(day_rate(ctx)),
    unit = T("words / min"),
    points = series.pts,
    x_ticks = axis,
    x_minor = ctx.minor_per_gap(),
    stats = {
      { k = T("Written today"), v = ctx.group_text(r.words), small = T("words") },
      { k = T("Recorded today"), v = ctx.clock_span(r.ms), small = "" },
      { k = T("Today's peak"), v = tostring(math.floor(r.peak + 0.5)), small = T("words/min") },
    },
    foot = string.format(T("Today you wrote %s words"), ctx.group_text(r.words)),
    file = "nota-stats-day-" .. r.ymd .. ".png",
  }
end

-- ── 长期那本账（热力图，2026-09-27）──────────────────────────────────────
--
-- 用户：「加一个功能，类似 Contribution Graph 那样的热力图，记录长期数据。
-- 仅记录打字数。功能归属于心电图插件。」
--
-- ⚠️ **算的那一半在 `long.lua`**：窗口怎么定、哪些天算数、那个字符串怎么拼——
-- 那几条是纯算术，只是要有人把账本递进去。

--- 长期那张分享卡。`st` 是 `main.lua` 算好的那份统计（`long_stats()`）。
function M.long_card(ctx, st)
  return ctx.long.card(ctx.days, st, ctx.nowinfo)
end

--- 那条热力图上的日格字符串。
function M.days_text(ctx, st)
  return ctx.long.days_text(ctx.days, st)
end

--- 那一句人话（"最近 N 周，你在 M 天里写下了 X 个字"）。
function M.long_saying(ctx, st)
  return ctx.long.saying(st)
end

--- 面板 ① 那一块**长期**（热力图 ＋ 一句人话）。**只有连日期都读不出来时才一个块都不给**。
-- ⚠️ **2026-10-07 改了**（用户原话：「"长期记录"也要默认显示哦」）：以前这里还有一条
-- `st.days <= 0`——一个字都没写的账本**整块不画**，于是刚装上的机器打开面板根本看不到
-- 「长期记录」这四个字。现在**空账本照画**：一整片空格子 ＋ 一句「最近 N 周，你在 0 天里
-- 写下了 0 个字」（与「默认手表界面」那条同一条口径：表盘上的格子本来就该一直在）。
-- ⚠️ **代价如实记着**：面板每秒重画一次，而这一块要拼一个几百字的字符串、前端那边要铺
-- 一百八十多个格子（`ui/heatmap.ts` 把 182 天摊成 7×26 个 `<span>`）——**没账的时候也照铺**。
-- 这是用户点名要的，不是漏了那条优化；真嫌费，正确的做法是让前端缓存那一格，而不是把
-- 块吞掉（吞掉的症状是"装完什么都没有"）。
-- ⚠️ 那句人话是**必要的**：格子对读屏软件没有意义（前端那一块挂 `aria-hidden`），
-- "写了多少人少天"要有一句说得出来的话。
-- ⚠️ **2026-10-04 起这一块排在最上面**（用户给的参考图里，长期那条记录在最前），
-- 所以那个打头的 `separator` 没了——它当初是为了和上面那块隔开，而现在它上面
-- 没有东西，留着就是面板顶上凭空一条横线。
function M.long_blocks(ctx)
  local st = ctx.long_stats()
  if not st then
    return {}
  end
  return {
    {
      kind = "heatmap",
      title = T("Long-term record"),
      unit = T("words"),
      days = M.days_text(ctx, st),
      weeks = st.weeks,
      to = st.ymd,
    },
    { kind = "text", tone = "muted", text = M.long_saying(ctx, st) },
  }
end

return M
