#!/usr/bin/env bash
# R0.3 legacy boundary scanner (Gather rewrite plan v2).
#
# Enforced rules must have ZERO matches and fail the build when violated.
# Tracked rules are printed as a progress metric; they become enforced when the
# owning rewrite workstream (R1..R6) deletes the old implementation.
set -eo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

fail=0
enforced_rules=0
tracked_rules=0

METRICS_FILE="$(mktemp)"
trap 'rm -f "$METRICS_FILE"' EXIT

# count_matches <ere-pattern> <path> <include-glob>
count_matches() {
  local pattern="$1" path="$2" include="$3"
  if [[ -d "$path" ]]; then
    grep -rE --include="$include" -l "$pattern" "$path" 2>/dev/null | wc -l | tr -d ' ' || true
  elif [[ -f "$path" ]]; then
    grep -Eq "$pattern" "$path" 2>/dev/null && echo 1 || echo 0
  else
    echo 0
  fi
}

# enforce <name> <pattern> <path> <include-glob>
enforce() {
  local name="$1" pattern="$2" path="$3" include="$4"
  enforced_rules=$((enforced_rules + 1))
  local n
  n=$(count_matches "$pattern" "$path" "$include")
  if [[ "$n" != "0" ]]; then
    echo "LEGACY[enforced] $name: $n file(s) still match in $path" >&2
    grep -rE --include="$include" -l "$pattern" "$path" 2>/dev/null | sed 's/^/  - /' >&2 || true
    fail=1
  else
    echo "ok   [enforced] $name"
  fi
}

# tracked <name> <pattern> <path> <include-glob>
tracked() {
  local name="$1" pattern="$2" path="$3" include="$4"
  tracked_rules=$((tracked_rules + 1))
  local n
  n=$(count_matches "$pattern" "$path" "$include")
  printf 'meter[tracked ] %-38s %s file(s)\n' "$name" "$n"
  printf '%s\t%s\n' "$name" "$n" >> "$METRICS_FILE"
}

APP="desktop/native/gather-app"
CORE="desktop/native/gather-core"
NATIVE="desktop/native"

# ---------------------------------------------------------------- enforced
enforced_rules=$((enforced_rules + 1))
banned=$(find "$NATIVE" -type f \( -name 'Legacy*.swift' -o -name '*Compat*.swift' -o -name '*Adapter*.swift' \) 2>/dev/null || true)
if [[ -n "$banned" ]]; then
  echo "LEGACY[enforced] no Legacy*/Compat*/Adapter* source files" >&2
  echo "$banned" | sed 's/^/  - /' >&2
  fail=1
else
  echo "ok   [enforced] no Legacy*/Compat*/Adapter* source files"
fi

enforce "no WebKit/JS runtime"           'import (WebKit|JavaScriptCore)|WKWebView' "$NATIVE" "*.swift"
enforce "no Electron residue"            'electron|ipcRenderer|nodeIntegration'     "$NATIVE" "*.swift"
enforce "no app-level JSONSerialization" 'JSONSerialization'                        "$APP"    "*.swift"

# ---------------------------------------------------------------- tracked
tracked "awaitSync semaphore bridge (R5)"       'awaitSync'                        "$APP"    "*.swift"
tracked "SessionCommandRouter (R5)"             'SessionCommandRouter'             "$NATIVE" "*.swift"
tracked "Services layer (R2)"                   '.'                                "$CORE/Sources/GatherCore/Services" "*.swift"
tracked "StubCommandRouter (R5)"                'StubCommandRouter'                "$APP"    "*.swift"
tracked "raw SQL outside Store (R1)"            'connection\.prepare\(|db\.prepare\(' "$CORE/Sources/GatherCore/Services" "*.swift"
tracked "unchecked Sendable (R1/R2)"            '@unchecked Sendable'              "$NATIVE" "*.swift"
tracked "dual-track l10n zhDesc/enDesc (R6)"    'zhDesc|enDesc'                    "$APP"    "*.swift"
tracked "batchAsync copies (R2)"                'func batchAsync'                  "$CORE"   "*.swift"
tracked "Runtime layer SQL statements (R2)"   'SELECT |INSERT INTO |UPDATE .* SET|DELETE FROM '  "$CORE/Sources/GatherCore/Runtime" "*.swift"
tracked "legacy DB layer files (R1)"            '.'  "$CORE/Sources/GatherCore/Database" "*.swift"
tracked "legacy Repositories files (R1)"        '.'  "$CORE/Sources/GatherCore/Database/Repositories" "*.swift"
tracked "legacy Repo test files (R1)"           '.'  "$CORE/Tests/GatherCoreTests/Database" "*.swift"
# 剩余旧 Repo 的调用文件数（R1 收尾排序用：越小越先切）。
tracked "legacy SessionRepo callers (R1)"       'sessionRepo\.'        "$CORE/Sources"   "*.swift"
tracked "legacy AnalysisJobRepo callers (R1)"   'AnalysisJobRepo'       "$CORE/Sources"   "*.swift"
tracked "legacy MetadataOutboxRepo callers"     'outboxRepo\.'         "$CORE/Sources"   "*.swift"
tracked "legacy PhotoRepo callers (R1)"         'photoRepo\.'          "$CORE/Sources"   "*.swift"
tracked "legacy AssetRepo callers (R1)"         'assetRepo\.'          "$CORE/Sources"   "*.swift"

# ---------------------------------------------------------------- ratchet
# 旧层文件数只允许下降：baseline 是上限；上升即失败，下降时提示更新 baseline。
BASELINE="scripts/legacy-baseline.txt"
if [[ -f "$BASELINE" ]]; then
  while IFS=$'\t' read -r name count; do
    [[ -z "$name" ]] && continue
    limit=$(awk -F'=' -v key="$name" '$1 == key { print $2 }' "$BASELINE")
    [[ -z "$limit" ]] && continue
    if (( count > limit )); then
      echo "LEGACY[ratchet] $name: $count > baseline $limit（旧层文件数不允许增长）" >&2
      fail=1
    elif (( count < limit )); then
      echo "note [ratchet] $name: $count < baseline $limit（旧层已收缩，请同步 scripts/legacy-baseline.txt）"
    fi
  done < "$METRICS_FILE"
else
  echo "note [ratchet] 未找到 $BASELINE，仅打印度量"
fi

echo "----"
echo "enforced rules: $enforced_rules, tracked metrics: $tracked_rules"
if [[ "$fail" != "0" ]]; then
  echo "legacy boundary check FAILED" >&2
  exit 1
fi
echo "legacy boundary check OK"
