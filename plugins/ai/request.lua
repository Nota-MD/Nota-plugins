-- AI 助手插件的**发请求那一半**：整段收、流式收、以及"这一轮走哪条路"。
--
-- 2026-10-04 从 `chat.lua` 按功能拆出来（那一份当时 977 行，离 1000 那条硬线
-- 只剩 23 行——`docs/07` 第 58 项那批代码就是压上去的）。
--
-- 拆的线是「**会不会发 HTTP**」：
--
-- | 文件 | 管什么 |
-- |---|---|
-- | `util.lua` | 公共词汇：设置项的键、`read_setting` / `clean_error` / `now_ms` |
-- | **本文件** `request.lua` | 发一次请求：组规格、两道围栏、整段/流式两条路、解回包 |
-- | `chat.lua` | 对话状态（`chats` / `cur` / `next_id`）、`M.send`、改动块的解析与应用、几条改状态的命令 |
-- | `store.lua` | 对话落盘（`nota.data`） |
-- | `scope.lua` | 「AI 可读的文件」 |
-- | `panel.lua` | 把对话画成右侧栏那一列内容块（**只读**） |
-- | `main.lua` | 插件外壳：`on_load` / 命令注册 / 菜单与面板声明 |
--
-- ⚠️ **依赖方向还是单向的**：`chat` → `request` → `util`。`request` **不认识对话**
-- ——它收下的是一张"发给模型的消息表"和一串要拼进去的 `messages`，回来的是一段
-- 回答。谁在跟谁说话、说完了落哪儿，都是 `chat.lua` 的事。
--
-- ⚠️ 为什么要拆：`docs/09` §4 那条 300–800 行。拆的位置不是"随便对半切"，
-- 是**这一份单独拿出去也能讲通**（"怎么跟一个 OpenAI 兼容接口说话"），
-- 而 `chat.lua` 剩下的那一半也讲得通（"一个对话里有什么、怎么存"）。
--
-- ⚠️ `T` 也要 `bind_text`（`main.lua` 的 `on_load` 里那一句），理由见 `util.lua` 文件头。
-- ⚠️ 变量名一律 ASCII（理由写在 `main.lua` 文件头）：中文标识符是 Lua 的语法错误。

local util = require("util")

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────
-- 每个模块各有一份 `T`，都由 `main.lua` 的 `on_load` 接上（见 `util.lua` 文件头）。
local T = function(s) return s end

--- 把文案取词器接上宿主（由 `main.lua` 的 `on_load` 调）。
function M.bind_text(f)
  T = f
end

-- ── 上限 ──────────────────────────────────────────────────────────────────

--- 流式那条路上，两次往面板推字之间**至少**隔多少毫秒（`docs/07` 第 58 项）。
---
--- ⚠️ 为什么**必须**有这个：模型是一个字一个字吐的，一个 2000 字的回答会有
--- 上千个 `delta`。一个 `delta` 推一次，就是上千次跨进程事件——面板会卡，
--- 而且卡得莫名其妙（用户看到的是"Nota 变慢了"，不是" AI 插件在刷屏"）。
--- 80 毫秒大约一秒 12 次，肉眼就是"一行一行往外冒"。
---
--- ⚠️ 计时用的是**墙钟**（`util.now_ms`），不是累加：宿主那边每次事件都带
--- 全文，推的间隔偶尔不均匀完全没关系——**丢一次推不影响最终结果**
---（收工时面板会拉一次真的内容，见 `chat.lua::M.send` 末尾）。
local STREAM_PUSH_MS = 80

