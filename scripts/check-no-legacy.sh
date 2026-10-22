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
}

APP="desktop/native/gather-app"
CORE="desktop/native/gather-core"
NATIVE="desktop/native"

# ---------------------------------------------------------------- enforced
# 3b-6：Adapter 在拆 target 后是合法的端口实现命名（组合根 GatherHost 里的
# *Adapter.swift 把 Live API / 文件系统能力适配到 GatherUI 的端口协议）。
# 因此只允许它们出现在 GatherHost，其余位置仍按 legacy shim 处理。
enforced_rules=$((enforced_rules + 1))
banned=$(find "$NATIVE" -type f \( -name 'Legacy*.swift' -o -name '*Compat*.swift' -o -name '*Adapter*.swift' \) 2>/dev/null \
  | grep -vE '^desktop/native/gather-app/Sources/GatherHost/[^/]*Adapter\.swift$' || true)
if [[ -n "$banned" ]]; then
  echo "LEGACY[enforced] no Legacy*/Compat*/Adapter* source files (Adapter* 仅限 GatherHost 端口实现)" >&2
  echo "$banned" | sed 's/^/  - /' >&2
  fail=1
else
  echo "ok   [enforced] no Legacy*/Compat*/Adapter* source files (Adapter* 仅限 GatherHost 端口实现)"
fi

enforce "no WebKit/JS runtime"           'import (WebKit|JavaScriptCore)|WKWebView' "$NATIVE" "*.swift"
enforce "no Electron residue"            'electron|ipcRenderer|nodeIntegration'     "$NATIVE" "*.swift"
enforce "no app-level JSONSerialization" 'JSONSerialization'                        "$APP"    "*.swift"

# ---------------------------------------------------------------- tracked
tracked "awaitSync semaphore bridge (R5)"       'awaitSync'                        "$APP"    "*.swift"
# B8.4 收口：Router / 命令客户端已删除，改为 enforced 0 防回潮。
# 只看 app（GatherCore 不在本 cut 的修改范围）。
enforce "no SessionCommandRouter (R5)"          'SessionCommandRouter'             "$APP"    "*.swift"
enforce "no CommandRouter/WebResponse (R5)"     'CommandRouter|WebResponse'        "$APP"    "*.swift"
enforce "no NativeCommandClient (R5)"           'NativeCommandClient'              "$APP"    "*.swift"
tracked "Services layer (R2)"                   '.'                                "$CORE/Sources/GatherDomain/Services" "*.swift"

tracked "raw SQL outside Store (R1)"            'connection\.prepare\(|db\.prepare\(' "$CORE/Sources/GatherDomain/Services" "*.swift"
tracked "unchecked Sendable (R1/R2)"            '@unchecked Sendable'              "$NATIVE" "*.swift"
# R6：双轨文案的判据只看"英文侧死数据"（enDesc/labelEn/titleEn）。zhDesc 是
# 单轨实现里的正常键名（渲染走 l(zhLabel/zhDesc)），计入会把合法实现误报。
tracked "dual-track l10n enDesc/labelEn/titleEn (R6)" 'enDesc|labelEn|titleEn'      "$APP"    "*.swift"
tracked "batchAsync copies (R2)"                'func batchAsync'                  "$CORE"   "*.swift"

echo "----"
echo "enforced rules: $enforced_rules, tracked metrics: $tracked_rules"
if [[ "$fail" != "0" ]]; then
  echo "legacy boundary check FAILED" >&2
  exit 1
fi
echo "legacy boundary check OK"
