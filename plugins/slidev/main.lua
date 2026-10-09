-- Slidev 演示插件。
--
-- 宿主 API 见 docs/13-lua-api.md；`nota.devserver` 那一节是这个文件的主要依据。
--
-- ── 这个插件在 2026-09-25 之前是程序本体的一部分 ──────────────────────────
--
-- 拆出来的判据是用户那句「几个不是所有人能用到的功能放到拓展里面」：要 Node、
-- 要 npm 装几百 MB、写文档的人里绝大多数不写幻灯片。拆完之后**机制留在宿主**
--（挑端口、写入口、起进程、杀进程树、探端口通没通——见
-- `src-tauri/src/devserver.rs` 文件头），**命令与话术归这里**。
-- 所以这个文件里没有一行"怎么办进程"，只有"跟用户怎么说"和"哪几颗按钮"。
--
-- ── 一次预览的流程 ────────────────────────────────────────────────────────
--
-- ```text
-- 点「开始预览」→ 先探（装没装、文档目录是不是个 Slidev 项目、**这份文档要的主题包在不在**）
--                  └─ 探不通就在面板上说清楚，**不盲起**（见 `describe_probe`）
--                → nota.devserver.start{doc=}   宿主写入口、起进程、等端口通
--                  └─ 通了：面板里嵌一块 `frame`（地址由宿主填，见下面）
--                  └─ 没通：**把进程自己的输出端给用户**（病因都在里面）
-- 改文档 → 宿主自己重写入口文件（Slidev 那边热更新），这个插件不用盯着
-- ```
--
-- ⚠️ 第三条（主题包）是 2026-09-26 补的，起因是用户实测的一场"面板说能跑、
-- 进程两秒就退"：光看"项目里有没有 `@slidev/theme-*`"不够——装的是
-- `theme-seriph`、文档要的是 `theme-default`，照样起不来。规则与取舍写在
-- 下面「主题」那一节。
--
-- ⚠️ **`start` 会阻塞到端口通**（最多 180 秒）。所以：
-- 1. 它由**按钮/菜单**发起，不在 `on_load` 里跑（那会把应用启动卡住）；
-- 2. 阻塞期间整个 plugins 锁是被持有的，别的插件命令都得排队——
--    包括用户点「停止预览」。这是 `nota.devserver` 已知的代价（`docs/13`），
--    和 AI 插件发 30 秒 HTTP 请求是同一件事。
--
-- ── 状态：一个现问，一个存着，一个归宿主 ──────────────────────────────────
--
-- | 状态 | 怎么拿 | 为什么 |
-- |---|---|---|
-- | 会话（活着没、端口多少、地址） | **每次现问** `nota.devserver.status()` | 进程可能自己死了、"停止"可能从菜单点过 |
-- | 探测结果 | 交给**宿主**记着（`probe_async` 有就取、没有就等它后台探） | 它要跑一次 `npx`（实测 1.3 秒），不能每次画面都跑 |
-- | 上次启动失败那句话 | 存着（`last_error`） | 通知一闪就没了，面板上得留一条 |
--
-- 会话与探测的分界值得说清楚：**"这段数据是不是别人的"**。会话状态是宿主的、随时会变，
-- 存下来就是"面板显示的是几分钟前的东西"；探测结果是**一台机器上"装没装"的事实**——
-- 只会在用户装了东西的时候变，而那件事用户自己知道，他装完会回到这个面板来，
-- 那时点一下「重新检测」（或直接「开始预览」，它也会现探一次）就把它顶掉了。
--
-- ⚠️ **探测那条缓存 2026-09-26 挪去了宿主**（`lua/api/devserver.rs` 的
-- 「探测缓存」一节）：只有宿主能在后台探、探完喊前端重拉这一页，
-- 而面板的 `render` 是同步拉的、**等不起**那 1.3 秒（`docs/07` BUG-36）。
-- 口径一个字没变：**不过期，靠用户动作顶掉**。
--
-- ⚠️ **为什么不给探测结果定个过期时间**：能问时间的地方都不干净——
-- Lua 沙箱里**根本没有 `os`**（`lua/mod.rs` 的 `必须为空的全局`：`os.execute` /
-- `os.getenv` 都在里面，所以整张 `os` 表被置了 nil，连带 `os.time` 一起没有）；
-- 宿主那边倒是有钟，但要拿它做"几分钟后自动作废"就得再定一条"多久算久"
-- 而且会多出一种界面状态（"结论过期了，正在重探"）。这里并不需要它——
-- 过期的结论**有路可走而且只有一步**。
--
-- ⚠️⚠️ **变量名一律用 ASCII，中文只许出现在注释和字符串里。**
-- `local 面板 = 1` 是**语法错误**：Lua 的标识符只认 `[A-Za-z_][A-Za-z0-9_]*`。
-- 一整份插件会加载失败，面板和菜单一起消失（`lua/mod.rs` 有用例钉着这条）。

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────

