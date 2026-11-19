#!/usr/bin/env python3
"""G6 端口/行类型表面门禁（2026-11-18 Wave 5 / M8 端口准入台账 + M10 行类型收敛；无有效 fake 端口数要求 fake 被测试引用）。

只读、Linux 可跑、只依赖 python3 标准库；扫描量下限 fail-closed；--self-test 用 mktemp fixture 做负样本自测
（端口/方法计数、行类型识别与注释遮罩、fake 声明与有效性、token 计数口径、聚合 ratchet、
逐端口方法数漂移、--write-baseline 无 --allow-growth 拒写、端口删除属收紧 note），不写仓库。

扫描口径（2026-11-18 性能轮：输出与旧实现逐字节一致）：
  - 注释遮罩：整文件一次正则（行首 /* 块注释 + // 行注释），保留字符串与行数（与旧逐行实现等价）；
  - 名字引用计数：单次 \w+ token 化 + Counter（\bname\b 不可重叠匹配数 ≡ 整词元计数），
    把 O(文件 × 名字数) 次 regex 扫描降为 O(文件) 次；
  - DBRow 单名字：子串预过滤命中后才跑精确 \bDBRow\b 正则（口径同前）。

守护：
  1) Persistence 端口协议数量与 requirement 方法总数（增长需 --allow-growth 并记账）；
  2) **无 fake 端口数**（端口准入台账覆盖率）与无**有效** fake 端口数（fake 必须被测试引用）只降不升；
  3) Persistence public 行类型数（*Row/*DTO/*Record；DBRow 是 SQLite 行数组别名，排除）只降不升；
  4) Application 对 Persistence public 行类型的引用数（M10 收敛目标）只降不升；
  5) Application/UI/Host 对 public DBRow 的引用数必须为 0。

ratchet 判定（纯函数，--self-test 覆盖负样本）：
  - 聚合指标上涨即违规（port 侧 3 项需 --allow-growth 并记账；其余 4 项只降不升）；
  - 端口身份：新增端口 / fake 覆盖回退 = 违规；删除端口 = 收紧（打 note，--write-baseline 固化为新基线）；
  - 逐端口方法数：当前 > 基线即违规（新增能力需 --allow-growth 并记账）；
  - --write-baseline：存在违规且未带 --allow-growth 时拒写（exit 1，不落盘）。

台账：docs/baselines/port-row-surface-baseline.json 记录每个端口的 file/name/methods/has_fake/has_effective_fake
（含逐端口方法数漂移检查），作为「端口准入台账」的可校验来源；聚合指标参与 ratchet。

用法：check-port-row-surface.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "desktop" / "native" / "gather-core"
APP = ROOT / "desktop" / "native" / "gather-app"
PORTS_DIR = CORE / "Sources" / "GatherPersistence" / "Ports"
APP_SRC = CORE / "Sources" / "GatherApplication"
UI_SRC = APP / "Sources" / "GatherUI"
HOST_SRC = APP / "Sources" / "GatherHost"
TESTS_DIRS = [CORE / "Tests", APP / "Tests"]
BASELINE = ROOT / "docs" / "baselines" / "port-row-surface-baseline.json"
PROG = "check-port-row-surface"

PROTOCOL_RE = re.compile(r"^public protocol (\w+)", re.M)
FUNC_RE = re.compile(r"^\s+(?:nonisolated\s+)?func\s", re.M)
ROW_RE = re.compile(r"^\s*public\s+(?:struct|enum|typealias)\s+(\w*(?:Row|DTO|Record))\b", re.M)
ROW_EXCLUDE = {"DBRow"}  # DBRow 是 SQLite 行数组别名（DBValues.swift），不是行投影 DTO
DBROW_RE = re.compile(r"\bDBRow\b")
WORD_RE = re.compile(r"\w+")                       # 词元化：\w+ 与 \bname\b 的整词匹配口径等价
UPPER_WORD_RE = re.compile(r"\b[A-Z]\w*")          # 仅大写开头词元：名字全为大写开头 ASCII 标识符时的快路径
UPPER_NAME_RE = re.compile(r"[A-Z][A-Za-z0-9_]*\Z")
BLOCK_COMMENT_RE = re.compile(r"(?sm)^[^\S\n]*/\*(?:.*?\*/[^\n]*|.*\Z)")
LINE_COMMENT_RE = re.compile(r"//[^\n]*")

USAGE = """用法：check-port-row-surface.sh [--strict] [--write-baseline [--allow-growth]] [--self-test]

  --strict           任一违规/上涨即 exit 1（默认 warning 模式 exit 0）
  --write-baseline   重写 docs/baselines/port-row-surface-baseline.json；默认拒绝上涨（含端口身份/逐端口方法数）
  --allow-growth     与 --write-baseline 连用，显式批准增长（端口数/methods/行类型数/新增端口）
  --self-test        用 mktemp fixture 做负样本自测（不写仓库；含 ratchet 纯函数断言）
