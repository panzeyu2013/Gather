#!/usr/bin/env bash
# G3 并发标注白名单门禁（2026-11-18 架构评审 Wave 4）：扫描 desktop/native/*/Sources
# 的 @unchecked Sendable 与 nonisolated(unsafe)（剥注释/字符串），用花括号配对定位
# 最近外层类型，登记为 (file, type, kind) 白名单（预算 60/60 已满）。
#   - 出现基线外的 (file,type,kind) 即 FAIL（即使总数不变）；
#   - 同一位置 count 上涨也 FAIL；减少只告警并提示收紧。
# 基线 docs/baselines/structure-baseline.json 的 gates.concurrency-whitelist section
# （当前 60 处 @unchecked + 4 处 nonisolated(unsafe)）；
# --self-test 用 mktemp fixture 证明新增/注释误报边界。
# 默认 warning 模式 exit 0；--strict 时违规即 exit 1。
# 用法：./scripts/check-concurrency-whitelist.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-structural-gates.py" concurrency-whitelist "$@"
