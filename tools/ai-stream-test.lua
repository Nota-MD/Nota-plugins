-- AI 助手插件：**流式那条路的无头测试**（跑的是 `plugins/ai/chat.lua` 的真身）。
--
-- 跑法（在仓库根目录，**要用容器里的 lua**）：
--
-- ```sh
-- podman exec -u 1000 -w "$PWD" tauri-dev lua tools/ai-stream-test.lua
-- ```
--
-- 为什么要它（`docs/07` 第 58 项）：这条路上**除了它没有任何自动化看得见**。
-- `lua/tests.rs` 那两条只做到"把 `.lua` 编译一遍 / 把 `require` 链求一遍值"，
-- 一行都不会真跑；而流式最要紧的几件事全是**运行期**的：
--
-- * 块边界**不是行边界**——一帧 JSON 会被切成好几块，一行 `data:` 会横跨两块；
-- * `[DONE]` 之后服务器可能还发东西（真服务不发，但断了又续上的网关会）；
-- * 对方**不认流式**时要自动退回整段收（`chat.lua::ask` 那三行）；
-- * 答到一半断了时，**那半截要留在对话里**，而且**不许**再整段要一次；
-- * 开关关着时一次都不该走流式那条路。
--
-- 这五条开窗点按钮要么摆不出来（断流、网关不认），要么得靠数着时间看，
-- 而这里把 `nota` 整个桩掉、时钟和分块都由测试自己定，几毫秒跑完。
--
-- ⚠️ **它和 `tools/stub-openai.py` 是两回事，别混**：那个替的是**服务**
-- （真起一个 HTTP 服务，走真的 `nota.http.stream`），验的是"整条链子通不通"；
-- 这个替的是**宿主**，验的是"Lua 这边拆得对不对"。两个都值当：
-- 桩服务那条路上出不来"对方不认流式"这种分支（除非改桩），
-- 而这条路上验不到"宿主分块读真的不会劈开汉字"（那是 `http.rs` 的活）。
--
-- ⚠️ **标识符一律 ASCII**（`main.lua` 头上记着这个坑：中文标识符是 Lua 的语法
-- 错误）。注释中文没问题。
--
-- ⚠️ 路径**按脚本自己的位置算**（`arg[0]`），不写死仓库绝对路径：谁 clone 到
-- 哪儿都能跑。所以**必须从仓库根目录跑**（上面那条命令就是）。

local HERE = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = HERE .. "/../plugins/ai/?.lua;" .. package.path

local fails = 0
local function eq(actual, want, what)
  if actual == want then
    print("  ok   " .. what .. " = " .. tostring(actual))
  else
    fails = fails + 1
    print("  FAIL " .. what .. ": want [" .. tostring(want) .. "] got [" .. tostring(actual) .. "]")
  end
end