"""

# 聚合 ratchet 口径：前 3 项增长需 --allow-growth 并记账，后 4 项只降不升
GROWTH_METRICS = ("ports", "port_methods", "persistence_public_row_types")
NO_GROWTH_METRICS = (
    "ports_without_fake",
    "ports_without_effective_fake",
    "persistence_row_refs_in_application",
    "dbrow_refs_outside_persistence",
)
ZERO_METRICS = ("dbrow_refs_outside_persistence",)


def read(p):
    return p.read_text(encoding="utf-8", errors="replace")


def mask_comments(text):
    """遮罩 // 行注释与行首 /* 块注释（保留字符串内容、行数与未注释代码）。

    与旧逐行实现等价：行首 /* 起块注释，本行含 */ 只遮本行，否则遮到含 */ 的行（含该行），
    未闭合块注释遮到文件尾；其余行按第一个 // 截断。
    实现改为整文件一次正则替换（按换行数回填，保持行号），避免逐行 Python 循环。
    """
    if "/*" in text:
        text = BLOCK_COMMENT_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    if "//" in text:
        text = LINE_COMMENT_RE.sub("", text)
    return text


_MASKED_CACHE = {}


def masked(p):
    """读取并注释遮罩（按路径缓存；scan() 内每个文件只读/遮罩一次）。"""
    key = str(p)
    text = _MASKED_CACHE.get(key)
    if text is None:
        text = mask_comments(read(p))
        _MASKED_CACHE[key] = text
    return text


def token_re(names):
    """选词元正则：names 全为大写开头 ASCII 标识符时用大写词元快路径（计数与全词元等价），否则用全词元。"""
    if names and all(UPPER_NAME_RE.match(n) for n in names):
        return UPPER_WORD_RE
    return WORD_RE


def token_counts(texts, names):
    """统计 names 的整词出现次数：单次词元化 + Counter（口径 = \bname\b 不可重叠匹配数）。"""
    rx = token_re(names)
    counts = Counter()
    for text in texts:
        counts.update(rx.findall(text))
    return counts


def rel(p):
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def swift_files(root):
    if not root.exists():
        return []
    return sorted(p for p in root.rglob("*.swift"))


def scan_ports(ports_dir):
    files = swift_files(ports_dir)
    ports = []
    for p in files:
        text = masked(p)
        for m in PROTOCOL_RE.finditer(text):
            name = m.group(1)
            depth = 0
            i = m.end() - 1
            started = False
            while i < len(text):
                if text[i] == "{":
                    started = True
                    depth += 1
                elif text[i] == "}":
                    depth -= 1
                    if started and depth == 0:
                        break
                i += 1
            body = text[m.end():i]
            methods = len(FUNC_RE.findall(body))
            ports.append({"file": rel(p), "name": name, "methods": methods})
    return {"files": len(files), "ports": ports}


DECL_CONFORMANCE_RE = re.compile(
    r"\b(?:class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
    r"\s*(?::\s*([^{\n]+?))?\s*\{")


def parse_conformance_pairs(text):
    """返回 [(声明类型名, [conformance 协议名...])]，用于端口准入台账。"""
    pairs = []
    for m in DECL_CONFORMANCE_RE.finditer(text):
        decl = m.group(1)
        if not m.group(2):
            continue
        protos = []
        for part in m.group(2).split(","):
            name = part.strip().split()[0] if part.strip() else ""
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                protos.append(name)
        if protos:
            pairs.append((decl, protos))
    return pairs


def fake_analysis(test_texts):
    """返回 (声明了 fake 的协议集合, 被测试实际引用过的有效 fake 协议集合)。

    有效 fake = 该 fake 类型在测试文本里被引用不止一次（定义之外至少一处使用），
    避免「声明即算 fake」把 ports_without_fake 指标做成空壳。
    计数口径：单次词元化 + Counter（与旧 \bdecl\b 的 re.findall 计数和等价；名字全为大写开头时走大写词元快路径）。
    """
    pairs = []
    for text in test_texts:
        pairs.extend(parse_conformance_pairs(text))
    counts = token_counts(test_texts, [decl for decl, _protos in pairs])
    declared = set()
    effective = set()
    for decl, protos in pairs:
        declared.update(protos)
        if counts.get(decl, 0) > 1:
            effective.update(protos)
    return declared, effective


def fake_conformances():
    texts = []
    for root in TESTS_DIRS:
        for p in swift_files(root):
            texts.append(masked(p))
    declared, _effective = fake_analysis(texts)
    return declared


def count_row_types():
    n = 0
    rows = []
    for p in swift_files(CORE / "Sources" / "GatherPersistence"):
        text = masked(p)
        for m in ROW_RE.finditer(text):
            if m.group(1) in ROW_EXCLUDE:
                continue
            n += 1
            rows.append(m.group(1))
    return n, rows


def count_refs(roots, patterns):
    """返回 (引用总数, {相对路径: 引用数})，口径 = 每个 pattern 的 \bpattern\b 不可重叠匹配数之和。

    多名字走单次词元化 + Counter；单名字（DBRow）先子串预过滤，命中才跑精确正则。
    """
    total = 0
    per = {}
    single = len(patterns) == 1
    if single:
        single_re = re.compile(r"\b" + re.escape(patterns[0]) + r"\b")
        names_re = None
    else:
        single_re = None
        names_re = token_re(patterns)
    for root in roots:
        for p in swift_files(root):
            text = masked(p)
            if single:
                if patterns[0] not in text:
                    continue
                c = len(single_re.findall(text))
            else:
                counts = Counter(names_re.findall(text))
                c = sum(counts.get(x, 0) for x in patterns)
            if c:
                per[rel(p)] = c
                total += c
    return total, per


def scan():
    port_scan = scan_ports(PORTS_DIR)
    test_texts = []
    for root in TESTS_DIRS:
        for p in swift_files(root):
            test_texts.append(masked(p))
    fakes, effective = fake_analysis(test_texts)
    ports = port_scan["ports"]
    without_fake = [p for p in ports if p["name"] not in fakes]
    without_effective = [p for p in ports if p["name"] not in effective]
    row_count, row_names = count_row_types()
    # D2 泄漏面：Application 仍在引用「Persistence 侧声明的」行类型（M10 三热点迁走后应显著下降）
    for port in ports:
        port["has_fake"] = port["name"] in fakes
        port["has_effective_fake"] = port["name"] in effective
    hot_refs, hot_detail = count_refs([APP_SRC], row_names)
    dbrow_refs, dbrow_detail = count_refs([APP_SRC, UI_SRC, HOST_SRC], ["DBRow"])
    return {
        "scan": {
            "port_files": port_scan["files"],
            "ports": len(ports),
            "app_sources": len(swift_files(APP_SRC)),
        },
        "metrics": {
            "ports": len(ports),
            "port_methods": sum(p["methods"] for p in ports),
            "ports_without_fake": len(without_fake),
            "ports_without_effective_fake": len(without_effective),
            "persistence_public_row_types": row_count,
            "persistence_row_refs_in_application": hot_refs,
            "dbrow_refs_outside_persistence": dbrow_refs,
        },
        "ports": sorted(ports, key=lambda p: p["name"]),
        "detail": {
            "without_fake": sorted(p["name"] for p in without_fake),
            "without_effective_fake": sorted(p["name"] for p in without_effective),
            "row_type_names": row_names,
            "row_refs": hot_detail,
            "dbrow_refs": dbrow_detail,
        },
    }


def load_baseline(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def save_baseline(path, data):
    """原子写：同目录临时文件 + os.replace，避免中断留下半截 JSON。"""
    import os
    import tempfile

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".port-row-baseline.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def metric_ratchet_findings(cur, old):
    """聚合指标 ratchet（纯函数）：返回 (违规列表, 收紧指标列表)。"""
    growth = [k for k in GROWTH_METRICS if k in old and cur.get(k, 0) > old[k]]
    regress = [k for k in NO_GROWTH_METRICS if k in old and cur.get(k, 0) > old[k]]
    tightened = [k for k in cur if k in old and cur[k] < old[k]]
    violations = ["%s 上涨：%d > %d" % (k, cur[k], old[k]) for k in growth + regress]
    for k in ZERO_METRICS:
        if cur.get(k, 0) > 0:
            violations.append("%s = %d（必须为 0）" % (k, cur[k]))
    return violations, tightened


def port_method_findings(current_ports, base_ports):
    """逐端口方法数漂移（纯函数）：返回 [(端口名, 当前方法数, 基线方法数)]，当前 > 基线即需 --allow-growth。"""
    findings = []
    for port in current_ports:
        before = base_ports.get(port["name"])
        before_methods = before.get("methods") if isinstance(before, dict) else before
        if before_methods is not None and port["methods"] > before_methods:
            findings.append((port["name"], port["methods"], before_methods))
    return findings


def port_identity_findings(current_ports, base_ports):
    """端口身份 ratchet（纯函数）：返回 (违规列表, 收紧 note 列表)。

    新增端口 / fake 覆盖回退 = 违规（聚合数相同但「删旧加新」必须显式批准）；
    删除端口 = 收紧，只打 note（--write-baseline 固化为新基线）。
    """
    problems = []
    notes = []
    current = {p["name"]: p for p in current_ports}
    base = {name: p for name, p in base_ports.items() if isinstance(p, dict)}
    for name in sorted(set(current) - set(base)):
        problems.append("新增端口 %s（端口准入需 --allow-growth 并在 docs/cleanup-backlog.md 记账）" % name)
    for name in sorted(set(base) - set(current)):
        notes.append("端口 %s 已删除（收紧；--write-baseline 固化）" % name)
    for name in sorted(set(current) & set(base)):
        if base[name].get("has_fake") and not current[name].get("has_fake"):
            problems.append("端口 %s 的 fake 覆盖回退（基线有 fake、当前没有）" % name)
        if base[name].get("has_effective_fake") and not current[name].get("has_effective_fake"):
            problems.append("端口 %s 的有效 fake 回退（fake 未被测试使用）" % name)
    return problems, notes


def baseline_write_refusal(violations, allow_growth):
    """--write-baseline 拒写判定（纯函数）：有违规且未显式 --allow-growth 时返回拒写原因。"""
    if violations and not allow_growth:
        return list(violations)
    return []


def main(argv):
    strict = write = allow_growth = self_test = False
    for a in argv:
        if a == "--strict":
            strict = True
        elif a == "--write-baseline":
            write = True
        elif a == "--allow-growth":
            allow_growth = True
        elif a == "--self-test":
            self_test = True
        elif a in ("-h", "--help"):
            print(USAGE)
            return 0
        else:
            print(PROG + ": 未知参数：" + a, file=sys.stderr)
            return 2
    if self_test:
        return self_test_impl()
    result = scan()
    if result["scan"]["port_files"] < 25:
        print(PROG + ": 扫描量异常：Ports 目录只扫到 %d 个 Swift 文件（<25）" % result["scan"]["port_files"], file=sys.stderr)
        return 2
    if result["metrics"]["ports"] < 38:
        print(PROG + ": 扫描量异常：只识别到 %d 个端口协议（<38）" % result["metrics"]["ports"], file=sys.stderr)
        return 2
    baseline = load_baseline(BASELINE)
    old = baseline.get("metrics", {})
    cur = result["metrics"]
    violations, tightened = metric_ratchet_findings(cur, old)
    base_ports = {p.get("name"): p for p in baseline.get("ports", [])}
    identity_findings, identity_notes = port_identity_findings(result["ports"], base_ports)
    violations.extend(identity_findings)
    violations.extend("端口 %s 方法数上涨：%d > %d（新增能力需 --allow-growth 并记账）" % finding
                      for finding in port_method_findings(result["ports"], base_ports))
    notes = ["%s 下降：%d（可 --write-baseline 收紧）" % (k, cur[k]) for k in tightened]
    notes.extend(identity_notes)
    print("%s: 端口 %d / 方法 %d / 无 fake %d / 无有效 fake %d / Persistence public 行类型 %d / App 行引用 %d / DBRow 外溢 %d"
          % (PROG, cur["ports"], cur["port_methods"], cur["ports_without_fake"], cur["ports_without_effective_fake"],
             cur["persistence_public_row_types"], cur["persistence_row_refs_in_application"],
             cur["dbrow_refs_outside_persistence"]))
    for note in notes:
        print("  note " + note)
    if write:
        refusals = baseline_write_refusal(violations, allow_growth)
        if refusals:
            for v in refusals:
                print("  REFUSED: " + v, file=sys.stderr)
            print("  如需有意增长，改用 --write-baseline --allow-growth 并在 docs/cleanup-backlog.md 记账", file=sys.stderr)
            return 1
        data = {
            "schema": 2,
            "generated_by": "scripts/check-port-row-surface.sh --write-baseline",
            "note": ("G6 端口/行类型表面 ratchet + 端口准入台账（M8/M10）。"
                     "ports/port_methods/persistence_public_row_types 增长需 --allow-growth；"
                     "ports_without_fake / ports_without_effective_fake / persistence_row_refs_in_application / "
                     "dbrow_refs_outside_persistence 只降不升。"),
            "scan": result["scan"],
            "metrics": cur,
            "ports": result["ports"],
            "detail": result["detail"],
        }
        save_baseline(BASELINE, data)
        print(PROG + ": baseline 已写入 docs/baselines/port-row-surface-baseline.json")
        return 0
    if not old:
        print(PROG + ": 基线缺失（先 --write-baseline）", file=sys.stderr)
        return 2 if strict else 0
    if violations:
        for v in violations:
            print("  FAIL: " + v, file=sys.stderr)
        if strict:
            print(PROG + ": FAILED (--strict)", file=sys.stderr)
            return 1
        print(PROG + ": WARN（warning 模式；使用 --strict 作为硬门禁）", file=sys.stderr)
        return 0
    print(PROG + ": OK" + (" (--strict)" if strict else ""))
    return 0


def self_test_impl():
    import shutil
    import tempfile

    tmp = Path(tempfile.mkdtemp(prefix="check-port-row-"))
    try:
        ports = tmp / "Ports"
        ports.mkdir(parents=True)
        (ports / "Demo.swift").write_text(
            "public protocol DemoReading: Sendable {\n    func a() -> Int\n    func b(x: String) throws\n}\n",
            encoding="utf-8")
        scan_result = scan_ports(ports)
        if len(scan_result["ports"]) != 1 or scan_result["ports"][0]["methods"] != 2:
            print(PROG + ": self-test FAIL 端口/方法计数：%r" % scan_result, file=sys.stderr)
            return 1
        row_file = tmp / "Rows.swift"
        row_file.write_text("public struct HiddenRow {} // public struct CommentRow {}\n", encoding="utf-8")
        matched = ROW_RE.findall(mask_comments(row_file.read_text(encoding="utf-8")))
        if matched != ["HiddenRow"]:
            print(PROG + ": self-test FAIL 行类型/注释遮罩：%r" % matched, file=sys.stderr)
            return 1
        test_text = "final class PortFakeDemo: DemoReading, OtherReading {}\n"
        declared, effective = fake_analysis([test_text])
        if declared != {"DemoReading", "OtherReading"} or effective:
            print(PROG + ": self-test FAIL fake 声明解析：%r/%r" % (declared, effective), file=sys.stderr)
            return 1
        declared2, effective2 = fake_analysis([test_text + "let fake = PortFakeDemo()\n"])
        if effective2 != {"DemoReading", "OtherReading"}:
            print(PROG + ": self-test FAIL fake 有效性（被引用后应有效）：%r" % (effective2,), file=sys.stderr)
            return 1
        nested = "    public struct NestedRow: Sendable {}\n// public struct CommentRow {}\n"
        if ROW_RE.findall(mask_comments(nested)) != ["NestedRow"]:
            print(PROG + ": self-test FAIL 嵌套/注释行类型：%r" % (ROW_RE.findall(mask_comments(nested)),), file=sys.stderr)
            return 1
        if not re.search(r"\bDBRow\b", "func f(row: DBRow) {}"):
            print(PROG + ": self-test FAIL DBRow 检测", file=sys.stderr)
            return 1
        # 注释遮罩：行首块注释（单行/多行/未闭合）与行注释，保留字符串内容
        block_masked = mask_comments(
            "let a = \"BlockRow\"\n/* struct CommentRow {}\n* struct StillRow {} */\npublic struct KeptRow {}\n")
        if ROW_RE.findall(block_masked) != ["KeptRow"]:
            print(PROG + ": self-test FAIL 块注释遮罩：%r" % (ROW_RE.findall(block_masked),), file=sys.stderr)
            return 1
        unclosed_masked = mask_comments("public struct TopRow {}\n/*\npublic struct TailRow {}\n")
        if ROW_RE.findall(unclosed_masked) != ["TopRow"]:
            print(PROG + ": self-test FAIL 未闭合块注释遮罩：%r" % (ROW_RE.findall(unclosed_masked),), file=sys.stderr)
            return 1
        # token 计数口径：多名字 token 路径与单名字预过滤路径都必须等于旧 \bname\b 参考计数
        app = tmp / "App"
        app.mkdir()
        naming = ("public struct FooRow {}\n"
                  "func use() {\n"
                  "    _ = FooRow()\n"
                  "    _ = FooRowExtra()\n"
                  "    let fooRow = 1\n"
                  "    let s = \"FooRow\"\n"
                  "    // FooRow 注释里不计数\n"
                  "}\n")
        (app / "Naming.swift").write_text(naming, encoding="utf-8")
        ref_names = ["FooRow", "fooRow", "FooRowExtra"]
        reference = sum(len(re.findall(r"\b" + re.escape(x) + r"\b", mask_comments(naming))) for x in ref_names)
        total, detail = count_refs([app], ref_names)
        if total != reference or total != 5 or list(detail.values()) != [5]:
            print(PROG + ": self-test FAIL token 计数口径：%r/%r（参考 %d）" % (total, detail, reference), file=sys.stderr)
            return 1
        if token_re(["FooRow"]) is not UPPER_WORD_RE or token_re(["FooRow", "fooRow"]) is not WORD_RE:
            print(PROG + ": self-test FAIL 词元快路径选择（全大写开头走快路径，含小写名走全词元回退）", file=sys.stderr)
            return 1
        single_total, _single_detail = count_refs([app], ["FooRow"])
        if single_total != 3:
            print(PROG + ": self-test FAIL 单名字预过滤计数：%r" % (single_total,), file=sys.stderr)
            return 1
        # 聚合 ratchet 负样本：端口数 / 方法数 / 行类型数上涨必须违规；下降只算收紧
        violations, tightened = metric_ratchet_findings(
            {"ports": 45, "port_methods": 341, "persistence_public_row_types": 81},
            {"ports": 44, "port_methods": 340, "persistence_public_row_types": 80})
        if not violations or tightened:
            print(PROG + ": self-test FAIL 聚合上涨未违规：%r/%r" % (violations, tightened), file=sys.stderr)
            return 1
        violations2, tightened2 = metric_ratchet_findings(
            {"ports": 43, "port_methods": 339, "persistence_public_row_types": 76,
             "ports_without_fake": 15, "ports_without_effective_fake": 15,
             "persistence_row_refs_in_application": 46, "dbrow_refs_outside_persistence": 0},
            {"ports": 44, "port_methods": 340, "persistence_public_row_types": 80,
             "ports_without_fake": 16, "ports_without_effective_fake": 16,
             "persistence_row_refs_in_application": 76, "dbrow_refs_outside_persistence": 0})
        if violations2 or "ports" not in tightened2:
            print(PROG + ": self-test FAIL 收紧判定：%r/%r" % (violations2, tightened2), file=sys.stderr)
            return 1
        # 逐端口方法数漂移：当前 > 基线即违规，相等/下降不算
        method_growth = port_method_findings(
            [{"name": "DemoReading", "methods": 3, "has_fake": True}],
            {"DemoReading": {"name": "DemoReading", "methods": 2, "has_fake": True}})
        if method_growth != [("DemoReading", 3, 2)]:
            print(PROG + ": self-test FAIL 端口方法数上涨：%r" % (method_growth,), file=sys.stderr)
            return 1
        if port_method_findings([{"name": "DemoReading", "methods": 2}],
                                {"DemoReading": {"name": "DemoReading", "methods": 2}}):
            print(PROG + ": self-test FAIL 端口方法数相等误报", file=sys.stderr)
            return 1
        # 端口身份：删除属收紧 note；新增/fake 覆盖回退属违规
        base_ports = {"OldPort": {"name": "OldPort", "methods": 2, "has_fake": True, "has_effective_fake": True}}
        identity_violations, identity_notes = port_identity_findings([], base_ports)
        if identity_violations or not any("OldPort" in n and "已删除" in n for n in identity_notes):
            print(PROG + ": self-test FAIL 端口删除收紧 note：%r/%r" % (identity_violations, identity_notes), file=sys.stderr)
            return 1
        added_violations, _added_notes = port_identity_findings(
            [{"name": "NewPort", "methods": 1, "has_fake": True}], base_ports)
        if not any("新增端口 NewPort" in v for v in added_violations):
            print(PROG + ": self-test FAIL 新增端口未违规：%r" % (added_violations,), file=sys.stderr)
            return 1
        fake_violations, _fake_notes = port_identity_findings(
            [{"name": "OldPort", "methods": 2, "has_fake": False, "has_effective_fake": False}], base_ports)
        if not any("fake 覆盖回退" in v for v in fake_violations):
            print(PROG + ": self-test FAIL fake 覆盖回退未违规：%r" % (fake_violations,), file=sys.stderr)
            return 1
        # --write-baseline 拒写：有违规且无 --allow-growth 必须拒写；显式 allow-growth 或无违规才放行
        if not baseline_write_refusal(["ports 上涨：45 > 44"], False):
            print(PROG + ": self-test FAIL --write-baseline 未拒写违规", file=sys.stderr)
            return 1
        if baseline_write_refusal(["ports 上涨：45 > 44"], True):
            print(PROG + ": self-test FAIL --allow-growth 仍拒写", file=sys.stderr)
            return 1
        if baseline_write_refusal([], False):
            print(PROG + ": self-test FAIL 无违规仍拒写", file=sys.stderr)
            return 1
        print(PROG + ": self-test OK（端口/方法计数、行类型识别与注释/块注释遮罩、fake 声明/有效性、"
              "token 与单名字预过滤计数口径、聚合 ratchet、逐端口方法数漂移、端口身份收紧 note、--write-baseline 拒写）")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
