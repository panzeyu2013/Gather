#!/usr/bin/env python3
# G0-G5 结构门禁共享实现（2026-11-18 架构评审 Wave 4；2026-11-18 门禁基线精简）。
#
# 六个 scripts/check-*.sh 是薄包装，统一调用本文件：
#     python3 scripts/check-structural-gates.py <gate> [参数]
# gate 取值：lock-order / import-graph / module-size /
#           concurrency-whitelist / layer-symbols / public-surface-app
#
# 六道门禁共用一份基线 docs/baselines/structure-baseline.json（schema=2）：
#   { "schema": 2, "note": "...", "gates": { "<gate>": { ...旧独立文件字段... } } }
# 每个 gate 一个 section，语义与旧的 docs/<gate>-baseline.json 一致。
#
# 统一参数（六道门禁一致；默认 warning 模式 exit 0，CI 一律 --strict）：
#   --strict          任一违规/上涨即 exit 1（默认 warning 模式 exit 0）
#   --write-baseline  只原子更新统一基线里本 gate 的 section（读-改-写）；默认拒绝上涨/新增条目
#   --allow-growth    与 --write-baseline 连用，显式批准上涨/新增条目
#   --self-test       用 mktemp 临时 fixture 做负样本自测（不写仓库）
#
# 只读、Linux 可跑、只依赖 python3 标准库；每道门禁都有扫描量下限，
# 路径/解析器失效时 fail closed（exit 2），不会静默 0 命中。
from __future__ import annotations

import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "desktop" / "native" / "gather-core"
APP = ROOT / "desktop" / "native" / "gather-app"
CORE_SRC = CORE / "Sources"
APP_SRC = APP / "Sources"
DOCS = ROOT / "docs"

STRUCTURE_BASELINE = DOCS / "baselines" / "structure-baseline.json"

# gate -> (统一基线文件, gates 下的 section 名)
BASELINES = {
    "lock-order": (STRUCTURE_BASELINE, "lock-order"),
    "import-graph": (STRUCTURE_BASELINE, "import-graph"),
    "module-size": (STRUCTURE_BASELINE, "module-size"),
    "concurrency-whitelist": (STRUCTURE_BASELINE, "concurrency-whitelist"),
    "layer-symbols": (STRUCTURE_BASELINE, "layer-symbols"),
    "public-surface-app": (STRUCTURE_BASELINE, "public-surface-app"),
}

STRUCTURE_NOTE = (
    "G0–G5 结构门禁共享基线（schema 2）：gates.<gate> 每个 section 对应一道门禁，"
    "语义与旧的 docs/<gate>-baseline.json 独立文件一致（schema 版本上提到顶层，不写时间戳，减少重钉 diff 噪声）。"
    "--write-baseline 只原子更新对应 section 并保留其他 gate 数据；"
    "默认拒绝上涨/新增条目，显式 --allow-growth 并在 docs/cleanup-backlog.md 记账。"
)

PROG_MAP = {
    "lock-order": "check-lock-order",
    "import-graph": "check-import-graph",
    "module-size": "check-module-size",
    "concurrency-whitelist": "check-concurrency-whitelist",
    "layer-symbols": "check-layer-symbols",
    "public-surface-app": "check-public-surface-app",
}

PROG = "check-structural-gates"

USAGE = """用法：scripts/check-<gate>.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]

  --strict          任一违规/上涨即 exit 1（默认 warning 模式 exit 0）
  --write-baseline  只原子更新 docs/baselines/structure-baseline.json 里本 gate 的 section；默认拒绝上涨/新增条目
  --allow-growth    与 --write-baseline 连用，显式批准上涨/新增条目
  --self-test       用 mktemp 临时 fixture 做负样本自测（不写仓库）
"""


def emit(msg):
    print("%s: %s" % (PROG, msg))


def err(msg):
    print("%s: %s" % (PROG, msg), file=sys.stderr)


def die(msg):
    err("FAIL " + msg)
    sys.exit(2)