-- ── 请求 ──────────────────────────────────────────────────────────────────
--
-- # ⚠️ 两条路，一条整段、一条流式（2026-10-04 加，`docs/07` 第 58 项）
--
-- | 路 | 怎么走 | 什么时候走 |
-- |---|---|---|
-- | **整段**（`request`） | 一次 POST，等整份回应到齐 | 流式关着，或者流式那条**根本没通** |
-- | **流式**（`stream_request`） | `nota.http.stream`，边收边把字推给面板 | 用户在设置里开着（默认开） |
--
-- ⚠️ **两条路的输出形状完全一样**（`{ok, text}` / `{ok=false, error}`），
-- 所以 `chat.lua::M.send` 那边不需要知道走的是哪条——判断只在 `M.ask` 里做一次。
--
-- ⚠️ 为什么要**自动退回**整段（`M.ask` 里那三行）：`stream = true` 是写在请求体
-- 里的一个**请求**，不是一条保证。自建服务、网关、老接口都可能直接忽略它、
-- 回一份普通的整段 JSON。那种情况下用户该看到的是"没有边打边出"，**不是**
-- 一条他没法处理的报错——所以一个字都没收到时照旧整段要一次。
-- 反过来，**收到过字就不退回**：那是"答到一半断了"，再发一次会把同一段话
-- 要两遍（按量计费的服务上这是真花钱），而半截内容更接近事实。

--- 这一轮要 POST 的那个请求体（两条路共用）。
---
--- ⚠️ 表体**当 JSON 发**，`content-type: application/json` 由宿主补上
---（自己再写一遍反而会被当成"我写过了"，见 http.rs 里 `写了_content_type`）。
--- ⚠️ `messages` 是**数组**：Lua 里就是"1..n 连续整数键"的表，宿主按这个判。
local function build_spec(url, key, model, messages, stream)
  return {
    url = url,
    -- 模型慢。默认的 30 秒对长文生成是不够的，宿主那边上限是 180 秒。
    timeout_ms = 120000,
    headers = {
      authorization = "Bearer " .. key,
    },
    body = {
      model = model,
      messages = messages,
      -- ⚠️ 只有流式那条路才写这个键：整段那条路写上它，某些服务会改回
      -- 一份 SSE 正文，而那条路那边**没有一行行拆的代码**，整份当 JSON 解
      -- 只会得到"不是 JSON"。少写一个键，两边都少一处能错的地方。
      stream = stream or nil,
    },
  }
end

--- 开一次请求前那两项检查：密钥有没有、地址像不像样。
---
--- ⚠️ 返回 `nil` 表示"可以发"，返回一张表表示"这一轮不用发了"——两条路都要
--- 走这一遭，抽出来是为了别把这两句话抄两遍（抄漏一处的表现是"流式那条路上
--- 地址少了 https 直接崩一个栈给用户看"）。
local function preflight(nota)
  local key = util.read_setting(nota, util.KEY_API, "")
  if key == "" then
    return { ok = false, error = T("No API key yet: press “Set key…” in the panel.") }
  end

  local base = util.read_setting(nota, util.KEY_BASE, util.DEFAULT_BASE)
  -- ⚠️ 先自己看一眼协议头：地址是用户在设置里手填的，少了 `https://` 的话
  -- 宿主会**抛**一句给作者看的错（"地址少了协议头"）。那句话本身挺准，
  -- 但用户看到的是"插件出错了"而不是"我少打了一段"。这里拦下来，说人话。
  if not string.match(base, "^https?://") then
    return {
      ok = false,
      error = T("The endpoint URL must start with https:// (or http:// for a service on this machine): %s", base),
    }
  end

  return nil, {
    key = key,
    url = util.join_url(base),
    model = util.read_setting(nota, util.KEY_MODEL, util.DEFAULT_MODEL),
  }
end

--- 从**一份已经到齐的回包**里取出那句话。两条路都用它（流式退回整段时也走这儿）。
---
--- ⚠️ 4xx/5xx **不是**宿主层面的错误（宿主故意关掉了 `http_status_as_error`）：
--- 配额用完、密钥不对这类话就写在响应体里，得读出来给用户看。
local function read_reply(r)
  if r.code ~= 200 then
    local detail = ""
    if type(r.json) == "table" and type(r.json.error) == "table" then
      detail = tostring(r.json.error.message or "")
    end
    if detail == "" then
      -- 不是 JSON（网关的 HTML 错误页）就原样端前 300 字：真正的病因写在里面，
      -- Nota 编不出比它更准的话。
      detail = string.sub(r.text or "", 1, 300)
    end
    return { ok = false, error = T("The endpoint returned %d: %s", r.code, detail) }
  end

  if type(r.json) ~= "table" then
    return {
      ok = false,
      error = T("The endpoint did not return JSON (HTTP %s): %s", r.code, string.sub(r.text or "", 1, 300)),
    }
  end

  local choices = r.json.choices
  local content = nil
  if type(choices) == "table" and type(choices[1]) == "table" and type(choices[1].message) == "table" then
    content = choices[1].message.content
  end
  if type(content) ~= "string" or content == "" then
    -- 形状对不上时**说清楚是哪儿对不上**：只报"生成失败"的话，用户和
    -- 插件作者都只能猜是网络问题还是接口换了。
    return { ok = false, error = T("The endpoint returned 200 but there is no choices[1].message.content in it.") }
  end

  return { ok = true, text = content }
