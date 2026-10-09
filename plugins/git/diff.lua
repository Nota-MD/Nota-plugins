-- Git 插件的**差异预览那一半**（2026-09-29 从 `main.lua` 拆出来）。
--
-- 拆它的理由只有行数一条：`main.lua` 到了 997 行，离本仓 `.lua` 的硬上限
-- 1000（`docs/09` §4）只剩三行，而按用户 2026-09-29 那条新尺子
--（「不要每个代码文件都 1000 行，998 行这样……比如 300、500、800 这样，根据功能拆分」）
-- 它本来就该拆。**内容一个字节没改**，只是搬了家。
--
-- # 这条缝在哪儿
--
-- 「**把 git 的输出翻成面板能画的东西**」这一整块是自成一家：它只吃
-- `nota` 与一段差异文本，回一串内容块，不碰任何选择状态。留在 `main.lua` 里的
-- 是另一半——**提交树、改动列表、命令、生命周期**，那些要读写 `picked` /
-- `compared` / `show_graph` 这些"用户点了哪儿"的状态。
--
-- ⚠️ `why_of` / `run_diff` / `diff_section` 三样**提交树那一半也在用**
--（`bond_action` / `review_blocks` 里），所以它们跟着搬过来之后要从 `M` 上取
-- ——`main.lua` 顶上有一行别名把原名接回去，调用点一个没改。
--
-- ⚠️ 与 `plugins/stats/*.lua` 那几份同一个路子（`require`，插件多文件，
-- `docs/12` §5.9）：**变量名一律 ASCII**，中文只许出现在注释和字符串里。
--
-- ⚠️ 这份**不认识 `nota` 的全局**：`nota` 一律当参数递进来，`T` 走 `bind_text`
--（模块级的字符串本来就不该等到 `nota` 到手，同 `main.lua` 顶上那段）。

local M = {}

--- 文案取用器。默认原样返回——模块级的字符串不该等 `nota`。
local T = function(s) return s end

--- 把真取用器接进来。`main.lua` 在 `on_load` 里调（那时 `nota` 才到手）。
function M.bind_text(f)
  T = f
end

-- ── 差异预览（2026-09-25 加，2026-09-26 补齐上下文）─────────────────────
--
-- 用户要的是「**标红/绿文本来标记是删除还是添加**」（2026-09-25），
-- 2026-09-26 又点名「**照 Folio 那个 Git 拓展的形状来**」——每一行分档上色
--（加 / 删 / `@@` 段头 / 文件信息），上下文行不上色
--（`extensions/git/fo-git-panel-diff.c`）。所以取的是**完整的** unified diff：
-- 文件头、`@@`、上下文、增删，一屏里读起来跟终端里那份一样。
--
-- 红绿由宿主画（`kind = "diff"` + 行上的 `op`），翻译在 `nota.diff.parse_unified`
--（宿主）——那边跟"哪一行是文件头、哪一行是被删掉的内容"较劲（一份真 diff 里会
-- 长出 `--- 分隔线` 这种看着像文件头的正文行），有用例按着，见 `docs/13` §8.5。
--
-- ⚠️ `show_diff` 是**模块级**的显示开关，不是数据：上面那条"刻意不缓存任何 git
-- 数据"说的是别存 git 的输出（存了就会显示几分钟前的改动），而"要不要画差异"
-- 关了面板再打开还保持着，正是用户期望的。

--- 一块差异最多画几行（每份文件 / 全部加起来）。
--
-- 三个理由：面板只有 260px 宽（画多了就是一片红绿墙，用户照样得滚）、宿主给一层
-- 内容块的上限是 200 项（`ui.rs::面板节点上限`）、以及**上下文行也占额度**——
-- git 默认每个改动前后各带 3 行（我们显式写 `-U3`），一个小改动就是十来行，
-- 额度得按**画出来的行**算，不能再按"红绿行"算。每份文件一块这个切法本身
-- 也保证了不会撞宿主那道上限。
local MAX_PER_FILE = 80
local MAX_TOTAL = 200

--- 「差异这块画不画」。⚠️ 它是**显示开关，不是数据**——`main.lua` 顶上那条
--- "刻意不缓存任何 git 数据"说的是别存 git 的输出（存了就会显示几分钟前的改动），
--- 而"要不要画差异"关了面板再打开还保持着，正是用户期望的。
---
--- ⚠️ 状态在**本模块**里，`main.lua` 只经 `M.show()` / `M.toggle()` 读写——
--- 两边各存一份就会出现"按钮上写着 Hide、面板里却没画"。
local show_diff = true

