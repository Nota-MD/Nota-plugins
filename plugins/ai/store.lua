-- 对话**落盘**：一份自己定的行格式，加编码解码（`docs/07` 第 57 项）。
--
-- 从前对话只在内存里（`chat.lua` 的 `chats`），关掉应用就没了。这一份把它存下来。
--
-- # 落在哪儿：`nota.data`（**不是** `nota.settings`）
--
-- 第 57 项原来记的是"走插件自己的设置段"。那条写于 2026-09-25，而**两天后
-- （2026-09-27）宿主加了 `nota.data`**：`~/.local/share/nota/plugin-data/<id>/`
-- 下面一串**属于这个插件的文本文件**，写是原子的，上限 1 MiB。
--
-- `data.rs` 的文件头把这两样东西的分工写死了，而且举的**就是这一种例子**：
--
-- > `nota.settings` 那是**设置**……能存的类型故意很小——文本、数字、布尔。
-- > 而一条写作记录天然是**一串**记录，拿设置文件当数据库用就把它变成了一个
-- > 没有 schema 的 blob。
--
-- 一份聊天记录正是"一串记录"，所以落点改成 `nota.data`。**顺带少两样麻烦**：
-- 不必把 JSON 塞进 TOML 字符串里（换行、引号、控制字符三层转义），
-- 也不会让用户手改密钥的那个文件里多出一大坨看不懂的东西。
--
-- ⚠️ 这是**有意的偏离**，记在 `docs/07` 第 57 项那一行里。
--
-- # 格式
--
-- ```text
-- nota-ai-chats/1
-- chat <编号> <开着吗> <标题>
-- msg <角色> <正文>
-- chat 2 1 另一段对话
-- msg user 帮我把这段润色一下
-- ```
--
-- 一行一条记录、字段用空格分（**正文永远是最后一个字段**，所以它里面的空格
-- 不用管）。正文里的换行 / 回车 / 反斜杠先编码掉，见 `enc` / `dec`。
--
-- ⚠️ **第一行是版本号**，而且**认不出就整份丢掉**（`load` 里那条）。理由：
-- 格式将来会变，而"半懂不懂地读进来"比"读不进来"坏得多——后者用户看得见
-- （对话没了，他知道出事了），前者是把一份读歪的记录摆在他面前。
-- 这一条与宿主那几条"认不出就当空"的口径一致（`plugin.toml` 的 `api` 那一条）。
--
-- # ⚠️ 不存的：待应用的改动（`patch`）
--
-- 它是一份**等着用户点头**的临时状态，而且它的 `-` 行必须与**此刻**的文档
-- 逐字一致。存下来、下次开应用再画出来，那份改动多半已经对不上文档了，
-- 而"应用"只会报一句"没找到"。那种账不值得记。
--
-- ⚠️ 变量名一律 ASCII（理由写在 `main.lua` 文件头）。

local util = require("util")

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────
-- 每个模块各有一份 `T`，都由 `main.lua` 的 `on_load` 接上（见 `util.lua` 文件头）。
local T = function(s) return s end

--- 把文案取词器接上宿主（由 `main.lua` 的 `on_load` 调）。
function M.bind_text(f)
  T = f
end

-- ── 参数 ──────────────────────────────────────────────────────────────────

--- 存盘文件的名字（`nota.data` 的命名规矩：ASCII、不含分隔符）。
local FILE = "chats.txt"

--- 格式版本。**第一行就是它**，改了格式就改这里。
local VERSION = "nota-ai-chats/1"

--- 一个对话最多存多少条消息（从最旧的开始丢）。
---
--- ⚠️ 有上限的理由是 `nota.data` 的 1 MiB：聊天记录是会长的东西，而超了那次
--- 写盘会**整个失败**（宿主报错），那就成了"越聊越存不上"。压在一个稳当的
--- 条数下面，超了丢最旧的——用户在面板上本来也只看得见最近 8 条。
M.MSGS_MAX = 200

-- ── 编码 ──────────────────────────────────────────────────────────────────
--
-- 正文里可能有换行，而**一行就是一条记录**，所以换行必须编码掉。
-- 反斜杠自己**先**编（不然下一步产出的那个反斜杠会被再编一次），
-- 解码是**一趟扫完**（不能分三次 `gsub`：`\\n` 这种序列会被后一趟读错）。

--- 编码成一行：反斜杠 → `\\`，换行 → `\n`，回车 → `\r`。
function M.enc(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, "\n", "\\n")
  s = string.gsub(s, "\r", "\\r")
  return s
end

--- `enc` 的反面。认不出的转义（`\q`）原样留着——丢了那个反斜杠就再也还原不回来。
function M.dec(s)
  return (string.gsub(s, "\\(.)", function(c)
    if c == "n" then
      return "\n"
    elseif c == "r" then
      return "\r"
    elseif c == "\\" then
      return "\\"
    end
    return "\\" .. c
  end))
end

-- ── 落盘格式 ──────────────────────────────────────────────────────────────

