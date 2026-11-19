#!/usr/bin/env python3
r"""Swift Testing 事件流 + /usr/bin/time -l 剖析器（纯解析层，Linux 也可跑）。

背景：macOS 上 scripts/profile-tests.sh 用
    /usr/bin/time -l -o <time.txt> swift test --package-path <pkg> \
        --event-stream-output-path <events.jsonl>
同时产出两份数据：
  - events.jsonl：Swift Testing 的 JSON Lines 事件流（ST-0002 ABI）：
      每行 {"version":0|"6.3"|..., "kind":"test"|"event", "payload":{...}}
      test 记录（kind=suite/function）先于事件下发，事件里只带 testID；
      testStarted/testEnded 是函数级（套件级也会发，必须排除），
      testCaseStarted/testCaseEnded 是参数化用例级。
  - time.txt：BSD /usr/bin/time -l 的统计（real/user/sys 一行 +
      "<字节> maximum resident set size"），也兼容 GNU time -v 文本（便于自测/移植）。

本文件负责：解析事件流 → 每个测试耗时 top N、按 suite 聚合耗时、总耗时；
解析 time -l → real/user/sys/最大常驻内存 RSS。输出人类可读文本或 --json。
无数据/文件不可解析时明确报错（非零退出码），不静默输出空报告。

用法：
  python3 scripts/lib/test-profile.py --events <events.jsonl> \
      [--time-stats <time.txt>] [--top 30] [--json]
  python3 scripts/lib/test-profile.py --self-test   # mktemp 合成夹具自测
  python3 scripts/lib/test-profile.py --help

退出码：0 成功；1 无可用数据（文件缺失/事件流无耗时/时间统计不可解析）；
        2 参数用法错误（argparse）。
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

PROFILE_EXIT_OK = 0
PROFILE_EXIT_NO_DATA = 1

# 已知事件 kind；新增 kind 只计数不报错（JSON ABI 允许工具忽略未知记录）。
_KNOWN_EVENT_KINDS = frozenset({
    "runStarted", "runEnded", "testStarted", "testCaseStarted",
    "issueRecorded", "testCaseEnded", "testEnded", "testSkipped",
    "valueAttached", "testCancelled", "testCaseCancelled",
})
# 事件流里带 testID 的“结束/开始”事件；套件级事件也会出现，靠 test 记录 kind 区分。
_SOURCE_LOCATION_RE = re.compile(r':\d+(?::\d+)?$')


class ProfileError(Exception):
    """可预期的数据问题（CLI 转 stderr + 退出码 1，不打印 traceback）。"""


def _instant_seconds(payload):
    """取事件 instant（优先 since1970；否则 absolute），无法解析返回 None。"""
    instant = payload.get("instant")
    if not isinstance(instant, dict):
        return None
    for key in ("since1970", "absolute"):
        value = instant.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)) and math.isfinite(float(value)):
            return float(value)
    return None


def _record_parts(obj):
    """返回 (包装 kind, payload)；兼容标准包装与扁平容错格式。

    标准格式：{"version":0,"kind":"event"|"test","payload":{...}}。
    容错：某些工具/中间层会把 payload 直接平铺成一行（kind 即事件/记录 kind）。
    """
    kind = obj.get("kind")
    payload = obj.get("payload")
    if isinstance(payload, dict):
        return kind if isinstance(kind, str) else None, payload
    if kind in ("test", "event", "configuration"):
        return kind, {}
    if isinstance(kind, str):
        return None, obj
    return None, {}


def _has_source_location(test_id):
    """事件流里函数 testID 末尾带 sourceLocation（如 File.swift:12:6）；套件 ID 不带。"""
    return ".swift" in test_id or bool(_SOURCE_LOCATION_RE.search(test_id))


def _split_test_id(test_id):
    """把 "Module.Type/Sub/test()/File.swift:12:6" 拆成 (module, 名字组件, 源位置后缀)。

    ABI 说 testID 是不透明字符串；这里只做容错解析：模块与名字组件用 '.'/'/' 分隔，
    源位置组件特征为含 ".swift" 或 ":行[:列]" 结尾。解析不出来时返回原样组件。
    """
    module, sep, rest = test_id.partition(".")
    if not sep:
        module, rest = "", test_id
    comps = rest.split("/") if rest else []
    cut = len(comps)
    for index, comp in enumerate(comps):
        if ".swift" in comp or comp == "unknown" or _SOURCE_LOCATION_RE.search(comp):
            cut = index
            break
    return module, comps[:cut], "/".join(comps[cut:])


def _classify_test_id(test_id, meta):
    """函数级 testID 返回 True；套件级返回 False（套件事件不计入测试耗时）。"""
    if isinstance(meta, dict) and meta.get("kind") in ("function", "suite"):
        return meta["kind"] == "function"
    return _has_source_location(test_id)


def _function_name(test_id, meta):
    """人类可读测试名：优先 test 记录的 displayName/name，回退 testID 末段。"""
    if isinstance(meta, dict):
        display = meta.get("displayName")
        if isinstance(display, str) and display:
            return display
        name = meta.get("name")
        if isinstance(name, str) and name:
            return name
    _module, comps, _src = _split_test_id(test_id)
    return comps[-1] if comps else test_id


def _suite_path(test_id, meta):
    """函数所属套件路径（类型组件用 '/' 连接；自由函数返回空串）。"""
    _module, comps, _src = _split_test_id(test_id)
    kind = meta.get("kind") if isinstance(meta, dict) else None
    if kind == "suite":
        return "/".join(comps)
    if kind == "function":
        return "/".join(comps[:-1]) if len(comps) > 1 else ""
    # 没有 test 记录时的兜底：带源位置的按函数处理（末段是函数名）。
    if _has_source_location(test_id):
        return "/".join(comps[:-1]) if len(comps) > 1 else ""
    return "/".join(comps)


def _suite_label(path, display_by_path):
    """套件展示名：逐级用 suite 记录里的 displayName/name，缺失时用类型名。"""
    if not path:
        return "（自由函数）"
    parts = []
    prefix = []
    for comp in path.split("/"):
        prefix.append(comp)
        parts.append(display_by_path.get("/".join(prefix), comp))
    return " / ".join(parts)


def parse_event_stream(path):
    """解析 Swift Testing JSON Lines 事件流；无耗时数据时抛 ProfileError。"""
    events_path = os.fspath(path)
    if not os.path.isfile(events_path):
        raise ProfileError("事件流文件不存在: %s" % events_path)
    try:
        handle = open(events_path, "r", encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ProfileError("无法打开事件流文件 %s: %s" % (events_path, exc))

    tests = {}
    suite_display = {}
    suite_ids = set()
    fn_start, fn_end = {}, {}
    case_start, case_end, case_count = {}, {}, {}
    skipped = set()
    failed = set()
    issue_failures = 0
    run_start = None
    run_end = None
    lines_total = 0
    bad_samples = []
    bad_count = 0
    records = {"suite": 0, "function": 0, "other": 0}
    events_total = 0
    unknown_events = 0
    unknown_samples = []
    undated_events = 0

    first = True
    with handle:
        for raw in handle:
            line = raw.strip()
            if first:
                first = False
                if line.startswith("\ufeff"):
                    line = line.lstrip("\ufeff").strip()
            lines_total += 1
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (ValueError, UnicodeDecodeError) as exc:
                bad_count += 1
                if len(bad_samples) < 3:
                    bad_samples.append("第 %d 行: %s" % (lines_total, exc))
                continue
            if not isinstance(obj, dict):
                bad_count += 1
                if len(bad_samples) < 3:
                    bad_samples.append("第 %d 行: 顶层不是 JSON 对象" % lines_total)
                continue

            wrapper_kind, payload = _record_parts(obj)
            payload_kind = payload.get("kind")
            is_test_record = wrapper_kind == "test" or (
                wrapper_kind is None and payload_kind in ("suite", "function") and "id" in payload
            )
            if is_test_record:
                test_id = payload.get("id")
                if not isinstance(test_id, str) or not test_id:
                    records["other"] += 1
                    continue
                kind = payload.get("kind") if payload_kind in ("suite", "function") else "other"
                source = payload.get("sourceLocation")
                source = source if isinstance(source, dict) else {}
                meta = {
                    "kind": kind,
                    "name": payload.get("name") if isinstance(payload.get("name"), str) else "",
                    "displayName": payload.get("displayName") if isinstance(payload.get("displayName"), str) else "",
                    "file": source.get("filePath") or source.get("_filePath") or source.get("fileID") or "",
                    "line": source.get("line"),
                }
                tests[test_id] = meta
                if kind == "suite":
                    records["suite"] += 1
                    suite_ids.add(test_id)
                    display = meta["displayName"] or meta["name"]
                    if display:
                        suite_display["/".join(_split_test_id(test_id)[1])] = display
                elif kind == "function":
                    records["function"] += 1
                else:
                    records["other"] += 1
                continue
            if wrapper_kind == "configuration":
                continue

            event_kind = payload_kind
            if event_kind not in _KNOWN_EVENT_KINDS:
                unknown_events += 1
                if len(unknown_samples) < 3:
                    unknown_samples.append(str(event_kind))
                continue
            events_total += 1
            test_id = payload.get("testID")
            test_id = test_id if isinstance(test_id, str) and test_id else None
            instant = _instant_seconds(payload)
            if event_kind in ("runStarted", "runEnded"):
                if instant is None:
                    undated_events += 1
                elif event_kind == "runStarted":
                    run_start = instant if run_start is None else min(run_start, instant)
                else:
                    run_end = instant if run_end is None else max(run_end, instant)
                continue
            if test_id is None:
                continue
            if instant is None and event_kind != "testSkipped":
                undated_events += 1
                continue
            if event_kind == "testSkipped":
                skipped.add(test_id)
            elif event_kind == "issueRecorded":
                issue = payload.get("issue")
                if isinstance(issue, dict) and issue.get("isFailure") is True:
                    issue_failures += 1
                    failed.add(test_id)
            elif event_kind == "testStarted":
                fn_start[test_id] = fn_start.get(test_id, 0.0) + instant
            elif event_kind == "testEnded":
                fn_end[test_id] = fn_end.get(test_id, 0.0) + instant
            elif event_kind == "testCaseStarted":
                case_start[test_id] = case_start.get(test_id, 0.0) + instant
                case_count[test_id] = case_count.get(test_id, 0) + 1
            elif event_kind == "testCaseEnded":
                case_end[test_id] = case_end.get(test_id, 0.0) + instant

    # 逐 testID 汇总：函数级 started/ended 成对求和即可（并行/重复执行也成立）；
    # 只有 case 事件的参数化测试回退为用例耗时之和；套件 ID 一律排除。
    durations = {}
    duration_source = {}
    for test_id in set(fn_start) | set(case_start):
        if test_id in suite_ids or not _classify_test_id(test_id, tests.get(test_id)):
            continue
        if test_id in fn_start and test_id in fn_end:
            durations[test_id] = max(0.0, fn_end[test_id] - fn_start[test_id])
            duration_source[test_id] = "function"
        elif test_id in case_start and test_id in case_end:
            durations[test_id] = max(0.0, case_end[test_id] - case_start[test_id])
            duration_source[test_id] = "testCase"
        else:
            undated_events += 1

    if not durations:
        raise ProfileError(
            "未解析到任何测试耗时事件（事件流 %s；共 %d 行，测试记录 suite=%d/function=%d，"
            "事件 %d，无法解析行 %d）。请确认 swift test 真的运行了 Swift Testing 用例，"
            "且 --event-stream-output-path 指向本次运行的文件。"
            % (events_path, lines_total, records["suite"], records["function"],
               events_total, bad_count))

    return {
        "path": events_path,
        "lines_total": lines_total,
        "bad_count": bad_count,
        "bad_samples": bad_samples,
        "records": records,
        "events_total": events_total,
        "unknown_events": unknown_events,
        "unknown_samples": unknown_samples,
        "undated_events": undated_events,
        "tests": tests,
        "suite_display": suite_display,
        "suite_ids": suite_ids,
        "durations": durations,
        "duration_source": duration_source,
        "case_count": case_count,
        "skipped": skipped,
        "failed": failed,
        "issue_failures": issue_failures,
        "run_start": run_start,
        "run_end": run_end,
    }


def parse_time_stats(path):
    """解析 /usr/bin/time -l（BSD）或 GNU time -v 文本；没有任何字段时抛 ProfileError。"""
    stats_path = os.fspath(path)
    if not os.path.isfile(stats_path):
        raise ProfileError("时间统计文件不存在: %s（/usr/bin/time -l -o 的输出）" % stats_path)
    try:
        with open(stats_path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as exc:
        raise ProfileError("无法打开时间统计文件 %s: %s" % (stats_path, exc))

    result = {"real": None, "user": None, "sys": None, "max_rss_bytes": None, "format": "unknown"}
    for line in text.splitlines():
        (real, user, sys) = _parse_bsd_times(line)
        if real is not None:
            result.update({"real": real, "user": user, "sys": sys, "format": "bsd"})
            continue
        rss = _parse_bsd_rss(line)
        if rss is not None:
            result["max_rss_bytes"] = rss
            continue
        gnu = _parse_gnu_time_line(line)
        if gnu is not None:
            key, value = gnu
            if key == "max_rss_bytes":
                result["max_rss_bytes"] = value
            else:
                result[key] = value
            if result["format"] == "unknown":
                result["format"] = "gnu"
    if all(result[key] is None for key in ("real", "user", "sys", "max_rss_bytes")):
        raise ProfileError(
            "无法从 %s 解析 real/user/sys/maximum resident set size；"
            "该文件不像 /usr/bin/time -l（或 GNU time -v）的输出。" % stats_path)
    return result


def _parse_bsd_times(line):
    match = re.match(
        r"^\s*([0-9]+(?:\.[0-9]+)?)\s+real\s+([0-9]+(?:\.[0-9]+)?)\s+user\s+"
        r"([0-9]+(?:\.[0-9]+)?)\s+sys\s*$", line)
    if not match:
        return (None, None, None)
    return (float(match.group(1)), float(match.group(2)), float(match.group(3)))


def _parse_bsd_rss(line):
    match = re.match(r"^\s*([0-9]+)\s+maximum resident set size\s*$", line)
    return int(match.group(1)) if match else None


def _parse_gnu_time_line(line):
    match = re.match(r"^\s*Maximum resident set size \(kbytes\):\s*([0-9]+)\s*$", line)
    if match:
        return ("max_rss_bytes", int(match.group(1)) * 1024)
    match = re.match(r"^\s*User time \(seconds\):\s*([0-9]+(?:\.[0-9]+)?)\s*$", line)
    if match:
        return ("user", float(match.group(1)))
    match = re.match(r"^\s*System time \(seconds\):\s*([0-9]+(?:\.[0-9]+)?)\s*$", line)
    if match:
        return ("sys", float(match.group(1)))
    match = re.match(r"^\s*Elapsed \(wall clock\) time.*:\s*(\S+)\s*$", line)
    if match:
        seconds = _parse_hms(match.group(1))
        if seconds is not None:
            return ("real", seconds)
    return None


def _parse_hms(value):
    """GNU time 的 "h:mm:ss" / "m:ss.ss" → 秒。"""
    try:
        parts = value.split(":")
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
        return float(value)
    except ValueError:
        return None


def _summarize(events, time_stats, time_warnings, time_stats_path=None):
    """把原始解析结果整理成报告模型（测试行/套件聚合/总览）。"""
    display_by_path = events["suite_display"]
    tests = []
    for test_id, duration in events["durations"].items():
        meta = events["tests"].get(test_id, {})
        path = _suite_path(test_id, meta)
        tests.append({
            "test_id": test_id,
            "name": _function_name(test_id, meta),
            "suite": path,
            "suite_label": _suite_label(path, display_by_path),
            "duration_seconds": round(duration, 6),
            "test_cases": events["case_count"].get(test_id, 0),
            "duration_source": events["duration_source"].get(test_id, "function"),
        })
    tests.sort(key=lambda item: (-item["duration_seconds"], item["suite_label"], item["name"]))

    suites = {}
    for item in tests:
        key = item["suite"]
        entry = suites.setdefault(key, {
            "suite": key,
            "label": item["suite_label"],
            "duration_seconds": 0.0,
            "test_count": 0,
        })
        entry["duration_seconds"] += item["duration_seconds"]
        entry["test_count"] += 1
    suite_rows = sorted(suites.values(),
                        key=lambda item: (-item["duration_seconds"], item["label"]))
    for entry in suite_rows:
        entry["duration_seconds"] = round(entry["duration_seconds"], 6)

    function_ids = [tid for tid, meta in events["tests"].items() if meta.get("kind") == "function"]
    skipped = events["skipped"]
    missing_timing = [tid for tid in function_ids
                      if tid not in events["durations"] and tid not in skipped]
    total_duration = round(sum(item["duration_seconds"] for item in tests), 6)
    wall = None
    if events["run_start"] is not None and events["run_end"] is not None:
        wall = max(0.0, events["run_end"] - events["run_start"])

    warnings = list(time_warnings)
    if events["bad_count"]:
        warnings.append("事件流有 %d 行无法解析（已跳过，计数可能偏小）：%s"
                        % (events["bad_count"], "；".join(events["bad_samples"])))
    if events["unknown_events"]:
        warnings.append("事件流有 %d 个未知事件 kind（按 ABI 忽略）：%s"
                        % (events["unknown_events"], "、".join(events["unknown_samples"])))
    if events["failed"]:
        warnings.append("事件流记录到 %d 个失败测试（剖析运行本身失败；"
                        "profile-tests.sh 会以非零退出码结束）" % len(events["failed"]))
    if wall is None:
        warnings.append("事件流缺少 runStarted/runEnded，无法计算事件流墙钟")

    return {
        "events_path": events["path"],
        "time_stats_path": time_stats_path if time_stats is not None else None,
        "parse": {
            "lines": events["lines_total"],
            "bad_lines": events["bad_count"],
            "test_records": events["records"],
            "events": events["events_total"],
            "unknown_events": events["unknown_events"],
            "undated_events": events["undated_events"],
        },
        "totals": {
            "test_count": len(tests),
            "duration_seconds": total_duration,
            "run_wall_seconds": None if wall is None else round(wall, 6),
            "skipped": len(skipped),
            "failed_tests": len(events["failed"]),
            "issue_failures": events["issue_failures"],
            "missing_timing": len(missing_timing),
            "missing_timing_ids": sorted(missing_timing)[:20],
            "duration_source": {
                "function": sum(1 for item in tests if item["duration_source"] == "function"),
                "testCase": sum(1 for item in tests if item["duration_source"] == "testCase"),
            },
        },
        "time": time_stats,
        "tests": tests,
        "suites": suite_rows,
        "warnings": warnings,
    }


def analyze(events_path, time_stats_path=None):
    """解析 + 汇总；events 无耗时数据或 time 统计不可解析时抛 ProfileError。"""
    events = parse_event_stream(events_path)
    time_stats = None
    stats_path = None
    if time_stats_path:
        stats_path = os.fspath(time_stats_path)
        time_stats = parse_time_stats(time_stats_path)
    return _summarize(events, time_stats, _time_warnings(time_stats), stats_path)


def _time_warnings(time_stats):
    if time_stats is None:
        return []
    missing = [label for key, label in (
        ("real", "real"), ("user", "user"), ("sys", "sys"), ("max_rss_bytes", "RSS"))
        if time_stats.get(key) is None]
    if not missing:
        return []
    return ["/usr/bin/time 统计缺少字段（报告中显示 未解析）：%s" % "、".join(missing)]


def _fmt_seconds(value):
    return "%.3f s" % value if value is not None else "未解析"


def _fmt_rss(rss_bytes):
    if rss_bytes is None:
        return "未解析"
    return "%.1f MiB（%d bytes）" % (rss_bytes / (1024.0 * 1024.0), rss_bytes)


def _truncate(text, limit=160):
    return text if len(text) <= limit else text[:limit - 1] + "…"


def render_text(result, top=30):
    """人类可读报告（中文）。"""
    lines = []
    parse = result["parse"]
    totals = result["totals"]
    lines.append("== 测试剖析（Swift Testing 事件流 + /usr/bin/time -l）==")
    lines.append("事件流: %s" % result["events_path"])
    lines.append("解析: %d 行 → 测试记录 suite=%d / function=%d，事件 %d（unknown %d，"
                 "坏行 %d，缺 instant 事件 %d）"
                 % (parse["lines"], parse["test_records"]["suite"],
                    parse["test_records"]["function"], parse["events"],
                    parse["unknown_events"], parse["bad_lines"], parse["undated_events"]))
    lines.append("")
    lines.append("-- 总览 --")
    lines.append("有耗时测试: %d（函数级 %d / 用例级回退 %d）"
                 % (totals["test_count"], totals["duration_source"]["function"],
                    totals["duration_source"]["testCase"]))
    lines.append("测试耗时合计: %.3f s" % totals["duration_seconds"])
    if totals["run_wall_seconds"] is not None:
        lines.append("事件流墙钟（runStarted→runEnded）: %.3f s" % totals["run_wall_seconds"])
    if totals["skipped"]:
        lines.append("跳过测试: %d" % totals["skipped"])
    if totals["failed_tests"]:
        lines.append("失败测试: %d（issueRecorded isFailure）" % totals["failed_tests"])
    if totals["missing_timing"]:
        lines.append("无耗时事件的测试: %d（例如未实际运行/被过滤）"
                     % totals["missing_timing"])
    time_stats = result["time"]
    if time_stats is not None:
        lines.append("")
        lines.append("-- /usr/bin/time -l --")
        lines.append("real %s | user %s | sys %s"
                     % (_fmt_seconds(time_stats.get("real")),
                        _fmt_seconds(time_stats.get("user")),
                        _fmt_seconds(time_stats.get("sys"))))
        lines.append("最大常驻内存 RSS: %s" % _fmt_rss(time_stats.get("max_rss_bytes")))
        lines.append("提示: real/user/sys 与 RSS 含构建开销；预热构建（先跑一次 "
                     "scripts/test.sh）后再剖析更接近纯测试成本。")
    lines.append("")
    lines.append("-- 每测试耗时 top %d --" % top)
    shown = result["tests"][:top]
    if not shown:
        lines.append("  （无）")
    for index, item in enumerate(shown, 1):
        if item["suite_label"] and item["suite_label"] != "（自由函数）":
            label = "%s / %s" % (item["suite_label"], item["name"])
        else:
            label = item["name"]
        cases = ""
        if item["test_cases"]:
            cases = "（%d 参数化用例）" % item["test_cases"]
        lines.append("  %2d. %9.3f s  %s%s"
                     % (index, item["duration_seconds"], _truncate(label), cases))
    hidden = len(result["tests"]) - len(shown)
    if hidden > 0:
        lines.append("  … 其余 %d 个测试未列出（--top 调整）" % hidden)
    lines.append("")
    lines.append("-- 按 suite 聚合（%d 个）--" % len(result["suites"]))
    for entry in result["suites"]:
        lines.append("  %10.3f s  %5d 用例  %s"
                     % (entry["duration_seconds"], entry["test_count"],
                        _truncate(entry["label"])))
    if result["warnings"]:
        lines.append("")
        lines.append("-- 注意 --")
        for warning in result["warnings"]:
            lines.append("  " + warning)
    return "\n".join(lines)


def render_json(result):
    return json.dumps(result, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# 自测：mktemp 合成夹具（Linux/macOS 都可跑，不写仓库）
# ---------------------------------------------------------------------------

_SELF_TEST_EVENTS = "\n".join([
    '{"version":0,"kind":"test","payload":{"kind":"suite","name":"AlphaTests",'
    '"displayName":"甲套件","id":"GatherCoreTests.AlphaTests","sourceLocation":'
    '{"fileID":"GatherCoreTests/AlphaTests.swift","_filePath":"/src/AlphaTests.swift",'
    '"line":5,"column":1}}}',
    '{"version":0,"kind":"test","payload":{"kind":"function","name":"alpha()",'
    '"id":"GatherCoreTests.AlphaTests/alpha()/AlphaTests.swift:10:6","isParameterized":false}}',
    '{"version":0,"kind":"test","payload":{"kind":"function","name":"param(x:)","isParameterized":true,'
    '"id":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6"}}',
    '{"version":0,"kind":"test","payload":{"kind":"suite","name":"BetaTests",'
    '"id":"GatherCoreTests.BetaTests","sourceLocation":{"fileID":"GatherCoreTests/BetaTests.swift",'
    '"_filePath":"/src/BetaTests.swift","line":3,"column":1}}}',
    '{"version":0,"kind":"test","payload":{"kind":"function","name":"caseOnly()",'
    '"id":"GatherCoreTests.BetaTests/caseOnly()/BetaTests.swift:6:6","isParameterized":true}}',
    '{"version":0,"kind":"test","payload":{"kind":"function","name":"skippedFn()",'
    '"id":"GatherCoreTests.BetaTests/skippedFn()/BetaTests.swift:9:6","isParameterized":false}}',
    '{"version":0,"kind":"test","payload":{"kind":"function","name":"globalProbe()",'
    '"id":"GatherCoreTests.globalProbe()/Global.swift:3:1","isParameterized":false}}',
    '{"version":0,"kind":"event","payload":{"kind":"runStarted",'
    '"instant":{"absolute":100.0,"since1970":1000.0}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testStarted","testID":"GatherCoreTests.AlphaTests",'
    '"instant":{"absolute":100.01,"since1970":1000.01}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testStarted",'
    '"testID":"GatherCoreTests.AlphaTests/alpha()/AlphaTests.swift:10:6",'
    '"instant":{"absolute":101.0,"since1970":1001.0}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testEnded",'
    '"testID":"GatherCoreTests.AlphaTests/alpha()/AlphaTests.swift:10:6",'
    '"instant":{"absolute":103.5,"since1970":1003.5}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testStarted",'
    '"testID":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6",'
    '"instant":{"absolute":104.0,"since1970":1004.0}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseStarted",'
    '"testID":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6",'
    '"instant":{"absolute":104.1,"since1970":1004.1}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseEnded",'
    '"testID":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6",'
    '"instant":{"absolute":104.6,"since1970":1004.6}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseStarted",'
    '"testID":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6",'
    '"instant":{"absolute":104.7,"since1970":1004.7}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseEnded",'
    '"testID":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6",'
    '"instant":{"absolute":105.0,"since1970":1005.0}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testEnded",'
    '"testID":"GatherCoreTests.AlphaTests/param(x:)/AlphaTests.swift:14:6",'
    '"instant":{"absolute":105.2,"since1970":1005.2}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseStarted",'
    '"testID":"GatherCoreTests.BetaTests/caseOnly()/BetaTests.swift:6:6",'
    '"instant":{"absolute":2000.1,"since1970":2000.1}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseEnded",'
    '"testID":"GatherCoreTests.BetaTests/caseOnly()/BetaTests.swift:6:6",'
    '"instant":{"absolute":2000.6,"since1970":2000.6}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseStarted",'
    '"testID":"GatherCoreTests.BetaTests/caseOnly()/BetaTests.swift:6:6",'
    '"instant":{"absolute":2000.7,"since1970":2000.7}}}',
    '{"version":0,"kind":"event","payload":{"kind":"testCaseEnded",'
    '"testID":"GatherCoreTests.BetaTests/caseOnly()/BetaTests.swift:6:6",'
    '"instant":{"absolute":2001.0,"since1970":2001.0}}}',
    # 扁平格式容错：字段直接在行上（无 payload 包装）。
    '{"kind":"testStarted","testID":"GatherCoreTests.globalProbe()/Global.swift:3:1",'
    '"instant":{"absolute":3000.0,"since1970":3000.0}}',
    '{"kind":"testEnded","testID":"GatherCoreTests.globalProbe()/Global.swift:3:1",'
    '"instant":{"absolute":3000.123,"since1970":3000.123}}',
    '{"version":0,"kind":"event","payload":{"kind":"testSkipped",'
    '"testID":"GatherCoreTests.BetaTests/skippedFn()/BetaTests.swift:9:6",'
    '"instant":{"absolute":2002.0,"since1970":2002.0}}}',
    '{"version":0,"kind":"event","payload":{"kind":"issueRecorded",'
    '"testID":"GatherCoreTests.AlphaTests/alpha()/AlphaTests.swift:10:6",'
    '"issue":{"isFailure":true},"instant":{"absolute":1003.6,"since1970":1003.6}}}',
    '{"version":0,"kind":"event","payload":{"kind":"futureEvent","testID":null,'
    '"instant":{"absolute":1003.6,"since1970":1003.6}}}',
    '{"version":0,"kind":"configuration","payload":{}}',
    "not-json",
    "",
    '{"version":0,"kind":"event","payload":{"kind":"testEnded","testID":"GatherCoreTests.AlphaTests",'
    '"instant":{"absolute":1003.5,"since1970":1003.5}}}',
    '{"version":0,"kind":"event","payload":{"kind":"runEnded",'
    '"instant":{"absolute":3001.0,"since1970":3001.0}}}',
]) + "\n"

_SELF_TEST_TIME_BSD = """        1.50 real         1.00 user         0.25 sys
  123456789  maximum resident set size
        0  average shared memory size
        0  average unshared data size
        0  average unshared stack size
