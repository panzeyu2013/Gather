#!/usr/bin/env bash
# G4 层级符号门禁（2026-11-18 架构评审 Wave 4 / D1 / C1）：扫描
# GatherApplication（剥注释/字符串）的符号级越界：
#   DBConnection / Database( / SQLite3 / CSQLite 计入违规；
#   .connection 只作提示、不计违规。
# 基线 docs/baselines/structure-baseline.json 的 gates.layer-symbols section 是
# {file, pattern, count, reason, line_hint}
# 允许清单：基线外的出现即 FAIL；同一 file+pattern 计数上涨也 FAIL。
# 当前允许清单只有 1 个文件 2 处：MaintenanceService 的 VACUUM 第二连接（ADR-035 允许例外，
# :153 类型标注 + :155 第二连接）。LibraryPackageService / ExternalMetadataMigrationService
# 已在 Wave 4 端口化后移除。新增越界即 FAIL。
# --self-test 用 mktemp fixture 证明代码命中/注释不误报会被识别。
# 默认 warning 模式 exit 0；--strict 时违规即 exit 1。
# 用法：./scripts/check-layer-symbols.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-structural-gates.py" layer-symbols "$@"
