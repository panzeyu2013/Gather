#!/usr/bin/env bash
# 清理 ratchet 门禁（refactor-design-breaking-2026-10-21 §8.6）。
#
# 指标（均为“非纯注释行”的匹配行数；整行以 // 或 * 开头不计）：
#   unchecked_sendable  Sources/**/*.swift 中 @unchecked Sendable
#   try_optional        Sources/**/*.swift 中 try?
#   try_bang            Sources/**/*.swift 中 try!（零容忍：新代码不得引入）
#   as_bang             Sources/**/*.swift 中 as!（零容忍：用 guard/as? 或 CFTypeID + unsafeDowncast）
#   fatal_error         Sources/**/*.swift 中 fatalError（零容忍：错误走 throws，不崩进程）
#   nonisolated_unsafe  Sources/**/*.swift 中 nonisolated(unsafe)（并发约定禁止新增）
#   services_prepare    gather-core/Sources/GatherApplication/Services 中 prepare(
#   todo_fixme          Sources + Tests 中 TODO / FIXME
#   with_known_issue    Tests 中 withKnownIssue(
#
# baseline: docs/baselines/cleanup-baseline.json
#   - 超过 baseline：FAIL（exit 1）
#   - 低于 baseline：提示收紧 baseline，不失败
#   - baseline 缺失/缺 key：FAIL（防止门禁静默失效）
#   - --write-baseline 输出 schema=2，不写 generated_at（重复写无 diff，便于收紧基线）
#
# --self-test：负样本自测（mktemp fixture，不写仓库）。把本脚本原样复制进临时 fixture
# 仓库，用同一份判定逻辑断言「超 baseline → FAIL；等于/低于 → PASS；缺 baseline/缺 key → FAIL」。
# 用法：
#   ./scripts/check-cleanup-ratchet.sh
#   ./scripts/check-cleanup-ratchet.sh --write-baseline
#   ./scripts/check-cleanup-ratchet.sh --self-test
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
BASELINE="docs/baselines/cleanup-baseline.json"
METRICS="unchecked_sendable try_optional try_bang as_bang fatal_error nonisolated_unsafe services_prepare todo_fixme with_known_issue"

# ---------------------------------------------------------------------------
# --self-test：负样本自测（mktemp fixture，不写仓库；fixture 不达预期即 exit 1）
#   做法：把本脚本原样复制进临时 fixture 仓库，用同一份判定逻辑跑合成树，断言：
#     1) try_optional / unchecked_sendable 超 baseline → FAIL（exit 1）
#     2) 等于 / 低于 baseline → PASS（exit 0；低于只提示收紧）
#     3) 缺 baseline 文件 / baseline 缺 key → FAIL（exit 1，防止门禁静默失效）
# ---------------------------------------------------------------------------
SELFTEST_OUT=""
SELFTEST_TMP=""
SELFTEST_PROG="check-cleanup-ratchet"
SELFTEST_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

selftest_die() {
  echo "$SELFTEST_PROG: self-test FAIL — $1" >&2
  exit 1
}

# selftest_expect <期望退出码> <说明> <fixture 脚本> [参数...]
selftest_expect() {
  local want="$1" desc="$2" script="$3"
  shift 3
  local st=0
  SELFTEST_OUT=$(bash "$script" "$@" 2>&1) || st=$?
  if [ "$st" -ne "$want" ]; then
    echo "$SELFTEST_PROG: self-test FAIL — $desc（期望 exit ${want}，实得 ${st}）" >&2
    printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /' >&2
    exit 1
  fi
}

# selftest_contains <期望子串> <说明>
selftest_contains() {
  case "$SELFTEST_OUT" in
    *"$1"*) return 0 ;;
  esac
  echo "$SELFTEST_PROG: self-test FAIL — $2（输出里没有「$1」）" >&2
  printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /' >&2
  exit 1
}