--- 取一句界面文案，顺带格式化。**键就是下面写下的那句原文。**
---
--- 宿主按"应用语言"在清单的 `langs` 里挑一份表（`lang/<tag>.toml`）给这个插件
---（`nota.i18n`，见 `src-tauri/src/lua/api/i18n.rs`）。表里没有这条 → **用原文**。
--- 所以：**原句写英语**（2026-09-28 起用户定的方向），要翻译的才进
--- `lang/zh-CN.toml`（键 = 这里的原句；`lang/en.toml` 不写了——英语就是原文）；
--- 表读不到、键写错、插件语言对不上，退化的样子都是**看见原文**，不报错。
---
--- ⚠️ `T` 在 `on_load` 里**重新绑一次**：`nota` 要到那时才到手，而这之前
--- 模块级别的语句（表头那些常量）照样能调它——那时它原样返回。
--- ⚠️ 译文里要用到 `%` 得写成 `%%`（走的是 `string.format`）。
local T = function(s) return s end

-- ── 常量 ──────────────────────────────────────────────────────────────────

--- 日志最多画几行。宿主留的是最后 30 行，画全了是一堵墙，而病因总在最后几行。
local LOG_LINES = 12

--- 日志每行最多多长。npm 的报错有时一整行几百个字符。
local LOG_COL = 200

--- 装没装 —— 那条「去官网看安装指南」按钮的去处。
--
-- ⚠️ **地址别照印象另写**：2026-09-24 是**查 VitePress 的 `hashmap.json` 页面表**
-- 核出来的（那个站是 SPA，乱编的路径也回 200 和同一张外壳，看状态码核不出来）。
-- 用户对面板的原话就是「如果没有，导航到官网的下载指南」。
local GUIDE_URL = "https://sli.dev/guide/"

-- ── 模块级状态（两个，都在上面那张表里解释过）────────────────────────────

local last_error = nil

--- 上一次预览的是哪一份文档的标题。
--
-- ⚠️ 不是缓存宿主的状态：`nota.devserver.status()` 里**没有"哪一份"这个字段**，
-- 而"我请宿主预览了哪份"是这个插件自己的事（`start` 的入参就是它）。
-- 所以这条与上面"会话状态每次现问"不冲突——它记的是**我的意图**，不是宿主的现况；
-- 会话不在了（`status()` 给 nil）时它根本不会被画出来。
local preview_title = nil

-- ── 探测 ──────────────────────────────────────────────────────────────────
--
-- 两条路，**别合并**（判据见宿主 `src-tauri/src/lua/api/devserver.rs` 的
-- 「探测缓存」那一节）：
--
-- | 走哪条 | 谁在用 | 等不等 |
-- |---|---|---|
-- | `probe_now`（`force = true`） | 起预览前、「重新检测」、面板上那颗「仍然试一次」 | **等**，最多 20 秒 |
-- | `probe_async` | 面板的 `render` | **不等**：有现成结论就给，没有就回一句「正在检查」 |
--
-- ⚠️ 面板渲染**只能**走 `probe_async`。`render` 是同步拉的，在那儿等一次 `npx`
--（正常 1.3 秒、最坏 20 秒）会让那一页在那几秒里**什么都画不出来**——用户点了
-- 页签、屏幕上一点反应都没有（`docs/07` BUG-36：老宿主那版是异步探的、界面先画
-- 一张「检测中」，2026-09-25 拆成插件时把那张弄丢了）。
--
-- ⚠️ 「探过一次就一直用」这条缓存**现在在宿主那边**（键是插件 id，跟着项目根走）：
-- 根换了（用户切到别的目录的文档）就重探，用户装了 Node 之后点一下「重新检测」
-- 也就顶掉了。这里不再自己记一份——两份缓存只会分叉。

-- ── 主题：这份文档要的那个包，装没装 ────────────────────────────────────────
--
-- 2026-09-26 补的一层。起因是用户实测的那一场：
--
-- ```text
-- [nota] $ npx @slidev/cli /home/lqy/.nota-slidev-1.md --port 32791 --no-open
-- The theme "@slidev/theme-default" was not found and cannot prompt for installation
-- ```
--
-- **探测器那时候说的是"能跑"**（项目里确实有 `node_modules/@slidev/theme-`，
-- 只不过装的是 `theme-seriph`），于是面板放它过去了，进程两秒后自己退出。
-- 病因是那条判据太粗：`project_marker` 只回答"这是不是一个 Slidev 项目"，
-- 回答不了"**文档要的那一个包**在不在"——而后者是**逐份文档**都不一样的
-- （`theme: seriph` 的文档和没写主题的文档要的不是同一个包），写不进清单。
--
-- 所以宿主那边加了一条通用的入参 `probe{need = "…"}`（见 `devserver.rs`）。
-- 这个文件负责把"文档要什么"翻译成那条路径——**规则照 Slidev 自己的解析器**，
-- 不是照印象写的（本机装的那份 `@slidev/cli` 的 `resolver` 读出来的）。

