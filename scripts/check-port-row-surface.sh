#!/usr/bin/env bash
# G6 端口/行类型表面门禁（2026-11-18 Wave 5，M8 端口准入台账 + M10 行类型收敛；2026-11-18 性能轮扫描降本）。
# 守护：Persistence 端口数与 requirement 方法总数（增长需 --allow-growth）；
# 无 fake / 无有效 fake（fake 需被测试引用）端口数 / Persistence public 行类型数 /
# Application 对 Persistence public 行类型引用数只降不升；Application/UI/Host 对 DBRow 引用必须为 0。
# ratchet：聚合指标上涨即违规；逐端口方法数漂移、新增端口、fake 覆盖回退亦违规；
# 删除端口属收紧（只打 note，--write-baseline 固化）；--write-baseline 无 --allow-growth 时拒写（exit 1、不落盘）。
# 扫描：注释遮罩后单次词元化计数（口径与旧实现逐字节一致；--strict 本机 ~0.17s）。
# 台账见 docs/baselines/port-row-surface-baseline.json（每个端口 file/name/methods/has_fake/has_effective_fake；schema 2，无 generated_at）。
# 用法：./scripts/check-port-row-surface.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-port-row-surface.py" "$@"
