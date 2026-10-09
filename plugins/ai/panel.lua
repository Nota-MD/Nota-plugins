-- 把 AI 助手那一栏**画出来**：对话切换器、可读文件、消息、待应用的改动、预设、输入框、设置。
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
-- # ⚠️ 2026-10-04：版面的顺序按第 61 项 (a) 改过
--
-- 用户原话是「**上方可以切换不同对话**」，而当时的顺序是
-- 设置 → 对话清单 → 消息 → ……——**设置在最上面**，而清单只列最近 5 个。
-- 现在的顺序是这一列（从上到下）：
--
-- 1. **对话切换器**（全部对话，开着的在上、关着的在下）；
-- 2. 消息 ＋ 待应用的改动；
-- 3. 「AI 可读的文件」（第 61 项 (c)）；
-- 4. 预设 ＋ 输入框；
-- 5. **设置挪到了最下面**——它是一次性填完就不再看的东西，占着最上面那一屏
--    等于把"切换对话"这件事挤出去。
--
-- ⚠️ `T` 也要 `bind_text`（`main.lua` 的 `on_load` 里那一句），理由见 `util.lua` 文件头。
-- ⚠️ 变量名一律 ASCII（理由写在 `main.lua` 文件头）。

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

-- ── 对话切换器 ────────────────────────────────────────────────────────────

--- 一颗对话按钮（开着的、关着的共用一份画法）。
local function chat_button(c, i, is_open)
  return {
    -- ⚠️ 标题存的是**原文**（`chat.lua::fresh` 那个"新对话"是模块级求值的，
    -- 那时 `T` 还是占位符），所以这里要现取一次译文。
    label = (is_open and (i == chat.cur_index() and "● " or "○ ") or "· ") .. T(c.title),
    command = is_open and "switch_chat" or "reopen_chat",
    args = { id = c.id },
    style = (is_open and i == chat.cur_index()) and "primary" or "normal",
  }
end

