#!/usr/bin/env bash
# R0.3 legacy boundary scanner (Gather rewrite plan v2).
#
# Enforced rules fail the build when violated: zero-tolerance rules must have
# ZERO matches; threshold-ratchet rules must not exceed their recorded target.
# Tracked rules are printed as a progress metric; they become enforced when the
# owning rewrite workstream (R1..R6) deletes the old implementation.
#
# ------------------------------------------- R8 gate hardening (acc-gate H1..H9)
# H1 每条规则的作用路径必须存在：路径改名/消失立即 FAIL，不再静默计 0（assert_scan_path）。
#    已整树删除的旧层目录改为「同名目录不得再现」断言，锚点仍须存在（enforce_absent_tree）。
# H2 baseline 文件缺失、某 tracked 度量缺 key、或 baseline 存在无对应度量的孤儿 key：FAIL。
# H3 grep/find 失败（坏正则、IO 错误）与 0 命中不再混淆：stderr 非空或退出码超界即 FAIL。
# H5 tracked 度量同时输出「文件数 + 出现次数」，两个口径都写入 baseline 棘轮。
# H6 Runtime SQL 规则大小写不敏感；raw SQL 规则纳入 db 的 execute 入口；Electron 规则大小写
#    不敏感（仅按代码行判定，行注释中的历史设计引用不算残留，见 enforce_no_electron）。
# H7 扫描目录不可读/不可进入即 FAIL。
# H8 产物相关 CI job 声明 needs: boundary（见 .github/workflows/ci.yml）。
#
# 已知限制（本轮未实现，不得当成已覆盖）：
# H4 元防护：脚本 / baseline / CI 工作流自身被改写（删规则、抬阈值、删 job）没有独立校验，
#    需 CODEOWNERS、分支保护、对脚本与 baseline 的哈希锁定等仓库外机制。
# H9 漂移窗口：grep/find 扫描与棘轮判定之间、CI checkout 与本脚本运行之间没有快照或锁，
#    存在 TOCTOU 漂移窗口；需固定 commit 或只读快照才能闭合。
# 另有：扫描含 .build 构建缓存（与加固前行为一致），缓存内容变化可能影响计数；本轮未排除。
set -eo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

fail=0
enforced_rules=0
tracked_rules=0

METRICS_FILE="$(mktemp)"
GREP_ERR="$(mktemp)"
trap 'rm -f "$METRICS_FILE" "$GREP_ERR"' EXIT

# ---------------------------------------------------------------- scan plumbing
# assert_scan_path <rule-name> <path>：H1/H7 —— 作用路径必须存在、可读、目录可进入。
assert_scan_path() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    echo "LEGACY[gate] $name: 扫描路径不存在：$path（H1：路径改名/消失即 FAIL）" >&2
    fail=1
    return 1
  fi
  if [[ ! -r "$path" ]]; then
    echo "LEGACY[gate] $name: 扫描路径不可读：$path（H7）" >&2
    fail=1
    return 1
  fi
  if [[ -d "$path" && ! -x "$path" ]]; then
    echo "LEGACY[gate] $name: 扫描目录不可进入：$path（H7）" >&2
    fail=1
    return 1
  fi
  return 0
}

# check_tool_errors <tool> <rule-name> <path> <status> <max-ok-status>：H3/H7。
check_tool_errors() {
  local tool="$1" name="$2" path="$3" status="$4" max_ok="$5"
  local bad=0
  if (( status > max_ok )); then
    echo "LEGACY[gate] $name: $tool 退出码 $status（> $max_ok），扫描 $path 未完成（H3）" >&2
    bad=1
  fi
  if [[ -s "$GREP_ERR" ]]; then
    echo "LEGACY[gate] $name: $tool 扫描 $path 时写入 stderr（H3/H7）：" >&2
    sed 's/^/  ! /' "$GREP_ERR" >&2 || true
    bad=1
  fi
  if (( bad != 0 )); then
    fail=1
  fi
  return 0
}

