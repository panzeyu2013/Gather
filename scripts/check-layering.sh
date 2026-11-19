#!/usr/bin/env bash
# 分层门禁（refactor-design-breaking-2026-10-21 §2 / §7.3）。
#
# Cut 3 / 3b-6 布局后强制：
#   GatherUI        不得 import GatherPersistence / GatherApplication / GatherAnalysis /
#                   GatherHost（UI 只经 GatherProtocol + 自有端口协议取能力）
#   GatherHost      组合根：可 import 四层 core，但不得反向依赖 GatherApp；
#                   GatherUI 也不得 import 它（上一条已覆盖）
#   GatherApp       只有 @main/Scene，不得直接 import 四层 core（必须经 GatherHost）
#   core 四层 / GatherUI / GatherHost 不得 import GatherCore 伞（3b-6 已删除）
#   GatherAnalysis  不得 import GatherPersistence
#   GatherApplication    不得 import SwiftUI
#
# 20 条方向全部 fail-closed（Cut 0 的 "not split yet" 早退分支已删除，勿再加回）。
#
# --self-test：负样本自测（mktemp fixture，不写仓库）。把本脚本原样复制进临时 fixture
# 仓库，断言「GatherUI import GatherPersistence → FAIL」「合法依赖 → PASS」
# （另含 @_exported import 负样本）。
# 用法：./scripts/check-layering.sh [--self-test]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE_SRC="desktop/native/gather-core/Sources"
APP_SRC="desktop/native/gather-app/Sources"
UI_DIR="$APP_SRC/GatherUI"
HOST_DIR="$APP_SRC/GatherHost"
ENTRY_DIR="$APP_SRC/GatherApp"
ANALYSIS_DIR="$CORE_SRC/GatherAnalysis"
DOMAIN_DIR="$CORE_SRC/GatherApplication"
PERSISTENCE_DIR="$CORE_SRC/GatherPersistence"
# #1：元数据写盘（XMP/JPEG/IPTC）从 GatherHost 抽成独立 target。
METADATA_IO_DIR="$CORE_SRC/GatherMetadataIO"
# 评审面 2 F5：Delivery 一直没有扫描根，等于「无人拦 Delivery → Application/Analysis」；
# 评审面 3 5.3：新模块 GatherPreviewData 也没进扫描表。两者补上。
DELIVERY_DIR="$CORE_SRC/GatherDelivery"
PREVIEW_DIR="$APP_SRC/GatherPreviewData"

# ---------------------------------------------------------------------------
# --self-test：负样本自测（mktemp fixture，不写仓库；fixture 不达预期即 exit 1）
#   做法：把本脚本原样复制进临时 fixture 仓库，用同一份判定逻辑跑合成树，断言：
#     1) GatherUI import GatherPersistence（含 @_exported 写法）→ FAIL（exit 1）
#     2) 各层合法依赖（含 GatherHost 组合根引用 core、GatherApp 只 import GatherHost）→ PASS
# ---------------------------------------------------------------------------
SELFTEST_OUT=""
SELFTEST_TMP=""
SELFTEST_PROG="check-layering"
SELFTEST_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

selftest_die() {
  echo "$SELFTEST_PROG: self-test FAIL — $1" >&2
  exit 1
}

# selftest_expect <期望退出码> <说明> <fixture 脚本>
selftest_expect() {
  local want="$1" desc="$2" script="$3"
  local st=0
  SELFTEST_OUT=$(bash "$script" 2>&1) || st=$?
  if [ "$st" -ne "$want" ]; then
    echo "$SELFTEST_PROG: self-test FAIL — ${desc}（期望 exit ${want}，实得 ${st}）" >&2
    printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /' >&2
    exit 1
  fi
}

# selftest_contains <期望子串> <说明>
selftest_contains() {
  case "$SELFTEST_OUT" in
    *"$1"*) return 0 ;;
  esac
  echo "$SELFTEST_PROG: self-test FAIL — $2（输出里没有「$1」）" >&2
  printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /' >&2
  exit 1
}

# selftest_filler <目录> <个数>：生成不参与任何 import 判定的占位 Swift 文件
selftest_filler() {
  local dir="$1" n="$2" i=0
  mkdir -p "$dir"
  while [ "$i" -lt "$n" ]; do
    printf '// self-test 占位（无 import 语句）\nlet filler_%s = 0\n' "$i" > "$dir/F$i.swift"
    i=$((i + 1))
  done
}

selftest_cleanup() {
  if [ -n "$SELFTEST_TMP" ]; then
    rm -rf "${SELFTEST_TMP:?}"
  fi
}