--- 从文档正文里读出 frontmatter 那行 `theme:`。没有就给 `nil`。
---
--- ⚠️ 只认**开头**那一段（第一行是 `---`、到收尾的 `---` 为止）：正文里的
--- `---` 是分隔线，不是 frontmatter。
--- ⚠️ **收尾那行不在就当没写**（宁可不问，也不拿半截文字当结论）；`theme:` 后面
--- 空着也当没写（那是 YAML 的嵌套地图，不是主题名）。
local function theme_from_text(text)
  if not text or text == "" then
    return nil
  end
  -- UTF-8 的 BOM：有些编辑器存盘会带上，带上之后第一行就不是 `---` 了。
  local body = (string.gsub(text, "^\239\187\191", ""))

  -- 第一行必须是 `---`（前后空白随意，行尾可以带 `\r`）。
  local rest = string.match(body, "^[ \t]*%-%-%-[ \t]*\r?\n(.*)$")
  if not rest then
    return nil
  end
  -- 开头这段：到收尾那行 `---` 为止（末尾那行可以是文件最后一行，没有换行）。
  local head = string.match(rest, "^(.-)\r?\n%-%-%-[ \t]*\r?\n")
    or string.match(rest, "^(.-)\r?\n%-%-%-[ \t]*$")
  if not head then
    return nil
  end

  for line in string.gmatch(head, "[^\r\n]+") do
    local value = string.match(line, "^[ \t]*theme[ \t]*:[ \t]*(.-)[ \t]*$")
    if value then
      value = string.gsub(value, "^([\"'])(.-)%1$", "%2") -- 去引号
      value = string.gsub(value, "[ \t]+#.*$", "") -- 去行尾注释
      if value == "" then
        return nil
      end
      return value
    end
  end
  return nil
end

--- 主题名 → 要去问的那个**包名**。`nil` = **不用问**。
---
--- 规则（照 `@slidev/cli` 的 `resolver`，2026-09-26 从本机那份读出来的）：
---
--- | 文档里写的 | Slidev 会去找 | 这里问不问 |
--- |---|---|---|
--- | 没写 `theme:` | `@slidev/theme-default` | 问它 |
--- | `theme: none` | **一个主题都不要**（它第一句就是 `name === "none"` 就直接返回） | 不问 |
--- | 带 `/`（`@org/xxx`、`./我的主题`、`/abs`） | 按**路径**解析 | 不问（那不是包名） |
--- | `theme: seriph` | 依次试 `@slidev/theme-seriph`、`slidev-theme-seriph`、`seriph` | 问头一个 |
---
--- ⚠️ **只问头一个**：它是官方主题的命名，绝大多数文档要的就是它。要装成后两个
--- 名字（第三方 `slidev-theme-*`）的话，这里会说"没找到"——那是**有根据的猜测**，
--- 不是证明，面板上永远留着「仍然试一次」那条路（`idle_blocks` 里那句话）。
local function theme_package(name)
  if not name then
    return "@slidev/theme-default"
  end
  if name == "none" then
    return nil
  end
  if string.find(name, "/", 1, true) then
    return nil
  end
  return "@slidev/theme-" .. name
end

--- 这份文档要问的那个包：`nil` = 不用问；否则一张
--- `{ need = "node_modules/@slidev/theme-seriph", pkg = "@slidev/theme-seriph",
--- theme_name = "seriph" }`。
---
--- ⚠️ `theme_name` 是**文档里到底写没写**那一行（没写就是 `nil`，那时 `pkg` 是
--- 默认主题包）。**结论一样（都是"没装"），出路不一样**：写了的人手上已经有那行、
--- 改一个词就行；没写的人得**先加三行 frontmatter**。所以这张表要把它带出去，
--- 话才说得准（`describe_probe` 的 `notheme` 那两支）。
---
--- ⚠️ 读的是**活动文档**的正文：宿主那边 `probe`/`start` 不带 `root` 时用的也是
--- 活动文档（`lua/api/devserver.rs::活动文档`），两边看的是同一份——
--- 不会出现"问的是 A、跑的是 B"。
--- ⚠️ `need` 是**从项目根往下数**的相对路径，宿主会拿它**连父目录一起**找
--- （Node 解析 `node_modules` 就是从当前目录一层层往上的，实测那一场主题就装在
--- 文档的父目录里）。所以这里拼的是 `node_modules/<包名>`，不是绝对路径。
local function required_theme(nota)
  local text = ""
  if nota.document and nota.document.get_text then
    text = nota.document.get_text() or ""
  end
  local theme_name = theme_from_text(text)
  local pkg = theme_package(theme_name)
  if not pkg then
    return nil
  end
  return { need = "node_modules/" .. pkg, pkg = pkg, theme_name = theme_name }
end

