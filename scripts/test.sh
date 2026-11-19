#!/usr/bin/env bash
# 统一测试入口（本地与 CI 同口径；CI 单包走 scripts/run-swift-tests.sh）。
# 分层：core 多数用例 hermetic 并行；Logger/TraceLogging/LogFileSink/ReadPool
# 改进程级 GatherLogger/慢事务阈值，自动扫描后单独串行第二遍（--skip-build 复用）。
# app 并行稳定（2026-10-29 SIGSEGV 已修）；CI 固定串行 + 1200s 看门狗。
# TEST_TIMEOUT/TEST_LOG 有值时本地也走同款 perl alarm + 日志 + 失败摘要。
#
# >>> usage
#   ./scripts/test.sh core|app|all [额外 swift test 参数]
#   ./scripts/test.sh --clean-temp [--apply]   # 统计/清理 >1 天测试残留
#   SWIFT_TEST_FLAGS="--disable-sandbox" ./scripts/test.sh core
#   TEST_TIMEOUT=1200 TEST_LOG=/tmp/g.log ./scripts/test.sh --no-parallel app
# <<< usage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/desktop/native/gather-core"
APP="$ROOT/desktop/native/gather-app"
# 模型编译缓存：默认位置是 ~/Library/Caches（沙箱/CI 里可能只读，也不该让测试污染
# 用户缓存）。测试统一落到仓库 .build/，跨运行复用——同一份权重只编译一次，
# 之后各进程只读，避免每次运行往系统临时目录写 37MB。
export GATHER_MODEL_CACHE_DIR="${GATHER_MODEL_CACHE_DIR:-$ROOT/.build/gather-model-cache}"
# SWIFT_TEST_FLAGS 是「按空白拆分」的一组默认 flag（不是单个带空格参数）：
# read -a 只做 IFS 拆分不做 glob；多行先归一为空格；set -u 下必须给默认值，
# 否则不带该变量的文档化入口会直接 unbound variable（T1）。
_normalized_flags="${SWIFT_TEST_FLAGS:-}"
_normalized_flags="${_normalized_flags//$'\n'/ }"
IFS=$' \t\n' read -r -a FLAGS <<< "$_normalized_flags"

usage() {
    # 标记行定界（>>> usage/<<< usage），不依赖固定 sed 行号（T15）。
    sed -n '/^# >>> usage$/,/^# <<< usage$/p' "$0" \
        | sed -e '1d' -e '$d' -e 's/^# //' -e 's/^#$//'
}

# --clean-temp：统计/清理两个 temp root 里 >1 天的 Gather 残留（原
# scripts/clean-test-temp.sh 已并入，T11）。只统计除非 --apply；gather-models-*
# 归 app 的 ModelInstaller 所有（下载包/解压目录），不动；CoreML 不认 $TMPDIR，
# 始终写 DARWIN_USER_TEMP_DIR，所以两个 root 都要看。
clean_temp_summary() {
    local label="$1" root="$2" count size
    if [ ! -d "$root" ]; then
        echo "  $label: 0 项 / 0 MB"
        return 0
    fi
    count="$(find "$root" -maxdepth 1 \( -name 'gather-*' -o -name 'SFace_*' \) \
        ! -name 'gather-models-*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" -eq 0 ]; then
        echo "  $label: 0 项 / 0 MB"
        return 0
    fi
    size="$(find "$root" -maxdepth 1 \( -name 'gather-*' -o -name 'SFace_*' \) \
        ! -name 'gather-models-*' -print0 2>/dev/null \
        | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s/1024}')"
    echo "  $label: ${count} 项 / ${size:-0} MB"
}

clean_temp() {
    local tmp_root darwin_tmp root
    tmp_root="${TMPDIR:-/tmp}"
    darwin_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$tmp_root")"
    echo "临时目录残留统计（仅统计，未删除）："
    clean_temp_summary "TMPDIR   ($tmp_root)" "$tmp_root"
    clean_temp_summary "CoreML   ($darwin_tmp)" "$darwin_tmp"
    if [ "$APPLY" != "1" ]; then
        echo
        echo "确认无误后执行：$0 --clean-temp --apply   （只删 1 天前的条目）"
        return 0
    fi
    for root in "$tmp_root" "$darwin_tmp"; do
        [ -d "$root" ] || continue
        find "$root" -maxdepth 1 -mtime +1 \( -name 'gather-*' -o -name 'SFace_*' \) \
            ! -name 'gather-models-*' -print0 2>/dev/null \
            | xargs -0 rm -rf 2>/dev/null || true
    done
    echo
    echo "已删除 1 天前的残留。剩余："
    clean_temp_summary "TMPDIR   ($tmp_root)" "$tmp_root"
    clean_temp_summary "CoreML   ($darwin_tmp)" "$darwin_tmp"
}

# 参数面：前置开关（--no-parallel / --clean-temp [--apply] / -h），首个非开关参数
# 是目标（core|app|all，缺省 all），其余原样透传给每条 swift test。
NO_PARALLEL=0
CLEAN_TEMP=0
APPLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-parallel) NO_PARALLEL=1; shift ;;
        --clean-temp) CLEAN_TEMP=1; shift ;;
        --apply) APPLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "test.sh: 未知选项 $1（--help 查看用法）" >&2; exit 2 ;;
        *) break ;;
    esac
