#!/usr/bin/env python3
r"""测试成本审计（report-only，非 CI 门禁；Linux 可跑）。

背景：测试套件的墙钟成本主要发生在 macOS（swift test），但 Linux 无 macOS SDK
不能实测。本工具在 Linux 上做**静态成本代理**扫描：统计 desktop/native/*/Tests
下高成本模式的出现次数，按加权分数排序输出 Top N 与仓库总计，供挑选
「需 macOS 实测」的测试改造候选。它不测量耗时，也不参与任何门禁/CI。

成本代理与权重（只用于排序；权重是经验值，不是耗时测量）：
  db_open     5  真实库打开：Database.open / DBConnection(path:)
  db_memory   2  内存库打开：Database.openInMemory
  temp_io     3  临时目录/文件写：FileManager.default.temporaryDirectory /
                 NSTemporaryDirectory / write(to:) / createDirectory（逐事件合计）
  sleep       4  固定 sleep：Thread.sleep / Task.sleep 且参数含数字常量
  process     4  Process()：外部进程启动/等待
  vision_ml   3  Vision/CoreML 引用：Vision、CoreML、VN* 类型、MLModel* 类型
  large_image 2  大尺寸图像字面量：width/height 字面量 >= 2000（逐维计数）
  tests       1  @Test 用例数（每用例的调度/夹具基础成本）

口径与限制：
  - 注释与字符串字面量先整体遮罩（换成等长空格、保留换行），其中的字样不计入，
    避免夹具/文案字符串误报；raw string（#"..."#）与嵌套块注释同样遮罩。
  - 只统计模式命中次数，不追踪 helper 调用链：经 TestSupport 公共函数建库/建目录
    时成本只在定义处计一次。
  - DBConnection(path: ":memory:") 与文件库路径不区分（模式级计数）。
  - 输出确定性：同一份仓库重复运行逐字节一致（无时间戳，排序键固定）。

用法：
  python3 scripts/audit-test-costs.py [--root <repo 根>] [--top 40] [--json]
  python3 scripts/audit-test-costs.py --self-test   # mktemp 合成夹具自测
  python3 scripts/audit-test-costs.py --help

退出码：0 成功；1 扫描根缺失/无 *.swift/文件不可读（fail closed，不静默空报告）；
        2 参数用法错误（argparse）。

报告口径：**report-only 非 CI**；单用例真实耗时与优化收益 **需 macOS 实测**
（scripts/profile-tests.sh / swift test --event-stream-output-path）。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

# 扫描根（相对仓库根；与 task-44 要求一致：desktop/native/*/Tests）。
SCAN_ROOTS = (
    "desktop/native/gather-core/Tests",
    "desktop/native/gather-app/Tests",
)

# 加权表：score = Σ(命中次数 × 权重)。权重只影响排序，不是耗时测量。
WEIGHTS = {
    "db_open": 5,
    "db_memory": 2,
    "temp_io": 3,
    "sleep": 4,
    "process": 4,
    "vision_ml": 3,
    "large_image": 2,
    "tests": 1,
}
WEIGHT_ORDER = (
    "db_open", "db_memory", "temp_io", "sleep",
    "process", "vision_ml", "large_image", "tests",
)

# 每类成本代理的识别模式（全部作用在「注释/字符串已遮罩」的源码上）。
PATTERNS = {
    # 真实库打开：Database.open 不匹配 Database.openInMemory；DBConnection(path: 兼容文件/内存库。
    "db_open": re.compile(
        r"\bDatabase\s*\.\s*open(?!InMemory)\b"
        r"|\bDBConnection\s*\(\s*path\s*:"),
    "db_memory": re.compile(r"\bDatabase\s*\.\s*openInMemory\b"),
    "temp_dir": re.compile(
        r"\bFileManager\s*\.\s*default\s*\.\s*temporaryDirectory\b"
        r"|\bNSTemporaryDirectory\s*\("),
    "create_dir": re.compile(r"\bcreateDirectory\s*\("),
    "file_write": re.compile(r"\.write\s*\(\s*to\s*:"),
    "process": re.compile(r"(?<![\w])Process\s*\("),
    "vision_ml": re.compile(
        r"\b(?:Vision|CoreML)\b|\bMLModel\w*|\bVN[A-Z]\w*"),
    "tests": re.compile(r"^[ \t]*@Test([ \t(]|$)", re.M),
}
# sleep 需要先取出括号内参数，按「参数含数字常量」区分固定/变量。
SLEEP_START_RE = re.compile(r"\b(?:Thread|Task)\s*\.\s*sleep\s*\(")
DIGIT_RE = re.compile(r"[0-9]")
LARGE_DIM_RE = re.compile(r"\b(?:width|height)\s*:\s*([0-9][0-9_]*)")
LARGE_IMAGE_THRESHOLD = 2000

DEFAULT_TOP = 40

# totals / 每文件 JSON 字段顺序（固定顺序保证输出确定性）。
TOTAL_ORDER = (
    "files", "score", "tests", "db_open", "db_memory",
    "temp_io", "temp_dir", "create_dir", "file_write",
    "sleep", "sleep_variable", "process", "vision_ml", "large_image",
)


class AuditError(Exception):
    """可预期的数据问题（main 转 stderr + 退出码 1，不打印 traceback）。"""


def _blank_range(out, start, end):
    """把 out[start:end] 换成空格（保留换行与总长度，行号不漂移）。"""
    limit = min(end, len(out))
    for index in range(start, limit):
        if out[index] != "\n":
            out[index] = " "


def mask_source(text):
    """遮罩 Swift 注释与字符串字面量内容（等长空格、保留换行）。

    覆盖 // 行注释、可嵌套 /* */ 块注释、普通/三引号/raw（#"..."#）字符串与转义；
    避免注释与夹具字符串里的成本模式被误计入（自测用合成夹具验证）。
    """
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        ch = text[i]
        if ch == "#":
            # raw string：开头 # 与字符串内容一起遮罩（###"..."### 同理）。
            j = i
            while j < n and text[j] == "#":
                j += 1
            if j < n and text[j] == '"':
                hashes = j - i
                if text.startswith('"""', j):
                    close = '"""' + "#" * hashes
                    found = text.find(close, j + 3)
                    end = n if found < 0 else found + len(close)
                else:
                    close = '"' + "#" * hashes
                    found = text.find(close, j + 1)
                    end = n if found < 0 else found + len(close)
                _blank_range(out, i, end)
                i = end
                continue
            i += 1
            continue
        if ch == '"':
            if text.startswith('"""', i):
                found = text.find('"""', i + 3)
                end = n if found < 0 else found + 3
            else:
                j = i + 1
                while j < n:
                    if text[j] == "\\":
                        j += 2
                        continue
                    if text[j] in ('"', "\n"):
                        j += 1
                        break
                    j += 1
                end = min(j, n)
            _blank_range(out, i, end)
            i = end
            continue
        if text.startswith("//", i):
            found = text.find("\n", i)
            end = n if found < 0 else found
            _blank_range(out, i, end)
            i = end
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
            end = min(j, n)
            _blank_range(out, i, end)
            i = end
            continue
        i += 1
    return "".join(out)