-- ── 一个够用的 JSON 解码器 ────────────────────────────────────────────────
--
-- ⚠️ 容器里那个 `lua` 没有 cjson / dkjson（连 `require` 都找不到），而宿主给
-- 插件的 `nota.json.decode` 是 **Rust 那一边**的东西（`lua/api/json.rs`）。
-- 所以在无头测试里它只能是个桩——但**不能随便给一个**：给个"永远返回空表"的
-- 桩，`delta_of` 就什么都取不到，整条流式路会静默地一个字都不出来，
-- 而这个测试会**全绿**（因为断言的是"没推过字"那条）。那就成了自己骗自己。
-- 所以这里写了个真的能解的小解码器，只覆盖 stub 会发的那些形状。
local function json_decode(s)
  local i = 1
  local function skip()
    while i <= #s and s:sub(i, i):match("%s") do
      i = i + 1
    end
  end
  local parse_value
  local function parse_string()
    i = i + 1
    local out = {}
    while true do
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1
        break
      end
      if c == "\\" then
        local e = s:sub(i + 1, i + 1)
        local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if e == "u" then
          out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16))
          i = i + 6
        else
          out[#out + 1] = map[e] or e
          i = i + 2
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return table.concat(out)
  end
  function parse_value()
    skip()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1
      local t = {}
      skip()
      if s:sub(i, i) == "}" then
        i = i + 1
        return t
      end
      while true do
        skip()
        local k = parse_string()
        skip()
        i = i + 1 -- 冒号
        t[k] = parse_value()
        skip()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then
          break
        end
      end
      return t
    elseif c == "[" then
      i = i + 1
      local t = {}
      skip()
      if s:sub(i, i) == "]" then
        i = i + 1
        return t
      end
      while true do
        t[#t + 1] = parse_value()
        skip()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then
          break
        end
      end
      return t
    elseif c == '"' then
      return parse_string()
    elseif s:sub(i, i + 3) == "null" then
      i = i + 4
      return nil
    elseif s:sub(i, i + 3) == "true" then
      i = i + 4
      return true
    elseif s:sub(i, i + 4) == "false" then
      i = i + 5
      return false
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      i = i + #num
      return tonumber(num)
    end
  end
  return parse_value()
end

-- ── 假宿主 ────────────────────────────────────────────────────────────────

local SETTINGS = { api_key = "stub", base_url = "http://127.0.0.1:1/v1", model = "stub", stream = "1" }
local PUSHED = {} -- 插件喊过的每一次 `nota.ui.stream`（`""` = 收工那一声）
local POSTED = 0 -- 走整段那条路的次数
local SCENARIO = "stream"

--- 把一段 SSE 正文按**任意字符位置**切成若干块，模拟宿主的分块读。
---
--- ⚠️ 切在**字符**上而不是字节上：宿主保证过"绝不把半个汉字交给插件"
---（`http.rs::切出完整段`），所以插件这一侧看到的最小单位就是一个字符。
--- 这里要摆的正是"一帧 JSON 横跨两块、一行 `data:` 只来了一半"那种情况。
local function chop(text, n)
  local out = {}
  local i = 1
  while i <= #text do
    out[#out + 1] = text:sub(i, i + n - 1)
    i = i + n
  end
  return out
end

--- 假时钟：**每问一次前进 100 毫秒**。
---
--- ⚠️ 为什么要造假表：`STREAM_PUSH_MS` 是 80，而用真时钟的话下面几段在一毫秒里
--- 就跑完了——每一帧都会被节流吃掉，界面上"越写越长"那条路**一次都走不到**，
--- 测试却照样全绿。造一张"每次问都往前走一格"的表，节流才会真的放行几次。
local CLOCK = 0
local function tick_ms()
  CLOCK = CLOCK + 100
  return CLOCK
end

--- 这一串推出去的正文是不是**一次比一次长、而且后一个是前一个的延长**。
---
--- 这是流式这条路唯一的硬不变量（推的是"到此刻为止的全文"，不是增量）。
--- ⚠️ 写成断言而不是拿 `#PUSHED` 去对数：那个数取决于 `STREAM_PUSH_MS` 与
--- 假时钟的步长，改一个就会红——而它红了并不说明代码坏了。
local function pushes_grow(pushed)
  local prev = nil
  for _, p in ipairs(pushed) do
    if prev ~= nil and p:sub(1, #prev) ~= prev then
      return false, ("后一次推的不是前一次的延长：[%s] → [%s]"):format(prev, p)
    end
    prev = p
  end
  return true
end

--- 造一段 SSE（形状与 `tools/stub-openai.py` 的 `stream` 模式一模一样）。
local function sse_frames(pieces)
  local out = {}
  for _, p in ipairs(pieces) do
    local quoted = string.format("%q", p)
    out[#out + 1] = 'data: {"id":"stub-1","object":"chat.completion.chunk","model":"stub",'
      .. '"choices":[{"index":0,"delta":{"content":' .. quoted .. '},"finish_reason":null}]}\n\n'
  end
  out[#out + 1] = 'data: {"id":"stub-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
  out[#out + 1] = "data: [DONE]\n\n"
  return table.concat(out)
end

local WHOLE_TEXT = '{"choices":[{"message":{"content":"整段回的那句话"}}]}'

local nota = {
  settings = {
    get = function(k) return SETTINGS[k] end,
    set = function(k, v) SETTINGS[k] = v end,
  },
  ui = {
    notify = function() end,
    refresh = function() end,
    stream = function(t) PUSHED[#PUSHED + 1] = t or "" end,
  },
  time = { now = function() return { now_ms = tick_ms() } end },
  json = { decode = json_decode },
  document = { get_text = function() return "第一行\n第二行" end },
  data = { read = function() return nil end, write = function() return true end },
  -- 改动块不是这一轮要验的东西（有它自己的一批用例），给个"一个围栏都没有"的桩。
  diff = { parse = function() return { text = "", hunks = {}, bad = 0 } end },
  http = {
    post = function()
      POSTED = POSTED + 1
      return { ok = true, code = 200, text = WHOLE_TEXT, json = json_decode(WHOLE_TEXT), chunks = 1 }
    end,
    stream = function(spec, cb)
      assert(spec.body.stream == true, "流式那条路必须带上 stream = true")
      if SCENARIO == "wholereply" then
        -- 对方不认流式：回一份整段 JSON（**一行 `data:` 都没有**）。
        cb(WHOLE_TEXT)
        return { ok = true, code = 200, text = WHOLE_TEXT, json = json_decode(WHOLE_TEXT), chunks = 1 }
      end
      if SCENARIO == "cut" then
        -- 答到一半连接被对方关掉。
        for _, c in ipairs(chop(sse_frames({ "写到一半" }), 7)) do
          cb(c)
        end
        return { ok = false, error = "读取响应体失败：连接被对方关掉了" }
      end
      local sse = sse_frames({ "我把第一句", "改短了。", "后面还有很长很长的一段话" })
      if SCENARIO == "done" then
        -- `[DONE]` **之后**还来一帧：那一帧的字一个字都不该进来。
        sse = sse_frames({ "前面这几个字" })
          .. 'data: {"choices":[{"delta":{"content":"不该出现的字"}}]}\n\n'
      end
      for _, c in ipairs(chop(sse, 7)) do
        cb(c)
      end
      return { ok = true, code = 200, text = "", chunks = #chop(sse, 7) }
    end,
  },
}

local chat = require("chat")

--- 新开一个对话跑一轮，返回 `(r, 对话表)`。
local function send_once()
  local c = { id = 1, open = true, title = "t", msgs = {}, scope = {}, expanded = {} }
  return chat.send(nota, c, "改一下"), c
end

local function reset(scenario)
  SCENARIO = scenario
  PUSHED, POSTED = {}, 0
end

-- ── (1) 流式：一帧横跨好几块，正文要与整段那条路一致 ──────────────────────
print("(1) 流式：块边界切碎一帧，正文照样拼得回来")
reset("stream")
do
  local r, c = send_once()
  eq(r.ok, true, "ok")
  eq(r.text, "我把第一句改短了。后面还有很长很长的一段话", "正文")
  eq(c.msgs[#c.msgs].role, "assistant", "最后一条是回答")
  eq(c.msgs[#c.msgs].text, r.text, "回答落进对话里")
  -- ⚠️ 要 `>= 3`（**至少两次正文**）而不是 `>= 2`：后者一次正文推都够了，
  -- 那样"越写越长"这条根本就没走到（节流把后面每一帧都吃掉也会满足）。
  eq(#PUSHED >= 3, true, "推了至少三次（两次以上正文 + 一次收工），实际 " .. #PUSHED)
  eq(PUSHED[1] ~= "", true, "第一次推就有字（不是先推一个空的）")
  eq(PUSHED[#PUSHED], "", "最后一次是空串（收工）")
  eq(pushes_grow({ table.unpack(PUSHED, 1, #PUSHED - 1) }), true, "推出去的正文一次比一次长")
  eq(PUSHED[#PUSHED - 1], r.text, "收工之前那一次推的就是全文")
end

-- ── (2) 对方不认流式 ⇒ 自动退回整段 ──────────────────────────────────────
print("(2) 一行 data: 都没有 ⇒ 自动退回整段收")
reset("wholereply")
do
  local r = send_once()
  eq(r.ok, true, "ok")
  eq(r.text, "整段回的那句话", "正文")
  eq(#PUSHED, 0, "一个字都没流过面板 ⇒ 一次都不惊动前端")
end

-- ── (3) `[DONE]` 之后的字不许进来 ─────────────────────────────────────────
print("(3) [DONE] 之后再来的帧一概不收")
reset("done")
do
  local r = send_once()
  eq(r.ok, true, "ok")
  eq(r.text, "前面这几个字", "正文（`[DONE]` 之后那帧被丢掉了）")
end

-- ── (4) 答到一半断了 ─────────────────────────────────────────────────────
print("(4) 答到一半断了：半截留着，而且不许再整段要一次")
reset("cut")
do
  local r, c = send_once()
  local n = #c.msgs
  eq(r.ok, false, "ok")
  eq(c.msgs[n].role, "error", "最后一条是错误说明")
  eq(c.msgs[n - 1].role, "assistant", "倒数第二条是那半截回答")
  eq(c.msgs[n - 1].text, "写到一半", "半截的字")
  eq(POSTED, 0, "收到过字就不整段要第二次（那会白花一次钱）")
  eq(PUSHED[#PUSHED], "", "失败也要把那段临时的字撤掉")
end

-- ── (5) 开关关着 ⇒ 整段那条路，一次都不调 stream ─────────────────────────
print("(5) 关掉「边生成边显示」⇒ 走整段那条路")
reset("off")
SETTINGS.stream = "0"
do
  local r = send_once()
  eq(r.ok, true, "ok")
  eq(r.text, "整段回的那句话", "正文")
  eq(POSTED, 1, "走了 post")
  eq(#PUSHED, 0, "一次都没推字")
end
SETTINGS.stream = "1"

-- ── (6) 设置项没了（第一次装）⇒ 默认**开着** ─────────────────────────────
print("(6) 设置里没有这个键 ⇒ 默认开着")
reset("stream")
SETTINGS.stream = nil
do
  local r = send_once()
  eq(r.ok, true, "ok")
  eq(r.text, "我把第一句改短了。后面还有很长很长的一段话", "正文（走的还是流式那条路）")
  eq(#PUSHED >= 2, true, "推了（说明走的确实是流式那条路）")
  eq(PUSHED[1] ~= "", true, "第一次推就有字")
end
SETTINGS.stream = "1"

print("")
if fails == 0 then
  print("全部通过")
else
  print(("%d 条没过"):format(fails))
  os.exit(1)
end
