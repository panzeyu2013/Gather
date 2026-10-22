#!/usr/bin/env bash
# 分层门禁（refactor-design-breaking-2026-10-21 §2 / §7.3）。
#
# Cut 3 / 3b-6 布局后强制：
#   GatherUI        不得 import GatherPersistence / GatherDomain / GatherAnalysis /
#                   GatherHost（UI 只经 GatherProtocol + 自有端口协议取能力）
#   GatherHost      组合根：可 import 四层 core，但不得反向依赖 GatherApp；
#                   GatherUI 也不得 import 它（上一条已覆盖）
#   GatherApp       只有 @main/Scene，不得直接 import 四层 core（必须经 GatherHost）
#   core 四层 / GatherUI / GatherHost 不得 import GatherCore 伞（3b-6 已删除）
#   GatherAnalysis  不得 import GatherPersistence
#   GatherDomain    不得 import SwiftUI
#
# 当前仓库尚未拆分 target：输出 "not split yet" 并 exit 0（Cut 0 基线模式）。
# 用法：./scripts/check-layering.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE_SRC="desktop/native/gather-core/Sources"
APP_SRC="desktop/native/gather-app/Sources"
UI_DIR="$APP_SRC/GatherUI"
HOST_DIR="$APP_SRC/GatherHost"
ENTRY_DIR="$APP_SRC/GatherApp"
ANALYSIS_DIR="$CORE_SRC/GatherAnalysis"
DOMAIN_DIR="$CORE_SRC/GatherDomain"
PERSISTENCE_DIR="$CORE_SRC/GatherPersistence"

split=0
for d in "$UI_DIR" "$HOST_DIR" "$ENTRY_DIR" "$ANALYSIS_DIR" "$DOMAIN_DIR" "$PERSISTENCE_DIR"; do
  if [ -d "$d" ]; then split=1; fi
done

if [ "$split" -eq 0 ]; then
  echo "check-layering: not split yet — Sources 仍是 GatherCore/GatherApp 单 target（§9 Cut 3 拆分后启用）。"
  echo "check-layering: exit 0 (baseline mode)"
  exit 0
fi

fail=0

check_forbidden() {
  local dir="$1" label="$2"
  shift 2
  if [ ! -d "$dir" ]; then
    echo "skip   ${label}（目录不存在：${dir}）"
    return 0
  fi
  local files
  files=$(find "$dir" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
  local mod
  for mod in "$@"; do
    local hits
    hits=$(grep -rnE --include='*.swift' "^[[:space:]]*import[[:space:]]+$mod([[:space:]]|$)" "$dir" 2>/dev/null || true)
    if [ -n "$hits" ]; then
      echo "FAIL   ${label} 不得 import ${mod}："
      printf '%s\n' "$hits" | sed 's/^/  - /'
      fail=1
    else
      echo "ok     ${label}: 0 x import ${mod}（${files} 个 Swift 文件）"
    fi
  done
}

check_forbidden "$UI_DIR" "GatherUI" GatherPersistence GatherDomain GatherAnalysis GatherHost
check_forbidden "$ENTRY_DIR" "GatherApp" GatherProtocol GatherPersistence GatherAnalysis GatherDomain
check_forbidden "$HOST_DIR" "GatherHost" GatherApp
check_forbidden "$ANALYSIS_DIR" "GatherAnalysis" GatherPersistence
check_forbidden "$DOMAIN_DIR" "GatherDomain" SwiftUI

# 3b-6 已删除 GatherCore 伞：任何 target 再 import 它都视为回潮。
for d in "$UI_DIR" "$HOST_DIR" "$ENTRY_DIR" "$ANALYSIS_DIR" "$DOMAIN_DIR" "$PERSISTENCE_DIR"; do
  if [ -d "$d" ]; then
    check_forbidden "$d" "$(basename "$d")" GatherCore
  fi
done

echo "----"
if [ "$fail" -ne 0 ]; then
  echo "check-layering: FAILED" >&2
  exit 1
fi
echo "check-layering: OK"
