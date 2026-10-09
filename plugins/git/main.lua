-- Git 版本控制插件。
--
-- 宿主 API 见 docs/13-lua-api.md。这个插件是那份文档的**活样例**：
-- 想看"一个插件到底怎么写"，读这个文件就够。
--
-- 设计口径（与 Folio 的 git 扩展一致）：**不做 git 的替代品**。
-- 只做"写文档时最常用的那几下"——看改动、比差异、提交。
-- 分支管理、rebase、交互式暂存这些，用户去终端做比在 Nota 里点强。
--
-- ── 面板内容（2026-09-24 落地）────────────────────────────────────────────
--
-- `render` 是**每次拉都现跑一遍**的（宿主那侧有用例钉着这条），所以它里面
-- 直接问 git 要状态就对了——**不要**在 `on_load` 里算一次存起来：那样界面上
-- 会一直显示"应用刚启动那一刻"的改动，而且看着像是对的。
--
-- ⚠️ 声明（`register_panel` / `register_menu`）与内容是**两条路**：
-- 前者只在加载时跑一次、宿主按需读；后者每次读现调。混起来就是 BUG-13。
--
-- ── 差异预览（2026-09-25 落地）────────────────────────────────────────────
--
-- 「标红/绿，标出删了哪几行、加了哪几行」。**红绿是宿主画的**
--（`kind = "diff"`，外层 `.panel-diff` 那几个 `<pre>` 里逐行的 `.diff-del` /
-- `.diff-add`，见 `styles/diff.css`），
-- 这个插件只负责把 git 的输出翻成那个形状——翻译本身在宿主的
-- `nota.diff.parse_unified` 里（`src-tauri/src/lua/api/unified_diff.rs`）。
-- 判据与踩过的坑都在下面「差异预览」那一段。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里。** 非 ASCII 的标识符
-- 是**语法错误**（Lua 不认那些字节），症状是整份插件加载失败、面板和菜单一起消失。
-- 规矩与那条回归用例见 `docs/11` §变量名。

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────
--
-- `T("原句")` 取一句界面文案：宿主按**应用语言**在 `plugin.toml` 的 `langs` 里
-- 挑一份 `lang/<tag>.toml`（`nota.i18n`），表里没有这条就用原文。**键就是原文**，
-- ⚠️ **原文是英语**（2026-09-28 起），翻译只写进 `lang/zh-CN.toml`——
-- 这套规矩见 `docs/13` §nota.i18n。
--
-- ⚠️ `T` 在 `on_load` 里**重新绑一次**：`nota` 要到那时才到手（在那之前调它
-- 只会拿到原文，这是对的——模块级的字符串本来就不该等到 `nota`）。
-- ⚠️ 译文里要用到 `%` 得写成 `%%`（`T` 走的是 `string.format`）。
local T = function(s) return s end

-- ⚠️ 这里**刻意不缓存任何 git 数据**。早先有个"最近一次状态"的缓存，
-- 结果是"面板显示的是几分钟前的东西"的来源——每次要什么就现问 git，
-- 它本来就是个很快的命令行程序（见 `panel_content` 那段的注释）。
-- 模块级变量只有四个，**全是显示状态**（`show_diff` / `show_graph` /
-- `picked` / `compared`），一个字节的 git 输出都没存：差异和树每次都现问。
-- 它们各自在自己那一段里解释。

-- ── 小工具 ────────────────────────────────────────────────────────────────

-- ⚠️ `git status` 那份格式的解析（NUL 分隔、重命名要多读一段、分支名后面挂着
-- `[ahead 1]`）2026-09-26 **搬进宿主**了：`nota.git.parse_status`
--（`src-tauri/src/lua/api/git.rs` 里那一节）。搬的理由两条：它与
-- `nota.diff.parse_unified` 同属"画给用户看之前必须读准的格式"，挨着放好一起改；
-- 而且那边有用例按得住。调用点一律写 `nota.git.parse_status(r.raw)`。

--- 状态 → 「给人看的一行字」与「给界面看的语气」。**判据只有这一处**。
---
--- `state` 由宿主归类（`nota.git.parse_status`，取值就这四种，见 `docs/13` §nota.git）。
--- ⚠️ 两样写在一张表里：从前"哪句人话"和"什么语气"各写一套 `if`，改一处忘一处就会
--- 出现"列表里写着已暂存、颜色却是警示色"——同一件事在界面上自相矛盾。
---
--- ⚠️ `label` **同时是数据**：`refresh` 把它塞进 `e.describe` 广播出去（AI 插件拿它
--- 当上下文）。翻译它 = 别的插件读到的也是译文，这是**有意的**：那句话本来就是
--- 写给人看的，而一个界面只该有一种语言。
local STATES = {
  untracked = { label = "untracked", tone = "muted" },
  staged = { label = "staged", tone = "success" },
  ["staged-dirty"] = { label = "staged, with further changes", tone = "warn" },
  modified = { label = "modified", tone = "warn" },
}

