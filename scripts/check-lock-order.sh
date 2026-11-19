#!/usr/bin/env bash
# G0 锁序门禁（2026-11-18 架构评审 Wave 4）：docs/delivery-lock-order.md 的
# 「XMP -> DB 允许、DB -> XMP 禁止」静态扫描。扫描 GatherDelivery 里每个
# connection.transaction 花括号平衡块：块内出现 XMPFileLock / fileLock /
# 文件端口（DeliveryFilePort 等）/ FileManager / Task 绕过即违规（当前 0）。
#
# 基线 docs/baselines/structure-baseline.json 的 gates.lock-order section（0 违规 + 扫描计数下限）；
# --write-baseline 只原子更新该 section（读-改-写，保留其他 gate 数据）；
# 拒绝写入非 0 违规；--self-test 用 mktemp fixture 证明反向锁序会被发现。
# 默认 warning 模式 exit 0；--strict 时违规即 exit 1。
# 用法：./scripts/check-lock-order.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-structural-gates.py" lock-order "$@"
