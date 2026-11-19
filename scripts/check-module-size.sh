#!/usr/bin/env bash
# G2 模块规模 ratchet（2026-11-18 架构评审 Wave 4）：按 Package.swift 的
# target 统计每个 target 目录（Sources/Tests）的文件数、LOC、最大文件 LOC，
# 以及包级 Tests/Sources 行比。语义：
#   - Sources LOC 合计与最大文件 LOC 只降不升（上涨需 --allow-growth 并在 docs/cleanup-backlog.md 记账）；
#   - Tests 规模（LOC / 最大文件）只告警不失败（新增测试不应触发 --allow-growth）；
#   - 文件数上涨只告警不失败（拆文件是合法重构）；
#   - Tests/Sources 行比只记录，不参与 ratchet。
# 基线 docs/baselines/structure-baseline.json 的 gates.module-size section；
# --self-test 用 mktemp fixture 证明 LOC 上涨会被发现。
# 默认 warning 模式 exit 0；--strict 时上涨即 exit 1。
# 用法：./scripts/check-module-size.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-structural-gates.py" module-size "$@"
