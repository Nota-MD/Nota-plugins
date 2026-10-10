# Nota 插件仓库

Nota 那四个内置插件的**源码与发布仓库**（2026-10-09 从主仓库 `plugins/` 整个搬出来，
独立 git）。分工照工作区里另外两套的体例（`Folio-plugin/`、`Vellum-extensions/`）：

| 仓库 | 职责 |
|---|---|
| `Nota`（编辑器） | 宿主程序、Lua 运行时与 `nota.*` API（`src-tauri/src/lua/`）、装卸 / 信任 / 包格式、前端的面板 DSL（`src/ui/panel-nodes.ts`）、以及插件作者文档（`docs/11`–`13`） |
| `Nota-plugins`（本仓库） | 四个插件的**源码**（`plugins/`）、打包工具、插件自己的**无头测试**、开发那两个要外部程序的插件时用的假服务 |

⚠️ **主仓库里没有一份副本**：改插件只在本仓库改。宿主怎么找到它们，见下。

## 宿主从哪儿读这些插件

| 场合 | 落点 |
|---|---|
| 开发态（`cargo build` 出来的 debug 二进制） | 环境变量 **`NOTA_PLUGINS_DIR`**；没设时扫**本仓库的 `plugins/`**（相对主仓库就是同级目录 `../Nota-plugins/plugins`）；再没有才退回老的 `<主仓库>/plugins`（那条留着只是为了老检出还能跑） |
| 打包态 | 主仓库 `src-tauri/tauri.conf.json` 的 `bundle.resources` 里那条 `{"../../Nota-plugins/plugins": "plugins"}`（⚠️ **键是相对 `src-tauri/` 的**，所以要两级 `..` 才到工作区）把整棵目录拷成资源目录里的 `plugins/` |

⚠️ **"装出来的 Nota 自带这四个插件"这件事，由主仓库那条 `bundle.resources` 说了算**：
删掉它，装出来的包就一个插件都没有，用户在「设置 → 拓展 → 从文件安装…」里自己装
`.nota-plugin`（`Folio-plugin` 那边走的就是这条路）。今天留着——**换这一档是一行的事**。

⚠️ **开发态改 Lua 不用重编**：扫的是源码目录，存盘即生效（重启应用，或把那一页关掉再打开）。
⚠️ 但**改 `plugin.toml` 的能力 / 菜单 / 面板声明要重启应用**——那份清单是启动时读的。

## 内容

- `plugins/<id>/` —— 一个插件一个目录：
  - `plugin.toml`：清单（id / 版本 / **能力** / `[[settings]]` 声明的设置格 / `langs`）
  - `main.lua`：入口；其余 `.lua` 按功能拆（`require` 这几个字是宿主的沙箱版，只在插件自己目录里找）
  - `lang/<tag>.toml`：译文；**键是代码里的英语原文**（与宿主前端同一条规矩）
  - `design/`：写作统计那几张设计稿（改版式时要连着改的那份）
- `tools/pack-plugin.py` —— 把一个插件目录打成 `.nota-plugin`（可签名）
- `tools/stats-state-test.lua` —— 写作统计的**无头状态机测试**（桩掉 `nota`，时钟由测试推）
- `tools/ai-stream-test.lua` —— AI 插件流式那一条路的无头测试
- `tools/git-panel-test.lua` —— Git 插件的**面板与选择状态**无头测试（2026-10-09 加：
  那张 `attempt to get length of a nil value (global 'picked')` 的截图就是它的来由）
- `tools/undeclared-globals.lua` —— 静态扫"没声明就赋值"的名字（＝ 想写全局）
- `tools/stub-openai.py` / `tools/stub-slidev.py` —— 开发那两个插件时用的假服务
- `tools/check.sh` —— 本仓库自己的闸（行数 ＋ 上面三份无头测试 ＋ 没声明就赋值的名字）

## 当前插件

| 插件 | id | 版本 | 说明 |
|---|---|---|---|
| AI 助手 | `nota.ai` | 0.1.0 | 润色 / 续写 / 总结 / 翻译；自己的 API 密钥 |
| Git 版本控制 | `nota.git` | 0.1.0 | 改动、差异、提交；走系统 `git` |
| Slidev 演示 | `nota.slidev` | 0.1.0 | 把当前文档当幻灯片放出来 |
| 写作统计 | `nota.stats` | 0.5.0 | 像运动手表那样记一轮写作 ＋ 分享图 |

## 怎么跑

⚠️ 这台机器上 `lua` 不在宿主里，在容器 `tauri-dev` 里（与主仓库同一套工装）：

```sh
# 闸（行数 + 三份无头测试 + 没声明就赋值的名字）
bash tools/check.sh

# 单跑写作统计那一份（ALL PASS（203 条断言））
podman exec -u 1000 -w "$PWD" tauri-dev lua tools/stats-state-test.lua

# 打包一个插件（输出 <插件目录>/dist/<id>-<版本>.nota-plugin）
python3 tools/pack-plugin.py plugins/git
```

## 规矩（照主仓库同一套，别松）

1. ⚠️ **变量名一律 ASCII**：Lua 的标识符不许有非 ASCII 字符，写了是**语法错误**，
   症状是整份插件加载失败、面板与菜单一起消失（`main.lua` 与 `cards.lua` 头上都记着）。
2. ⚠️ **界面文案写英语原文**，译文进 `lang/<tag>.toml`；键就是那句原文。
3. ⚠️ **每个文件 ≤ 1000 行**（目标 300–800）：`bash tools/check.sh` 报，`main.lua`
   现在 902 行——往它里面加东西之前先想怎么拆。
4. ⚠️ **只许用 `nota.*` API**：宿主的能力白名单在 `plugin.toml` 的 `capabilities` 里，
   没申请的能力调不动（文档在主仓库 `docs/11`–`13`）。
5. ⚠️ **别把宿主的东西搬进来**：面板长什么样归宿主（`kind = "..."` 那几个块），
   插件只说"要什么"。
