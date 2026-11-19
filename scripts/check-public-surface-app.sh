#!/usr/bin/env bash
# G5 app public 面 ratchet（2026-11-18 架构评审 Wave 4）：在 check-protocol-surface.sh
# 口径上扩展（剥注释/字符串）：
#   (a) GatherUI / GatherHost / GatherApp / GatherPreviewData 四个 target 的
#       顶层 public 类型数 + public 声明行数；
#   (b) GatherProtocol/API/**/*.swift 每个 public protocol 体内的 requirement 行数
#       （func / var / init / associatedtype，剥注释）。
# 基线 docs/baselines/structure-baseline.json 的 gates.public-surface-app section，
# 只降不升（上涨需 --allow-growth 记账）。
# 注意：GatherPreviewData 用 package 可见性，public 面 0 是预期，不误报。
# --self-test 用 mktemp fixture 证明两类计数与上涨检测。
# 默认 warning 模式 exit 0；--strict 时上涨即 exit 1。
# 用法：./scripts/check-public-surface-app.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check-structural-gates.py" public-surface-app "$@"