"""

_SELF_TEST_TIME_GNU = """	Command being timed: "swift test"
	User time (seconds): 1.25
	System time (seconds): 0.10
	Elapsed (wall clock) time (h:mm:ss or m:ss): 0:01.50
	Maximum resident set size (kbytes): 1048576
"""


class _SelfTest:
    def __init__(self):
        self.checks = 0
        self.failures = []

    def check(self, condition, message):
        self.checks += 1
        if not condition:
            self.failures.append(message)

    def close(self, value, expected, message):
        self.check(value is not None and abs(value - expected) < 1e-6,
                   "%s（期望 %.6f，实际 %r）" % (message, expected, value))


def run_self_test():
    """mktemp 合成事件流 + BSD/GNU time 文本，覆盖正常/容错/报错路径。"""
    suite = _SelfTest()
    workdir = tempfile.mkdtemp(prefix="gather-test-profile-")
    try:
        events_path = os.path.join(workdir, "events.jsonl")
        time_bsd_path = os.path.join(workdir, "time-bsd.txt")
        time_gnu_path = os.path.join(workdir, "time-gnu.txt")
        time_bad_path = os.path.join(workdir, "time-bad.txt")
        empty_path = os.path.join(workdir, "empty.jsonl")
        records_only_path = os.path.join(workdir, "records-only.jsonl")
        with open(events_path, "w", encoding="utf-8") as handle:
            handle.write(_SELF_TEST_EVENTS)
        with open(time_bsd_path, "w", encoding="utf-8") as handle:
            handle.write(_SELF_TEST_TIME_BSD)
        with open(time_gnu_path, "w", encoding="utf-8") as handle:
            handle.write(_SELF_TEST_TIME_GNU)
        with open(time_bad_path, "w", encoding="utf-8") as handle:
            handle.write("这不是 time 输出\n随便几行\n")
        open(empty_path, "w", encoding="utf-8").close()
        with open(records_only_path, "w", encoding="utf-8") as handle:
            handle.write(_SELF_TEST_EVENTS.splitlines()[0] + "\n"
                         + _SELF_TEST_EVENTS.splitlines()[1] + "\n")

        # 1) 时间统计解析（BSD / GNU）
        bsd = parse_time_stats(time_bsd_path)
        suite.close(bsd["real"], 1.5, "BSD real")
        suite.close(bsd["user"], 1.0, "BSD user")
        suite.close(bsd["sys"], 0.25, "BSD sys")
        suite.check(bsd["max_rss_bytes"] == 123456789,
                    "BSD RSS 字节（实际 %r）" % (bsd["max_rss_bytes"],))
        gnu = parse_time_stats(time_gnu_path)
        suite.close(gnu["real"], 1.5, "GNU elapsed")
        suite.close(gnu["user"], 1.25, "GNU user")
        suite.close(gnu["sys"], 0.10, "GNU sys")
        suite.check(gnu["max_rss_bytes"] == 1048576 * 1024,
                    "GNU RSS kbytes→bytes（实际 %r）" % (gnu["max_rss_bytes"],))

        # 2) 事件流解析：耗时、套件聚合、跳过/失败/参数化用例、容错计数
        result = analyze(events_path, time_bsd_path)
        totals = result["totals"]
        suite.check(totals["test_count"] == 4, "有耗时测试数 = 4（实际 %r）" % (totals["test_count"],))
        suite.close(totals["duration_seconds"], 4.623, "测试耗时合计")
        suite.close(totals["run_wall_seconds"], 2001.0, "事件流墙钟")
        suite.check(totals["skipped"] == 1, "跳过测试数 = 1（实际 %r）" % (totals["skipped"],))
        suite.check(totals["failed_tests"] == 1, "失败测试数 = 1（实际 %r）" % (totals["failed_tests"],))
        suite.check(totals["missing_timing"] == 0, "无耗时测试数 = 0（实际 %r）" % (totals["missing_timing"],))
        suite.check(totals["duration_source"]["function"] == 3,
                    "函数级耗时 3 个（实际 %r）" % (totals["duration_source"],))
        suite.check(totals["duration_source"]["testCase"] == 1,
                    "用例级回退 1 个（实际 %r）" % (totals["duration_source"],))
        by_name = {item["name"]: item["duration_seconds"] for item in result["tests"]}
        suite.close(by_name.get("alpha()"), 2.5, "alpha 耗时")
        suite.close(by_name.get("param(x:)"), 1.2, "参数化函数总耗时")
        suite.close(by_name.get("caseOnly()"), 0.8, "只有用例事件的回退耗时")
        suite.close(by_name.get("globalProbe()"), 0.123, "自由函数（扁平格式）耗时")
        suite.check("GatherCoreTests.AlphaTests" not in by_name
                    and all(not tid.endswith("AlphaTests") for tid in
                            [item["test_id"] for item in result["tests"]]),
                    "套件级 testStarted/testEnded 未被当成测试耗时")
        param = [item for item in result["tests"] if item["name"] == "param(x:)"][0]
        suite.check(param["test_cases"] == 2, "参数化用例计数 = 2（实际 %r）" % (param["test_cases"],))
        by_suite = {entry["label"]: entry for entry in result["suites"]}
        suite.close(by_suite.get("甲套件", {}).get("duration_seconds"), 3.7, "套件聚合（displayName）")
        suite.check(by_suite.get("甲套件", {}).get("test_count") == 2,
                    "套件聚合用例数 = 2（实际 %r）" % (by_suite.get("甲套件"),))
        suite.close(by_suite.get("BetaTests", {}).get("duration_seconds"), 0.8, "套件聚合（隐式套件）")
        suite.close(by_suite.get("（自由函数）", {}).get("duration_seconds"), 0.123,
                    "自由函数聚合")
        parse = result["parse"]
        suite.check(parse["bad_lines"] == 1, "坏行计数 = 1（实际 %r）" % (parse["bad_lines"],))
        suite.check(parse["unknown_events"] == 1,
                    "未知事件计数 = 1（实际 %r）" % (parse["unknown_events"],))
        suite.check(parse["test_records"]["suite"] == 2
                    and parse["test_records"]["function"] == 5,
                    "test 记录计数（实际 %r）" % (parse["test_records"],))
        suite.check(len(result["warnings"]) >= 2, "坏行/失败/未知事件产生警告（实际 %r）"
                    % (result["warnings"],))
        suite.check(bsd["format"] == "bsd" and gnu["format"] == "gnu", "time 格式识别")

        # 3) 文本/JSON 渲染与 --top
        text = render_text(result, top=2)
        suite.check("4.623 s" in text, "文本报告含耗时合计")
        suite.check("alpha()" in text and "param(x:)" in text, "top2 含前两名")
        suite.check("caseOnly()" not in text, "top2 不含第三名")
        suite.check("123456789" in text and "MiB" in text, "文本报告含 RSS")
        payload = json.loads(render_json(result))
        suite.close(payload["totals"]["duration_seconds"], 4.623, "JSON 合计")
        suite.check(payload["time"]["max_rss_bytes"] == 123456789, "JSON RSS")
        suite.check(len(payload["tests"]) == 4, "JSON 测试行数 = 4")

        # 4) 无数据/坏输入必须明确报错（不静默）
        def expect_error(call, label):
            try:
                call()
            except ProfileError as exc:
                suite.check(bool(str(exc)), "%s 抛 ProfileError 且消息非空" % label)
                return
            suite.check(False, "%s 应抛 ProfileError" % label)

        expect_error(lambda: parse_event_stream(os.path.join(workdir, "missing.jsonl")),
                     "事件流缺失")
        expect_error(lambda: parse_event_stream(empty_path), "空事件流")
        expect_error(lambda: parse_event_stream(records_only_path), "只有 test 记录无事件")
        expect_error(lambda: parse_time_stats(time_bad_path), "时间统计不可解析")
        expect_error(lambda: parse_time_stats(os.path.join(workdir, "missing-time.txt")),
                     "时间统计缺失")
        expect_error(lambda: analyze(events_path, time_bad_path), "analyze + 坏时间统计")

        # 5) CLI 子进程：正常 --json / 无数据退出码 1 / 用法错误退出码 2
        profile_py = os.path.abspath(__file__)
        cli_ok = subprocess.run(
            [sys.executable or "python3", profile_py, "--events", events_path,
             "--time-stats", time_bsd_path, "--json"],
            capture_output=True, text=True)
        suite.check(cli_ok.returncode == 0, "CLI 正常退出码 = %d（stderr: %s）"
                    % (cli_ok.returncode, cli_ok.stderr.strip()[:200]))
        if cli_ok.returncode == 0:
            cli_payload = json.loads(cli_ok.stdout)
            suite.close(cli_payload["totals"]["duration_seconds"], 4.623, "CLI JSON 合计")
        cli_missing = subprocess.run(
            [sys.executable or "python3", profile_py, "--events",
             os.path.join(workdir, "nope.jsonl")],
            capture_output=True, text=True)
        suite.check(cli_missing.returncode == 1,
                    "CLI 缺失事件流退出码 = %d" % cli_missing.returncode)
        suite.check("不存在" in cli_missing.stderr, "CLI 缺失事件流 stderr 明确报错")
        cli_bad_top = subprocess.run(
            [sys.executable or "python3", profile_py, "--events", events_path, "--top", "0"],
            capture_output=True, text=True)
        suite.check(cli_bad_top.returncode == 2,
                    "CLI --top 0 用法错误退出码 = %d" % cli_bad_top.returncode)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if suite.failures:
        print("test-profile 自测失败（%d/%d 项）：" % (len(suite.failures), suite.checks),
              file=sys.stderr)
        for failure in suite.failures:
            print("  - " + failure, file=sys.stderr)
        return 1
    print("test-profile 自测: OK（%d 项断言）" % suite.checks)
    return 0


def _build_parser():
    parser = argparse.ArgumentParser(
        prog="test-profile.py",
        description="解析 Swift Testing 事件流（--event-stream-output-path）与 "
                    "/usr/bin/time -l，输出每测试耗时 top N、按 suite 聚合耗时、"
                    "总耗时与 RSS/real/user/sys。无数据时明确报错（退出码 1）。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例：\n"
               "  python3 scripts/lib/test-profile.py --events /tmp/e.jsonl \\\n"
               "      --time-stats /tmp/time.txt --top 30\n"
               "  python3 scripts/lib/test-profile.py --self-test\n")
    parser.add_argument("--events", metavar="PATH",
                        help="Swift Testing JSON Lines 事件流文件")
    parser.add_argument("--time-stats", metavar="PATH",
                        help="/usr/bin/time -l -o 产生的统计文件（可选）")
    parser.add_argument("--top", metavar="N", type=int, default=30,
                        help="每测试耗时榜单条数（默认 30，必须 > 0）")
    parser.add_argument("--json", action="store_true",
                        help="输出机器可读 JSON（用于后续报表/基线对比）")
    parser.add_argument("--self-test", action="store_true",
                        help="mktemp 合成夹具自测（Linux/macOS 可跑，不写仓库）")
    return parser


def main(argv=None):
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return run_self_test()
    if not args.events:
        parser.error("--events 必需（除非使用 --self-test）")
    if args.top <= 0:
        parser.error("--top 必须是正整数（当前 %r）" % (args.top,))
    try:
        result = analyze(args.events, args.time_stats)
    except ProfileError as exc:
        print("test-profile.py: %s" % exc, file=sys.stderr)
        return PROFILE_EXIT_NO_DATA
    print(render_json(result) if args.json else render_text(result, args.top))
    return PROFILE_EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
