-- AI 助手插件的**对话那一半**：对话状态 ＋ 组消息 ＋ 改动块 ＋ 几条改状态的命令体。
--
-- 2026-09-29 从 `main.lua` 按功能拆出来（那一份当时 997 行）。拆的线是
-- 「**会碰网络和文档的那一半**」——本文件里全是"要动起来"的东西：
--
-- - **对话状态**：`chats` / `cur` / `next_id` 三份账；
-- - **组消息**：把当前文档、参考文件、最近 `HISTORY_MAX` 轮拼成一张消息表；
-- - **改动块**：模型在末尾附的那段 `nota-diff`，解析与应用都调宿主的 `nota.diff`；
-- - **几条改状态的命令体**（新开 / 切 / 关 / 删 / 应用 / 丢弃）——⚠️ **它们跟着
--   状态走**，不留在 `main.lua`：那几个函数每次都要读写 `chats` 和 `cur`，隔着一个
--   文件去够只会让两处永远得一起改（同 `plugins/git/diff.lua` 那条 `show_diff`
--   的理由）。`main.lua` 里只剩 `nota.command.register(...)` 那一行转接。
--
-- | 文件 | 管什么 |
-- |---|---|
-- | `util.lua` | 公共词汇：设置项的键、`read_setting` / `cut` / `len` 这几个小工具 |
-- | `request.lua` | **发一次请求**：组规格、整段/流式两条路、解回包 |
-- | **本文件** `chat.lua` | 对话（状态 ＋ 组消息 ＋ 改动块 ＋ 改状态的命令） |
-- | `store.lua` | 对话落盘（`nota.data` 里一份自定的行格式） |
-- | `scope.lua` | 「AI 可读的文件」 |
-- | `panel.lua` | 把对话画成右侧栏那一列内容块（**只读**） |
-- | `main.lua` | 插件外壳：`on_load` / 命令注册 / 菜单与面板声明 |
--
-- ⚠️ **发 HTTP 的那一段 2026-10-04 搬去了 `request.lua`**：这一份当时 977 行，
-- 离 1000 那条硬线只剩 23 行（`docs/09` §4 那条 300–800）。拆的线是"**会不会
-- 发 HTTP**"，不是"对半切"——`request.lua` 单独拿出去也讲得通（"怎么跟一个
-- OpenAI 兼容接口说话"），本文件剩下的那一半同样讲得通（"一个对话里有什么"）。
-- ⚠️ **依赖方向：`chat` → `request` → `util`**，没有反向的边（`request` 不认识
-- "对话"，它收下的是消息表，回来的是回答）。
--
-- ⚠️ `T` 也要 `bind_text`（`main.lua` 的 `on_load` 里那一句），理由见 `util.lua` 文件头。
-- ⚠️ 变量名一律 ASCII（理由写在 `main.lua` 文件头）。
--
-- # ⚠️ 2026-10-04（第 57 / 61 项）：对话分成**开着**和**关着**两种
--
-- 用户 2026-09-25 的原话里有一句「**关闭对话自动释放上下文**」。「关闭」和
-- 「删除」是**两件事**：关是"从上下文里拿掉、还能再打开"，删是"记录扔掉"。
-- 从前只有删除（`drop_chat`），而且只剩一个时它偷偷降级成"清空"——两件事共用一个按钮。
--
-- 现在每个对话有一个 `open`。**开着**的进"工作区"：能切过去、能说话；
-- **关着**的只留在清单里，点一下能重新打开。
--
-- ⚠️ **判据落在哪儿**（这是"释放上下文"这句唯一可验的说法）：
-- `build_messages` 只读 `M.current()`，而 `M.current()` **只会返回一个
-- `open = true` 的对话**（找不到就返回 `nil`）。所以"关掉的那个不再进上下文"
-- 不是一句愿望，是这一条不变量：**关着的对话不可能被组进任何一次请求**。
--
-- ⚠️ 一个打开的都没有是**合法状态**（用户可以把它们全关掉）：那时面板上说
-- 一句"没有打开的对话"，输入框不画。`M.current()` 因此可能返回 `nil`——
-- 所有用到它的地方都得先判一下。

