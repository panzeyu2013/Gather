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
#                           生产 = GatherPersistence/GatherDelivery/GatherAnalysis/
#                           GatherApplication + gather-app/Sources；Protocol 内按标识符计数并排除声明
#                           本身；注释和字符串已剥离。Tests 不计入引用（只靠
#                           ContractTests 存活的 DTO 仍算零引用，随之删除）。
#   router_envelope_types   Router 时代 JSON 信封类型声明数：
#                           ResponseID / ErrorDetail / ResponseErrorBody /
#                           ResponseOk / ResponseErr / Response<T>。目标 0。
#
# 基线：docs/baselines/surface-baseline.json（schema 2，gates.protocol-surface / gates.protocol-surface-modules 两节；--write-baseline 原子重写两节，上涨需 --allow-growth）。
# 默认 warning 模式 exit 0；--strict 时任一指标高于 baseline 即 exit 1。
# 指标回落不自动收紧 baseline；收紧必须显式 --write-baseline 并在台账记账。
#
# 用法：./scripts/check-protocol-surface.sh [--strict] [--write-baseline [--allow-growth]]
#   --write-baseline 只允许持平或收紧；指标上涨必须同时给 --allow-growth 并在台账记账。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROTO="desktop/native/gather-core/Sources/GatherProtocol"
CORE_SOURCES="desktop/native/gather-core/Sources"
APP_SOURCES="desktop/native/gather-app/Sources"
BASELINE="docs/baselines/surface-baseline.json"
SURFACE_GATE="protocol-surface"
MODULES_GATE="protocol-surface-modules"
BASELINE_NOTE="公开面 ratchet（schema 2，双 section）：gates.protocol-surface 为 WP1 Protocol 公开面（protocol_files/protocol_lines 为信息字段，不参与 compare_metric）；gates.protocol-surface-modules 为模块级 public 面（顶层 public 类型 + public 声明行）。口径见 scripts/check-protocol-surface.sh 头注释。"

STRICT=0
WRITE_BASELINE=0
ALLOW_GROWTH=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --write-baseline) WRITE_BASELINE=1 ;;
    --allow-growth) ALLOW_GROWTH=1 ;;
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

# ── 扫描（2026-11-18 性能轮：单 python3 进程一次读盘完成全部计数）────────────
# 口径与旧 perl/awk 流水线逐字节等价（迁移时用旧实现对全量语料比对：token 计数表
# 14,379 项完全一致，五项指标与五项模块指标相同）。#1：GatherMetadataIO（XMP/JPEG/
# IPTC 写盘）也是生产代码，必须计入引用面，否则把文件搬去新 target 会让原本有引用的
# DTO 变成"零引用"假阳性。
python3 - "$TMP" "$PROTO" "$CORE_SOURCES" "$APP_SOURCES" <<'PY'
import re
import sys
from collections import Counter
from pathlib import Path

TMP = Path(sys.argv[1])
PROTO = Path(sys.argv[2])
CORE = Path(sys.argv[3])
APP = Path(sys.argv[4])
MODULES = ("GatherPersistence", "GatherDelivery", "GatherAnalysis", "GatherApplication", "GatherMetadataIO")

# 顶层声明：行首必须是 public，排除缩进的嵌套类型。
DECL_RE = re.compile(r"^public (?:struct|enum|indirect enum|final class|class|protocol|actor) ([A-Za-z_][A-Za-z0-9_]*)", re.M)
# public 声明行：行首（可缩进）public + 空白（等价旧 grep '^[[:space:]]*public[[:space:]]'）。
DECL_LINE_RE = re.compile(r"^[ \t]*public[ \t]", re.M)
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# raw string 剥离（等价旧 perl：先普通 #"..."#，再三引号 #"""..."""#）。
RAW_STRING_RE = re.compile(r'#+"(?:[^"\\]|\\.)*"#+', re.S)
RAW_TRIPLE_RE = re.compile(r'#+"""(?s:.*?)"""#+', re.S)
SPECIAL_RE = re.compile(r'["/]')
ENVELOPE = {"ResponseID", "ResponseErrorBody", "ResponseErr", "ResponseOk", "Response"}