local function describe(entry)
  return T((STATES[entry.state] or STATES.modified).label)
end

--- 未跟踪的文件有几个。**它们不在 `git diff HEAD` 里**（git 还不认识它们），
--- 所以底下要单独说一句，否则"有个新文件、差异里找不到"像个 bug。
local function count_untracked(entries)
  local n = 0
  for _, e in ipairs(entries) do
    if e.state == "untracked" then
      n = n + 1
    end
  end
  return n
end

-- ── 命令 ──────────────────────────────────────────────────────────────────

--- 取一次状态并发给界面。
--
-- `silent` 用在**加载时那一次**：那时用户还没打开任何文件夹，"不是 git 仓库"
-- 是理所当然的，弹一条警告只会让人以为哪里坏了。用户主动点刷新时不静默。
local function refresh(nota, silent)
  local r = nota.git.status()
  if r.code ~= 0 then
    -- 最常见的失败是"这个目录不是 git 仓库"。**要把这句话说清楚**——
    -- 原样显示 git 的报错（"fatal: not a git repository..."）用户未必看得懂
    -- 是 Nota 没能定位到仓库，还是他自己忘了 git init。
    if not silent then
      nota.ui.notify(T("This is not a git repository: %s", r.stderr), "warn")
    end
    nota.event.emit("git:status", { is_repo = false, branch = "", entries = {} })
    nota.ui.refresh()
    return
  end

  local parsed = nota.git.parse_status(r.raw)
  for _, e in ipairs(parsed.entries) do
    e.describe = describe(e)
  end
  parsed.is_repo = true

  -- 广播给**别的插件**（`docs/11` §插件之间怎么协作）。这条与下面那句
  -- `nota.ui.refresh` 是两件事：这一条是给插件的（比如 AI 插件要把改动当上下文），
  -- 那一条是给界面的。⚠️ 一码归一码，别指望界面去收这个。
  nota.event.emit("git:status", parsed)

  -- 告诉界面"我这边变了，去重拉一次"。⚠️ 这一句**只是提示**，不是内容：
  -- 面板没打开时没人收，用户打开时照样会拉到当时的状态（见 docs/12 §面板内容）。
  -- 面板上那颗「刷新」按钮点下去本来也会重拉，但菜单里的「刷新改动」不会——
  -- 少了这一句，从菜单刷新就得手动再点一下面板才看得到变化。
  nota.ui.refresh()
end

-- ── 面板内容 ──────────────────────────────────────────────────────────────
--
-- 返回一串**内容块**（docs/13 §面板 DSL）。宿主只认下面这七种 `kind`；
-- 认不出的会被前端如实画成"不认识这种内容块"——所以别写没在文档里的名字。

--- 一条改动该用什么语气。⚠️ 判据在 `STATES` 那张表里，**不在这里重写一遍**：
--- 从前这里是一套自己的 `if`，与 `describe` 各判各的，改一处就会出现自相矛盾的界面。
local function tone_of(e)
  return (STATES[e.state] or STATES.modified).tone
end

-- ── 差异预览（2026-09-25 落地）────────────────────────────────────────────
--
-- ⚠️ **实现整块 2026-09-29 搬去了 `diff.lua`**（`require`，插件多文件的第三个
-- 用户；拆的理由与那条缝在哪儿写在那边文件头）——`main.lua` 当时 997 行，
-- 离 1000 只剩三行。下面这行是**转接**：名字一个没改，几十处调用点全都不用动。
--
-- 口径一句话：「标红/绿，标出删了哪几行、加了哪几行」。**红绿是宿主画的**
--（`kind = "diff"`，外层 `.panel-diff` 那几个 `<pre>` 里逐行的 `.diff-del` /
-- `.diff-add`，见 `styles/diff.css`），
-- 这个插件只负责把 git 的输出翻成那个形状——翻译本身在宿主的
-- `nota.diff.parse_unified` 里（`src-tauri/src/lua/api/unified_diff.rs`）。

