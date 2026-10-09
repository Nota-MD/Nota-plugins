-- 写作统计的**刻度与"数怎么写"**（2026-09-27 从 `main.lua` 拆出来）。
--
-- 拆它的理由有两条，都是硬的：
--
--   1. **行数**：`main.lua` 顶到 1000 行（本仓 `.lua` 的硬上限，`docs/09` §4），
--      而这块是整份插件里**唯一纯函数**的一截——搬它动不到任何状态；
--   2. 它是 `require`（插件多文件，`docs/12` §5.9）的**第一个真用户**：拆出来的
--      那一天，插件系统刚学会在自己目录里找 `.lua`。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里**（同 `main.lua` 顶上
-- 那一条）：Lua 的标识符不许有非 ASCII 字符，写了是**语法错误**，症状是整份插件
-- 加载失败、面板和菜单一起消失。
--
-- 这一份**不认识 `nota`**：它不知道文档、不认识账本、也不会落盘，只把数字与
-- 时刻摆成画得出来的样子。译文那一侧要晚一步（`nota` 要到 `on_load` 才到手），
-- 所以 `T` 是先给一个"原样返回"的桩、由 `bind_text` 换掉（同 `main.lua` 顶上那段）。

local M = {}

--- 文案取用器。默认原样返回——模块级的字符串本来就不该等 `nota`。
local T = function(s) return s end

--- 把真取用器接进来。`main.lua` 在 `on_load` 里调（那时 `nota` 才到手）。
function M.bind_text(f)
  T = f
end

--- 一个数写成字。`nil` = 没有结论 → 空串（前端画破折号，不画 0）。
function M.num_text(v)
  if not v then
    return ""
  end
  return tostring(v)
end

--- 时长写成 `12:34`（超过一小时写 `1:02:03`）。
-- ⚠️ 与面板上那个 `human_span`（`12 分 34 秒`）**故意不一样**：面板是读一句话，卡片是看
-- 一个数——`12:34` 一眼就能和旁边的数字对齐着读。
function M.clock_span(ms)
  local mn = math.floor(ms / 60000)
  local secs = math.floor(ms % 60000 / 1000)
  if mn >= 60 then
    return string.format("%d:%02d:%02d", math.floor(mn / 60), mn % 60, secs)
  end
  return string.format("%d:%02d", mn, secs)
end

--- 卡片右上角那个日期时间。拿不到时间来源就是空串（那一段就不画）。
function M.date_text(tinfo)
  if not tinfo then
    return ""
  end
  return string.format(T("%d-%02d-%02d %02d:%02d"), tinfo.y, tinfo.mo, tinfo.d, tinfo.hh, tinfo.mi)
end

--- 文件名里的时刻：`20260927-2214`。**纯 ASCII**——它要进文件系统。
function M.stamp_text(tinfo)
  if not tinfo then
    return "00000000-0000"
  end
  return string.format("%04d%02d%02d-%02d%02d", tinfo.y, tinfo.mo, tinfo.d, tinfo.hh, tinfo.mi)
end

--- 把"第几分钟写了几个字"摊成一条**等距**的速度序列（字/分钟）。
--
-- ⚠️ 空档**补 0 而不是跳过**：跳过就等于把两段写作之间的午休从横轴上剪掉，图上读起来是"一直在写"——而"什么时候停过"正是这张图要说的事之一。
-- 时间轴等距这条不能省（横轴是按序号画的）。
--
-- ⚠️ 点太多时按**等长的桶**合并（桶 = 整数分钟），值 = 桶里的字 ÷ 桶的分钟数，仍然是一条**字/分钟**的曲线。前端一块图最多认 200
-- 个点（`每块上限`）。⚠️ `max_points` 由上家传（`main.lua` 的 `MAX_POINTS`）：一份图上能画几个点
-- 是**整份插件的口径**，不该在这里另立一个。
function M.spread(mins, from_i, to_i, max_points)
  local out = { pts = {}, bucket = 1, from_i = from_i, to_i = to_i }
  if to_i < from_i then
    return out
  end
  local bucket = math.max(1, math.ceil((to_i - from_i + 1) / max_points))
  out.bucket = bucket
  local i = from_i
  while i <= to_i do
    local last_i = math.min(i + bucket - 1, to_i)
    local sums = 0
    for k = i, last_i do
      sums = sums + (mins[k] or 0)
    end
    table.insert(out.pts, math.floor(sums / bucket + 0.5))
    i = last_i + 1
  end
  return out