local util = require("util")
local store = require("store")
local scope = require("scope")
local request = require("request")

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────
-- 每个模块各有一份 `T`，都由 `main.lua` 的 `on_load` 接上（见 `util.lua` 文件头）。
local T = function(s) return s end

--- 把文案取词器接上宿主（由 `main.lua` 的 `on_load` 调）。
function M.bind_text(f)
  T = f
end

-- ── 上限 ──────────────────────────────────────────────────────────────────
--
-- ⚠️ 每一个都是**为了"这一栏还能看"**：右侧栏只有 260px 宽，而对话是会长的东西，
-- 不设上限的话一屏里全是一个月前的聊天记录。
--（另外两条上限是画面板的，在 `panel.lua`；对文件的那条在 `scope.lua`。）

--- 最多同时留几个对话。
---
--- ⚠️ 2026-10-04 起这个数**还管着存盘**：20 个对话 × 每个最多 100 条消息
--- （`store.MSGS_MAX`）是那份文件的理论上限，而它必须压在一个稳当的地方——
--- 见 `touch` 里「存不下就丢最旧的对话」那段。
local MAX_CHATS = 20

--- 发给模型的历史最多带几轮（`user`/`assistant` 各算一条）。
--- 不带上限的话，聊久了每次请求都要把整段历史重发一遍。
local HISTORY_MAX = 40

-- ── 预设 ──────────────────────────────────────────────────────────────────
--
-- ⚠️ **顺序写死在一张数组里**，不用 `pairs` 遍历下面那张表——`pairs` 的顺序
-- 不保证，界面上那排按钮会每次重开都换位置（而且不报错，只是"按钮乱跳"）。
local PRESET_ORDER = { "polish", "summarize", "continue_writing", "translate_en", "translate_zh" }

-- 每一句都是**用户会说的那句话**：它会作为一条用户消息出现在对话里，
-- 所以不能写成"给模型的命令"（那样用户看到的是"请只输出译文："这种半句话）。
local PRESETS = {
  polish = {
    label = "Polish",
    ask = "帮我润色当前文档，保持原意和语气。改动用末尾的改动块给出。",
  },
  summarize = {
    label = "Summarize",
    ask = "用要点总结一下当前文档。只回答，不要改文档。",
  },
  continue_writing = {
    label = "Continue writing",
    ask = "顺着当前文档继续写下去，风格保持一致。新内容用只有 `+` 行的改动块追加到文末。",
  },
  translate_en = {
    label = "Translate to English",
    ask = "把当前文档整篇译成英文。改动用末尾的改动块给出（整段替换）。",
  },
  translate_zh = {
    label = "Translate to Chinese",
    ask = "把当前文档整篇译成中文。改动用末尾的改动块给出（整段替换）。",
  },
}

--- 预设的**顺序**（`panel.lua` 与 `main.lua` 都按这个顺序画/注册）。
--- ⚠️ 给的是那张数组本身，**别改它**——顺序写死的理由在上面的注释里。
function M.preset_order()
  return PRESET_ORDER
end

--- 取一个预设（`nil` = 没有这个 id）。
function M.preset(id)
  return PRESETS[id]
end