local diff = require("diff")

local why_of, run_diff = diff.why_of, diff.run_diff
local get_diff, diff_section = diff.get_diff, diff.diff_section


-- ── 提交树 ────────────────────────────────────────────────────────────────
-- 来由与两条点击路径写在上面那段（`show_graph` 那儿）；这里只有实现。

--- 提交树最多画几行（**含纯连接线行**）。60 = "最近这些提交"的量，再多就成了
--- 一个得滚很久的东西。⚠️ 它**只管树**，与差异那份额度（`MAX_TOTAL`）各算各的。
local MAX_GRAPH = 60

--- 树上一行右边那串字：短哈希 + 分支标签 + 标题。
---
--- ⚠️ 分支标签**不能省**：没有它，"哪一行是 main 的头"在图上看不出来，而这正是
--- 提交树最有用的那一眼（挤不下时截掉的是标题，哈希和分支名留在左边）。
---（标签两头的括号和空格宿主已经去掉了——那是 `%d` 那一段的事。）
local function row_text(hash, refs, subject)
  if refs == "" then
    return hash .. "  " .. subject
  end
  return hash .. "  " .. refs .. " · " .. subject
end

--- 这个哈希是不是已经选中了。
local function is_picked(hash)
  for _, h in ipairs(picked) do
    if h == hash then
      return true
    end
  end
  return false
end

--- 左边那截图线（键）要挂的动作。根提交（`parent == ""`）**也有**键可点，
--- 只是那条键通向"空树"（`compared_blocks` 里走 `git show`），照样给一颗。
local function bond_action(hash, parent)
  local title = T("Diff %s against its parent %s", hash, parent)
  if parent == "" then
    title = T("See what the very first commit %s put in (it has no parent to compare against)", hash)
  end
  return { command = "bond_diff", args = { hash = hash, parent = parent }, title = title }
end

--- 提交树那一块。**没有提交时也画一句人话**，不是空面板。
---
--- ⚠️ "图线怎么切、合并提交的父算哪个、连接线行怎么认"**全是宿主的事**
---（`nota.git.log_graph`：格式串与解析在同一处，那边有用例按着）。这里只做两件：
--- 这一行该说哪句话、点了跑哪条命令。
local function graph_blocks(nota)
  local r = nota.git.log_graph(MAX_GRAPH)
  if not r.ok then
    -- 还没有第一次提交时 `git log` 也会失败，但那是**正常状态**，不是错误。
    -- 判据用 `rev-parse --verify HEAD` 的退出码，**不去认 git 那句英文**——那句话
    -- 会随版本和语言变，认它等于把一句译文当协议。
    if nota.git.run({ "rev-parse", "--verify", "-q", "HEAD" }).code ~= 0 then
      return {
        { kind = "text", tone = "muted", text = T("There is no first commit yet. Once you commit, the tree will grow here.") },
      }
    end
    return { { kind = "text", tone = "warn", text = T("Could not read the commit tree: %s", why_of(r, "git log")) } }
  end

  local rows, last = {}, nil
  for _, row in ipairs(r.rows) do
    if row.hash then
      local parent = row.parent or ""
      last = { hash = row.hash, parent = parent }
      rows[#rows + 1] = {
        art = row.art,
        text = row_text(row.hash, row.refs or "", row.subject or ""),
        tone = "normal",
        picked = is_picked(row.hash),
        bond = bond_action(row.hash, parent),
        pick = {
          command = "pick_commit",
          args = { hash = row.hash },
          title = T("Select %s (pick one more to compare them)", row.hash),
        },
      }
    else
      -- 纯连接线行：**归它上面那个提交**（顶上那段写了这条读法的边界）。
      rows[#rows + 1] = {
        art = row.art,
        text = "",
        tone = "muted",
        bond = last and bond_action(last.hash, last.parent) or nil,
      }
    end
  end

  if #rows == 0 then
    return { { kind = "text", tone = "muted", text = T("The commit tree is empty.") } }
  end
  return { { kind = "graph", items = rows } }
end

--- 显示状态变了：让**两处**界面都重拉一次。
--
-- ⚠️ 光靠前端自己重拉是不够的：右栏那颗按钮跑完只会重拉它自己那一页
--（`PluginDock.tsx::跑`），编辑区摊着的那一份收不到——症状是"在面板里换了
-- 一对提交，编辑区还画着上一对"。这一句是广播（`id = nil` = "这个插件的
-- 面板都算变了"），两处都会重拉。
local function redraw(nota)
  nota.ui.refresh()
