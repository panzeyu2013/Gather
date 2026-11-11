#!/usr/bin/env bash
# Wave3 收尾 / task-25：验收已组装 .app 的 App Intents 元数据。
#
# 背景：Shortcuts.app 能列出 Gather 的 4 个动作，前提是
# <app>/Contents/Resources/Metadata.appintents/{version.json,extract.actionsdata}
# 存在且包含对应 intent 标识。SwiftPM 本身不生成该产物，由
# desktop/native/build.sh 调用 scripts/build-appintents-metadata.sh 补上。
#
# 用法：
#   ./scripts/check-appintents.sh                         # 默认检查 release/Gather.app
#   ./scripts/check-appintents.sh --app /path/Gather.app
#   ./scripts/check-appintents.sh --meta /path/Metadata.appintents
#   ./scripts/check-appintents.sh --expect A,B --meta <path>
#
# 退出码：0 = 元数据存在且 4 个 intent 标识齐全；1 = 缺失/损坏/标识不全；
# 2 = 参数错误或路径不存在。
#
# 环境变量 GATHER_APPINTENTS_EXPECTED 可覆盖期望列表（默认 4 个，与
# GatherApp/GatherAutomationIntents.swift 同步），供预发布/实验构建复用。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_BUNDLE=""
META_DIR=""
EXPECTED="${GATHER_APPINTENTS_EXPECTED:-CreateWorkspaceAndImportIntent,ExportWorkspaceIntent,WritebackWorkspaceMetadataIntent,WorkspaceStatusIntent}"

usage() {
  sed -n '2,25p' "$0"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_BUNDLE="${2:-}"; shift 2 ;;
    --meta) META_DIR="${2:-}"; shift 2 ;;
    --expect) EXPECTED="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "check-appintents: unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -n "$META_DIR" ]]; then
  :
elif [[ -n "$APP_BUNDLE" ]]; then
  META_DIR="$APP_BUNDLE/Contents/Resources/Metadata.appintents"
else
  DEFAULT_APP="$ROOT_DIR/release/Gather.app"
  if [[ -d "$DEFAULT_APP" ]]; then
    META_DIR="$DEFAULT_APP/Contents/Resources/Metadata.appintents"
  else
    echo "check-appintents: 未找到默认产物 $DEFAULT_APP" >&2
    echo "  先构建：./desktop/native/build.sh，或用 --app/--meta 指定路径" >&2
    exit 2
  fi
fi

ACTIONS_FILE="$META_DIR/extract.actionsdata"
VERSION_FILE="$META_DIR/version.json"
if [[ ! -d "$META_DIR" ]]; then
  echo "check-appintents: FAIL 缺少 Metadata.appintents: $META_DIR" >&2
  exit 1
fi
if [[ ! -s "$VERSION_FILE" ]]; then
  echo "check-appintents: FAIL 缺少 version.json: $VERSION_FILE" >&2
  exit 1
fi
if [[ ! -s "$ACTIONS_FILE" ]]; then
  echo "check-appintents: FAIL 缺少 extract.actionsdata: $ACTIONS_FILE" >&2
  exit 1
fi

python3 - "$META_DIR" "$ACTIONS_FILE" "$VERSION_FILE" "$EXPECTED" <<'PY'
import json
import sys

meta_dir, actions_path, version_path, expected_raw = sys.argv[1:5]
expected = [item for item in expected_raw.split(",") if item]

try:
    version = json.load(open(version_path, encoding="utf-8"))
except Exception as error:  # noqa: BLE001 - 校验脚本需要把损坏详情打出来
    print(f"check-appintents: FAIL version.json 损坏: {error}", file=sys.stderr)
    sys.exit(1)
try:
    data = json.load(open(actions_path, encoding="utf-8"))
except Exception as error:  # noqa: BLE001
    print(f"check-appintents: FAIL extract.actionsdata 损坏: {error}", file=sys.stderr)
    sys.exit(1)

actions = data.get("actions") or {}
shortcuts = data.get("autoShortcuts") or []
identifiers = set()
for key, value in actions.items():
    identifiers.add(key)
    if isinstance(value, dict):
        for field in ("identifier", "fullyQualifiedTypeName"):
            raw = value.get(field)
            if isinstance(raw, str) and raw:
                identifiers.add(raw)
                if "." in raw:
                    identifiers.add(raw.rsplit(".", 1)[-1])

missing = [item for item in expected if item not in identifiers]
shortcut_ids = []
for item in shortcuts:
    if isinstance(item, dict):
        action_id = item.get("actionIdentifier")
        if isinstance(action_id, str):
            shortcut_ids.append(action_id)

print(f"check-appintents: meta={meta_dir}")
print(f"check-appintents: version={version.get('version')} tools={version.get('toolsVersion')}")
print(f"check-appintents: intents({len(identifiers)}): " + ", ".join(sorted(identifiers)))
if shortcut_ids:
    print(f"check-appintents: shortcuts({len(shortcut_ids)}): " + ", ".join(sorted(set(shortcut_ids))))
if missing:
    print("check-appintents: FAIL 缺少必需 intent: " + ", ".join(missing), file=sys.stderr)
    print("  期望: " + ", ".join(expected), file=sys.stderr)
    sys.exit(1)
if not shortcuts:
    print("check-appintents: warning 无 autoShortcuts（AppShortcutsProvider 未进入元数据；"
          "Shortcuts 仍可看到动作但不会出现在 App 快捷指令短语里）", file=sys.stderr)
sys.exit(0)
PY

echo "check-appintents: OK"
