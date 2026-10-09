-- 写作统计的**面板内容**：② 小字数据概览 与 ④ 记录卡（2026-10-04 从 `main.lua` 拆出）。
--
-- 拆它的尺子与 `ticks.lua` 那一次**同一条**、只是换了个数：这一批（把面板改成运动
-- 手表那套版式）改完，`main.lua` 又顶到了 1055 行，而 `.lua` 的硬上限是 1000
-- （`docs/09` §4）。挑中这一段是因为它是**整份插件里唯一不持有状态**的一截：
-- 它只读别人算好的数、只往外发字段（`kind = "fields"` / `kind = "cards"`），搬它
-- 动不到任何一条时间线。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里**（同 `main.lua` 顶上
-- 那一条）：Lua 的标识符不许有非 ASCII 字符，写了是**语法错误**，症状是整份插件
-- 加载失败、面板和菜单一起消失。
--
-- ⚠️ 译文那一侧晚一步（`nota` 要到 `on_load` 才到手），所以 `T` 是先给一个"原样
-- 返回"的桩、由 `bind_text` 换掉（同 `ticks.lua` / `long.lua`）。
--
-- ⚠️ **它靠 `ctx`（一张"这一拍怎么样"的表）读状态，而不是 `require("main")`**：
-- Lua 的 `require` 是单向的，反过来引就是一个环。表由 `main.lua` 每画一次面板现搭
-- 一张（`card_ctx`）——每秒一张表的开销可以忽略，换来的是"这几个函数到底认识哪几样
-- 东西"写在调用处那几行字上，而不是散在几十个上值里。
-- ⚠️ `ctx` 里**只有读**：这几个函数一个字段都不往回写（写了就成了藏在参数里的状态）。

local M = {}

--- 文案取用器。默认原样返回——模块级的字符串本来就不该等 `nota`。
local T = function(s) return s end

--- 把真取用器接进来。`main.lua` 在 `on_load` 里调（那时 `nota` 才到手）。
function M.bind_text(f)
  T = f
end

--- ② 那几行小字：本轮的细账 ＋ 那个大字是**怎么算出来的**。
--
-- `ctx` 要的四样：`round_words`（本轮写了多少字）、`elapsed_ms`（记了多久）、
-- `peak_rate`（峰值字/分钟）、`window_s`（大数字回看多少秒，2026-10-04 加）；
-- 另外借 `ctx.span_text`（时长说成人话）。
-- ⚠️ 只放**记录卡上已经有的数之外的**：卡上那个大字是速度，这几行是它的旁注。
-- ⚠️ 「整篇文档」**不在**这儿——它在记录卡底下那行汇总里。"同一个数写在两个地方"
-- 迟早会有一处忘了改（这一条以前在这块和分享图上各写过一遍）。
--
-- ⚠️ **窗口那一行是 2026-10-04 加的**（用户那天要求大数字按"最近 Δt 秒"算，
-- Δt 做成设置页上的一根滑杆）：拖完滑杆得当场看得见生效了没有。
-- ⚠️ 标签与滑杆用的是**同一个键**（`"Speed window"`）：一处译了，两处都对。
function M.overview(ctx)
  return {
    { label = T("Written this round"), value = string.format(T("%d words"), ctx.round_words) },
    { label = T("Recorded for"), value = ctx.span_text(ctx.elapsed_ms) },
    {
      label = T("Peak speed"),
      value = string.format(T("%d words/min"), math.floor(ctx.peak_rate + 0.5)),
    },
    { label = T("Speed window"), value = string.format(T("last %d s"), ctx.window_s) },
  }
end

--- 本轮那条曲线上的点。
--
-- `ctx` 要的几样：`phase`、`round_mins`、`last_minute()`（本轮记到第几分钟）、
-- `spread(mins, from, to)`、`plot()`（最近三分钟的逐秒采样）。
--
-- ⚠️ 跑着/暂停时给**逐秒**那条（最近三分钟的采样，就是原来那条"心电图"），结算
-- 之后换成**整轮每分钟**那条：跑着的时候要看"刚才这几分钟怎么起伏"（用户原话
-- 「实时显示…下方 s-t 图」），结算之后要看"整轮一路怎么走"。
-- 两条都不是假的，只是同一个过程的两种粒度。
function M.round_points(ctx)
  if ctx.phase == "done" then
    return ctx.spread(ctx.round_mins, 0, ctx.last_minute()).pts
  end
  return ctx.plot()