--- 把一串对话编成要写进文件的那一整段文本。
---
--- ⚠️ 收的是**一串表**（`{id, open, title, msgs}`），不是 `chat.lua` 里那份
--- 状态表本身——这一份不认识"当前是第几个"之类的东西，它只搬字符串
--- （依赖方向见 `util.lua` 文件头）。
function M.encode(chats)
  local lines = { VERSION }
  for _, c in ipairs(chats) do
    lines[#lines + 1] = string.format("chat %d %d %s", c.id, c.open and 1 or 0, M.enc(c.title))
    local from = math.max(1, #c.msgs - M.MSGS_MAX + 1)
    for i = from, #c.msgs do
      local m = c.msgs[i]
      lines[#lines + 1] = string.format("msg %s %s", m.role, M.enc(m.text))
    end
  end
  -- ⚠️ 末尾补一个换行：不补的话最后一行与"文件被截断"看起来一模一样。
  return table.concat(lines, "\n") .. "\n"
end

--- 反过来：一段文本 → `{ {id, open, title, msgs}, … }`。
---
--- 读不懂就返回**空表**（调用方自己决定是"一个新对话都没有"还是"用默认的"），
--- 版本对不上也返回空表（理由见文件头）。
function M.decode(text)
  local chats = {}
  local cur = nil
  local first = true

  -- ⚠️ 逐行**的写法**：先补一个换行，再按"非贪婪 + 换行"取。
  -- 写成 `gmatch("([^\n]*)\n?")` 也能跑，但那个模式**能匹配空串**——
  -- 靠 `gmatch` 自己对空匹配的让步才不转圈，读的人得想一下才敢确定它会不会死循环。
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if first then
      if line ~= VERSION then
        return {}
      end
      first = false
    elseif line ~= "" then
      local id, open, title = string.match(line, "^chat (%d+) (%d+) (.*)$")
      if id then
        cur = { id = tonumber(id), open = (open == "1"), title = M.dec(title), msgs = {} }
        chats[#chats + 1] = cur
      else
        local role, body = string.match(line, "^msg (%a+) (.*)$")
        -- ⚠️ 没有 `cur` 的 `msg` **丢掉**：那是半份坏文件，硬塞进上一个对话里
        -- 只会让用户看到一段不属于那儿的对话。
        if role and cur then
          cur.msgs[#cur.msgs + 1] = { role = role, text = M.dec(body) }
        end
      end
    end
  end

  return chats
end

-- ── 读写 ──────────────────────────────────────────────────────────────────

--- `nota.data` 一次能写多少字节（`lua/api/data.rs::上限字节`）。
---
--- ⚠️ **常量名别照抄成中文**：这是 Lua，标识符只认 ASCII（`main.lua` 文件头那条）。
--- 上面那个 `上限字节` 是 **Rust 那边的**名字，这里只写在注释里指路。
---
--- ⚠️ 抄一份在插件里是**不得不**：超了那次写盘会**整个失败**，而"下次开会话
--- 时读到一份超限的文件"更糟——`nota.data.read` 也会拒，于是整份记录读不回来，
--- 用户看到的是**所有对话一夜之间全没了**。所以这一份拷贝是拿来**事先算**的，
--- 不是拿来事后补救的。宿主那边改了数，这里要跟着改（`docs/07` 第 57 项记着）。
local LIMIT_BYTES = 1024 * 1024

--- 把这一串对话写进插件自己的那个文件。
---
--- 返回 `true`、或者 `true, 丢掉了几个`、或者 `nil, 原因`。
---
--- # ⚠️ 装不下时它会**改动传进来的那张表**（从最旧的对话开始丢）
---
--- 见 `上限字节` 那条：写超限是**整个失败**，读超限是**整个读不回来**。两个都不行，
--- 所以这里自己先量一遍，超了就把最旧的对话整个丢掉再量——**留得住最近的，
--- 丢得掉最远的**，丢几个如实报给调用方去说一声。
---
--- ⚠️ 丢的时候是**那张表本身**，不是一份副本：副本的话，内存里留着的那几段
--- 下次存盘又会冒出来再被丢一遍，而调用方的 `cur`（当前是第几个）会随着
--- 每次存盘漂一次。**只有一份账**，调用方按返回的那个数去挪 `cur`。
---
--- ⚠️ 为什么不丢"每个对话最旧的消息"：那样每个对话都变得七零八落，而用户
--- 回头看的时候**分不清"这段本来就短"和"它被削过"**。整个对话地丢，
--- 用户看到的是"最早那几段不在了"——一件能理解、也能自己处理的事。
---
--- ⚠️ 至少留一个对话：一个都不剩的话，用户下次开应用看到的是"没有对话"，
--- 而那不是"存不下"的合理后果。剩下的那一个自己也可能超限——那就让它超，
--- 宿主会报错，调用方会说一句，用户能自己去删消息（那是他的记录）。
---
--- ⚠️ **不抛错**：调用点在"每改一次状态就存一次"上，一次写盘失败把整条命令
--- 带崩（用户会觉得"点了一下什么都没发生"）比"存不上"更糟。失败会在面板上
--- 留一句，见 `chat.lua::touch`。
function M.save(nota, chats)
  if not (nota.data and nota.data.write) then
    return nil, T("This host build has no nota.data; chats will not be kept after you quit.")
  end

  local dropped = 0
  local text = M.encode(chats)
  while #text > LIMIT_BYTES and #chats > 1 do
    table.remove(chats, 1)
    dropped = dropped + 1
    text = M.encode(chats)
  end

  local ok, err = pcall(function()
    nota.data.write(FILE, text)
  end)
  if not ok then
    return nil, util.clean_error(err)
  end
  return true, dropped
end

--- 读回来。**读不到 / 读不懂都给空表**（不是错误）：第一次用这个插件时
--- 那个文件根本不存在，而那不是故障。
---
--- ⚠️ 返回**空的 `{}`**，与"读出一份坏文件"用同一个值。分不开是有意的：
--- 两种情况的处理都是"当作没有对话"，多一个返回值只会让调用点多一个分支。
function M.load(nota)
  if not (nota.data and nota.data.read) then
    return {}
  end
  local ok, text = pcall(function()
    return nota.data.read(FILE)
  end)
  if not ok or type(text) ~= "string" or text == "" then
    return {}
  end
  return M.decode(text)
end

return M
