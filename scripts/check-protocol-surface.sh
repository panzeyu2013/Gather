#!/usr/bin/env bash
# Protocol 公开面 ratchet 门禁（WP1，2026-10-22）。
#
# 指标（均为实测，口径写在下方）：
#   public_types            Protocol 顶层 public 类型声明数：struct / enum /
#                           indirect enum / final class / class / protocol / actor。
#                           嵌套类型不计（与 WP1 盘点 347 口径一致）。
#   public_declarations     以 public 开头的声明行数（含成员；等价于
#                           grep -rhE '^[[:space:]]*public[[:space:]]' | wc -l）。
#   zero_reference_types    生产代码与 Protocol 内均无引用的顶层 public 类型数。
#                           生产 = GatherPersistence/GatherAnalysis/GatherDomain
#                           + gather-app/Sources；Protocol 内按标识符计数并排除声明
#                           本身；注释和字符串已剥离。Tests 不计入引用（只靠
#                           ContractTests 存活的 DTO 仍算零引用，随之删除）。
#   router_envelope_types   Router 时代 JSON 信封类型声明数：
#                           ResponseID / ErrorDetail / ResponseErrorBody /
#                           ResponseOk / ResponseErr / Response<T>。目标 0。
#
# 基线：docs/protocol-surface-baseline.json（--write-baseline 重写）。
# 默认 warning 模式 exit 0；--strict 时任一指标高于 baseline 即 exit 1。
# 指标回落不自动收紧 baseline；收紧必须显式 --write-baseline 并在台账记账。
#
# 用法：./scripts/check-protocol-surface.sh [--strict] [--write-baseline]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROTO="desktop/native/gather-core/Sources/GatherProtocol"
CORE_SOURCES="desktop/native/gather-core/Sources"
APP_SOURCES="desktop/native/gather-app/Sources"
BASELINE="docs/protocol-surface-baseline.json"

STRICT=0
WRITE_BASELINE=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --write-baseline) WRITE_BASELINE=1 ;;
    -h|--help)
      sed -n '2,29p' "$0"
      exit 0
      ;;
    *)
      echo "check-protocol-surface: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$PROTO" ]; then
  echo "check-protocol-surface: FAIL — 缺少 $PROTO" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

find "$PROTO" -type f -name '*.swift' | LC_ALL=C sort > "$TMP/proto-files"
find "$CORE_SOURCES/GatherPersistence" "$CORE_SOURCES/GatherAnalysis" \
     "$CORE_SOURCES/GatherDomain" "$APP_SOURCES" \
     -type f -name '*.swift' 2>/dev/null | LC_ALL=C sort > "$TMP/prod-files"

proto_file_n=$(wc -l < "$TMP/proto-files" | tr -d ' ')
proto_line_n=$(while IFS= read -r f; do cat "$f"; done < "$TMP/proto-files" | wc -l | tr -d ' ')

# 顶层声明：行首必须是 public，排除缩进的嵌套类型。
grep -hE '^public (struct|enum|indirect enum|final class|class|protocol|actor) [A-Za-z_][A-Za-z0-9_]*' \
  $(cat "$TMP/proto-files") > "$TMP/decls" || true
sed -E 's/^public (struct|enum|indirect enum|final class|class|protocol|actor) ([A-Za-z_][A-Za-z0-9_]*).*/\2/' \
  "$TMP/decls" | LC_ALL=C sort > "$TMP/type-names"
public_types=$(wc -l < "$TMP/type-names" | tr -d ' ')
public_declarations=$(grep -hE '^[[:space:]]*public[[:space:]]' $(cat "$TMP/proto-files") | wc -l | tr -d ' ')

# 每个类型名的声明次数（顶层同名不应出现；防御性保留）。
awk '{ print $1 }' "$TMP/type-names" | LC_ALL=C sort | uniq -c > "$TMP/decl-counts"

# 代码语料：Protocol + 生产 Sources。剥离 //、/* */、普通字符串和三引号字符串。
{
  cat "$TMP/proto-files"
  cat "$TMP/prod-files"
} | xargs -n 200 awk '
BEGIN { inblock = 0; instr = 0; intriple = 0 }
{
  line = $0; out = ""; i = 1; n = length(line)
  while (i <= n) {
    c = substr(line, i, 1); two = substr(line, i, 2); three = substr(line, i, 3)
    if (inblock) {
      if (two == "*/") { inblock = 0; i += 2 } else { i++ }
    } else if (intriple) {
      if (three == "\"\"\"") { intriple = 0; i += 3 } else { i++ }
    } else if (instr) {
      if (c == "\\") { i += 2 }
      else if (c == "\"") { instr = 0; i++ }
      else { i++ }
    } else if (three == "\"\"\"") {
      intriple = 1; i += 3
    } else if (two == "//") {
      break
    } else if (two == "/*") {
      inblock = 1; i += 2
    } else if (c == "\"") {
      instr = 1; i++
    } else {
      out = out c; i++
    }
  }
  print out
}
' > "$TMP/code.txt"