-- ── 送给模型的系统提示词 ──────────────────────────────────────────────────
--
-- ⚠️ 下面这段和 `lua/api/diff.rs` 里那两个围栏常量、`docs/13` 那张表是
-- **同一份契约的三处**。改一处就得改三处——漏一处的症状是"模型照旧格式写、
-- 插件认不出来了"，而两边都不报错。
--
--（从前这里还有 `FENCE_OPEN` / `FENCE_CLOSE` 两个常量，解析也在这个文件里。
-- 2026-09-24 解析与应用搬去了宿主，常量跟着走，别在这儿再写一份。）**每轮都重发**（里面带着当前文档的全文）。
---
--- ⚠️ 为什么文档放在**系统消息**里、而不是第一轮的用户消息里：文档是会被改的
---（用户自己改、或者刚应用了一处改动），而 `-` 行必须与**当前**文档逐字一致。
--- 放在每轮重建的系统消息里，模型看到的永远是此刻的正文。
local SYSTEM_PROMPT = [[
你是 Nota（一个 Markdown 编辑器）里的写作助手。用户在同你对话，系统消息里带着当前文档的全文。

你的回答分两部分，按这个顺序写：

第一部分是**普通文本**：直接回答用户。可以解释、可以建议、可以只是聊天、可以问回去。按 Markdown 写，用户在对话里直接读这一段。

第二部分（**只有需要改文档的时候才写**）是**改动块**，放在整个回答的**最末尾**：

```nota-diff
- 原文里的一整行（逐字照抄，从行首到行尾，一个字都不能改）
- 原文里紧接着的下一行
+ 换上去的新内容
+ 可以有好几行
```

改动块的规矩（错一条就应用不上）：

1. 它必须是回答的**最后一样东西**，后面不要再写任何字；
2. `-` 行必须和**当前文档**逐字一致，而且必须是文档里**连续的一段**：不要改标点、不要补空格、不要省略、不要自己排版；
3. `-` 行是"要被换掉的原话"，`+` 行是"换上去的新话"。不是让你把改过的整篇文档重抄一遍，只写动过的那一段；
4. 只改一处就写一个改动块；改多处就写多个改动块，**按它们在文档里出现的先后顺序**写；
5. 只是往文档里加新东西（不删任何一行）时，改动块里**只写 `+` 行**，它会追加到文末；
6. **不需要改文档时就一个改动块都不要写**：不要写空的改动块，也不要写"占位"的改动块。

⚠️ 你说要改什么，就必须在改动块里给出。用户是按改动块把改动**应用**进文档的，正文里那句"我把第二段改得更简洁了"不会进文档。
]]

--- 系统消息里**参考文件**那一段的引子。
---
--- ⚠️ 单独一段（不并进 `SYSTEM_PROMPT`）：参考文件是**这一轮有、下一轮可能没有**
--- 的东西，而上面那段是每一轮都在的规矩。混在一起的话，"这轮没挂文件"就得
--- 把整段提示词拼两遍。
local SCOPE_PROMPT = [[
下面是用户另外指定给这次对话的**参考文件**（它们不在编辑区里，只是给他看的材料）。
引用它们的时候说清楚是哪个文件。**不要**为这些文件里的内容写改动块——改动块只针对编辑区里的那一篇。
]]
-- ── 改动块：交给宿主 ─────────────────────────────────────────────────────
--
-- 「末尾附一段 diff」这件事的**解析与应用都在宿主的 `nota.diff` 里**
--（`src-tauri/src/lua/api/diff.rs`），本文件只负责调它。为什么不在插件里做：
--
-- 1. 那份格式**不是 AI 专有的**——界面上那块 `kind = "diff"` 的渲染本来就在
--    宿主里（`src/ui/panel-nodes.ts` 的白名单），格式的定义放宿主才不会两边漂；
-- 2. 它唯一会**改坏用户文档**，所以必须能拿单元测试一条条钉住。Rust 那边一条
--    `#[test]` 就够，写在 Lua 里得先造一个宿主环境；
-- 3. 这一份文件还要守 1000 行上限（`docs/09` §4），搬走这 200 行是**按职责拆**
--    ——插件管对话，宿主管格式——不是为凑行数。
--
-- ⚠️ 契约（改一处要改三处）：围栏与那几条规矩写在 `lua/api/diff.rs`
-- ＋ 下面那段 `SYSTEM_PROMPT`（送给模型的）＋ `docs/13-lua-api.md` §AI 改动块。

