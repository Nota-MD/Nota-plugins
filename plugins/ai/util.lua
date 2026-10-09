-- AI 助手插件的**公共词汇**：设置项的键名、几个小工具、以及文案取词器。
--
-- 2026-09-29 从 `main.lua` 按功能拆出来（那一份当时 997 行，离 1000 那条硬线
-- 只剩三行）。2026-10-04 又长出两份（落盘、可读范围），见下面那张表。
--
-- | 文件 | 管什么 |
-- |---|---|
-- | **本文件** `util.lua` | 设置项的键与默认值 · `read_setting` / `join_url` / `clip` / `cut` / `len` / `trim` / `clean_error` / `now_ms` |
-- | `request.lua` | **发一次请求**（2026-10-04 加）：整段/流式两条路、解回包 |
-- | `chat.lua` | 对话（状态 ＋ 组消息 ＋ 改动块 ＋ 改状态的命令）——**会碰网络和文档的那一半** |
-- | `store.lua` | 对话**落盘**：一份自定的行格式 ＋ 编码解码（`nota.data`） |
-- | `scope.lua` | 「AI 可读的文件」：列工作区里的 `.md`、开关、拼进系统消息 |
-- | `panel.lua` | 把对话画成右侧栏那一列内容块（**只读**，一个字节都不改） |
-- | `main.lua` | 插件外壳：`on_load` / 命令注册 / 菜单与面板声明 |
--
-- ⚠️ 为什么单独一份而不是塞进 `chat.lua`：`panel.lua` 也要读设置项（面板顶上
-- 那三行就是），而 `panel` 去 `require("chat")` 拿一个叫 `read_setting` 的东西
-- 讲不通——那是设置，不是对话。**依赖方向是单向的**：`request` / `chat` / `scope`
-- / `store` / `panel` → `util`；`chat` → `request` / `scope` / `store`；**没有反向的边**
--（`store` 不认识对话长什么样之上的东西，它只搬字符串；`request` 也不认识"对话"，
-- 它收下的是一张消息表）。
-- ⚠️ `T`（文案取词器）在每个模块里**各有一份**，都靠 `bind_text` 从 `main.lua`
-- 的 `on_load` 里接上（理由写在 `docs/12` §5.9）：模块级求值时 `nota` 还没到手。
-- 少了那一句**不报错**，只是这几块里的英文在中文界面上不翻。

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────
-- `T("原句")` 取译文（**键就是原文**，表在 `lang/`）。⚠️ **原文是英语**
--（2026-09-28 起），译文进 `lang/zh-CN.toml`；规矩见 `docs/13` §nota.i18n。
-- ⚠️ `T` 在 `on_load` 里重新绑一次（`nota` 到那时才到手）；译文里的 `%` 写成 `%%`。
local T = function(s) return s end

--- 把文案取词器接上宿主（由 `main.lua` 的 `on_load` 调）。
function M.bind_text(f)
  T = f
end

-- ── 设置 ──────────────────────────────────────────────────────────────────
--
-- 键名只用 ASCII 字母和下划线：宿主的 `nota.settings` 会拒掉带点的键
--（`a.b` 在 TOML 里是嵌套表，读回来形状就变了），理由见 settings.rs。

M.KEY_API = "api_key"
M.KEY_BASE = "base_url"
M.KEY_MODEL = "model"

--- 「AI 可读的文件」总共允许多少**字符**（`docs/07` 第 61 项 (c)）。
---
--- ⚠️ 单位是**字符**，不是 token（见 `docs/07` 第 61 项 (c2) 那条）：数 token
--- 要一份模型自己的分词表，而那是几百 KB 的另一份数据、还得跟着模型换代。
--- 字符数是个**粗略但谁都能算**的尺子，面板上那句话也照着这么写。
M.KEY_SCOPE = "scope_chars"

--- 「边生成边显示」（流式）开着没有（`docs/07` 第 58 项，2026-10-04）。
---
--- ⚠️ 存的是**字符串** `"1"` / `"0"`，不是布尔：`nota.settings` 那一格
--- 只放得下字符串（TOML 里当然有布尔，但那张表的口径是"一行一个文本值"，
--- 见 settings.rs）。判断一律走 `util.stream_on(nota)`，别自己去比字符串。
M.KEY_STREAM = "stream"

M.DEFAULT_BASE = "https://api.openai.com/v1"
M.DEFAULT_MODEL = "gpt-4o-mini"

--- 那些参考文件总共能占多少字符。**默认 20000**——大约是一篇中篇文档，
--- 塞进 8k～32k 上下文的模型都还留得下对话本身。
M.DEFAULT_SCOPE = "20000"

--- 「边生成边显示」**默认开着**（`"1"`）。
---
--- ⚠️ 默认开着是因为它**只在长回答上才有感觉**，而"回答有多长"用户事先不知道：
--- 默认关着的话，绝大多数人一辈子不会去打开它。代价是有些**本地/自建**服务
--- 不支持 `stream = true`——那种情况下 `chat.lua` 会**自动退回**整段收（见
--- `chat.lua` 顶上那段"两条路"），用户看到的只是"没有边打边出"，不是报错。
M.DEFAULT_STREAM = "1"

-- ── 小工具 ────────────────────────────────────────────────────────────────