end

--- 一条曲线的三档横轴刻度：起、中、末。⚠️ 同位置只留一次（重了会叠字）。
--
-- `label_of` 可以返回字符串，也可以返回 `{ label = …, big = true }`——后者是"这一档是个
-- 整点"（用户 2026-09-27：「到小时就用稍微大一点的字体」），宿主会把字号放大一号。
function M.three_ticks(from_i, bucket, count, label_of)
  if count < 2 then
    return {}
  end
  -- 一个刻度项：字符串 → 只带 label；表 → 连 `big` 一起带上。
  local function make(at, lb)
    if type(lb) == "table" then
      return { at = at, label = lb.label, big = lb.big }
    end
    return { at = at, label = lb }
  end

  local out = {}
  for _, f in ipairs({ 0, 0.5, 1 }) do
    local idx = math.floor(f * (count - 1) + 0.5)
    local at = idx / (count - 1)
    local item = make(at, label_of(from_i + idx * bucket, f))
    if #out > 0 and at == out[#out].at then
      out[#out] = item -- ⚠️ 撞位了**后写的赢**：点很少（两三个）时，"中间"和"最后"
      -- 会落到同一个槽里——留着"中间"的话，右端就写不成「结束」了。
      -- ⚠️ 换的是**整个项**（不是只换 label）：不然"小字"那个 `big = nil` 会留下来。
    elseif #out == 0 or at > out[#out].at then
      table.insert(out, item)
    end
  end
  return out
end

--- 本轮图上的横轴标签：`开始` / `6 分` / `结束`（**不是钟点**，理由见 `main.lua` 文件头）。
--
-- ⚠️ 中间那一档**正好落在整小时上**（60 / 120 / … 分钟）就改写「2 小时」、并且**放大一号**
-- ——用户 2026-09-27：「到小时就用稍微大一点的字体标出来是几小时」。一轮很少跑到一小时，
-- 所以绝大多数时候这里就是「32 分」；真跑到了，"小时"这两个字就是这条轴上最大的字。
function M.round_tick(mn, f)
  if f <= 0 then
    return T("Start")
  end
  if f >= 1 then
    return T("End")
  end
  if mn >= 60 and mn % 60 == 0 then
    return { label = string.format(T("%d h"), mn / 60), big = true }
  end
  return string.format(T("%d min"), mn)
end

--- 今日图上的横轴标签：钟点（`09:12`）。这张图的横轴就是**墙上时间**。
function M.clock_tick(mn)
  local m = mn % 1440
  return string.format("%02d:%02d", math.floor(m / 60), m % 60)
end

--- 主刻度之间隔几个小格。
--
-- ⚠️ 这是用户 2026-09-27 要的"仪器的标尺"那一半：主刻度给**数**，小格只给**密度**——
-- 没有小格时，两档之间是空的，读不出"这两档离得多近"。格数是插件定的（一格是几分钟
-- 只有插件知道），**字号与长度是宿主定的**（`src/ui/share-card.ts`）。
function M.minor_per_gap()
  return 4
end

--- 今日那张卡的横轴主刻度：**按钟点标**。
--
-- 用户原话：「如果是全天的话，那就一个小时为一个单位的横坐标标尺」＋「到小时就用稍微
-- 大一点的字体标出来是几小时」。所以：
--
--   * 每一档都是**整点**（`09:00`），带 `big = true` → 宿主画大一号；
--   * 挤不下就 2/3/4/6/8/12 小时一档（前端一块图最多认 13 档，`panel-nodes.ts`）；
--   * 一档都摆不出来（跨度不到一小时）就返回空表——**不编位置**，让宿主那张图只有
--     小格，比编一档假钟点强。
--
-- `from_i` / `bucket` / `count` 三个与 `spread` 同一个口径：第 i 个点覆盖
-- `[from_i + i*bucket, …]` 分钟，横轴按序号等距。
function M.day_ticks(from_i, bucket, count)
  if count < 2 or bucket < 1 then
    return {}
  end
  local span = (count - 1) * bucket
  -- 一档要占的分钟数：从 60 分钟起，一档挡不住就往大里挑（12 档是前端的硬上限）。
  local step = 0
  for _, h in ipairs({ 1, 2, 3, 4, 6, 8, 12 }) do
    if math.ceil(span / (60 * h)) + 1 <= 12 then
      step = 60 * h
      break
    end
  end
  if step == 0 then
    return {}
  end

  local last_m = from_i + span
  local out = {}
  -- 从**第一个整点**起（不是从 `from_i` 起）：`from_i` 是"今天第一次写字那一分钟"，
  -- 09:12 开始写就标 09:12 的话，每一档都是一个不整的数，读起来全是噪音。
  local m = math.ceil(from_i / step) * step
  while m <= last_m do
    local idx = math.floor((m - from_i) / bucket + 1e-9)
    table.insert(out, { at = idx / (count - 1), label = M.clock_tick(m), big = true })
    m = m + step
  end
  return out
end

-- ⚠️ 这里原本还有一个 `M.window_ticks`（面板那条曲线"最老的点离现在多久"那排
-- 横轴刻度），**2026-10-04 删了**：那块独立的曲线（`kind = "chart"`）折进了记录卡
-- （`kind = "cards"`）里，而卡里那条窄曲线没有刻度——它只有 36px 高，摆不下
-- "-2 分 / -1 分 / 现在"那一排。`main.lua` 那边转发它的那个局部函数一起删了。
-- 哪天再要一块带刻度的曲线（比如把卡片里的图放大），这一段从 git 历史里拿回来就是。

-- ── 长期那本账要的两个小工具（2026-09-27，热力图）──────────────────────────
--
-- ⚠️ 这一段**只做算术**：哪天算第几号、一个数怎么加千位分隔。它不认识账本、
-- 也不认识 `nota`——"哪一段窗口、窗口里有多少字"是 `main.lua` 的事。

--- 一个数写成带千位分隔的样子：`128400` → `128,400`。
-- ⚠️ 卡片上那个大数字是 210px 高的一行，六个数字连成一片**数不出位数**；
-- ⚠️ 只处理非负数（这个插件数的全是字数与天数），负数原样返回。
function M.group_text(n)
  local v = math.floor(tonumber(n) or 0)
  if v < 0 then
    return tostring(v)
  end
  -- 倒过来每三位插一个逗号：正着写要看"离末尾还有几位"，倒着写只看满没满三位。
  local rev = tostring(v):reverse():gsub("(%d%d%d)", "%1,")
  local out = rev:reverse()
  -- ⚠️ 位数正好是三的倍数时，倒着插会在**最前面**多一个逗号（`999` → `,999`）。
  if out:sub(1, 1) == "," then
    out = out:sub(2)
  end
  return out
end

--- `2026-09-27` → 天数编号（1970-01-01 = 0）。认不出来返回 `nil`。
function M.ymd_number(ymd)
  if type(ymd) ~= "string" then
    return nil
  end
  local y, m, d = ymd:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return nil
  end
  return M.day_number(tonumber(y), tonumber(m), tonumber(d))
end

--- 公历某一天的天数编号（1970-01-01 = 0）。
--
-- ⚠️ 自己算是**被迫**的：沙箱里只有 `nota.time.now()`（给年月日时分），没有
-- `os.time`、没有日历库，而"这半年一共写了多少字"要按天求和。
-- 算法是 Howard Hinnant 那套 `days_from_civil`（把 3 月当一年的头、用 400 年
-- 一个闰年周期去掉所有特例）——**不是**"加上 86400 秒"那种近似：那种写法在
-- 夏令时与闰年上都会错一天。
function M.day_number(y, m, d)
  if type(y) ~= "number" or type(m) ~= "number" or type(d) ~= "number" then
    return nil
  end
  if m < 1 or m > 12 or d < 1 or d > 31 then
    return nil
  end
  local yy = m <= 2 and y - 1 or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- 那一天所在这一周的**周一**（同一种天数编号）。
-- ⚠️ 1970-01-01 是**周四**，所以偏移是 3 不是 0（`(n + 3) % 7`：周四 → 3）。
function M.monday_of(n)
  return n - (n + 3) % 7
end

return M