end

--- 定下一对要看的提交，并把**方向理正**（早的那个在 `a`）。
---
--- ⚠️ 这不是洁癖：`git diff 新 旧` 的正负号是反的，而界面上写着「红 = 删」——
--- 方向不理正，那句话就有一半时候是假的。判据是 `merge-base --is-ancestor`
---（退出码 0 = 前者是后者的祖先 = 更早）。两条**不在一条线上**的提交（比如两个
--- 分支的尖端）谁也不是谁的祖先，那就按点击顺序来——标题里写的就是实际跑的那条
--- 命令，所以那种情况下它照样是准的。
local function set_compared(nota, a, b)
  if a ~= "" and nota.git.run({ "merge-base", "--is-ancestor", b, a }).code == 0 then
    a, b = b, a
  end
  compared = { a = a, b = b }
end

--- 「现在正在看的那一对」那几块（点了树上的键、或选中两个提交之后）。
--- ⚠️ 两处界面（右栏面板、编辑区）**共用这一份**——同一对提交在两处必须长得一样。
local function compared_blocks(nota)
  if not compared then
    return {}
  end
  local a, b = compared.a, compared.b
  local cmd, title, text, why

  if a == "" then
    -- 根提交没有父可以比：`git show` 对它画的正好是"跟空树比"——所有文件都算
    -- 新加的，正是要看的东西。
    cmd = "git show " .. b
    title = T("The first commit %s (everything counts as newly added)", b)
    text, why = run_diff(nota, { "show", "--format=", b })
  else
    cmd = "git diff " .. a .. " " .. b
    title = T("Between %s → %s", a, b)
    text, why = run_diff(nota, { "diff", a, b })
  end

  local blocks = diff_section(nota, title, text, why, cmd, 0)
  blocks[#blocks + 1] = {
    kind = "buttons",
    items = { { label = T("Clear selection"), command = "clear_pick" } },
  }
  return blocks
end

--- 「这里不是 git 仓库」那一屏。**右栏和编辑区共用这一份。**
---
--- ⚠️ 从前这里写的是"去终端跑一次 `git init`"——那等于把功能砍了一半（用户
--- 2026-09-26 点名「界面要允许 git init」）。那颗按钮就在**文档所在目录**跑。
local function not_repo_blocks()
  return {
    { kind = "heading", text = T("This is not a git repository") },
    { kind = "text", tone = "muted", text = T("Create a repository in the document's directory and you can look at changes, compare diffs and commit right here.") },
    {
      kind = "buttons",
      items = {
        { label = T("Create a repository"), command = "init_repo", style = "primary" },
        -- 「再试一次」留着：仓库也可能是在**别处**建好的（用户在终端里 init 了、
        -- 或者切到了另一个文档目录），这条路得能重新发现它。
        { label = T("Try again"), command = "refresh" },
      },
    },
  }
end

--- 这个仓库算不算得出 Git 身份（`user.name` / `user.email`）——算不出就提交不了。
---
--- ⚠️ 判据是 `git var GIT_AUTHOR_IDENT` 的**退出码**，不是去认 git 那句话：git 的
--- 报错是**本地化**的（中文 git 说的是「作者身份未知」），认它等于把一句译文当协议。
---（身份配在全局还是这个仓库里都一样——这里问的是"现在算不算得出"。）
local function has_identity(nota)
  return nota.git.run({ "var", "GIT_AUTHOR_IDENT" }).code == 0
end