end

--- 发一次对话请求（**整段**那条路），返回 `{ ok, text }` 或 `{ ok = false, error }`。
---
--- ⚠️ **两条失败通道**，2026-10-04（第 60 项）之后分的：
---
--- 1. **环境类**（连不上 / 超时 / 读断了）——宿主把它折成
---    `{ ok = false, error = "…" }` **返回**，不抛。这里直接拿 `r.error` 用。
--- 2. **参数写错**（地址少了协议头、方法不认识）——宿主**照旧抛**，因为那是
---    给插件作者看的。用户手上也可能撞到第 2 类（接口地址是他填的），
---    所以外面那层 `pcall` 留着当**兜底网**，用 `clean_error` 掐掉栈。
local function request(nota, messages)
  local bail, env = preflight(nota)
  if bail then
    return bail
  end

  local r
  local ok, err = pcall(function()
    r = nota.http.post(build_spec(env.url, env.key, env.model, messages, false))
  end)

  if not ok then
    -- 兜底网（见上面那段）。走到这儿说明是**参数写错**那一类。
    return { ok = false, error = T("The request was not sent: %s", util.clean_error(err)) }
  end

  -- 第 1 类：环境不给力。宿主给的就是一句能直接显示的话。
  if r.ok ~= true then
    return { ok = false, error = r.error or T("The request failed for an unknown reason.") }
  end

  return read_reply(r)
end

--- 一行 SSE 里的**正文**（`data: {…}` 里那个 `{…}`）；不是数据行就给 `nil`。
---
--- ⚠️ 只认 `data:`，`event:` / `id:` / 注释行（`:` 打头）一概不认：OpenAI 那套
--- 协议里我们一个都用不上，认了反而要多写三行不会被执行到的代码。
local function sse_body(line)
  return string.match(line, "^data:%s*(.*)$")
end

--- 从 SSE 的一小段 JSON 里取出那几个新字。
---
--- ⚠️ 形状是 `choices[1].delta.content`——**不是**整段那条路的
--- `choices[1].message.content`。两个词差一个字母，抄错了的表现是**一个字都
--- 出不来**，而流式那条路上"没有字"和"还没开始写"长得一模一样。
local function delta_of(nota, payload)
  local v = nota.json.decode(payload)
  if type(v) ~= "table" then
    return nil
  end
  local choices = v.choices
  if type(choices) ~= "table" or type(choices[1]) ~= "table" then
    return nil
  end
  local delta = choices[1].delta
  if type(delta) ~= "table" then
    return nil
  end
  local content = delta.content
  if type(content) ~= "string" then
    return nil
  end
  return content
end

