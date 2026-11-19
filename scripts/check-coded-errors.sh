#!/usr/bin/env bash
# 错误码类型化门禁（P1-2 / R1，批 1 加固）。
#
# 规则：
#   1. **全仓 Sources**（core + app）不得再抛「裸码字符串」DBError.message("<CODE>")
#      ——域错误必须 throw PersistenceError(code:)，上层经 CodedError 映射。
#      支持跨行写法（message( 换行后紧跟 "CODE"）。
#   2. **全仓 Sources** 的 GatherErrorCode(rawValue:) 字符串反解必须显式标注
#      “allow: string-code”，且标记必须与命中行**同一文件 ±2 行内**（防止一个标记
#      覆盖相邻多条反解）。
#      现存例外：ExportServiceError / WritebackServiceError 的 description 与码同源、
#      JobServiceError.jobFailed 的落库文本（job.error 列是字符串）。
#
# --self-test：负样本自测（mktemp fixture，不写仓库）。把本脚本原样复制进临时 fixture
# 仓库：DBError.message("X") 裸码 → FAIL；PersistenceError(code:) 合法写法 → PASS
# （另含整行注释里的裸码不计、未标注字符串反解 FAIL 两类负样本）。
# 用法：./scripts/check-coded-errors.sh [--self-test]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE="desktop/native/gather-core/Sources"
APP="desktop/native/gather-app/Sources"

# ---------------------------------------------------------------------------
# --self-test：负样本自测（mktemp fixture，不写仓库；fixture 不达预期即 exit 1）
#   做法：把本脚本原样复制进临时 fixture 仓库，用同一份判定逻辑跑合成树，断言：
#     1) 全仓只有 PersistenceError(code:) / 带 allow 标注的反解 → PASS（exit 0）
#     2) DBError.message("X") 裸码 → FAIL（exit 1）；整行注释里的裸码不计
#     3) GatherErrorCode(rawValue:) 未标注 → FAIL（exit 1）
# ---------------------------------------------------------------------------
SELFTEST_OUT=""
SELFTEST_TMP=""
SELFTEST_PROG="check-coded-errors"
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

# selftest_filler <目录> <个数>：生成不匹配任何规则的占位 Swift 文件（满足扫描量下限）
selftest_filler() {
  local dir="$1" n="$2" i=0
  mkdir -p "$dir"
  while [ "$i" -lt "$n" ]; do
    printf '// self-test 占位（无裸码、无反解）\nlet filler_%s = 0\n' "$i" > "$dir/F$i.swift"
    i=$((i + 1))
  done
}

selftest_cleanup() {
  if [ -n "$SELFTEST_TMP" ]; then
    rm -rf "${SELFTEST_TMP:?}"
  fi
}

