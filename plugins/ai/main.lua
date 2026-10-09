-- AI 助手插件：右侧那一栏里的**一间对话框**。
--
-- 走**任何 OpenAI 兼容的接口**（`POST {base_url}/chat/completions`）：官方 API、
-- 中转站、以及跑在自己机器上的 Ollama / LM Studio 都是同一条路。
-- 密钥和地址由用户自己填，存在 `~/.config/nota/plugin-settings/nota.ai.toml`
-- （明文，见 `docs/12` §插件设置为什么不加密）。
--
-- ⚠️ 本机服务通常**不需要密钥**，但请求里那个 `authorization` 头 Nota 照发
-- （Ollama 会忽略它）。所以面板上写着"随便填一个"——不填的话插件没法区分
-- "他还没配"和"这个服务不要密钥"。
--
-- # 一次对话长什么样（用户 2026-09-24 定的）
--
-- > 你要让 AI 生成 diff……应该是有一个对话框，然后 AI 可以做出普通文本的回复。
-- > 在末尾用特殊标注写 diff。
--
-- 所以每一轮回答都是**两段**：
--
-- 1. **普通文本**（可以直接读的那段话）——画成对话里的一条消息；
-- 2. 需要改文档时，**最末尾**再附一个改动块：用围栏 ````nota-diff` 包起来，
--    `-` 开头的是"原文里要被换掉的那几行"，`+` 开头的是"换上去的新话"。
--
-- 界面上画成一块 `kind = "diff"` 的内容块（宿主只负责画，不认识"改动块"这个概念）。
-- **解析与应用走宿主的 `nota.diff`**（`src-tauri/src/lua/api/diff.rs`）：
-- 那份格式不是 AI 专有的，而且它是唯一会改坏文档的地方，得能拿 Rust 单元测试钉住。
-- 契约见 `docs/13-lua-api.md` §「AI 改动块」——那是全局那份。
--
-- # ⚠️ 一条设计原则：**AI 的输出不许直接落进文档**
--
-- 从第一版起就没变过，现在更硬：改动**先解析成一份待应用的清单**，在面板上
-- 画成一块 diff，用户点「应用改动」才 `set_text`。理由很实在——模型会犯错，
-- 而"文档被悄悄改掉、用户按了 Ctrl+Z 才发现"是最坏的一种错。
--
-- 另一条同样重要：**改动是按"逐字找到那几行"应用的**（`nota.diff.apply`），
-- 不是"从头覆盖整篇"。所以应用失败时文档**一个字都没动**，只会报"没找到"。
-- 这比"改了一半"好得多。
--
-- # 多对话（2026-10-04 按第 57 / 61 项改过）
--
-- 面板**最上面**是切换器：可以开新的、切回去、**关掉**（从上下文里拿掉，
-- 还能再打开）、**删除**（记录扔掉——两件事，两个按钮）。每个对话有自己
-- 的消息历史、待应用的改动、以及「AI 可读的文件」那一份范围。
--
-- ⚠️ **对话会落盘**了（第 57 项）：存在 `nota.data` 那个属于本插件的角落里的
-- `chats.txt`（自定的行格式，见 `store.lua` 文件头）。关掉应用再打开还在。
-- ⚠️ **待应用的改动不存**——它是一份等着点头的临时状态，而它的 `-` 行必须与
-- 此刻的文档逐字一致（理由见 `store.lua` 文件头）。
--
-- ⚠️ 调用这几个命令**会占住一个后台线程**（HTTP 是阻塞的，见
-- `src-tauri/src/lua/api/http.rs` 文件头），界面不会冻住，但一次生成要等几秒到
-- 几十秒。**没有做流式**——那是另一件事，记在 `docs/07`。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里。**
-- 这一条不是风格问题：Lua 的标识符只认 `[A-Za-z_][A-Za-z0-9_]*`
--（`lislalpha` 用的是 C 的 `isalpha`，`local 键 = 1` 里那几个 UTF-8 字节在任何
-- locale 下都不算字母），写成 `local 键_密钥 = …` 是**语法错误**，
-- 整份插件加载失败、面板和菜单一起消失。
-- 而 Lua 报的话是 `<name> expected near '<\233>'`——看到那句很难想到是名字的问题。
-- `src-tauri/src/lua/mod.rs::内置插件都能被_lua_编译` 把这条钉住了。
--
-- # ⚠️ 2026-09-29 起按功能拆成了好几份
--
-- 这个文件当时 997 行，离 `docs/09` §4 那条 1000 行的硬线只剩三行——一个字都加不
-- 进去了。用户这一轮给的新尺子是「不要每个代码文件都 1000 行，998 行这样，要宽松
-- 一些。比如 300、500、800 这样。根据功能拆分」，于是按**职责**分了家：
--
-- | 文件 | 管什么 |
-- |---|---|
-- | `util.lua` | 公共词汇：设置项的键与默认值 ＋ `read_setting` / `join_url` / `cut` / `len` / `trim` / `clean_error` / `now_ms` |
-- | `request.lua` | **发一次请求**（2026-10-04 加，第 58 项）：整段/流式两条路、解回包 |
-- | `chat.lua` | 对话那一半：状态（`chats` / `cur` / `next_id`）＋ 组消息 ＋ 改动块 ＋ 几条改状态的命令体 |
-- | `store.lua` | 对话落盘（2026-10-04 加，第 57 项）：`nota.data` 里一份自定的行格式 |
-- | `scope.lua` | 「AI 可读的文件」（2026-10-04 加，第 61 项 (c)） |
-- | `panel.lua` | 把上面那几份画成右侧栏那一列内容块（**只读**，一个字节都不改） |
-- | **本文件** | 插件外壳：`on_load` / `nota.command.register` / 菜单与面板声明 |
--
-- ⚠️ 分家的线是「**谁只读、谁改东西**」、「**谁要碰网络**」、「**谁碰 HTTP**」，
-- 不是按行数从中间切一刀。⚠️ 依赖方向**始终单向**：
-- `chat` → `request` → `util`，`panel` → `util`；没有反向的边。
--
-- ⚠️⚠️ **每个模块各有一份自己的 `T`**，都必须由下面 `on_load` 里那几句
-- `bind_text(T)` 接上（这是 `require` 那条路上的通用规律，写在 `docs/12` §5.9）。
-- 少了哪一句**都不会报错**，只是那一块里的英文在中文界面上不翻——差异那几块
-- 在 `plugins/git/diff.lua` 上已经踩过一次同样的坑。**加了模块就要加一句**，
-- 这是这一族里最容易漏的一件事。

local M = {}

-- ── 转接 ──────────────────────────────────────────────────────────────────
--
-- ⚠️ 下面这三个 `require` 走的是宿主那套**插件多文件**机制（`docs/12` §5.9）：
-- 只能 require 本插件目录里的 `.lua`，模块名不带 `.lua`、不带路径。
-- ⚠️ `require` 的结果**取一次就够**：模块只求值一次，后面再来拿的是同一张表
--（`docs/12` §5.9 那条"只求值一次"）。

local util = require("util")
local request = require("request")
local chat = require("chat")
local store = require("store")
local scope = require("scope")
local panel = require("panel")

-- ── 文案 ──────────────────────────────────────────────────────────────────
-- `T("原句")` 取译文（**键就是原文**，表在 `lang/`）。⚠️ **原文是英语**
--（2026-09-28 起），译文进 `lang/zh-CN.toml`；规矩见 `docs/13` §nota.i18n。
-- ⚠️ `T` 在 `on_load` 里重新绑一次（`nota` 到那时才到手）；译文里的 `%` 写成 `%%`。
-- ⚠️（这里从前还跟着一句「这个文件贴着 1000 行上限，所以注释比另两个插件短」——
-- 2026-09-29 拆成四份之后不成立了，见文件头。其余三份各有自己的一份 `T`。）
local T = function(s) return s end

-- ── 生命周期 ──────────────────────────────────────────────────────────────

--- 存一个设置项。空串 = **清掉**（回到默认值）——`PromptDialog` 那边把
--- "清空再确定"当取消，所以这条主要给"命令被别的插件调"的场合兜底。
local function save_setting(nota, key, value, what)
  if value == nil or value == "" then
    nota.settings.set(key, nil)
    -- `what` 由调用方给（"密钥"/"接口地址"/"模型"，见下面几条命令），
    -- 所以**里外都要过一次 `T`**：里面的键是那个词，外面的键带 `%s`。
    nota.ui.notify(T("%s restored to its default", T(what)), "info")
  else
    nota.settings.set(key, value)
    nota.ui.notify(T("%s saved", T(what)), "success")
  end
  nota.ui.refresh()
  return { ok = true }
end

function M.on_load(nota)
  -- ⚠️ **第一件事**:把文案接上宿主给的这张表（见上面 `local T` 那段）。
  T = function(fmt, ...)
    local s = nota.i18n and nota.i18n.text(fmt) or nil
    s = s or fmt
    if select("#", ...) > 0 then
      return string.format(s, ...)
    end
    return s
  end

  -- ⚠️ **第二件事**：把这个 `T` 分给另外几个模块（它们各有一份自己的 `T`）。
  -- 少一句的症状写在文件头：不报错，只是那几块里的英文不翻。
  util.bind_text(T)
  request.bind_text(T)
  chat.bind_text(T)
  store.bind_text(T)
  scope.bind_text(T)
  panel.bind_text(T)

  -- ⚠️ **第三件事**：把上次那几段对话读回来（第 57 项）。
  -- 顺序要紧：**必须在 `bind_text` 之后、`register_panel` 之前**——面板第一次
  -- 拉内容时那份记录得已经在手里了，否则用户会看见一个空栏闪一下再填上。
  -- ⚠️ 读不到 / 读不懂**不报错**（第一次用这个插件时那个文件本来就不存在，
  -- 那不是故障），保持开局那一个空对话，见 `chat.load`。
  chat.load(nota)

  -- 每个预设一条命令。用循环而不是抄五遍——抄五遍的版本一定会有一处名字
  -- 或提示词写错，而那种错只有点下去才发现。
  for _, id in ipairs(chat.preset_order()) do
    -- ⚠️ 循环变量必须**当场捕获**到 `local`：Lua 的数值 for 每轮虽然换了值，
    -- 但闭包捕获的是同一个名字——不 `local` 一份的话，五个命令会全部指向
    -- 最后一个预设。这类错不报错，只是"点润色出来的是翻译"。
    local captured = id
    nota.command.register(captured, function()
      return chat.run_preset(nota, captured)
    end)
  end

  --- 用户在面板里敲的一句话。`args.text` 是输入框里的内容。
  nota.command.register("send", function(args)
    local text = args and args.text
    if type(text) ~= "string" or util.trim(text) == "" then
      return { ok = false, error = T("Nothing to send") }
    end
    -- ⚠️ 一个开着的对话都没有是**合法状态**（用户可以把它们全关掉），
    -- 那时 `chat.current()` 给 `nil`——`chat.send` 自己会说一句。
    return chat.send(nota, chat.current(), util.trim(text))
  end)

  --- 开一个新对话，并切过去。
  --- ⚠️ 本体在 `chat.lua`（它管着 `chats` / `cur` / `next_id` 那三本账）。
  nota.command.register("new_chat", function()
    return chat.new_chat(nota)
  end)

  --- 切到某个对话。`args.id` 是编号（`panel.lua` 的对话清单里发出的那个）。
  nota.command.register("switch_chat", function(args)
    return chat.switch_chat(nota, args and args.id)
  end)

  --- **关闭**当前对话：从上下文里拿掉，记录留着，随时能再打开（第 61 项 (b)）。
  nota.command.register("close_chat", function()
    return chat.close_chat(nota)
  end)

  --- 重新打开一个关着的对话。`args.id` 同上。
  nota.command.register("reopen_chat", function(args)
    return chat.reopen_chat(nota, args and args.id)
  end)

  --- 删掉一个对话（`args.id` 不给就是当前那个）。
  --- ⚠️ 只剩一个时**不删而是清空**：一个对话都没有的界面很难用（清单空着，
  --- 用户得先点一下"新建"），而"这是最后一段记录"这个场合里，清空与删除
  --- 对用户是同一件事。那条判据在 `chat.lua` 里。
  nota.command.register("del_chat", function(args)
    return chat.drop_chat(nota, args and args.id)
  end)

  --- 把某一条消息展开 / 收起（第 59 项）。`args.i` 是消息在对话里的**下标**。
  nota.command.register("expand_msg", function(args)
    return chat.toggle_expanded(nota, chat.current(), args and args.i)
  end)

  --- 把「AI 可读的文件」挂上 / 摘下（第 61 项 (c)）。`args.path` 是工作区里的相对路径。
  nota.command.register("toggle_scope", function(args)
    return chat.toggle_scope(nota, args and args.path)
  end)

  --- 把待应用的改动写进文档。
  ---
  --- ⚠️ **这条命令只该由用户点确认触发。** 别的地方（比如"生成完顺手调一下"）
  --- 调它，就等于绕过了那道确认。所以它只有一处调用者：`panel.lua` 里那两颗
  --- 按钮（`kind = "buttons"`），外加编辑区那份预览上的「应用改动」。
  nota.command.register("apply_patch", function()
    return chat.apply_patch(nota)
  end)

  --- 丢掉待应用的改动（**不动文档**）。
  nota.command.register("discard_patch", function()
    return chat.discard_patch(nota)
  end)

  --- 把改动**就地面在正文上**（右侧栏那一份上的「在编辑区看」）。
  ---
  --- 用户 2026-09-25 要的是"直接在编辑区域预览"，2026-09-26 又把这个要求
  --- 说死了一遍：「我的想法是直接将内容嵌入编辑区域……直接作用于编辑区域，
  --- 而不是开一个独立界面」。所以这里走 `nota.ui.review_diff`：正文**一个字
  --- 都不动**，被删的那些划掉、新增的那些以绿框插在原位；顶上那颗开关在
  --- "改动对比"与"改后效果"之间切（切的是画法，不重算）。
  ---
  --- ⚠️ 用户按 Esc / 点「收起预览」**不经过这里**：收起来是前端直接做的
  --- （`bridge/ipc.ts::reviewClose`）——插件可能正卡在一次慢调用里。
  nota.command.register("review_patch", function()
    local text, err = chat.patched_text(nota)
    if not text then
      -- 改动没了 / 打不出来：**明说一句**，不是摊一块空白（用户是看着一块
      -- "改动"点进来的，什么都不发生会以为坏了）。
      nota.ui.notify(err, "warn")
      return { ok = false, error = err }
    end
    nota.ui.review_diff({
      title = T("Change preview"),
      text = text,
      -- 与右侧栏那两颗按钮**同两条命令**：接受就是 `apply_patch`（一笔编辑，
      -- Ctrl+Z 退得回来），放弃就是 `discard_patch`。两处的命令一样，就
      -- 不会出现"在这一处按接受和那一处按接受做的事不一样"。
      accept = { label = T("Apply changes"), command = "apply_patch" },
      reject = { label = T("Discard changes"), command = "discard_patch" },
    })
    return { ok = true }
  end)

  nota.command.register("set_key", function(args)
    return save_setting(nota, util.KEY_API, args and args.api_key, "密钥")
  end)

  nota.command.register("set_base", function(args)
    return save_setting(nota, util.KEY_BASE, args and args.base_url, "接口地址")
  end)

  nota.command.register("set_model", function(args)
    return save_setting(nota, util.KEY_MODEL, args and args.model, "模型")
  end)

  --- 「AI 可读的文件」那个大小上限（第 61 项 (c)）。
  --- ⚠️ 存的是**用户敲的那串字**，不是数字：填了个看不懂的东西时
  --- `scope.budget` 会退回默认（不报错），存原样是为了让用户在设置里
  --- 一眼看见自己填的是什么。
  nota.command.register("set_scope", function(args)
    return save_setting(nota, util.KEY_SCOPE, args and args.scope_chars, "可读范围的字符上限")
  end)

  --- 「边生成边显示」那个开关（`docs/07` 第 58 项）。
  ---
  --- ⚠️ 它**没有参数**：按一下就是把当前状态取反，值由插件自己算。让面板那边
  --- 传一个"目标值"过来的话，面板上那颗按钮的字（"打开"/"关掉"）一旦和真实
  --- 状态错开一拍，用户按下去就会按到反的那个方向——那种 bug 只有用户看得见。
  ---
  --- ⚠️ **不走 `save_setting`**：那条是给"填一个值"用的，它的提示语是
  --- `"%s saved"`，套到这句上会变成英语的"Show as it is written saved"。
  --- 开关要说的是**现在是什么状态**，所以自己说一句。
  nota.command.register("toggle_stream", function()
    local on = util.stream_on(nota)
    nota.settings.set(util.KEY_STREAM, on and "0" or "1")
    if on then
      nota.ui.notify(T("Answers will be shown all at once again."), "info")
    else
      nota.ui.notify(T("Answers will be shown as they are written."), "info")
    end
    nota.ui.refresh()
    return { ok = true }
  end)

  -- ── 界面贡献 ────────────────────────────────────────────────────────────
  -- `location` 现在可以省（默认就是 `right`），写出来是为了让人一眼看到。
  -- 旧值是 `"sidebar"`，那时插件装在左侧栏第三页；那一页 2026-09-22 搬到了右边。
  --
  -- ⚠️ 2026-09-24 起右侧栏是**一页签一个插件**（用户要求"两个拓展不能同时占用"），
  -- 所以这一页打开时是独占的——见 `docs/04` §右侧栏。
  nota.ui.register_panel({
    id = "ai",
    title = "AI",
    location = "right",
    render = function()
      return panel.content(nota)
    end,
  })

  -- ⚠️ 2026-09-26 起这里**不再注册"编辑区那一份"面板**（`location = "main"`）。
  --
  -- 原先编辑区里的改动预览是"把 `review` 面板整个摊过去"，正文让位——用户
  -- 否掉了那个形态（「直接作用于编辑区域，而不是开一个独立界面」）。现在走
  -- 上面那条 `review_patch` → `nota.ui.review_diff`：画在正文身上，不需要面板。
  --
  -- 少一份面板不是损失：`register_panel` 那一份存在的唯一理由就是被摊开，
  -- 而摊开这件事现在由宿主直接做了（那正是"不另开界面"的字面意思）。
  -- `nota.ui.review(面板)` 这条 API 仍在（git 那份差异还在用它，
  -- 见 `plugins/git/main.lua`）。

  -- 预设都进菜单。⚠️ **菜单和面板上的按钮要对得上**：只在面板里放两个、
  -- 菜单里放三个，用户就得记住"哪个功能在哪儿"，而这种记性没人愿意花。
  for _, id in ipairs(chat.preset_order()) do
    nota.ui.register_menu({ label = T(chat.preset(id).label), command = id, menu = "plugins" })
  end
  nota.ui.register_menu({ label = T("New chat"), command = "new_chat", menu = "plugins" })
end

function M.on_unload()
  -- ⚠️ **密钥和地址留在设置文件里**（`nota.settings` 每次 `set` 就落盘了），
  -- 不在这里清。卸载插件不该把用户填的东西一起扔了——那是"装回来还得重填"。
  -- ⚠️ 对话也一样（2026-10-04 起它落盘了，见 `store.lua`）：**这里什么都不做**。
  -- 卸载一个插件不该顺手删掉用户的聊天记录，那份记录在
  -- `~/.local/share/nota/plugin-data/nota.ai/chats.txt`，用户想要就自己删。
end

return M
