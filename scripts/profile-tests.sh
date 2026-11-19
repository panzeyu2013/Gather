#!/usr/bin/env bash
# macOS 测试剖析入口：用 /usr/bin/time -l 包裹一次 swift test（带 Swift Testing
# 事件流输出），随后用 scripts/lib/test-profile.py 汇总每测试耗时 top N、按 suite
# 聚合耗时、总耗时与 real/user/sys/RSS。
#
# 为什么默认 --no-parallel：并行执行有调度竞争与 CPU 抢占，单测试耗时不可比；
# 需要观测并行行为时显式 --parallel（结果会混入竞争开销）。
# Linux 无 macOS SDK：只支持 --dry-run（验证参数装配）/ --help / --self-test
# （解析器自测）；真实运行模式在 Linux 上明确报错退出 2。
#
# >>> usage
#   scripts/profile-tests.sh core|app [--parallel] [--filter REGEX] [--top N] [--dry-run]
#   scripts/profile-tests.sh --self-test
#   scripts/profile-tests.sh --help
#
#   core|app      剖析 desktop/native/gather-{core,app} 测试包
#   --parallel    透传 swift test --parallel（默认 --no-parallel，保耗时可比）
#   --filter X    只剖析匹配 X 的测试（swift test --filter，正则）
#   --top N       每测试耗时榜单条数（默认 30）
#   --dry-run     只打印将执行/解析的命令，不真正运行（Linux 可验证参数装配）
#   --self-test   运行解析器自测（scripts/lib/test-profile.py --self-test）
#
#   环境变量：
#     PROFILE_KEEP=1      成功后保留事件流/计时/日志临时目录（默认成功即清理；
#                         失败一定保留并把路径打印到 stderr）
#     PROFILE_TIMEOUT=秒  可选看门狗（默认不启用；macOS 自带 perl 提供 alarm）
# <<< usage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_PY="$ROOT/scripts/lib/test-profile.py"

usage() {
    # 标记行定界（>>> usage/<<< usage），不依赖固定 sed 行号。
    sed -n '/^# >>> usage$/,/^# <<< usage$/p' "$0" \
        | sed -e '1d' -e '$d' -e 's/^# //' -e 's/^#$//'
}

die() {
    echo "profile-tests.sh: $*" >&2
    exit 2
}

TARGET=""
PARALLEL=0
FILTER=""
TOP=30
DRY_RUN=0
SELF_TEST=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --parallel) PARALLEL=1; shift ;;
        --filter)
            [ "$#" -ge 2 ] || die "--filter 需要参数"
            FILTER="$2"
            shift 2
            ;;
        --filter=*) FILTER="${1#--filter=}"; shift ;;
        --top)
            [ "$#" -ge 2 ] || die "--top 需要参数"
            TOP="$2"
            shift 2
            ;;
        --top=*) TOP="${1#--top=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "未知选项 $1（--help 查看用法）" ;;
        *)
            [ -z "$TARGET" ] || die "多余参数 $1（目标只能是 core|app）"
            TARGET="$1"
            shift
            ;;
    esac
done
[ "$#" -eq 0 ] || die "多余参数：$*"

if [ "$SELF_TEST" = 1 ]; then
    [ -z "$TARGET" ] || die "--self-test 不接受目标参数"
    command -v python3 >/dev/null 2>&1 || die "缺少 python3（解析器自测需要）"
    [ -f "$PROFILE_PY" ] || die "缺少解析器 $PROFILE_PY"
    exec python3 "$PROFILE_PY" --self-test
fi

case "$TARGET" in
    core) PKG="$ROOT/desktop/native/gather-core" ;;
    app) PKG="$ROOT/desktop/native/gather-app" ;;
    *) die "未知目标 ${TARGET:-<空>}（core|app）" ;;
esac
case "$TOP" in
    ''|*[!0-9]*) die "--top 必须是正整数（当前 '$TOP'）" ;;
esac
[ "$TOP" -gt 0 ] || die "--top 必须是正整数（当前 '$TOP'）"
if [ -n "$FILTER" ]; then
    case "$FILTER" in
        *[![:space:]]*) ;;
        *) die "--filter 不能为空" ;;
    esac
fi
if [ -n "${PROFILE_TIMEOUT:-}" ]; then
    case "$PROFILE_TIMEOUT" in
        ''|*[!0-9]*) die "PROFILE_TIMEOUT 必须是正整数秒（当前 '$PROFILE_TIMEOUT'）" ;;
    esac
fi

# 临时目录在两种模式下都先建出来，保证 --dry-run 打印的是本次真实路径。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gather-profile-XXXXXX")"
EVENTS="$WORK/events.jsonl"
TIME_FILE="$WORK/time.txt"
LOG="$WORK/test.log"

# 临时目录一建出来就挂清理 trap：后续任何 die/失败退出都不会留下空目录；
# 失败或 PROFILE_KEEP=1 时 CLEAN=0，保留文件并把路径打到 stderr。
CLEAN=1
cleanup() {
    if [ "$CLEAN" = 1 ]; then
        rm -rf "$WORK"
    else
        echo "剖析原始文件保留在: ${WORK}（清理：rm -rf ${WORK}）" >&2
    fi
}
trap cleanup EXIT

# 命令装配（--dry-run 与真实运行共用，避免两套口径漂移）。
SWIFT_CMD=(swift test --package-path "$PKG"
    --explicit-target-dependency-import-check error)
