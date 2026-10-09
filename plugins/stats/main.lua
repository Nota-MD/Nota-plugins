-- 写作统计（原名「写作心电图」，2026-09-27 用户要求改名）。
--
-- 用户 2026-09-26（当时叫「写作心电图」）：「写作心电图。统计打字速度，实时显示，
-- 大红字数字/分钟，下方 s-t 图」
-- ＋「参考运动手表的运动记录，有一个开始、暂停、终止」；2026-09-27：「分享支持全日状态，
-- 也应该支持某一次的记录的状态。另外横纵坐标的刻度要标」。
--
-- ⚠️ **逐块的长篇说明在 `docs/13` §14.4**（每一处"为什么这么做"，连"哪条分支手点摆不出来"
-- 都在）。这里只留**写代码时手边必须有**的四件事：状态图、时序三条口径、两本账、ASCII 规矩。
--
-- ⚠️ 第二轮之前它**自动连续计时**（面板一开着就采），用户点名运动手表那套之后改成**显式的一轮**：
--
-- ```text
--   idle ──「开始记录」──▶ running ──「暂停」──▶ paused
--                            ▲                    │
--                            └─────「继续」────────┘
--                            │                    │
--                            └────「终止」─────────┴──▶ done ──「再来一轮」──▶ running
-- ```
--
-- ⚠️ `done` 是**留着结果给人看**，不是清零（清零那一下在「再来一轮」）。
--
-- **时序口径**：① **换文档 = 自动暂停**（不是终止），因为数的原料是**当前这一份文档**的
-- 「字/词」数，切走了就与本轮开头无关——⚠️ 两个都没存过盘的新文档 `path` 都是空串、分不出来，这时
-- 不暂停（已知的粗糙处）；② **面板没开着就不采点**（前端只拉活动页）：那段时间照旧算进**总数
-- 与时长**，但不画点、不算峰值——中间没有采样，画出来是假尖刺；③ 时间只有 `stats().clock_ms`
-- （自 Nota 启动起算的**单调**毫秒，沙箱里没有 `os`），所以「记录时长」是累加出来的。
--
-- **数的是什么**：`stats().words`（当前文档的**「字/词」数**）比上次多了多少——**不读键盘**。
-- 别的窗口里打的字不算；删字不算（负增量按 0）；**粘一大段也算**。
--
-- ⚠️ **2026-09-27 之前这里读的是 `stats().chars`（码点数）**，用户那天点名改了
-- （「注意，**如果是英文的话要统计词**…如果 token 拆分器写的代码量太多的话就不用用了」）：
-- 码点那条口径对中文是对的、对英文是错的（`hello` 算 5 个字，写一句英文读数虚高
-- 四五倍）。现在这一条数的是宿主 `nota.document.stats().words`，规则是
-- **中文一个字算一个 ＋ 一段连续的英文/数字算一个词**（没有分词器，见
-- `src-tauri/src/lua/api/document.rs::词数` 顶上那张规则表）。
-- ⚠️ 于是**历史那几天的账和今天以后不是一个口径**（`days.txt` 里的老数字是码点）。
-- 用户还没有正式用户、`days.txt` 也是本机自己的记录，所以**不做换算、也不加版本字段**；
-- 但**别拿老数据和今天的比**——记录在 `docs/13` §14.4。
--
-- **两本账**（后一本是 2026-09-27 加的）：
--
-- | 账 | 什么时候累加 | 存在哪儿 | 用来画什么 |
-- |---|---|---|---|
-- | **本轮** | 只在 `running` 时 | 内存（`total_add` / `round_mins`） | 面板曲线 ＋ 本轮分享图 |
-- | **今日** | 同上（**同一支代码**） | `nota.data` 的 `days.txt` | 面板的「今天…」 ＋ 今日分享图 |
--
-- ⚠️ 两本账数的是同一件事，只是**键不一样**（本轮按"本轮第几分钟"，今日按"当天第几分钟"）。
-- ⚠️ **只有今日那本落盘**（`data.own`，纯文本，删了只是今天的账从头开始）；本轮是"刚才那场运动"，重启之后还在才是怪的。
--
-- ⚠️ **分享图这边只给字段**（`kind = "share"`：标题、大数字、三格数、点、横轴刻度），
-- 画成什么样是前端的事（`src/ui/share-card.ts`）——理由与"宿主不认识 Markdown"同一条。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里。** Lua 的标识符不许有非
-- ASCII 字符，写了是**语法错误**——症状是整份插件加载失败、面板和菜单一起消失
-- （`plugins/README.md` 里记过这个坑）。

local M = {}

-- 面板 id。⚠️ 2026-09-27 跟着插件改名一起从 `"heartbeat"` 改成了 `"stats"`——那时
-- 还没有用户，所以没写一次性搬家（`plugin.toml` 顶上那一段写着这件事）。
local PANEL_ID = "stats"

-- 历史和曲线留这么久（毫秒）。三分钟：260px 宽的一栏里每秒一个点就是 180 个。
local KEEP_MS = 180000

-- 算大数字那个滑动窗口的**边界**（秒）。⚠️ 窗口本身**不再是常数**：
-- 用户 2026-10-04 要求"不要统计全局的，按最近 Δt 秒算"，而 Δt 由他在
-- 「设置 → 拓展」那一页上拖（`plugin.toml` 的 `[[settings]]`，默认 5 秒）。
-- 这里这两个数是**兜底**：插件不信任外面来的数（文件可能被手改坏、
-- `nota.settings` 也读不到），与 `window_ms` 那段说明是同一件事的两半。
local MIN_WINDOW_S = 1
local MAX_WINDOW_S = 60
local DEFAULT_WINDOW_S = 5