def strip_file(text):
    """剥离 raw string、注释与字符串（保留换行；状态机口径同旧 awk 实现）。"""
    text = RAW_STRING_RE.sub("", text)
    text = RAW_TRIPLE_RE.sub("", text)
    out = []
    pos = 0
    n = len(text)
    # 0 code / 1 line comment / 2 block comment / 3 string / 4 triple string
    state = 0
    while pos < n:
        if state == 0:
            m = SPECIAL_RE.search(text, pos)
            if m is None:
                out.append(text[pos:])
                break
            j = m.start()
            if j > pos:
                out.append(text[pos:j])
            if text[j] == '"':
                if text.startswith('"""', j):
                    state, pos = 4, j + 3
                else:
                    state, pos = 3, j + 1
            elif text.startswith("//", j):
                state, pos = 1, j + 2
            elif text.startswith("/*", j):
                state, pos = 2, j + 2
            else:
                out.append("/")
                pos = j + 1
        elif state == 1:
            k = text.find("\n", pos)
            if k < 0:
                break
            out.append("\n")
            pos = k + 1
            state = 0
        elif state == 2:
            k = text.find("*/", pos)
            if k < 0:
                out.append("\n" * text.count("\n", pos))
                break
            out.append("\n" * text.count("\n", pos, k))
            pos = k + 2
            state = 0
        elif state == 3:
            q = pos
            while True:
                q = text.find('"', q)
                if q < 0:
                    out.append("\n" * text.count("\n", pos))
                    pos = n
                    break
                b = q - 1
                while b >= pos and text[b] == "\\":
                    b -= 1
                if (q - 1 - b) % 2 == 0:  # 偶数个反斜杠 = 字符串结束
                    out.append("\n" * text.count("\n", pos, q))
                    pos = q + 1
                    state = 0
                    break
                q += 1
        else:
            k = text.find('"""', pos)
            if k < 0:
                out.append("\n" * text.count("\n", pos))
                pos = n
            else:
                out.append("\n" * text.count("\n", pos, k))
                pos = k + 3
                state = 0
    return "".join(out)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


def swift_files(root):
    return sorted(root.rglob("*.swift"))


proto_files = swift_files(PROTO)
prod_files = []
for module in MODULES:
    prod_files.extend(swift_files(CORE / module))
prod_files.extend(swift_files(APP))
proto_texts = [read(p) for p in proto_files]
decl_names = []
public_declarations = 0
for text in proto_texts:
    decl_names.extend(DECL_RE.findall(text))
    public_declarations += len(DECL_LINE_RE.findall(text))
decl_counts = Counter(decl_names)
token_counts = Counter()
for path in proto_files:
    token_counts.update(TOKEN_RE.findall(strip_file(read(path))))
for path in prod_files:
    token_counts.update(TOKEN_RE.findall(strip_file(read(path))))
zero = [name for name in sorted(decl_counts)
        if token_counts.get(name, 0) - decl_counts[name] <= 0]
metrics = {
    "proto_file_n": len(proto_files),
    "proto_line_n": sum(text.count("\n") for text in proto_texts),
    "public_types": len(decl_names),
    "public_declarations": public_declarations,
    "zero_reference_types": len(zero),
    "router_envelope_types": sum(decl_counts[name] for name in ENVELOPE if name in decl_counts),
}
(TMP / "metrics.env").write_text(
    "".join("%s=%d\n" % item for item in metrics.items()), encoding="utf-8")
(TMP / "zero").write_text("".join(name + "\n" for name in zero), encoding="utf-8")
module_metrics = []
for module in MODULES:
    directory = CORE / module
    if not directory.exists():
        continue
    types = 0
    decls = 0
    for path in swift_files(directory):
        text = read(path)
        types += len(DECL_RE.findall(text))
        decls += len(DECL_LINE_RE.findall(text))
    lower = module.lower()
    module_metrics.append("public_types_%s %d" % (lower, types))
    module_metrics.append("public_declarations_%s %d" % (lower, decls))
(TMP / "module-metrics").write_text(
    "\n".join(module_metrics) + ("\n" if module_metrics else ""), encoding="utf-8")
PY
# 指标由指标文件提供；先显式置默认值，既防 set -u 又便于 shellcheck 识别赋值。
proto_file_n=0
proto_line_n=0
public_types=0
public_declarations=0
zero_reference_types=0
router_envelope_types=0
. "$TMP/metrics.env"

# 评审 R4-F22：扫描量下限守卫，防止文件清单为空/被截断时把 0 当合规。
if [ "$proto_file_n" -lt 110 ] || [ "$public_types" -lt 513 ]; then
  echo "FAIL 扫描量异常：proto_file_n=$proto_file_n public_types=$public_types" >&2
  exit 2
fi