# selftest_filler <目录> <个数>：生成不匹配任何指标的占位 Swift 文件（满足扫描量下限）
selftest_filler() {
  local dir="$1" n="$2" i=0
  mkdir -p "$dir"
  while [ "$i" -lt "$n" ]; do
    printf '// self-test 占位（不参与任何指标）\nlet filler_%s = 0\n' "$i" > "$dir/F$i.swift"
    i=$((i + 1))
  done
}

# selftest_baseline <文件> [key=value ...]：按 metrics 列表生成 fixture 基线（默认 0）
selftest_baseline() {
  local file="$1" key val pair sep=""
  shift
  {
    printf '{\n  "schema": 2,\n  "counting": "self-test fixture",\n  "metrics": {'
    for key in $METRICS; do
      val=0
      for pair in "$@"; do
        case "$pair" in
          "$key="*) val="${pair#*=}" ;;
        esac
      done
      printf '%s\n    "%s": %s' "$sep" "$key" "$val"
      sep=","
    done
    printf '\n  }\n}\n'
  } > "$file"
}

selftest_cleanup() {
  if [ -n "$SELFTEST_TMP" ]; then
    rm -rf "${SELFTEST_TMP:?}"
  fi
}

self_test() {
  local tmpbase="${TMPDIR:-/tmp}" fx gate base
  tmpbase="${tmpbase%/}"
  SELFTEST_TMP=$(mktemp -d "${tmpbase}/check-cleanup-ratchet-selftest.XXXXXX") ||
    selftest_die "mktemp 创建临时目录失败"
  trap selftest_cleanup EXIT
  fx="$SELFTEST_TMP/fixture"
  gate="$fx/scripts/$SELFTEST_PROG.sh"
  base="$fx/docs/baselines/cleanup-baseline.json"

  # fixture 仓库：判定所需的扫描根 + 足够多 Swift 文件（门禁有 <300 的扫描量下限）。
  mkdir -p "$fx/scripts" \
    "$fx/desktop/native/gather-core/Sources/GatherApplication/Services" \
    "$fx/desktop/native/gather-core/Tests" \
    "$fx/desktop/native/gather-app/Sources" \
    "$fx/desktop/native/gather-app/Tests" \
    "$fx/docs/baselines"
  cp "$SELFTEST_SELF" "$gate"
  selftest_filler "$fx/desktop/native/gather-core/Sources/Filler" 300
  cat > "$fx/desktop/native/gather-app/Sources/SelftestFixtures.swift" <<'SWIFT'
// self-test fixture：整行注释里的 try? / @unchecked Sendable 不计入口径
// let commented = try? nothing()
struct SelftestBad {
    func read() -> Int? {
        let a = try? readInt()
        let b = try? readInt()
        return a ?? b
    }
}

struct SelftestSendable: @unchecked Sendable {
    let value = 0
}

struct SelftestSendableGap: @unchecked /* 块注释间隔 */ Sendable {
    let value = 1
}
SWIFT

  # 断言 1：等于 baseline → PASS（同时证明整行注释不计、块注释间隔仍计数）。
  selftest_baseline "$base" try_optional=2 unchecked_sendable=2
  selftest_expect 0 "等于 baseline 应 PASS" "$gate"
  selftest_contains "check-cleanup-ratchet: OK" "等于 baseline 应输出 OK"

  # 断言 2：try_optional 超 baseline → FAIL（等于 2 已由断言 1 钉住，此处可精确到 2）。
  selftest_baseline "$base" try_optional=1 unchecked_sendable=2
  selftest_expect 1 "try_optional 超 baseline 应 FAIL" "$gate"
  selftest_contains "try_optional" "FAIL 行应点名 try_optional"

  # 断言 3：unchecked_sendable 超 baseline → FAIL。
  selftest_baseline "$base" try_optional=2 unchecked_sendable=1
  selftest_expect 1 "unchecked_sendable 超 baseline 应 FAIL" "$gate"
  selftest_contains "unchecked_sendable" "FAIL 行应点名 unchecked_sendable"

  # 断言 4：低于 baseline → PASS（只提示可收紧，不失败）。
  selftest_baseline "$base" try_optional=5 unchecked_sendable=2
  selftest_expect 0 "低于 baseline 应 PASS" "$gate"
  selftest_contains "improved" "低于 baseline 应提示 improved"

  # 断言 5：缺 baseline 文件 → FAIL。
  rm -f "$base"
  selftest_expect 1 "缺 baseline 应 FAIL" "$gate"
  selftest_contains "缺少" "缺 baseline 的报错应点名缺少"

  # 断言 6：baseline 缺 key → FAIL（防止门禁静默跳过该指标）。
  selftest_baseline "$base" try_optional=2 unchecked_sendable=2
  grep -v '"try_optional"' "$base" > "$SELFTEST_TMP/broken.json"
  mv "$SELFTEST_TMP/broken.json" "$base"
  selftest_expect 1 "baseline 缺 key 应 FAIL" "$gate"
  selftest_contains "缺 key" "缺 key 的报错应点名缺 key"

  # 断言 7：--write-baseline（持平/收紧）可写，输出 schema=2 且不写 generated_at（重复写无 diff）。
  selftest_baseline "$base" try_optional=2 unchecked_sendable=2
  selftest_expect 0 "持平/收紧时 --write-baseline 应可写" "$gate" --write-baseline
  selftest_contains "baseline 已写入" "写盘应提示 baseline 已写入"
  if ! grep -q '"schema": 2' "$base"; then
    selftest_die "--write-baseline 输出缺少 schema=2"
  fi
  if grep -q 'generated_at' "$base"; then
    selftest_die "--write-baseline 输出仍写 generated_at（会造成每次重钉 diff）"
  fi
  if ! grep -q '"try_optional": 2' "$base"; then
    selftest_die "--write-baseline 输出未写入实测值（try_optional=2）"
  fi

  echo "$SELFTEST_PROG: self-test OK（超基线 2 项 FAIL / 等于与低于 PASS / 缺 baseline 与缺 key FAIL / 写盘 schema=2 且无 generated_at；7 条断言）"
  return 0
}