if [ "$PARALLEL" = 1 ]; then
    SWIFT_CMD+=(--parallel)
else
    SWIFT_CMD+=(--no-parallel)
fi
SWIFT_CMD+=(--event-stream-output-path "$EVENTS")
if [ -n "$FILTER" ]; then
    SWIFT_CMD+=(--filter "$FILTER")
fi
CMD=(/usr/bin/time -l -o "$TIME_FILE")
if [ -n "${PROFILE_TIMEOUT:-}" ]; then
    # perl 的 alarm 包在 time 之内：exec 后 pid 不变，rusage 仍属于 swift test。
    CMD+=(perl -e 'alarm shift; exec @ARGV' "$PROFILE_TIMEOUT")
fi
CMD+=("${SWIFT_CMD[@]}")
REPORT_CMD=(python3 "$PROFILE_PY" --events "$EVENTS" --time-stats "$TIME_FILE"
    --top "$TOP")

if [ "$DRY_RUN" = 1 ]; then
    echo "== profile-tests.sh --dry-run（不执行；Linux 可验证参数装配）=="
    echo "目标: ${TARGET}（${PKG}）"
    if [ "$PARALLEL" = 1 ]; then
        echo "并发: --parallel（单测试耗时含调度竞争）"
    else
        echo "并发: --no-parallel（默认，耗时可比）"
    fi
    if [ -n "$FILTER" ]; then
        echo "过滤: $FILTER"
    fi
    echo "事件流: $EVENTS"
    echo "计时:   ${TIME_FILE}（/usr/bin/time -l -o）"
    echo "日志:   $LOG"
    echo "将执行:"
    printf '  '
    printf '%q ' "${CMD[@]}"
    printf '\n'
    echo "随后解析:"
    printf '  '
    printf '%q ' "${REPORT_CMD[@]}"
    printf '\n'
    rmdir "$WORK" 2>/dev/null || true
    exit 0
fi

# 真实运行：macOS + swift + /usr/bin/time + python3 全部就绪才继续。
if [ "$(uname -s)" != "Darwin" ]; then
    rmdir "$WORK" 2>/dev/null || true
    echo "profile-tests.sh: 真实剖析需要 macOS（Swift Testing 事件流 + /usr/bin/time -l；Linux 无 macOS SDK）" >&2
    echo "  Linux 可用：--dry-run（参数装配）/ --help / --self-test（解析器自测）" >&2
    exit 2
fi
command -v swift >/dev/null 2>&1 \
    || die "缺少 swift（macOS 需安装 Xcode 或 Command Line Tools）"
command -v python3 >/dev/null 2>&1 || die "缺少 python3（报告解析需要）"
[ -x /usr/bin/time ] || die "缺少 /usr/bin/time（macOS 自带；本脚本用它取 -l 统计）"
[ -f "$PROFILE_PY" ] || die "缺少解析器 $PROFILE_PY"

if [ "$PARALLEL" = 1 ]; then
    CONCURRENCY_LABEL="--parallel（耗时含调度竞争）"
else
    CONCURRENCY_LABEL="--no-parallel（默认）"
fi
echo "== gather-$TARGET 测试剖析（/usr/bin/time -l + Swift Testing 事件流）"
echo "   目标包: $PKG"
echo "   并发:   $CONCURRENCY_LABEL"
if [ -n "$FILTER" ]; then
    echo "   过滤:   $FILTER"
fi
echo "   事件流: $EVENTS"
echo "   计时:   $TIME_FILE"
echo "   日志:   $LOG"
echo "   提示:   real/RSS 含构建开销；预热构建后（先跑一次 scripts/test.sh ${TARGET}）更接近纯测试成本。"

set +e
"${CMD[@]}" >"$LOG" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    CLEAN=0
    echo "profile-tests.sh: 测试命令失败（exit ${RC}），以下打印原始日志：" >&2
    echo "  日志: $LOG" >&2
    if [ -s "$EVENTS" ]; then
        echo "  事件流已部分生成: ${EVENTS}（可单独解析：python3 $PROFILE_PY --events ${EVENTS}）" >&2
    fi
    echo "=== 失败摘要 ===" >&2
    grep -nE '✘|recorded an issue|^error:' "$LOG" | head -40 >&2 || true
    echo "=== 日志尾部（最多 200 行）===" >&2
    tail -200 "$LOG" >&2
    exit "$RC"
fi

echo "== 测试命令完成，生成报告 =="
tail -3 "$LOG"
if [ ! -s "$EVENTS" ]; then
    CLEAN=0
    echo "profile-tests.sh: swift test 成功但未生成事件流文件 $EVENTS" >&2
    echo "  请确认本机 Swift Testing 支持 --event-stream-output-path（Swift 6.2+ 的 SwiftPM 会转发）" >&2
    exit 1
fi
set +e
python3 "$PROFILE_PY" --events "$EVENTS" --time-stats "$TIME_FILE" --top "$TOP"
REPORT_RC=$?
set -e
if [ "$REPORT_RC" -ne 0 ]; then
    CLEAN=0
    echo "profile-tests.sh: 剖析报告生成失败（exit ${REPORT_RC}）；事件流/计时/日志保留在 $WORK" >&2
    exit 1
fi

if [ "${PROFILE_KEEP:-0}" = "1" ]; then
    CLEAN=0
    echo "剖析原始文件保留在: $WORK"
fi