--- 编辑区那一份：**只画差异**。
--
-- 用户 2026-09-25：「要求允许直接在Markdown编辑区域进行预览。」理由是右侧那
-- 260px 里一份 diff 一行的两头都看不全，而**差异恰恰是要横着读的**。
-- ⚠️ 2026-09-26 起两处都**不折行**了（`diff.css` 里那一行 `white-space: pre`
-- ＋ 横向滚动），所以"看不全"从"折成一团"变成了"要横着滚"——这一颗
-- 「在编辑区看」还是有用的（宽处一屏能读下整行），但理由换了一个。
--
-- ⚠️ 画的**就是面板里那一份 `diff_blocks`**（`panel_content` 的「看差异」那一
-- 段也是它）：同一次改动在两处必须长得一样，不然用户会以为是两回事。
local function review_blocks(nota)
  local r = nota.git.status()
  if r.code ~= 0 then
    -- 不是仓库时**照实说**：编辑区那么大一块地方，摊开一句"这里不是 git 仓库"
    -- 比摊开一片空白强（空白看着像坏了）。这一屏与右栏**共用一份**
    --（`not_repo_blocks`）——两边各写一遍的话，加一颗按钮就得记得加两处。
    return not_repo_blocks()
  end

  local untracked = count_untracked(nota.git.parse_status(r.raw).entries)

  -- ⚠️ 用户点了树上的键之后，编辑区摊着的是**当前这一对的差异**，不是工作区
  -- 那一份（用户 2026-09-25 要的是"在编辑区直接预览"，那就得是此刻在看的东西；
  -- 而"此刻在看什么"是 `compared` 说了算，与下面那块 `show_diff` 无关）。
  -- 想回到工作区那一份 = 点「清空选择」（那正是那颗按钮的另一半用处）。
  if compared then
    return compared_blocks(nota)
  end

  local text, why = get_diff(nota)
  return diff_section(nota, T("Diff"), text, why, "git diff HEAD", untracked)
end