--- 现探一次，**当场等**。用在"用户刚点了一下"的场合：那一刻给的结论得是此刻的。
---
--- 两个返回值：宿主的报告 + 这份文档要问的那个包（`required_theme` 那张表）。
--- 第二个要一起带出来，是因为"没找到"那句话得**点名**是哪个包没装（见 `describe_probe`）。
local function probe_now(nota)
  local want = required_theme(nota)
  return nota.devserver.probe({ force = true, need = want and want.need }), want
end

--- 拿探测结论，**不等人**。可能拿到 `state = "checking"`——那不是结论，
--- 是"后台正在探"（探完宿主会喊前端重拉这一页，见 `describe_probe` 那一档）。
local function probe_async(nota)
  local want = required_theme(nota)
  return nota.devserver.probe({ need = want and want.need }), want
end

--- 把宿主给的一堆**事实**翻成一句人话 + 一条细节。
--
-- ⚠️ 话写在这一侧是设计，不是随手：宿主只知道"命令通没通、项目根里有没有那个
-- 标记目录"，而"这算什么情况、该怎么办"只有这个插件知道（见 `devserver.rs::Probe`
-- 上面的注释）。所以宿主给的 `state` 只有四个词，别指望它更细。
--
-- ⚠️ 判"文档还没存过盘"用的是 `root == nil`，不是 `marker_found == false`——
-- 后者在"没存过盘"和"存过盘但目录不是 Slidev 项目"两种情况下都是 false。
-- 这两件事给用户的出路完全不同（一个是"先存盘"，一个是"去建项目"）。
--
-- `want` 是 `required_theme` 那张表（这份文档要的那个包），没有就是不用问。
-- ⚠️ 那一档必须排在"还不是一个 Slidev 项目"**后面**：`need_found` 在 `root == nil`
-- 时也是 `false`（宿主那边写的是 `root.is_some_and(…)`），而"这份文档还没存过盘"
-- 比"少一个包"更靠前——先存盘，才谈得上项目根在哪儿。
local function describe_probe(p, want)
  -- `checking`：后台那次探测还没回来（`probe_async` 才给得出这一档）。
  -- ⚠️ **这不是一个结论**，所以一个字都不许往"装没装"上靠——下面 `unknown`
  -- 那档的注释写着同一条道理，这里更甚：此刻我们连"问没问出结果"都还不知道。
  if p.state == "checking" then
    return {
      state = "checking",
      tone = "muted",
      message = T("Checking whether Slidev is available on this machine… (up to 20 seconds)"),
      detail = T("This page updates itself once the check finishes. If you do not want to wait, press “Check now” below."),
    }
  end

  local ver = p.version and (" " .. p.version) or ""

  if p.state == "ready" then
    if not p.marker_found then
      if not p.root then
        return {
          state = "missing",
          tone = "warn",
          message = T("Slidev%s is installed, but this document has not been saved to disk yet.", ver),
          detail = T("Slidev takes the entry file's directory as the project root (relative paths such as `![](./img.png)` rely on it), and a brand-new document has no directory yet. Save it first, then try again."),
        }
      end
      return {
        state = "missing",
        tone = "warn",
        message = T("Slidev%s is installed, but `%s` is not a Slidev project yet.", ver, p.root),
        detail = T("Neither that directory nor any of its parents has `node_modules/@slidev/theme-*`. Slidev looks for even the default theme inside the project and exits when it cannot find one — the `npm init slidev@latest` line in the official guide is what creates such a project."),
      }
    end
    -- 这份文档要的那个**主题包**没装（`need_found == false`）。
    -- ⚠️ 这一档就是 2026-09-26 用户实测那一场：项目里有一个 `@slidev/theme-*`
    -- 就算"是项目"（上面那条已经过了），但**不是文档要的那一个** ⇒ Slidev 起手
    -- 就去要它的主题，要不到就直接退出，于是"面板说能跑、进程两秒就没了"。
    --
    -- ⚠️ **两支：文档压根没写 `theme:`（要的是默认主题包）与写了但那个没装。**
    -- 分开说的理由只有一个：**出路不一样**。写了的人手上已经有那一行，改一个
    -- 词就行；没写的人**连那行都没有**，得先加三行 frontmatter——同一句话
    -- （"把开头那行 `theme:` 改成一个装过的"）在后者身上是**照着做不出来的**。
    -- 判据就是 `want.theme_name` 是不是 `nil`（`required_theme` 带出来的）。
    if p.need_found == false and want then
      if not want.theme_name then
        -- ⚠️ 这一支是**2026-09-26 用户那份文档的形状**：他有 `@slidev/theme-seriph`
        -- 却一个 `theme:` 都没写，于是 Slidev 去要 `@slidev/theme-default`。
        -- 而 53 起那个包**不再随 `@slidev/cli` 一起装**（实测：本机 `find` 它 0 命中，
        -- 而没写主题的文档一跑就退、写 `theme: none` 或 `theme: seriph` 的都能起）——
        -- 也就是说**全新按官方指南装的机器上，没写主题的文档都跑不起来**。
        return {
          state = "notheme",
          tone = "warn",
          message = T("This document names no theme, and the default theme `%s` Slidev asks for is not installed.", want.pkg),
          detail = T("Looked for `%s` (and in every parent directory). Even a document that names no theme makes Slidev look for that default theme package inside the project — since 53 it no longer ships with `@slidev/cli` — and Slidev exits when it cannot find one. Three ways out: run `npm i %s` inside `%s` (that gives you the default look); or add three lines at the very top of the document — `---`, `theme: none`, `---` (no theme, just to get the content on screen); or write the name of a theme that is installed on this machine.",
            want.need,
            p.root,
            want.pkg
          ),
        }
      end
      return {
        state = "notheme",
        tone = "warn",
        message = T("The theme `%s` this document asks for is not installed.", want.pkg),
        detail = T("Looked for `%s` (and in every parent directory). Slidev resolves a theme by trying `@slidev/theme-<name>` and then `slidev-theme-<name>`; this is the first of the two. Install one inside `%s`: `npm i %s`; or change the `theme:` line at the top of the document to `none` (no theme) or to the name of a theme that is installed.",
          want.need,
          p.root,
          want.pkg
        ),
      }
    end

    return {
      state = "ready",
      tone = "success",
      message = T("Detected Slidev%s — you can open the preview.", ver),
      detail = "",
    }
  end

  if p.state == "missing" then
    -- ⚠️ 判据是宿主 `detail` 里那句"没找到 `x`"——那是**我们自己**写的话
    --（`devserver.rs` 的同一个分支），不是 git/npm 的输出，所以匹配得住。
    -- 分出来是因为这两件事的出路不同：一个是去装 Node，一个是去装 Slidev。
    local msg
    if string.find(p.detail, "没找到", 1, true) then
      msg = T("The command to run was not found on this machine — most likely Node.js is not installed. Slidev is a front-end tool, so node/npx has to be there first.")
    else
      msg = T("`%s` cannot run offline, so Slidev is probably not installed on this machine yet.", p.command)
    end
    return { state = "missing", tone = "warn", message = msg, detail = p.detail }
  end

  -- unknown：探测自己没问出结果。**不等于没装**，所以措辞上不许暗示"去装一个"。
  return {
    state = "unknown",
    tone = "muted",
    message = T("The probe got no answer: `%s` did not reply within 20 seconds. That does not mean it is not installed.", p.command),
    detail = T("A custom start command may not understand `--version`, or it may already be running and have no intention of exiting. If you want to try, press “Try anyway”."),
  }