--- 拆一段回答：返回 `{ text = 正文, hunks = {...}, bad = 坏行数 }`。
--- 一个改动块都没有时 `hunks` 是空表（**不是 `nil`**：调用方不用分情况）。
function M.parse(nota, text)
  return nota.diff.parse(text)
end

--- 应用改动：成功给新全文，失败给 `nil, 原因`（**失败时文档一个字都不许动**）。
function M.apply(nota, doc, hunks)
  return nota.diff.apply(doc, hunks)
end
-- ── 对话 ──────────────────────────────────────────────────────────────────

--- 全部对话。
local chats = {}

--- 当前是第几个（1 起）。⚠️ 可能指着一个**关着**的对话，`M.current()` 会自己跳开。
local cur = 1

--- 下一个对话的编号。用**编号**而不是下标当身份：删掉一个对话之后下标会整体前移，
--- 而面板上那个「切到这个对话」的按钮里存的是编号（`args.id`）。存盘之后编号
--- 还得继续往下发，所以 `M.load` 会把 `next_id` 顶到"读进来的最大编号 + 1"。
local next_id = 1

--- 一个新对话该长什么样（三处"新建"共用一份，免得漏了哪个字段）。
--- ⚠️ `scope` 一开始是**空表**（一个文件都没挂），不是 `nil`——`scope.has` 那几处
--- 每次都要 `or {}` 的话，总有一天会漏掉一处。
local function fresh(id)
  return { id = id, open = true, title = "新对话", msgs = {}, patch = nil, scope = {}, expanded = {} }
end

--- 开局就摆一个空对话（不然面板一打开是"没有对话"，用户得先点一下才能说话）。
local function reset_chat()
  chats = { fresh(next_id) }
  next_id = next_id + 1
  cur = 1
end

reset_chat()

--- 一共几个对话（`panel.lua` 画清单用）。
function M.count()
  return #chats
end

--- 第几个对话（`panel.lua` 画清单用；越界给 `nil`）。
function M.at(i)
  return chats[i]
end

--- 当前是第几个（`panel.lua` 画清单用）。
function M.cur_index()
  return cur
end

--- 当前那个对话。**只会给一个 `open` 的**；一个开的都没有时给 `nil`。
---
--- ⚠️ 这条不变量是第 61 项 (b)「关闭对话自动释放上下文」的**全部判据**：
--- 组消息的地方只认 `M.current()`，所以关着的对话不可能进上下文。
function M.current()
  if cur >= 1 and cur <= #chats and chats[cur].open then
    return chats[cur]
  end
  -- `cur` 指歪了（刚把那个关掉 / 删掉、或者热重载之后）：找第一个开着的。
  for i, c in ipairs(chats) do
    if c.open then
      cur = i
      return c
    end
  end
  return nil
end

--- 开着的有几个（面板上那句"没有打开的对话"要用）。
function M.open_count()
  local n = 0
  for _, c in ipairs(chats) do
    if c.open then
      n = n + 1
    end
  end
  return n
end

--- 按编号找对话的下标。找不到给 `nil`。
local function find_chat(id)
  for i, c in ipairs(chats) do
    if c.id == id then
      return i
    end
  end
  return nil
end

--- 这个对话里说过话没有。**在 push 之前调**——用来决定要不要拿第一句话当标题。
local function chat_is_fresh(chat)
  for _, m in ipairs(chat.msgs) do
    if m.role == "user" then
      return false
    end
  end
  return true
end

--- 拿一句话当标题：掐短、去掉换行（标题只会画在一颗按钮里）。
---
--- ⚠️ 这里**不能**用 `util.cut()`。它截短之后补的是省略号，但真正的理由是
--- 长度：标题只会画在一颗按钮里，十几个字就够，"这一句到底说了什么"要看正文。
--- 标题的省略号自己加，而且标题**不进任何预算**。
local function title_from(text)
  local one = (string.gsub(text, "%s+", " "))
  local n = utf8.len(one)
  if n and n > 14 then
    return string.sub(one, 1, utf8.offset(one, 15) - 1) .. "…"
  end
  return one
