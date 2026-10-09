#!/usr/bin/env python3
"""假 Slidev：给 `NOTA_SLIDEV_CMD` 用的替身。

**这是工装，不是产品代码。** 真 Slidev 第一次要下几百 MB，而"起进程 → 轮询端口
→ 开窗口 → 同步正文 → 收摊"这条链跟幻灯片怎么渲染没关系。这个替身收下同样的
参数、绑同样的地址（⚠️ **`[::1]`，IPv6**——真 Slidev 只绑这一套栈，见
`docs/07` §4），把入口文件**现读现端**出去，于是"同步有没有写进去"用一句
`curl` 就看得见。用法见 `docs/06` §5.7。

它故意不做的事：不改 markdown、不热更新、不认主题。那些都是真 Slidev 的活。
"""

import pathlib
import socket
import sys
import threading

args = sys.argv[1:]
port = 0
entry = None
i = 0
while i < len(args):
    if args[i] == "--port" and i + 1 < len(args):
        port = int(args[i + 1])
        i += 2
        continue
    if args[i] == "--no-open":
        i += 1
        continue
    entry = args[i]  # 最后一个位置参数就是入口文件
    i += 1

print(f"[stub] 端口={port} 入口={entry}", flush=True)

srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("::1", port))
srv.listen(8)
print(f"[stub] 听着 [::1]:{port}", flush=True)


def handle(conn: socket.socket) -> None:
    try:
        conn.recv(4096)
    except OSError:
        pass
    try:
        # ⚠️ **每次请求都重读**：这样"改一下正文再 curl"就能看出同步生效了，
        # 不用重启替身。
        text = pathlib.Path(entry).read_text(encoding="utf-8") if entry else "(没给入口)"
    except OSError as e:
        text = f"(读不到入口：{e})"
    body = f"<html><body><pre>{text}</pre></body></html>".encode()
    head = (
        b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)
    )
    try:
        conn.sendall(head + body)
    except OSError:
        pass
    conn.close()


while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