grep -oE '[A-Za-z_][A-Za-z0-9_]*' "$TMP/code.txt" | LC_ALL=C sort | uniq -c > "$TMP/freq" || true

: > "$TMP/zero"
zero_reference_types=0
while IFS= read -r name; do
  decl_n=$(awk -v n="$name" '$2 == n { print $1; exit }' "$TMP/decl-counts")
  total_n=$(awk -v n="$name" '$2 == n { print $1; exit }' "$TMP/freq")
  [ -n "$decl_n" ] || decl_n=1
  [ -n "$total_n" ] || total_n=0
  if [ $((total_n - decl_n)) -le 0 ]; then
    printf '%s\n' "$name" >> "$TMP/zero"
    zero_reference_types=$((zero_reference_types + 1))
  fi
done < "$TMP/type-names"

envelope_re='ResponseID|ResponseErrorBody|ResponseErr|ResponseOk|Response'
router_envelope_types=$(grep -cE "^public (struct|enum|indirect enum|final class|class|protocol|actor) ($envelope_re)([^A-Za-z0-9_]|$)" "$TMP/decls" 2>/dev/null || true)

baseline_value() {
  local key="$1"
  if [ ! -f "$BASELINE" ]; then
    return 1
  fi
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$BASELINE" | head -n 1
}

write_baseline() {
  mkdir -p "$(dirname "$BASELINE")"
  cat > "$BASELINE" <<JSON
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "note": "WP1 Protocol 公开面 ratchet；口径见 scripts/check-protocol-surface.sh 头注释。",
  "protocol_files": $proto_file_n,
  "protocol_lines": $proto_line_n,
  "public_types": $public_types,
  "public_declarations": $public_declarations,
  "zero_reference_types": $zero_reference_types,
  "router_envelope_types": $router_envelope_types
}
JSON
}

if [ "$WRITE_BASELINE" -eq 1 ]; then
  write_baseline
  echo "check-protocol-surface: baseline 已写入 $BASELINE"
fi

echo "check-protocol-surface:"
echo "  Protocol 文件/行          $proto_file_n / $proto_line_n"
echo "  public 类型              $public_types"
echo "  public 声明行            $public_declarations"
echo "  zero-reference 类型      $zero_reference_types"
echo "  Router 信封类型          $router_envelope_types"

if [ ! -f "$BASELINE" ]; then
  echo "check-protocol-surface: FAIL — 缺少基线 $BASELINE（先运行 --write-baseline）" >&2
  exit 2
fi

fail=0
compare_metric() {
  local key="$1" current="$2" base
  base=$(baseline_value "$key" || true)
  if [ -z "$base" ]; then
    echo "FAIL 基线缺少指标 $key" >&2
    fail=1
    return
  fi
  if [ "$current" -gt "$base" ]; then
    echo "FAIL $key = $current > baseline $base" >&2
    fail=1
  elif [ "$current" -lt "$base" ]; then
    echo "warn $key = $current < baseline $base（可 --write-baseline 收紧）"
  else
    echo "ok   $key = $current"
  fi
}

compare_metric public_types "$public_types"
compare_metric public_declarations "$public_declarations"
compare_metric zero_reference_types "$zero_reference_types"
compare_metric router_envelope_types "$router_envelope_types"

if [ -s "$TMP/zero" ]; then
  echo "零引用候选（file:line 见 WP1 盘点；此处仅列名）："
  sed 's/^/  - /' "$TMP/zero"
fi

echo "----"
if [ "$STRICT" -eq 1 ]; then
  if [ "$fail" -ne 0 ]; then
    echo "check-protocol-surface: FAILED (--strict)" >&2
    exit 1
  fi
  echo "check-protocol-surface: OK (--strict)"
else
  if [ "$fail" -ne 0 ]; then
    echo "check-protocol-surface: WARN (warning mode; 使用 --strict 作为硬门禁)"
  else
    echo "check-protocol-surface: PASS (warning mode; 使用 --strict 作为硬门禁)"
  fi
fi