-- 上面那三个数与清单里那条 `[[settings]]`（min / max / default）**必须一致**。
-- ⚠️ 两处各写一遍是**有意的**：清单那份是给宿主画滑杆用的，这份是插件自己算数
-- 用的。`docs/11`「给拓展做一格设置」里写着这条"两处都有"的规矩——
-- 不一致的表现是"滑杆能拖到 60，而插件按 20 算"，界面上完全看不出来。

-- 数据跨度短于这么久就**不给数字**（画一个破折号）。
-- ⚠️ 不是"算不出来"，是**样本太少时那个数没有意义**：两秒钟打了三个字，乘出来是 90 字/分钟，而那不是任何人的写作速度，是一个除法。
-- ⚠️ `done`（整轮）与今日那个平均速度用它；`running` 那一支用的是
-- **"Δt 与它取小"**（见 `average_rate`）：窗口拖到 5 秒时，样本攒够 5 秒
-- 就该出数了——拿 10 秒去卡的话，默认档位上大数字会白白空 5 秒。
local MIN_SPAN_MS = 10000

-- 两次采样隔得比这久 = 中间断档（面板没开着）。
-- ⚠️ 第二轮起它**不再重置本轮**（一轮是由"开始/终止"划的），只决定"这一枪要不要画到曲线上"——见文件头那段与 `tick`。
local GAP_MS = 15000

-- 图上最多给多少个点。前端还有一道同样的上限（`ui/panel-nodes.ts::每块上限`）。
local MAX_POINTS = 200

-- 本轮的状态（状态图见文件头）。⚠️ 用字符串而不是数字：日志里"3 是什么"是记不住的。
-- ⚠️ 它是**模块级**的：整份插件活着它就活着，**应用一重启就没了**（本轮不落盘）。
local phase = "idle"

-- 采样序列，一项 = `{ t = 时刻, dt = 这一段有多久, add = 这一段长了几个字 }`。
-- ⚠️ 存 `dt` / `add` 而**不是**存算好的速度（理由见 `docs/13` §14.4「加权怎么算」）。
local samples = {}

-- **本轮**每分钟的字/词数（键 = 本轮第几分钟，从 0 起，值 = 那一分钟写了多少「字/词」）。
-- ⚠️ 面板曲线用 `samples`（最近三分钟、逐秒），**分享图用这一份**（整轮）。两份只是
-- 粒度不同，不是两个真相源——都在 `take_sample` 那一处累加。
local round_mins = {}

-- 上一次采样。`nil` = 还没有基线（刚开始，或者刚「继续」）。
local last_t = nil
local last_words = nil

-- 上一次看到的文档路径。用来认"用户换文档了"（→ 自动暂停）。
local last_path = nil

-- 本轮累计：写了多少字、跑了多久、峰值。
-- ⚠️ 是**累加**出来的，不是 `words - 起点词数`：后者会把**暂停期间**打的字也算进来。
local total_add = 0
local elapsed_ms = 0
local peak_rate = 0

-- `paused` 时冻结的那个读数（**为什么必须冻**见 `docs/13` §14.4「冻结」那一行）。
-- ⚠️ 它由 `panel_content` 每一枪更新，不在 `take_sample` 里再写一遍（两个真相源）。
local frozen_rate = nil

-- ── 今日那本账（跨轮、落盘）────────────────────────────────────────────────
--
-- ⚠️ **文件格式那一半 2026-09-27 搬去了 `ledger.lua`**（`require`，插件多文件的
-- 第三个用户）：长期那块并进来之后这份文件顶到 1033 行，而本仓 `.lua` 的硬上限是
-- 1000（`docs/09` §4）。文件名、两个保留上限、`M.new_day` / `M.prune` /
-- `M.load` / `M.save` 都在那边，**这一侧只剩下面几行转接**（名字与调用点一个没动）。
--
-- 切法看"认不认识状态"：那边只认"这些行长什么样"，状态留在这一侧。

-- `[ymd] = 记录`，一条记录 = 一天。字段与 `days.txt` 一一对应：
--
-- ```text
-- v1
-- d 2026-09-27 1284 754000 210 3    -- 日期 字/词数 毫秒 峰值 轮数
-- m 2026-09-27 1334 42              -- 日期 当天第几分钟 那一分钟写了多少
-- ⚠️ 第二格是 `words`（中文字数 ＋ 英文词数，见文件头），**不是码点数**。
-- ```
--
-- ⚠️ 分钟账**只记有字的那一分钟**（稀疏）：一整天写满要 1440 行，而绝大多数是 0。
-- 曲线上的空档由 `spread` 补回来（补 0，不是跳过）。
local days = {}

-- 此刻在记的那一条（`days[ymd]` 里的**同一个表**，不是副本）。
-- ⚠️ `nil` = 还没有时间来源（`nota.time` 拿不到），那时整套"今日"都不出现。
local today = nil

-- 内存里的账与磁盘上那份不一致（有东西没写回）。
local dirty = false

-- `on_unload` 拿不到 `nota`（宿主就是不传，`lua/mod.rs` 那边写着），所以在 `on_load` 里留一份——落盘的最后一枪靠它。
local saved_nota = nil

-- 拍了拍数：每 30 拍（≈30 秒）落一次盘。⚠️ 崩溃/强杀最多丢半分钟，而写一次是"几个 KB 的文本覆盖"，比每秒都写划算得多。
local ticks_since_save = 0
local SAVE_EVERY = 30

-- 分享那一屏正开着看哪一本账：`nil` = 没开，`round` / `day`。⚠️ 它**不是第五个
-- phase**，是一层盖在 `phase` 之上的显示状态：关掉它，原来那一屏原样回来。
local share_scope = nil