--- 顶上那一段：**全部**对话（第 61 项 (a)）。
---
--- ⚠️ 从前只列最近 5 个，更早的只画一句"前面还有 N 个"——**那些对话既看不见
--- 也点不到**，唯一能碰到它们的办法是把更晚的删掉。这一栏是能滚的
--- （`.dock-body` 有 `overflow: auto`），列得下。
local function chats_blocks()
  local blocks = {}
  local is_open = chat.open_count()

  blocks[#blocks + 1] = {
    kind = "heading",
    text = T("Chats (%d open, %d in total)", is_open, chat.count()),
  }

  local items = { { label = T("＋ New chat"), command = "new_chat", style = "primary" } }
  if is_open > 0 then
    -- ⚠️ **关闭**，不是删除（第 61 项 (b)）：关掉的那个不再进上下文，点一下能再开。
    -- 它**不画成红色**——红色留给下面那颗真的会把记录扔掉的。
    items[#items + 1] = { label = T("Close this chat"), command = "close_chat" }
    items[#items + 1] = { label = T("Delete this chat"), command = "del_chat", style = "danger" }
  end
  for i = 1, chat.count() do
    local c = chat.at(i)
    if c.open then
      items[#items + 1] = chat_button(c, i, true)
    end
  end
  blocks[#blocks + 1] = { kind = "buttons", items = items }

  -- 关着的那几个：单独一组，带「打开」和「删除」。
  local closed = {}
  for i = 1, chat.count() do
    local c = chat.at(i)
    if not c.open then
      closed[#closed + 1] = { c = c, i = i }
    end
  end
  if #closed > 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("Closed chats (%d). They are out of the context; open one to talk to it again.", #closed),
    }
    local closed_items = {}
    for _, e in ipairs(closed) do
      closed_items[#closed_items + 1] = chat_button(e.c, e.i, false)
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
  end

  return blocks
end

-- ── 消息 ──────────────────────────────────────────────────────────────────

--- 一条消息 ＋（够长时）一颗「展开全文」。
---
--- 返回一串块：**主块在前，按钮在后**——按钮长在这条消息下面，而不是飘到
--- 这一列的最后去。
local function one_message(nota, c, i, m)
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
    blocks[#blocks + 1] = { kind = "message", from = "ai", text = util.cut(full, limit) }
  elseif m.role == "user" then
    local limit = shown and HOST_TEXT_MAX or PREVIEW_USER
    blocks[#blocks + 1] = { kind = "message", from = "user", text = util.cut(full, limit) }
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

  return blocks
end

--- 对话本身：最近几条消息。
local function messages_blocks(nota, c)
  local blocks = {}
  local msgs = c.msgs

  if #msgs == 0 then
    blocks[#blocks + 1] = {
      kind = "empty",
      text = T("Nothing said yet. Type below, or press a preset."),
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
    for _, b in ipairs(one_message(nota, c, i, msgs[i])) do
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

--- 设置那一段：五行现状 ＋ 五颗按钮。
---
--- ⚠️ 2026-10-04 各多了一行一颗：「边生成边显示」（`docs/07` 第 58 项）。
local function settings_blocks(nota, key)
  local blocks = {}

  blocks[#blocks + 1] = { kind = "heading", text = T("Settings") }

  blocks[#blocks + 1] = {
    kind = "fields",
    items = {
      { label = T("Model"), value = util.read_setting(nota, util.KEY_MODEL, util.DEFAULT_MODEL) },
      { label = T("URL"), value = util.read_setting(nota, util.KEY_BASE, util.DEFAULT_BASE) },
      {
        label = T("Key"),
        value = key ~= "" and T("configured") or T("not set"),
        tone = key ~= "" and "success" or "warn",
      },
      { label = T("Readable size"), value = T("%d characters", scope.budget(nota)) },
      -- 「边生成边显示」（`docs/07` 第 58 项）。**不开成一行字而是画在这儿**：
      -- 它是"这个插件现在怎么干活"的一部分，和上面四行是同一类东西。
      {
        label = T("Show as it is written"),
        value = util.stream_on(nota) and T("on") or T("off"),
        tone = util.stream_on(nota) and "success" or "normal",
      },
    },
  }

  blocks[#blocks + 1] = {
    kind = "buttons",
    items = {
      {
        label = key == "" and T("Set key…") or T("Change key…"),
        command = "set_key",
        style = key == "" and "primary" or "normal",
        prompt = {
          arg = "api_key",
          label = T("API key"),
          placeholder = "sk-…",
          -- ⚠️ 遮屏。密钥会明文存进 `~/.config/nota/plugin-settings/`，
          -- 这一条挡的不是存盘，是**旁边的人从肩膀上看见**。
          secret = true,
          hint = T("It is sent only to the address above. Local models (Ollama / LM Studio) usually need no key — any value will do."),
        },
      },
      {
        label = T("Change URL…"),
        command = "set_base",
        prompt = {
          arg = "base_url",
          label = T("Endpoint URL"),
          placeholder = util.DEFAULT_BASE,
          hint = T("An OpenAI-compatible URL (including /v1). For a local service you can use http://127.0.0.1:11434/v1"),
        },
      },
      {
        label = T("Change model…"),
        command = "set_model",
        prompt = {
          arg = "model",
          label = T("Model name"),
          placeholder = util.DEFAULT_MODEL,
          hint = T("The name from your provider's documentation"),
        },
      },
      {
        label = T("Change readable size…"),
        command = "set_scope",
        prompt = {
          arg = "scope_chars",
          label = T("Characters"),
          placeholder = util.DEFAULT_SCOPE,
          -- ⚠️ 这里**不写"token"**：插件数的是字符，把"token"写上去就成了
          -- 一句不准的承诺（见 `scope.lua` 文件头那张表）。
          hint = T("How many characters the readable files may take together. Roughly a quarter of that many tokens for Chinese text."),
        },
      },
      -- ⚠️ 这一条**是开关不是 prompt**（`docs/07` 第 58 项）：它没有"值"要
      -- 让人填，只有两个状态。面板那套块里没有 checkbox 这种东西（见
      -- `docs/13`），唯一的开关写法就是"按钮上的字说出按下去会怎样"。
      {
        label = util.stream_on(nota) and T("Turn off “show as it is written”") or T("Turn on “show as it is written”"),
        command = "toggle_stream",
      },
    },
  }

  return blocks
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

  -- ① 切换器在最上面（第 61 项 (a)）。
  for _, b in ipairs(chats_blocks()) do
    blocks[#blocks + 1] = b
  end
  blocks[#blocks + 1] = { kind = "separator" }

  -- ② 一个开着的对话都没有 → 下面的消息/预设/输入框统统不画。
  if not c then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("No chat is open. Press “＋ New chat”, or open one of the closed chats above."),
    }
    for _, b in ipairs(settings_blocks(nota, key)) do
      blocks[#blocks + 1] = b
    end
    return blocks
  end

  for _, b in ipairs(messages_blocks(nota, c)) do
    blocks[#blocks + 1] = b
  end
  for _, b in ipairs(patch_blocks(c)) do
    blocks[#blocks + 1] = b
  end

  -- ③ 可读的文件。
  blocks[#blocks + 1] = { kind = "separator" }
  for _, b in ipairs(scope_blocks(nota, c)) do
    blocks[#blocks + 1] = b
  end

  -- ④ 预设 ＋ 输入框。
  blocks[#blocks + 1] = { kind = "separator" }
  blocks[#blocks + 1] = { kind = "heading", text = T("On the current document") }
  local items = {}
  for _, id in ipairs(chat.preset_order()) do
    -- ⚠️ 预设名**现取译文**（`chat.lua` 里那张 `PRESETS` 是模块级常量，求值时 `T` 还没接上宿主）。
    items[#items + 1] = { label = T(chat.preset(id).label), command = id }
  end
  blocks[#blocks + 1] = { kind = "buttons", items = items }

  if key == "" then
    -- ⚠️ 没密钥时**连输入框都不画**：画了的话用户敲一段话、按发送、等几秒、
    -- 拿到一句"还没填密钥"。不如把话先说在前面。
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("Press “Set key…” in Settings at the bottom first; the input box appears once that is filled in."),
    }
  else
    blocks[#blocks + 1] = {
      kind = "input",
      arg = "text",
      submit = "send",
      submit_label = T("Send"),
      placeholder = T("Ask something, or have it edit the document…"),
      -- 多行框里回车是换行，发送是 Ctrl+Enter（前端 `PanelBody.tsx` 定的规矩）。
      hint = T("Ctrl+Enter to send · Enter for a new line"),
      multiline = true,
    }
  end

  -- ⑤ 设置在最下面。
  blocks[#blocks + 1] = { kind = "separator" }
  for _, b in ipairs(settings_blocks(nota, key)) do
    blocks[#blocks + 1] = b
  end

  return blocks
end

return M
