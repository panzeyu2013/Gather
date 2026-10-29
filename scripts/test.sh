#!/usr/bin/env bash
# 统一测试入口（本地与 CI 同口径）。
#
# 分层原因（实测见 docs/test-runtime-audit.md）：
# - gather-core 的绝大部分用例是 hermetic 的纯行为/临时库测试，可并行；
#   并行实测 1,444 例（主批 1.2s + 状态批 0.2s），串行 ~9.2s（M5 Pro，Debug，不含构建）。
# - 少数套件改的是**进程级** GatherLogger 状态（output/minimumLevel）或
#   DBConnection 的全局慢事务阈值，跨套件并行会互相偷日志行/改写等级：
#     LoggerTests / TraceLoggingTests / LogFileSinkTests / ReadPoolTests
#   这些套件单独串行跑第二遍（--skip-build 复用第一遍的产物）。
# - gather-app 用例并行也稳定：2026-10-29 定位了真实挂载用例的 SIGSEGV
#   （NSWindow.close() 触发 KVO 二次 release）并改为 orderOut；另有
#   CullingViewModelAPITests 的 history 刷新竞态已修。50 次并行重复全绿；
#   排查单例时仍可直接用 `swift test --no-parallel`。
#
# 用法：
#   ./scripts/test.sh core            # core 并行主批 + 全局状态套件串行批
#   ./scripts/test.sh app             # app 并行（诊断单例时用 --no-parallel 直跑）
#   ./scripts/test.sh all             # 两包都跑
#   SWIFT_TEST_FLAGS="--disable-sandbox" ./scripts/test.sh core
# 额外参数原样透传给每条 swift test。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/desktop/native/gather-core"
APP="$ROOT/desktop/native/gather-app"
FLAGS=(${SWIFT_TEST_FLAGS:-})

# 进程级状态的套件：只能串行，且与主批分开进程执行。
CORE_SERIAL_FILTER='LoggerTests|TraceLoggingTests|LogFileSinkTests|ReadPoolTests'

usage() {
    sed -n '2,22p' "$0"
}

run_core() {
    echo "== gather-core：并行主批（跳过全局状态套件）"
    swift test --package-path "$CORE" --parallel \
        --skip "$CORE_SERIAL_FILTER" "${FLAGS[@]}" "$@"
    echo "== gather-core：全局状态套件串行批"
    swift test --package-path "$CORE" --no-parallel --skip-build \
        --filter "$CORE_SERIAL_FILTER" "${FLAGS[@]}" "$@"
}

run_app() {
    echo "== gather-app：并行（AppKit 窗口生命周期 SIGSEGV 已修复）"
    swift test --package-path "$APP" --parallel "${FLAGS[@]}" "$@"
}

case "${1:-all}" in
    core) [ "$#" -gt 0 ] && shift; run_core "$@" ;;
    app) [ "$#" -gt 0 ] && shift; run_app "$@" ;;
    all) [ "$#" -gt 0 ] && shift; run_core "$@"; run_app "$@" ;;
    -h|--help) usage ;;
    *) echo "test.sh: 未知目标 ${1}（core|app|all）" >&2; exit 2 ;;
esac
