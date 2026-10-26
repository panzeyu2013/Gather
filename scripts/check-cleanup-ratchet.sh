#!/usr/bin/env bash
# 清理 ratchet 门禁（refactor-design-breaking-2026-10-21 §8.6）。
#
# 指标（均为“非纯注释行”的匹配行数；整行以 // 或 * 开头不计）：
#   unchecked_sendable  Sources/**/*.swift 中 @unchecked Sendable
#   try_optional        Sources/**/*.swift 中 try?
#   services_prepare    gather-core/Sources/GatherApplication/Services 中 prepare(
#   todo_fixme          Sources + Tests 中 TODO / FIXME
#   with_known_issue    Tests 中 withKnownIssue(
#
# baseline: docs/cleanup-baseline.json
#   - 超过 baseline：FAIL（exit 1）
#   - 低于 baseline：提示收紧 baseline，不失败
#   - baseline 缺失/缺 key：FAIL（防止门禁静默失效）
# 用法：
#   ./scripts/check-cleanup-ratchet.sh
#   ./scripts/check-cleanup-ratchet.sh --write-baseline
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE_SRC="desktop/native/gather-core/Sources"
APP_SRC="desktop/native/gather-app/Sources"
# 3b-6：GatherUI / GatherHost 已全部迁入 Sources，app 侧功能页不再有
# gather-app/<Feature>/ 旧目录；ratchet 覆盖 Sources 即可。
SERVICES="$CORE_SRC/GatherApplication/Services"
CORE_TESTS="desktop/native/gather-core/Tests"
APP_TESTS="desktop/native/gather-app/Tests"
BASELINE="docs/cleanup-baseline.json"
METRICS="unchecked_sendable try_optional services_prepare todo_fixme with_known_issue"

for d in "$CORE_SRC" "$APP_SRC" "$SERVICES" "$CORE_TESTS" "$APP_TESTS"; do
  if [ ! -d "$d" ]; then
    echo "check-cleanup-ratchet: FAIL 缺少扫描根：$d" >&2
    exit 1
  fi
done
SWIFT_N=$(find "$CORE_SRC" "$APP_SRC" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
if [ "$SWIFT_N" -lt 300 ]; then
  echo "check-cleanup-ratchet: FAIL Sources 只扫到 ${SWIFT_N} 个 Swift 文件（<300）" >&2
  exit 1
fi

WRITE=0
for arg in "$@"; do
  case "$arg" in
    --write-baseline) WRITE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "check-cleanup-ratchet: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

# count_matches <ERE> <path...>
# 只统计非纯注释行；同一行多次匹配按 1 计。
count_matches() {
  local re="$1"
  shift
  local total=0 f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(grep -E "$re" "$f" 2>/dev/null | grep -vE '^[[:space:]]*(//|\*)' | wc -l | tr -d ' ')
    total=$((total + n))
  done < <(find "$@" -type f -name '*.swift' -not -path '*/.build/*' 2>/dev/null | sort)
  echo "$total"
}

metric() {
  case "$1" in
    unchecked_sendable) count_matches '@unchecked Sendable' "$CORE_SRC" "$APP_SRC" ;;
    try_optional)       count_matches 'try\?' "$CORE_SRC" "$APP_SRC" ;;
    services_prepare)   count_matches 'prepare\(' "$SERVICES" ;;
    todo_fixme)         count_matches 'TODO|FIXME' "$CORE_SRC" "$APP_SRC" "$CORE_TESTS" "$APP_TESTS" ;;
    with_known_issue)   count_matches 'withKnownIssue' "$CORE_TESTS" "$APP_TESTS" ;;
    *) echo "0" ;;
  esac
}

write_baseline() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  mkdir -p "$(dirname "$BASELINE")"
  cat > "$BASELINE" <<JSON
{
  "schema": 1,
  "generated_at": "$ts",
  "generated_by": "scripts/check-cleanup-ratchet.sh --write-baseline",
  "counting": "matching non-comment lines (lines whose first non-space chars are // or * are ignored)",
  "metrics": {
    "unchecked_sendable": $(metric unchecked_sendable),
    "try_optional": $(metric try_optional),
    "services_prepare": $(metric services_prepare),
    "todo_fixme": $(metric todo_fixme),
    "with_known_issue": $(metric with_known_issue)
  },
  "scopes": {
    "unchecked_sendable": "desktop/native/*/Sources/**/*.swift",
    "try_optional": "desktop/native/*/Sources/**/*.swift",
    "services_prepare": "desktop/native/gather-core/Sources/GatherApplication/Services/**/*.swift",
    "todo_fixme": "desktop/native/*/Sources + desktop/native/*/Tests",
    "with_known_issue": "desktop/native/*/Tests/**/*.swift"
  }
}
JSON
}

if [ "$WRITE" -eq 1 ]; then
  write_baseline
  echo "check-cleanup-ratchet: baseline 已写入 $BASELINE"
  for key in $METRICS; do
    printf '  %-22s %s\n' "$key" "$(metric "$key")"
  done
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "check-cleanup-ratchet: FAIL — 缺少 $BASELINE" >&2
  echo "  先运行：./scripts/check-cleanup-ratchet.sh --write-baseline" >&2
  exit 1
fi

baseline_value() {
  local key="$1" line val
  line=$(grep -E "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$BASELINE" 2>/dev/null | head -n 1 || true)
  val=$(printf '%s' "$line" | grep -oE '[0-9]+' | head -n 1 || true)
  printf '%s' "$val"
}

fail=0
printf '%-22s %8s %8s  %s\n' "metric" "current" "baseline" "status"
for key in $METRICS; do
  cur=$(metric "$key")
  base=$(baseline_value "$key")
  if [ -z "$base" ]; then
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "?" "FAIL (baseline 缺 key)"
    fail=1
    continue
  fi
  if [ "$cur" -gt "$base" ]; then
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "$base" "FAIL (+$((cur - base)))"
    fail=1
  elif [ "$cur" -lt "$base" ]; then
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "$base" "ok (improved $((base - cur)); 可收紧 baseline)"
  else
    printf '%-22s %8s %8s  %s\n' "$key" "$cur" "$base" "ok"
  fi
done

echo "----"
if [ "$fail" -ne 0 ]; then
  echo "check-cleanup-ratchet: FAILED — 清理指标不得高于 baseline" >&2
  exit 1
fi
echo "check-cleanup-ratchet: OK（全部指标不超过 baseline）"
