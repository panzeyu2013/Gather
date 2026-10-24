#!/usr/bin/env bash
# backlog 证据门禁（P2-5 / R2，批 1 加固）。
#
# 规则：docs/cleanup-backlog.md 中状态为 pending / deferred 的 CL 段，必须包含
# 可复核的证据标记，且标记后有实际内容（不是只写“证据：”）。
# - status 大小写不敏感、支持全角冒号（status：Pending 不再逃逸）；
# - 无 status 或 status 无法识别的 ### CL- 段直接 FAIL；
# - 证据标记：证据 / 未完成原因 / 实测 / 最终复核 / 验收偏差，冒号后必须非空。
#
# 用法：./scripts/check-backlog-evidence.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FILE="docs/cleanup-backlog.md"
[ -f "$FILE" ] || { echo "check-backlog-evidence: 缺少 $FILE"; exit 1; }

echo "check-backlog-evidence:"
if awk '
  function flush() {
    if (section == "") return
    if (has_status == 0) { print "FAIL 缺少可识别 status：" section; fail = 1; return }
    if (status == 1 && evidence == 0) { print "FAIL pending/deferred 段无有效证据：" section; fail = 1 }
  }
  function low(s) { return tolower(s) }
  /^### CL-/ {
    flush()
    section = $0; status = 0; has_status = 0; evidence = 0
    line = low($0)
    if (line ~ /status[:：][ \t]*(pending|deferred)/) { status = 1; has_status = 1 }
    else if (line ~ /status[:：]/) { has_status = 1 }
    next
  }
  /^## / { flush(); section = ""; status = 0; has_status = 0; evidence = 0; next }
  {
    if (section == "") next
    line = low($0)
    if (line ~ /status[:：][ \t]*(pending|deferred)/) { status = 1; has_status = 1 }
    if (line ~ /(证据|未完成原因|实测|最终复核|验收偏差)/ && $0 ~ /[:：][ \t]*[^ \t]/) evidence = 1
  }
  END { flush(); if (fail) exit 1 }
' "$FILE"; then
  echo "ok     pending/deferred 段均有带内容的证据"
  echo "----"
  echo "check-backlog-evidence: OK"
else
  echo "       要求：status 可识别；pending/deferred 段内写「证据/未完成原因/实测/最终复核/验收偏差：<内容>」"
  echo "----"
  echo "check-backlog-evidence: FAILED"
  exit 1
fi