end
--- 把待应用的改动**就地面在正文上**要的那份"改完之后"。
---
--- ⚠️ 这是 `nota.ui.review_diff` 要的**整篇目标文本**，不是补丁、不是 hunk。
--- 补丁怎么打是这边的事（`M.apply`），宿主与编辑器只认"整篇该长什么样"
--- 这一种说法——多一种说法就多一处会对不齐的地方（理由写在
--- `src-tauri/src/lua/api/ui.rs::预览改动表`）。
---
--- ⚠️ **和 `apply_patch` 走同一条 `M.apply`**：预览里看到的、和真写进去的
--- 必须是同一份。这里若另算一遍，两处一旦不一样，用户就会看到"预览是一个样、
--- 应用之后是另一个样"——而那是所有预览功能里最难解释的一种坏。
---
--- 返回 `nil, 原因` 表示这份补丁打不出来（与 `apply_patch` 同一套判据）。
function M.patched_text(nota)
  local chat = M.current()
  if not chat then
    return nil, T("No chat is open")
  end
  if not chat.patch then
    return nil, T("There are no changes waiting to be applied")
  end
  local doc = nota.document.get_text() or ""
  return M.apply(nota, doc, chat.patch.hunks)
end
-- ── 落盘 ──────────────────────────────────────────────────────────────────
--
-- 格式、编码、读写都在 `store.lua`；这里只管**什么时候存**。

--- 存一次。
---
--- ⚠️ **每一次改状态之后都存**，没有"退出前统一存"那一步：应用可能被 `kill`、
--- 可能崩，而"退出前存"那条路在两种情况下都不跑。代价是一次几 KB 的写盘，
--- 在一个只有用户点按钮才会走的路径上，那不是个问题。
---
--- ⚠️ 存不下时**从最旧的对话开始丢**（`store.save` 干这件事），并说一声。
--- 不说的话用户只会看到"以前的对话莫名其妙少了"。
local function touch(nota)
  local ok, extra = store.save(nota, chats)
  if not ok then
    nota.ui.notify(T("These chats could not be saved: %s", tostring(extra)), "warn")
  elseif extra and extra > 0 then
    -- ⚠️ `store.save` 是**就地把最旧的那几个从 `chats` 里删掉**的（理由写在它那儿），
    -- 所以 `cur` 得跟着往左挪同样多——不挪的话用户会莫名其妙地切到另一个对话上。
    cur = math.max(1, cur - extra)
    M.current()
    nota.ui.notify(T("The saved chat file hit its 1 MiB limit, so %d of the oldest chats were dropped.", extra), "warn")
  end
  nota.ui.refresh()
end

--- 把存下来的对话读进来（`main.lua` 的 `on_load` 里调，**在 `bind_text` 之后**）。
---
--- 文件不在 / 读不懂 → 保持开局那一个空对话。**不报错**：第一次用这个插件时
--- 那个文件本来就不存在，那不是故障。
function M.load(nota)
  local saved = store.load(nota)
  if #saved == 0 then
    return
  end
  chats = saved
  for _, c in ipairs(chats) do
    c.patch = nil
    c.scope = c.scope or {}
    c.expanded = {}
    if c.id >= next_id then
      next_id = c.id + 1
    end
  end
  cur = 1
  M.current()
end

