-- 「AI 可读的文件」：把工作区里的 `.md` 挑几篇，一起送给模型（`docs/07` 第 61 项 (c)）。
--
-- 用户原话是「**可以选择AI可读的范围，也就是md文件，上限5个，大小上限为AI
-- 上下文长度**」。这一份管的就是那三件事：**哪些**、**几个**、**多大**。
--
-- # 三件事都是**可验的**，所以口径写死
--
-- | 问题 | 答案 | 为什么 |
-- |---|---|---|
-- | 范围属于谁 | **属于那个对话**（`chat.scope`） | 用户说的是"可以创建多个对话"，而"这一篇让 AI 看看"是那一轮对话里的意图。挂在全局的话，切到另一个对话时那段参考还在，用户看不见它、也想不到它 |
-- | 上限几个 | **5 个**（`MAX_FILES`） | 用户写死的数 |
-- | 大小怎么算 | **字符数**，总共 `scope_chars`（默认 20000，设置里改） | ⚠️ **不是 token**。数 token 要一份模型自己的分词表——那是另一份几百 KB 的数据，还得跟着模型换代，而这个插件连 JSON 都不自带。字符数是**粗略但谁都能算**的尺子，面板上那句提示也照这么写，不假装它是 token |
--
-- ⚠️ "大小上限为 AI 上下文长度"这句话**没有照字面做**：插件知道自己的接口地址
-- 和模型名，但**不知道那个模型的上下文窗口有多大**（各家不一样，还会随版本变，
-- 没有一张能查的表）。所以它变成**一个用户填的数**——填小了浪费、填大了被服务端
-- 拒（那是个 400，正文里写着原因，用户看得见）。这是**有意的取舍**，记在 `docs/07`。
--
-- # 从哪儿找文件
--
-- `nota.fs.list(".")`：**工作区根目录**底下那一层，只认 `.md`，按名字排。
-- ⚠️ **不递归**：`nota.fs.list` 就是"一层"，而"递归扫一遍工作区"是另一件事
-- （大仓库里那是几万次系统调用，插件没有理由为了列个清单去干那个）。
-- 需要的时候再说，别在这儿偷偷展开。
--
-- ⚠️ 变量名一律 ASCII（理由写在 `main.lua` 文件头）。

local util = require("util")

local M = {}

-- ── 文案 ──────────────────────────────────────────────────────────────────
-- 每个模块各有一份 `T`，都由 `main.lua` 的 `on_load` 接上（见 `util.lua` 文件头）。
local T = function(s) return s end

--- 把文案取词器接上宿主（由 `main.lua` 的 `on_load` 调）。
function M.bind_text(f)
  T = f
end

-- ── 参数 ──────────────────────────────────────────────────────────────────

--- 一个对话最多挂几个文件。**用户可以看见的那个数**，面板上会写出来。
M.MAX_FILES = 5

--- 面板上最多画几个可选文件。**只是画**——画 200 颗按钮那一栏就没法用了。
M.SHOW_MAX = 40

-- ── 找文件 ────────────────────────────────────────────────────────────────

--- 这一段可读的范围能选哪些文件。
---
--- 返回 `{ "a.md", "b.md" }`，或者 `nil, 原因`（没开工作区、宿主没给 `nota.fs`、
--- 目录读不到）。⚠️ **失败是有话要说的**（"先打开一个工作区"），所以这里区别于
--- `store.load` 那条"读不到就是空"：那个是"正常地还没有"，这个是"现在做不了"。
function M.available(nota)
  if not (nota.fs and nota.fs.list) then
    return nil, T("This host build has no nota.fs, so no files can be listed.")
  end

  local ok, names = pcall(function()
    return nota.fs.list(".")
  end)
  if not ok then
    return nil, T("No workspace is open, so the files of the workspace cannot be listed. Open a folder first.")
  end
  if type(names) ~= "table" then
    return {}
  end

  local out = {}
  for _, name in ipairs(names) do
    -- ⚠️ 只认小写的 `.md`：`.MD` 在同一个目录里会排到另一处，而按后缀挑的时候
    -- 又多一处要记得同时改。真遇到 `.MD` 的时候再说（那时是用户来提）。
    if type(name) == "string" and string.sub(name, -3) == ".md" and #out < M.SHOW_MAX then
      out[#out + 1] = name
    end
  end
  return out
end

--- 这个对话里挂没挂这个名字。
function M.has(c, path)
  for _, p in ipairs(c.scope or {}) do
    if p == path then
      return true
    end
  end
  return false
end

--- 挂上 / 摘下。返回 `true` 表示挂上了，`false` 表示摘掉了，`nil, 原因` 表示没成。
---
--- ⚠️ 上限是**在这里**挡的，不是在界面里：命令可以被菜单、被别的插件调进来，
--- 只把按钮画灰掉的话，另一条路照样能挂上第 6 个。
function M.toggle(nota, c, path)
  if type(path) ~= "string" or path == "" then
    return nil, T("No file was named.")
  end
  c.scope = c.scope or {}

  for i, p in ipairs(c.scope) do
    if p == path then
      table.remove(c.scope, i)
      return false
    end
  end

  if #c.scope >= M.MAX_FILES then
    return nil, T("At most %d files can be readable in one chat; unselect one first.", M.MAX_FILES)
  end
  c.scope[#c.scope + 1] = path
  return true
end

--- budget：这一轮参考文件总共能占多少**字符**。
function M.budget(nota)
  local raw = util.read_setting(nota, util.KEY_SCOPE, util.DEFAULT_SCOPE)
  local n = tonumber(raw)
  -- ⚠️ 填了个非数字（`"20k"`）就当默认：**不报错**。这是"我懒得算"，不是
  -- "我要一个空的范围"——报错挡住的是用户本来想干的事。
  if not n or n < 0 then
    n = tonumber(util.DEFAULT_SCOPE)
  end
  return math.floor(n)
end

-- ── 拼进系统消息 ──────────────────────────────────────────────────────────

--- 这一轮参考文件的正文 ＋ 一条"谁被截了"的账。
---
--- 返回 `text`（拼好的那一段，**没挂文件时是空串**）、`used`（用掉多少字符）、
--- `notes`（一个字符串数组：读不到的、被截断的、预算用完了没放进来的）。
function M.render(nota, c)
  local picked = c.scope or {}
  if #picked == 0 then
    return "", 0, {}
  end

  local budget = M.budget(nota)
  local left = budget
  local used = 0
  local notes = {}
  local parts = {}

  for _, path in ipairs(picked) do
    if left <= 0 then
      notes[#notes + 1] = T("%s was not sent: the size budget (%d characters) is used up.", path, budget)
    else
      local ok, body = pcall(function()
        return nota.fs.read(path)
      end)
      if not ok or type(body) ~= "string" then
        notes[#notes + 1] = T("%s could not be read (it may have been moved or deleted).", path)
      else
        local whole = util.len(body)
        local take = body
        if whole > left then
          take = util.cut(body, left)
          notes[#notes + 1] = T("%s was cut short: it has %d characters and only %d were left in the budget.", path, whole, left)
        end
        parts[#parts + 1] = "──── " .. path .. " ────\n" .. take
        used = used + util.len(take)
        left = left - util.len(take)
      end
    end
  end

  if #parts == 0 then
    return "", 0, notes
  end
  return table.concat(parts, "\n\n"), used, notes
end

return M