self_test() {
  local tmpbase="${TMPDIR:-/tmp}" fx core gate
  tmpbase="${tmpbase%/}"
  SELFTEST_TMP=$(mktemp -d "${tmpbase}/check-coded-errors-selftest.XXXXXX") ||
    selftest_die "mktemp 创建临时目录失败"
  trap selftest_cleanup EXIT
  fx="$SELFTEST_TMP/fixture"
  core="$fx/desktop/native/gather-core/Sources"
  gate="$fx/scripts/$SELFTEST_PROG.sh"

  # fixture 仓库：core + app 扫描根 + 足够多 Swift 文件（门禁有 <300 的扫描量下限）。
  mkdir -p "$fx/scripts" "$core" "$fx/desktop/native/gather-app/Sources"
  cp "$SELFTEST_SELF" "$gate"
  selftest_filler "$core/Filler" 300
  cat > "$core/ErrorFixtures.swift" <<'SWIFT'
// self-test fixture：整行注释里的裸码不计入口径
// DBError.message("COMMENTED_OUT")

func throwTyped() throws {
    throw PersistenceError(code: .internalError)
}

func decodeMarked(_ raw: String) -> GatherErrorCode? {
    // allow: string-code —— self-test fixture：反解已显式标注（同一文件 ±4 行内）
    return GatherErrorCode(rawValue: raw)
}
SWIFT

  # 断言 1：合法写法 → PASS（注释里的裸码若被误报，此处即 FAIL）。
  selftest_expect 0 "PersistenceError(code:) 合法写法应 PASS" "$gate"
  selftest_contains "0 处 DBError.message" "注释里的裸码不应计入"
  selftest_contains "1 处反解均已标注" "带 allow 标注的反解应计为已标注"

  # 断言 2：DBError.message("X") 裸码 → FAIL。
  printf 'func throwBare() throws {\n    throw DBError.message("SELFTEST_BARE")\n}\n' \
    > "$core/BareCodeFixture.swift"
  selftest_expect 1 "DBError.message 裸码应 FAIL" "$gate"
  selftest_contains "SELFTEST_BARE" "FAIL 行应点名裸码"
  rm -f "$core/BareCodeFixture.swift"

  # 断言 3：GatherErrorCode(rawValue:) 未标注 → FAIL。
  printf 'func decodeRaw(_ raw: String) -> GatherErrorCode? {\n    return GatherErrorCode(rawValue: raw)\n}\n' \
    > "$core/UnmarkedReverseFixture.swift"
  selftest_expect 1 "未标注字符串反解应 FAIL" "$gate"
  selftest_contains "未标注" "FAIL 行应提示未标注"

  echo "$SELFTEST_PROG: self-test OK（PersistenceError(code:) PASS；DBError.message 裸码/未标注反解 FAIL；3 条断言）"
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
    echo "check-coded-errors: --self-test 只接受单独使用（不与其他参数混跑）" >&2
    exit 2
  fi
  self_test
  exit 0
fi


echo "check-coded-errors:"
python3 - "$CORE" "$APP" <<'PY'
import pathlib
import re
import sys

bases = [pathlib.Path(p) for p in sys.argv[1:]]
fail = False

# 扫描根守卫：目录消失/改名不得静默 0 命中（Gate fail-open，复审 P1）。
total = 0
for base in bases:
    if not base.is_dir():
        print(f"FAIL   缺少扫描根：{base}")
        fail = True
    else:
        total += sum(1 for _ in base.rglob("*.swift"))
if total < 300:
    print(f"FAIL   Sources 只扫到 {total} 个 Swift 文件（<300），疑似根路径错误")
    fail = True

# 1) DBError.message("<CODE>")：允许换行/空白，但码必须是完整字符串。
bare = re.compile(r'DBError\.message\s*\(\s*"([A-Z][A-Z0-9_]*)"')
hits = []
for base in bases:
    for path in sorted(base.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in bare.finditer(text):
            line = text[: match.start()].count("\n") + 1
            source_line = text.splitlines()[line - 1].strip()
            if source_line.startswith(("//", "/*", "*")):
                continue
            hits.append(f"{path}:{line}: {match.group(1)}")

if hits:
    print("FAIL   全仓仍有裸码字符串（应改 throw PersistenceError(code:) / CodedError）：")
    for hit in hits:
        print(f"  - {hit}")
    fail = True
else:
    print("ok     0 处 DBError.message(<CODE>)（core + app）")

# 2) 字符串反解必须带 allow 标记（同一文件 ±4 行内）。
raw = re.compile(r'GatherErrorCode\(rawValue:')
unmarked = []
marked = []
for base in bases:
    for path in sorted(base.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        lines = text.splitlines()
        for match in raw.finditer(text):
            line = text[: match.start()].count("\n") + 1
            if lines[line - 1].strip().startswith(("//", "/*", "*")):
                continue
            window = "\n".join(lines[max(0, line - 3): line + 2])
            if "allow: string-code" in window:
                marked.append(f"{path}:{line}")
            else:
                unmarked.append(f"{path}:{line}")

if unmarked:
    print("FAIL   未标注的字符串反解（需在命中行 ±4 行内写 // allow: string-code 并说明理由）：")
    for hit in unmarked:
        print(f"  - {hit}")
    fail = True
else:
    print(f"ok     {len(marked)} 处反解均已标注")
    for hit in marked:
        print(f"       已标注：{hit}")

sys.exit(1 if fail else 0)
PY
status=$?
echo "----"
if [ "$status" -ne 0 ]; then
  echo "check-coded-errors: FAILED"
  exit 1
fi
echo "check-coded-errors: OK"
