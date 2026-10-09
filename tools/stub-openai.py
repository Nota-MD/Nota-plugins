#!/usr/bin/env python3
"""一个假的 OpenAI 兼容接口，专门用来**离线验 AI 插件的对话框与改动块**。

它跟 `tools/stub-slidev.py` 是同一类东西：**替身**。区别是那边替的是一个进程，
这边替的是一条 HTTP 服务。

# why

`docs/06` §5.12 记着一条实测教训：**验 AI 那一格要花真钱、还依赖真密钥**，
所以"别连着点"。但改动块那几条路（应用成功 / 应用失败 / 坏行 / 追加 / 多处）
**每一条都值得单独看一眼界面**——那就得能反复点，而且每次的输入要**可控**。

所以这个替身做三件事：

1. **不需要密钥**（字段收下、不校验）；
2. 回一段**可预测**的回答：先一段普通文本，末尾附 `` ```nota-diff `` 改动块；
3. 改动块的内容**从请求里那份文档里现取**——这样"逐字一致"一定成立，
   不用手工把文档抄进桩里（抄错一个字，验的就是"没找到"那条错路）。

# 用法

```sh
python3 tools/stub-openai.py            # 绑 127.0.0.1:8731
```

然后把插件设置指过来（⚠️ **http + 回环**才被 `nota.http` 的地址围栏放行，
见 `docs/13` §9）：

```sh
podman exec -u 1000 tauri-dev cat > ~/.config/nota/plugin-settings/nota.ai.toml <<'EOF'
api_key = "stub"
base_url = "http://127.0.0.1:8731/v1"
model = "stub"
EOF
```

⚠️ **验完把用户那三个值改回去**（那一格动的是**用户的**密钥/地址/模型，
不是测试夹具——`docs/06` §5.12 ③ 有同样的提醒）。

# 模式（环境变量 `STUB_MODE`）

| 值 | 回答里的改动块 | 界面上该看到什么 |
|---|---|---|
| `replace`（默认） | `- 第一行` / `+ [改] 第一行` | 一块 diff（一红一绿）；点「应用改动」→ 文档第一行真的变了 |
| `insert` | 只有 `+` 两行 | 纯插入 ⇒ 规矩是**追加到文末** |
| `twohunks` | 两个围栏，分别改第一行与最后一行 | 两块 diff，标着「第 1 处」「第 2 处」 |
| `bad` | 围栏里混一行不带标记的解释 | diff 之上多一句「有 1 行既不 - 也不 +」 |
| `dirty` | `-` 一行**文档里没有**的话 | 点「应用改动」→ **报"没找到"、文档一个字都不动** |
| `nofence` | 没有围栏，只有正文 | 只有一条消息，**没有** diff、**没有**「应用改动」 |

`STUB_PORT` 换端口。请求原文会写进 `STUB_LOG`（默认 `/tmp/stub-openai-last.json`），
用来核"插件到底送了什么上去"。

# 流式（`docs/07` 第 58 项，2026-10-04 加）

`STUB_MODE=stream` 时**不管请求里写没写 `stream`**，都按 SSE 一段一段往外吐
（一段 `data: {...}` ＋ 最后一行 `data: [DONE]`）。正文和围栏与 `replace` 那份
一模一样，所以"边打边出完之后，改动块照样能应用"这一条一眼就能验。

⚠️ **另外那些模式下，请求里带 `stream = true` 时桩照旧回一份整段 JSON**
——那不是疏忽，那是**故意留的第二个用例**：现实的网关/自建服务里有一大批
直接忽略这个字段。插件那边必须**自动退回整段收**（`chat.lua::ask`），
界面上的表现是"没有边打边出，但回答照旧出来"，**不该**是一条报错。

`STREAM_SLICE` 换每个 HTTP 分块写多少**字节**（默认 23）。⚠️ **按字节切是
故意的**：23 不是任何东西的倍数，切下去必然会把某个汉字劈成两半落在两个
TCP 分块上——宿主要保证的正是"**绝不把半个汉字交给插件**"（`http.rs::切出完整段`）。
想要更碎的切法就把它调小，想要"一次到齐"就调大（比如 100000）。
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("STUB_PORT", "8731"))
MODE = os.environ.get("STUB_MODE", "replace")
LOG = os.environ.get("STUB_LOG", "/tmp/stub-openai-last.json")
# 流式每一小片写多少**字节**，以及两片之间停多久（见文件头那张表底下那段）。
SLICE = int(os.environ.get("STREAM_SLICE", "23"))
SLICE_PAUSE = float(os.environ.get("STREAM_PAUSE", "0.03"))
# 一个 `data:` 帧里塞几个**字符**的正文（越小，界面上"一个个字往外冒"越明显）。
DELTA_CHARS = int(os.environ.get("STREAM_DELTA", "5"))

# 插件把文档嵌在系统消息里，两头是这两句（见 plugins/ai/main.lua 的 build_messages）。
开始 = "──── 当前文档全文开始 ────"
结束 = "──── 当前文档全文结束 ────"


def 取文档(请求: dict) -> str:
    """从请求的 messages 里把那份文档抠出来。取不到给空串。"""
    for m in 请求.get("messages") or []:
        c = m.get("content") or ""
        i = c.find(开始)
        j = c.find(结束)
        if i >= 0 and j > i:
            return c[i + len(开始):j].strip("\n")
    return ""


def 取行(文档: str):
    """文档里的非空行（就是"能被引用"的那些）。"""
    return [l for l in 文档.split("\n") if l.strip()]


def 造回答(文档: str):
    """按 MODE 造一段"模型回答"。返回 (正文, 围栏里的行列表)。"""
    行 = 取行(文档)
    头 = 行[0] if 行 else ""
    尾 = 行[-1] if 行 else ""

    if MODE == "nofence":
        return "我读了一遍，没什么要改的。", None

    if MODE == "insert":
        # ⚠️ 形状是**一处改动**（外层数组）里包着两行，不是"两处改动"。
        # 2026-09-24 这里写成 `["+ …", "+ …"]` 时，`拼回答` 的 `块 += h`
        # 会把字符串按**字符**摊开，桩于是回了一堆单字行——界面上表现为
        # "改动块里有 20 行既不 - 也不 +"。**那是桩写错了，不是解析器错了**
        # （反过来还顺带验了坏行是真会数出来）。
        return "我加了两句在末尾。", [["+ 这是桩加的第一句。", "+ 这是桩加的第二句。"]]

    if MODE == "twohunks":
        if not 头:
            return "文档是空的，我没法指出改哪儿。", None
        围栏 = [
            ["- " + 头, "+ [改] " + 头],
            ["- " + 尾, "+ [尾] " + 尾],
        ]
        return "我把第一句和最后一句各动了一下。", 围栏

    if MODE == "bad":
        if not 头:
            return "文档是空的。", None
        # 中间那一行**不带标记**，插件该把它数成"坏行"并如实说出来。
        return "我改了一句，顺便多打了一行。", [["- " + 头, "（这行是我手滑多打的）", "+ [改] " + 头]]

    if MODE == "dirty":
        # 引一行**文档里根本没有**的话：应用必须失败，而且**一个字都不许动**。
        return "我按记忆改了它。", [["- 这句文档里根本没有。", "+ 换成了这句。"]]

    # replace（默认）
    if not 头:
        return "文档是空的，我先加一句。", ["+ 桩加的第一句。"]
    return "我把第一句改短了。", [["- " + 头, "+ [改] " + 头]]


def 拼回答(正文: str, 围栏):
    """拼一段带改动块的回答。`围栏` 是**一串围栏**，每个围栏是一串行。

    ⚠️ 2026-09-26 修：这里原先把 `围栏` 拍平成一个围栏（`块 += h`），
    与文件头那张表写的「`twohunks` = 两个围栏」正好相反。后果是两份改动被
    解析成**一处**：`-` 的两行（第一段、第三段）在文档里并不连续，于是
    `nota.diff.apply` 如实报「第 1 处改动没找到能对上的原文」——界面上表现为
    「点『在编辑区看』什么都不发生」。**那是桩写错了，不是解析器或预览错了**
    （反过来还顺带验了"不连续的两行确实会被挡住"）。
    """
    if 围栏 is None:
        return 正文
    段 = [正文]
    for h in 围栏:
        段.append("```nota-diff\n" + "\n".join(h) + "\n```")
    return "\n\n".join(段)


def 切帧(回答: str, 模型: str):
    """把一段回答切成 SSE 的那些帧（字符串，**没有编码过**）。

    每帧的形状照 OpenAI 的流式协议抄：`data: {"choices":[{"delta":{"content":"…"}}]}`。
    ⚠️ 流式那边插件读的是 `choices[1].delta.content`，**不是**整段那条路的
    `choices[1].message.content`——桩这边两边都得给对，不然测出来的是桩的错。
    """
    帧 = []
    for i in range(0, len(回答), DELTA_CHARS):
        片 = 回答[i:i + DELTA_CHARS]
        体 = {
            "id": "stub-1",
            "object": "chat.completion.chunk",
            "model": 模型,
            "choices": [{"index": 0, "delta": {"content": 片}, "finish_reason": None}],
        }
        # ⚠️ 帧尾是**两个**换行（SSE 的规矩），最后一帧的 `[DONE]` 也是。
        帧.append("data: " + json.dumps(体, ensure_ascii=False) + "\n\n")
    # 收尾那两帧：一个空 delta＋finish_reason，一个 `[DONE]`。真服务也是这么发的。
    尾 = {
        "id": "stub-1",
        "object": "chat.completion.chunk",
        "model": 模型,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    帧.append("data: " + json.dumps(尾, ensure_ascii=False) + "\n\n")
    帧.append("data: [DONE]\n\n")
    return "".join(帧)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 静音默认的每请求一行
        pass

    def _send(self, code: int, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_stream(self, 整段: str):
        """按 SSE 一段一段写出去，**按字节**切（见文件头那段）。"""
        原始 = 整段.encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        # ⚠️ 分块传输，**不写 content-length**：长度这会儿还不知道（而且这正是
        # 流式的全部意义）。写了 content-length 的话 ureq 会等够那么多字节，
        # "边打边出"就退化成"一次到齐"——而那种退化在界面上的表现是
        # "这个功能好像没生效"，很难一眼看出是桩写错了。
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        for i in range(0, len(原始), SLICE):
            片 = 原始[i:i + SLICE]
            self.wfile.write(b"%x\r\n" % len(片) + 片 + b"\r\n")
            self.wfile.flush()
            time.sleep(SLICE_PAUSE)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self):
        self._send(200, json.dumps({"object": "stub", "mode": MODE}).encode())

    def do_POST(self):
        长度 = int(self.headers.get("content-length") or 0)
        原文 = self.rfile.read(长度).decode("utf-8", "replace")
        try:
            请求 = json.loads(原文)
        except Exception:
            请求 = {}
        with open(LOG, "w", encoding="utf-8") as f:
            json.dump(请求, f, ensure_ascii=False, indent=2)

        文档 = 取文档(请求)
        正文, 围栏 = 造回答(文档)
        回答 = 拼回答(正文, 围栏)
        模型 = 请求.get("model") or "stub"
        流式 = MODE == "stream"
        print(
            f"[stub-openai] {self.path} mode={MODE} 文档 {len(文档)} 字 → 回答 {len(回答)} 字"
            f"（围栏 {'有' if 围栏 is not None else '无'}；"
            f"请求里 stream={请求.get('stream')!r} → {'SSE' if 流式 else '整段'}）",
            flush=True,
        )
        if 流式:
            self._send_stream(切帧(回答, 模型))
            return
        # 形状照 OpenAI 抄（插件只读 choices[1].message.content，别的不看）。
        体 = {
            "id": "stub-1",
            "object": "chat.completion",
            "model": 模型,
            "choices": [
                {"index": 0, "message": {"role": "assistant", "content": 回答}, "finish_reason": "stop"}
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        self._send(200, json.dumps(体, ensure_ascii=False).encode("utf-8"))


if __name__ == "__main__":
    if MODE not in ("replace", "insert", "twohunks", "bad", "dirty", "nofence", "stream"):
        print(f"不认识的 STUB_MODE：{MODE}", file=sys.stderr)
        sys.exit(2)
    print(
        f"[stub-openai] 127.0.0.1:{PORT} mode={MODE} log={LOG}"
        + (f"（每片 {SLICE} 字节 / 每帧 {DELTA_CHARS} 字）" if MODE == "stream" else ""),
        flush=True,
    )
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