end

-- ── 日志 ──────────────────────────────────────────────────────────────────

--- 把宿主抛过来的错**只剥掉一层壳**：`pcall` 抓到的 `mlua::Error::RuntimeError`
--- 显示出来是 `runtime error: <真正的话>`。
--
--- ⚠️ **里面的字一个字都不改**：那句话是宿主写的（进程输出、端口、超时秒数都在
--- 里面，见 `devserver.rs::start`），比这个插件能编的准。
--
--- ⚠️ 只有**调用栈**要砍掉：mlua 抛出来时后面会接一段 `stack traceback:`——
--- `[C]: in function 'pcall'`、`[string "…/main.lua"]:434: in function <...>:414`。
--- 那些行号是**这个文件自己的**，对用户一个字都没用，而且会把真正的原因挤出面板
--- （用户 2026-09-26 贴回来的那一屏就是这样：病因"主题没找到"底下跟着五行栈）。
local function err_text(err)
  -- ⚠️ `gsub` 返回**两个**值（新串、换了几处）。用括号把它切成一个，
  -- 不然拼进字符串的时候会把那个数字带上（`"…" .. gsub(...)` = "串2"）。
  local s = (string.gsub(tostring(err), "^runtime error:%s*", ""))
  local cut = string.find(s, "stack traceback:", 1, true)
  if cut then
    -- 连它前面那个换行一起砍（`\nstack traceback:` 是 mlua 的排版）。
    s = (string.gsub(string.sub(s, 1, cut - 1), "\n+$", ""))
  end
  return s
end

--- 把进程输出切成一块块 `text`。**只在出事之后画**（正常看预览不需要读日志）。
local function log_blocks(nota)
  local raw = nota.devserver.log()
  if not raw or raw == "" then
    return {}
  end

  local lines = {}
  for line in string.gmatch(raw, "[^\n]+") do
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    return {}
  end

  local blocks = {
    { kind = "separator" },
    { kind = "heading", text = T("Process output (last few lines)") },
  }
  local first = #lines - LOG_LINES + 1
  if first < 1 then
    first = 1
  end
  for i = first, #lines do
    local line = lines[i]
    if #line > LOG_COL then
      line = string.sub(line, 1, LOG_COL) .. "…"
    end
    blocks[#blocks + 1] = { kind = "text", tone = "muted", text = line }
  end
  if first > 1 then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "muted",
      text = T("(%d earlier lines not shown.)", first - 1),
    }
  end
  return blocks