# scan <rule-name> <pattern> <path> <include-glob> [grep-flags]
# 结果写入全局：SCAN_FILES / SCAN_OCC / SCAN_LIST（换行分隔的命中文件列表）。
# grep 退出码 1（无命中）正常；>1（坏正则/IO 错误）或 stderr 非空一律 FAIL。
scan() {
  local name="$1" pattern="$2" path="$3" include="$4" flags="$5"
  SCAN_FILES=0
  SCAN_OCC=0
  SCAN_LIST=""
  if ! assert_scan_path "$name" "$path"; then
    return 1
  fi
  local status=0 raw
  if [[ -d "$path" ]]; then
    : > "$GREP_ERR"
    raw=$(grep -rE $flags --include="$include" -l -e "$pattern" "$path" 2>"$GREP_ERR") || status=$?
    check_tool_errors "grep" "$name" "$path" "$status" 1
    if [[ -n "$raw" ]]; then
      SCAN_LIST="$raw"
      SCAN_FILES=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
    fi
    status=0
    : > "$GREP_ERR"
    raw=$(grep -rEo $flags --include="$include" -e "$pattern" "$path" 2>"$GREP_ERR") || status=$?
    check_tool_errors "grep" "$name" "$path" "$status" 1
    if [[ -n "$raw" ]]; then
      SCAN_OCC=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
    fi
  elif [[ -f "$path" ]]; then
    : > "$GREP_ERR"
    raw=$(grep -E $flags -e "$pattern" "$path" 2>"$GREP_ERR") || status=$?
    check_tool_errors "grep" "$name" "$path" "$status" 1
    if [[ -n "$raw" ]]; then
      SCAN_FILES=1
      SCAN_LIST="$path"
    fi
    status=0
    : > "$GREP_ERR"
    raw=$(grep -Eo $flags -e "$pattern" "$path" 2>"$GREP_ERR") || status=$?
    check_tool_errors "grep" "$name" "$path" "$status" 1
    if [[ -n "$raw" ]]; then
      SCAN_OCC=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
    fi
  fi
  return 0
}

# ---------------------------------------------------------------- rule helpers
# enforce <name> <pattern> <path> <include-glob> [grep-flags]
enforce() {
  local name="$1" pattern="$2" path="$3" include="$4" flags="$5"
  enforced_rules=$((enforced_rules + 1))
  if ! scan "$name" "$pattern" "$path" "$include" "$flags"; then
    return 0
  fi
  if [[ "$SCAN_FILES" != "0" ]]; then
    echo "LEGACY[enforced] $name: $SCAN_FILES file(s) still match in $path" >&2
    printf '%s\n' "$SCAN_LIST" | sed 's/^/  - /' >&2 || true
    fail=1
  else
    echo "ok   [enforced] $name"
  fi
  return 0
}

# enforce_max <name> <pattern> <path> <include-glob> <max-files> [grep-flags]
# 度量已达目标值：文件数超过 max 即 FAIL（棘轮，不允许回退）。
enforce_max() {
  local name="$1" pattern="$2" path="$3" include="$4" limit="$5" flags="$6"
  enforced_rules=$((enforced_rules + 1))
  if ! scan "$name" "$pattern" "$path" "$include" "$flags"; then
    return 0
  fi
  if (( SCAN_FILES > limit )); then
    echo "LEGACY[enforced] $name: $SCAN_FILES file(s) > threshold $limit in $path" >&2
    printf '%s\n' "$SCAN_LIST" | sed 's/^/  - /' >&2 || true
    fail=1
  else
    echo "ok   [enforced] $name ($SCAN_FILES <= $limit)"
  fi
  return 0
}

# enforce_max_occ <name> <pattern> <path> <include-glob> <max-occurrences> [grep-flags]
# 出现次数粒度的棘轮：弥补「命中文件数」粒度无法阻止文件内继续增长的空隙。
enforce_max_occ() {
  local name="$1" pattern="$2" path="$3" include="$4" limit="$5" flags="$6"
  enforced_rules=$((enforced_rules + 1))
  if ! scan "$name" "$pattern" "$path" "$include" "$flags"; then
    return 0
  fi
  if (( SCAN_OCC > limit )); then
    echo "LEGACY[enforced] $name: $SCAN_OCC occurrence(s) > threshold $limit in $path" >&2
    fail=1
  else
    echo "ok   [enforced] $name ($SCAN_OCC <= $limit)"
  fi
  return 0
}

# tracked <name> <pattern> <path> <include-glob> [grep-flags]
# H5：同时给出文件数与出现次数，两个口径都交给 baseline 棘轮。
tracked() {
  local name="$1" pattern="$2" path="$3" include="$4" flags="$5"
  tracked_rules=$((tracked_rules + 1))
  if ! scan "$name" "$pattern" "$path" "$include" "$flags"; then
    printf 'meter[tracked ] %-38s SCAN-PATH-MISSING\n' "$name"
    return 0
  fi
  printf 'meter[tracked ] %-38s %s file(s) / %s occurrence(s)\n' "$name" "$SCAN_FILES" "$SCAN_OCC"
  printf '%s\t%s\n' "$name" "$SCAN_FILES" >> "$METRICS_FILE"
  printf '%s [occurrences]\t%s\n' "$name" "$SCAN_OCC" >> "$METRICS_FILE"
  return 0
}