# selftest_fixture <fixture 根>：铺一层「全部方向合法」的最小分层仓库
selftest_fixture() {
  local fx="$1" src="$1/desktop/native"
  mkdir -p "$fx/scripts" \
    "$src/gather-core/Sources/GatherAnalysis" \
    "$src/gather-core/Sources/GatherApplication" \
    "$src/gather-core/Sources/GatherPersistence" \
    "$src/gather-core/Sources/GatherMetadataIO" \
    "$src/gather-core/Sources/GatherDelivery" \
    "$src/gather-app/Sources/GatherUI" \
    "$src/gather-app/Sources/GatherHost" \
    "$src/gather-app/Sources/GatherApp" \
    "$src/gather-app/Sources/GatherPreviewData"
  selftest_filler "$src/gather-core/Sources/Filler" 300
  # 合法依赖：UI 只碰 SwiftUI + GatherProtocol；Host 是组合根；App 只 import Host。
  printf 'import SwiftUI\nimport GatherProtocol\n' > "$src/gather-app/Sources/GatherUI/UIFixture.swift"
  printf 'import GatherApplication\nimport GatherPersistence\nimport GatherAnalysis\nimport GatherProtocol\n' \
    > "$src/gather-app/Sources/GatherHost/HostFixture.swift"
  printf 'import GatherHost\n' > "$src/gather-app/Sources/GatherApp/AppFixture.swift"
  printf 'import GatherProtocol\n' > "$src/gather-core/Sources/GatherAnalysis/AnalysisFixture.swift"
  printf 'import GatherProtocol\n' > "$src/gather-core/Sources/GatherApplication/ApplicationFixture.swift"
  printf 'import GatherProtocol\n' > "$src/gather-core/Sources/GatherPersistence/PersistenceFixture.swift"
  printf 'import GatherProtocol\nimport GatherPersistence\n' \
    > "$src/gather-core/Sources/GatherMetadataIO/MetadataIOFixture.swift"
  printf 'import GatherProtocol\nimport GatherPersistence\nimport GatherAnalysis\n' \
    > "$src/gather-core/Sources/GatherDelivery/DeliveryFixture.swift"
  printf 'import GatherProtocol\n' > "$src/gather-app/Sources/GatherPreviewData/PreviewFixture.swift"
}

self_test() {
  local tmpbase="${TMPDIR:-/tmp}" fx ui
  tmpbase="${tmpbase%/}"
  SELFTEST_TMP=$(mktemp -d "${tmpbase}/check-layering-selftest.XXXXXX") ||
    selftest_die "mktemp 创建临时目录失败"
  trap selftest_cleanup EXIT
  fx="$SELFTEST_TMP/fixture"
  ui="$fx/desktop/native/gather-app/Sources/GatherUI/UIFixture.swift"
  selftest_fixture "$fx"
  cp "$SELFTEST_SELF" "$fx/scripts/$SELFTEST_PROG.sh"

  # 断言 1：合法分层 → PASS（各层方向都留了正样本，避免「一律放行」的假绿）。
  selftest_expect 0 "合法依赖应 PASS" "$fx/scripts/$SELFTEST_PROG.sh"
  selftest_contains "check-layering: OK" "合法依赖应输出 OK"

  # 断言 2：GatherUI import GatherPersistence → FAIL。
  printf 'import SwiftUI\nimport GatherPersistence\n' > "$ui"
  selftest_expect 1 "GatherUI import GatherPersistence 应 FAIL" "$fx/scripts/$SELFTEST_PROG.sh"
  selftest_contains "不得 import GatherPersistence" "FAIL 行应点名 GatherPersistence"

  # 断言 3：@_exported 写法同样不得绕过（复审 P2 的正则兼容性）。
  printf '@_exported import GatherPersistence\n' > "$ui"
  selftest_expect 1 "@_exported import GatherPersistence 应 FAIL" "$fx/scripts/$SELFTEST_PROG.sh"
  selftest_contains "@_exported import GatherPersistence" "FAIL 行应打印命中行"

  echo "$SELFTEST_PROG: self-test OK（GatherUI -> GatherPersistence（含 @_exported）FAIL；合法分层 PASS；3 条断言）"
  return 0
}

# --self-test 必须在扫描根守卫与真实扫描前 short-circuit：fixture 不满足 300 文件下限，
# 且自测不写仓库。
SELFTEST=0
for arg in "$@"; do
  if [ "$arg" = "--self-test" ]; then
    SELFTEST=1
  fi
