#!/usr/bin/env bash
# V1 夹具往返预演：把验证 harness 临时复制进 GatherAppTests，跑完即删。
#
# 用法：./scripts/validation/run-v1-fixtures.sh [fixtures-dir]
# 默认 fixtures-dir：.build/validation/fixtures-matrix
# 退出：测试失败 → 非 0；日志：.build/validation/logs/v1-fixtures-roundtrip.log
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
cd "$ROOT" || exit 2

FIXTURES="${1:-$ROOT/.build/validation/fixtures-matrix}"
SOURCE="$ROOT/scripts/validation/V1FixtureRoundTripTests.swift"
TARGET="$ROOT/desktop/native/gather-app/Tests/GatherAppTests/V1FixtureRoundTripTests.swift"
OUT="${GATHER_VALIDATION_OUT:-$ROOT/.build/validation}"
LOG="$OUT/logs/v1-fixtures-roundtrip.log"
mkdir -p "$(dirname "$LOG")" || exit 2

if [[ ! -d "$FIXTURES" ]]; then
  echo "fixtures dir not found: ${FIXTURES}（先跑 fixtures.py generate --matrix）" >&2
  exit 2
fi
if [[ -e "$TARGET" ]]; then
  echo "refusing: $TARGET already exists" >&2
  exit 2
fi

cleanup() { rm -f "$TARGET"; }
trap cleanup EXIT INT TERM

cp "$SOURCE" "$TARGET" || exit 2
export GATHER_VALIDATION_FIXTURES="$FIXTURES"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/gather-clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" 2>/dev/null || true

echo "fixtures: $FIXTURES"
echo "log: $LOG"
swift test --package-path "$ROOT/desktop/native/gather-app" --disable-sandbox \
  --filter V1FixtureRoundTripTests 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
echo "EXIT:$rc" >> "$LOG"
exit "$rc"