--- 面板此刻该显示什么。**每次读都现跑**（见文件头）。
local function panel_content(nota)
  local r = nota.git.status()

  -- 不是仓库：**如实说，并且就地给一条出路**（那一屏里那颗「初始化仓库」）。
  -- 空着的话用户看到的是一个空白面板，而原因（没 git init）和出路都看不出来。
  if r.code ~= 0 then
    return not_repo_blocks()
  end

  local parsed = nota.git.parse_status(r.raw)
  local blocks = {}
  local untracked = count_untracked(parsed.entries)

  local branch = parsed.branch
  if branch == "" then
    branch = T("(git did not report a branch)")
  end
  blocks[#blocks + 1] = { kind = "heading", text = branch }

  if #parsed.entries == 0 then
    -- **空的不是错误**：干净的工作区是正常状态，画一个空列表会让人以为没读出来。
    blocks[#blocks + 1] = { kind = "empty", text = T("No uncommitted changes.") }
  else
    local items = {}
    for _, e in ipairs(parsed.entries) do
      items[#items + 1] = {
        title = e.path,
        badge = describe(e),
        -- 重命名/复制的原名写在副标题里：只看新名字看不出"这是从哪儿来的"。
        subtitle = e.orig and T("formerly %s", e.orig) or "",
        tone = tone_of(e),
      }
    end
    blocks[#blocks + 1] = { kind = "list", items = items }
  end

  -- Git 身份没配的话**现在就说**：git 会拒绝提交，而它自己那句报错又长又是译文。
  -- ⚠️ 不能等到提交失败才说——那是用户在这台机器上第一次提交唯一会卡住的地方，
  -- 到时候他已经在想"这功能是不是坏的"了。
  if not has_identity(nota) then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "warn",
      text = T("This repository has no Git identity (name and email) yet; git will refuse to commit."),
    }
    blocks[#blocks + 1] = {
      kind = "buttons",
      items = {
        {
          label = T("Set identity…"),
          command = "set_identity",
          style = "primary",
          -- 两个字段（`secondArg`）——判据与「提交…」那颗是同一套 `prompt`，
          -- 多出来的那个字段见 `docs/13` §prompt。
          prompt = {
            arg = "name",
            label = T("Git identity"),
            placeholder = T("Name, for example: Jane Doe"),
            hint = T("git uses this to sign every commit"),
            secondArg = "email",
            secondLabel = T("Email"),
            secondPlaceholder = T("you@example.com"),
          },
        },
      },
    }
  end

  blocks[#blocks + 1] = {
    kind = "buttons",
    items = {
      { label = T("Refresh"), command = "refresh" },
      {
        label = T("Commit…"),
        command = "commit",
        style = "primary",
        -- ⚠️ `prompt` = 点之前先弹宿主的输入框问一句（`docs/13` §prompt）。
        -- **不要**改成"先提交再让用户改信息"：提交信息是提交的一部分，
        -- 事后改要 amend，那已经不是"写文档时最常用的那几下"了。
        prompt = {
          arg = "message",
          label = T("Commit message"),
          placeholder = T("One line saying what changed"),
          hint = T("Stages every change with `add`, then commits them together"),
        },
      },
      -- ⚠️ 按钮在差异**上面**：差异可以很长（最多 200 行），摆在按钮后面的话，
      -- 用户每次都得先滚过一整片红绿才够得着「提交…」。
      {
        label = diff.show() and T("Hide diff") or T("Show diff"),
        command = "toggle_diff",
      },
      -- ⚠️ 「看差异」是**在这一栏里**看（窄，长行要横着滚），「在编辑区看」是
      -- 换到正文那么宽去看。两颗按钮不是重复：同一份 diff，一屏能读下多少
      -- 差得远，而 diff 是要横着读的。
      --
      -- ⚠️ 「在编辑区看」**只有这一颗**，看的是"此刻在看的那一份"（编辑区那边
      -- 由 `compared` 决定画工作区那一份还是历史那一对）。**不要**在下面那块
      -- 历史差异旁边再放一颗同名的：同一件事在同一页上有两颗按钮，用户会
      -- 以为它们打开的不是同一个东西。
      { label = T("View in editor"), command = "review_diff" },
      -- 提交树默认**不摊开**：它一摊开就是几十行，而这个面板的第一件事是
      -- "有没有东西要提交"。想看见树的人会看见这颗按钮。
      { label = show_graph and T("Hide the commit tree") or T("Commit tree"), command = "toggle_graph" },
    },
  }

  -- ── 提交树（默认收着，`show_graph` 那个开关说了算）───────────────────────
  if show_graph then
    blocks[#blocks + 1] = { kind = "separator" }
    blocks[#blocks + 1] = { kind = "heading", text = T("Commit tree") }
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("Click the graph on the left for what this commit changed; click the text on the right to select it (select two to compare them)."),
    }
    if #picked > 0 then
      -- 选中的那两个要**写出来**：树一长，用户滚回去看自己点了哪两行很费劲，
      -- 而"我比的是哪两个"这件事错了，下面那份差异就白看了。
      blocks[#blocks + 1] = {
        kind = "text",
        tone = "success",
        text = T("Selected: %s", table.concat(picked, "、")),
      }
    end
    for _, b in ipairs(graph_blocks(nota)) do
      blocks[#blocks + 1] = b
    end
  end

  -- ── 正在看的那一对（点了树上的键、或选中了两个提交）─────────────────────
  if compared then
    blocks[#blocks + 1] = { kind = "separator" }
    for _, b in ipairs(compared_blocks(nota)) do
      blocks[#blocks + 1] = b
    end
  end

  if diff.show() then
    blocks[#blocks + 1] = { kind = "separator" }
    local text, why = get_diff(nota)
    for _, b in ipairs(diff_section(nota, T("Diff"), text, why, "git diff HEAD", untracked)) do
      blocks[#blocks + 1] = b
    end
  end

  return blocks
end

--- 提交全部改动。
function M.commit(nota, message)
  if not message or message == "" then
    return { ok = false, error = T("The commit message cannot be empty") }
  end

  -- 先 add -A。**只提交已跟踪文件的改动**是更保守的做法，但写文档的人
  -- 更常见的意图是"把这一轮的所有改动存下来"，所以默认全加。
  local added = nota.git.run({ "add", "-A" })
  if added.code ~= 0 then
    return { ok = false, error = T("git add failed: %s", added.stderr) }
  end

  -- 身份没配就停在这儿，**不去跑那条注定失败的 commit**。
  -- ⚠️ 位置在 `add` **之后**：`add` 都不成功说明这儿根本不是仓库（或另有毛病），
  -- 那时说"先填身份"是答非所问。
  if not has_identity(nota) then
    return { ok = false, error = T("Set the Git identity (name and email) first — git will not commit without it.") }
  end

  local committed = nota.git.run({ "commit", "-m", message })
  if committed.code ~= 0 then
    -- "nothing to commit" 不是错误，是没有改动可提交——要分开说，
    -- 否则用户会以为自己哪儿操作错了。
    local nothing = string.find(committed.stdout .. committed.stderr, "nothing to commit")
    if nothing then
      return { ok = false, error = T("There is nothing to commit") }
    end
    return { ok = false, error = T("git commit failed: %s", committed.stderr) }
  end

  return { ok = true, output = committed.stdout }
end

-- ── 生命周期 ──────────────────────────────────────────────────────────────

function M.on_load(nota)
  -- ⚠️ **第一件事**:把文案取用器接到宿主给的这份表上（上面 `local T` 那段）。
  -- ⚠️ 局部名一律 ASCII：**Lua 的标识符不许有非 ASCII 字符**（文件头那条）。
  T = function(fmt, ...)
    local s = nota.i18n and nota.i18n.text(fmt) or nil
    s = s or fmt
    if select("#", ...) > 0 then
      return string.format(s, ...)
    end
    return s
  end

  -- ⚠️ 搬去 `diff.lua` 的那一半**也要拿到这一份**：它是个独立模块，自己那个 `T`
  -- 还是"原样返回"的桩。少了这一句，差异那几块里的英文原文在中文界面上不会翻
  -- ——而它**不报错**，只是界面上那几句始终是英语。
  diff.bind_text(T)

  -- 刷状态。
  nota.command.register("refresh", function()
    refresh(nota)
    return { ok = true }
  end)

  -- 建仓库。**"全在界面里做完"的第一步**：没有它，用户得先开一个终端。
  --
  -- ⚠️ 跑在**活动文档所在目录**（cwd 由宿主定，见 `lua/api/git.rs` 文件头）。
  -- ⚠️ 分支名**不写死**：`git init` 自己会听 `init.defaultBranch`，那是用户的配置。
  nota.command.register("init_repo", function()
    local r = nota.git.run({ "init" })
    if r.code ~= 0 then
      local why = why_of(r, "git init")
      nota.ui.notify(T("git init failed: %s", why), "error")
      return { ok = false, error = why }
    end
    nota.ui.notify(T("The repository is ready"), "success")
    refresh(nota)
    return { ok = true, output = r.stdout }
  end)

  -- 填 Git 身份（`user.name` / `user.email`）。
  --
  -- ⚠️ 写进**这个仓库**的 `.git/config`（`git config` **不带 `--global`**），不碰
  -- `~/.gitconfig`：全局配置是用户机器上的公共资源，一个编辑器插件替他改不合适
  --（`docs/11` 的能力表把"能改全局配置"记成挡不住的已知边界——我们主动不越界）。
  -- 代价是每建一个新仓库要再填一次。
  nota.command.register("set_identity", function(args)
    local name = args and args.name or ""
    local email = args and args.email or ""
    -- 两个都要：只设一半的话 `git var` 照样算不出来，而用户会以为自己填过了。
    if name == "" or email == "" then
      return { ok = false, error = T("Both the name and the email are required") }
    end
    for _, kv in ipairs({ { "user.name", name }, { "user.email", email } }) do
      local r = nota.git.run({ "config", kv[1], kv[2] })
      if r.code ~= 0 then
        local why = why_of(r, "git config")
        nota.ui.notify(T("Could not save the identity: %s", why), "error")
        return { ok = false, error = why }
      end
    end
    nota.ui.notify(T("The Git identity is saved in this repository"), "success")
    refresh(nota)
    return { ok = true }
  end)

  -- 取差异文本（给界面显示，也给 AI 插件当上下文）。
  nota.command.register("diff", function(args)
    local staged = args and args.staged or false
    local r = nota.git.diff(staged)
    return { ok = r.code == 0, text = r.text, error = r.stderr }
  end)

  -- 折叠 / 展开差异。**只改显示，不碰 git**（不 add、不改文件）。
  nota.command.register("toggle_diff", function()
    diff.toggle()
    refresh(nota)
    return { ok = true }
  end)

  -- 收起 / 摊开提交树。和 `toggle_diff` 同一个性质：**只改显示，不碰 git**。
  nota.command.register("toggle_graph", function()
    show_graph = not show_graph
    redraw(nota)
    return { ok = true }
  end)

  -- 点树上一行的右边那截：选中 / 取消 / 挤掉最早那个。
  --
  -- ⚠️ 满了两个之后再点一个 = **把最早那个挤出去**（不是"从头再来"）：想比第 1
  -- 个和第 3 个时，点第 3 个再点第 1 个就到了。选它是因为**每次点击的效果都
  -- 一样**（加自己、去掉最早的），没有"这一次是清空"这种例外。
  nota.command.register("pick_commit", function(args)
    local hash = args and args.hash or ""
    if hash == "" then
      return { ok = false, error = T("This line has no commit, so it cannot be selected.") }
    end

    for i, h in ipairs(picked) do
      if h == hash then
        table.remove(picked, i)
        -- 取消一个之后就不成对了：正在看的那一对也收掉，否则界面上会出现
        -- "只选了一个、底下还画着一对"这种自相矛盾的样子。
        compared = nil
        redraw(nota)
        return { ok = true }
      end
    end

    picked[#picked + 1] = hash
    if #picked > 2 then
      table.remove(picked, 1)
    end
    if #picked == 2 then
      set_compared(nota, picked[1], picked[2])
    else
      compared = nil
    end
    redraw(nota)
    return { ok = true }
  end)

  -- 点树上一行的左边那截（键）：看这一次提交与它父提交之间的差异。
  nota.command.register("bond_diff", function(args)
    local hash = args and args.hash or ""
    if hash == "" then
      return { ok = false, error = T("This line has no commit, so there is nothing to open.") }
    end
    set_compared(nota, args.parent or "", hash)
    redraw(nota)
    return { ok = true }
  end)

  -- 清空选择：退回"工作区 vs 最后一次提交"那一份。
  nota.command.register("clear_pick", function()
    picked = {}
    compared = nil
    redraw(nota)
    return { ok = true }
  end)

  -- 提交。
  nota.command.register("commit", function(args)
    local message = args and args.message or ""
    local result = M.commit(nota, message)
    if result.ok then
      nota.ui.notify(T("Committed"), "success")
      -- 提交完差异就空了，编辑区那一份摊着没意义（还容易让人以为"怎么什么都不剩"）。
      nota.ui.review(nil)
      refresh(nota)
    else
      nota.ui.notify(result.error, "error")
    end
    return result
  end)

  -- 把差异摊到编辑区（面板上那颗「在编辑区看」）。
  --
  -- ⚠️ 用户点「回到正文」**不经过这里**：收起来是前端直接做的
  -- （`bridge/ipc.ts::reviewClose`）——git 子进程正跑着的时候也得退得出来。
  nota.command.register("review_diff", function()
    nota.ui.review("review")
    return { ok = true }
  end)

  -- 仓库根目录。
  nota.command.register("repo_root", function()
    return { path = nota.git.repo_root() }
  end)

  -- ── 界面贡献 ────────────────────────────────────────────────────────────
  -- `location = "right"` = 右侧插件栏（也是默认值，写出来是为了让人一眼看到）。
  -- 早先这里是 `"sidebar"`，那时插件还装在左侧栏的第三页，那一页 2026-09-22 搬走了。
  nota.ui.register_panel({
    id = "git",
    title = "Git",
    location = "right",
    -- ⚠️ `render` **每次拉都现跑一遍**，所以它里面必须是"现在怎么样"，
    -- 不能是"加载时怎么样"。写成闭包捕获一份快照就是最坏的那种错
    --（界面看着是对的，只是永远是几分钟前的）。
    render = function()
      return panel_content(nota)
    end,
  })

  -- 编辑区里的那一份（`location = "main"`）。
  --
  -- ⚠️ `location` 声明的是"这一块属于哪儿"，**不是**"现在就摊开"：摊开是上面
  -- 那条 `review_diff` 命令调 `nota.ui.review("review")` 的结果。所以它不会在
  -- 右侧栏多占一页（那一栏只收 `location = "right"` 的），而是在「插件」页的
  -- 清单里挂个名——那儿能看见它属于编辑区。
  nota.ui.register_panel({
    id = "review",
    title = T("Diff"),
    location = "main",
    render = function()
      return review_blocks(nota)
    end,
  })

  nota.ui.register_menu({
    label = T("Commit…"),
    command = "commit",
    menu = "plugins",
    -- 与面板上那颗「提交…」同一个 `prompt`：两条路上的问法必须一样，
    -- 否则同一个功能在菜单里和在面板里表现不同。
    prompt = {
      arg = "message",
      label = T("Commit message"),
      placeholder = T("One line saying what changed"),
      hint = T("Stages every change with `add`, then commits them together"),
    },
  })

  nota.ui.register_menu({
    label = T("Refresh changes"),
    command = "refresh",
    menu = "plugins",
  })

  -- 开面板时先刷一次，用户不必手动点刷新。
  --
  -- ⚠️ **包 pcall 是刻意的，不是防御性编程的迷信**：这一句在 `on_load` 的末尾，
  -- 它一抛错，整份插件的加载就被判失败（用户看到的是"这个插件坏了"），
  -- 而真实原因可能只是"还没开工作区"。宿主那边已经把这类环境问题折成
  -- `code ~= 0` 的结果表了（见 src-tauri/src/lua/api/git.rs 的文件头），
  -- 这里再兜一层，是为了**将来宿主新加的任何一种环境失败**都不会再变成一次误判。
  local ok, err = pcall(refresh, nota, true)
  if not ok then
    nota.log.warn("首次刷新改动失败：" .. tostring(err))
  end
end

function M.on_unload()
  -- 没有要落盘的状态：改动清单每次都是从 git 现取的。
end

return M