--- 现在画不画差异。
function M.show()
  return show_diff
end

--- 翻一下，返回翻完的值（`toggle_diff` 那条命令用）。
function M.toggle()
  show_diff = not show_diff
  return show_diff
end

--- git 调用失败时该显示的那句话。`what` 是那条命令的名字（"git diff"）。
--
-- ⚠️ 别写成 `r.stderr ~= "" and r.stderr or "…"`：Lua 里空串是**真**，
-- 那个写法在 stderr 为空时会返回空串，等于把原因吞了。（踩过一次，
-- 这条注释就留在这儿别挪。）
local function why_of(r, what)
  if r.stderr == nil or r.stderr == "" then
    return T("%s exited with a non-zero status", what)
  end
  return r.stderr
end

--- 跑一条 git（差异那条路上的公共部分）：成功给文本，失败给 `(nil, 原因)`。
--
-- ⚠️ `--no-color` 和 `-U3` 是**每一条差异命令都要带的**，所以直接写在这儿：
-- `-U3` 是 git 的默认上下文行数，写出来是因为**界面上看到的东西取决于它**
--（改了哪几行紧挨着的是谁），而默认值有机会被 `diff.context` 之类的配置改掉
-- ——那样"面板里显示几行上下文"就成了"看用户 git 配置"，
-- 两个人打开同一份仓库看到的不一样。
--
-- ⚠️ 路径转义那件事（`core.quotePath`）宿主已经在 `run_git` 里统一处理了，
-- 这里不用管——不处理的话中文文件名在差异里是一串 `\344\270\255`。
local function run_diff(nota, argv)
  local full = { argv[1], "--no-color", "-U3" }
  for i = 2, #argv do
    full[#full + 1] = argv[i]
  end
  local r = nota.git.run(full)
  if r.ok then
    return r.stdout
  end
  return nil, why_of(r, "git diff")
end

--- 取一次「工作区 vs 最后一次提交」的差异。返回 `(文本, 错因)`。
--
-- ⚠️ 用 `HEAD`，不用裸的 `diff`：裸 `git diff` 是"工作区 vs 暂存区"，而这个
-- 面板上那颗「提交…」会先 `add -A`——一旦暂存过，裸 diff 就是空的，
-- 用户看到的是"改动列表里明明有东西、差异里却什么都没有"。
-- `HEAD` 把已暂存的和没暂存的一起算进来。
-- 仓库还没有第一次提交时 `HEAD` 不存在（git 报"有歧义的参数 'HEAD'"），
-- 那就退回裸 diff——那时候暂存区里也不可能有东西，两者等价。
--
-- ⚠️ **不要**改写成 `nota.git.diff(false)`：那个 helper 的 argv 写死在
-- `lua/api/git.rs` 里（只有 `--no-color` 和可选的 `--cached`），给不了 `HEAD`。
local function get_diff(nota)
  local text = run_diff(nota, { "diff", "HEAD" })
  if text then
    return text
  end
  return run_diff(nota, { "diff" })
end

--- 差异那几块：每份文件一条标题 + 一整块 unified diff（含上下文与文件头）。
--
-- `text` 是**已经取回来的**差异文本（取的那一步在 `get_diff` / `run_diff`
-- 那一侧，这里只负责翻译成内容块）。
-- `cmd` = "要看全的话在终端跑哪一句"。它进的是底下那两句截断提示——
-- ⚠️ 2026-09-26 起它是**参数**而不是写死的 `git diff HEAD`：提交树上点出来的
-- 那一对得说 `git diff 甲 乙`，否则照着提示敲会得到另一样东西。
-- `untracked` = 改动列表里未跟踪的文件有几个。**它们不在 `git diff HEAD` 里**
--（git 还不认识它们），不说一句的话，"列表里有个新文件、差异里找不到"
-- 看着就像个 bug。历史差异没有这个问题（传 0）。
local function diff_blocks(nota, text, cmd, untracked)
  local files = nota.diff.parse_unified(text)
  local blocks = {}

  -- 总行数先数出来：中途 break 掉之后再数就不全了，而"一共多少行"正是
  -- 用户判断"要不要去终端看"的依据。
  local total = 0
  for _, f in ipairs(files) do
    total = total + #f.lines
  end

  local drawn, skipped = 0, 0
  for i, f in ipairs(files) do
    -- ⚠️ 全局额度用完了就**不再往下开**。一开始是"继续开、只是不画行"，
    -- 结果一个改动多的仓库（Nota 自己就是）后面四十份文件全变成
    -- 一条标题 + 一句"还有 N 行没画"——那片桩子比一句话还长，而且没有用。
    if drawn >= MAX_TOTAL then
      skipped = #files - i + 1
      break
    end

    local title = f.path
    if f.added then
      title = title .. T("(new file)")
    elseif f.deleted then
      title = title .. T("(deleted)")
    end
    blocks[#blocks + 1] = { kind = "heading", text = title }

    -- ⚠️ 2026-09-26 起**没有"没有行可画"那一档了**。从前二进制文件与只改了
    -- 文件模式的那种在这里画一句"没有行可画"；现在它们也有三行可看
    --（`diff --git` / `index` / `Binary files … differ`），而"这份没法按行比"
    -- 正是 git 自己那句话说的——它比我们再写一句中文准，也不用翻译。
    local items, per = {}, 0
    for _, line in ipairs(f.lines) do
      if drawn < MAX_TOTAL and per < MAX_PER_FILE then
        items[#items + 1] = { op = line.op, text = line.text }
        drawn, per = drawn + 1, per + 1
      end
    end
    if #items > 0 then
      blocks[#blocks + 1] = { kind = "diff", items = items }
    end
    if per < #f.lines then
      blocks[#blocks + 1] = {
        kind = "text",
        tone = "muted",
        text = T("(%d more lines from this file are not drawn)", #f.lines - per),
      }
    end
  end

  if #files == 0 then
    blocks[#blocks + 1] = { kind = "text", tone = "muted", text = T("There is no diff to show.") }
  elseif skipped > 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("(The diff is too long: %d lines in total, the first %d are drawn here, and %d files are not drawn. Run `%s` in a terminal to see all of it.)",
        total,
        drawn,
        skipped,
        cmd
      ),
    }
  elseif total > drawn then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("(%d diff lines in total; the first %d are drawn here. Run `%s` in a terminal to see all of them.)",
        total,
        drawn,
        cmd
      ),
    }
  end

  if untracked > 0 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("%d more untracked files are not in the diff — git's diff only covers tracked files; once they are committed they will show up here.",
        untracked
      ),
    }
  end

  return blocks
end

--- 一段"带标题的差异"：标题 + 颜色说明 + 那一份差异。
---
--- 三处地方要画同一套排版（工作区那一份、历史那一对、编辑区那一份），所以只写
--- 一遍。⚠️ 那句颜色说明**每次都要说**：换了一对提交之后看到的还是同一套红绿蓝
--- 灰，而界面上别的地方没有解释过它们。
---
--- ⚠️ **必须在 `diff_blocks` 之后**：那个是 `local function`，写在它前面的话这里的
--- `diff_blocks(...)` 会被编译成**全局**查找——加载照样成功，一画差异就报
--- "attempt to call a nil value"。2026-09-26 拿假宿主跑真代码时撞出来的。
local function diff_section(nota, title, text, why, cmd, untracked)
  local out = {
    { kind = "heading", text = title },
    { kind = "text", tone = "muted", text = T("(red = removed, green = added, blue = where, grey = file info)") },
  }
  if not text then
    out[#out + 1] = { kind = "text", tone = "warn", text = T("Could not get the diff: %s", why) }
  else
    for _, b in ipairs(diff_blocks(nota, text, cmd, untracked)) do
      out[#out + 1] = b
    end
  end
  return out
end

-- ── 转出 ──────────────────────────────────────────────────────────────────
--
-- ⚠️ 这四行**必须在最后**：上面那几个 `local function` 是按"谁调谁"的顺序写的
--（`diff_section` 调 `diff_blocks`，写在它前面会被编译成**全局**查找——加载照样成功，
-- 一画差异就报 "attempt to call a nil value"，2026-09-26 撞出来过）。
-- 转出放在文件尾，那个顺序就一个字没动。

M.why_of = why_of
M.run_diff = run_diff
M.get_diff = get_diff
M.diff_blocks = diff_blocks
M.diff_section = diff_section

return M