--- 组装这一轮发给模型的完整消息表，外加一串"参考资料发生了什么"的话。
---
--- ⚠️ 文档进的是**系统消息**，而且每轮重建（理由见 `SYSTEM_PROMPT` 那段）。
--- `error` / `note` 那两种角色**不发给模型**：它们是给用户看的旁白。
---
--- 返回两个值：`messages`、`notes`（读不到 / 被截短 / 预算用完的文件，
--- 由 `M.send` 落成一条旁白给用户看）。
local function build_messages(nota, chat)
  local doc = nota.document.get_text() or ""
  local sys
  if doc == "" then
    sys = SYSTEM_PROMPT .. "\n\n（当前文档是空的。）"
  else
    sys = SYSTEM_PROMPT .. "\n\n──── 当前文档全文开始 ────\n" .. doc .. "\n──── 当前文档全文结束 ────"
  end

  -- 参考文件（第 61 项 (c)）：挂了才有这一段。
  local refs, _, notes = scope.render(nota, chat)
  if refs ~= "" then
    sys = sys .. "\n\n" .. SCOPE_PROMPT .. "\n" .. refs
  end

  local messages = { { role = "system", content = sys } }

  -- 只带最近 HISTORY_MAX 条：聊久了全带上，每一轮都在重发一个月前的记录。
  local start_i = math.max(1, #chat.msgs - HISTORY_MAX + 1)
  for i = start_i, #chat.msgs do
    local m = chat.msgs[i]
    if m.role == "user" or m.role == "assistant" then
      messages[#messages + 1] = { role = m.role, content = m.text }
    end
  end

  return messages, notes
end

--- 说一句话 → 等回答 → 落进对话里。**所有会走网络的路都收在这一个函数**。
function M.send(nota, chat, text)
  if not chat then
    return { ok = false, error = T("No chat is open. Press “New chat” first.") }
  end

  local fresh = chat_is_fresh(chat)
  chat.msgs[#chat.msgs + 1] = { role = "user", text = text }
  if fresh then
    chat.title = title_from(text)
  end

  local messages, notes = build_messages(nota, chat)
  -- ⚠️ 参考资料出了状况（某个文件读不到、被截短）时**留一句旁白在对话里**：
  -- 不说的话，模型答得不对用户只会以为"它就是笨"，而真正的原因是他的文件
  -- 压根没送出去。
  for _, n in ipairs(notes) do
    chat.msgs[#chat.msgs + 1] = { role = "note", text = n }
  end
  -- ⚠️ 问也先落盘：回答要等几秒到几十秒，这中间应用崩了的话，
  -- 用户至少还能看到自己问过什么。
  touch(nota)

  -- 走哪条路由 `request.ask` 定（流式开着就走流式，见那边的表）。
  --
  -- ⚠️ `pushed` 记的是"**我真的往面板推过字**"：收工时要喊一声 `stream("")`
  -- 把那段临时的字撤掉，但没推过的那些轮次（流式关着、或者对方不认流式）
  -- 就不必去惊动一次前端。
  local pushed = false
  local r = request.ask(nota, messages, function(text)
    pushed = true
    -- ⚠️ 推的是"到此刻为止的全文"，而且**是推不是拉**——跑这条命令的时候
    -- 宿主握着 `plugins` 锁，`nota.ui.refresh()` 在这中间回不来。见
    -- `request.lua::stream_request` 顶上的表。
    nota.ui.stream(text)
  end)

  if pushed then
    -- ⚠️ **不管成功失败都要喊这一声**：那段字只是临时显示，不撤的话屏幕上
    -- 会一直停在那半截上——成功了像是"永远写不完"，失败了像是"它还在写"。
    -- （前端在拉回真内容时也会顺手清一遍，那是**兜底**，不是这里的替代。）
    nota.ui.stream("")
  end

  if not r.ok then
    -- ⚠️ 流式答到一半断掉时收到的那半截，**留在对话里**再补一条错误说明。
    -- 不留的话，用户刚亲眼看着字一个个冒出来、然后它们整段消失了——那比
    -- 一开始就报错更让人以为是自己弄坏了什么。
    if type(r.partial) == "string" and r.partial ~= "" then
      chat.msgs[#chat.msgs + 1] = { role = "assistant", text = r.partial }
    end
    -- ⚠️ 失败也**留在对话里**（用一种单独的角色）：用户看得见自己说了什么、
    -- 失败在哪一步，而不是"面板闪了一下，我说的话也没了"。
    chat.msgs[#chat.msgs + 1] = { role = "error", text = r.error }
    touch(nota)
    nota.ui.notify(r.error, "error")
    return { ok = false, error = r.error }
  end

  chat.msgs[#chat.msgs + 1] = { role = "assistant", text = r.text }

  local p = M.parse(nota, r.text)
  if #p.hunks > 0 then
    chat.patch = { hunks = p.hunks, bad = p.bad }
    nota.ui.notify(T("The AI's reply contains changes; they are written to the document only after you confirm."), "info")
  else
    -- ⚠️ 新回复里没有改动块 → **上一处作废**。留着它的话，用户又聊了几轮之后
    -- 点「应用改动」，应用的是几轮之前那处已经过时的改动。
    chat.patch = nil
  end

  touch(nota)
  return { ok = true, text = r.text }
end

--- 跑一个预设：就是把那句写好的话当用户消息发出去。
function M.run_preset(nota, id)
  local p = PRESETS[id]
  if not p then
    return { ok = false, error = T("Unknown preset: %s", tostring(id)) }
  end
  local r = M.send(nota, M.current(), p.ask)
  -- 从菜单点进来的时候用户未必看着右侧面板，说一句让他去那儿看。
  if r.ok then
    -- ⚠️ 预设名要**现取译文**：`PRESETS` 是模块级常量，求值时 `T` 还没接上宿主。
    nota.ui.notify(T("The answer to “%s” is in the AI panel on the right.", T(p.label)), "success")
  end
  return r
end

--- 开一个新对话，并切过去。
function M.new_chat(nota)
  if #chats >= MAX_CHATS then
    local msg = T("At most %d chats can be kept at once; delete a few first.", MAX_CHATS)
    nota.ui.notify(msg, "warn")
    return { ok = false, error = msg }
  end
  chats[#chats + 1] = fresh(next_id)
  next_id = next_id + 1
  cur = #chats
  touch(nota)
  return { ok = true }
end

--- 切到某个对话。`args.id` 是编号（`panel.lua` 里发出的那个）。
---
--- ⚠️ 切到一个**关着**的对话不切（那等于偷偷把它打开了）：面板上给关着的那几个
--- 画的是「打开」，走的是 `reopen_chat`。这里挡一下，是为了让"开着/关着"这件事
--- 只有一条路能改。
function M.switch_chat(nota, id)
  local i = id and find_chat(id) or nil
  if not i then
    return { ok = false, error = T("That chat is gone") }
  end
  if not chats[i].open then
    return { ok = false, error = T("That chat is closed. Open it first.") }
  end
  cur = i
  touch(nota)
  return { ok = true }
end

--- **关闭**当前对话：从上下文里拿掉，记录留着，随时能再打开。
---
--- ⚠️ 与 `drop_chat` 是**两件事**（第 61 项 (b)）：关是"这次不聊它了"，
--- 删是"这段记录不要了"。从前只有后者，而且只剩一个时它偷偷降级成清空——
--- 两个意思共用一个红按钮。
function M.close_chat(nota)
  local c = M.current()
  if not c then
    return { ok = false, error = T("No chat is open") }
  end
  c.open = false
  -- `cur` 还指着它，`M.current()` 会自己跳到下一个开着的（没有就是 nil）。
  M.current()
  touch(nota)
  nota.ui.notify(T("Closed “%s”. It is out of the context now; open it again whenever you want.", T(c.title)), "info")
  return { ok = true }
end

--- 重新打开一个关着的对话，并切过去。
function M.reopen_chat(nota, id)
  local i = id and find_chat(id) or nil
  if not i then
    return { ok = false, error = T("That chat is gone") }
  end
  chats[i].open = true
  cur = i
  touch(nota)
  return { ok = true }
end

--- 删掉一个对话（`args.id` 不给就是当前那个）。
---
--- ⚠️ 只剩一个时**不删而是清空**：一个对话都没有的界面很难用（清单空着，
--- 用户得先点一下"新建"），而"这是最后一段记录"这个场合里，清空与删除
--- 对用户是同一件事。⚠️ 清空时**把它重新打开**，否则"只剩一个、而且是关着的"
--- 会变成一个没有输入框的界面。
function M.drop_chat(nota, id)
  local i = id and find_chat(id) or cur
  if not i or not chats[i] then
    return { ok = false, error = T("That chat is gone") }
  end

  if #chats <= 1 then
    chats[i] = fresh(chats[i].id)
    cur = i
    nota.ui.notify(T("Cleared this chat"), "info")
  else
    table.remove(chats, i)
    if cur > #chats then
      cur = #chats
    end
    M.current()
    nota.ui.notify(T("Deleted this chat"), "info")
  end
  touch(nota)
  return { ok = true }
end

--- 把「AI 可读的文件」挂上 / 摘下（`args.path` 是工作区里的相对路径）。
function M.toggle_scope(nota, path)
  local c = M.current()
  if not c then
    return { ok = false, error = T("No chat is open") }
  end
  local on, err = scope.toggle(nota, c, path)
  if on == nil then
    nota.ui.notify(err, "warn")
    return { ok = false, error = err }
  end
  touch(nota)
  nota.ui.notify(
    on and T("%s is now readable by the AI in this chat.", path)
      or T("%s is no longer readable by the AI.", path),
    "info"
  )
  return { ok = true }
end

function M.apply_patch(nota)
  local chat = M.current()
  if not chat then
    return { ok = false, error = T("No chat is open") }
  end
  if not chat.patch then
    return { ok = false, error = T("There are no changes waiting to be applied") }
  end

  local doc = nota.document.get_text() or ""
  local new_text, err = M.apply(nota, doc, chat.patch.hunks)
  if not new_text then
    -- **文档一个字都没动**（`apply_patch` 失败时不返回半截结果）。
    nota.ui.notify(T("The changes could not be applied: %s", err), "error")
    return { ok = false, error = err }
  end

  nota.document.set_text(new_text)
  chat.msgs[#chat.msgs + 1] = { role = "note", text = T("(These changes have been applied.)") }
  chat.patch = nil
  -- ⚠️ 改动没了，编辑区那一份就**自己收起来**（宿主不收：它不知道
  -- 「应用改动」是什么意思，见 `lua/api/ui.rs::预览改动表`）。
  nota.ui.review_diff(nil)
  touch(nota)
  nota.ui.notify(T("The changes have been written to the document; Ctrl+Z undoes them"), "success")
  return { ok = true }
end

--- 丢掉待应用的改动（**不动文档**）。
function M.discard_patch(nota)
  local chat = M.current()
  if not chat then
    return { ok = false, error = T("No chat is open") }
  end
  if chat.patch then
    chat.msgs[#chat.msgs + 1] = { role = "note", text = T("(These changes were discarded.)") }
    chat.patch = nil
  end
  -- 同上：改动作废了，编辑区那一份收起来。
  nota.ui.review_diff(nil)
  touch(nota)
  return { ok = true }
end

--- 把某一条消息**展开 / 收起**（第 59 项）。
---
--- ⚠️ 这是**纯界面状态**，所以不进 `store`（存了的话，下次开应用还是全展开的，
--- 而用户当时为什么展开的那条早滚出屏幕了）。也不落盘、不算进任何预算。
function M.toggle_expanded(nota, chat, i)
  if not chat then
    return { ok = false, error = T("No chat is open") }
  end
  local n = tonumber(i)
  if not n or n < 1 or n > #chat.msgs then
    return { ok = false, error = T("That message is gone") }
  end
  chat.expanded = chat.expanded or {}
  if chat.expanded[n] then
    -- 收起时**把键删掉**（`= nil`）：留一个 `false` 也不影响正确性，
    -- 但"展开过哪些"这件事就再也清不干净了。
    chat.expanded[n] = nil
  else
    chat.expanded[n] = true
  end
  nota.ui.refresh()
  return { ok = true }
end

return M