--- 读一个设置项。没填、或填的不是文本，都给兜底值。
function M.read_setting(nota, key, fallback)
  local v = nota.settings.get(key)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return fallback
end

--- 「边生成边显示」（`docs/07` 第 58 项）这一刻是开着还是关着。
---
--- ⚠️ **只认 `"1"` 是开**，别的值一律当关——包括空串和读不到（那时 `read_setting`
--- 会给回 `DEFAULT_STREAM`，也就是 `"1"`）。反过来写（"不等于 `"0"` 就算开"）
--- 的话，将来多出第三个值时会**静默地变成开**，而这类开关的默认方向一变，
--- 表现是"我以为关掉了，它还在往外吐字"。
function M.stream_on(nota)
  return M.read_setting(nota, M.KEY_STREAM, M.DEFAULT_STREAM) == "1"
end

--- 拼接口地址。末尾的斜杠要去掉——用户填 `.../v1/` 是常事，
--- 拼出 `.../v1//chat/completions` 有些服务器会当成另一个路径。
function M.join_url(base)
  return (string.gsub(base, "/+$", "")) .. "/chat/completions"
end

--- 此刻的 Unix 毫秒（**墙钟**）。
---
--- ⚠️ 只用来**算间隔**（流式那条路每 80 毫秒才往面板推一次），不做别的。
--- 算间隔其实用单调钟更合适（`nota.document` 那个 `clock_ms`），但那一位要
--- 文档能力、而且没开文档时读不到；这里的用途对"时钟被改过"完全不敏感。
---
--- ⚠️ 读不到就给 `0`：调用方那边退化成"每次都推"，是慢，不是错。
function M.now_ms(nota)
  local ok, t = pcall(function() return nota.time.now() end)
  if not ok or type(t) ~= "table" or type(t.now_ms) ~= "number" then
    return 0
  end
  return t.now_ms
end

--- 一段文本的**字符**数（不是字节数）。UTF-8 不合法时退回字节数。
---
--- ⚠️ 退回字节数而不是 `nil`：`utf8.len` 对坏字节返回 `nil`，而调用方（面板、
--- 范围预算）只是要一个"多大"的数——给 `nil` 的话它们各自得写一遍兜底，
--- 漏一处就是一次 `attempt to perform arithmetic on a nil value`。
function M.len(s)
  return utf8.len(s) or #s
end

--- 截断到 `limit` 个**字符**，末尾只加一个省略号——**不加任何解释**。
---
--- ⚠️ 末尾那句"面板放不下"从前是写在正文里的（`clip`）。第 59 项把解释搬到了
--- 按钮上（「展开全文（共 N 字）」）：**正文里再夹一句就是同一件事说两遍**，
--- 而且它本身也占地方——正好是这一项要治的毛病。
---
--- ⚠️ 按**字符**截（不是字节）：按字节截会把一个汉字劈成半个，
--- 半个汉字出去会被宿主转成"�"。
function M.cut(s, limit)
  local n = M.len(s)
  if n <= limit then
    return s
  end
  local head = utf8.offset(s, limit + 1)
  if head == nil then
    -- 不是合法 UTF-8（理论上到不了）：按字节兜底，总比不截好。
    return string.sub(s, 1, limit) .. "…"
  end
  return string.sub(s, 1, head - 1) .. "…"
end

--- 去掉首尾空白。`gsub` 返回两个值，外面那对括号是**必须**的。
function M.trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

--- 把宿主抛回来的错误收拾成一句人话（**只治显示**）。
---
--- ⚠️ mlua 有个绕不开的行为：**从 Rust 回调里返回的错误会被它包成 `CallbackError`**，
--- 并在消息后面缀上一整段 `stack traceback:`（`mlua-0.12.1/src/util/error.rs`
--- 里 `callback_error` 干的）。`pcall` 抓到的就是那段字符串——2026-09-24 目检实测：
--- 一次"连不上"能把面板糊满，连状态栏都被顶掉两行，而用户要的只是"连不上"三个字。
---
--- 所以这里把栈掐掉、把 `runtime error: ` 这个前缀去掉。⚠️ 里面的换行在面板上
--- 会**折成空格**（`text` 块按正常空白排版），但掐的时候得按原文找，别按看到的找。
---
--- # ⚠️ 2026-10-04（第 60 项）之后它**不再是主路**
---
--- `nota.http.*` 现在把"连不上 / 超时 / 读断了"折成**结果表**（`{ok = false,
--- error = "…"}`，见 `src-tauri/src/lua/api/http.rs::落定`），所以最常见的那个
--- 失败**根本不进这里**——它是 `r.error` 里一句现成的中文，不用掐。
---
--- 这一份留着兜**另外一半**：宿主里**别的** API 仍然抛错（`nota.fs.read` 读不到、
--- `nota.diff.apply` 的用法写错），以及 `nota.http` 里那些"作者把参数写错了"的错
--- （地址少了协议头、方法不认识）——那几种**故意**保留栈信息，因为它们是给作者看的。
--- 所以调用点上的 `pcall` 是一张**兜底网**，不是主路。
function M.clean_error(e)
  local s = tostring(e)
  local cut = string.find(s, "stack traceback:", 1, true)
  if cut then
    s = string.sub(s, 1, cut - 1)
  end
  s = (string.gsub(s, "^runtime error: ", ""))
  return M.trim(s)
end

return M
