-- 把 AI 助手那一栏**画出来**：上方的对话标签页、消息、待应用的改动、输入卡片、
-- 两个次要开关、以及"设置在哪"那一句。
--
-- 2026-09-29 从 `main.lua` 按功能拆出来（那一份当时 997 行）。拆的线是
-- 「**谁只读、谁改东西**」：本文件里**没有一个函数改状态**——从头到尾只做一件事，
-- 把 `chat.lua` / `scope.lua` 里那两份账**翻译成一列内容块**（`kind = "fields"` /
-- `"buttons"` / `"message"` / `"diff"` / `"input"`……那一套见 `docs/13` §面板内容块）。
--
-- ⚠️ 这条例外的只有一处：`M.content` 读得到**当前那个对话**，而"当前是哪个"是
-- `chat.lua` 的账。所以它只调 `chat.current()` / `chat.count()` 这几个**取用**函数，
-- 拿到的表只读不写——写的那几条（新开 / 切 / 关 / 删 / 应用 / 展开）都在 `chat.lua` 里。
--
-- | 文件 | 管什么 |
-- |---|---|
-- | `util.lua` | 公共词汇：设置项的键、`read_setting` / `cut` / `len` 这几个小工具 |
-- | `chat.lua` | 对话（状态 ＋ 请求 ＋ 改动块） |
-- | `store.lua` | 对话落盘 |
-- | `scope.lua` | 「AI 可读的文件」 |
-- | **本文件** `panel.lua` | 把上面那几份画成右侧栏那一列内容块（**只读**） |
-- | `main.lua` | 插件外壳：`on_load` / 命令注册 / 菜单与面板声明 |
--
-- # ⚠️ 2026-10-10：整块版面按用户那句「要让它更现代」重排过
--
-- 用户原话是「**修改AI插件。……要让它更现代，类似这种**」（附一张 DeepSeek 的
-- 对话框截图）＋「**API等设置专门放一个窗口**」＋「**对话用标签页管理，在上方**」。
-- 于是这一栏从"一列按钮和清单"变成一张对话框，顺序是（从上到下）：
--
-- 1. **标签页**（`kind = "tabs"`，开着的对话各一颗，末尾一颗「＋」）；
-- 2. 消息（一句话都没说时是 `kind = "hero"` 那一行问候）＋ 待应用的改动；
-- 3. **输入卡片**（`kind = "input"`：多行框 ＋ 一排预设小按钮 ＋ 发送键）；
-- 4. 两张**次要开关**（「可读文件」「已关掉的」）——摊开的那两块跟在它们后面；
-- 5. 最后一行灰字：**「API 与模型在设置里」**。
--
-- ⚠️ **五格设置整块搬去了「设置 → 拓展」那扇窗**（2026-10-10）：
-- 地址 / 模型 / 密钥 / 可读上限 / 边生成边显示，现在由宿主画
--（清单里的 `[[settings]]`，见 `plugin.toml` 底下那一段）。从前它们挤在面板最下面、
-- 占掉半屏，而"填一次就不再看"的东西不该常驻在一个聊天窗口里——这也正是用户
-- 那句话的意思。⇒ 本文件里那一段（`settings_blocks`）**整块删掉了**。
--
-- ⚠️ `T` 也要 `bind_text`（`main.lua` 的 `on_load` 里那一句），理由见 `util.lua` 文件头。
-- ⚠️ 变量名一律 ASCII（理由写在 `main.lua` 文件头）。

-- ── 这一栏自己的两个显示开关 ─────────────────────────────────────────────
--
-- 「可读文件」与「已关掉的对话」两块默认**收着**：它们都是"偶尔用一次"的东西，
-- 摊开时会各占掉半屏（文件最多 5 颗按钮、已关掉的对话还可能更多），而聊天的
-- 主视线只该有"消息 ＋ 输入框"。
--
-- ⚠️ **状态住在本模块**，`main.lua` 只经 `M.scope_open()` / `M.toggle_scope_open()`
-- 那两对读写——与 `diff.lua` 那份 `show_diff` 同一条口径（`docs/12` §5.9）：
-- 谁的东西谁拿着，别让"两处各存一份"变成"按一下按钮、面板里却没变"。
local show_scope = false
local show_closed = false