# --self-test 必须在扫描根守卫与真实扫描前 short-circuit：fixture 不满足 300 文件下限，
# 且自测不写仓库、不读真实基线。
SELFTEST=0
for arg in "$@"; do
  if [ "$arg" = "--self-test" ]; then
    SELFTEST=1
  fi
done
if [ "$SELFTEST" -eq 1 ]; then
  if [ "$#" -ne 1 ]; then
    echo "check-cleanup-ratchet: --self-test 只接受单独使用（不与其他参数混跑）" >&2
    exit 2
  fi
  self_test
  exit 0
fi


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
ALLOW_GROWTH=0
for arg in "$@"; do
  case "$arg" in
    --write-baseline) WRITE=1 ;;
    --allow-growth) ALLOW_GROWTH=1 ;;
    -h|--help)
      sed -n '2,26p' "$0"
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

# count_unchecked_sendable：跨行/注释间隔的 @unchecked Sendable 也要计数（评审 R3T-07）。
# 逐文件剥掉纯注释行后做多行正则；与 count_matches 的“非纯注释行”口径一致。
count_unchecked_sendable() {
  python3 - "$@" <<'PY'
import pathlib
import re
import sys

total = 0
for root in sys.argv[1:]:
    for p in pathlib.Path(root).rglob('*.swift'):
        if '/.build/' in str(p):
            continue
        try:
            text = p.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)  # 块注释间隔也归一
        lines = [l for l in text.splitlines() if not l.lstrip().startswith(('//', '*'))]
        total += len(re.findall(r'@unchecked\s+Sendable', '\n'.join(lines)))
print(total)
PY
}