done
if [ "$SELFTEST" -eq 1 ]; then
  if [ "$#" -ne 1 ]; then
    echo "check-layering: --self-test 只接受单独使用（不与其他参数混跑）" >&2
    exit 2
  fi
  self_test
  exit 0
fi


# 扫描根守卫：目录消失/改名不得静默跳过（Gate fail-open，复审 P1）。
for d in "$UI_DIR" "$HOST_DIR" "$ENTRY_DIR" "$ANALYSIS_DIR" "$DOMAIN_DIR" "$PERSISTENCE_DIR" "$METADATA_IO_DIR" "$DELIVERY_DIR" "$PREVIEW_DIR"; do
  if [ ! -d "$d" ]; then
    echo "check-layering: FAIL 缺少扫描根：$d" >&2
    exit 1
  fi
done
SWIFT_N=$(find "$CORE_SRC" "$APP_SRC" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
if [ "$SWIFT_N" -lt 300 ]; then
  echo "check-layering: FAIL Sources 只扫到 ${SWIFT_N} 个 Swift 文件（<300），疑似根路径错误" >&2
  exit 1
fi

fail=0

check_forbidden() {
  local dir="$1" label="$2"
  shift 2
  if [ ! -d "$dir" ]; then
    echo "skip   ${label}（目录不存在：${dir}）"
    return 0
  fi
  local files
  files=$(find "$dir" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
  local mod
  for mod in "$@"; do
    local hits
    # 复审 P2：兼容 @_exported 与 import struct/class/... Mod.Type 写法。
    hits=$(grep -rnE --include='*.swift' "^[[:space:]]*(@_exported[[:space:]]+)?import([[:space:]]+(struct|class|enum|func|var|typealias))?[[:space:]]+$mod([.[:space:]]|$)" "$dir" 2>/dev/null || true)
    if [ -n "$hits" ]; then
      echo "FAIL   ${label} 不得 import ${mod}："
      printf '%s\n' "$hits" | sed 's/^/  - /'
      fail=1
    else
      echo "ok     ${label}: 0 x import ${mod}（${files} 个 Swift 文件）"
    fi
  done
}

# UI/入口不得直接依赖写盘实现（#1）：只能经 GatherProtocol 的 XMPProvider 端口。
check_forbidden "$UI_DIR" "GatherUI" GatherPersistence GatherApplication GatherAnalysis GatherHost GatherDelivery GatherMetadataIO
check_forbidden "$ENTRY_DIR" "GatherApp" GatherProtocol GatherPersistence GatherAnalysis GatherApplication GatherDelivery GatherMetadataIO
check_forbidden "$HOST_DIR" "GatherHost" GatherApp
check_forbidden "$ANALYSIS_DIR" "GatherAnalysis" GatherPersistence
# #1 C4/C5：写盘实现是叶子适配器——只许依赖 Protocol / Persistence / Analysis，
# 反过来任何 core 层都不得 import 它（宿主与测试除外）。
check_forbidden "$METADATA_IO_DIR" "GatherMetadataIO" GatherApplication GatherDelivery GatherHost
check_forbidden "$DOMAIN_DIR" "GatherApplication" GatherMetadataIO
check_forbidden "$PERSISTENCE_DIR" "GatherPersistence" GatherMetadataIO
check_forbidden "$ANALYSIS_DIR" "GatherAnalysis" GatherMetadataIO
check_forbidden "$DOMAIN_DIR" "GatherApplication" SwiftUI
# 评审补：Delivery 只能依赖 Protocol / Persistence / Analysis，不得反向依赖 Application；
# PreviewData 是 DEBUG-only 预览夹具，只能依赖 Protocol（不得碰 UI / Host / Application）。
check_forbidden "$DELIVERY_DIR" "GatherDelivery" GatherApplication GatherHost
check_forbidden "$PREVIEW_DIR" "GatherPreviewData" GatherUI GatherHost GatherApplication GatherMetadataIO

# 3b-6 已删除 GatherCore 伞：任何 target 再 import 它都视为回潮。
for d in "$UI_DIR" "$HOST_DIR" "$ENTRY_DIR" "$ANALYSIS_DIR" "$DOMAIN_DIR" "$PERSISTENCE_DIR" "$METADATA_IO_DIR"; do
  if [ -d "$d" ]; then
    check_forbidden "$d" "$(basename "$d")" GatherCore
  fi
done

echo "----"
if [ "$fail" -ne 0 ]; then
  echo "check-layering: FAILED" >&2
  exit 1
fi
echo "check-layering: OK"