end

--- ④ 那一串记录卡。
--
-- `ctx` 要的：上面 `round_points` 那几样，外加 `num_text`（数写成字）、`group_text`
-- （数带千位分隔）、`long_stats()`（长期那本账）。
--
-- ⚠️ 顺序是**新账在前**（本轮 → 今日 → 长期）。参考图上那三条是倒着排日期的
-- （10/3、9/27、9/13），同一个意思：最近的那条在最上面。
-- ⚠️ **一条都没有也照发**（见下面那段）：汇总那行里的"整篇文档"永远在。
-- ⚠️ **2026-10-07 起 idle 那一屏也有本轮卡**（用户原话：「默认手表界面哦」）——
-- 那一屏从"一句说明 ＋ 一颗按钮"变成"运动手表那块表盘，只是所有数都是 0"。
--- `shown` 是这一拍那个速度读数（`panel_content` 已经按相位算好了，暂停时是
--- 冻结值）——**不能在这儿再算一遍**，理由见 `docs/13` §14.4「冻结」。
function M.record_cards(ctx, shown, words, day_row)
  local items = {}

  -- 本轮那条：**四个相位都发**。
  -- ⚠️ 「还没开始」那一屏也发（2026-10-07，用户原话「默认手表界面哦」）：面板一打开
  -- 就该是运动手表那个样子——一个大数字 ＋ 底下一条线，只是这一刻它老老实实写着 0
  -- （真手表开机也是 00:00，这一屏不该靠"什么都没有"来表达"还没开始"）。
  -- ⚠️ **idle 那个大字不能走 `num_text(shown)`**：idle 相位 `shown` 是 `nil`，
  -- 而 `num_text(nil)` 给的是空串、渲染层会画成一根破折号——"还没开始"该显示 `0`，
  -- 不是"没有读数"（那是 `running` 刚起步还不够采样时的样子，见 `bignum` 那条用例）。
  items[#items + 1] = {
    icon = "round",
    value = ctx.phase == "idle" and "0" or ctx.num_text(shown),
    unit = T("words / min"),
    caption = string.format(
      T("This round · %s words · %s"),
      ctx.group_text(ctx.round_words),
      ctx.span_text(ctx.elapsed_ms)
    ),
    -- ⚠️ idle 时 `plot()` 是空的（采样只在跑着的时候累加），所以这条线自然是空的
    -- ——不必在这儿特判一个 `{}`。
    points = M.round_points(ctx),
  }

  local r = day_row
  if r and r.words > 0 then
    local series = ctx.spread(r.mins, r.first or 0, r.last or 0)
    items[#items + 1] = {
      icon = "today",
      value = ctx.group_text(r.words),
      unit = T("words"),
      caption = string.format(T("Today · %d rounds"), r.rounds),
      points = series.pts,
    }
  end

  -- 长期那条：⚠️ 门槛与 `can_share("long")` 一致（**两天**起），否则会出现
  -- "记录卡上有长期、分享按钮里没有"这种两处对不上的样子。
  local st = ctx.long_stats()
  if st and st.days >= 2 then
    items[#items + 1] = {
      icon = "long",
      value = ctx.group_text(st.total),
      unit = T("words"),
      caption = string.format(
        T("The last %d weeks · %d days with writing"),
        st.weeks,
        st.days
      ),
      points = {},
    }
  end

  -- ⚠️ **一条记录都没有也照发**：底下那行汇总（整篇文档）在任何一屏都在，
  -- 把它一起省掉的话"还没有任何一条记录"的那一屏就只剩一句说明和一颗按钮了。
  -- 那种情况下不画那行小标题（没有框给它当标题）。
  return {
    kind = "cards",
    title = #items > 0 and T("Writing record") or "",
    items = items,
    -- 汇总那行给的是**整篇文档**，不是上面那几条的和：三条记录的区间是**互相包着**
    -- 的（长期 ⊇ 今日 ⊇ 本轮），加起来是个没有意义的数。
    -- ⚠️ 所以标签写「整篇文档」而不写「总计」——"总计"会让人以为那是和。
    total = {
      label = T("Whole document"),
      value = ctx.group_text(words),
      unit = T("words"),
    },
  }
end

return M