local util = require("util")
local chat = require("chat")
local scope = require("scope")

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
--（另外两条上限跟对话走，在 `chat.lua`；对文件的那条在 `scope.lua`。）

--- 面板上最多画最近几条消息。
local SHOW_MSGS = 8

--- 一块改动最多画多少行。**只是画**——应用用的是完整的那份。
local SHOW_DIFF_LINES = 120

--- 一条消息**收起时**最多画多少字（第 59 项）。
---
--- ⚠️ 这两个数从前是 15000 / 1000，也就是"几乎不折"。260px 宽的一栏里，
--- 15000 字是几百行，一屏里那一条就把别的全顶出去了——而用户真正要的
--- 是"扫一眼这段说了什么"。想细读就点那颗「展开全文」，它就在同一条下面。
local PREVIEW_AI = 1500
local PREVIEW_USER = 300

--- 宿主一次最多画多少字的**一块文本**。
---
--- ⚠️ 抄一份在插件里是**不得不**：宿主与前端对一条文本的兜底都是 20000 字
--- （`lua/api/ui.rs::面板文本上限` / `ui/panel-nodes.ts::消息上限`），而它们
--- 超了就**闷声截断**、只留一个 `…`。压在它们下面，用户看到的就是我们自己
--- 那句"只画到这儿"——那正是第 59 项要的那件事：**别让"看不见"是无声的**。
--- 宿主那边改了数，这里要跟着改（`docs/07` 第 59 项记着）。
local HOST_TEXT_MAX = 20000

--- 「AI 可读的文件」那一排按钮上的两个记号：挂着 / 没挂。
---
--- ⚠️ 写成常量而**不是直接写在 `label = "✓ " .. p` 里**：`tools/i18n-check.sh`
--- 会把 `label = "…"` 当成一条**文案键**（那条规矩是为了 `PRESETS` 那种
--- "表里存原文、用的时候才 `T(...)`"的写法，见它 §③）。这两个记号是符号、
--- 不进翻译表，写成字面量的话它每次都会报"还有两条没翻"。
local ON = "✓ "
local OFF = "○ "

-- ── 对话：上方的标签页 ────────────────────────────────────────────────────