# ── 基线读写（2026-11-18 迁移：schema 2 单文件 docs/baselines/surface-baseline.json）──
# 旧布局是两份独立 JSON（Protocol 总量 + 模块级各一份）；现合并为一份基线的两个 gate section，
# --write-baseline 一次性原子读-改-写。
# 读取用一次 python3 内联解析（旧实现按 key 逐个 sed），key 名与比较语义保持不变。
load_baseline_kv() {
  : > "$TMP/baseline-kv"
  [ -f "$BASELINE" ] || return 0
  python3 - "$BASELINE" > "$TMP/baseline-kv" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write("check-protocol-surface: FAIL — 基线 JSON 解析失败：%s\n" % exc)
    sys.exit(2)
gates = data.get("gates") if isinstance(data, dict) else None
if not isinstance(gates, dict):
    sys.exit(0)
for gate in ("protocol-surface", "protocol-surface-modules"):
    section = gates.get(gate)
    if not isinstance(section, dict):
        print("%s\t__section_missing__" % gate)
        continue
    for key, value in section.items():
        if isinstance(value, bool) or not isinstance(value, int):
            continue
        print("%s\t%s\t%d" % (gate, key, value))
PY
}

baseline_value() {
  local gate="$1" key="$2"
  awk -F '\t' -v gate="$gate" -v key="$key" '$1 == gate && $2 == key { print $3; exit }' \
    "$TMP/baseline-kv"
}

baseline_section_missing() {
  awk -F '\t' -v gate="$1" '$1 == gate && $2 == "__section_missing__" { found = 1 } END { exit found ? 0 : 1 }' \
    "$TMP/baseline-kv"
}