-- 这一拍拿到的**墙上时间**（`nota.time.now()` 那份，`nil` = 拿不到）。
-- ⚠️ 每拍都重新问一次，而且**存下来给同一拍里后面几处复用**（今日账、卡片日期、文件名）：一次采样里问两遍，跨零点那一瞬间就会得到两份不一致的时间。
local nowinfo = nil
-- 文案取用器。`on_load` 里重新绑一次——`nota` 要到那时才到手。
-- ⚠️ 在那之前调它只会拿到原文，这是对的（模块级的字符串本来就不该等 `nota`）。
local T = function(s) return s end

--- 把这一轮整个清掉（`idle` 与「再来一轮」都走它）。
local function reset_round()
  samples = {}
  round_mins = {}
  last_t = nil
  last_words = nil
  last_path = nil
  total_add = 0
  elapsed_ms = 0
  peak_rate = 0
  frozen_rate = nil
end

-- ── 今日那本账：读、写、翻页 ─────────────────────────────────────────────
--
-- 真正干活的四个函数在 `ledger.lua`（理由见上面那段）；这里是**转接**，为的是
-- 这一侧剩下的代码一个字都不用改。⚠️ 转接里**带 `days`**：账本是这一侧的状态。

local ledger = require("ledger")

local function new_day(ymd)
  return ledger.new_day(ymd)
end

local function prune_days()
  ledger.prune(days)
end

local function load_ledger(nota)
  ledger.load(days, nota)
end



--- 换到"今天"那一条（没有就建一条）。跨天时自动翻页。
---
--- ⚠️ 翻页**不是清零**：昨天那一条留在 `days` 里，照旧写回磁盘（面板上不显示它，但那本账还在）。今日分享图要的数因此永远只来自当前这一条。
local function roll_day(tinfo)
  if not tinfo or tinfo.ymd == "" then
    return nil
  end
  if today and today.ymd == tinfo.ymd then
    return today
  end
  local r = days[tinfo.ymd]
  if not r then
    r = new_day(tinfo.ymd)
    days[tinfo.ymd] = r
    prune_days()
  end
  today = r
  return today
end

--- 把内存里的账写回磁盘。**没脏就不写**（每一拍都写等于每秒覆盖一次文件）。
--
-- ⚠️ 这一侧只管**要不要写**（脏位、`today`）与"写成了清脏位"；拼行、落盘、
-- 出错记日志都在 `ledger.lua` 的 `M.save` 里。
local function save_ledger(nota)
  if not dirty or not today then
    return
  end
  if ledger.save(days, nota) then
    dirty = false
  end
end

--- 往今日那条记录里记一分钟。
local function add_minute(r, mn, n)
  if not r or n <= 0 then
    return
  end
  r.mins[mn] = (r.mins[mn] or 0) + n
  if not r.first or mn < r.first then
    r.first = mn
  end
  if not r.last or mn > r.last then
    r.last = mn
  end
end

--- 数一拍，够 `SAVE_EVERY` 拍就把账写回去一次。
-- ⚠️ 由**采样**数拍、不由时间数：这个插件没有 timer，唯一可靠的心跳就是"宿主又拉了一次
-- 面板"。代价是面板关着时不落盘——而那段时间本来也没有新账。
local function tick_save()
  ticks_since_save = ticks_since_save + 1
  if ticks_since_save >= SAVE_EVERY then
    ticks_since_save = 0
    save_ledger(saved_nota)
  end
end


--- 收一个采样点。**每一次 `render` 都调一次**，干什么由 `phase` 决定。
-- ⚠️ 只有 `running` 会累加，另外三个状态走同一句话：**只把基线挪到此刻**。
-- `minute_of_day` / `day_row` 可能是 `nil`（拿不到时间来源），那时**今日那本整个不记**
-- ——本轮照记不误，界面上也照旧，只是"今天"那一块不出现。
local function take_sample(now, words, path, minute_of_day, day_row)
  if phase ~= "running" then
    last_t, last_words, last_path = now, words, path
    return
  end

  -- 基线还没立（刚「开始」或刚「继续」）：这一枪只当起点。
  if last_t == nil then
    last_t, last_words, last_path = now, words, path
    return
  end

  -- ⚠️ 换文档 → **自动暂停**（不是终止）。理由在文件头"跑表在什么情况下自己停"。
  -- ⚠️ 这里**不去冻 `frozen_rate`**：它由 `panel_content` 每一枪更新，而"切走前那一刻"的读数上一枪就已经存进去了（见
  -- `frozen_rate` 那一段）。
  if last_path ~= path then
    phase = "paused"
    last_t, last_words, last_path = now, words, path
    return
  end

  local dt = now - last_t
  local add = words - last_words
  -- ⚠️ 这一分钟**在加 `dt` 之前**算：一次采样跨过分钟边界时，那点字算进**哪一分钟**本来就只能四舍五入。
  -- 取"这一枪落在哪一分钟"比取"这一枪之后落在哪一分钟"更贴，而且 1 秒一采的间隔下两种算法的差最多一分钟、只在边界上出现。
  local rel_min = math.floor(elapsed_ms / 60000)
  last_t = now
  last_words = words

  -- ⚠️ `dt <= 0` 是可能的（同一个毫秒里被拉两次），除法会炸出 inf。
  if dt <= 0 then
    return
  end
  -- 删字不算打字量：不能给负数，也不能让一次大删把平均速度拽下去。
  if add < 0 then
    add = 0
  end

  -- ⚠️ 这两行在断档分支**之上**：面板刚才没开着，用户也是真在写字，那段时间该进总数与时长。断档只影响"这一枪画不画到曲线上"。
  total_add = total_add + add
  elapsed_ms = elapsed_ms + dt

  -- 今日那本账的字数与时长也在这里（同一支代码、同一个条件）。
  -- ⚠️ 口径必须与本轮**完全一致**：不然"本轮 100 字"和"今天涨了 300 字"会让用户以为哪一个算错了（其实只是暂停期间打的字算不算的分歧）。
  if day_row then
    day_row.words = day_row.words + add
    day_row.ms = day_row.ms + dt
    dirty = true
  end

  -- 断档：中间那段没有采样点，画出来是一根假尖刺（五分钟的量算成"这一秒打了 300 个字"），峰值同理。所以只累加、不落点、不算峰值。
  if dt > GAP_MS then
    tick_save()
    return
  end

  table.insert(samples, { t = now, dt = dt, add = add })

  local rate = add * 60000 / dt
  if rate > peak_rate then
    peak_rate = rate
  end

  -- 本轮那本账：按"本轮第几分钟"落一格（分享图用 `samples` 画不了整轮，见 `round_mins`）。
  round_mins[rel_min] = (round_mins[rel_min] or 0) + add

  -- 今日那本账：峰值与分钟格。⚠️ 峰值与落点**都在断档那道闸之后**——断档那一段的"速度"是个假数（五分钟的量除以一秒），算进峰值就是撒谎。
  if day_row then
    if rate > day_row.peak then
      day_row.peak = rate
    end
    if minute_of_day then
      add_minute(day_row, minute_of_day, add)
    end
  end

  tick_save()

  -- 裁掉窗口外的老点。⚠️ 从**头**删（最旧的），所以那个 `while` 一次最多走一两轮。
  local from = now - KEEP_MS
  while #samples > 0 and samples[1].t < from do
    table.remove(samples, 1)
  end
