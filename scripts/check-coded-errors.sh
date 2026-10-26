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
# 用法：./scripts/check-coded-errors.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CORE="desktop/native/gather-core/Sources"
APP="desktop/native/gather-app/Sources"

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