--- 发一次对话请求（**流式**那条路），边收边把"正在写的字"推给面板。
---
--- 返回形状与 `request` 完全一样，另外多一个 `partial`（已经收到的那些字，
--- 一个字都没收到时是 `""`）——`M.ask` 靠它决定要不要退回整段那条路。
---
--- ⚠️ 推给面板走的是 `nota.ui.stream`（**推**），不是 `nota.ui.refresh`（拉）：
--- 这条命令跑着的时候宿主一直握着锁，拉那条路在这中间**回不来**。
--- 来龙去脉在 `src-tauri/src/lua/api/ui.rs::实时表` 顶上。
---
--- ⚠️ **推的是"到此刻为止的全文"**，不是这一段的增量：宿主那边只留最后 8000
--- 个字符，前端也只会拿它整块显示。发增量的话两端都得自己攒，而"攒"这件事
--- 一旦两边各攒一份，断一次线就会错位。
local function stream_request(nota, messages, on_delta)
  local bail, env = preflight(nota)
  if bail then
    return bail
  end

  -- 缓冲区：块边界**既不是行边界也不保证落在字符边界上**（跨 UTF-8 那个由
  -- 宿主保证不劈开），所以只有"攒到换行"才算收到一整行。
  local buf = ""
  local acc = ""
  local saw_data = false
  local done = false
  -- 上一次往外推的时刻。`-STREAM_PUSH_MS` 是为了让**第一段**立刻推出去。
  local last_push = -STREAM_PUSH_MS

  local spec = build_spec(env.url, env.key, env.model, messages, true)
  local r
  local ok, err = pcall(function()
    r = nota.http.stream(spec, function(chunk)
      buf = buf .. chunk
      while true do
        local nl = string.find(buf, "\n", 1, true)
        if not nl then
          break
        end
        local line = string.sub(buf, 1, nl - 1)
        buf = string.sub(buf, nl + 1)
        -- ⚠️ 行尾可能带一个 `\r`（SSE 的规矩就是 `\r\n` 结尾）。不掐掉的话
        -- `data: {...}\r` 交到 JSON 解析器手上就是"多了一个控制字符"。
        line = string.gsub(line, "\r$", "")
        if not done then
          local payload = sse_body(line)
          if payload == "[DONE]" then
            -- ⚠️ 看到它**不喊停**：`[DONE]` 之后服务器自己会关连接，而回调
            -- 返回 `false` 是"用户/插件要中断"那条路——那条路会让结果表上多出
            -- 一个 `aborted`，我们这边并没有中断。这里只是不再往里收字。
            done = true
          elseif payload then
            saw_data = true
            local piece = delta_of(nota, payload)
            if piece and piece ~= "" then
              acc = acc .. piece
              local now = util.now_ms(nota)
              if now - last_push >= STREAM_PUSH_MS then
                last_push = now
                on_delta(acc)
              end
            end
          end
        end
      end
      return true
    end)
  end)

  if not ok then
    return { ok = false, error = T("The request was not sent: %s", util.clean_error(err)), partial = acc }
  end

  if r.ok ~= true then
    return {
      ok = false,
      error = r.error or T("The request failed for an unknown reason."),
      -- ⚠️ 半截也带回去：连接是"答到一半断的"时候，这几百个字常常已经有用。
      partial = acc,
    }
  end

  if not saw_data then
    -- 一行 `data:` 都没有 ⇒ 对方**不认流式**，这份就是整段那种响应。
    -- 照整段那条路解一次（`ask` 那边看到 `ok` 就直接用了）。
    return read_reply(r)
  end

  if acc == "" then
    -- ⚠️ 有 `data:` 行、却一个字都没有：这是**真的空回答**（模型只吐了
    -- 几个 `delta` 里没有 content 的帧）。如实说，别退回整段再要一次——
    -- 那会白花一次钱，而且很可能还是空的。
    return {
      ok = false,
      error = T("The endpoint streamed a reply but it had no text in it."),
      partial = "",
    }
  end

  return { ok = true, text = acc, partial = acc }
end

--- 这一轮走哪条路。**判断只在这一处**（`chat.lua::M.send` 不知道也不该知道）。
---
--- ⚠️ 退回整段那三行的判据是 `partial == ""`，理由见本段顶上那个表。
function M.ask(nota, messages, on_delta)
  if not (on_delta and util.stream_on(nota)) then
    return request(nota, messages)
  end

  local r = stream_request(nota, messages, on_delta)
  if r.ok or (r.partial or "") ~= "" then
    return r
  end
  return request(nota, messages)
end

-- ⚠️ **这一行不能漏**：Lua 的 `require` 在模块块什么都不返回时，会把
-- `package.loaded["request"]` 记成 `true`，于是 `require("request")` 拿回来的是
-- 一个布尔值——调用点上那句 `request.ask(...)` 报的是
-- `attempt to index a boolean value (upvalue 'request')`，
-- 而**报错的位置在另一份文件里**，看着像是 `chat.lua` 出了问题。
return M
