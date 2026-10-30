#!/usr/bin/env bash
# 清理测试/构建在系统临时目录留下的 Gather 残留（默认只统计，不删除）。
#
# 来源（2026-10-30 实测）：
#   · $TMPDIR/gather-*                —— 测试夹具目录/文件（makeTempDir、各自建目录的用例）；
#                                        修好后由 GatherTestSupport/TempHygiene.swift 的
#                                        atexit 钩子清掉，这里只收历史残留；
#   · <darwin user temp>/SFace_*.mlmodelc —— CoreML 运行时编译产物（37MB/进程，进程退出不删）；
#                                        EmbeddingModel 已改内存加载，新版本不再产生。
# 注意：CoreML 不认 $TMPDIR，始终写 getconf DARWIN_USER_TEMP_DIR，所以两处都要看。
#
# 用法：
#   ./scripts/clean-test-temp.sh           # 只统计
#   ./scripts/clean-test-temp.sh --apply   # 删除 **1 天前** 的条目（避免误删正在跑的测试/app）
set -euo pipefail

APPLY=0
case "${1:-}" in
    --apply) APPLY=1 ;;
    ""|--dry-run) ;;
    *) echo "用法: $0 [--apply]" >&2; exit 2 ;;
esac

TMP_ROOT="${TMPDIR:-/tmp}"
DARWIN_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "$TMP_ROOT")"

summarize() {
    local label="$1"; shift
    local count size
    count="$(find "$@" -maxdepth 1 \( -name 'gather-*' -o -name 'SFace*' \) ! -name 'gather-models-*' 2>/dev/null | wc -l | tr -d ' ')"
    size="$(find "$@" -maxdepth 1 \( -name 'gather-*' -o -name 'SFace*' \) ! -name 'gather-models-*' -print0 2>/dev/null \
        | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s/1024}')"
    echo "  $label: ${count} 项 / ${size:-0} MB"
}

echo "临时目录残留统计（仅统计，未删除）："
summarize "TMPDIR   ($TMP_ROOT)" "$TMP_ROOT"
summarize "CoreML   ($DARWIN_TMP)" "$DARWIN_TMP"

if [[ "$APPLY" != "1" ]]; then
    echo
    echo "确认无误后执行：$0 --apply   （只删 1 天前的条目）"
    exit 0
fi

for root in "$TMP_ROOT" "$DARWIN_TMP"; do
    [[ -d "$root" ]] || continue
    # gather-models-* 归 app 的 ModelInstaller 所有（下载包/解压目录），不在此列。
    find "$root" -maxdepth 1 -mtime +1 \( -name 'gather-*' -o -name 'SFace*' \) \
        ! -name 'gather-models-*' -print0 2>/dev/null \
        | xargs -0 rm -rf 2>/dev/null || true
done
echo
echo "已删除 1 天前的残留。剩余："
summarize "TMPDIR   ($TMP_ROOT)" "$TMP_ROOT"
summarize "CoreML   ($DARWIN_TMP)" "$DARWIN_TMP"