done
# 文档兼容：TEST_SERIAL=1 等同 --no-parallel。
if [ "${TEST_SERIAL:-0}" = "1" ]; then
    NO_PARALLEL=1
fi
if [ "$APPLY" = 1 ] && [ "$CLEAN_TEMP" != 1 ]; then
    echo "test.sh: --apply 只能与 --clean-temp 一起用" >&2
    exit 2
fi
if [ "$CLEAN_TEMP" = 1 ]; then
    if [ "$#" -gt 0 ]; then
        echo "test.sh: --clean-temp 不接受目标或额外参数" >&2
        exit 2
    fi
    clean_temp
    exit 0
fi

# 进程级兜底（2026-10-30）：TempHygiene(atexit) 覆盖不到 SIGKILL / Ctrl-C，且个别
# 跨进程 rendezvous（gather-replay-*.lock）不保证删。这里用「运行开始标记 + mtime」
# 在退出时清掉本次运行新增的临时条目；gather-models-* 归 app 的 ModelInstaller 所有。
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

# TEST_TIMEOUT/TEST_LOG 任一有值时，走与 scripts/run-swift-tests.sh 相同的
# 「perl alarm 看门狗 + 输出落盘 + 失败摘要」；两者都没设时原样直跑（历史行为）。
# TEST_LOG 给定时 core 两批共用一份日志（第二批前空行分隔），失败摘要看整份。
TEST_LOG_STARTED=0
run_swift_test() {
    local log timeout
    if [ -z "${TEST_TIMEOUT:-}" ] && [ -z "${TEST_LOG:-}" ]; then
        "$@"
        return 0
    fi
    timeout="${TEST_TIMEOUT:-1200}"
    case "$timeout" in
        ''|*[!0-9]*)
            echo "test.sh: TEST_TIMEOUT 必须是正整数秒（当前 '$timeout'）" >&2
            exit 2
            ;;
    esac
    log="${TEST_LOG:-}"
    if [ -z "$log" ]; then
        log="$(mktemp "${TMPDIR:-/tmp}/gather-test.XXXXXX")"
    elif [ "$TEST_LOG_STARTED" = 1 ]; then
        printf '\n===== 下一批 =====\n' >>"$log"
    else
        : >"$log"
        TEST_LOG_STARTED=1
    fi
    if ! perl -e 'alarm shift; exec @ARGV' "$timeout" "$@" >>"$log" 2>&1; then
        echo "::error::tests failed or timed out（看门狗 ${timeout}s，日志：$log）"
        echo "=== failures ==="
        grep -nE '✘|recorded an issue|^error:' "$log" | head -40 || true
        echo "=== tail ==="
        tail -120 "$log"
        exit 1
    fi
    tail -20 "$log"
}

# macOS 自带 bash 3.2：空数组在 set -u 下展开 "${arr[@]}" 会报 unbound variable
#（bash 3.2 的历史缺陷，CI 的 /bin/bash 正是 3.2）。只在非空时展开。
# 目标之后的 --no-parallel 同样识别（文档示例 `test.sh core --no-parallel`），其余
# 参数原样透传；TEST_SERIAL=1 与 --no-parallel 等价（文档兼容别名）。
TARGET="${1:-all}"
if [ "$#" -gt 0 ]; then
    shift
fi
SWIFT_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-parallel) NO_PARALLEL=1 ;;
        *) SWIFT_ARGS=("${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}" "$arg") ;;
    esac
done
# --no-parallel 时主批/app 显式传 --no-parallel（与 CI 同口径）；串行批本来就是串行。
CONCURRENCY_FLAG=(--parallel)
if [ "$NO_PARALLEL" = 1 ]; then
    CONCURRENCY_FLAG=(--no-parallel)
fi

run_core() {
    if [ "$NO_PARALLEL" = 1 ]; then
        echo "== gather-core：串行主批（--no-parallel，跳过全局状态套件）"
    else
        echo "== gather-core：并行主批（跳过全局状态套件）"
    fi
    run_swift_test swift test --package-path "$CORE" \
        ${CONCURRENCY_FLAG[@]+"${CONCURRENCY_FLAG[@]}"} \
        --explicit-target-dependency-import-check error \
        --skip "$CORE_SERIAL_FILTER" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
    echo "== gather-core：全局状态套件串行批"
    run_swift_test swift test --package-path "$CORE" --no-parallel --skip-build \
        --explicit-target-dependency-import-check error \
        --filter "$CORE_SERIAL_FILTER" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
}

run_app() {
    if [ "$NO_PARALLEL" = 1 ]; then
        echo "== gather-app：串行（--no-parallel）"
    else
        echo "== gather-app：并行（AppKit 窗口生命周期 SIGSEGV 已修复）"
    fi
    run_swift_test swift test --package-path "$APP" \
        ${CONCURRENCY_FLAG[@]+"${CONCURRENCY_FLAG[@]}"} \
        --explicit-target-dependency-import-check error ${FLAGS[@]+"${FLAGS[@]}"} "$@"
}

case "$TARGET" in
    core) run_core ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} ;;
    app) run_app ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} ;;
    all)
        run_core ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}
        run_app ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}
        ;;
    *) echo "test.sh: 未知目标 $TARGET（core|app|all）" >&2; exit 2 ;;
esac