def _paren_argument(text, open_index):
    """返回 (括号内文本, 右括号之后的位置)；未闭合时取到文本末尾。"""
    depth = 0
    n = len(text)
    i = open_index
    while i < n:
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:i], i + 1
        i += 1
    return text[open_index + 1:], n


def count_sleeps(masked):
    """数 (固定 sleep, 变量 sleep)：参数含数字常量算固定，否则算变量。"""
    fixed = 0
    variable = 0
    position = 0
    while True:
        match = SLEEP_START_RE.search(masked, position)
        if match is None:
            return fixed, variable
        argument, position = _paren_argument(masked, match.end() - 1)
        if DIGIT_RE.search(argument):
            fixed += 1
        else:
            variable += 1


def count_large_images(masked):
    """数 width/height 字面量 >= 阈值（逐维计数；下划线分隔视为同一字面量）。"""
    count = 0
    for match in LARGE_DIM_RE.finditer(masked):
        try:
            value = int(match.group(1).replace("_", ""))
        except ValueError:
            continue
        if value >= LARGE_IMAGE_THRESHOLD:
            count += 1
    return count


def scan_file(path, relative_path):
    """扫描单个 Swift 文件，返回成本代理计数字典（含 score）。"""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise AuditError("无法读取 %s：%s" % (relative_path, exc))
    masked = mask_source(text)
    counts = {}
    for key in ("db_open", "db_memory", "temp_dir", "create_dir",
                "file_write", "process", "vision_ml", "tests"):
        counts[key] = len(PATTERNS[key].findall(masked))
    counts["sleep"], counts["sleep_variable"] = count_sleeps(masked)
    counts["large_image"] = count_large_images(masked)
    counts["temp_io"] = counts["temp_dir"] + counts["create_dir"] + counts["file_write"]
    counts["score"] = sum(counts[key] * WEIGHTS[key] for key in WEIGHT_ORDER)
    counts["path"] = relative_path
    return counts


