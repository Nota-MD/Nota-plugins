-- 今日那本账的**文件格式**：怎么读、怎么写、哪天该丢（2026-09-27 从 `main.lua` 拆出来）。
--
-- 拆它的理由只有**行数**一条，但是硬的：长期那块并进去之后 `main.lua` 顶到 1033
-- 行，而本仓 `.lua` 的硬上限是 1000（`docs/09` §4）。`require` 这条路是
-- `ticks.lua` 先蹚出来的（插件多文件，`docs/12` §5.9）——这一份是**第三个**用户。
--
-- ⚠️ 切在哪一刀是**按"认不认识状态"**切的，不是按长短：
--
--   * 这一份**不认识 `days`**——那本账整个由调用方传进来（`M.load(days, …)`）；
--     它也**不认识 `today` / `dirty`**，更不问 `nota.time`。"写完之后脏位清不清"
--     是调用方的事（`M.save` 只回一句"写成了没有"）。
--   * 留在 `main.lua` 的是状态本身：`days` / `today` / `dirty`，以及翻页
--     （`roll_day` 要动 `today`，而 `today` 是"此刻在记的那一条"）。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里**（同 `main.lua` 顶上
-- 那一条）：Lua 的标识符不许有非 ASCII 字符，写了是**语法错误**，症状是整份插件
-- 加载失败、面板和菜单一起消失。
--
-- ⚠️ 这一份**不给 `T` 留口子**：它一个字都不给用户看（只有失败时一行
-- `nota.log.warn`，那是日志不是界面），所以不需要 `bind_text` 那一套。

local M = {}

-- 磁盘上那个文件名。**ASCII**：`nota.data` 只收 ASCII 名字（见 `lua/api/data.rs`）。
local LEDGER = "days.txt"

-- 账本留几天：**两种行分开算**（2026-09-27 起）。
--
-- 在这之前是"整天留 7 天"，因为那时账本只服务"今天"与"这一轮"。热力图要的是
-- **长期**（用户原话：「记录长期数据」），所以日账那一行要留得久——一年出头。
--
-- ⚠️ 分的依据是**行有多胖**：一天一行 `d`（几十字节，400 天也就十几 KB），而
-- 一天最多 1440 行 `m`（一分钟一行，7 天封顶一百多 KB）。两个上限合起来仍然
-- 远在 `nota.data` 的 1 MiB 之下。
-- ⚠️ 超过 `KEEP_MIN_ROWS` 的那些天**只丢分钟账、不丢日账**：面板上那条曲线与
-- "今日"要的是一天里的分钟，而热力图要的是"那一天一共写了多少字"——后者在 `d` 行里。
local KEEP_DAY_ROWS = 400
local KEEP_MIN_ROWS = 7

--- 一条空记录。
function M.new_day(ymd)
  return { ymd = ymd, words = 0, ms = 0, peak = 0, rounds = 0, mins = {} }
end

--- 从稀疏的分钟账里补出"第一次写"与"最后一次写"（都是当天第几分钟）。
--- ⚠️ 这两个数**不进文件**：它们是分钟账的函数，存两份就会有一天对不上。
function M.fill_bounds(r)
  r.first, r.last = nil, nil
  for mi in pairs(r.mins) do
    if not r.first or mi < r.first then r.first = mi end
    if not r.last or mi > r.last then r.last = mi end
  end
end