end

-- ── 面板内容 ──────────────────────────────────────────────────────────────
--
-- ⚠️ `render` **每次拉都现跑一遍**（宿主那侧有用例钉着这条），所以它里面不许
-- 写"加载时怎么样"。这里唯一存着的东西是探测结果（有 TTL，理由见上）和
-- "上次失败说了什么"（通知一闪就没，面板上得留一条）。

--- 会话活着：一块 `frame` + 两颗按钮。
--
-- ⚠️ `frame` 块里**只写 `height`**。地址由宿主填，而且只会填**这个插件自己**
-- 这场会话的地址（`lua/api/devserver.rs::填_frame`）——插件在这里写 url 也没用，
-- 宿主会先抹掉再填。这是"嵌自己的预览"和"嵌任意网页"的分界。
local function running_blocks(s)
  local title = preview_title
  if not title or title == "" then
    title = T("Current document")
  end

  return {
    { kind = "heading", text = T("Previewing") },
    { kind = "text", tone = "muted", text = T("%s · port %d", title, s.port) },
    { kind = "frame", height = 520 },
    {
      kind = "buttons",
      items = {
        { label = T("Stop preview"), command = "stop" },
        -- 全屏演示、演讲者视图（双屏）只有真浏览器有，嵌在面板里的 iframe
        -- 两样都做不到。地址还是宿主填的那个（插件交不出别的）。
        { label = T("Open in browser"), command = "open_browser" },
      },
    },
    {
      kind = "text",
      tone = "muted",
      text = T("Edits re-render automatically (Slidev's own hot reload). Only one screen is drawn here; press “Open in browser” when you present full-screen."),
    },
  }
end