def scan(root):
    """扫描两个测试根；没有可用根或没有 *.swift 时 fail closed（AuditError）。"""
    roots = []
    for relative in SCAN_ROOTS:
        candidate = root / relative
        if candidate.is_dir():
            roots.append((relative, candidate))
    if not roots:
        raise AuditError(
            "扫描根不存在：%s（请用 --root 指向仓库根）" % "、".join(SCAN_ROOTS))
    files = []
    for _, directory in roots:
        for swift_file in sorted(directory.rglob("*.swift")):
            relative_path = swift_file.relative_to(root).as_posix()
            files.append(scan_file(swift_file, relative_path))
    if not files:
        raise AuditError(
            "扫描根下没有 *.swift：%s" % "、".join(item[0] for item in roots))
    files.sort(key=lambda item: (-item["score"], -item["tests"], item["path"]))
    totals = {"files": len(files)}
    for key in TOTAL_ORDER:
        if key == "files":
            continue
        totals[key] = sum(item[key] for item in files)
    return {
        "files": files,
        "scan_roots": [item[0] for item in roots],
        "totals": totals,
    }


def _file_entry(item):
    """每文件 JSON 条目（字段顺序固定）。"""
    entry = {"path": item["path"], "score": item["score"]}
    for key in TOTAL_ORDER:
        if key in ("files", "score"):
            continue
        entry[key] = item[key]
    return entry


def build_json(result, top_n):
    """构造机器可读结果（无时间戳；重复运行逐字节一致）。"""
    totals = result["totals"]
    return {
        "schema": 1,
        "tool": "audit-test-costs.py",
        "report_only": True,
        "ci_gate": False,
        "note": "report-only 非 CI 门禁；成本为静态模式代理，单用例真实耗时与收益"
                "需 macOS 实测（scripts/profile-tests.sh / swift test 事件流）",
        "scan_roots": result["scan_roots"],
        "weights": {key: WEIGHTS[key] for key in WEIGHT_ORDER},
        "files_scanned": totals["files"],
        "top": [_file_entry(item) for item in result["files"][:top_n]],
        "totals": {key: totals[key] for key in TOTAL_ORDER},
    }


def _display_width(text):
    """终端显示宽度（CJK 全角字符按 2 列）。"""
    width = 0
    for ch in text:
        width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return width


def _pad(text, width, align):
    padding = max(0, width - _display_width(text))
    return (" " * padding + text) if align == ">" else (text + " " * padding)


TABLE_HEADER = ("#", "分数", "@Test", "库开", "内存", "临时",
                "sleep", "进程", "ML", "大图", "文件")


