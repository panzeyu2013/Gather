#!/usr/bin/env bash
# 统一测试入口（本地与 CI 同口径）。
#
# 分层原因（实测见 docs/test-runtime-audit.md）：
# - gather-core 的绝大部分用例是 hermetic 的纯行为/临时库测试，可并行；
#   并行实测 1,434 例（主批 1.1s + 状态批 0.2s），串行 ~9.2s（M5 Pro，Debug，不含构建）。
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
# 模型编译缓存：默认位置是 ~/Library/Caches（沙箱/CI 里可能只读，也不该让测试污染
# 用户缓存）。测试统一落到仓库 .build/，跨运行复用——同一份权重只编译一次，
# 之后各进程只读，避免每次运行往系统临时目录写 37MB。
export GATHER_MODEL_CACHE_DIR="${GATHER_MODEL_CACHE_DIR:-$ROOT/.build/gather-model-cache}"
# SC2206：SWIFT_TEST_FLAGS 是「按空白拆分」的一组 flag（不是单个带空格参数），
# 原写法 ${SWIFT_TEST_FLAGS:-} 不加引号依赖 word splitting，且会顺带触发 glob 展开；
# read -a 只做 IFS 拆分、不做 glob，空值时得到空数组（后续 ${FLAGS[@]+...} 兼容 bash 3.2）。
# read -a 只读一行：先把换行归一为空格，否则多行 flags 只取首行（评审 R3T-10）。
_normalized_flags="${SWIFT_TEST_FLAGS//$'\n'/ }"
IFS=$' \t\n' read -r -a FLAGS <<< "$_normalized_flags"

# 进程级兜底（2026-10-30）：进程内的 TempHygiene(atexit) 覆盖不到两种情况——
# ① SIGKILL / Ctrl-C 时 atexit 不执行；② 个别子系统（如 DeliveryReplayClaims 的
# gather-replay-*.lock 跨进程 rendezvous）用完不一定删，一次全量会留 1-2 个
# 0 字节文件。这里用“运行开始标记 + mtime 更新”在退出时清掉本次运行新增的临时
# 条目；`gather-models-*` 归 app 的 ModelInstaller 所有（下载包/解压目录），不在此列。
TEST_TEMP_MARK="$(mktemp "${TMPDIR:-/tmp}/.gather-test-run.XXXXXX")"
cleanup_test_temp() {
    local root
    for root in "${TMPDIR:-/tmp}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"; do
        [[ -n "$root" && -d "$root" ]] || continue
        find "$root" -maxdepth 1 \( -name 'gather-*' -o -name 'SFace_*' \) \
            -not -name 'gather-models-*' -newer "$TEST_TEMP_MARK" -print0 2>/dev/null \
            | xargs -0 rm -rf 2>/dev/null || true
    done
    rm -f "$TEST_TEMP_MARK"
}
trap cleanup_test_temp EXIT

# 进程级状态的套件：只能串行，且与主批分开进程执行。
# P3-7：不再手工维护名单——扫描 core 测试里直接触碰进程级日志/慢事务阈值的
# 文件，按文件名生成 filter，新增同类套件自动进入串行批。
CORE_SERIAL_FILTER="$(grep -rlE 'GatherLogger|slowTransaction' \
    "$CORE/Tests/GatherCoreTests" --include='*.swift' 2>/dev/null \
    | sed 's#.*/##; s#\.swift$##' | sort -u | paste -sd'|' -)"
if [ -z "$CORE_SERIAL_FILTER" ]; then
    echo "test.sh: FAIL 未发现进程级状态套件（GatherLogger/slowTransaction），名单推导失效" >&2
    exit 1
fi
# 文件名必须真的声明同名 suite/type，否则 --filter 会静默 0 命中。
for name in ${CORE_SERIAL_FILTER//|/ }; do
    if ! grep -rqE "(struct|final class|class) ${name}([ :{]|$)" "$CORE/Tests/GatherCoreTests"; then
        echo "test.sh: FAIL 串行名单 ${name} 在测试目录找不到同名类型" >&2
        exit 1
    fi
done

usage() {
    sed -n '2,21p' "$0"
}

# macOS 自带 bash 3.2：空数组在 set -u 下展开 "${arr[@]}" 会报 unbound variable
#（bash 3.2 的历史缺陷，CI 的 /bin/bash 正是 3.2）。只在非空时展开。
run_core() {
    echo "== gather-core：并行主批（跳过全局状态套件）"
    swift test --package-path "$CORE" --parallel \
        --skip "$CORE_SERIAL_FILTER" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
    echo "== gather-core：全局状态套件串行批"
    swift test --package-path "$CORE" --no-parallel --skip-build \
        --filter "$CORE_SERIAL_FILTER" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
}

run_app() {
    echo "== gather-app：并行（AppKit 窗口生命周期 SIGSEGV 已修复）"
    swift test --package-path "$APP" --parallel ${FLAGS[@]+"${FLAGS[@]}"} "$@"
}

case "${1:-all}" in
    core) [ "$#" -gt 0 ] && shift; run_core "$@" ;;
    app) [ "$#" -gt 0 ] && shift; run_app "$@" ;;
    all) [ "$#" -gt 0 ] && shift; run_core "$@"; run_app "$@" ;;
    -h|--help) usage ;;
    *) echo "test.sh: 未知目标 ${1}（core|app|all）" >&2; exit 2 ;;
esac
