#!/usr/bin/env python3
"""把一个插件目录打成 `.nota-plugin`（zip）并（可选）签名。

这是**作者那一侧**的工具。宿主只**解**包、只**验**签，从不打包、更不会签名
（私钥永远不该出现在装了 Nota 的机器上，见 `docs/11` §1.6）。

格式的**真相源**在 `src-tauri/src/plugin/package.rs`（读的一侧）与 `docs/11` §1.6
（写的一侧的形状）。这个脚本是第三种实现，所以摘要算法在这里是**照抄**的，
不是"大意相同"——两处差一个字节，症状就是"包看起来好好的、装的时候说签名对不上"。

用法::

    # 1. 造一把签名钥匙（只做一次）。⚠️ 私钥要自己保管好，别提交进仓库。
    python3 tools/pack-plugin.py --new-key ~/nota-签名钥匙.pem

    # 2. 打包 + 签名（输出 plugins/git/… 同级的 git-0.1.0.nota-plugin）
    python3 tools/pack-plugin.py plugins/git --key ~/nota-签名钥匙.pem

    # 3. 不签名也打得出来（开发时互相传着试，装的时候会显示「未签名」）
    python3 tools/pack-plugin.py plugins/git

    # 4. 只想看看别人给的包是谁签的、内容改过没有
    python3 tools/pack-plugin.py --verify 别人给的.nota-plugin

依赖：`openssl`（签名与验签都靠它；`ed25519` 是 OpenSSL 3 的内置算法）。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# ── 与宿主那侧对齐的常量 ──────────────────────────────────────────────────
# ⚠️ 这几个名字**两处实现必须一字不差**：读的一侧在
# `src-tauri/src/plugin/package.rs`（`清单文件` / `签名文件` / `包后缀`）。
清单文件 = "plugin.toml"
签名文件 = "nota-signature.toml"
包后缀 = ".nota-plugin"

# 上限（与 `package.rs` 里那三条一致）。宿主先全解到内存里再验签，
# 所以这几条是防 zip 炸弹的：一个 4 KiB 的包能解出几个 GB。
总上限 = 32 * 1024 * 1024
单文件上限 = 16 * 1024 * 1024
条目上限 = 2048
名字上限 = 512

# 打进包里**不带**的东西：点开头的（.git / .DS_Store）、编辑器缓存、以及签名文件
# 自己（它是"附加在包上的"，不是载荷的一部分——见 docs/11 §1.6）。
跳过目录名 = {"__pycache__", "node_modules"}


def 摘要(文件们: list[tuple[str, bytes]]) -> bytes:
    """载荷摘要：条目按路径排序，每条算 `路径字节 + \\0 + 内容 sha256`，再 sha256 一次。

    ⚠️ 排序用的是**字节序**（`sorted()` 对 `str` 比的是码点，对纯 ASCII 路径
    与 Rust 的 `str::cmp` 一致；这里统一按 UTF-8 字节排，两边行为才完全一样）。
    """
    h = hashlib.sha256()
    for 路径, 内容 in sorted(文件们, key=lambda x: x[0].encode("utf-8")):
        h.update(路径.encode("utf-8"))
        h.update(b"\0")
        h.update(hashlib.sha256(内容).digest())
    return h.digest()


def 收目录(root: Path) -> list[tuple[str, bytes]]:
    """把一个插件目录收成 `[(相对路径, 内容)]`。路径一律用 `/` 分隔。"""
    出: list[tuple[str, bytes]] = []
    总 = 0
    for 路 in sorted(root.rglob("*")):
        if 路.is_symlink() or not 路.is_file():
            continue  # ⚠️ 符号链接整条跳过：跟着走就是一次无限递归（与宿主同一条判据）
        相对 = 路.relative_to(root)
        if any(段.startswith(".") or 段 in 跳过目录名 for 段 in 相对.parts):
            continue
        名 = "/".join(相对.parts)
        if 名 == 签名文件:
            continue
        if len(名.encode("utf-8")) > 名字上限:
            sys.exit(f"✗ 路径太长（{名字上限} 字节上限）：{名}")
        内容 = 路.read_bytes()
        if len(内容) > 单文件上限:
            sys.exit(f"✗ `{名}` 超过 {单文件上限} 字节")
        总 += len(内容)
        if 总 > 总上限:
            sys.exit(f"✗ 插件目录总共超过 {总上限} 字节")
        出.append((名, 内容))
    if len(出) > 条目上限:
        sys.exit(f"✗ 文件太多（上限 {条目上限} 条）")
    return 出


def 跑(cmd: list[str], **kw) -> bytes:
    """跑一条命令，返回标准输出；失败就把它的报错原样带出来。"""
    try:
        p = subprocess.run(cmd, capture_output=True, check=False, **kw)
    except FileNotFoundError:
        sys.exit(f"✗ 找不到 `{cmd[0]}`——签名和验签都要它（装上 openssl 再来）")
    if p.returncode != 0:
        sys.exit(f"✗ `{' '.join(cmd)}` 失败：\n{p.stderr.decode('utf-8', 'replace')}")
    return p.stdout


# 把 32 字节原始公钥包成 PEM 用的 SPKI 前缀（Ed25519 的固定头，RFC 8410）。
# 就是 `302a300506032b6570032100` + 公钥那 32 字节。
SPKI前缀 = bytes.fromhex("302a300506032b6570032100")


def 公钥原文(钥匙: Path) -> bytes:
    """从私钥里取出 32 字节原始公钥（PEM 里那一长串 DER 的最后 32 字节）。"""
    der = 跑(["openssl", "pkey", "-in", str(钥匙), "-pubout", "-outform", "DER"])
    if len(der) < 32:
        sys.exit("✗ 从私钥里读公钥失败了（这真的是把 ed25519 私钥吗？）")
    return der[-32:]


def 公钥pem(原始: bytes) -> str:
    """把 32 字节原始公钥拼成 PEM。验签那一侧只拿得到这个（没有私钥）。"""
    b64 = base64.b64encode(SPKI前缀 + 原始).decode("ascii")
    行 = [b64[i : i + 64] for i in range(0, len(b64), 64)]
    return "-----BEGIN PUBLIC KEY-----\n" + "\n".join(行) + "\n-----END PUBLIC KEY-----\n"


def 指纹(原始: bytes) -> str:
    """`sha256(公钥)[:8]` 的十六进制——与 `installed.rs::公钥指纹` 同一条算法。

    ⚠️ 它是**算出来的**，不是随便起的一个 id：宿主验签时会拿包里的公钥重算一遍
    再对比，对不上就拒（否则改一个 key_id 就能冒充别人已信任的那把钥匙）。
    """
    return hashlib.sha256(原始).digest()[:8].hex()


def 签名块(钥匙: Path, 载荷摘要: bytes, 临时: Path) -> str:
    """用 openssl 签这份摘要，拼出 `nota-signature.toml` 的正文。"""
    摘要文件 = 临时 / "载荷摘要"
    签名文件出 = 临时 / "签名"
    摘要文件.write_bytes(载荷摘要)
    跑(
        [
            "openssl",
            "pkeyutl",
            "-sign",
            "-rawin",
            "-inkey",
            str(钥匙),
            "-in",
            str(摘要文件),
            "-out",
            str(签名文件出),
        ]
    )
    签名 = 签名文件出.read_bytes()
    if len(签名) != 64:
        sys.exit(f"✗ 签名应该是 64 字节，实际 {len(签名)} 字节")
    原件 = 公钥原文(钥匙)
    from datetime import date

    return (
        "[signature]\n"
        'algorithm = "ed25519"\n'
        f'key_id = "{指纹(原件)}"\n'
        f'public_key = "{base64.b64encode(原件).decode("ascii")}"\n'
        f'signature = "{base64.b64encode(签名).decode("ascii")}"\n'
        f'signed_at = "{date.today().isoformat()}"\n'
    )


def 干活_打包(args: argparse.Namespace) -> int:
    源 = Path(args.目录).resolve()
    if not (源 / 清单文件).is_file():
        sys.exit(f"✗ {源} 里没有 {清单文件}——不是一个插件目录")

    文件们 = 收目录(源)
    if not 文件们:
        sys.exit("✗ 这个目录里没有可打包的文件")

    # 清单里的 id / version 决定输出文件名。**只读、不改**：打得出来的包
    # 与目录里的清单必须一致，不然"我打的包怎么装不上"就是从这里来的。
    id_, 版本 = "", ""
    for 行 in (源 / 清单文件).read_text(encoding="utf-8").splitlines():
        行 = 行.strip()
        if 行.startswith("id") and not id_:
            id_ = 行.split("=", 1)[-1].strip().strip('"')
        if 行.startswith("version") and not 版本:
            版本 = 行.split("=", 1)[-1].strip().strip('"')

    出 = Path(args.out) if args.out else 源.parent / f"{id_ or 源.name}-{版本 or '0'}{包后缀}"
    出.parent.mkdir(parents=True, exist_ok=True)

    摘要值 = 摘要(文件们)
    print(f"· {len(文件们)} 个文件，载荷摘要 {摘要值.hex()[:16]}…")

    with zipfile.ZipFile(出, "w", zipfile.ZIP_DEFLATED) as z:
        for 名, 内容 in sorted(文件们, key=lambda x: x[0].encode("utf-8")):
            z.writestr(名, 内容)
        if args.key:
            with tempfile.TemporaryDirectory() as 临时目录:
                块 = 签名块(Path(args.key), 摘要值, Path(临时目录))
            # ⚠️ 顺序无关（宿主按路径排序后算摘要，且签名文件不参与摘要），
            # 放在最后只是"一眼能看出它是附加的"。
            z.writestr(签名文件, 块)
            print(f"· 已签名（指纹 {块.split('key_id =')[1].split(chr(34))[1]}）")
        else:
            print("· 没有签名——装它的那一侧会如实显示「未签名」")

    print(f"✓ 打好了：{出}（{出.stat().st_size} 字节）")
    return 0


def 干活_验证(args: argparse.Namespace) -> int:
    包 = Path(args.verify)
    with zipfile.ZipFile(包) as z:
        名字 = z.namelist()
        if 签名文件 not in 名字:
            # ⚠️ 这不是失败：开发态的包本来就可以不签（宿主照样装，只是标"未签名"）。
            print("· 这个包没有签名（未签名 ≠ 坏的）")
            return 0
        载荷 = [(n, z.read(n)) for n in 名字 if n != 签名文件]
        块 = z.read(签名文件).decode("utf-8")

    取 = {}
    for 行 in 块.splitlines():
        行 = 行.strip()
        if "=" in 行 and not 行.startswith("["):
            k, v = 行.split("=", 1)
            取[k.strip()] = v.strip().strip('"')

    原始 = base64.b64decode(取["public_key"])
    签名值 = base64.b64decode(取["signature"])
    if 指纹(原始) != 取["key_id"]:
        print(f"✗ key_id 与公钥对不上：文件里写 {取['key_id']}，算出来 {指纹(原始)}")
        return 1

    with tempfile.TemporaryDirectory() as 临时目录:
        临时 = Path(临时目录)
        (临时 / "公钥.pem").write_text(公钥pem(原始))
        (临时 / "摘要").write_bytes(摘要(载荷))
        (临时 / "签名").write_bytes(签名值)
        p = subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-verify",
                "-rawin",
                "-pubin",
                "-inkey",
                str(临时 / "公钥.pem"),
                "-in",
                str(临时 / "摘要"),
                "-sigfile",
                str(临时 / "签名"),
            ],
            capture_output=True,
        )
        if p.returncode != 0:
            print("✗ 签名对不上——这个包在签完之后被改过（或者签名块是坏的）")
            print(p.stderr.decode("utf-8", "replace").strip())
            return 1

    print(f"✓ 签名有效（指纹 {取['key_id']}，签于 {取.get('signed_at', '没写')}）")
    print("· 它只说明「这份载荷是持有那把私钥的人签的」，不说明「是谁」——")
    print("  宿主那边还要看这把钥匙在不在信任库里（不在就显示「未知签名者」）。")
    return 0


def 干活_造钥匙(args: argparse.Namespace) -> int:
    路 = Path(args.new_key).expanduser()
    if 路.exists():
        sys.exit(f"✗ {路} 已经存在了——不覆盖（覆盖等于把上一个插件的签名能力弄丢）")
    路.parent.mkdir(parents=True, exist_ok=True)
    跑(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(路)])
    os.chmod(路, 0o600)  # ⚠️ 只自己可读：这是私钥
    print(f"✓ 造好了：{路}")
    print("· ⚠️ 别把它提交进仓库、别放进插件包里。丢了就再也签不出同一个身份。")
    print("· 公钥（给用户核对的指纹）要等打包时算，或者自己跑：")
    print(f"    openssl pkey -in {路} -pubout -outform DER | tail -c 32 | sha256sum | cut -c1-16")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(
        description="打包（可选签名）一个 Nota 插件目录，或验证一个已有的包",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("用法::")[-1],
    )
    p.add_argument("目录", nargs="?", help="要打包的插件目录（里面有 plugin.toml）")
    p.add_argument("--key", help="签名用的 ed25519 私钥（PEM）。不给就不签名")
    p.add_argument("--new-key", metavar="路径", help="造一把新的签名私钥，然后退出")
    p.add_argument("-o", "--out", help="输出的包路径。默认：<id>-<版本>.nota-plugin")
    p.add_argument("--verify", metavar="包", help="验证一个已有的包（改了没有、谁签的）")
    args = p.parse_args()

    if args.new_key:
        return 干活_造钥匙(args)
    if args.verify:
        return 干活_验证(args)
    if args.目录:
        return 干活_打包(args)
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