# enforce_no_electron <name> <path> <include-glob>
# H6：大小写不敏感；但仓库现存两处「对齐 Electron ...」的行注释是历史设计说明而非运行时残留，
# 故先剥掉行注释再判定。已知限制：块注释中的 token 仍会被判为残留；仅注释中的 token 不计。
enforce_no_electron() {
  local name="$1" path="$2" include="$3"
  enforced_rules=$((enforced_rules + 1))
  if ! assert_scan_path "$name" "$path"; then
    return 0
  fi
  local status=0 cand
  : > "$GREP_ERR"
  cand=$(grep -rIiE --include="$include" -l -e 'electron|ipcRenderer|nodeIntegration' "$path" 2>"$GREP_ERR") || status=$?
  check_tool_errors "grep" "$name" "$path" "$status" 1
  local hits="" f code
  if [[ -n "$cand" ]]; then
    : > "$GREP_ERR"
    while IFS= read -r f; do
      code=$(sed 's|//.*||' "$f" 2>>"$GREP_ERR" || true)
      if grep -qiE -e 'electron|ipcRenderer|nodeIntegration' <<< "$code"; then
        hits+="$f"$'\n'
      fi
    done <<< "$cand"
    check_tool_errors "sed" "$name" "$path" 0 0
  fi
  if [[ -n "$hits" ]]; then
    echo "LEGACY[enforced] $name: Electron 残留出现在代码行" >&2
    printf '%s' "$hits" | sed 's/^/  - /' >&2 || true
    fail=1
  else
    echo "ok   [enforced] $name (case-insensitive; 行注释引用除外)"
  fi
  return 0
}

# enforce_absent_tree <name> <anchor-dir> <tree-name>
# H1 的删除态变体：旧层目录（R1 已整树删除）不得以同名目录再次出现；
# 锚点目录必须存在，避免把锚点一并挪走造成静默放行。
enforce_absent_tree() {
  local name="$1" anchor="$2" tree="$3"
  enforced_rules=$((enforced_rules + 1))
  if ! assert_scan_path "$name" "$anchor"; then
    return 0
  fi
  local status=0 found
  : > "$GREP_ERR"
  found=$(find "$anchor" -type d -name "$tree" 2>"$GREP_ERR") || status=$?
  check_tool_errors "find" "$name" "$anchor" "$status" 0
  if [[ -n "$found" ]]; then
    echo "LEGACY[enforced] $name: 旧层目录再次出现：$tree" >&2
    printf '%s\n' "$found" | sed 's/^/  - /' >&2 || true
    fail=1
  else
    echo "ok   [enforced] $name (旧层目录不存在)"
  fi
  return 0
}

APP="desktop/native/gather-app"
CORE="desktop/native/gather-core"
NATIVE="desktop/native"

# ---------------------------------------------------------------- enforced
enforced_rules=$((enforced_rules + 1))
BANNED_NAME="no Legacy*/Compat*/Adapter* source files"
if assert_scan_path "$BANNED_NAME" "$NATIVE"; then
  : > "$GREP_ERR"
  fstatus=0
  banned=$(find "$NATIVE" -type f \( -name 'Legacy*.swift' -o -name '*Compat*.swift' -o -name '*Adapter*.swift' \) 2>"$GREP_ERR") || fstatus=$?
  check_tool_errors "find" "$BANNED_NAME" "$NATIVE" "$fstatus" 0
  if [[ -n "$banned" ]]; then
    echo "LEGACY[enforced] $BANNED_NAME" >&2
    printf '%s\n' "$banned" | sed 's/^/  - /' >&2 || true
    fail=1
  else
    echo "ok   [enforced] $BANNED_NAME"
  fi
fi

enforce "no WebKit/JS runtime"           'import (WebKit|JavaScriptCore)|WKWebView' "$NATIVE" "*.swift"
enforce_no_electron "no Electron residue" "$NATIVE" "*.swift"
enforce "no app-level JSONSerialization" 'JSONSerialization'                        "$APP"    "*.swift"

# --------------------------------------- enforced: threshold ratchet (R8 gate)
# 度量已达目标值：超过阈值即 FAIL（不得回退的棘轮）。
# 收敛后请同步下调此处阈值与 scripts/legacy-baseline.txt。
enforce_max "Runtime layer SQL statements (R2)" 'SELECT |INSERT INTO |UPDATE .* SET|DELETE FROM '  "$CORE/Sources/GatherCore/Runtime" "*.swift" 0 "-i"
# R7：Services 层已完全清退（0 文件），原「Services 内不得有裸 SQL」度量随层退役；
# 以 H1 删除态断言承接（旧层同名目录再现即 FAIL），enforced 计数不变。
enforce_absent_tree "legacy Services dir must stay absent (R2)" "$CORE/Sources/GatherCore" "Services"
enforce_max "unchecked Sendable (R1/R2)"      '@unchecked Sendable'                "$CORE/Sources" "*.swift" 5
enforce_max "batchAsync copies (R2)"          'func batchAsync'                    "$CORE"   "*.swift" 3