def rel(path):
    try:
        return str(Path(path).resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        die("无法读取 %s：%s" % (rel(path), exc))


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def swift_files(root):
    root = Path(root)
    if not root.is_dir():
        die("缺少扫描根：%s" % rel(root))
    return sorted(p for p in root.rglob("*.swift") if "/.build/" not in str(p))


def _mask_span(buf, start, end):
    total = len(buf)
    for k in range(start, min(end, total)):
        if buf[k] != "\n":
            buf[k] = " "


def mask_comments(text):
    """只遮罩注释（保留字符串字面量）。供 Package.swift 解析用。"""
    if "//" not in text and "/*" not in text:
        return text
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            _mask_span(out, i, j)
            i = j
            continue
        if text.startswith("/*", i):
            depth = 0
            j = i
            while j < n:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                    continue
                if text.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                    continue
                j += 1
            _mask_span(out, i, j)
            i = j
            continue
        if text[i] == '"':
            if text.startswith('"""', i):
                j = text.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"' or text[j] == "\n":
                    j += 1
                    break
                j += 1
            i = j
            continue
        i += 1
    return "".join(out)


_TRIPLE_STR_RE = re.compile(r'"""(?:\\\\.|(?!""").)*"""', re.S)
# 转义分支 = 一个反斜杠 + 任意字符（正则写作 \\. ，即源码里的 r'\\.'）。
# 旧写法的转义分支是「两个反斜杠 + 任意字符」，而字符类 [^"\\\n] 又把单个
# 反斜杠排除在外 → 含 \" 的字面量整条匹配不上：字符串在 \" 处提前结束，里面的 }
# 露成代码，block_body 在那里闭合、后续成员全部丢失（2026-11-24 修，P2；
# 负样本见 PUBLIC_FIXTURE_STRING_MASK）。
_STR_RE = re.compile(r'"(?:\\.|[^"\\\n])*"')
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
_LINE_COMMENT_RE = re.compile(r"//[^\n]*")


def _blank(s):
    return "".join(c if c == "\n" else " " for c in s)


def mask_code(text):
    """遮罩注释与字符串字面量：符号级扫描用（字符串里的标记/大括号不算代码）。"""
    if "//" not in text and "/*" not in text and '"' not in text:
        return text
    out = _TRIPLE_STR_RE.sub(lambda m: _blank(m.group(0)), text)
    out = _STR_RE.sub(lambda m: _blank(m.group(0)), out)
    out = _BLOCK_COMMENT_RE.sub(lambda m: _blank(m.group(0)), out)
    out = _LINE_COMMENT_RE.sub(lambda m: _blank(m.group(0)), out)
    return out


def balanced(text, open_index, opener="(", closer=")"):
    depth = 0
    for i in range(open_index, len(text)):
        ch = text[i]
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return i
    return -1


def block_body(text, start):
    """从 start 起找第一个 { 并返回配对花括号内的 body；找不到返回 None。"""
    brace = text.find("{", start)
    if brace < 0:
        return None
    close = balanced(text, brace, "{", "}")
    if close < 0:
        return None
    return text[brace + 1:close]


def parse_args(argv):
    opts = {"strict": False, "write": False, "allow_growth": False, "self_test": False}
    for arg in argv:
        if arg == "--strict":
            opts["strict"] = True
        elif arg == "--write-baseline":
            opts["write"] = True
        elif arg == "--allow-growth":
            opts["allow_growth"] = True
        elif arg == "--self-test":
            opts["self_test"] = True
        elif arg in ("-h", "--help"):
            print(USAGE, end="")
            sys.exit(0)
        else:
            die("未知参数：%s（支持 --strict / --write-baseline / --allow-growth / --self-test）" % arg)
    return opts


def baseline_label(gate):
    path, section = BASELINES[gate]
    return "%s 的 gates.%s section" % (rel(path), section)


def _read_structure_baseline():
    """读统一基线顶层；文件不存在返回 None（等价旧实现的「基线文件缺失」）。"""
    if not STRUCTURE_BASELINE.is_file():
        return None
    try:
        data = json.loads(STRUCTURE_BASELINE.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        die("无法读取 %s：%s" % (rel(STRUCTURE_BASELINE), exc))
    except json.JSONDecodeError as exc:
        die("基线 JSON 解析失败：%s（%s）" % (rel(STRUCTURE_BASELINE), exc))
    if not isinstance(data, dict):
        die("基线 JSON 顶层必须是对象：%s" % rel(STRUCTURE_BASELINE))
    gates = data.get("gates")
    if gates is not None and not isinstance(gates, dict):
        die("基线 gates 必须是对象：%s" % rel(STRUCTURE_BASELINE))
    return data


def load_baseline(gate):
    """读本 gate 的 section；文件或 section 缺失返回 None（沿用旧「缺基线」分支）。"""
    _path, section = BASELINES[gate]
    data = _read_structure_baseline()
    if data is None:
        return None
    gates = data.get("gates") or {}
    if section not in gates:
        return None
    value = gates[section]
    if not isinstance(value, dict):
        die("基线 section 必须是对象：%s（gates.%s）" % (rel(STRUCTURE_BASELINE), section))
    return value


def save_baseline(gate, section_data):
    """原子更新本 gate 的 section：读-改-写保留其他 gate 数据，写临时文件再 rename。

    顶层固定 {schema: 2, note, gates}；section 顺序按 G0–G5 固定，保证重复写入幂等。
    """
    _path, section = BASELINES[gate]
    root = _read_structure_baseline() or {}
    existing = root.get("gates") or {}
    gates = dict(existing)
    gates[section] = section_data
    ordered = {}
    for name in BASELINES:
        if name in gates:
            ordered[name] = gates[name]
    for name in sorted(set(gates) - set(BASELINES)):
        ordered[name] = gates[name]
    note = root.get("note")
    data = {
        "schema": 2,
        "note": note if isinstance(note, str) and note else STRUCTURE_NOTE,
        "gates": ordered,
    }
    STRUCTURE_BASELINE.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=str(STRUCTURE_BASELINE.parent),
                prefix="." + STRUCTURE_BASELINE.name + ".", suffix=".tmp",
                delete=False) as handle:
            tmp = Path(handle.name)
            handle.write(text)
        tmp.chmod(0o644)  # 临时文件默认 0600；与仓库其他基线保持一致
        tmp.replace(STRUCTURE_BASELINE)
    finally:
        if tmp is not None and tmp.exists():
            tmp.unlink()


class Report:
    def __init__(self, opts):
        self.opts = opts
        self.problems = []
        self.notes = []

    def problem(self, msg):
        self.problems.append(msg)

    def note(self, msg):
        self.notes.append(msg)

    def finish(self, ok_msg):
        for note in self.notes:
            print("  note " + note)
        for problem in self.problems:
            print("  FAIL " + problem, file=sys.stderr)
        if self.problems:
            if self.opts["strict"]:
                err("FAILED（%d 项；--strict）" % len(self.problems))
                return 1
            err("WARN（%d 项；--strict 时失败）" % len(self.problems))
            return 0
        emit("OK " + ok_msg)
        return 0


# ---------------------------------------------------------------- Package.swift

TARGET_RE = re.compile(r"\.(executableTarget|testTarget|target)\s*\(")
NAME_RE = re.compile(r'\bname\s*:\s*"([^"]+)"')
PATH_RE = re.compile(r'\bpath\s*:\s*"([^"]+)"')
DEPS_RE = re.compile(r"\bdependencies\s*:\s*\[")
STRING_RE = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"')
PRODUCT_RE = re.compile(r'\.product\s*\(\s*name\s*:\s*"([^"]+)"')
TARGET_DEP_RE = re.compile(r'\.target\s*\(\s*name\s*:\s*"([^"]+)"')


def find_target_name(span):
    for m in NAME_RE.finditer(span):
        prefix = span[max(0, m.start() - 30):m.start()]
        if re.search(r"\.(product|target|package)\s*\(\s*$", prefix):
            continue
        return m.group(1)
    return None


def parse_package(package_dir):
    package_dir = Path(package_dir)
    manifest = package_dir / "Package.swift"
    if not manifest.is_file():
        die("缺少 %s" % rel(manifest))
    text = mask_comments(read_text(manifest))
    targets = []
    for m in TARGET_RE.finditer(text):
        kind = m.group(1)
        paren = text.find("(", m.start())
        if paren < 0:
            continue
        close = balanced(text, paren)
        if close < 0:
            die("Package.swift target 声明括号不平衡：%s" % rel(manifest))
        span = text[paren + 1:close]
        name = find_target_name(span)
        if not name:
            continue
        path_m = PATH_RE.search(span)
        deps = set()
        dep_m = DEPS_RE.search(span)
        if dep_m:
            bracket = span.find("[", dep_m.start())
            end = balanced(span, bracket, "[", "]")
            if bracket >= 0 and end > bracket:
                dep_text = span[bracket + 1:end]
                for pattern in (STRING_RE, PRODUCT_RE, TARGET_DEP_RE):
                    for sm in pattern.finditer(dep_text):
                        deps.add(sm.group(1))
        targets.append({
            "name": name,
            "kind": kind,
            "path": path_m.group(1) if path_m else None,
            "package": package_dir,
            "deps_raw": sorted(deps),
            "dir": None,
        })
    if not targets:
        die("Package.swift 未解析到任何 target：%s" % rel(manifest))
    return targets


def target_dir(target):
    if target["path"]:
        return target["package"] / target["path"]
    base = "Tests" if target["kind"] == "testTarget" else "Sources"
    return target["package"] / base / target["name"]


def resolve_targets(packages):
    targets = []
    for package_dir in packages:
        targets.extend(parse_package(package_dir))
    names = {t["name"] for t in targets}
    if len(names) != len(targets):
        die("Package.swift 出现重复 target 声明")
    for target in targets:
        target["deps"] = sorted(d for d in target["deps_raw"] if d in names and d != target["name"])
        target["dir"] = target_dir(target)
    return targets, names

# ---------------------------------------------------------------- G0 锁序（XMP -> DB）

TRANSACTION_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*transaction\s*(?:\{|\()")
LOCK_ORDER_FORBIDDEN = [
    ("XMPFileLock", re.compile(r"\bXMPFileLock\b")),
    ("fileLock", re.compile(r"\bfileLock\b")),
    ("文件端口类型", re.compile(r"\b(?:DeliveryFilePort|XMPDeliveryFilePort|FileSystemDeliveryFilePort)\b")),
    ("文件端口调用 files.", re.compile(r"\bfiles\s*\.")),
    ("FileManager", re.compile(r"\bFileManager\b")),
    ("DeliveryTemporaryFiles", re.compile(r"\bDeliveryTemporaryFiles\b")),
    ("Task 绕过", re.compile(r"\bTask(?:\.detached)?\s*[\(\{]")),
]
FILE_LOCK_RUN_RE = re.compile(r"\bfileLock\s*\.\s*run\s*\(")


def scan_lock_order(delivery_dir):
    files = swift_files(delivery_dir)
    blocks = []
    violations = []
    run_sites = 0
    for path in files:
        masked = mask_code(read_text(path))
        run_sites += len(FILE_LOCK_RUN_RE.findall(masked))
        for m in TRANSACTION_RE.finditer(masked):
            brace = masked.find("{", m.end() - 1)
            close = balanced(masked, brace, "{", "}") if brace >= 0 else -1
            line = line_of(masked, m.start())
            if close < 0:
                violations.append({"file": rel(path), "line": line, "token": "未闭合 transaction 块"})
                continue
            body = masked[brace + 1:close]
            blocks.append({"file": rel(path), "line": line, "receiver": m.group(1)})
            for label, pattern in LOCK_ORDER_FORBIDDEN:
                for hit in pattern.finditer(body):
                    violations.append({
                        "file": rel(path),
                        "line": line_of(masked, brace + 1 + hit.start()),
                        "token": label,
                    })
    return {"files": len(files), "blocks": blocks, "run_sites": run_sites, "violations": violations}


def gate_lock_order(opts):
    if opts["self_test"]:
        return self_test_lock_order()
    delivery = CORE_SRC / "GatherDelivery"
    result = scan_lock_order(delivery)
    if result["files"] < 15:
        die("扫描量异常：GatherDelivery 只扫到 %d 个 Swift 文件（<15）" % result["files"])
    if len(result["blocks"]) < 2:
        die("扫描量异常：只识别到 %d 个 transaction 块（<2）" % len(result["blocks"]))
    baseline = load_baseline("lock-order")

    if opts["write"]:
        if result["violations"]:
            for v in result["violations"]:
                err("  违规：%s:%s 事务块内出现 %s" % (v["file"], v["line"], v["token"]))
            err("REFUSED — G0 基线只接受 0 违规；先修 DB->XMP 反向锁序")
            return 1
        data = {
            "generated_by": "scripts/check-lock-order.sh --write-baseline",
            "note": (
                "docs/delivery-lock-order.md：XMP -> DB 允许、DB -> XMP 禁止。"
                "统计 GatherDelivery 里 connection.transaction 花括号平衡块内出现的 XMPFileLock / fileLock / "
                "文件端口 / FileManager / Task 绕过；基线硬编码 0 违规。"
            ),
            "scope": "desktop/native/gather-core/Sources/GatherDelivery",
            "baseline": {
                "xmp_in_db_transaction": 0,
                "transaction_blocks": len(result["blocks"]),
                "swift_files": result["files"],
                "allowed_file_lock_run_sites": result["run_sites"],
            },
            "transaction_receivers": sorted({b["receiver"] for b in result["blocks"]}),
        }
        save_baseline("lock-order", data)
        emit("baseline 已写入 %s" % baseline_label("lock-order"))
        emit("  transaction 块 %d / Swift 文件 %d / fileLock.run 站点 %d / 违规 0"
             % (len(result["blocks"]), result["files"], result["run_sites"]))
        return 0

    if baseline is None:
        err("FAIL — 缺少 %s（先运行 --write-baseline）" % baseline_label("lock-order"))
        return 2
    rep = Report(opts)
    for v in result["violations"]:
        rep.problem(
            "%s:%s transaction 块内出现 %s（DB->XMP 反向锁序禁止；"
            "文件阶段必须在取 XMPFileLock 之后再读 DB）" % (v["file"], v["line"], v["token"]))
    base = baseline.get("baseline", {})
    base_blocks = int(base.get("transaction_blocks", 0) or 0)
    if len(result["blocks"]) < base_blocks:
        rep.note("transaction 块 %d < 基线 %d（可 --write-baseline 收紧）"
                 % (len(result["blocks"]), base_blocks))
    emit("GatherDelivery %d 文件 / %d 个 transaction 块 / %d 个 fileLock.run 站点（允许方向）"
         % (result["files"], len(result["blocks"]), result["run_sites"]))
    return rep.finish("transaction 块内 0 处 DB->XMP 反向锁序（已检查 %d 块）" % len(result["blocks"]))

# ---------------------------------------------------------------- G1 target 依赖 / import 图

IMPORT_RE = re.compile(
    r"(?m)^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)\n]*\))?[ \t]+)*import[ \t]+"
    r"(?:(?:class|struct|enum|protocol|typealias|func|var|let)[ \t]+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)")

G1_MIN_TARGETS = 18
G1_MIN_FILES = 700


def find_cycles(graph):
    index = {}
    low = {}
    onstack = set()
    stack = []
    result = []
    counter = [0]

    def strongconnect(node):
        index[node] = counter[0]
        low[node] = counter[0]
        counter[0] += 1
        stack.append(node)
        onstack.add(node)
        for nxt in sorted(graph.get(node, [])):
            if nxt not in index:
                strongconnect(nxt)
                low[node] = min(low[node], low[nxt])
            elif nxt in onstack:
                low[node] = min(low[node], index[nxt])
        if low[node] == index[node]:
            component = []
            while True:
                member = stack.pop()
                onstack.discard(member)
                component.append(member)
                if member == node:
                    break
            if len(component) > 1:
                result.append(sorted(component))

    for node in sorted(graph):
        if node not in index:
            strongconnect(node)
    return sorted(result)


def scan_import_graph(packages):
    targets, names = resolve_targets(packages)
    graph = {t["name"]: list(t["deps"]) for t in targets}
    violations = []
    imports = 0
    files = 0
    for target in targets:
        for path in swift_files(target["dir"]):
            files += 1
            masked = mask_code(read_text(path))
            for m in IMPORT_RE.finditer(masked):
                module = m.group(1)
                if module not in names or module == target["name"]:
                    continue
                imports += 1
                if module not in target["deps"]:
                    violations.append({
                        "target": target["name"],
                        "file": rel(path),
                        "line": line_of(masked, m.start()),
                        "module": module,
                    })
    return {
        "targets": graph,
        "target_dirs": {t["name"]: rel(t["dir"]) for t in targets},
        "files": files,
        "imports": imports,
        "violations": violations,
        "cycles": find_cycles(graph),
    }


def gate_import_graph(opts):
    if opts["self_test"]:
        return self_test_import_graph()
    result = scan_import_graph([CORE, APP])
    if len(result["targets"]) < G1_MIN_TARGETS:
        die("扫描量异常：只解析到 %d 个 target（<%d）" % (len(result["targets"]), G1_MIN_TARGETS))
    if result["files"] < G1_MIN_FILES:
        die("扫描量异常：只扫到 %d 个 Swift 文件（<%d）" % (result["files"], G1_MIN_FILES))
    baseline = load_baseline("import-graph")
    allowlist = []
    if baseline is not None:
        raw_allowlist = baseline.get("allowlist", [])
        if not isinstance(raw_allowlist, list):
            die("基线 allowlist 必须是数组：%s" % baseline_label("import-graph"))
        allowlist = [e for e in raw_allowlist if isinstance(e, dict)]
    allowed = {(e.get("target"), e.get("module")) for e in allowlist}
    undeclared = [v for v in result["violations"] if (v["target"], v["module"]) not in allowed]

    if opts["write"]:
        if undeclared:
            for v in undeclared:
                err("  未声明 import：%s:%s %s -> %s"
                    % (v["file"], v["line"], v["target"], v["module"]))
            err("REFUSED — 先在 Package.swift 补 target 依赖，或手工在 allowlist 登记理由")
            return 1
        grew = []
        if baseline is not None:
            old_targets = baseline.get("targets", {})
            cur_names = set(result["targets"])
            old_names = set(old_targets)
            for name in sorted(cur_names - old_names):
                grew.append("新 target：%s" % name)
            for name in sorted(cur_names & old_names):
                old_deps = set(old_targets.get(name, []))
                for dep in sorted(set(result["targets"][name]) - old_deps):
                    grew.append("新依赖边：%s -> %s" % (name, dep))
        if grew and not opts["allow_growth"]:
            for item in grew:
                err("  涨：" + item)
            err("REFUSED — target 集合/依赖边增长必须显式批准（--allow-growth 并在 docs/cleanup-backlog.md 台账记账）")
            return 1
        data = {
            "generated_by": "scripts/check-import-graph.sh --write-baseline",
            "note": (
                "Package.swift 声明的 target 内部依赖边（a+b）与实际 import 图。"
                "allowlist 只登记「实际 import 的模块不在该 target dependencies 里」的存量例外；"
                "新增 target / 新增依赖边需 --write-baseline --allow-growth 并记账。"
            ),
            "scan": {
                "targets": len(result["targets"]),
                "swift_files": result["files"],
                "internal_imports": result["imports"],
            },
            "targets": {name: result["targets"][name] for name in sorted(result["targets"])},
            "cycles": result["cycles"],
            "allowlist": allowlist,
        }
        save_baseline("import-graph", data)
        emit("baseline 已写入 %s" % baseline_label("import-graph"))
        emit("  targets %d / Swift 文件 %d / 内部 import %d / 环 0 / 未声明 import 0"
             % (len(result["targets"]), result["files"], result["imports"]))
        return 0

    if baseline is None:
        err("FAIL — 缺少 %s（先运行 --write-baseline）" % baseline_label("import-graph"))
        return 2
    rep = Report(opts)
    for v in undeclared:
        rep.problem("%s:%s import %s 未在 target %s 的 Package.swift dependencies 里声明"
                    % (v["file"], v["line"], v["module"], v["target"]))
    cur_names = set(result["targets"])
    old_targets = baseline.get("targets", {})
    old_names = set(old_targets)
    for name in sorted(cur_names - old_names):
        rep.problem("新 target 未登记：%s（--write-baseline --allow-growth 后记账）" % name)
    for name in sorted(old_names - cur_names):
        rep.note("target 消失：%s（可 --write-baseline 收紧）" % name)
    for name in sorted(cur_names & old_names):
        old_deps = set(old_targets.get(name, []))
        cur_deps = set(result["targets"][name])
        for dep in sorted(cur_deps - old_deps):
            rep.problem("target %s 新增依赖边 -> %s（Package.swift 边增长需记账）" % (name, dep))
        for dep in sorted(old_deps - cur_deps):
            rep.note("target %s 依赖边消失 -> %s（可收紧）" % (name, dep))
    for cycle in result["cycles"]:
        rep.problem("target 级依赖环：%s" % " -> ".join(cycle + [cycle[0]]))
    emit("targets %d / Swift 文件 %d / 内部 import %d"
         % (len(result["targets"]), result["files"], result["imports"]))
    return rep.finish("target 依赖边全部已声明、无 target 级环")

# ---------------------------------------------------------------- G2 模块规模 ratchet

G2_MIN_TARGETS = 18
G2_MIN_FILES = 1000


def scan_module_size(packages):
    targets, _names = resolve_targets(packages)
    entries = []
    total_files = 0
    for target in targets:
        directory = target["dir"]
        files = swift_files(directory) if directory.is_dir() else []
        loc = 0
        max_loc = 0
        max_file = ""
        for path in files:
            count = len(read_text(path).splitlines())
            loc += count
            if count > max_loc:
                max_loc = count
                max_file = rel(path)
        entries.append({
            "name": target["name"],
            "kind": target["kind"],
            "dir": rel(directory),
            "package": rel(target["package"]),
            "files": len(files),
            "loc": loc,
            "max_file_loc": max_loc,
            "max_file": max_file,
        })
        total_files += len(files)
    packages_stats = {}
    for package_dir in packages:
        package_rel = rel(package_dir)
        sources_loc = tests_loc = 0
        sources_files = tests_files = 0
        tests_prefix = rel(Path(package_dir) / "Tests") + "/"
        for entry in entries:
            if entry["package"] != package_rel:
                continue
            if entry["dir"].startswith(tests_prefix):
                tests_loc += entry["loc"]
                tests_files += entry["files"]
            else:
                sources_loc += entry["loc"]
                sources_files += entry["files"]
        ratio = round(tests_loc / sources_loc, 4) if sources_loc else 0.0
        packages_stats[package_rel] = {
            "sources_loc": sources_loc,
            "tests_loc": tests_loc,
            "sources_files": sources_files,
            "tests_files": tests_files,
            "tests_to_sources_ratio": ratio,
        }
    return {"targets": entries, "packages": packages_stats, "files": total_files}


def compare_module_size(current, baseline):
    problems = []
    notes = []
    base_targets = baseline.get("targets", {})
    cur_targets = {t["name"]: t for t in current["targets"]}
    for name in sorted(base_targets):
        base = base_targets[name]
        cur = cur_targets.get(name)
        if cur is None:
            notes.append("target 消失：%s（可 --write-baseline 收紧）" % name)
            continue
        # 测试 target 的规模只告警：新增/修改测试不应触发 --allow-growth（与 test-catalog 方向一致）。
        is_test = "/Tests/" in cur.get("dir", "")
        loc_grew = cur["loc"] > int(base.get("loc", 0))
        loc_shrank = cur["loc"] < int(base.get("loc", 0))
        max_grew = cur["max_file_loc"] > int(base.get("max_file_loc", 0))
        if is_test:
            if loc_grew:
                notes.append("target %s（Tests）LOC 上涨：%d -> %d（测试规模只告警）"
                             % (name, int(base.get("loc", 0)), cur["loc"]))
            if max_grew:
                notes.append("target %s（Tests）最大文件 LOC 上涨：%d -> %d（测试规模只告警）"
                             % (name, int(base.get("max_file_loc", 0)), cur["max_file_loc"]))
        else:
            if loc_grew:
                problems.append("target %s LOC 上涨：%d -> %d"
                                % (name, int(base.get("loc", 0)), cur["loc"]))
            elif loc_shrank:
                notes.append("target %s LOC 下降：%d -> %d（可收紧）"
                             % (name, int(base.get("loc", 0)), cur["loc"]))
            if max_grew:
                problems.append("target %s 最大文件 LOC 上涨：%d -> %d（%s）"
                                % (name, int(base.get("max_file_loc", 0)),
                                   cur["max_file_loc"], cur["max_file"]))
            elif cur["max_file_loc"] < int(base.get("max_file_loc", 0)):
                notes.append("target %s 最大文件 LOC 下降（可收紧）" % name)
        if cur["files"] > int(base.get("files", 0)):
            notes.append("target %s 文件数上涨：%d -> %d（拆文件是合法重构，只告警）"
                         % (name, int(base.get("files", 0)), cur["files"]))
    cur_names = set(cur_targets)
    for name in sorted(cur_names - set(base_targets)):
        notes.append("新 target：%s（LOC 计入包级合计；--write-baseline 登记）" % name)
    base_packages = baseline.get("packages", {})
    for package, stats in sorted(current["packages"].items()):
        base = base_packages.get(package)
        if not isinstance(base, dict):
            notes.append("新包：%s（--write-baseline 登记）" % package)
            continue
        for key, label in (("sources_loc", "Sources LOC"),):
            base_value = int(base.get(key, 0))
            if stats[key] > base_value:
                problems.append("%s %s 上涨：%d -> %d" % (package, label, base_value, stats[key]))
            elif stats[key] < base_value:
                notes.append("%s %s 下降：%d -> %d（可收紧）"
                             % (package, label, base_value, stats[key]))
        base_tests = int(base.get("tests_loc", 0))
        if stats["tests_loc"] > base_tests:
            notes.append("%s Tests LOC 上涨：%d -> %d（测试规模只告警）"
                         % (package, base_tests, stats["tests_loc"]))
    return problems, notes


def gate_module_size(opts):
    if opts["self_test"]:
        return self_test_module_size()
    current = scan_module_size([CORE, APP])
    if len(current["targets"]) < G2_MIN_TARGETS:
        die("扫描量异常：只统计到 %d 个 target 目录（<%d）"
            % (len(current["targets"]), G2_MIN_TARGETS))
    if current["files"] < G2_MIN_FILES:
        die("扫描量异常：只扫到 %d 个 Swift 文件（<%d）" % (current["files"], G2_MIN_FILES))
    baseline = load_baseline("module-size")

    if opts["write"]:
        if baseline is not None:
            problems, _notes = compare_module_size(current, baseline)
            if problems and not opts["allow_growth"]:
                for problem in problems:
                    err("  涨：" + problem)
                err("REFUSED — 模块 LOC/最大文件 LOC 上涨必须显式批准"
                    "（--allow-growth 并在 docs/cleanup-backlog.md 台账记账）")
                return 1
        data = {
            "generated_by": "scripts/check-module-size.sh --write-baseline",
            "note": (
                "每 target 文件数/LOC/最大文件 LOC + 包级 Sources/Tests LOC。"
                "Sources LOC 合计与最大文件 LOC 只降不升（上涨需 --allow-growth 并记账）；Tests 规模只告警；"
                "文件数上涨只告警不失败（拆文件是合法重构）；Tests/Sources 行比只记录、不参与 ratchet。"
            ),
            "scan": {"target_dirs": len(current["targets"]), "swift_files": current["files"]},
            "packages": current["packages"],
            "targets": {t["name"]: {
                "files": t["files"],
                "loc": t["loc"],
                "max_file_loc": t["max_file_loc"],
                "max_file": t["max_file"],
            } for t in sorted(current["targets"], key=lambda item: item["name"])},
        }
        save_baseline("module-size", data)
        emit("baseline 已写入 %s" % baseline_label("module-size"))
        for package, stats in sorted(current["packages"].items()):
            emit("  %s：Sources %d 行 / Tests %d 行（Tests/Sources %.1f%%）"
                 % (package, stats["sources_loc"], stats["tests_loc"],
                    stats["tests_to_sources_ratio"] * 100))
        return 0

    if baseline is None:
        err("FAIL — 缺少 %s（先运行 --write-baseline）" % baseline_label("module-size"))
        return 2
    problems, notes = compare_module_size(current, baseline)
    rep = Report(opts)
    for problem in problems:
        rep.problem(problem)
    for note in notes:
        rep.note(note)
    for package, stats in sorted(current["packages"].items()):
        emit("  %s：Sources %d 行 / Tests %d 行（Tests/Sources %.1f%%）"
             % (package, stats["sources_loc"], stats["tests_loc"],
                stats["tests_to_sources_ratio"] * 100))
    return rep.finish("LOC 合计与最大文件 LOC 不超过基线（%d target / %d 文件）"
                      % (len(current["targets"]), current["files"]))

# ---------------------------------------------------------------- G3 并发标注白名单

G3_MIN_FILES = 700

UNCHECKED_RE = re.compile(r"@unchecked\s+Sendable")
NONISOLATED_RE = re.compile(r"nonisolated\s*\(\s*unsafe\s*\)")
TYPE_DECL_RE = re.compile(r"\b(class|struct|enum|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)")
TYPE_KEYWORD_NAMES = {
    "func", "var", "let", "init", "subscript", "class", "static", "final",
    "mutating", "nonisolated", "convenience", "required", "dynamic", "weak",
    "unowned", "lazy", "private", "public", "internal", "fileprivate", "open",
    "override", "where", "throws", "async",
}


def type_push_events(masked):
    events = {}
    for m in TYPE_DECL_RE.finditer(masked):
        name = m.group(2)
        if name in TYPE_KEYWORD_NAMES:
            continue
        brace = masked.find("{", m.end())
        if brace < 0:
            continue
        between = masked[m.end():brace]
        if "}" in between or ";" in between or len(between) > 240:
            continue
        if brace not in events:
            events[brace] = name
    return events


def enclosing_type(masked, pos, events):
    stack = []
    for i, ch in enumerate(masked[:pos]):
        if ch == "{":
            stack.append(events.get(i))
        elif ch == "}":
            if stack:
                stack.pop()
    line_start = masked.rfind("\n", 0, pos) + 1
    same_line = None
    for m in TYPE_DECL_RE.finditer(masked[line_start:pos]):
        if m.group(2) not in TYPE_KEYWORD_NAMES:
            same_line = m.group(2)
    if same_line:
        return same_line
    for name in reversed(stack):
        if name:
            return name
    return "<file-scope>"


def scan_concurrency(roots):
    files = 0
    entries = {}
    totals = {"unchecked_sendable": 0, "nonisolated_unsafe": 0}
    for root in roots:
        for path in swift_files(root):
            files += 1
            masked = mask_code(read_text(path))
            unchecked = list(UNCHECKED_RE.finditer(masked))
            nonisolated = list(NONISOLATED_RE.finditer(masked))
            if not unchecked and not nonisolated:
                continue
            totals["unchecked_sendable"] += len(unchecked)
            totals["nonisolated_unsafe"] += len(nonisolated)
            events = type_push_events(masked)
            for kind, matches in (("unchecked_sendable", unchecked),
                                  ("nonisolated_unsafe", nonisolated)):
                for m in matches:
                    key = (rel(path), enclosing_type(masked, m.start(), events), kind)
                    entries[key] = entries.get(key, 0) + 1
    return {"files": files, "entries": entries, "totals": totals}


def gate_concurrency_whitelist(opts):
    if opts["self_test"]:
        return self_test_concurrency_whitelist()
    result = scan_concurrency([CORE_SRC, APP_SRC])
    if result["files"] < G3_MIN_FILES:
        die("扫描量异常：只扫到 %d 个 Swift 文件（<%d）" % (result["files"], G3_MIN_FILES))
    baseline = load_baseline("concurrency-whitelist")
    base_entries = {}
    if baseline is not None:
        raw = baseline.get("entries", [])
        if not isinstance(raw, list):
            die("基线 entries 必须是数组：%s" % baseline_label("concurrency-whitelist"))
        for item in raw:
            if not isinstance(item, dict):
                continue
            key = (item.get("file"), item.get("type"), item.get("kind"))
            base_entries[key] = int(item.get("count", 1) or 1)
    cur_entries = result["entries"]

    def entry_list(mapping):
        return [{"file": key[0], "type": key[1], "kind": key[2], "count": mapping[key]}
                for key in sorted(mapping)]

    if opts["write"]:
        grew = []
        for key in sorted(cur_entries):
            if key not in base_entries:
                grew.append("新增白名单位置：%s [%s] %s" % (key[0], key[2], key[1]))
            elif cur_entries[key] > base_entries[key]:
                grew.append("同位置数量上涨：%s [%s] %d -> %d"
                            % (key[0], key[2], base_entries[key], cur_entries[key]))
        if baseline is not None and grew and not opts["allow_growth"]:
            for item in grew:
                err("  涨：" + item)
            err("REFUSED — 新增 @unchecked Sendable / nonisolated(unsafe) 必须显式批准"
                "（--allow-growth 并在 docs/cleanup-backlog.md 台账记账；预算 60/60 已满）")
            return 1
        data = {
            "generated_by": "scripts/check-concurrency-whitelist.sh --write-baseline",
            "note": (
                "并发标注白名单（file + 最近外层类型名 + kind）。出现基线外的 (file,type) 即 FAIL，"
                "即使总数不变；同一位置 count 上涨也 FAIL；减少只告警并提示收紧。"
            ),
            "scan": {"swift_files": result["files"], "totals": result["totals"]},
            "entries": entry_list(cur_entries),
        }
        save_baseline("concurrency-whitelist", data)
        emit("baseline 已写入 %s" % baseline_label("concurrency-whitelist"))
        emit("  unchecked_sendable %d / nonisolated_unsafe %d / Swift 文件 %d"
             % (result["totals"]["unchecked_sendable"],
                result["totals"]["nonisolated_unsafe"], result["files"]))
        return 0

    if baseline is None:
        err("FAIL — 缺少 %s（先运行 --write-baseline）" % baseline_label("concurrency-whitelist"))
        return 2
    rep = Report(opts)
    for key in sorted(cur_entries):
        if key not in base_entries:
            rep.problem("新增并发标注：%s [%s] %s（预算 60/60 已满；改用锁盒/actor）"
                        % (key[0], key[2], key[1]))
        elif cur_entries[key] > base_entries[key]:
            rep.problem("并发标注数量上涨：%s [%s] %s %d -> %d"
                        % (key[0], key[2], key[1], base_entries[key], cur_entries[key]))
        elif cur_entries[key] < base_entries[key]:
            rep.note("%s [%s] %s 数量下降：%d -> %d（可收紧）"
                     % (key[0], key[2], key[1], base_entries[key], cur_entries[key]))
    for key in sorted(set(base_entries) - set(cur_entries)):
        rep.note("白名单位置消失：%s [%s] %s（可 --write-baseline 收紧）"
                 % (key[0], key[2], key[1]))
    emit("unchecked_sendable %d / nonisolated_unsafe %d / Swift 文件 %d"
         % (result["totals"]["unchecked_sendable"],
            result["totals"]["nonisolated_unsafe"], result["files"]))
    return rep.finish("并发标注全部在白名单内（%d 条位置）" % len(cur_entries))

# ---------------------------------------------------------------- G4 Application 符号级越界

G4_MIN_FILES = 100

LAYER_PATTERNS = [
    ("DBConnection", re.compile(r"\bDBConnection\b")),
    ("Database(", re.compile(r"\bDatabase\s*\(")),
    ("SQLite3", re.compile(r"\bSQLite3\b")),
    ("CSQLite", re.compile(r"\bCSQLite\b")),
]
LAYER_HINT_RE = re.compile(r"\.connection\b")


def scan_layer_symbols(app_dir):
    files = swift_files(app_dir)
    hits = []
    hints = []
    for path in files:
        masked = mask_code(read_text(path))
        for pattern_name, pattern in LAYER_PATTERNS:
            for m in pattern.finditer(masked):
                hits.append({"file": rel(path), "pattern": pattern_name,
                             "line": line_of(masked, m.start())})
        for m in LAYER_HINT_RE.finditer(masked):
            hints.append({"file": rel(path), "line": line_of(masked, m.start())})
    return {"files": len(files), "hits": hits, "hints": hints}


def gate_layer_symbols(opts):
    if opts["self_test"]:
        return self_test_layer_symbols()
    app_dir = CORE_SRC / "GatherApplication"
    result = scan_layer_symbols(app_dir)
    if result["files"] < G4_MIN_FILES:
        die("扫描量异常：GatherApplication 只扫到 %d 个 Swift 文件（<%d）"
            % (result["files"], G4_MIN_FILES))
    baseline = load_baseline("layer-symbols")
    allowlist = []
    if baseline is not None:
        raw = baseline.get("allowlist", [])
        if not isinstance(raw, list):
            die("基线 allowlist 必须是数组：%s" % baseline_label("layer-symbols"))
        allowlist = [e for e in raw if isinstance(e, dict)]
    by_key = {}
    for entry in allowlist:
        by_key[(entry.get("file"), entry.get("pattern"))] = entry
    current_counts = {}
    for hit in result["hits"]:
        key = (hit["file"], hit["pattern"])
        current_counts[key] = current_counts.get(key, 0) + 1

    if opts["write"]:
        grew = []
        for key in sorted(current_counts):
            if key not in by_key:
                grew.append("新增越界：%s [%s]" % (key[0], key[1]))
            elif current_counts[key] > int(by_key[key].get("count", 1) or 1):
                grew.append("越界计数上涨：%s [%s] %d -> %d"
                            % (key[0], key[1], int(by_key[key].get("count", 1) or 1),
                               current_counts[key]))
        if baseline is not None and grew and not opts["allow_growth"]:
            for item in grew:
                err("  涨：" + item)
            err("REFUSED — 新增符号越界必须显式批准（--allow-growth 并在 docs/cleanup-backlog.md 台账记账）")
            return 1
        first_lines = {}
        for hit in result["hits"]:
            key = (hit["file"], hit["pattern"])
            if key not in first_lines or hit["line"] < first_lines[key]:
                first_lines[key] = hit["line"]
        new_allowlist = []
        for key in sorted(current_counts):
            old = by_key.get(key, {})
            reason = old.get("reason") or (
                "当前树存量（--write-baseline 生成；core-refactor 集成后收紧；"
                "维护/迁移路径直持 DBConnection，见架构评审 D1/C1）")
            new_allowlist.append({
                "file": key[0],
                "pattern": key[1],
                "count": current_counts[key],
                "reason": reason,
                "line_hint": first_lines.get(key, 0),
            })
        data = {
            "generated_by": "scripts/check-layer-symbols.sh --write-baseline",
            "note": (
                "GatherApplication 符号级越界白名单：DBConnection / Database( / SQLite3 / CSQLite "
                "计入违规（.connection 只作提示不计违规）。基线外的出现即 FAIL；"
                "同一 file+pattern 计数上涨也 FAIL。MaintenanceService 的 VACUUM 属 ADR-035 允许例外。"
            ),
            "scope": "desktop/native/gather-core/Sources/GatherApplication",
            "scan": {"files": result["files"], "violations": len(result["hits"]),
                     "hints": len(result["hints"])},
            "allowlist": new_allowlist,
        }
        save_baseline("layer-symbols", data)
        emit("baseline 已写入 %s" % baseline_label("layer-symbols"))
        emit("  GatherApplication %d 文件 / 越界命中 %d（登记 %d 个 file+pattern）/ 提示 %d"
             % (result["files"], len(result["hits"]), len(new_allowlist), len(result["hints"])))
        return 0

    if baseline is None:
        err("FAIL — 缺少 %s（先运行 --write-baseline）" % baseline_label("layer-symbols"))
        return 2
    rep = Report(opts)
    for hit in result["hits"]:
        key = (hit["file"], hit["pattern"])
        if key not in by_key:
            rep.problem("%s:%d GatherApplication 内出现越界符号 %s"
                        % (hit["file"], hit["line"], hit["pattern"]))
    for key in sorted(current_counts):
        if key in by_key:
            base_count = int(by_key[key].get("count", 1) or 1)
            if current_counts[key] > base_count:
                rep.problem("%s [%s] 越界计数上涨：%d -> %d"
                            % (key[0], key[1], base_count, current_counts[key]))
            elif current_counts[key] < base_count:
                rep.note("%s [%s] 越界计数下降：%d -> %d（可收紧）"
                         % (key[0], key[1], base_count, current_counts[key]))
    for key in sorted(set(by_key) - set(current_counts)):
        rep.note("白名单条目消失：%s [%s]（可 --write-baseline 收紧）" % (key[0], key[1]))
    emit("GatherApplication %d 文件 / 越界命中 %d / .connection 提示 %d"
         % (result["files"], len(result["hits"]), len(result["hints"])))
    for hint in result["hints"]:
        emit("  提示（不计违规）：%s:%d .connection" % (hint["file"], hint["line"]))
    return rep.finish("GatherApplication 符号级越界全部在登记白名单内（%d 处）" % len(result["hits"]))

# ---------------------------------------------------------------- G5 app public 面 / API requirement

G5_MIN_APP_FILES = 300
G5_MIN_API_FILES = 40
G5_MIN_API_PROTOCOLS = 10
G5_MIN_API_REQUIREMENTS = 100

APP_TARGETS = [
    ("GatherUI", APP_SRC / "GatherUI"),
    ("GatherHost", APP_SRC / "GatherHost"),
    ("GatherApp", APP_SRC / "GatherApp"),
    ("GatherPreviewData", APP_SRC / "GatherPreviewData"),
]
API_DIR = CORE_SRC / "GatherProtocol" / "API"
# 声明边界：行首，或单行多声明 / 单行类型体 / 单行协议体里的 ; { } 之后。
# 旧实现只认「行首（可选缩进）+ public」，实际漏计（2026-11-23 P1-3，见
# .tmp/arch-plan-2026-11-23/06-gates.md §6.2）：
#   - 属性前缀与 public 同行：`@MainActor public final class`、`@MainActor public protocol`；
#   - 缩进/嵌套的 public 类型：`extension X { public struct Y }`（类型正则旧版连行首缩进都不认）；
#   - 单行多声明：`public struct A {} public struct B {}`、`public enum E { case a }` 之后的声明；
#   - 单行协议体：`public protocol P { func a(); var b: Int { get } }`。
# 边界用定宽后行断言（零宽），匹配起点仍落在声明这一行，行号语义不变。
_DECL_BOUNDARY = r"(?:^|(?<=[;{}]))"
_ATTR_PREFIX = r"(?:@\w+(?:\([^)\n]*\))?[ \t]+)*"
PUBLIC_TYPE_RE = re.compile(
    r"(?m)" + _DECL_BOUNDARY + r"[ \t]*" + _ATTR_PREFIX +
    r"public\s+(?:struct|enum|indirect\s+enum|final\s+class|class|protocol|actor)\s+"
    r"[A-Za-z_][A-Za-z0-9_]*")
PUBLIC_DECL_RE = re.compile(
    r"(?m)" + _DECL_BOUNDARY + r"[ \t]*" + _ATTR_PREFIX + r"public[ \t]")
PUBLIC_PROTOCOL_RE = re.compile(
    r"(?m)" + _DECL_BOUNDARY + r"[ \t]*" + _ATTR_PREFIX +
    r"public\s+protocol\s+[A-Za-z_][A-Za-z0-9_]*")

# public extension 的隐式 public 成员（2026-11-24 修，P1-3 尾巴）：
# "public extension Foo { func bar() }" 里的 bar 是 public，但行内没有 public
# 关键字，PUBLIC_DECL_RE 一条都不认。旧实现漏计 GatherUI 16 个 public
# extension / 33 个隐式 public 成员，往已有 extension 追加方法时类型数与声明数
# 都不变 → CI 静默放行。这里只数**无显式访问修饰**的成员（public/open/package/
# internal/fileprivate/private 都不在下面的修饰符白名单里，所以显式声明不会被
# 二次计数：它们走 PUBLIC_DECL_RE，或本来就不属于 public 面），且只数 extension
# 体第一层（函数体里的局部 let/var 不是成员，靠 brace_depths 过滤）。
# typealias 也在白名单里（2026-11-24 修，P2）：extension 里的 typealias 是隐式
# public，而显式写法的 public typealias 旧版会被 PUBLIC_DECL_RE 计入 —— 只漏这一种
# 会让「挪到 public extension 里」变成静默少计。当前源码 0 处，不影响基线。
_IMPLICIT_MEMBER_MODIFIERS = (
    r"(?:(?:static|final|class|mutating|nonisolated|override|required|"
    r"convenience|dynamic|lazy|weak|unowned|indirect)[ \t]+)*")
PUBLIC_EXTENSION_RE = re.compile(
    r"(?m)" + _DECL_BOUNDARY + r"[ \t]*" + _ATTR_PREFIX +
    r"public\s+extension\s+[A-Za-z_][A-Za-z0-9_.]*")
IMPLICIT_EXTENSION_MEMBER_RE = re.compile(
    r"(?m)" + _DECL_BOUNDARY + r"[ \t]*" + _ATTR_PREFIX + _IMPLICIT_MEMBER_MODIFIERS +
    r"(?:func|var|let|init|subscript|typealias)\b")
API_REQUIREMENT_RE = re.compile(
    r"(?m)" + _DECL_BOUNDARY + r"[ \t]*" + _ATTR_PREFIX +
    r"(?:(?:static|mutating|nonisolated|class|final)[ \t]+)*"
    r"(?:func|var|init|associatedtype)\b")


def brace_depths(body):
    """body 每个下标处相对 owner 体的花括号深度（mask_code 已遮掉字符串与注释）。"""
    depth = 0
    depths = [0] * (len(body) + 1)
    for index, char in enumerate(body):
        depths[index] = depth
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
    depths[len(body)] = depth
    return depths


def count_implicit_extension_members(masked):
    """public extension 体内第一层、无显式访问修饰的成员声明数。"""
    total = 0
    for match in PUBLIC_EXTENSION_RE.finditer(masked):
        body = block_body(masked, match.end())
        if body is None:
            continue
        depths = brace_depths(body)
        total += sum(1 for decl in IMPLICIT_EXTENSION_MEMBER_RE.finditer(body)
                     if depths[decl.start()] == 0)
    return total


def count_explicit_public_declarations(masked):
    """显式 public 声明数：PUBLIC_DECL_RE 命中减去 public extension 头。

    PUBLIC_DECL_RE 的既有口径是「public 后面跟任意 token 即计一条」，所以
    "public extension Foo {" 这一行本身也被算成一条声明。于是
    public extension Foo { func a() {} }  = 头 1 + 隐式 1 = 2，而等价写法
    extension Foo { public func a() {} } = 1：把成员从 extension 体里挪到头上
    （或反过来）会让声明数 ±1 → 纯改写假失败/假通过（2026-11-24 修，P2）。
    extension 头不是声明，减掉它之后两种写法的公开面都恰好是 1。
    max(0, ...) 兜底：极端输入（PUBLIC_EXTENSION_RE 命中多于 PUBLIC_DECL_RE）
    不能让计数变成负数。
    """
    hits = len(PUBLIC_DECL_RE.findall(masked))
    heads = len(PUBLIC_EXTENSION_RE.findall(masked))
    return max(0, hits - heads)


def scan_public_surface(targets, api_dir):
    target_stats = {}
    implicit_totals = {}
    app_files = 0
    for name, directory in targets:
        files = swift_files(directory) if directory.is_dir() else []
        public_types = 0
        public_declarations = 0
        implicit_members = 0
        for path in files:
            masked = mask_code(read_text(path))
            public_types += len(PUBLIC_TYPE_RE.findall(masked))
            # 声明数 = 显式 public 声明（不含 public extension 头）+ public extension
            # 的隐式 public 成员。合并而非独立 metric：public extension F { func f() }
            # 与 extension F { public func f() } 的公开面完全相同，独立 metric 会让这种
            # 纯改写变成「一个涨、一个降」→ 假失败；合并后计数对改写不变。
            public_declarations += count_explicit_public_declarations(masked)
            implicit_members += count_implicit_extension_members(masked)
        public_declarations += implicit_members
        target_stats[name] = {
            "files": len(files),
            "public_types": public_types,
            "public_declarations": public_declarations,
        }
        implicit_totals[name] = implicit_members
        app_files += len(files)
    api_files = swift_files(api_dir)
    api_protocols = 0
    api_requirements = 0
    for path in api_files:
        masked = mask_code(read_text(path))
        for m in PUBLIC_PROTOCOL_RE.finditer(masked):
            body = block_body(masked, m.end())
            if body is None:
                continue
            api_protocols += 1
            api_requirements += len(API_REQUIREMENT_RE.findall(body))
    return {
        "targets": target_stats,
        # 仅用于报告的分项（不写进基线：声明数已经把两半合并，避免同一公开面被
        # 记两笔，也避免两边漂移）。
        "implicit_extension_members": implicit_totals,
        "api": {
            "files": len(api_files),
            "public_protocols": api_protocols,
            "requirement_lines": api_requirements,
        },
        "app_files": app_files,
    }


def compare_public_surface(current, baseline):
    problems = []
    notes = []
    base_targets = baseline.get("targets", {})
    for name, stats in current["targets"].items():
        base = base_targets.get(name)
        if not isinstance(base, dict):
            notes.append("新 target：%s（--write-baseline 登记）" % name)
            continue
        for key, label in (("public_types", "public 类型"),
                           ("public_declarations", "public 声明行")):
            base_value = int(base.get(key, 0))
            if stats[key] > base_value:
                problems.append("%s %s 上涨：%d -> %d"
                                % (name, label, base_value, stats[key]))
            elif stats[key] < base_value:
                notes.append("%s %s 下降：%d -> %d（可收紧）"
                             % (name, label, base_value, stats[key]))
        if stats["files"] > int(base.get("files", 0)):
            notes.append("%s 文件数上涨：%d -> %d（只告警，不算 public 面）"
                         % (name, int(base.get("files", 0)), stats["files"]))
    base_api = baseline.get("api", {})
    for key, label in (("requirement_lines", "API protocol requirement 行"),
                       ("public_protocols", "API public protocol 数")):
        base_value = int(base_api.get(key, 0))
        cur_value = current["api"][key]
        if cur_value > base_value:
            problems.append("%s 上涨：%d -> %d" % (label, base_value, cur_value))
        elif cur_value < base_value:
            notes.append("%s 下降：%d -> %d（可收紧）" % (label, base_value, cur_value))
    return problems, notes


def emit_public_surface(current):
    for name, stats in current["targets"].items():
        emit("  %-16s 文件 %3d / public 类型 %3d / public 声明行 %4d"
             "（其中 public extension 隐式成员 %d）"
             % (name, stats["files"], stats["public_types"],
                stats["public_declarations"],
                current["implicit_extension_members"].get(name, 0)))
    emit("  API：%d 文件 / %d 个 public protocol / %d 条 requirement 行"
         % (current["api"]["files"], current["api"]["public_protocols"],
            current["api"]["requirement_lines"]))


def gate_public_surface_app(opts):
    if opts["self_test"]:
        return self_test_public_surface()
    current = scan_public_surface(APP_TARGETS, API_DIR)
    if current["app_files"] < G5_MIN_APP_FILES:
        die("扫描量异常：app 四个 target 只扫到 %d 个 Swift 文件（<%d）"
            % (current["app_files"], G5_MIN_APP_FILES))
    if current["api"]["files"] < G5_MIN_API_FILES:
        die("扫描量异常：GatherProtocol/API 只扫到 %d 个 Swift 文件（<%d）"
            % (current["api"]["files"], G5_MIN_API_FILES))
    if current["api"]["public_protocols"] < G5_MIN_API_PROTOCOLS:
        die("扫描量异常：只识别到 %d 个 public protocol（<%d）"
            % (current["api"]["public_protocols"], G5_MIN_API_PROTOCOLS))
    if current["api"]["requirement_lines"] < G5_MIN_API_REQUIREMENTS:
        die("扫描量异常：只识别到 %d 条 requirement 行（<%d）"
            % (current["api"]["requirement_lines"], G5_MIN_API_REQUIREMENTS))
    baseline = load_baseline("public-surface-app")

    if opts["write"]:
        if baseline is not None:
            problems, _notes = compare_public_surface(current, baseline)
            if problems and not opts["allow_growth"]:
                for problem in problems:
                    err("  涨：" + problem)
                err("REFUSED — app public 面 / API requirement 上涨必须显式批准"
                    "（--allow-growth 并在 docs/cleanup-backlog.md 台账记账）")
                return 1
        data = {
            "generated_by": "scripts/check-public-surface-app.sh --write-baseline",
            "note": (
                "app 四个 target（GatherUI/GatherHost/GatherApp/GatherPreviewData）的 public 类型数"
                "（含缩进/嵌套声明与同一行的属性前缀）+ public 声明数（同一行多条分别计数；"
                "显式 public 声明 + public extension 体内隐式 public 的 "
                "func/var/let/init/subscript/typealias，extension 头本身不计）；"
                "GatherProtocol/API/**/*.swift 每个 public protocol 体内的 requirement 数"
                "（func/var/init/associatedtype，剥注释；单行协议体按 ; { } 分隔计数）。只降不升；"
                "GatherPreviewData 用 package 可见性，public 面 0 是预期（不误报）。"
            ),
            "scan": {"app_swift_files": current["app_files"],
                     "api_files": current["api"]["files"]},
            "targets": current["targets"],
            "api": {
                "public_protocols": current["api"]["public_protocols"],
                "requirement_lines": current["api"]["requirement_lines"],
            },
        }
        save_baseline("public-surface-app", data)
        emit("baseline 已写入 %s" % baseline_label("public-surface-app"))
        emit_public_surface(current)
        return 0

    if baseline is None:
        err("FAIL — 缺少 %s（先运行 --write-baseline）" % baseline_label("public-surface-app"))
        return 2
    problems, notes = compare_public_surface(current, baseline)
    rep = Report(opts)
    for problem in problems:
        rep.problem(problem)
    for note in notes:
        rep.note(note)
    emit_public_surface(current)
    return rep.finish("app public 面与 API requirement 不超过基线")

# ---------------------------------------------------------------- 自测 fixture

LOCK_FIXTURE_BAD = '''// fixture: DB -> XMP 反向锁序（G0 应发现；含尾随闭包与 transaction({...}) 两种形态）
func bad(connection: DBConnection, fileLock: XMPFileLock) throws {
    try connection.transaction {
        try fileLock.run(path: "a.xmp") { _ in }
    }
}

func badParen(connection: DBConnection, fileLock: XMPFileLock) throws {
    try connection.transaction({
        try fileLock.run(path: "b.xmp") { _ in }
    })
}
'''

LOCK_FIXTURE_GOOD = '''// fixture: 允许方向 XMP -> DB（G0 不应误报）
func good(connection: DBConnection, fileLock: XMPFileLock) async throws {
    try await fileLock.run(path: "a.xmp") {
        try connection.transaction {
            _ = try connection.query("SELECT 1")
        }
    }
}
'''

IMPORT_FIXTURE_MANIFEST = '''// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "import-fixture",
    targets: [
        .target(name: "Alpha", dependencies: []),
        .target(name: "Beta", dependencies: ["Alpha"]),
    ]
)
'''

IMPORT_FIXTURE_MANIFEST_DECLARED = '''// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "import-fixture",
    targets: [
        .target(name: "Alpha", dependencies: ["Beta"]),
        .target(name: "Beta", dependencies: ["Alpha"]),
    ]
)
'''

SIZE_FIXTURE_MANIFEST = '''// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "size-fixture",
    targets: [
        .target(name: "Tiny", dependencies: []),
        .testTarget(name: "TinyTests", dependencies: ["Tiny"]),
    ]
)
'''

CONCURRENCY_FIXTURE = '''// fixture: 并发标注白名单样本
final class Outer {
    final class Inner: @unchecked Sendable {}
}

enum Cache {
    nonisolated(unsafe) static var table: [String: Int] = [:]
}

// @unchecked Sendable 出现在注释里，不算
let note = "@unchecked Sendable 出现在字符串里，不算"
'''

LAYER_FIXTURE = '''// fixture: Application 符号级越界
// DBConnection 出现在注释里，不算
final class Fixture {
    let connection: DBConnection

    func open() throws {
        _ = try Database(path: "x")
        _ = service.connection
    }
}
'''

PUBLIC_FIXTURE_TARGET_EXTENSION = """// fixture: public extension 的隐式 public 成员（6 个正样本 / 2 个负样本）
public extension Widget {
    func title() -> String { "" }
    var flag: Bool { true }
    static func make() -> Self { Widget(id: 1) }
    @discardableResult func reset() -> Bool { true }
    init(stub: Int) { _ = stub }

    func withBody() -> Int {
        // 函数体里的局部 let 不是成员（负样本，必须不计）
        let local = 1
        return local
    }

    // 显式 private 不是 public 面（负样本，必须不计）
    private func hidden() {}
}
"""

PUBLIC_FIXTURE_TARGET = '''// fixture: public 面样本（属性前缀 / 缩进嵌套 / 单行多声明）
public struct Widget: Sendable {
    public let id: Int
    public func render() {}
}

public enum Mode {
    case a
}

@MainActor public final class Host {
    public let name: String
}

enum Namespace {
    public struct Nested { public func f() {} }
}

public struct Alpha {} public struct Beta {}
'''

PUBLIC_FIXTURE_EXTENSION_ADDED = "    func appended() {}\n"
# 显式 public 成员：走 PUBLIC_DECL_RE，不能被隐式计数器二次计数。
PUBLIC_FIXTURE_EXTENSION_ADDED_EXPLICIT = "    public func exposed() {}\n"
# static let：修饰符白名单（static/final/...）必须认。
PUBLIC_FIXTURE_EXTENSION_ADDED_STATIC = "    static let cache = 0\n"
# typealias：extension 里的 typealias 也是隐式 public（旧白名单漏计）。
PUBLIC_FIXTURE_EXTENSION_ADDED_TYPEALIAS = "    typealias Row = Int\n"

# 字符串里的 } 与 \" 必须被遮罩：旧 _STR_RE 漏 \" → 字面量提前结束，} 露成代码，
# block_body 在那里闭合、tail() 丢失（隐式成员 1 而不是 2）。
PUBLIC_FIXTURE_STRING_MASK = '''// fixture: 字符串遮罩负样本
public extension Widget {
    func logLine() {
        log("x } \\" y")
    }

    func tail() {}
}
'''

PUBLIC_FIXTURE_API = '''// fixture: API requirement 样本（含属性前缀与单行协议体）
public protocol FixtureAPI: Sendable {
    func load() async throws
    var name: String { get }
    static func make() -> Self
}

@MainActor public protocol InlineAPI {
    func a(); var b: Int { get }; init(c: Int)
}
'''


def self_test_lock_order():
    tmp = Path(tempfile.mkdtemp(prefix="check-lock-order-"))
    try:
        delivery = tmp / "GatherDelivery"
        delivery.mkdir(parents=True)
        (delivery / "Fixture.swift").write_text(LOCK_FIXTURE_BAD, encoding="utf-8")
        bad = scan_lock_order(delivery)
        if len(bad["blocks"]) != 2:
            die("self-test FAIL：违规 fixture 的 transaction 块识别数 %d != 2" % len(bad["blocks"]))
        if len(bad["violations"]) < 2:
            die("self-test FAIL：违规 fixture 的 DB->XMP 反向锁序没有被发现（%r）" % (bad["violations"],))
        (delivery / "Fixture.swift").write_text(LOCK_FIXTURE_GOOD, encoding="utf-8")
        good = scan_lock_order(delivery)
        if good["violations"]:
            die("self-test FAIL：合规 fixture 被误报：%r" % (good["violations"],))
        if good["run_sites"] != 1 or len(good["blocks"]) != 1:
            die("self-test FAIL：合规 fixture 计数异常：%r" % (good,))
        emit("self-test OK（违规 fixture 命中 %d 处；合规 fixture 0 误报）"
             % len(bad["violations"]))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test_import_graph():
    tmp = Path(tempfile.mkdtemp(prefix="check-import-graph-"))
    try:
        package = tmp / "fixture"
        alpha = package / "Sources" / "Alpha"
        beta = package / "Sources" / "Beta"
        alpha.mkdir(parents=True)
        beta.mkdir(parents=True)
        (package / "Package.swift").write_text(IMPORT_FIXTURE_MANIFEST, encoding="utf-8")
        (alpha / "A.swift").write_text("import Beta\n", encoding="utf-8")
        (beta / "B.swift").write_text("import Alpha\n", encoding="utf-8")
        result = scan_import_graph([package])
        if not result["violations"]:
            die("self-test FAIL：未声明 import（Alpha -> Beta）没有被发现")
        if result["cycles"]:
            die("self-test FAIL：无环 fixture 被误报环：%r" % (result["cycles"],))
        (alpha / "A.swift").write_text("@preconcurrency import Beta\n", encoding="utf-8")
        result = scan_import_graph([package])
        if not result["violations"]:
            die("self-test FAIL：@preconcurrency import 未被识别")
        (alpha / "A.swift").write_text("import Beta\n", encoding="utf-8")
        (package / "Package.swift").write_text(IMPORT_FIXTURE_MANIFEST_DECLARED, encoding="utf-8")
        result = scan_import_graph([package])
        if result["violations"]:
            die("self-test FAIL：声明后的 import 仍被误报：%r" % (result["violations"],))
        if result["cycles"] != [["Alpha", "Beta"]]:
            die("self-test FAIL：target 级环没有被发现：%r" % (result["cycles"],))
        emit("self-test OK（未声明 import 1 处；声明后 0 违规；target 环 Alpha<->Beta 被发现）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test_module_size():
    tmp = Path(tempfile.mkdtemp(prefix="check-module-size-"))
    try:
        package = tmp / "fixture"
        tiny = package / "Sources" / "Tiny"
        tests = package / "Tests" / "TinyTests"
        tiny.mkdir(parents=True)
        tests.mkdir(parents=True)
        (package / "Package.swift").write_text(SIZE_FIXTURE_MANIFEST, encoding="utf-8")
        (tiny / "One.swift").write_text("let one = 1\nlet two = 2\nlet three = 3\n", encoding="utf-8")
        (tiny / "Two.swift").write_text("let four = 4\n", encoding="utf-8")
        (tests / "T.swift").write_text("let t1 = 1\nlet t2 = 2\nlet t3 = 3\nlet t4 = 4\n",
                                       encoding="utf-8")
        current = scan_module_size([package])
        tiny_stats = [t for t in current["targets"] if t["name"] == "Tiny"][0]
        if tiny_stats["files"] != 2 or tiny_stats["loc"] != 4 or tiny_stats["max_file_loc"] != 3:
            die("self-test FAIL：Tiny 统计异常：%r" % (tiny_stats,))
        package_stats = current["packages"][rel(package)]
        if package_stats["sources_loc"] != 4 or package_stats["tests_loc"] != 4:
            die("self-test FAIL：包级 LOC 统计异常：%r" % (package_stats,))
        baseline = {"targets": {"Tiny": {"files": 2, "loc": 3, "max_file_loc": 3}},
                    "packages": {rel(package): {"sources_loc": 3, "tests_loc": 4}}}
        problems, _notes = compare_module_size(current, baseline)
        if not problems:
            die("self-test FAIL：LOC 上涨没有被 compare 发现")
        (tiny / "One.swift").write_text("let one = 1\nlet two = 2\nlet three = 3\n", encoding="utf-8")
        baseline["targets"]["Tiny"] = {"files": 2, "loc": 4, "max_file_loc": 3}
        baseline["packages"][rel(package)] = {"sources_loc": 4, "tests_loc": 4}
        problems, _notes = compare_module_size(current, baseline)
        if problems:
            die("self-test FAIL：持平基线被误报：%r" % (problems,))
        emit("self-test OK（LOC 上涨被发现；持平不误报）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test_concurrency_whitelist():
    tmp = Path(tempfile.mkdtemp(prefix="check-concurrency-"))
    try:
        root = tmp / "Sources"
        root.mkdir(parents=True)
        (root / "Fixture.swift").write_text(CONCURRENCY_FIXTURE, encoding="utf-8")
        result = scan_concurrency([root])
        if result["totals"] != {"unchecked_sendable": 1, "nonisolated_unsafe": 1}:
            die("self-test FAIL：并发标注计数异常：%r" % (result["totals"],))
        keys = {(key[1], key[2]) for key in result["entries"]}
        if ("Inner", "unchecked_sendable") not in keys:
            die("self-test FAIL：嵌套类型 Inner 的 @unchecked Sendable 没有定位到：%r" % (keys,))
        if ("Cache", "nonisolated_unsafe") not in keys:
            die("self-test FAIL：Cache 的 nonisolated(unsafe) 没有定位到：%r" % (keys,))
        if any(key[1] in ("note", "<file-scope>") for key in result["entries"]):
            die("self-test FAIL：注释/字符串里的标记被误报：%r" % (result["entries"],))
        emit("self-test OK（嵌套类型/枚举定位正确；注释与字符串里的标记 0 误报）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test_layer_symbols():
    tmp = Path(tempfile.mkdtemp(prefix="check-layer-symbols-"))
    try:
        root = tmp / "GatherApplication"
        root.mkdir(parents=True)
        (root / "Fixture.swift").write_text(LAYER_FIXTURE, encoding="utf-8")
        result = scan_layer_symbols(root)
        patterns = sorted(hit["pattern"] for hit in result["hits"])
        if patterns != ["DBConnection", "Database("]:
            die("self-test FAIL：越界符号识别异常：%r" % (patterns,))
        if len(result["hints"]) != 1:
            die("self-test FAIL：.connection 提示计数异常：%d" % len(result["hints"]))
        emit("self-test OK（代码里的 DBConnection/Database( 命中 2 处；注释不误报；"
             ".connection 提示 1 处）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def self_test_public_surface():
    tmp = Path(tempfile.mkdtemp(prefix="check-public-surface-"))
    try:
        app = tmp / "app" / "Sources" / "GatherUI"
        api = tmp / "app" / "Sources" / "GatherProtocol" / "API"
        app.mkdir(parents=True)
        api.mkdir(parents=True)
        (app / "Fixture.swift").write_text(PUBLIC_FIXTURE_TARGET + PUBLIC_FIXTURE_TARGET_EXTENSION,
                                           encoding="utf-8")
        (api / "FixtureAPI.swift").write_text(PUBLIC_FIXTURE_API, encoding="utf-8")
        current = scan_public_surface([("GatherUI", app)], api)
        stats = current["targets"]["GatherUI"]
        # 6 个 public 类型：Widget/Mode/Host（属性前缀）+ Nested（缩进嵌套）+ Alpha/Beta（单行多声明）。
        if stats["public_types"] != 6:
            die("self-test FAIL：public 类型计数异常：%r" % (stats,))
        # 16 条 public 声明 = 10 条显式（Widget/let/func + Mode + Host/let + Nested/func
        # + Alpha/Beta）+ 6 条隐式成员（func/var/static func/属性前缀 func/init/带函数体的 func）。
        # public extension 头**不计**（count_explicit_public_declarations 减掉了头：
        # 头不是声明，计了会让 "public extension { func a }" 比等价写法多 1）。
        # private 成员与函数体里的局部 let 不计。
        if stats["public_declarations"] != 16:
            die("self-test FAIL：public 声明计数异常：%r" % (stats,))
        if current["implicit_extension_members"]["GatherUI"] != 6:
            die("self-test FAIL：public extension 隐式成员计数异常：%r"
                % (current["implicit_extension_members"],))
        # 往已有 public extension 追加一个成员：计数必须 +1（bug 现场是「不变」）。
        (app / "Fixture.swift").write_text(
            PUBLIC_FIXTURE_TARGET + PUBLIC_FIXTURE_TARGET_EXTENSION.replace(
                "    private func hidden() {}",
                PUBLIC_FIXTURE_EXTENSION_ADDED + "    private func hidden() {}"),
            encoding="utf-8")
        appended = scan_public_surface([("GatherUI", app)], api)["targets"]["GatherUI"]
        if appended["public_declarations"] != stats["public_declarations"] + 1:
            die("self-test FAIL：往已有 public extension 追加成员后计数没变：%r -> %r"
                % (stats["public_declarations"], appended["public_declarations"]))

        def rescan(added):
            (app / "Fixture.swift").write_text(
                PUBLIC_FIXTURE_TARGET + PUBLIC_FIXTURE_TARGET_EXTENSION.replace(
                    "    private func hidden() {}", added + "    private func hidden() {}"),
                encoding="utf-8")
            return scan_public_surface([("GatherUI", app)], api)

        # 追加显式 public func：走 PUBLIC_DECL_RE，隐式成员必须仍是 6（同一成员不能被
        # 两条正则各记一次），声明数 +1。
        explicit_added = rescan(PUBLIC_FIXTURE_EXTENSION_ADDED_EXPLICIT)
        if explicit_added["implicit_extension_members"]["GatherUI"] != 6:
            die("self-test FAIL：显式 public 成员被当成隐式成员：%r"
                % (explicit_added["implicit_extension_members"],))
        if explicit_added["targets"]["GatherUI"]["public_declarations"] != stats["public_declarations"] + 1:
            die("self-test FAIL：追加显式 public 成员后声明数没变：%r -> %r"
                % (stats["public_declarations"],
                   explicit_added["targets"]["GatherUI"]["public_declarations"]))

        # 追加 static let：修饰符白名单要认，隐式成员 +1（6 -> 7）。
        static_added = rescan(PUBLIC_FIXTURE_EXTENSION_ADDED_STATIC)
        if static_added["implicit_extension_members"]["GatherUI"] != 7:
            die("self-test FAIL：public extension 里的 static let 未计入：%r"
                % (static_added["implicit_extension_members"],))

        # 追加 typealias：extension 里的 typealias 也是隐式 public（旧白名单漏计）。
        typealias_added = rescan(PUBLIC_FIXTURE_EXTENSION_ADDED_TYPEALIAS)
        if typealias_added["implicit_extension_members"]["GatherUI"] != 7:
            die("self-test FAIL：public extension 里的 typealias 未计入：%r"
                % (typealias_added["implicit_extension_members"],))

        # 字符串里的 } 与 \" 必须被遮罩：旧 _STR_RE 漏 \" 时 block_body 在字符串里的
        # } 处提前闭合，tail() 整个丢失（隐式成员 1 而不是 2）。
        mask_dir = tmp / "mask" / "GatherUI"
        mask_dir.mkdir(parents=True)
        (mask_dir / "MaskFixture.swift").write_text(PUBLIC_FIXTURE_STRING_MASK, encoding="utf-8")
        masked = scan_public_surface([("GatherUI", mask_dir)], api)
        if masked["implicit_extension_members"]["GatherUI"] != 2:
            die("self-test FAIL：字符串里的 } 提前结束了 extension body：%r"
                % (masked["implicit_extension_members"],))
        if masked["targets"]["GatherUI"]["public_declarations"] != 2:
            die("self-test FAIL：字符串遮罩后声明数异常：%r"
                % (masked["targets"]["GatherUI"],))

        (app / "Fixture.swift").write_text(PUBLIC_FIXTURE_TARGET + PUBLIC_FIXTURE_TARGET_EXTENSION,
                                           encoding="utf-8")
        if current["api"]["public_protocols"] != 2:
            die("self-test FAIL：public protocol 计数异常：%r" % (current["api"],))
        if current["api"]["requirement_lines"] != 6:
            die("self-test FAIL：requirement 计数异常：%r" % (current["api"],))
        baseline = {
            "targets": {"GatherUI": {"files": 1, "public_types": 1,
                                     "public_declarations": 4}},
            "api": {"public_protocols": 1, "requirement_lines": 2},
        }
        problems, _notes = compare_public_surface(current, baseline)
        if len(problems) != 4:
            die("self-test FAIL：public 面上涨没有被 compare 全部发现：%r" % (problems,))
        exact = {
            "targets": {"GatherUI": {"files": 1, "public_types": stats["public_types"],
                                     "public_declarations": stats["public_declarations"]}},
            "api": {"public_protocols": current["api"]["public_protocols"],
                    "requirement_lines": current["api"]["requirement_lines"]},
        }
        problems, _notes = compare_public_surface(current, exact)
        if problems:
            die("self-test FAIL：持平基线被误报：%r" % (problems,))
        emit("self-test OK（属性前缀/缩进嵌套/单行多声明均计入：类型 6 / 声明 16"
             "（public extension 头不计 + 隐式成员 6，private 与函数体内局部 let 不计）/ "
             "protocol 2 / requirement 6；追加成员 +1 / 显式 public 不改隐式数 / "
             "static let 与 typealias 各 +1 / 字符串里的 } 被遮罩（隐式 2）；"
             "上涨被发现、持平不误报）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------- 入口

GATES = {
    "lock-order": gate_lock_order,
    "import-graph": gate_import_graph,
    "module-size": gate_module_size,
    "concurrency-whitelist": gate_concurrency_whitelist,
    "layer-symbols": gate_layer_symbols,
    "public-surface-app": gate_public_surface_app,
}


def main(argv):
    global PROG
    if not argv:
        err("缺少 gate 参数；可选：%s" % " / ".join(sorted(GATES)))
        return 2
    gate = argv[0]
    if gate not in GATES:
        err("未知 gate：%s；可选：%s" % (gate, " / ".join(sorted(GATES))))
        return 2
    PROG = PROG_MAP[gate]
    opts = parse_args(argv[1:])
    return GATES[gate](opts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