end

--- 现在这个窗口有多长（毫秒）。
--
-- 用户 2026-10-04 要的就是这一格：**"统计某一个 Δt 内的打字数量"**，
-- Δt 在「设置 → 拓展」那一页上拖（宿主画的滑杆），默认 5 秒、1–60 秒。
--
-- ⚠️ **每一枪现读**（不缓存）：宿主写完设置会发一条"面板该重拉了"
-- （`commands/plugin.rs::nota_plugin_setting_set`），下一枪就该是新窗口——
-- 缓存的话用户拖完滑杆得等重启，而"拖了没反应"正是这一格最不该有的表现。
-- 读一次是一张 Lua 表里取一个键，比这一枪里画的那些东西便宜得多。
--
-- ⚠️ 外面来的数**一律不信**：设置文件用户可以直接拿编辑器改
-- （`lua/api/settings.rs` 文件头就是这么说的），写进去 `0` / `"五秒"` / `999`
-- 都不该让这一枪算出一个荒唐的除法。取不到就是默认 5 秒。
--
-- ⚠️ 用 `saved_nota` 而**不是** `panel_content` 那个参数：这一条要在 `card_ctx`
-- 里也被调到，而那张表是**不带参数**搭的（同 `save_ledger` 那几处）。
-- 老插件（api = 2 之前）没有 `nota.settings` 这一号对象，所以先问一句有没有。
local function window_ms()
  local n = nil
  if saved_nota and saved_nota.settings then
    n = saved_nota.settings.get("window_seconds")
  end
  if type(n) ~= "number" then
    n = DEFAULT_WINDOW_S
  end
  n = math.floor(n + 0.5)
  if n < MIN_WINDOW_S then
    n = MIN_WINDOW_S
  end
  if n > MAX_WINDOW_S then
    n = MAX_WINDOW_S
  end
  return n * 1000
end

--- 最近 Δt 秒的平均速度（字/分钟）。样本不够就返回 `nil`。
--
-- 口径：**把窗口里那几个采样点的字加起来、时长加起来，再折算成"每分钟多少字"**。
-- 窗口 5 秒时那是"最近 5 秒里打了多少字 ×12"——数还是每分钟的那个数，
-- 只是回看的这一段短得多、跳得多（用户要的就是这个：他要看**此刻**的手速，
-- 不是整整一分钟的平均）。
--
-- ⚠️ 窗口是**滑动**的、不是"最近第几个点"：`from = now - 窗`。一次采样跨过
-- 窗口边界时要么整段算进、要么整段不算，误差的上限是一个采样间隔（≈1 秒），
-- 而窗口最小就是 1 秒——所以最短那一档上这两种取法差得出来（0 个字与 1 个点）。
-- 不为此再做插值：**一个秒级的读数不值得为它发明一套半样本的算法**。
--
-- ⚠️ `nil` 与 0 是**两件事**：`nil` = "还没有结论"（画破折号），0 = "有结论、就是没在打"。
local function average_rate(now, win)
  local total, span = 0, 0
  local from = now - win
  for _, s in ipairs(samples) do
    if s.t >= from then
      total = total + s.add
      span = span + s.dt
    end
  end
  -- ⚠️ 够不够看**Δt 与 MIN_SPAN_MS 取小**：窗口比 10 秒短时，"攒够一整个窗口"
  -- 就是**已经回看满 Δt 秒**了（那时折算出来的数正是用户要的那个）；
  -- 拿 10 秒去卡的话，默认 5 秒档上大数字要空 10 秒才出数。
  local need = win
  if need > MIN_SPAN_MS then
    need = MIN_SPAN_MS
  end
  if span < need then
    return nil
  end
  return math.floor(total / span * 60000 + 0.5)
end

--- **整轮**的平均速度（字/分钟）。跑太短就返回 `nil`（理由同 `MIN_SPAN_MS`）。
-- ⚠️ 它**不看 `samples`**，看 `total_add` / `elapsed_ms`：`samples` 只留三分钟，拿它算
-- 整轮是错的。
local function round_rate()
  if elapsed_ms < MIN_SPAN_MS then
    return nil
  end
  return math.floor(total_add / elapsed_ms * 60000 + 0.5)
