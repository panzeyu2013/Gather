#!/usr/bin/env python3
"""Design-system token ratchet for GatherUI.

Counts a small set of "escape hatches" that should only go down. This is a
migration guard, not a linter: it intentionally counts occurrences (including
comments) so the number is deterministic and easy to explain.

Usage:
  ./scripts/check-design-system.sh            # fail if any metric increased
  ./scripts/check-design-system.sh --update   # write current values as baseline
  ./scripts/check-design-system.sh --warn-only
  ./scripts/check-design-system.sh --strict   # same failure rule; reserved
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "desktop" / "native" / "gather-app" / "Sources" / "GatherUI"
BASELINE = ROOT / "scripts" / "design-system-baseline.json"

# key -> (regex, description)
METRICS = {
    "font.callout": (re.compile(r"\.font\(\.callout"), "raw .callout"),
    "font.systemSize": (re.compile(r"\.system\(size:"), "raw .system(size:)"),
    "spacing.literalPadding": (re.compile(r"\.padding\([0-9.]+"), "numeric .padding"),
    "spacing.literalSpacing": (re.compile(r"spacing:[ \t]*[0-9.]+"), "numeric spacing:"),
    "empty.contentUnavailable": (re.compile(r"ContentUnavailableView"), "inline empty state"),
    "container.groupBox": (re.compile(r"GroupBox[ \t]*\{"), "inline GroupBox"),
    "theme.legacyAlias": (
        re.compile(r"GatherTheme\.(windowBackground|contentBackground|secondaryContentBackground|primary|primarySoft|background|border)"),
        "legacy theme alias",
    ),
    "radius.legacyAlias": (
        re.compile(r"GatherTheme\.Radius\.(group|panel|sm|md)"),
        "legacy radius alias",
    ),
}


def swift_files() -> list[Path]:
    return sorted(UI.rglob("*.swift"))


def count(pattern: re.Pattern[str]) -> int:
    total = 0
    for path in swift_files():
        text = path.read_text(encoding="utf-8")
        total += len(pattern.findall(text))
    return total


def current_values() -> dict[str, int]:
    return {key: count(pattern) for key, (pattern, _) in METRICS.items()}


def load_baseline() -> dict[str, int]:
    if not BASELINE.exists():
        raise SystemExit(
            f"missing baseline: {BASELINE}\n"
            "run ./scripts/check-design-system.sh --update first"
        )
    data = json.loads(BASELINE.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"invalid baseline (expected object): {BASELINE}")
    return {str(k): int(v) for k, v in data.items()}


def write_baseline(values: dict[str, int]) -> None:
    BASELINE.write_text(
        json.dumps(values, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="GatherUI design-system ratchet")
    parser.add_argument("--update", action="store_true", help="write current values as baseline")
    parser.add_argument("--warn-only", action="store_true", help="report but exit 0")
    parser.add_argument("--strict", action="store_true", help="reserved; same failure rule")
    args = parser.parse_args()

    if not UI.exists():
        print(f"FAIL: missing UI directory: {UI}", file=sys.stderr)
        return 2

    values = current_values()
    if args.update:
        write_baseline(values)
        print(f"updated {BASELINE}")
        for key, value in values.items():
            print(f"  {key:28s} {value}")
        return 0

    baseline = load_baseline()
    failed = False
    print("design-system ratchet")
    print(f"  UI: {UI}")
    print(f"  baseline: {BASELINE}")
    print(f"  {'metric':28s} {'current':>8s} {'baseline':>8s}  status")
    for key, current in values.items():
        base = baseline.get(key)
        if base is None:
            status = "NEW"
            failed = True
        elif current > base:
            status = f"REGRESSED (+{current - base})"
            failed = True
        elif current < base:
            status = f"improved (-{base - current})"
        else:
            status = "ok"
        print(f"  {key:28s} {current:8d} {str(base) if base is not None else '-':>8s}  {status}")

    if failed:
        print("\nFAIL: design-system metric increased; use the DesignSystem API or update the baseline deliberately.", file=sys.stderr)
        return 0 if args.warn_only else 1
    print("\nPASS: no regression")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