--- 没有会话：先问一句探测结论（**不等人**，见 `probe_async`），再按它说话。
local function idle_blocks(nota, s)
  local p, want = probe_async(nota)
  local d = describe_probe(p, want)
  local blocks = {}

  -- 会话还在、但进程已经退出了（自己崩了、或者被外面 kill 了）。
  -- ⚠️ 这句必须与"压根没起过"分开说：前者用户刚点过、正在等画面，
  -- 后者是刚打开面板。混成一句的话，前一种情况下用户会以为按钮没生效。
  if s then
    blocks[#blocks + 1] = {
      kind = "text",
      tone = "danger",
      text = T("The preview process has exited (port %s). Below is its last output.", s.port),
    }
  end

  blocks[#blocks + 1] = { kind = "text", tone = d.tone, text = d.message }
  if d.detail ~= "" then
    blocks[#blocks + 1] = { kind = "text", tone = "muted", text = d.detail }
  end

  if last_error then
    blocks[#blocks + 1] = { kind = "text", tone = "danger", text = T("Last start failed: %s", last_error) }
  end

  -- 事实表：用户拿着它们能自己判断（比如"查的是另一个目录"、"装是装了但没主题"）。
  -- 探测自己崩掉时 `command` 是空的，那这块就不画——空表比没有更难看。
  -- ⚠️ `checking` 也不画：那一档手里**只有命令和根**（版本、主题都还没有），
  -- 摆半张表出来，用户会以为"主题：没找到"是结论。
  if d.state ~= "checking" and p.command and p.command ~= "" then
    local items = { { label = T("Command"), value = p.command } }
    if p.version then
      items[#items + 1] = { label = T("Version"), value = p.version }
    end
    if p.root then
      items[#items + 1] = { label = T("Project root"), value = p.root }
    end
    -- ⚠️ 这一格有**两把尺子**，问过哪个就用哪个：
    --   · `need_found ~= nil` ⇒ 问的是**这份文档要的那一个包**（细）；
    --   · 否则 ⇒ 只问过"这里是不是个 Slidev 项目"（`marker_found`，粗）。
    -- 混着读会让用户以为"找到了"是指他要的那个包找到了——2026-09-26 那一场
    -- 就是这么被糊弄过去的（摆的是"主题：找到了"，跑起来却少包）。
    local label, value, tone = T("Theme"), nil, nil
    if p.need_found ~= nil and want then
      label = T("Theme package")
      value = p.need_found and T("found `%s`", want.pkg) or T("no `%s`", want.pkg)
      tone = p.need_found and "success" or "warn"
    else
      value = p.marker_found and T("found") or T("no `@slidev/theme-*`")
      tone = p.marker_found and "success" or "warn"
    end
    items[#items + 1] = { label = label, value = value, tone = tone }
    blocks[#blocks + 1] = { kind = "fields", items = items }
  end

  -- 出事之后才把日志端出来（正常看预览的人不需要读它）。
  if last_error or (s ~= nil) then
    for _, b in ipairs(log_blocks(nota)) do
      blocks[#blocks + 1] = b
    end
  end

  -- ⚠️ 按钮**排在日志后面**的话，出事时用户得先滚过一屏日志才够得着它。
  -- 日志最多 12 行，所以还在下面没关系——但按钮只有两三颗，放上面更顺。

  -- 还在探：只留一条"等不及就现探"的路。
  -- ⚠️ **这一档不画「仍然试一次」**：此刻还不知道装没装，摆一颗"要不硬闯试试"
  -- 的按钮等于替用户下了结论（`unknown` 那一档的注释写着同一条道理）。
  if d.state == "checking" then
    blocks[#blocks + 1] = {
      kind = "buttons",
      items = { { label = T("Check now"), command = "recheck", style = "primary" } },
    }
    return blocks
  end

  local force = d.state ~= "ready"
  local items = {
    {
      -- 探不通时是「仍然试一次」：**探测是有根据的猜测，不是证明**
      --（主题可能装在别处、命令可能装在 PATH 之外），所以永远留一条硬闯的路。
      label = force and T("Try anyway") or T("Start preview"),
      command = "start",
      style = "primary",
      args = { force = force },
    },
    { label = T("Re-check"), command = "recheck" },
  }
  -- 「没装」那两档上给一条去官网的路。
  -- ⚠️ 用户 2026-09-24 对面板的原话就是「**如果没有，导航到官网的下载指南**」，
  -- 而拆成插件时这条链接顺手一起没了（`docs/07` BUG-35）。
  -- ⚠️ **`unknown` 那档不给**：那时"装没装"还不知道，摆一颗"去装个吧"的按钮
  -- 就是把猜测当结论——描述那一档的注释里已经写死了这条口径。
  if d.state == "missing" then
    items[#items + 1] = { label = T("Open the official install guide"), command = "open_guide" }
  end
  blocks[#blocks + 1] = { kind = "buttons", items = items }

  return blocks
end

local function panel_content(nota)
  -- ⚠️ 现问，**不缓存**：进程可能自己死了，"停止"也可能刚从菜单点过。
  local s = nota.devserver.status()
  if s and s.alive then
    return running_blocks(s)
  end
  return idle_blocks(nota, s)
end

-- ── 命令 ──────────────────────────────────────────────────────────────────

--- 起预览。`args.force = true` 时不信探测的结论，照样起。
local function do_start(nota, force)
  -- ⚠️ 每次 start 都**现探一次**（不走缓存）：用户刚点了菜单，那一下我们给的
  -- 结论得是此刻的机器状态，而不是三十秒前那次画面的。代价是这一下多花
  -- 一两秒——接下来要等 180 秒的启动，这点不算什么。
  local p, want = probe_now(nota)
  local d = describe_probe(p, want)

  if d.state ~= "ready" and not force then
    -- **不盲起**：先告诉用户差什么。面板上那句话是同一句（`describe_probe`），
    -- 两处共用一个来源，免得菜单里说的和面板里说的不一样。
    nota.ui.notify(d.message, "warn")
    nota.ui.refresh("preview")
    return { ok = false, error = d.message }
  end

  preview_title = nota.document.get_title()

  -- ⚠️ **包 pcall**：`start` 失败时是**抛错**的（超时、进程起不来、被停掉），
  -- 而"抛出去"在插件里等于"这条命令崩了"——前端只会看到一次调用失败，
  -- 用户看不到病因。接下来那句 `notify` 才是给人看的。
  local ok, res = pcall(nota.devserver.start)
  if not ok then
    last_error = err_text(res)
    nota.ui.notify(T("The preview did not start: %s", last_error), "error")
    -- ⚠️ 这一下**必须在 notify 之后**：面板上要能读到 `last_error` 和日志，
    -- 而前端收到刷新事件就会来拉一次。
    nota.ui.refresh("preview")
    return { ok = false, error = last_error }
  end

  last_error = nil
  nota.ui.notify(T("Preview started (port %d)", res.port), "success")
  nota.ui.refresh("preview")
  return { ok = true, port = res.port, url = res.url }
end

--- 收摊。**宿主负责杀整棵进程树 + 删入口文件**（这个插件碰不到进程）。
local function do_stop(nota, silent)
  local had = nota.devserver.status()
  nota.devserver.stop()
  preview_title = nil
  if had then
    if not silent then
      nota.ui.notify(T("Preview stopped"), "info")
    end
    nota.ui.refresh("preview")
  elseif not silent then
    nota.ui.notify(T("The preview is not running"), "warn")
  end
end

-- ── 生命周期 ──────────────────────────────────────────────────────────────

function M.on_load(nota)
  -- ⚠️ **第一件事**:把文案取用器接到宿主给的这份表上（上面 `local T` 那段）。
  -- 在这一行之前调 `T` 只会拿到原文——这是对的（`nota` 那时还没有）。
  -- ⚠️ 局部名一律 ASCII：**Lua 的标识符不许有非 ASCII 字符**（`local 一句`
  -- 是语法错误，不是"能跑但编译器不高兴"）。这个坑在 `plugins/README.md` 里
  -- 记过一条，这里再犯一次就是因为顺手写中文名。中文放进注释和字符串。
  T = function(fmt, ...)
    local s = nota.i18n and nota.i18n.text(fmt) or nil
    s = s or fmt
    if select("#", ...) > 0 then
      return string.format(s, ...)
    end
    return s
  end

  nota.command.register("start", function(args)
    local force = (args and args.force) == true
    return do_start(nota, force)
  end)

  nota.command.register("stop", function()
    do_stop(nota, false)
    return { ok = true }
  end)

  -- 现探一次（**当场等**，把宿主那条缓存顶掉），然后重画面板。
  -- 「重新检测」与「立刻检测」都走这里：前者是"我装了东西，再看一眼"，
  -- 后者是"等不及你后台那一下了"——两件事要的都是**此刻**的结论。
  nota.command.register("recheck", function()
    local p = probe_now(nota)
    last_error = nil
    nota.ui.refresh("preview")
    return { ok = true, state = p.state }
  end)

  -- 把这场预览交给系统浏览器。
  -- ⚠️ 走的是 `nota.devserver.open_in_browser`，**不收参数**——能打开的只有
  -- 这个插件自己这场会话的地址。这不是 `nota.ui.open_url`（那条只放行 https，
  -- 而本地预览恰恰是 http，判据见宿主 `lua/api/devserver.rs` 文件头）。
  -- ⚠️ 「没装」那两档上那颗「去官网看安装指南」才是真走 `ui.open_url` 的
  -- ——它要去的是外站，两条路各管一头（能力表那段注释里写着同一条）。
  nota.command.register("open_browser", function()
    local ok, err = pcall(nota.devserver.open_in_browser)
    if not ok then
      nota.ui.notify(tostring(err), "warn")
      return { ok = false, error = tostring(err) }
    end
    return { ok = true }
  end)

  -- 去官网看安装指南。**只在「没装」那两档的按钮组里出现**（`idle_blocks`）。
  -- ⚠️ 地址是模块级常量 `GUIDE_URL`，理由写在那一行上（那个站是 SPA）。
  -- ⚠️ 走 `nota.ui.open_url`（能力表里申请了 `ui.open_url`）——那道闸只放行
  -- `https://`，`GUIDE_URL` 合格；换成 http 会被**当场报错**（宿主抛的）。
  nota.command.register("open_guide", function()
    local ok, err = pcall(nota.ui.open_url, GUIDE_URL)
    if not ok then
      nota.ui.notify(T("Could not open the browser: %s", tostring(err)), "warn")
      return { ok = false, error = tostring(err) }
    end
    return { ok = true }
  end)

  -- ── 界面贡献 ────────────────────────────────────────────────────────────
  --
  -- ⚠️ `wide = true`：幻灯片是**横向**的（16:9）。右栏默认那点宽度里嵌一块
  -- 画面，字会小到看不清——宽版是给"预览"这类面板留的（`docs/13` §面板）。
  nota.ui.register_panel({
    id = "preview",
    title = "Slidev",
    location = "right",
    wide = true,
    -- ⚠️ **每次拉都现跑一遍**，所以这里只能写"现在怎么样"。
    render = function()
      return panel_content(nota)
    end,
  })

  nota.ui.register_menu({
    label = T("Start Slidev preview"),
    command = "start",
    menu = "plugins",
  })

  nota.ui.register_menu({
    label = T("Stop Slidev preview"),
    command = "stop",
    menu = "plugins",
  })

  -- ⚠️ 这里**什么都不做**，而且刻意不在这里探一次：
  -- `on_load` 是同步走的，探测要跑一次 `npx`（最长 20 秒），
  -- 那会把应用启动卡住（`nota.devserver` 文件头也写着同一条）。
  -- 面板第一次被打开时**开一次后台探测**（`probe_async`）：那一页先画一句
  -- 「正在检查…」，探完宿主喊前端重拉，再换成结论。
end

function M.on_unload()
  -- ⚠️ 这里**收不了摊**，而且不是漏写了：宿主调 `on_unload` 时**不传 `nota`**
  --（`lua/mod.rs::unload` 是 `f.call::<()>(())`），所以这个函数里根本拿不到
  -- `nota.devserver`。
  --
  -- 收摊由**宿主**负责：插件被停用时 `plugin/mod.rs::set_enabled` 会主动
  -- 停掉挂在这个插件 id 上的那场会话（那个进程是宿主起的，本来就该宿主收）。
  -- 这条值得记下来：**"插件被停用"和"插件自己收摊"不是同一件事**，
  -- 凡是宿主持有的东西（进程、端口、影子文件），都得宿主那侧收。
end

return M
