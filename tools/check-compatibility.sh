#!/usr/bin/env bash
# 插件兼容契约：版本必须一致，API 必须同主版本且插件次版本不高于宿主。
set -euo pipefail
cd "$(dirname "$0")/.."

api=$(grep -o '"api"[[:space:]]*:[[:space:]]*"[^"]*"' compatibility.json | sed 's/.*"\([^"]*\)"$/\1/')
[[ "$api" =~ ^v([0-9]+)\.([0-9]+)$ ]] || {
  echo "FAIL compatibility.json host api=$api (expected vMAJOR.MINOR)" >&2
  exit 1
}
host_major="${BASH_REMATCH[1]}"
host_minor="${BASH_REMATCH[2]}"

for dir in plugins/*; do
  [ -f "$dir/plugin.toml" ] || continue
  file="$dir/plugin.toml"
  id=$(sed -n 's/^id[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' "$file" | head -1)
  ver=$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' "$file" | head -1)
  got_api=$(sed -n 's/^api[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' "$file" | head -1)
  table=$(grep -o "\"$id\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" compatibility.json | grep -o '"[^"]*"$' | tr -d '"' || true)
  [ -n "$table" ] || { echo "FAIL compatibility.json 缺少 $id" >&2; exit 1; }
  [ "$ver" = "$table" ] || { echo "FAIL $id manifest=$ver compatibility=$table" >&2; exit 1; }
  [[ "$got_api" =~ ^v([0-9]+)\.([0-9]+)$ ]] || {
    echo "FAIL $id api=$got_api (expected vMAJOR.MINOR)" >&2
    exit 1
  }
  plugin_major="${BASH_REMATCH[1]}"
  plugin_minor="${BASH_REMATCH[2]}"
  if [ "$plugin_major" -ne "$host_major" ] || [ "$plugin_minor" -gt "$host_minor" ]; then
    echo "FAIL $id api=$got_api is incompatible with host $api" >&2
    exit 1
  fi
done

echo "OK 官方插件兼容表：host api=$api，所有插件版本一致"