end

--- 给前端的那串点：每个采样一次，值 = 那一次的瞬时速度（字/分钟）。
local function plot_points()
  local out = {}
  local start = #samples - MAX_POINTS + 1
  if start < 1 then
    start = 1
  end
  for i = start, #samples do
    local s = samples[i]
    table.insert(out, s.add * 60000 / s.dt)
  end
  return out
end

--- 一段时长说成人话。
local function human_span(ms)
  if ms < 60000 then
    return string.format(T("%d s"), math.floor(ms / 1000))
  end
  return string.format(
    T("%d m %d s"),
    math.floor(ms / 60000),
    math.floor(ms % 60000 / 1000)
  )
end


-- ── 分享图与刻度 ─────────────────────────────────────────────────────────
--
-- ⚠️ **"数怎么写、刻度摆哪儿"那一半 2026-09-27 搬去了 `ticks.lua`**（`require`，插件
-- 多文件）：那几个是整份插件里唯一**不碰状态**的一截，搬走只为把这份文件压回 1000 行
-- 以内。下面几行是**转接**——名字和几十处调用点一个都没动，只是把"只有上家才知道"的
-- 两个口径（`MAX_POINTS`、`samples`）当参数递进去。
--
-- ⚠️ **2026-10-04 又搬了一次**：钮扣那一段（那颗开关的相位表、做分享图那三颗）、
-- 三张分享卡的字段、以及长期那块面板，一起去了 **`share.lua`**——理由同 `ticks.lua` /
-- `cards.lua`：Δt 窗口那一批把这份文件顶到 1065 行（硬上限 1000，`docs/09` §4）。
-- 它与 `cards.lua` 一样走**一张显式递进去的只读 `ctx` 表**（下面 `share_ctx`），
-- 而不是上值：`require` 是单向的，反过来引就是一个环。

local ticks = require("ticks")

-- ⚠️ **卡片与面板上凡是"多少个字"都走 `group_text`**（带千位分隔）：这份图上最大的
-- 那个数字和旁边三格小字如果一处带逗号、一处不带（`209,758` 与 `34225`），读起来像
-- 两个不同地方印出来的数。`ticks.lua` 那边的注释里写着为什么倒着插逗号。
local num_text, group_text = ticks.num_text, ticks.group_text

--- 摊点/画刻度时要带上"一份图最多几个点"（那个口径在上家）。
local function spread(mins, from_i, to_i)
  return ticks.spread(mins, from_i, to_i, MAX_POINTS)
end

-- ⚠️ 这里原本还有一个 `window_ticks`（把采样序列递进 `ticks.window_ticks` 去
-- 算横轴刻度），**2026-10-04 删了**：它唯一的用户是面板上那块独立的曲线
-- （`kind = "chart"`），而那块在同一天折进了记录卡里——卡里那条窄曲线没有刻度
-- （18px 的图上摆不下"第几分钟"）。`ticks.window_ticks` 也跟着一起删了。


-- ── 长期那本账（热力图，2026-09-27）──────────────────────────────────────
--
-- 用户：「加一个功能，类似 Contribution Graph 那样的热力图，记录长期数据。
-- 仅记录打字数。功能归属于心电图插件。」
--
-- ⚠️ **算的那一半在 `long.lua`**（`require`，插件多文件的第二个用户）：窗口怎么定、
-- 哪些天算数、那个字符串怎么拼——那几条是纯算术，只是要有人把账本递进去。
-- 这一行是**转接**：把"只有上家才知道"的两样（`days` 那本账、这一拍的 `nowinfo`）
-- 当参数递进去，名字与调用点一个都没动。

local long = require("long")

--- 这一拍那本长期账算出来的数（窗口、有字的天数、总字数…）。`long.lua` 一半的入口。
local function long_stats()
  return long.stats(days, nowinfo)
end

local share = require("share")

--- 一张"这一屏该摆什么"的表，给 `share.lua` 那几个函数读。
-- ⚠️ 同 `card_ctx`：里面**全是取值**（外加几个纯函数），那边一个字段都不往回写。
-- ⚠️ 每次要用现搭一张（面板一拍一张）：比一次 Lua 表构造的开销可以忽略，换来的是
-- "那几个函数到底认识哪几样东西"写在下面这二十来行上。
local function share_ctx()
  return {
    phase = phase,
    total_add = total_add,
    elapsed_ms = elapsed_ms,
    peak_rate = peak_rate,
    round_mins = round_mins,
    today = today,
    days = days,
    nowinfo = nowinfo,
    long = long,
    long_stats = long_stats,
    round_rate = round_rate,
    spread = spread,
    min_span_ms = MIN_SPAN_MS,
    num_text = num_text,
    group_text = group_text,
    -- 刻度那一批：只有分享图那几个函数要用，主文件这边一个都不用了，所以**不再**
    -- 在上头起别名，直接从 `ticks` 取（少一批只在两处之间转手的名字）。
    clock_span = ticks.clock_span,
    date_text = ticks.date_text,
    stamp_text = ticks.stamp_text,
    three_ticks = ticks.three_ticks,
    round_tick = ticks.round_tick,
    clock_tick = ticks.clock_tick,
    day_ticks = ticks.day_ticks,
    minor_per_gap = ticks.minor_per_gap,
  }
end


