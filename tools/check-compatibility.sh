#!/usr/bin/env bash
# 插件兼容契约：兼容表里的版本与每份 plugin.toml 必须一致，API 必须同为 2。
set -euo pipefail
cd "$(dirname "$0")/.."

api=$(grep -o '"api"[[:space:]]*:[[:space:]]*[0-9]*' compatibility.json | grep -o '[0-9]*$')
[ "$api" = "2" ] || { echo "FAIL compatibility.json host api=$api" >&2; exit 1; }

for dir in plugins/*; do
  [ -f "$dir/plugin.toml" ] || continue
  file="$dir/plugin.toml"
  id=$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' "$file" | head -1)
  ver=$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' "$file" | head -1)
  got_api=$(sed -n 's/^api[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)/\1/p' "$file" | head -1)
  table=$(grep -o "\"$id\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" compatibility.json | grep -o '"[^"]*"$' | tr -d '"' || true)
  [ -n "$table" ] || { echo "FAIL compatibility.json 缺少 $id" >&2; exit 1; }
  [ "$ver" = "$table" ] || { echo "FAIL $id manifest=$ver compatibility=$table" >&2; exit 1; }
  [ "$got_api" = "$api" ] || { echo "FAIL $id api=$got_api 期望 $api" >&2; exit 1; }
done

echo "OK 官方插件兼容表：host api=$api，四个插件版本一致"
