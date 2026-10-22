#!/usr/bin/env bash
# desktop/native/gather-app 的 Preview 表面门禁（Cut 4 / 4c-1）。
#
# 作用：
#   1. 统计 Sources 下的 #Preview 宏数量（只算行首宏，不算注释/文档）；
#   2. 少于 12 个直接失败（审计 §6.3 的交付底线）；
#   3. --strict 追加：达到目标 14 个、每个 #Preview 都在 #if DEBUG 内、
#      PreviewSupport/ 下每个文件整体被 #if DEBUG ... #endif 包裹、
#      且预览替身不得 import XCTest/Testing/@testable（不能依赖测试 target）。
#
# 用法：./scripts/check-preview-surface.sh [--strict]
#
# 退出码：0 = 通过；1 = 门禁失败；2 = 参数错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/desktop/native/gather-app/Sources"
PREVIEW_DIR="$SOURCES/GatherUI/PreviewSupport"

# 底线来自 docs/cut4-ui-audit.md §6.3（≥12）；4c-1 实际交付 14 个，
# --strict 把"建议目标"变成硬门槛，防止后续拆分悄悄丢失预览。
MIN_PREVIEWS=12
STRICT_MIN_PREVIEWS=14
STRICT=0

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -d "$SOURCES" ]; then
  echo "FAIL: 找不到 Sources 目录：$SOURCES" >&2
  exit 1
fi

# .build 是历史遗留的 SwiftPM 产物目录（Sources/.build），必须排除，
# 否则会把编译产物里的二进制/生成文件误算成预览。
preview_files() {
  find "$SOURCES" -type d -name .build -prune -o -type f -name '*.swift' -print0 \
    | xargs -0 grep -lE '^[[:space:]]*#Preview([ (]|$)' 2>/dev/null \
    | sort \
    || true
}

preview_occurrences() {
  find "$SOURCES" -type d -name .build -prune -o -type f -name '*.swift' -print0 \
    | xargs -0 grep -hE '^[[:space:]]*#Preview([ (]|$)' 2>/dev/null \
    || true
}

count="$(preview_occurrences | wc -l | tr -d ' ')"
files="$(preview_files)"

echo "Preview surface"
echo "  Sources: $SOURCES"
if [ -n "$files" ]; then
  while IFS= read -r file; do
    n="$(grep -cE '^[[:space:]]*#Preview([ (]|$)' "$file" || true)"
    printf "  %3d  %s\n" "$n" "$file"
  done <<< "$files"
fi
echo "  total: $count (min $MIN_PREVIEWS, strict min $STRICT_MIN_PREVIEWS)"

fail=0

if [ "$count" -lt "$MIN_PREVIEWS" ]; then
  echo "FAIL: #Preview 只有 $count 个，少于底线 $MIN_PREVIEWS 个。" >&2
  fail=1
fi

# PreviewSupport 是 Cut 4 / 4c-1 的 fixture 目录：至少要有固定数据 + API 替身。
support_files=0
support_lines=0
if [ -d "$PREVIEW_DIR" ]; then
  support_files="$(find "$PREVIEW_DIR" -type f -name '*.swift' | wc -l | tr -d ' ')"
  if [ "$support_files" -gt 0 ]; then
    support_lines="$(find "$PREVIEW_DIR" -type f -name '*.swift' -print0 | xargs -0 wc -l | tail -1 | awk '{print $1}')"
  fi
fi

if [ "$STRICT" -eq 1 ]; then
  # 1) 目标 14 个。
  if [ "$count" -lt "$STRICT_MIN_PREVIEWS" ]; then
    echo "FAIL(strict): #Preview 只有 $count 个，目标为 $STRICT_MIN_PREVIEWS 个。" >&2
    fail=1
  fi

  # 2) 每个 #Preview 都必须位于 #if DEBUG 内（release 不打包预览）。
  debug_bad="$(
    if [ -n "$files" ]; then
      while IFS= read -r file; do
        awk '
          /^[[:space:]]*#if[[:space:]]+DEBUG([[:space:]]|$)/ { depth++; next }
          /^[[:space:]]*#endif([[:space:]]|$)/ { if (depth > 0) depth--; next }
          /^[[:space:]]*#Preview([ (]|$)/ {
            if (depth == 0) print FILENAME ":" FNR
          }
        ' "$file"
      done <<< "$files"
    fi
  )"
  if [ -n "$debug_bad" ]; then
    echo "FAIL(strict): 以下 #Preview 不在 #if DEBUG 内：" >&2
    echo "$debug_bad" | sed 's/^/  /' >&2
    fail=1
  fi

  # 3) PreviewSupport 下每个文件整体 #if DEBUG ... #endif。
  # 4) 预览替身不得依赖测试 target。
  if [ ! -d "$PREVIEW_DIR" ]; then
    echo "FAIL(strict): 缺少目录 $PREVIEW_DIR" >&2
    fail=1
  else
    for file in "$PREVIEW_DIR"/*.swift; do
      [ -e "$file" ] || continue
      first="$(awk 'NF && $0 !~ /^[[:space:]]*\/\// { print; exit }' "$file")"
      last="$(awk 'NF { last = $0 } END { print last }' "$file")"
      if [ "$first" != "#if DEBUG" ] || [ "$last" != "#endif" ]; then
        echo "FAIL(strict): $file 未整体包裹在 #if DEBUG ... #endif 内。" >&2
        fail=1
      fi
    done

    if grep -RInE --include='*.swift' \
        '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(XCTest|Testing|GatherAppTests)' \
        "$PREVIEW_DIR" >/dev/null 2>&1; then
      echo "FAIL(strict): PreviewSupport 不得 import 测试模块（XCTest/Testing/GatherAppTests）。" >&2
      fail=1
    fi

    for required in PreviewFixtures.swift PreviewAPIs.swift PreviewProviders.swift; do
      if [ ! -f "$PREVIEW_DIR/$required" ]; then
        echo "FAIL(strict): 缺少 fixture 文件 $required" >&2
        fail=1
      fi
    done
  fi
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: #Preview=$count, PreviewSupport files=$support_files, lines=$support_lines"