write_baseline() {
  mkdir -p "$(dirname "$BASELINE")"
  # 新值交给 python3 合并：保留 schema/note 等语义字段与其它 gate section，只替换本门禁两节；
  # 同目录临时文件 + os.replace 保证原子写（失败不会留下半截 JSON）。
  CHECK_PROTO_FILE_N="$proto_file_n" \
    CHECK_PROTOCOL_LINE_N="$proto_line_n" \
    CHECK_PUBLIC_TYPES="$public_types" \
    CHECK_PUBLIC_DECLARATIONS="$public_declarations" \
    CHECK_ZERO_REFERENCE_TYPES="$zero_reference_types" \
    CHECK_ROUTER_ENVELOPE_TYPES="$router_envelope_types" \
    python3 - "$BASELINE" "$TMP/module-metrics" "$BASELINE_NOTE" <<'PY'
import json
import os
import sys
import tempfile

baseline, module_metrics, note = sys.argv[1], sys.argv[2], sys.argv[3]
new = {
    "protocol-surface": {
        "protocol_files": int(os.environ["CHECK_PROTO_FILE_N"]),
        "protocol_lines": int(os.environ["CHECK_PROTOCOL_LINE_N"]),
        "public_types": int(os.environ["CHECK_PUBLIC_TYPES"]),
        "public_declarations": int(os.environ["CHECK_PUBLIC_DECLARATIONS"]),
        "zero_reference_types": int(os.environ["CHECK_ZERO_REFERENCE_TYPES"]),
        "router_envelope_types": int(os.environ["CHECK_ROUTER_ENVELOPE_TYPES"]),
    },
    "protocol-surface-modules": {},
}
with open(module_metrics, encoding="utf-8") as fh:
    for line in fh:
        if line.strip():
            key, value = line.split()
            new["protocol-surface-modules"][key] = int(value)
data = {}
if os.path.exists(baseline):
    with open(baseline, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        sys.stderr.write("check-protocol-surface: FAIL — 基线不是 JSON 对象：%s\n" % baseline)
        sys.exit(2)
data["schema"] = 2
data.setdefault("note", note)
gates = data.get("gates")
if not isinstance(gates, dict):
    gates = {}
    data["gates"] = gates
for name in ("protocol-surface", "protocol-surface-modules"):
    gates[name] = new[name]
fd, tmp_path = tempfile.mkstemp(prefix=".surface-baseline.", dir=os.path.dirname(baseline) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.chmod(tmp_path, 0o644)  # mkstemp 默认 0600；与旧实现 cat > 的 0644 保持一致
os.replace(tmp_path, baseline)
PY
}

# 门禁自证（评审 P2）：--write-baseline 曾可把任意膨胀一条命令洗白。现在要求"涨"必须
# 显式批准：先比一遍旧基线，任何指标上涨都拒绝重写，除非同时给 --allow-growth。
load_baseline_kv
if [ "$WRITE_BASELINE" -eq 1 ] && [ -f "$BASELINE" ] && [ "$ALLOW_GROWTH" -eq 0 ]; then
  if ! baseline_section_missing "$SURFACE_GATE"; then
    grew=0
    for kv in "public_types:$public_types" \
              "public_declarations:$public_declarations" \
              "zero_reference_types:$zero_reference_types" \
              "router_envelope_types:$router_envelope_types"; do
      key=$(printf '%s' "$kv" | cut -d: -f1)
      cur=$(printf '%s' "$kv" | cut -d: -f2-)
      base=$(baseline_value "$SURFACE_GATE" "$key")
      if [ -z "$base" ]; then
        echo "  旧基线缺 key：$key（拒绝静默补写；先补 key 或加 --allow-growth）" >&2
        exit 1
      fi
      if [ "$cur" -gt "$base" ]; then
        echo "  涨：$key $base -> $cur" >&2
        grew=1
      fi
    done
    if [ "$grew" -ne 0 ]; then
      echo "check-protocol-surface: REFUSED — 基线膨胀必须显式批准" >&2
      echo "  公开面只能收紧；确需扩张时加 --allow-growth，并在 docs/cleanup-backlog.md 台账记账。" >&2
      exit 1
    fi
  fi
  if ! baseline_section_missing "$MODULES_GATE"; then
    grew=0
    while read -r k v; do
      base=$(baseline_value "$MODULES_GATE" "$k")
      if [ -z "$base" ]; then
        echo "  模块基线缺 key：$k（拒绝静默补写；先补 key 或加 --allow-growth）" >&2
        exit 1
      fi
      if [ "$v" -gt "$base" ]; then echo "  涨：$k $base -> $v" >&2; grew=1; fi
    done < "$TMP/module-metrics"
    if [ "$grew" -ne 0 ]; then
      echo "check-protocol-surface: REFUSED — 模块公开面膨胀必须显式批准（--allow-growth + 台账）" >&2
      exit 1
    fi
  fi
fi

if [ "$WRITE_BASELINE" -eq 1 ]; then
  write_baseline
  echo "check-protocol-surface: baseline 已写入 $BASELINE（$SURFACE_GATE + $MODULES_GATE）"
  load_baseline_kv  # 重读刚写入的基线，后续比较按新值（--write-baseline 语义与旧版一致）
fi

echo "check-protocol-surface:"
echo "  Protocol 文件/行          $proto_file_n / $proto_line_n"
echo "  public 类型              $public_types"
echo "  public 声明行            $public_declarations"
echo "  zero-reference 类型      $zero_reference_types"
echo "  Router 信封类型          $router_envelope_types"

if [ ! -f "$BASELINE" ] || baseline_section_missing "$SURFACE_GATE"; then
  echo "check-protocol-surface: FAIL — 缺少基线 $BASELINE（先运行 --write-baseline）" >&2
  exit 2
fi

fail=0
compare_metric() {
  local gate="$1" key="$2" current="$3" base
  base=$(baseline_value "$gate" "$key")
  if [ -z "$base" ]; then
    echo "FAIL 基线缺少指标 $key" >&2
    fail=1
    return
  fi
  if [ "$current" -gt "$base" ]; then
    echo "FAIL $key = $current > baseline $base" >&2
    fail=1
  elif [ "$current" -lt "$base" ]; then
    echo "warn $key = $current < baseline ${base}（可 --write-baseline 收紧）"
  else
    echo "ok   $key = $current"
  fi
}

compare_metric "$SURFACE_GATE" public_types "$public_types"
compare_metric "$SURFACE_GATE" public_declarations "$public_declarations"
compare_metric "$SURFACE_GATE" zero_reference_types "$zero_reference_types"
compare_metric "$SURFACE_GATE" router_envelope_types "$router_envelope_types"

# ── 模块级 ratchet（评审补）──────────────────────────────────────────────
# 模块指标与协议面同住 surface-baseline.json 的 gates.protocol-surface-modules（schema 2），
# key 名保持旧口径（public_types_<模块小写> / public_declarations_<模块小写>）。
if baseline_section_missing "$MODULES_GATE"; then
  echo "check-protocol-surface: FAIL — 缺少模块基线 $BASELINE（先运行 --write-baseline）" >&2
  exit 2
fi
echo "  模块 public 面（类型 / 声明）："
while read -r k v; do
  base=$(baseline_value "$MODULES_GATE" "$k")
  if [ -z "$base" ]; then
    echo "FAIL 模块基线缺少指标 $k" >&2; fail=1
  elif [ "$v" -gt "$base" ]; then
    echo "FAIL $k = $v > baseline $base" >&2; fail=1
  elif [ "$v" -lt "$base" ]; then
    echo "warn $k = $v < baseline ${base}（可 --write-baseline 收紧）"
  else
    echo "ok   $k = $v"
  fi
done < "$TMP/module-metrics"

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