--- 超过「留几天」的老账删掉。`ymd` 是 `2026-09-27` 这种定宽串，**字典序就是时间序**。
-- ⚠️ 它必须在 `M.load` **前面**（Lua 是先声明后使用）：看成一个没声明的名字就是一次
-- "调用 nil"——症状是**读得回账的人反而加载不了插件**（空账的人一切正常，所以开发机上不会冒出来）。
--
-- 两刀，见上面那两个常量：整条丢掉的是最老的那几天（超过 `KEEP_DAY_ROWS`），
-- 只丢**分钟账**的是再往前那些天（超过 `KEEP_MIN_ROWS`）。
function M.prune(days)
  local keys = {}
  for ymd in pairs(days) do
    table.insert(keys, ymd)
  end
  table.sort(keys)
  while #keys > KEEP_DAY_ROWS do
    days[table.remove(keys, 1)] = nil
  end
  -- ⚠️ 从**最老**那头往后数（`keys` 是升序），数到剩下 `KEEP_MIN_ROWS` 天为止。
  for i = 1, #keys - KEEP_MIN_ROWS do
    local r = days[keys[i]]
    -- ⚠️ 顺手把 `first` / `last` 也抹掉：那两个数是分钟账的函数（`fill_bounds`），
    -- 分钟账没了它们就成了**没有来源的数**，留着只会让人以为那一天还有分钟账。
    if r and (next(r.mins) ~= nil or r.first) then
      r.mins = {}
      r.first, r.last = nil, nil
    end
  end
end

--- 读回账本。**读不动就当没有**（不报错、不半读）。
--
-- ⚠️ 三条"不认"的判据都是刻意的：头一行不是 `v1`（版本比这个插件新）、单个数读不出来、日期串不成形。半读出来的账是**数对不上**的账，而"今天的账少了
-- 300 字"没有任何线索可查——宁可当作今天从头开始。
function M.load(days, nota)
  local ok, text = pcall(function()
    return nota.data.read(LEDGER)
  end)
  if not ok or type(text) ~= "string" then
    return
  end

  local saw_version = false
  for lines in text:gmatch("[^\n]+") do
    if lines == "v1" then
      saw_version = true
    elseif not saw_version then
      return
    else
      local kind, rest = lines:match("^(%a+) (.+)$")
      if kind == "d" then
        local ymd, c, ms, pk, rd = rest:match("^(%S+) (%d+) (%d+) (%d+) (%d+)$")
        if ymd then
          days[ymd] = {
            ymd = ymd,
            words = tonumber(c),
            ms = tonumber(ms),
            peak = tonumber(pk),
            rounds = tonumber(rd),
            mins = {},
          }
        end
      elseif kind == "m" then
        local ymd, mi, c = rest:match("^(%S+) (%d+) (%d+)$")
        local r = ymd and days[ymd]
        -- ⚠️ `m` 行认不出所属的那一天就丢掉：凭空造一条只有分钟账、却没有总数的记录，会让"今天写了 0 字"和一条曲线同时出现在面板上。
        if r then
          r.mins[tonumber(mi)] = tonumber(c)
        end
      end
    end
  end

  for _, r in pairs(days) do
    M.fill_bounds(r)
  end
  M.prune(days)
end

--- 把账写回磁盘，成了回 `true`。**要不要写**由调用方判（脏位在那一侧）。
function M.save(days, nota)
  if not nota then
    return false
  end

  local keys = {}
  for ymd in pairs(days) do
    table.insert(keys, ymd)
  end
  table.sort(keys)
  local lines = { "v1" }
  for _, ymd in ipairs(keys) do
    local r = days[ymd]
    table.insert(
      lines,
      string.format("d %s %d %d %d %d", r.ymd, r.words, r.ms, math.floor(r.peak + 0.5), r.rounds)
    )
    local mn = {}
    for mi in pairs(r.mins) do
      table.insert(mn, mi)
    end
    table.sort(mn)
    for _, mi in ipairs(mn) do
      table.insert(lines, string.format("m %s %d %d", r.ymd, mi, r.mins[mi]))
    end
  end

  local ok, err = pcall(function()
    return nota.data.write(LEDGER, table.concat(lines, "\n") .. "\n")
  end)
  if ok then
    return true
  end
  -- ⚠️ 写不出去**不是**这一屏的事：面板照旧显示内存里那份账（它是对的），只是重启之后会少一截。所以记一行日志、不弹通知。
  nota.log.warn("今日的账没能写回磁盘：" .. tostring(err))
  return false
end

return M