--- 此刻的**墙上时间**（本地时区）。拿不到就 `nil`。
-- ⚠️ `nil` 时**整套"今日"都不出现**，而不是显示一个假日期：一个会写错日期的账本比没有
-- 账本糟得多。⚠️ 能力上这条不会发生（`nota.time` 永远可用），但"拿不到就别说"与
-- `document.stats()` 那条同规矩——两处都 `pcall`。
local function wall_clock(nota)
  local ok, t = pcall(function()
    return nota.time.now()
  end)
  if not ok or type(t) ~= "table" then
    return nil
  end
  local ymd = tostring(t.ymd or "")
  if ymd == "" then
    return nil
  end
  local hh = tonumber(t.hh) or 0
  local mi = tonumber(t.mi) or 0
  return {
    ymd = ymd,
    y = tonumber(t.y) or 0,
    mo = tonumber(t.mo) or 0,
    d = tonumber(t.d) or 0,
    hh = hh,
    mi = mi,
    minute_of_day = hh * 60 + mi,
  }
end

-- ── ② 小字数据概览 与 ④ 记录卡（2026-10-04 加/改版）──────────────────────
--
-- 用户那天给了两张运动手表的截图当参考（「运动记录」那两屏），并定下版式：
-- **一条记录一个框**——左边一颗圆图标，右边一个大数 ＋ 一行小字；框底下那行是
-- 汇总。面板从那以后的四块是：
--
-- ```text
--   ① 热力图（长期那本账）        ← share.long_blocks()
--   ② 小字数据概览（本轮的细账）   ← cards.overview()
--   ③ 按钮（一颗开关 ＋「终止」）   ← BUTTONS
--   ④ 记录卡（本轮 / 今日 / 长期）  ← cards.record_cards() ＋ 底下那三颗分享按钮
-- ```
--
-- ⚠️ **画成什么样不在这边**：这里只给字段，框的圆角、图标、窄曲线全在
-- `src/ui/PanelBody.tsx`（`kind = "cards"`）——与分享图那条"插件说**什么**、
-- 宿主说**怎么显示**"是同一条规矩。
--
-- ⚠️ **三条记录的大字各是一个不同的东西**，这是有意的：本轮那头是**速度**
-- （用户第一句话就是「大红字数字/分钟」），今日与长期那两头是**字数**——它们是
-- "账"，不是"此刻多快"。把本轮也改成字数的话，这块面板上就再也没有"现在多快"了。
-- ⚠️ **这一段的内容 2026-10-04 搬去了 `cards.lua`**（`require`，同 `ticks.lua` /
-- `long.lua`）：这一批改完这份文件顶到了 1055 行（硬上限 1000，`docs/09` §4），而
-- "② 那三行小字 / ④ 那一串记录卡"是整份插件里唯一**不碰状态**的一截——搬它动不到
-- 任何一条时间线。下面这几行是**转接**：名字和调用点都还在，只是"这几个函数认识
-- 哪几样东西"换成了显式递进去的一张表（字段清单在 `cards.lua` 每个函数头上）。

local cards = require("cards")

--- 一张"这一拍怎么样"的表，给 `cards.lua` 那几个函数读。
-- ⚠️ 里面**全是取值**（外加几个纯函数）。`cards.lua` 往回写的话就成了藏在参数里的
-- 状态，那正是这一拆最不该引进来的东西——所以那边每个函数都是只读、只发字段。
local function card_ctx()
  return {
    phase = phase,
    round_words = total_add,
    elapsed_ms = elapsed_ms,
    peak_rate = peak_rate,
    round_mins = round_mins,
    spread = spread,
    plot = plot_points,
    -- ⚠️ 那个函数（在哪一分钟上）现在住在 `share.lua`：两边用的是**同一个**
    -- 实现，各算一遍的话会出现两个对不上的"这一轮到哪儿了"。
    last_minute = function() return share.round_last_minute(round_mins) end,
    span_text = human_span,
    num_text = num_text,
    group_text = group_text,
    long_stats = long_stats,
    -- ⚠️ 窗口（2026-10-04 加）是**设置**，不是本轮的账，但它必须摆到面板上：
    -- 用户在「设置 → 拓展」拖完那根滑杆，得**当场看得见生效了没有**——
    -- 不然拖完回面板，大数字还是老样子（窗口只影响它怎么算），
    -- 谁都会以为那颗滑杆坏了。摆在小字概览里当那个大数的旁注。
    window_s = window_ms() / 1000,
  }
end

