#!/usr/bin/env bash
# 重复符号门禁（refactor-design-breaking-2026-10-21 §8.6 / CL-12）。
#
# 规则：
#   1. func batchAsync 最多保留 1 份（多份 = 复制粘贴，FAIL）。
#   2. LockedBox / ResponseBox 的声明必须位于 Tests/Support/ 或 Tests/<Target>/Support/（CL-12 收口；
#      越界即 warning，--strict 时 FAIL）。
#
# 历史：旧规则 3（RequestGate 同名定义 ≤1 份）已于 2026-10-22 随 CL-04 删除该类型后移除；
#      该符号零生产调用点，不再作为任何门禁证据。
#
# 当前以 warning 模式 exit 0；--strict 时存在违规即 exit 1。
# 用法：./scripts/check-duplicate-symbols.sh [--strict]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "check-duplicate-symbols: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

find "$ROOT/desktop/native" -path '*/.build' -prune -o -type f -name '*.swift' -print | sort > "$TMP/files"

scan() {
  local re="$1" f rel
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$ROOT"/}"
    grep -nE "$re" "$f" 2>/dev/null | sed "s|^|$rel:|" || true
  done < "$TMP/files"
}

count_nonempty() {
  local s="$1"
  if [ -z "$s" ]; then echo 0; return; fi
  printf '%s\n' "$s" | grep -c . || true
}

fail=0
file_count=$(wc -l < "$TMP/files" | tr -d ' ')

batch_hits=$(scan 'func[[:space:]]+batchAsync([^A-Za-z0-9_]|$)')
batch_n=$(count_nonempty "$batch_hits")

helper_hits=$(scan '(class|struct|actor|enum)[[:space:]]+(LockedBox|ResponseBox)([^A-Za-z0-9_]|$)')
outside_hits=$(printf '%s\n' "$helper_hits" | grep -vE '/Tests/([^/]+/)?Support/' | grep -v '^$' || true)
outside_n=$(count_nonempty "$outside_hits")

echo "check-duplicate-symbols:"
echo "  扫描 Swift 文件     $file_count"
echo "  func batchAsync     $batch_n"
echo "  LockedBox/ResponseBox 在 Tests/Support 之外  $outside_n"

if [ "$batch_n" -gt 1 ]; then
  echo "FAIL batchAsync 存在 $batch_n 份副本："
  printf '%s\n' "$batch_hits" | sed 's/^/  - /'
  fail=1
elif [ "$batch_n" -eq 1 ]; then
  echo "ok   batchAsync 仅 1 份（旧实现，允许保留到对应 Cut）："
  printf '%s\n' "$batch_hits" | sed 's/^/  - /'
else
  echo "ok   batchAsync 已无副本"
fi

if [ "$outside_n" -gt 0 ]; then
  echo "WARN 以下测试锁盒声明不在 Tests/Support/（CL-12 应收进一份）："
  printf '%s\n' "$outside_hits" | sed 's/^/  - /'
else
  echo "ok   LockedBox/ResponseBox 均位于 Tests/Support/ 或不存在"
fi

echo "----"
if [ "$STRICT" -eq 1 ]; then
  if [ "$fail" -ne 0 ] || [ "$outside_n" -gt 0 ]; then
    echo "check-duplicate-symbols: FAILED (--strict)" >&2
    exit 1
  fi
  echo "check-duplicate-symbols: OK (--strict)"
else
  if [ "$fail" -ne 0 ]; then
    echo "check-duplicate-symbols: WARN (warning mode; 使用 --strict 作为硬门禁)"
  else
    echo "check-duplicate-symbols: PASS (warning mode; 使用 --strict 作为硬门禁)"
  fi
fi
