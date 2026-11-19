#!/usr/bin/env bash
# G1 import 图门禁（2026-11-18 架构评审 Wave 4）：解析两个 Package.swift 的
# target 依赖声明，再扫描 Sources/Tests 下每个 target 的 import，检查：
#   (a) 实际 import 的本包模块必须已在该 target 的 dependencies 声明
#       （间接依赖 import 属违规，只可在 docs/baselines/structure-baseline.json 的
#       gates.import-graph section 的 allowlist 显式登记）；
#   (b) target 级依赖图 SCC 环检测（有环即 FAIL）；
#   (c) target 集合/依赖边与基线一致（新增需 --write-baseline --allow-growth）。
# 基线 docs/baselines/structure-baseline.json 的 gates.import-graph section
# （扫描量下限 >=18 target / >=700 文件）；
# --self-test 用 mktemp fixture 证明「未声明 import + target 环」会被发现。
# 默认 warning 模式 exit 0；--strict 时违规即 exit 1。
# 用法：./scripts/check-import-graph.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-structural-gates.py" import-graph "$@"