--- 面板这一页此刻长什么样。**每次被拉都现跑一遍**，所以里面全是"现在怎么样"。
local function panel_content(nota)
  local ok, st = pcall(nota.document.stats)
  if not ok or type(st) ~= "table" then
    return {
      { kind = "empty", text = T("Can't read this document's length.") },
    }
  end

  local now = tonumber(st.clock_ms) or 0
  local words = tonumber(st.words) or 0
  local path = st.path or ""

  -- 这一拍的墙上时间（一次就够，同一拍里后面几处都用它，见 `nowinfo` 那段）。
  nowinfo = wall_clock(nota)
  local day_row = roll_day(nowinfo)

  -- ⚠️ 先采这一枪再画面板：屏幕上那个数必须是**含此刻**的。
  take_sample(now, words, path, nowinfo and nowinfo.minute_of_day or nil, day_row)

  -- `share.lua` 那几个函数要读的东西，这一拍搭一张（字段清单见 `share_ctx`）。
  -- ⚠️ 摆在**分享那一屏之前**：那一屏也要用（三张卡与那几颗按钮都在 `share.lua`）。
  local sx = share_ctx()

  -- 分享那一屏：**盖在 `phase` 上面**，`phase` 一动不动（`share_scope` 那段）。
  if share_scope then
    -- ⚠️ 落一次盘再画：卡片上的数是内存里那份（已经是最新的），但"关掉 Nota之前最后一眼看到的图"和"重启之后账上有的数"该是同一份。
    save_ledger(nota)
    local card
    if share_scope == "round" then
      card = share.round_card(sx)
    elseif share_scope == "day" then
      card = share.day_card(sx)
    else
      local st = long_stats()
      card = st and share.long_card(sx, st) or nil
    end
    -- ⚠️ 拿不到日期时（`nota.time` 那一跳失败）**不留一块空白**：说一句为什么。
    if not card then
      return {
        { kind = "text", text = T("Can't read today's date, so the long-term ledger can't be drawn.") },
        { kind = "buttons", items = share.buttons_for(sx, "share") },
      }
    end
    return {
      card,
      { kind = "buttons", items = share.buttons_for(sx, "share") },
      {
        kind = "text",
        tone = "muted",
        text = T("The two buttons under the card: save it as a PNG, or copy it to the clipboard."),
      },
    }
  end

  -- 面板的四块（顺序与出处见上面那段长注释）。⚠️ 每一块都**按需**：
  -- 空的那一块一个块都不发，而不是发一块空的。
  local out = {}

  -- `cards.lua` 那几个函数要读的东西，这一拍搭一张（字段清单见 `card_ctx`）。
  local cx = card_ctx()

  -- ① 长期那本账（热力图 ＋ 一句人话）。**没有账就一个块都不给**。
  for _, b in ipairs(share.long_blocks(sx)) do
    table.insert(out, b)
  end

  -- 这一拍那个速度读数（`record_cards` 要用，也是"冻结"那个口径唯一的算处）。
  -- 大数字：跑着/暂停看"最近 Δt 秒"，终止之后看"整轮"（表在文件头）。
  -- ⚠️⚠️ **暂停那一支必须直接用 `frozen_rate`，不能再算一遍**——理由与实测见
  -- `docs/13` §14.4「冻结」：写成"算出来不是 nil 就用算的"等于没冻。
  local shown = nil
  if phase == "done" then
    shown = round_rate()
  elseif phase == "paused" then
    shown = frozen_rate
  elseif phase == "running" then
    -- ⚠️ 窗口**每一枪现读**（用户在设置页拖一下，这一枪就该按新窗口算）。
    local live = average_rate(now, window_ms())
    if live then
      frozen_rate = live
    end
    shown = live or frozen_rate
  end

  -- ② 小字数据概览（本轮的细账）。
  -- ⚠️⚠️ **四个相位都摆**（2026-10-07 改）：用户原话「默认手表界面哦」——面板一打开
  -- 就该是运动手表那块表盘的样子，只是"还没开始"时这些数全是 0。改之前这里是一个
  -- `if phase == "idle"` 把这一整块跳过去（那一屏只有一句说明 ＋ 一颗按钮），
  -- 屏幕上完全看不出这块面板是干什么的。
  out[#out + 1] = { kind = "fields", items = cards.overview(cx) }

  -- ⚠️ idle 那一句说明**留着**：这一屏唯一该传达的事仍然是"按那颗按钮"，而按钮就在
  -- 下面一行。取消的是"看不出这块面板是干什么的"，不是"不用告诉用户怎么开始"。
  if phase == "idle" then
    out[#out + 1] = {
      kind = "text",
      text = T("Not started yet. Press “Start” and this round will count how much you write, how long it takes, and how fast you go."),
    }
  elseif phase == "paused" then
    -- ⚠️ 暂停那一句**只在"真暂停"时说**。自动暂停（换文档）也走这里，所以那句话要把两种来
    -- 路都讲清楚，否则用户会以为自己没按过什么、怎么就停了。
    -- ⚠️ 结算那一句（原来那句"这一轮你写下了 N 字"）**2026-10-04 删了**：记录卡上
    -- 本轮那条的小字里已经写着"本轮 · N 字 · 时长"，同一件事说两遍。
    out[#out + 1] = {
      kind = "text",
      text = T("Paused. Anything you type now doesn't count toward this round — press “Resume” to continue."),
    }
  end

  -- ③ 按钮：一颗开关（开始/暂停/继续/再来一轮）＋ 那颗不可逆的「终止」。
  out[#out + 1] = { kind = "buttons", items = share.buttons_for(sx, phase) }

  -- ④ 记录卡（本轮 / 今日 / 长期）。⚠️ **这一块永远发**（`cards.record_cards` 保证），
  -- 因为底下那行汇总「整篇文档」在任何一屏都得在；**本轮那条也永远在**
  -- （2026-10-07 起 idle 也画，见 `cards.lua` 里那段）。
  local record = cards.record_cards(cx, shown, words, day_row)
  out[#out + 1] = record

  -- 记录卡底下那三颗「做分享图」。⚠️ 一颗都发不出去（没东西可分享）就整块不发。
  local shares = share.share_buttons(sx)
  if #shares > 0 then
    out[#out + 1] = { kind = "buttons", items = shares }
  end

  -- ⚠️ 这一行是**必要的诚实**：不写它，用户切走半小时再回来会看到一条空曲线，而面板上没
  -- 有任何东西解释那一段为什么是空的。
  out[#out + 1] = { kind = "text", tone = "muted", text = T("Only recorded while this panel is open.") }

  return out
end

--- 插件加载。
function M.on_load(nota)
  -- ⚠️ **第一件事**：把文案取用器接到宿主给的这份表上（上面 `local T` 那段）。
  T = function(fmt, ...)
    local s = nota.i18n and nota.i18n.text(fmt) or nil
    s = s or fmt
    if select("#", ...) > 0 then
      return string.format(s, ...)
    end
    return s
  end
  -- ⚠️ **第二件事**：把同一个取用器交给 `ticks.lua` / `long.lua` / `cards.lua` /
  -- `share.lua`（它们各自那份 `T` 还是个原样返回的桩）。
  ticks.bind_text(T)
  long.bind_text(T)
  cards.bind_text(T)
  share.bind_text(T)

-- 留一份 `nota` 给 `on_unload`（宿主调它时**不传参**），然后读回今日那本账。
-- ⚠️ **今天那条记录不在这里建**：那要问一次 `nota.time`，而"现在几点"每一拍都会重新问
-- （`panel_content` 里那一次）——多问一次就是同一件事有两个时点，跨零点会打架。
-- ⚠️ 读账**静默失败**：一个插件不该因为自己的缓存读不出来而挡住面板。
  saved_nota = nota
  load_ledger(nota)

-- ⚠️ 四个状态各一条**显式**命令，不做"一个按钮三副面孔"的开关式命令：面板上的 `command`
-- 是写死的四个串，状态判断全在插件这边，前端一个 `if` 都不用加。
-- ⚠️ 每一条都返回 `{ ok = … }`（与 `plugins/slidev` 一致）：前端不看它，但出错要能冒出来。
  nota.command.register("start", function()
    reset_round()
    phase = "running"
    -- 今日那本账：轮数 +1（**起点算**：一轮开出去就算今天开过，中途崩了也认）。
    -- ⚠️ 顺手落一次盘，免得接下来那半分钟里应用被关掉。
    if today then
      today.rounds = today.rounds + 1
      dirty = true
      save_ledger(nota)
    end
    -- ⚠️ 基线留空，交给下一枪去立：命令这一侧**没有** `clock_ms`（那是 `document.stats()`
    -- 给的），代价是最多晚一秒开始算——正好是心跳的间隔。
    nota.ui.refresh(PANEL_ID)
    return { ok = true, phase = phase }
  end)

  nota.command.register("pause", function()
    if phase == "running" then
      phase = "paused"
    end
    nota.ui.refresh(PANEL_ID)
    return { ok = true, phase = phase }
  end)

  nota.command.register("resume", function()
    if phase == "paused" then
      phase = "running"
      -- 与「开始」同理：基线留空，下一枪重新立。
      -- ⚠️ 这一句就是"暂停期间打的字不算"的落点——重新立基线用的是**那一刻**的 `words`，
      -- 暂停那一段的增量就此落在基线之外。
      last_t = nil
      -- ⚠️⚠️ **旧的冻结值就地作废**（2026-10-04 开窗目检抓到的，见 `docs/06` §5.29b）。
      -- `frozen_rate` 是**暂停那一屏**的东西；继续之后它属于上一段。
      -- 不清的话：刚「继续」时样本还没攒够 `MIN_SPAN_MS`（10 秒），`average_rate` 返回
      -- `nil`，而 `shown = live or frozen_rate` 会拿它兜底——于是**明明在打字**，卡上的
      -- 大数却是暂停前那个读数（实测那天是 `0 字/分钟`，最误导的一种）。
      -- ⚠️ 「开始」那一支靠 `reset_round()` 早就清了同一个值，**只有这里漏了**——
      -- 两颗按钮通向同一个 `running` 屏，屏幕上的数就该是同一个来路。
      frozen_rate = nil
    end
    nota.ui.refresh(PANEL_ID)
    return { ok = true, phase = phase }
  end)

  nota.command.register("stop", function()
    -- ⚠️ 这里**只改状态，不结算**：`total_add` / `elapsed_ms` / `peak_rate` 在 `done` 下不
    -- 再被任何一支累加，所以它们**自己就是那份结算**——另存一份只会多一处对不上。
    if phase == "running" or phase == "paused" then
      phase = "done"
    end
    -- 一轮结束 = 今日那本账最该落盘的一刻（用户很可能接下来就关应用看分享图去了）。
    save_ledger(nota)
    nota.ui.refresh(PANEL_ID)
    return { ok = true, phase = phase }
  end)

-- 分享那三颗：`share_round` / `share_day` 只是**切一屏**，`share_close` 关掉它。
-- ⚠️ 它们**不读账、也不算数**——那一屏要的字段在 `panel_content` 里每一拍现算，命令这一
-- 侧只挪一下 `share_scope`：少一处"另一份结算"就少一处对不上的可能。
  nota.command.register("share_round", function()
    if share.can_share(share_ctx(), "round") then
      share_scope = "round"
    end
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("share_day", function()
    if share.can_share(share_ctx(), "day") then
      share_scope = "day"
    end
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("share_long", function()
    if share.can_share(share_ctx(), "long") then
      share_scope = "long"
    end
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.command.register("share_close", function()
    share_scope = nil
    nota.ui.refresh(PANEL_ID)
    return { ok = true }
  end)

  nota.ui.register_panel({
    id = PANEL_ID,
    title = T("Writing Stats"),
    -- 右侧插件栏（默认值，写出来是为了让人一眼看到）。
    location = "right",
    -- ⚠️ **这一行就是"实时"的全部来源**：宿主看到它才会每秒喊一次"该重拉了"，删掉它这块
    -- 面板就退化成"切过去才拉一次"。⚠️ 代价：`render` 会**每秒跑一遍**，所以里面只能有内存
    -- 里的加减乘除（要加子进程或网络请求，先回来看这一行）。
    live = true,
    render = function()
      return panel_content(nota)
    end,
  })
end

--- 插件卸载（停用、重装、退出应用）。**最后一枪落盘**。
-- ⚠️ 这是"今日那本账"不丢的唯一保险：正常退出走这里，崩溃/强杀走不到——那时最多丢
-- `SAVE_EVERY` 秒（30 秒）的账，这是刻意接受的代价。⚠️ 出错只记日志，卸载流程不该被一个
-- 插件的残骸卡住。
function M.on_unload()
  save_ledger(saved_nota)
end

return M