metric() {
  case "$1" in
    # 评审 R2T-09 / R3T-07：多行、块注释间隔、双空格、Tab 都计数（纯行注释不计）。
    unchecked_sendable) count_unchecked_sendable "$CORE_SRC" "$APP_SRC" ;;
    try_optional)       count_matches 'try\?' "$CORE_SRC" "$APP_SRC" ;;
    try_bang)           count_matches 'try!' "$CORE_SRC" "$APP_SRC" ;;
    as_bang)            count_matches 'as!' "$CORE_SRC" "$APP_SRC" ;;
    fatal_error)        count_matches 'fatalError' "$CORE_SRC" "$APP_SRC" ;;
    nonisolated_unsafe) count_matches 'nonisolated\(unsafe\)' "$CORE_SRC" "$APP_SRC" ;;
    services_prepare)   count_matches 'prepare\(' "$SERVICES" ;;
    todo_fixme)         count_matches 'TODO|FIXME' "$CORE_SRC" "$APP_SRC" "$CORE_TESTS" "$APP_TESTS" ;;
    with_known_issue)   count_matches 'withKnownIssue' "$CORE_TESTS" "$APP_TESTS" ;;
    *) echo "0" ;;
  esac
}

write_baseline() {
  mkdir -p "$(dirname "$BASELINE")"
  local tmp
  tmp="$(mktemp "$(dirname "$BASELINE")/.cleanup-baseline.XXXXXX")"
  cat > "$tmp" <<JSON
{
  "schema": 2,
  "generated_by": "scripts/check-cleanup-ratchet.sh --write-baseline",
  "counting": "matching non-comment lines (lines whose first non-space chars are // or * are ignored)",
  "metrics": {
    "unchecked_sendable": $(metric unchecked_sendable),
    "try_optional": $(metric try_optional),
    "try_bang": $(metric try_bang),
    "as_bang": $(metric as_bang),
    "fatal_error": $(metric fatal_error),
    "nonisolated_unsafe": $(metric nonisolated_unsafe),
    "services_prepare": $(metric services_prepare),
    "todo_fixme": $(metric todo_fixme),
    "with_known_issue": $(metric with_known_issue)
  },
  "scopes": {
    "unchecked_sendable": "desktop/native/*/Sources/**/*.swift",
    "try_optional": "desktop/native/*/Sources/**/*.swift",
    "try_bang": "desktop/native/*/Sources/**/*.swift",
    "as_bang": "desktop/native/*/Sources/**/*.swift",
    "fatal_error": "desktop/native/*/Sources/**/*.swift",
    "nonisolated_unsafe": "desktop/native/*/Sources/**/*.swift",
    "services_prepare": "desktop/native/gather-core/Sources/GatherApplication/Services/**/*.swift",
    "todo_fixme": "desktop/native/*/Sources + desktop/native/*/Tests",
    "with_known_issue": "desktop/native/*/Tests/**/*.swift"
  }
}
JSON
  chmod 644 "$tmp"
  mv "$tmp" "$BASELINE"
}

if [ "$WRITE" -eq 1 ] && [ -f "$BASELINE" ] && [ "$ALLOW_GROWTH" -eq 0 ]; then
  grew=0
  for key in $METRICS; do
    cur=$(metric "$key")
    base=$(grep -E "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$BASELINE" 2>/dev/null | grep -oE '[0-9]+' | head -n 1 || true)
    if [ -z "$base" ]; then
      echo "  旧基线缺 key：$key（拒绝静默补写；先补 key 或加 --allow-growth）" >&2
      exit 1
    fi
    if [ "$cur" -gt "$base" ]; then
      echo "  涨：$key $base -> $cur" >&2
      grew=1
    fi
  done
  if [ "$grew" -ne 0 ]; then
    echo "check-cleanup-ratchet: REFUSED — 基线膨胀必须显式批准" >&2
    echo "  确需扩张时加 --allow-growth，并在 docs/cleanup-backlog.md 台账记账。" >&2
    exit 1
  fi
fi

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