--- 关着的那几个对话（下标 + 对话本身）。**两处要用**（那两颗小开关的计数、
--- 摊开时那一列），所以只数一遍。
local function closed_chats()
  local out = {}
  for i = 1, chat.count() do
    local c = chat.at(i)
    if not c.open then
      out[#out + 1] = { c = c, i = i }
    end
  end
  return out
end

--- 上方那一排标签页：**开着的对话各一颗**（第 61 项 (a) 那一件，2026-10-10 换的形）。
---
--- ⚠️ 标题存的是**原文**（`chat.lua::fresh` 那个"新对话"是模块级求值的，
--- 那时 `T` 还是占位符），所以这里要现取一次译文。
---
--- ⚠️ 一颗标签是**两颗动作**：点字面切过去（`switch_chat`）、点右边那颗小叉关掉
--- （`close_chat`，2026-10-10 起它认 `id`，所以关的不一定是当前那个）。
--- 关**不是删**（第 61 项 (b)）：关掉的那个只是不再进上下文，随时能再打开——
--- 所以那颗叉**不画成红的**，而且它挂在每一颗标签上不会误伤（红色那颗在
--- 「已关掉的」摊开之后才出现）。
local function tabs_block()
  local items = {}
  for i = 1, chat.count() do
    local c = chat.at(i)
    if c.open then
      local title = T(c.title)
      items[#items + 1] = {
        label = title,
        active = (i == chat.cur_index()),
        pick = {
          command = "switch_chat",
          args = { id = c.id },
          title = T("Switch to “%s”", title),
        },
        close = {
          command = "close_chat",
          args = { id = c.id },
          title = T("Close “%s” — it leaves the context, and you can open it again", title),
        },
      }
    end
  end
  return {
    kind = "tabs",
    items = items,
    new = { command = "new_chat", title = T("New chat") },
  }
end

--- 关着的那些：**那一块摊开时**画的一列（默认收着，见上面那两个开关）。
local function closed_blocks()
  local closed = closed_chats()
  if #closed == 0 then
    return {}
  end
  local blocks = {
    {
      kind = "text",
      tone = "muted",
      text = T("Closed chats (%d). They are out of the context; open one to talk to it again.", #closed),
    },
  }
  local closed_items = {}
  for _, e in ipairs(closed) do
    local title = T(e.c.title)
    -- ⚠️ 记号走 `OFF` 那个常量（理由见它上面那段）：`label = "○ " .. x` 这种写法
    -- 会被 `tools/i18n-check.sh` §③ 当成一条**文案键**，而它是符号、不进翻译表。
    closed_items[#closed_items + 1] = {
      label = OFF .. title,
      command = "reopen_chat",
      args = { id = e.c.id },
    }
  end
  blocks[#blocks + 1] = { kind = "buttons", items = closed_items }

  -- ⚠️ 关着的也要能**删**：先打开再删是条路，但用户想清的正是"我不想再看见它"，
  -- 逼他先把它打开一遍是反的。所以单独给一排红的，一颗对一个。
  local drop_items = {}
  for _, e in ipairs(closed) do
    drop_items[#drop_items + 1] = {
      label = T("Delete “%s”", T(e.c.title)),
      command = "del_chat",
      args = { id = e.c.id },
      style = "danger",
    }
  end
  blocks[#blocks + 1] = { kind = "buttons", items = drop_items }
  return blocks
end

-- ── 消息 ──────────────────────────────────────────────────────────────────

--- 一条消息 ＋（够长时）一颗「展开全文」。
---
--- 返回一串块：**主块在前，按钮在后**——按钮长在这条消息下面，而不是飘到
--- 这一列的最后去。
local function one_message(nota, c, i, m, is_last)
  local blocks = {}
  local full = m.text
  local is_ai = (m.role == "assistant")

  if is_ai then
    -- ⚠️ 显示的是**拆掉改动块之后的正文**：改动块在下面单独画成一块 diff，
    -- 两处都画一遍，用户要读的东西就被夹在中间了。
    local p = chat.parse(nota, full)
    full = p.text
    if full == "" then
      full = T("(This round had only a change block and nothing else.)")
    end
  end

  local chars = util.len(full)
  local shown = (c.expanded or {})[i]

  if m.role == "assistant" then
    local limit = shown and HOST_TEXT_MAX or PREVIEW_AI
    -- ⚠️ `copy = true`（2026-10-10）：宿主在每一条底下画一颗「复制」。
    -- 插件这边没有剪贴板 API，所以这是一句**请求**，不是一条命令
    --（见 `docs/13` 那条 `kind = "message"`）。
    blocks[#blocks + 1] = { kind = "message", from = "ai", text = util.cut(full, limit), copy = true }
  elseif m.role == "user" then
    local limit = shown and HOST_TEXT_MAX or PREVIEW_USER
    blocks[#blocks + 1] = { kind = "message", from = "user", text = util.cut(full, limit), copy = true }
  elseif m.role == "error" then
    -- 失败的那一轮。**用 danger 画**：它是一句要用户处理的话（密钥不对、
    -- 连不上），不是聊天内容。
    blocks[#blocks + 1] = { kind = "text", tone = "danger", text = full }
  else
    -- `note` 之类：旁白，灰色。
    blocks[#blocks + 1] = { kind = "text", tone = "muted", text = full }
  end

  -- 只有真被截过的那几条才画按钮。⚠️ **`user` 也画**：用户自己敲的长段落
  -- 一样会被折，凭什么它就不能展开。
  local preview = is_ai and PREVIEW_AI or PREVIEW_USER
  if is_ai or m.role == "user" then
    if chars > preview then
      blocks[#blocks + 1] = {
        kind = "buttons",
        items = {
          {
            label = shown and T("Collapse") or T("Show all (%d characters)", chars),
            command = "expand_msg",
            args = { i = i },
          },
        },
      }
    end
  end

  -- ⚠️ 展开之后**还是画不完**的话，明说一句。第 59 项那句"只把上限调大不算解决"
  -- 说的就是这个：上限调到多少都有可能不够，**能看见"还不够"**才是解决。
  if shown and chars > HOST_TEXT_MAX then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("(This message has %d characters; the panel can draw at most %d of them.)", chars, HOST_TEXT_MAX),
    }
  end

  -- ⚠️ **最后一条是 AI 回答时**，底下挂一颗「重试」（2026-10-10 加）。
  -- 判据与理由写在 `chat.lua::retry_last` 那段：末尾是错误说明时不给
  --（重试一次还是同样结果），还在生成时宿主会把按钮灰着（`busy`）。
  if is_last and m.role == "assistant" then
    blocks[#blocks + 1] = {
      kind = "buttons",
      items = { { label = T("Ask again"), command = "retry_last" } },
    }
  end

  return blocks
end

--- 对话本身：最近几条消息。
local function messages_blocks(nota, c)
  local blocks = {}
  local msgs = c.msgs

  if #msgs == 0 then
    -- ⚠️ 空对话那一屏 2026-10-10 从 `empty`（一句小灰字）换成 `hero`
    --（一行大字 ＋ 一行小字）：现代对话框在一句都没聊时画的就是这个，
    -- 而用户那句"要让它更现代"要的正是这一眼的差别。
    blocks[#blocks + 1] = {
      kind = "hero",
      title = T("Hello — let's chat"),
      subtitle = T("Nothing said yet. Type below, or press a preset."),
    }
    return blocks
  end

  local start_i = math.max(1, #msgs - SHOW_MSGS + 1)
  if start_i > 1 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("(Only the latest %d are shown; this chat has %d in total.)", SHOW_MSGS, #msgs),
    }
  end

  for i = start_i, #msgs do
    for _, b in ipairs(one_message(nota, c, i, msgs[i], i == #msgs)) do
      blocks[#blocks + 1] = b
    end
  end

  return blocks
end

-- ── 待应用的改动 ──────────────────────────────────────────────────────────

--- 待应用的那块改动。**只画在右侧栏那一份里**。
---
--- ⚠️ 那颗「在编辑区看」是这里唯一画它的地方，所以没有"要不要画"这个参数了：
--- 编辑区那一份（`review_blocks`）2026-09-26 已经取消——它现在直接画在正文上，
--- 用不着先摆一颗"去编辑区"的按钮再点一下。
local function patch_blocks(c)
  local blocks = {}
  local patch = c.patch
  if not patch then
    return blocks
  end

  blocks[#blocks + 1] = { kind = "separator" }
  blocks[#blocks + 1] = { kind = "heading", text = T("Changes waiting to be applied (not yet written to the document)") }

  if patch.bad and patch.bad > 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("%d lines in the change block are neither - nor +; they were ignored.", patch.bad),
    }
  end

  local many = #patch.hunks > 1
  local drawn, total = 0, 0
  for i, h in ipairs(patch.hunks) do
    if many then
      blocks[#blocks + 1] = { kind = "text", tone = "muted", text = T("Change %d", i) }
    end
    local items = {}
    for _, line in ipairs(h.del) do
      total = total + 1
      if drawn < SHOW_DIFF_LINES then
        items[#items + 1] = { op = "del", text = line }
        drawn = drawn + 1
      end
    end
    for _, line in ipairs(h.add) do
      total = total + 1
      if drawn < SHOW_DIFF_LINES then
        items[#items + 1] = { op = "add", text = line }
        drawn = drawn + 1
      end
    end
    blocks[#blocks + 1] = { kind = "diff", items = items }
  end

  if total > drawn then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("(%d lines in total; only the first %d are drawn here — “Apply changes” writes the complete set.)",
        total,
        drawn
      ),
    }
  end

  local items = {
    { label = T("Apply changes"), command = "apply_patch", style = "primary" },
    { label = T("Discard changes"), command = "discard_patch" },
    -- ⚠️ 右侧那 260px 里，这种 diff 只能挤出改动的那几行，而"这一改对不对"
    -- 恰恰要看上下文。所以给一条**换到正文那么宽去看**的路——它现在把改动
    -- 就地画在正文上（`review_patch`），正文一个字不动。
    { label = T("View in editor"), command = "review_patch" },
  }
  blocks[#blocks + 1] = { kind = "buttons", items = items }

  return blocks
end

-- ── 可读的文件（第 61 项 (c)）─────────────────────────────────────────────

--- 「AI 可读的文件」那一段：开关 ＋ 预算。
---
--- ⚠️ **不读文件内容**：这一段每次刷新都跑，而 5 个 `.md` 加起来可能是几 MB。
--- 这里只列名字（`nota.fs.list` 一次 `read_dir`），大小的事交给 `scope.render`——
--- 它只在**真要发请求的时候**跑一次，而"哪个文件被截了"会作为一条旁白
--- 落在对话里给用户看（`chat.lua::M.send`）。
local function scope_blocks(nota, c)
  local blocks = {}
  local picked = c.scope or {}

  blocks[#blocks + 1] = { kind = "heading", text = T("Files the AI may read in this chat") }
  blocks[#blocks + 1] = {
    kind = "text",
    tone = "muted",
    text = T("At most %d files, %d characters counted together. This belongs to this chat only.",
      scope.MAX_FILES,
      scope.budget(nota)
    ),
  }

  local files, err = scope.available(nota)
  if not files then
    blocks[#blocks + 1] = { kind = "text", tone = "warn", text = err }
    return blocks
  end

  local items = {}
  -- 已选的先画（**包括那些已经不在了的**）：不画的话用户就摘不掉它，
  -- 而它每一轮都会去读一次、失败一次、在对话里留一句。
  for _, p in ipairs(picked) do
    items[#items + 1] = {
      label = ON .. p,
      command = "toggle_scope",
      args = { path = p },
      style = "primary",
    }
  end
  for _, p in ipairs(files) do
    if not scope.has(c, p) then
      items[#items + 1] = { label = OFF .. p, command = "toggle_scope", args = { path = p } }
    end
  end

  if #items == 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("There is no .md file in the workspace root (only the top level is listed)."),
    }
    return blocks
  end

  blocks[#blocks + 1] = { kind = "buttons", items = items }
  return blocks
end

-- ── 设置（挪到了最下面）───────────────────────────────────────────────────
--
-- ⚠️ **2026-10-10：这里从前是本文件里最长的一段**（五行现状 ＋ 五颗带 prompt 的
-- 按钮：改密钥 / 改地址 / 改模型 / 改可读上限 / 边生成边显示）。用户那句「API等
-- 设置专门放一个窗口」之后，五格**整块搬去了「设置 → 拓展」**——宿主照着
-- `plugin.toml` 底下那五段 `[[settings]]` 画（`docs/11` §2.5）。这一栏里只剩
-- **一句指路的话**，因为它再也读不到"用户配了什么"之外的任何东西要管。

--- 最后那一句灰字：设置在哪。
---
--- ⚠️ **这里只指路、不摆按钮**：插件没有"打开设置窗"这条 API（`docs/13` §8），
--- 面板上摆一颗点不动的按钮比不摆更坏（见 `buttons` 那条"没写 command 就画成灰的"
--- ——那是对**作者**的提醒，不是给用户的界面）。
local function settings_hint()
  return {
    kind = "text",
    tone = "muted",
    text = T("API key, endpoint, model and the other options are in Settings → Extensions."),
  }
end

-- ── 那两张次要开关（可读文件 / 已关掉的）──────────────────────────────────

--- 两张小开关。**只在那一块真有东西时给**（没有已关掉的对话就不摆第二颗）：
--- 一颗点了什么都不发生的开关，比没有这颗更让人困惑。
local function more_blocks(nota, c)
  local items = {
    {
      label = T("Files the AI may read (%d)", #(c.scope or {})),
      command = "toggle_scope_view",
      style = show_scope and "primary" or "normal",
    },
  }
  local closed = closed_chats()
  if #closed > 0 then
    items[#items + 1] = {
      label = T("Closed chats (%d)", #closed),
      command = "toggle_closed_view",
      style = show_closed and "primary" or "normal",
    }
  end
  return { { kind = "buttons", items = items } }
end

-- ── 整栏 ──────────────────────────────────────────────────────────────────

--- 面板此刻该显示什么。**每次拉都现跑**（见 `docs/13` §render）。
---
--- ⚠️ 局部变量叫 `c` 而不是 `chat`：`chat` 这个名字在本文件里是**那个模块**
---（顶上 `local chat = require("chat")`），撞名了不会报错，只会静悄悄地调错东西。
function M.content(nota)
  local c = chat.current()
  local key = util.read_setting(nota, util.KEY_API, "")
  local blocks = {}

  -- ① 标签页在最上面（第 61 项 (a)，2026-10-10 换的形）。
  blocks[#blocks + 1] = tabs_block()

  -- ⚠️ 标签页底下跟一行**小灰字**：现在用的是哪个模型。
  -- 这一格从前住在面板最下面那五格"现状"里；整块搬走之后，"我在跟哪个模型说话"
  -- 这条该留在聊天时看得见的地方——现代对话框把它画在标题底下（用户点名参照的
  -- 那份 Markra 源码也是这个位置），而**地址与密钥**不在这儿：那是设置，
  -- 不是聊天时该占位置的东西。
  blocks[#blocks + 1] = {
    kind = "text",
    tone = "muted",
    text = T("Model: %s", util.read_setting(nota, util.KEY_MODEL, util.DEFAULT_MODEL)),
  }

  -- ② 一个开着的对话都没有（所有对话都被关掉了）→ 只剩指路的一句。
  -- ⚠️ 这一屏**不画 hero ＋ 输入框**：没有对话就没有地方放那条消息，
  -- 画了等于让用户敲一段话、按发送、拿一句"没有打开的对话"。
  if not c then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("No chat is open. Press “＋”, or open one of the closed chats below."),
    }
    for _, b in ipairs(closed_blocks()) do
      blocks[#blocks + 1] = b
    end
    blocks[#blocks + 1] = settings_hint()
    return blocks
  end

  -- ③ 消息（空对话时那一块是 `hero`）＋ 待应用的改动。
  for _, b in ipairs(messages_blocks(nota, c)) do
    blocks[#blocks + 1] = b
  end
  for _, b in ipairs(patch_blocks(c)) do
    blocks[#blocks + 1] = b
  end

  -- ④ 输入卡片：多行框 ＋ 一排预设 ＋ 发送键（`kind = "input"`，2026-10-10
  -- 起它还认 `chips`）。
  if key == "" then
    -- ⚠️ 没密钥时**连输入框都不画**：画了的话用户敲一段话、按发送、等几秒、
    -- 拿到一句"还没填密钥"。不如把话先说在前面——而且现在能直接告诉他去哪儿填。
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("No API key yet. Fill it in under Settings → Extensions; the input box appears once that is done."),
    }
  else
    local chips = {}
    for _, id in ipairs(chat.preset_order()) do
      -- ⚠️ 预设名**现取译文**（`chat.lua` 里那张 `PRESETS` 是模块级常量，求值时 `T` 还没接上宿主）。
      chips[#chips + 1] = { label = T(chat.preset(id).label), command = id }
    end
    blocks[#blocks + 1] = {
      kind = "input",
      arg = "text",
      submit = "send",
      submit_label = T("Send"),
      placeholder = T("Ask something, or have it edit the document…"),
      -- 多行框里回车是换行，发送是 Ctrl+Enter（前端 `PanelBody.tsx` 定的规矩）。
      hint = T("Ctrl+Enter to send · Enter for a new line"),
      multiline = true,
      chips = chips,
    }
  end

  -- ⑤ 两张次要开关 ＋（摊开时）那两块。
  for _, b in ipairs(more_blocks(nota, c)) do
    blocks[#blocks + 1] = b
  end
  if show_scope then
    for _, b in ipairs(scope_blocks(nota, c)) do
      blocks[#blocks + 1] = b
    end
  end
  if show_closed then
    for _, b in ipairs(closed_blocks()) do
      blocks[#blocks + 1] = b
    end
  end

  -- ⑥ 设置在哪（一句话，最下面）。
  blocks[#blocks + 1] = { kind = "separator" }
  blocks[#blocks + 1] = settings_hint()

  return blocks
end

-- ── 那两张次要开关的读写（`main.lua` 注册的两条命令调它们）────────────────
--
-- ⚠️ 与 `diff.lua` 的 `M.show()` / `M.toggle()` 同一套：**状态在本模块**，
-- 命令那一层只转一下手。两处各存一份的话，症状是"点了按钮、面板里没变"。

--- 「AI 可读的文件」那一块摊开了没有。
function M.scope_open()
  return show_scope
end

--- 翻一下「AI 可读的文件」那块，返回翻完的值。
function M.toggle_scope_open()
  show_scope = not show_scope
  return show_scope
end

--- 「已关掉的对话」那一块摊开了没有。
function M.closed_open()
  return show_closed
end

--- 翻一下「已关掉的对话」那块，返回翻完的值。
function M.toggle_closed_open()
  show_closed = not show_closed
  return show_closed
end

return M
