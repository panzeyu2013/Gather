#!/usr/bin/env python3
"""Design-system token ratchet for GatherUI.

Counts a small set of "escape hatches" that should only go down. This is a
migration guard, not a linter: it intentionally counts occurrences (including
comments) so the number is deterministic and easy to explain.

fail-closed 守卫（2026-11-23 P1-3；见 .tmp/arch-plan-2026-11-23/06-gates.md §6.1）：
  1. 扫描量下限 MIN_SWIFT_FILES：GatherUI 只扫到更少的 *.swift → exit 2。
     旧行为：目录被清空/改名后 8 个指标全 0，仍打印 "PASS: no regression" 并 exit 0。
  2. 每个 metric「基线 > 0 且当前 = 0」→ exit 2（归零与解析器失效不可区分，
     fail closed；若确属迁移清零，用 --update --allow-zero 显式重钉基线）。
  3. --update 对「旧值 > 0 且新值 == 0」默认拒绝（exit 2，基线不动）：否则第 2 条
     的报错文案会把用户直接引到 --update，而 --update 会把全 0 静默写成基线，
     下一次 check 就 PASS（2026-11-24 修，fail-open）。
     确属迁移清零才加 --allow-zero；--allow-growth 与 --allow-zero 正交，不能互相顶替。
  这三类失败不受 --warn-only 降级（与其它门禁的扫描异常一致）；--update 也走
  同一扫描量下限，避免把失效的 0 写进基线。

Usage:
  ./scripts/check-design-system.sh            # fail if any metric increased
  ./scripts/check-design-system.sh --update   # write current values as baseline
  ./scripts/check-design-system.sh --update --allow-zero  # 确属迁移清零才允许写 0
  ./scripts/check-design-system.sh --warn-only
  ./scripts/check-design-system.sh --strict   # same failure rule; reserved
  ./scripts/check-design-system.sh --self-test  # mktemp fixture 负样本自测
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "desktop" / "native" / "gather-app" / "Sources" / "GatherUI"
BASELINE = ROOT / "docs" / "baselines" / "design-system-baseline.json"

# 与其它门禁的「扫描面失效」下限对齐（scripts/check-repo-hygiene.sh [g] 同样是 200）。
MIN_SWIFT_FILES = 200

# key -> (regex, description)
METRICS = {
    "font.callout": (re.compile(r"\.font\(\.callout"), "raw .callout"),
    "font.systemSize": (re.compile(r"\.system\(size:"), "raw .system(size:)"),
    # 只认**紧跟数字**的字面量。旧正则写的是 [0-9.]+：字符集里的 "." 让
    # ".padding(.horizontal, 12)"（带边形式）也被算成"数字 padding"，
    # 178/206 的计数是这类误报（2026-10-30 修）；同理 "spacing: .zero"。
    "spacing.literalPadding": (re.compile(r"\.padding\([0-9]"), "numeric .padding"),
    "spacing.literalSpacing": (re.compile(r"spacing:[ \t]*[0-9]"), "numeric spacing:"),
    "empty.contentUnavailable": (re.compile(r"ContentUnavailableView"), "inline empty state"),
    "container.groupBox": (re.compile(r"GroupBox[ \t]*\{"), "inline GroupBox"),
    "theme.legacyAlias": (
        # \b 必须加：旧模式里 primary 会前缀命中 GatherTheme.primaryText（4 处误报，
        # 2026-11-17 修）。精确 token 边界后只数真正的 legacy 别名。
        re.compile(r"GatherTheme\.(windowBackground|contentBackground|secondaryContentBackground|primary|primarySoft|background|border)\b"),
        "legacy theme alias",
    ),
    "radius.legacyAlias": (
        re.compile(r"GatherTheme\.Radius\.(group|panel|sm|md)"),
        "legacy radius alias",
    ),
}


def swift_files(ui: Path = UI) -> list[Path]:
    return sorted(ui.rglob("*.swift"))


def scan(ui: Path):
    """返回 (files, None)；扫描面不可信时返回 (None, exit_code=2)，fail closed。"""
    if not ui.exists():
        print(f"FAIL: missing UI directory: {ui}", file=sys.stderr)
        return None, 2
    files = swift_files(ui)
    if len(files) < MIN_SWIFT_FILES:
        print(
            f"FAIL: 扫描量异常：{ui} 只扫到 {len(files)} 个 Swift 文件"
            f"（<{MIN_SWIFT_FILES}），疑似路径/检出/解析器失效；拒绝判 PASS",
            file=sys.stderr,
        )
        return None, 2
    return files, None


def count(pattern: re.Pattern[str], files: list[Path]) -> int:
    total = 0
    for path in files:
        text = path.read_text(encoding="utf-8")
        total += len(pattern.findall(text))
    return total


def current_values(files: list[Path]) -> dict[str, int]:
    return {key: count(pattern, files) for key, (pattern, _) in METRICS.items()}


def load_baseline(path: Path = BASELINE) -> dict[str, int]:
    if not path.exists():
        raise SystemExit(
            f"missing baseline: {path}\n"
            "run ./scripts/check-design-system.sh --update first"
        )
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"invalid baseline (expected object): {path}")
    return {str(k): int(v) for k, v in data.items()}


def write_baseline(values: dict[str, int], path: Path = BASELINE) -> None:
    # 原子写：同目录临时文件 + os.replace，避免中断时留下半截 JSON。
    import os
    import tempfile

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".design-system-baseline.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(values, indent=2, ensure_ascii=False) + "\n")
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def update(ui: Path, baseline_path: Path, allow_growth: bool, allow_zero: bool = False) -> int:
    files, rc = scan(ui)
    if rc is not None:
        return rc
    values = current_values(files)
    if baseline_path.exists():
        old = load_baseline(baseline_path)
        if not allow_growth:
            grew = {
                key: (old.get(key), value)
                for key, value in values.items()
                if old.get(key) is not None and value > old[key]
            }
            if grew:
                for key, (base, current) in grew.items():
                    print(f"  涨：{key} {base} -> {current}", file=sys.stderr)
                print(
                    "check-design-system: REFUSED — 基线膨胀必须显式批准；"
                    "确需扩张时加 --allow-growth 并在 docs/cleanup-backlog.md 记账。",
                    file=sys.stderr,
                )
                return 1
        # 「旧值 > 0 → 新值 0」与解析器/扫描面失效不可区分：默认拒绝。
        # 这里必须 exit 2（而非 1）：它不是「指标变差」，而是「基线不可信」，
        # 与 check() 的归零守卫同一语义，--warn-only 也不降级。
        zeroed = {
            key: (old[key], value)
            for key, value in values.items()
            if old.get(key, 0) > 0 and value == 0
        }
        if zeroed and not allow_zero:
            for key, (base, current) in zeroed.items():
                print(f"  归零：{key} {base} -> {current}", file=sys.stderr)
            print(
                "check-design-system: REFUSED — 「基线 > 0 且当前 = 0」拒绝写入基线"
                "（与扫描面/正则失效不可区分，fail closed）；基线未改动。"
                "若确属迁移清零，加 --allow-zero 并在 docs/cleanup-backlog.md 记账。",
                file=sys.stderr,
            )
            return 2
    write_baseline(values, baseline_path)
    print(f"updated {baseline_path}")
    for key, value in values.items():
        print(f"  {key:28s} {value}")
    return 0


def check(ui: Path, baseline_path: Path, warn_only: bool) -> int:
    files, rc = scan(ui)
    if rc is not None:
        return rc
    values = current_values(files)
    baseline = load_baseline(baseline_path)
    failed = False
    emptied = []
    print("design-system ratchet")
    print(f"  UI: {ui}")
    print(f"  baseline: {baseline_path}")
    print(f"  {'metric':28s} {'current':>8s} {'baseline':>8s}  status")
    for key, current in values.items():
        base = baseline.get(key)
        if base is None:
            status = "NEW"
            failed = True
        elif current > base:
            status = f"REGRESSED (+{current - base})"
            failed = True
        elif base > 0 and current == 0:
            status = f"EMPTY (baseline {base} > 0)"
            failed = True
            emptied.append((key, base))
        elif current < base:
            status = f"improved (-{base - current})"
        else:
            status = "ok"
        print(f"  {key:28s} {current:8d} {str(base) if base is not None else '-':>8s}  {status}")

    if emptied:
        for key, base in emptied:
            print(
                f"FAIL: 指标归零：{key} 基线 {base} -> 0（疑似扫描面/正则失效，fail closed）",
                file=sys.stderr,
            )
        print(
            "check-design-system: FAIL — 「基线 > 0 且当前 = 0」不等于迁移完成；"
            "若确属清零，用 --update --allow-zero 显式重钉基线"
            "（只跑 --update 会被同样拒绝）。",
            file=sys.stderr,
        )
        return 2
    if failed:
        print("\nFAIL: design-system metric increased; use the DesignSystem API or update the baseline deliberately.", file=sys.stderr)
        return 0 if warn_only else 1
    print("\nPASS: no regression")
    return 0


def self_test() -> int:
    """mktemp fixture：空目录 / 指标归零 / 持平 PASS / 上涨 / --update 空目录。"""
    import contextlib
    import io
    import shutil
    import tempfile

    tmp = Path(tempfile.mkdtemp(prefix="check-design-system-"))
    try:
        def capture(fn):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = fn()
            return rc, out.getvalue(), err.getvalue()

        def make_ui(name: str, token_source: str) -> Path:
            ui = tmp / name
            ui.mkdir()
            for index in range(MIN_SWIFT_FILES):
                (ui / (f"Filler{index:03d}.swift")).write_text(
                    f"let filler{index} = {index}\n", encoding="utf-8")
            if token_source:
                (ui / "Token.swift").write_text(token_source, encoding="utf-8")
            return ui

        def write_baseline_file(name: str, values: dict[str, int]) -> Path:
            path = tmp / (name + ".json")
            path.write_text(json.dumps(values), encoding="utf-8")
            return path

        all_zero = {key: 0 for key in METRICS}
        failures = []

        # 1) 空目录（= 目录被清空/改名）：扫描量下限必须 exit 2，不能 PASS。
        empty_ui = tmp / "empty"
        empty_ui.mkdir()
        empty_baseline = write_baseline_file("empty", {"font.systemSize": 15})
        rc, out, err = capture(lambda: check(empty_ui, empty_baseline, False))
        if rc != 2 or "扫描量异常" not in err or "PASS" in out:
            failures.append("空目录未 fail closed（rc=%r, out=%r, err=%r）" % (rc, out, err))
        rc_update, _out, _err = capture(lambda: update(empty_ui, empty_baseline, False))
        if rc_update != 2:
            failures.append("--update 空目录未 fail closed（rc=%r）" % (rc_update,))

        # 2) 扫描量达标但指标全 0（正则/解析失效）：每个 >0 基线都必须硬失败。
        zeroed_ui = make_ui("zeroed", "")
        zeroed_values = dict(all_zero)
        zeroed_values["font.systemSize"] = 15
        zeroed_values["theme.legacyAlias"] = 1
        zeroed_baseline = write_baseline_file("zeroed", zeroed_values)
        rc, out, err = capture(lambda: check(zeroed_ui, zeroed_baseline, False))
        if rc != 2 or "指标归零" not in err or "EMPTY" not in out:
            failures.append("指标归零未硬失败（rc=%r, out=%r, err=%r）" % (rc, out, err))

        # 3) 持平：PASS（确认新守卫不误报）。
        ok_ui = make_ui("ok", 'Text("x")\n    .font(.system(size: 12))\n    .padding(8)\n')
        ok_baseline_values = dict(all_zero)
        ok_baseline_values["font.systemSize"] = 1
        ok_baseline_values["spacing.literalPadding"] = 1
        ok_baseline = write_baseline_file("ok", ok_baseline_values)
        rc, out, _err = capture(lambda: check(ok_ui, ok_baseline, False))
        if rc != 0 or "PASS: no regression" not in out:
            failures.append("持平样本被误报（rc=%r, out=%r）" % (rc, out))

        # 4) 上涨：仍按旧规则 exit 1（基线单独给，避免撞上归零守卫）。
        grew_ui = make_ui(
            "grew", 'Text("x")\n    .font(.system(size: 12))\n    .font(.system(size: 13))\n')
        grew_values = dict(all_zero)
        grew_values["font.systemSize"] = 1
        grew_baseline = write_baseline_file("grew", grew_values)
        rc, out, err = capture(lambda: check(grew_ui, grew_baseline, False))
        if rc != 1 or "REGRESSED" not in out:
            failures.append("上涨未被发现（rc=%r, out=%r, err=%r）" % (rc, out, err))

        # 5) --update 撞上「旧值 > 0 → 新值 0」必须拒绝且不动基线
        #    （旧行为的 fail-open：静默写全 0，之后 check 一律 PASS）。
        zero_drop_ui = make_ui("zero_drop", "")
        zero_drop_values = {key: 5 for key in METRICS}
        zero_drop_baseline = write_baseline_file("zero_drop", zero_drop_values)
        rc, out, err = capture(lambda: update(zero_drop_ui, zero_drop_baseline, False))
        if rc != 2 or "归零" not in err or "REFUSED" not in err:
            failures.append("--update 静默归零未拒绝（rc=%r, out=%r, err=%r）" % (rc, out, err))
        if json.loads(zero_drop_baseline.read_text(encoding="utf-8")) != zero_drop_values:
            failures.append("被拒绝的 --update 仍然改写了基线：%r"
                            % (zero_drop_baseline.read_text(encoding="utf-8"),))

        # 6) --allow-growth 不是归零许可（两个开关正交，不能互相顶替）。
        rc, _out, err = capture(lambda: update(zero_drop_ui, zero_drop_baseline, True))
        if rc != 2:
            failures.append("--allow-growth 被当成归零许可（rc=%r, err=%r）" % (rc, err))

        # 7) 显式 --allow-zero 才允许写入（正样本，确认守卫不误伤迁移）。
        rc, out, err = capture(lambda: update(zero_drop_ui, zero_drop_baseline, False, True))
        if rc != 0 or "updated" not in out:
            failures.append("--allow-zero 未放行（rc=%r, out=%r, err=%r）" % (rc, out, err))
        if json.loads(zero_drop_baseline.read_text(encoding="utf-8")) != all_zero:
            failures.append("--allow-zero 写入结果不是全 0：%r"
                            % (zero_drop_baseline.read_text(encoding="utf-8"),))

        # 8) 归零拒绝的逃生门只对「旧 > 0 → 0」生效：正常收紧（>0 且变小）仍可 --update。
        shrink_ui = make_ui("shrink", 'Text("x")\n    .font(.system(size: 12))\n')
        shrink_values = dict(all_zero)
        shrink_values["font.systemSize"] = 3
        shrink_baseline = write_baseline_file("shrink", shrink_values)
        rc, out, err = capture(lambda: update(shrink_ui, shrink_baseline, False))
        if rc != 0 or "updated" not in out:
            failures.append("正常收紧被误拒（rc=%r, out=%r, err=%r）" % (rc, out, err))

        # 9) --allow-zero 只放行「归零」，不放行「上涨」：两个开关正交（旧 bug 是
        #    把任一逃生门都当成 --allow-growth 的后门）。上涨仍走 REFUSED / exit 1。
        grew_update_ui = make_ui(
            "grew_update", 'Text("x")\n    .font(.system(size: 12))\n    .font(.system(size: 13))\n')
        grew_update_values = dict(all_zero)
        grew_update_values["font.systemSize"] = 1
        grew_update_baseline = write_baseline_file("grew_update", grew_update_values)
        rc, _out, err = capture(lambda: update(grew_update_ui, grew_update_baseline, False, True))
        if rc != 1 or "REFUSED" not in err:
            failures.append("--allow-zero 被当成上涨许可（rc=%r, err=%r）" % (rc, err))

        # 10) 归零守卫不受 --warn-only 降级：它不是「指标变差」，而是「基线不可信」，
        #     与 check() 的扫描量守卫同一语义，降级成 exit 0 就是 fail-open。
        rc, _out, err = capture(lambda: check(zeroed_ui, zeroed_baseline, True))
        if rc != 2 or "指标归零" not in err:
            failures.append("归零在 --warn-only 下被降级（rc=%r, err=%r）" % (rc, err))

        if failures:
            for item in failures:
                print("self-test FAIL：" + item, file=sys.stderr)
            return 2
        print(
            "self-test OK（空目录 exit 2 / 指标归零 exit 2（--warn-only 也不降级）/ "
            "持平 PASS / 上涨 exit 1 / --update 归零拒绝 exit 2 且基线不动 / "
            "--allow-growth 不放行归零 / --allow-zero 才写入且不放行上涨 / 正常收紧不误拒）"
        )
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="GatherUI design-system ratchet")
    parser.add_argument("--update", action="store_true", help="write current values as baseline")
    parser.add_argument(
        "--allow-growth",
        action="store_true",
        help="with --update: allow metrics to increase (must be recorded in docs/cleanup-backlog.md)",
    )
    parser.add_argument(
        "--allow-zero",
        action="store_true",
        help="with --update: allow a metric to drop from >0 to 0 (deliberate migration; "
             "must be recorded in docs/cleanup-backlog.md)",
    )
    parser.add_argument("--warn-only", action="store_true", help="report but exit 0")
    parser.add_argument("--strict", action="store_true", help="reserved; same failure rule")
    parser.add_argument("--self-test", action="store_true", help="mktemp fixture 负样本自测")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.update:
        return update(UI, BASELINE, args.allow_growth, args.allow_zero)
    return check(UI, BASELINE, args.warn_only)


if __name__ == "__main__":
    raise SystemExit(main())
