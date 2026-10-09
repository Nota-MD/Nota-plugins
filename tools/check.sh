#!/usr/bin/env bash
# 本仓库自己的闸（2026-10-09 建的：插件搬出主仓库之后，主仓库那份
# `tools/doc-sync-check.sh` 就扫不到这里了——**闸不能跟着文件一起搬丢**）。
#
# 两件事：
#   ① 行数：任何 .lua / .py / .toml 不得 >= 1000 行，> 800 报 WARN
#      （尺子与主仓库 `docs/09` §4 同一把：目标 300–800）
#   ② 两份无头测试：写作统计的状态机、AI 的流式那条路
#
# 跑法（在仓库根，⚠️ 这台机器的 lua 在容器里）：
#   bash tools/check.sh
#
# 退出码：0 = 全过；1 = 有 FAIL。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD

if [ -t 1 ]; then R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[1m'; N=$'\e[0m'
else R=''; Y=''; G=''; B=''; N=''; fi
FAILS=0; WARNS=0
fail() { printf '%sFAIL%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS + 1)); }
warn() { printf '%sWARN%s %s\n' "$Y" "$N" "$1"; WARNS=$((WARNS + 1)); }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$1"; }
head_() { printf '\n%s── %s%s\n' "$B" "$1" "$N"; }

head_ "① 行数（硬线 1000，> 800 报 WARN）"
OVER=0
while IFS= read -r f; do
  n=$(wc -l <"$f")
  if [ "$n" -ge 1000 ]; then
    fail "$f 有 $n 行，超上限了 —— 按职责拆"
    OVER=$((OVER + 1))
  elif [ "$n" -gt 800 ]; then
    warn "$f 有 $n 行，过了 800（目标 300–800），按功能拆"
  fi
done < <(find plugins tools -type f \( -name '*.lua' -o -name '*.py' -o -name '*.toml' \) | sort)
[ "$OVER" -eq 0 ] && ok "没有超限的文件"

head_ "② 两份无头测试"
# ⚠️ 两份都**必须在仓库根跑**（它们按脚本自己的位置算路径）。
if command -v podman >/dev/null 2>&1; then
  for t in stats-state-test ai-stream-test; do
    if out=$(podman exec -u 1000 -w "$ROOT" tauri-dev lua "tools/$t.lua" 2>&1); then
      # ⚠️ 两份的收尾行**不是同一句**（一份 `ALL PASS（N 条断言）`、一份 `全部通过`）
      ok "$t：$(printf '%s' "$out" | grep -E 'ALL PASS|全部通过' | tail -1)"
    else
      fail "$t 没过："
      printf '%s\n' "$out" | tail -12
    fi
  done
else
  warn "没装 podman —— 这一台机器上 lua 在容器里，② 这一栏跳过"
fi

printf '\n%s── 汇总%s\n' "$B" "$N"
if [ "$FAILS" -eq 0 ]; then
  printf '0 项 FAIL、%s 项 WARN\n' "$WARNS"
  exit 0
fi
printf '%s 项 FAIL、%s 项 WARN\n' "$FAILS" "$WARNS"
exit 1
