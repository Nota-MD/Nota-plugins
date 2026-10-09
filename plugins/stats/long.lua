--
-- 写作统计的**长期那本账**（2026-09-27 从 `main.lua` 拆出来，热力图要的）。
--
-- 拆它的理由与 `ticks.lua` 那条同源，但更硬：**行数**。`main.lua` 加上这一段之后
-- 是 1117 行，而本仓 `.lua` 的硬上限是 1000（`docs/09` §4）。这一块又刚好是能整块
-- 搬走的一截——它不碰状态，只要有人把账本与"此刻"递进来（下面那两个参数）。
--
-- 它把 `days` 那本账**压成发得出去的样子**：一格一天的那串记录（`days` 字段，
-- 格式由宿主定，理由见 `src/ui/heatmap.ts` 头上——宿主对"一层里的项数"有 200 的
-- 上限，一天一项地发根本发不出去），加上三个数（总字数 / 有字天数 / 单日最多）。
--
-- ⚠️ 窗口（铺几周、从哪天到哪天）**在这里定**，宿主照单全收：宿主只认 `weeks` 与
-- `to`，它不认识"有账以来"。所以面板那一块与分享图那张卡用的是**同一份**窗口与
-- 同一份数——两处各算一次的话，同一屏上会出现两个不一样的总字数。
--
-- ⚠️⚠️ **变量名一律用 ASCII**（同 `main.lua` 顶上那一条）：Lua 的标识符不许有非
-- ASCII 字符，写了是语法错误，症状是整份插件加载失败。
--
-- 它**不认识 `nota`**：账本与"此刻"由 `main.lua` 递进来（`days` / `nowinfo`），
-- 译文那一侧晚一步（`bind_text`，与 `ticks.lua` 同一套）。

local ticks = require("ticks")

local M = {}

--- 文案取用器。默认原样返回——模块级的字符串本来就不该等 `nota`。
local T = function(s) return s end

--- 把真取用器接进来。`main.lua` 在 `on_load` 里调。
function M.bind_text(f)
  T = f
end

--- 长期那本账最多铺几列（半年）／最少几列（两个月）。
-- ⚠️ 下限 8 与宿主那边夹的一样（`ui/heatmap.ts`）：账本刚开张时铺满半年，图上
-- 只有孤零零两格有颜色——那不是"长期数据"，那是把两个月的数据摊在半年里。
local WEEKS_MAX = 26
local WEEKS_MIN = 8

--- 长期那本账里要铺几列：从**第一条有字的记录**那一周，到今天这一周。
-- ⚠️ 按"周一对周一"数，不按天数除 7：宿主那边一列就是一周（周一到周日），
-- 拿天数除会在跨周的那几列上多算一列出来。
function M.weeks(days, today_n)
  local first_n = nil
  for ymd, r in pairs(days) do
    if (r.words or 0) > 0 then
      local n = ticks.ymd_number(ymd)
      if n and (not first_n or n < first_n) then
        first_n = n
      end
    end
  end
  if not first_n then
    return WEEKS_MIN
  end
  local w = math.floor((ticks.monday_of(today_n) - ticks.monday_of(first_n)) / 7) + 1
  if w < WEEKS_MIN then
    return WEEKS_MIN
  end
  if w > WEEKS_MAX then
    return WEEKS_MAX
  end
  return w
end

--- 长期那本账的窗口与三个数。拿不到日期就是 `nil`（那时整套长期都不出现）。
-- ⚠️ 一天都没写（`days == 0`）时**照样返回**——"这本账开了 12 周，一个字没写"是
-- 事实，只是调用方据此不画那一块（见 `panel_content`）。
function M.stats(days, tinfo)
  if not tinfo or not tinfo.ymd or tinfo.ymd == "" then
    return nil
  end
  local today_n = ticks.ymd_number(tinfo.ymd)
  if not today_n then
    return nil
  end
  local weeks = M.weeks(days, today_n)
  -- 窗口的第一天 = 今天这一周的周一，往前数 `weeks - 1` 周（与宿主铺格子的起点同源）。
  local from_n = ticks.monday_of(today_n) - (weeks - 1) * 7

  local total, held, peak = 0, 0, 0
  for ymd, r in pairs(days) do
    local n = ticks.ymd_number(ymd)
    -- ⚠️ 窗口外的记录**不掺和**：账本里留着的 400 天比窗口长，全算进来那个"总字数"
    -- 就与图上画的对不上了（图上只画窗口里那些天）。
    if n and n >= from_n and n <= today_n then
      local c = r.words or 0
      total = total + c
      if c > 0 then
        held = held + 1
      end
      if c > peak then
        peak = c
      end
    end
  end

  return {
    ymd = tinfo.ymd,
    weeks = weeks,
    from_n = from_n,
    today_n = today_n,
    total = total,
    days = held,
    max = peak,
    -- 日均按"**有字**的那些天"平均，不按窗口天数：分母是 182 的话，一个只在周末写
    -- 的人会被算成每天 30 字，而他的真实节奏是"周末一天 400 字"。
    avg = held > 0 and math.floor(total / held + 0.5) or 0,
  }
end

--- 窗口里那些天压成**一个字符串**：`2026-09-27:1284 2026-09-26:0 …`（升序）。
-- ⚠️ 升序只是让人在日志里读得顺；宿主按日期建表，顺序不影响它。
-- ⚠️ **0 字的那天也发**：那一天在账本里存在（`d` 行），"记了账但一个字没写"与
-- "那天账本还没开张"在图上都是空格，但前者至少说明那天的数据是完整的。
function M.days_text(days, st)
  local rows = {}
  for ymd, r in pairs(days) do
    local n = ticks.ymd_number(ymd)
    if n and n >= st.from_n and n <= st.today_n then
      table.insert(rows, { n = n, ymd = ymd, words = r.words or 0 })
    end
  end
  table.sort(rows, function(a, b)
    return a.n < b.n
  end)
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, row.ymd .. ":" .. tostring(row.words))
  end
  return table.concat(out, " ")
end

--- 长期那句人话（面板上一行字、卡片页脚一处）。**两处共用一份**，免得说法不一致。
function M.saying(st)
  return string.format(
    T("The last %d weeks: %d days with writing, %s words"),
    st.weeks,
    st.days,
    ticks.group_text(st.total)
  )
end

--- 「长期」那张卡片的字段（**热力图**：`shape = "heat"`）。
-- ⚠️ `days` 是**第一个参数**：这一份不认识账本（文件头那条），拼那串格子靠的是
-- `days_text`，而它要的正是账本本身。
function M.card(days, st, tinfo)
  return {
    kind = "share",
    shape = "heat",
    days = M.days_text(days, st),
    weeks = st.weeks,
    to = st.ymd,
    less = T("Less"),
    more = T("More"),
    title = T("Writing Stats"),
    subtitle = "Writing Stats",
    date = ticks.date_text(tinfo),
    label = T("Total in this window"),
    value = ticks.group_text(st.total),
    unit = T("words"),
    stats = {
      { k = T("Days with writing"), v = tostring(st.days), small = T("days") },
      { k = T("Daily average"), v = ticks.group_text(st.avg), small = T("words/day") },
      { k = T("Busiest day"), v = ticks.group_text(st.max), small = T("words") },
    },
    foot = M.saying(st),
    file = "nota-stats-long-" .. st.ymd .. ".png",
  }
end

return M