# —— 出现次数粒度棘轮（R8 加固：审计指出的「文件数」粒度空隙）——
enforce_max_occ "awaitSync occurrences (R5)" 'awaitSync' "$APP" "*.swift" 16

# —— 路径无关的符号级棘轮（R8 加固：闭合审计限制②"真空通过"）——
tracked "legacy DBConnection symbols (R1) [待处理]" 'DBConnection' "$CORE/Sources" "*.swift"
tracked "legacy Repositories path refs (R1) [待处理]" 'Database/Repositories' "$CORE/Sources" "*.swift"
tracked "legacy module bridge symbols (R5) [待处理]" 'NativeCommandClient' "$APP/Sources" "*.swift"
enforce_max_occ "@unchecked Sendable occurrences (R1/R2)" '@unchecked Sendable' "$CORE/Sources" "*.swift" 5
enforce_max_occ "batchAsync occurrences (R2)" 'func batchAsync' "$CORE" "*.swift" 3

# ---------------------------------------------------------------- tracked
tracked "awaitSync semaphore bridge (R5)"       'awaitSync'                        "$APP"    "*.swift"
tracked "SessionCommandRouter (R5)"             'SessionCommandRouter'             "$APP"    "*.swift"
# R7：Services 层已完全清退（0 文件），"Services layer (R2)" 度量退役（baseline 两个 key 同步删除）。
tracked "StubCommandRouter (R5)"                'StubCommandRouter'                "$APP"    "*.swift"
tracked "dual-track l10n zhDesc/enDesc (R6)"    'zhDesc|enDesc'                    "$APP"    "*.swift"
# H1 删除态：旧层目录已整树删除，不允许同名目录再现（锚点存在性由函数内断言保证）。
enforce_absent_tree "legacy DB layer dir must stay absent (R1)"     "$CORE/Sources/GatherCore" "Database"
enforce_absent_tree "legacy Repositories dir must stay absent (R1)" "$CORE/Sources/GatherCore" "Repositories"
enforce_max "legacy Repo test files (R1)"           '.'  "$CORE/Tests/GatherCoreTests/Database" "*.swift" 0
# 剩余旧 Repo 的调用文件数（R1 收尾排序用：越小越先切）。
enforce_max "legacy SessionRepo callers (R1)"       'sessionRepo\.'        "$CORE/Sources"   "*.swift" 0
enforce_max "legacy MetadataOutboxRepo callers"     'outboxRepo\.'         "$CORE/Sources"   "*.swift" 0
enforce_max "legacy PhotoRepo callers (R1)"         'photoRepo\.'          "$CORE/Sources"   "*.swift" 0
enforce_max "legacy AssetRepo callers (R1)"         'assetRepo\.'          "$CORE/Sources"   "*.swift" 0

# ---------------------------------------------------------------- ratchet
# 剩余 tracked 度量只允许下降：baseline 是上限；上升即失败，下降时提示更新 baseline。
# H2：baseline 缺失 / 度量缺 key / baseline 有孤儿 key 均 FAIL（棘轮不得静默消失）。
BASELINE="scripts/legacy-baseline.txt"
if [[ ! -f "$BASELINE" ]]; then
  echo "LEGACY[ratchet] baseline 文件缺失：$BASELINE（H2：棘轮不得静默消失）" >&2
  fail=1
else
  while IFS=$'\t' read -r name count; do
    [[ -z "$name" ]] && continue
    limit=$(awk -F'=' -v key="$name" '$1 == key { print $2 }' "$BASELINE")
    if [[ -z "$limit" ]]; then
      echo "LEGACY[ratchet] $name: baseline 缺少对应 key（H2：棘轮不得静默消失）" >&2
      fail=1
      continue
    fi
    if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
      echo "LEGACY[ratchet] $name: baseline 值非法：$limit" >&2
      fail=1
      continue
    fi
    if (( count > limit )); then
      echo "LEGACY[ratchet] $name: $count > baseline $limit（旧层不允许增长）" >&2
      fail=1
    elif (( count < limit )); then
      echo "note [ratchet] $name: $count < baseline $limit（旧层已收缩，请同步 scripts/legacy-baseline.txt）"
    fi
  done < "$METRICS_FILE"

  # 反向一一对应：baseline 的孤儿 key 说明度量被删/改名，不允许静默移除棘轮。
  while IFS='=' read -r key _; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    if ! grep -qxF -- "$key" <(cut -f1 "$METRICS_FILE"); then
      echo "LEGACY[ratchet] baseline 孤儿 key（无对应度量）：$key（H2）" >&2
      fail=1
    fi
  done < "$BASELINE"
fi

echo "----"
echo "enforced rules: $enforced_rules, tracked metrics: $tracked_rules"
if [[ "$fail" != "0" ]]; then
  echo "legacy boundary check FAILED" >&2
  exit 1
fi
echo "legacy boundary check OK"