def _table_row(rank, item):
    return (
        str(rank),
        str(item["score"]),
        str(item["tests"]),
        str(item["db_open"]),
        str(item["db_memory"]),
        str(item["temp_io"]),
        str(item["sleep"]),
        str(item["process"]),
        str(item["vision_ml"]),
        str(item["large_image"]),
        item["path"],
    )


def render_text(result, top_n):
    """人类可读报告：Top N 表格 + 仓库总计 + report-only/macOS 实测口径。"""
    totals = result["totals"]
    top = result["files"][:top_n]
    lines = [
        "== 测试成本审计（report-only，非 CI 门禁；静态成本代理不等于耗时测量）==",
        "扫描根: " + "、".join(result["scan_roots"]),
        "文件: %d 个 Swift（测试/支撑）  @Test: %d" % (totals["files"], totals["tests"]),
        "权重: " + " ".join("%s=%d" % (key, WEIGHTS[key]) for key in WEIGHT_ORDER),
        "      temp_io = temporaryDirectory/NSTemporaryDirectory/write(to:)/createDirectory 事件合计；"
        "large_image 按 width/height 字面量逐维计数；",
        "      权重只用于排序（静态命中数 × 权重），本工具不测量真实耗时。",
        "",
        "成本 Top %d（共 %d 个文件；同分按 @Test 数、路径排序）:"
        % (len(top), totals["files"]),
    ]
    rows = [_table_row(rank, item) for rank, item in enumerate(top, 1)]
    widths = []
    for column in range(len(TABLE_HEADER)):
        cells = [TABLE_HEADER[column]] + [row[column] for row in rows]
        widths.append(max(_display_width(cell) for cell in cells))

    def format_row(cells):
        padded = [
            _pad(cell, widths[column], "<" if column == len(cells) - 1 else ">")
            for column, cell in enumerate(cells)
        ]
        return "  ".join(padded)

    lines.append(format_row(TABLE_HEADER))
    lines.extend(format_row(row) for row in rows)
    lines.extend([
        "",
        "仓库总计: score=%d；文件=%d；@Test=%d"
        % (totals["score"], totals["files"], totals["tests"]),
        "  db_open=%d（Database.open / DBConnection(path:)）"
        "  db_memory=%d（Database.openInMemory）"
        % (totals["db_open"], totals["db_memory"]),
        "  temp_io=%d（临时目录 %d / createDirectory %d / write(to:) %d）"
        % (totals["temp_io"], totals["temp_dir"], totals["create_dir"],
           totals["file_write"]),
        "  sleep=%d（另有变量 sleep %d，不计分）  process=%d  vision_ml=%d  large_image=%d"
        % (totals["sleep"], totals["sleep_variable"], totals["process"],
           totals["vision_ml"], totals["large_image"]),
        "说明: report-only 非 CI；排序只是选题参考，单用例真实耗时与优化收益需 macOS 实测"
        "（scripts/profile-tests.sh / swift test --event-stream-output-path）。",
    ])
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 自测夹具
# 三个合成文件分别覆盖：全部模式命中 / 注释与字符串必须零误报 / 变量 sleep 不计分。
_FIXTURE_HEAVY = r"""// task-44 自测夹具：每类成本模式在代码里都至少命中一次。
import Foundation
import Vision

struct HeavyTests {
    @Test func writesRealDatabase() throws {
        let disk = try Database.open(at: "/tmp/gather-audit-fixture.sqlite")
        let conn = try DBConnection(path: "/tmp/gather-audit-fixture-2.sqlite")
        let mem = try Database.openInMemory()
        let memConn = try DBConnection(path: ":memory:")
        let dir = FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("fixture.bin"))
        let process = Process()
        Thread.sleep(forTimeInterval: 0.2)
        let imageSize = CGSize(width: 4000, height: 3000)
        let model = MLModelConfiguration()
        _ = (disk, conn, mem, memConn, process, imageSize, model)
    }

    @Test func secondCase() {
        #expect(true)
    }
}
"""

