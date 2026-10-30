#!/usr/bin/env bash
# V0 基线：冻结 commit 上的全量测试 + schema verify + 12 道门禁。
#
# 用法：
#   ./scripts/validation/v0-baseline.sh [--require-clean]
#
# 环境：
#   GATHER_VALIDATION_OUT   证据目录（默认 <repo>/.build/validation）
#   SWIFT_TEST_FLAGS        透传给 scripts/test.sh；DSH 沙箱下默认 --disable-sandbox
#   CLANG_MODULE_CACHE_PATH 默认 /private/tmp/gather-clang-module-cache
#
# 退出：任一步失败 → 1；全部通过 → 0。每步原始输出在 $OUT/logs/<step>.log，
# 汇总在 $OUT/logs/v0-summary.tsv（step / exit / log）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
cd "$ROOT" || exit 2

REQUIRE_CLEAN=0
if [[ "${1:-}" == "--require-clean" ]]; then
  REQUIRE_CLEAN=1
elif [[ $# -gt 0 ]]; then
  echo "v0-baseline: 未知参数 $1（只接受 --require-clean）" >&2
  exit 2
fi

OUT="${GATHER_VALIDATION_OUT:-$ROOT/.build/validation}"
LOGS="$OUT/logs"
mkdir -p "$LOGS" || exit 2
: > "$LOGS/v0-summary.tsv"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/gather-clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" 2>/dev/null || true

# DSH/受限沙箱：SwiftPM 编译 manifest 时会再套一层 sandbox-exec，内核拒绝。
# 只影响 SwiftPM 的构建沙箱，不影响被测应用（应用本身未开 App Sandbox）。
if [[ -n "${DSH_SESSION_ID:-}" && -z "${SWIFT_TEST_FLAGS:-}" ]]; then
  export SWIFT_TEST_FLAGS="--disable-sandbox"
  echo "note: 检测到 DSH 沙箱，SWIFT_TEST_FLAGS=--disable-sandbox"
fi

DIRTY=0
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  DIRTY=1
fi

{
  echo "time_utc=$(date -u +%FT%TZ)"
  echo "commit=$(git rev-parse HEAD)"
  echo "branch=$(git branch --show-current)"
  echo "dirty=$DIRTY"
  echo "swift_test_flags=${SWIFT_TEST_FLAGS:-}"
  echo "clang_module_cache=$CLANG_MODULE_CACHE_PATH"
  sw_vers
  swift --version
  xcodebuild -version
  echo "sdk=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
} > "$LOGS/env.txt" 2>&1

if [[ "$REQUIRE_CLEAN" == "1" && "$DIRTY" == "1" ]]; then
  echo "v0-baseline: 工作区不干净（--require-clean）" >&2
  git status --short >&2
  exit 1
fi

FAIL=0
PASS=0

run_step() {
  local name="$1"
  shift
  local log="$LOGS/$name.log"
  echo "== $name"
  "$@" > "$log" 2>&1
  local rc=$?
  printf '%s\t%d\t%s\n' "$name" "$rc" "$log" | tee -a "$LOGS/v0-summary.tsv"
  if [[ $rc -ne 0 ]]; then
    FAIL=1
    echo "FAIL $name (exit $rc); tail $log:" >&2
    tail -25 "$log" >&2
  else
    PASS=$((PASS + 1))
  fi
  return 0
}

run_step v0-tests ./scripts/test.sh all
run_step v0-schema swift run --package-path desktop/native/gather-core --disable-sandbox gather-schema verify

# 参数按各脚本自身用法；check-cleanup-ratchet 不接受 --strict。
run_step gate-no-legacy ./scripts/check-no-legacy.sh
run_step gate-cleanup-ratchet ./scripts/check-cleanup-ratchet.sh
run_step gate-layering ./scripts/check-layering.sh
run_step gate-protocol-surface ./scripts/check-protocol-surface.sh --strict
run_step gate-duplicate-symbols ./scripts/check-duplicate-symbols.sh --strict
run_step gate-test-catalog ./scripts/check-test-catalog.sh --strict
run_step gate-select-star ./scripts/check-select-star.sh --strict
run_step gate-preview-surface ./scripts/check-preview-surface.sh --strict
run_step gate-coded-errors ./scripts/check-coded-errors.sh
run_step gate-backlog-evidence ./scripts/check-backlog-evidence.sh
run_step gate-design-system ./scripts/check-design-system.sh
run_step gate-warnings ./scripts/check-warnings.sh

echo
echo "== 汇总"
cat "$LOGS/v0-summary.tsv"
echo
echo "== 测试计数"
grep -E 'Test run with|tests? passed' "$LOGS/v0-tests.log" || true
echo
echo "== schema"
grep -E 'schema ok|schema verify' "$LOGS/v0-schema.log" || true
echo
echo "== 结果"
if [[ $FAIL -eq 0 ]]; then
  echo "PASS: $PASS 步全绿（commit $(git rev-parse --short HEAD)）"
  exit 0
fi
echo "FAIL: $PASS 步通过，其余见 $LOGS/v0-summary.tsv" >&2
exit 1
