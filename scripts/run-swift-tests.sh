#!/usr/bin/env bash
# CI 测试段唯一入口（T3：原 ci.yml 两个逐字重复的 14 行 heredoc 归一到这里）：
# 固定串行（--no-parallel；TEST_PARALLEL=1 才换 --parallel）+ explicit-target-
# dependency-import-check error + 输出落盘 + perl alarm 看门狗 + 失败摘要；
# 本地 scripts/test.sh 复用同一套 env 口径。
#
# >>> usage
#   scripts/run-swift-tests.sh core|app [额外 swift test 参数]
#   TEST_TIMEOUT=1200  看门狗秒数（默认 1200）
#   TEST_LOG=<path>    测试输出日志；默认 mktemp，CI 有 $RUNNER_TEMP 时默认
#                      $RUNNER_TEMP/gather-<core|app>-tests.log（失败可上传）
#   TEST_EVENT_STREAM=<path>  有值时追加 swift test --event-stream-output-path
#                      （Swift Testing 事件流，供剖析/归档；默认不追加，行为不变）
#   TEST_PARALLEL=1    追加 --parallel（本地排障用；CI 不设，保持串行）
#   RUN_SWIFT_TESTS_DRY_RUN=1  只打印完整命令不执行（Linux 验证参数装配）
# <<< usage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    # 标记行定界（>>> usage/<<< usage），不依赖固定 sed 行号。
    sed -n '/^# >>> usage$/,/^# <<< usage$/p' "$0" \
        | sed -e '1d' -e '$d' -e 's/^# //' -e 's/^#$//'
}

TARGET="${1:-}"
case "$TARGET" in
    core) PKG="$ROOT/desktop/native/gather-core" ;;
    app) PKG="$ROOT/desktop/native/gather-app" ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "run-swift-tests.sh: 未知目标 ${TARGET:-<空>}（core|app）" >&2
        usage >&2
        exit 2
        ;;
esac
# 目标之后的参数原样透传给 swift test。
if [ "$#" -gt 0 ]; then
    shift
fi

TEST_TIMEOUT="${TEST_TIMEOUT:-1200}"
case "$TEST_TIMEOUT" in
    ''|*[!0-9]*)
        echo "run-swift-tests.sh: TEST_TIMEOUT 必须是正整数秒（当前 '$TEST_TIMEOUT'）" >&2
        exit 2
        ;;
esac

# 完整命令数组；bash 3.2 空数组在 set -u 下不能裸展开 "${arr[@]}"，
# 用 ${arr[@]+"…"} 守卫（本脚本数组恒非空，仅注释说明口径）。
CMD=(perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT" swift test \
    --package-path "$PKG" --explicit-target-dependency-import-check error)
if [ "${TEST_PARALLEL:-0}" = "1" ]; then
    CMD+=(--parallel)
else
    CMD+=(--no-parallel)
fi
# 可选事件流透传：TEST_EVENT_STREAM 非空才追加，默认命令逐字节不变。
if [ -n "${TEST_EVENT_STREAM:-}" ]; then
    CMD+=(--event-stream-output-path "$TEST_EVENT_STREAM")
fi
if [ "$#" -gt 0 ]; then
    CMD+=("$@")
fi

if [ "${RUN_SWIFT_TESTS_DRY_RUN:-0}" = "1" ]; then
    printf '%q ' "${CMD[@]}"
    printf '\n'
    exit 0
fi

# 日志：显式 TEST_LOG 优先；CI 有 RUNNER_TEMP 时落固定路径供失败上传；否则 mktemp。
if [ -n "${TEST_LOG:-}" ]; then
    LOG="$TEST_LOG"
elif [ -n "${RUNNER_TEMP:-}" ]; then
    LOG="$RUNNER_TEMP/gather-${TARGET}-tests.log"
else
    LOG="$(mktemp "${TMPDIR:-/tmp}/gather-${TARGET}-tests.XXXXXX")"
fi

echo "== gather-${TARGET} tests（日志：$LOG；看门狗：${TEST_TIMEOUT}s）"
if ! "${CMD[@]}" >"$LOG" 2>&1; then
    echo "::error::gather-${TARGET} tests failed or timed out"
    echo "=== failures ==="
    grep -nE '✘|recorded an issue|^error:' "$LOG" | head -40 || true
    echo "=== tail ==="
    tail -120 "$LOG"
    exit 1
fi
tail -20 "$LOG"