_FIXTURE_MASKED = r"""// task-44 自测夹具：成本模式只出现在注释/字符串里 → 计数必须为 0（不得误报）。
import Foundation

/* 块注释含嵌套：Database.open(at:) / DBConnection(path:)
   /* 内层：Thread.sleep(forTimeInterval: 9) / Process() / width: 9000 /
      @Test func fakeCommentTest() {} */
   外层：FileManager.default.temporaryDirectory / NSTemporaryDirectory() / write(to: x)
*/
struct MaskedTests {
    // @Test func commentedOut() {} —— 行注释里的 @Test 不算。
    let note = "Database.openInMemory / temporaryDirectory / write(to: x) / Process() / Task.sleep(for: .seconds(4)) / width: 8000"
    let raw = #"Task.sleep(nanoseconds: 999) / height: 8000 / Vision / CoreML"#
    let nearWidth = CGSize(width: 1999, height: 1999)
    let atWidth = CGSize(width: 2000, height: 1000)

    @Test func onlyCountedTest() {
        #expect(note.contains("Vision"))
        #expect(raw.contains("CoreML"))
    }
}
"""

_FIXTURE_VARIABLE_SLEEP = r"""// task-44 自测夹具：变量 sleep 只记入 sleep_variable，不计分。
struct VariableSleepTests {
    @Test func waitsForDelay(delay: Duration) async {
        try? await Task.sleep(for: delay)
        try? await Task.sleep(for: .milliseconds(50))
    }
}
"""

_HEAVY_EXPECT = {
    "tests": 2, "db_open": 3, "db_memory": 1,
    "temp_io": 3, "temp_dir": 1, "create_dir": 1, "file_write": 1,
    "sleep": 1, "sleep_variable": 0,
    "process": 1, "vision_ml": 2, "large_image": 2, "score": 46,
}
_MASKED_EXPECT = {
    "tests": 1, "db_open": 0, "db_memory": 0,
    "temp_io": 0, "temp_dir": 0, "create_dir": 0, "file_write": 0,
    "sleep": 0, "sleep_variable": 0,
    "process": 0, "vision_ml": 0, "large_image": 1, "score": 3,
}
_VARIABLE_SLEEP_EXPECT = {
    "tests": 1, "db_open": 0, "db_memory": 0,
    "temp_io": 0, "temp_dir": 0, "create_dir": 0, "file_write": 0,
    "sleep": 1, "sleep_variable": 1,
    "process": 0, "vision_ml": 0, "large_image": 0, "score": 5,
}


class _SelfTest:
    def __init__(self):
        self.checks = 0
        self.failures = []

    def check(self, condition, message):
        self.checks += 1
        if not condition:
            self.failures.append(message)

    def equal(self, actual, expected, message):
        self.check(actual == expected,
                   "%s（期望 %r，实际 %r）" % (message, expected, actual))


def _assert_counts(suite, item, expected, label):
    for key, value in expected.items():
        suite.equal(item[key], value, "%s %s" % (label, key))


def run_self_test():
    """mktemp 合成夹具自测：覆盖全部模式、注释/字符串遮罩、排序与 CLI 契约。"""
    suite = _SelfTest()
    workdir = tempfile.mkdtemp(prefix="gather-test-costs-")
    try:
        core = Path(workdir) / "desktop/native/gather-core/Tests/GatherCoreTests"
        app = Path(workdir) / "desktop/native/gather-app/Tests/GatherAppTests/Support"
        core.mkdir(parents=True)
        app.mkdir(parents=True)
        (core / "Heavy.swift").write_text(_FIXTURE_HEAVY, encoding="utf-8")
        (core / "Masked.swift").write_text(_FIXTURE_MASKED, encoding="utf-8")
        (app / "VariableSleep.swift").write_text(
            _FIXTURE_VARIABLE_SLEEP, encoding="utf-8")
        # 非 *.swift 文件不参与扫描（模式字样应被忽略）。
        (core / "Notes.txt").write_text(
            "Database.open / Thread.sleep(forTimeInterval: 5)\n", encoding="utf-8")

        # 1) 内部扫描：每文件每类计数（含注释/字符串遮罩与阈值边界）
        result = scan(Path(workdir))
        suite.equal(result["totals"]["files"], 3, "扫描文件数（忽略非 swift）")
        suite.equal(result["scan_roots"], list(SCAN_ROOTS), "扫描根清单")
        by_path = {item["path"]: item for item in result["files"]}
        heavy = by_path["desktop/native/gather-core/Tests/GatherCoreTests/Heavy.swift"]
        masked = by_path["desktop/native/gather-core/Tests/GatherCoreTests/Masked.swift"]
        variable = by_path[
            "desktop/native/gather-app/Tests/GatherAppTests/Support/VariableSleep.swift"]
        _assert_counts(suite, heavy, _HEAVY_EXPECT, "Heavy.swift")
        _assert_counts(suite, masked, _MASKED_EXPECT, "Masked.swift")
        _assert_counts(suite, variable, _VARIABLE_SLEEP_EXPECT, "VariableSleep.swift")

        # 2) 排序：分数降序（同分按 @Test 数、路径）
        suite.equal([item["path"].rsplit("/", 1)[-1] for item in result["files"]],
                    ["Heavy.swift", "VariableSleep.swift", "Masked.swift"],
                    "Top 排序")

        # 3) 仓库总计
        totals = result["totals"]
        suite.equal(totals["score"], 54, "仓库总分")
        suite.equal(totals["tests"], 4, "仓库 @Test 合计")
        suite.equal(totals["db_open"], 3, "仓库 db_open")
        suite.equal(totals["db_memory"], 1, "仓库 db_memory")
        suite.equal(totals["temp_io"], 3, "仓库 temp_io")
        suite.equal(totals["sleep"], 2, "仓库固定 sleep")
        suite.equal(totals["sleep_variable"], 1, "仓库变量 sleep")
        suite.equal(totals["process"], 1, "仓库 Process")
        suite.equal(totals["vision_ml"], 2, "仓库 Vision/CoreML")
        suite.equal(totals["large_image"], 3, "仓库大图字面量")

        # 4) 确定性：同一目录扫描两次 + JSON 序列化逐字节一致
        payload_one = json.dumps(build_json(result, DEFAULT_TOP),
                                 ensure_ascii=False, indent=2)
        payload_two = json.dumps(build_json(scan(Path(workdir)), DEFAULT_TOP),
                                 ensure_ascii=False, indent=2)
        suite.check(payload_one == payload_two, "重复扫描 JSON 逐字节一致")

        # 5) CLI 契约：--json / 文本模式 / --top / 错误退出码
        script = os.path.abspath(__file__)
        env = dict(os.environ, PYTHONIOENCODING="utf-8")

        def run_cli(arguments):
            return subprocess.run(
                [sys.executable or "python3", script] + arguments,
                capture_output=True, text=True, env=env)

        cli_json = run_cli(["--root", workdir, "--json"])
        suite.equal(cli_json.returncode, 0, "CLI --json 退出码")
        suite.equal(cli_json.stderr, "", "CLI --json stderr 为空")
        try:
            payload = json.loads(cli_json.stdout)
        except ValueError:
            payload = None
        suite.check(payload is not None, "CLI --json 输出可解析")
        if payload is not None:
            suite.equal(payload["schema"], 1, "JSON schema")
            suite.equal(payload["report_only"], True, "JSON report_only")
            suite.equal(payload["ci_gate"], False, "JSON ci_gate")
            suite.equal(payload["files_scanned"], 3, "JSON files_scanned")
            suite.equal(len(payload["top"]), 3, "JSON top 条数")
            suite.equal(payload["totals"]["score"], 54, "JSON 总分")
            suite.equal([item["path"].rsplit("/", 1)[-1] for item in payload["top"]],
                        ["Heavy.swift", "VariableSleep.swift", "Masked.swift"],
                        "JSON top 顺序")
            suite.check("需 macOS 实测" in payload["note"], "JSON note 标注需 macOS 实测")

        cli_json_again = run_cli(["--root", workdir, "--json"])
        suite.check(cli_json.stdout == cli_json_again.stdout,
                    "CLI --json 两次运行逐字节一致")

        cli_text = run_cli(["--root", workdir])
        suite.equal(cli_text.returncode, 0, "CLI 文本模式退出码")
        suite.check("report-only" in cli_text.stdout, "文本模式 header 标注 report-only")
        suite.check("需 macOS 实测" in cli_text.stdout, "文本模式标注需 macOS 实测")
        order = [cli_text.stdout.find(name) for name in
                 ("Heavy.swift", "VariableSleep.swift", "Masked.swift")]
        suite.check(all(position >= 0 for position in order) and order == sorted(order),
                    "文本模式 Top 顺序正确")

        cli_top_one = run_cli(["--root", workdir, "--top", "1"])
        suite.check(cli_top_one.returncode == 0
                    and "Heavy.swift" in cli_top_one.stdout
                    and "VariableSleep.swift" not in cli_top_one.stdout,
                    "--top 1 只输出 1 条")

        cli_bad_top = run_cli(["--root", workdir, "--top", "0"])
        suite.equal(cli_bad_top.returncode, 2, "--top 0 用法错误退出码 2")

        cli_missing_root = run_cli(
            ["--root", os.path.join(workdir, "no-such-repo")])
        suite.equal(cli_missing_root.returncode, 1, "缺失 --root 退出码 1")
        suite.check("--root 不是目录" in cli_missing_root.stderr,
                    "缺失 --root stderr 明确报错")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if suite.failures:
        print("audit-test-costs 自测失败（%d/%d 项）:"
              % (len(suite.failures), suite.checks), file=sys.stderr)
        for failure in suite.failures:
            print("  - " + failure, file=sys.stderr)
        return 1
    print("audit-test-costs 自测: OK（%d 项断言）" % suite.checks)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="audit-test-costs.py",
        description="测试成本审计（report-only，非 CI 门禁）：静态扫描 "
                    "desktop/native/*/Tests 的成本代理模式，按加权分数输出 Top N "
                    "与仓库总计；不测量耗时，真实收益需 macOS 实测。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python3 scripts/audit-test-costs.py\n"
               "  python3 scripts/audit-test-costs.py --top 20 --json\n"
               "  python3 scripts/audit-test-costs.py --self-test\n")
    parser.add_argument("--root", metavar="PATH",
                        help="仓库根目录（默认：本脚本所在仓库根）")
    parser.add_argument("--top", metavar="N", type=int, default=DEFAULT_TOP,
                        help="榜单条数（默认 %d，必须 > 0）" % DEFAULT_TOP)
    parser.add_argument("--json", action="store_true",
                        help="输出机器可读 JSON（用于报表/横向对比）")
    parser.add_argument("--self-test", action="store_true",
                        help="mktemp 合成夹具自测（Linux/macOS 可跑，不写仓库）")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return run_self_test()
    if args.top <= 0:
        parser.error("--top 必须是正整数（当前 %r）" % (args.top,))
    root = (Path(args.root).expanduser().resolve() if args.root
            else Path(__file__).resolve().parents[1])
    if not root.is_dir():
        print("audit-test-costs.py: --root 不是目录：%s" % root, file=sys.stderr)
        return 1
    try:
        result = scan(root)
    except AuditError as exc:
        print("audit-test-costs.py: %s" % exc, file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(build_json(result, args.top), ensure_ascii=False, indent=2))
    else:
        sys.stdout.write(render_text(result, args.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
