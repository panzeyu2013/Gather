#!/usr/bin/env bash
# Wave3 收尾 / task-25：为 Shortcuts 生成 App Intents 编译期元数据。
#
# 背景：SwiftPM 不会执行 Xcode 的 ExtractAppIntentsMetadata 构建步骤，直接
# `swift build` 组装出的 .app 没有 Contents/Resources/Metadata.appintents，
# Shortcuts.app 因此看不到 GatherAutomationIntents.swift 里的 4 个动作。
#
# 本脚本做两件事（与 Xcode 的 appintentsmetadataprocessor 调用等价）：
#   1) 对含 AppIntent/AppShortcutsProvider 的 Swift 源文件单独执行
#      `swiftc -c -Xfrontend -emit-const-values-path`（Xcode 的
#      SWIFT_ENABLE_EMIT_CONST_VALUES），把编译期常量清单写进临时目录；
#      协议清单用 AppIntents 公共协议名（AppIntent/AppShortcutsProvider/AppEnum/AppEntity）；
#   2) 调用 `appintentsmetadataprocessor --compile-time-extraction`，输出目录是
#      <app>/Contents/Resources（processor 自己创建 Metadata.appintents/）。
#
# 失败语义：
# - `--strict`（build.sh 的 GATHER_RELEASE=1 路径）：任何缺失/失败都 exit 1，
#   并打印原因（缺 xcrun/processor/SDK/源文件/Swift 依赖/产物为空）；
# - 非 strict（本地开发）：打印同样原因后 exit 0，让 build.sh 继续产出可运行的
#   未签名 app（Shortcuts 发现性缺失但不阻塞本地调试）。
#
# 用法（一般由 desktop/native/build.sh 调用）：
#   scripts/build-appintents-metadata.sh \
#     --app-bundle <path/Gather.app> \
#     --bin-path <swift build --show-bin-path 输出> \
#     --source-root desktop/native/gather-app/Sources/GatherApp \
#     --module-name GatherApp \
#     --target-triple arm64-apple-macos26.0 \
#     --deployment-target 26.0 [--strict]
#
# 环境变量：GATHER_APPINTENTS_VERBOSE=1 打印每条 swiftc 命令。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_BUNDLE=""
BIN_PATH=""
SOURCE_ROOT=""
MODULE_NAME="GatherApp"
TARGET_TRIPLE=""
DEPLOYMENT_TARGET="26.0"
STRICT=0

usage() {
  sed -n '2,40p' "$0"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle) APP_BUNDLE="${2:-}"; shift 2 ;;
    --bin-path) BIN_PATH="${2:-}"; shift 2 ;;
    --source-root) SOURCE_ROOT="${2:-}"; shift 2 ;;
    --module-name) MODULE_NAME="${2:-}"; shift 2 ;;
    --target-triple) TARGET_TRIPLE="${2:-}"; shift 2 ;;
    --deployment-target) DEPLOYMENT_TARGET="${2:-}"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage ;;
    *) echo "build-appintents-metadata: unknown argument: $1" >&2; usage ;;
  esac
done

log() { echo "[appintents] $*" >&2; }
warn() { echo "[appintents] warning: $*" >&2; }
fail() {
  echo "[appintents] error: $*" >&2
  if [[ "$STRICT" == "1" ]]; then
    exit 1
  fi
  warn "非 release 构建：跳过 App Intents 元数据（Shortcuts 将看不到动作）"
  exit 0
}

# ---- 参数与前置 ----
[[ -n "$APP_BUNDLE" ]] || fail "missing --app-bundle"
[[ -n "$BIN_PATH" ]] || fail "missing --bin-path"
[[ -n "$SOURCE_ROOT" ]] || fail "missing --source-root"
[[ -n "$TARGET_TRIPLE" ]] || fail "missing --target-triple"
[[ -d "$APP_BUNDLE/Contents" ]] || fail "app bundle not assembled: $APP_BUNDLE"
[[ -d "$SOURCE_ROOT" ]] || fail "GatherApp source root missing: $SOURCE_ROOT"
[[ -d "$BIN_PATH" ]] || fail "SwiftPM bin path missing: $BIN_PATH (run swift build first)"

PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
[[ -n "$PROCESSOR" ]] || fail "xcrun could not find appintentsmetadataprocessor (Xcode 14+ required)"
SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
[[ -n "$SWIFTC" ]] || fail "xcrun could not find swiftc"
SDK_ROOT="$(xcrun --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK_ROOT" && -d "$SDK_ROOT" ]] || fail "xcrun --show-sdk-path unavailable"
# processor 自带 toolchain 路径：<toolchain>/usr/bin/appintentsmetadataprocessor；
# 从 processor 反推（swiftc 可能来自 CLT，不一定是 Xcode toolchain）。
TOOLCHAIN_DIR="$(cd "$(dirname "$PROCESSOR")/../.." && pwd)"
XCODE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :DTXcodeBuild' "$(xcode-select -p)/../Info.plist" 2>/dev/null || true)"
if [[ -z "$XCODE_VERSION" ]]; then
  XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3; exit}')"
fi
[[ -n "$XCODE_VERSION" ]] || fail "cannot determine Xcode product build version (DTXcodeBuild)"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
[[ -d "$RESOURCES_DIR" ]] || fail "app Resources dir missing: $RESOURCES_DIR"
BUNDLE_ID=""
if [[ -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
fi

# 自检的 4 个 intent 标识（与 Sources/GatherApp/GatherAutomationIntents.swift 同步；
# 测试/预发布验证可用 GATHER_APPINTENTS_EXPECTED 覆盖为逗号分隔列表）。
EXPECTED_INTENTS="${GATHER_APPINTENTS_EXPECTED:-CreateWorkspaceAndImportIntent,ExportWorkspaceIntent,WritebackWorkspaceMetadataIntent,WorkspaceStatusIntent}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gather-appintents.XXXXXX")"
trap 'rm -rf "${TMP_DIR:-}"' EXIT
printf '%s' '["AppIntent","AppShortcutsProvider","AppEnum","AppEntity"]' > "$TMP_DIR/protocols.json"

# ---- 1) 找到需要元数据的源文件 ----
INTENT_SOURCES=()
while IFS= read -r file; do
  [[ -n "$file" ]] && INTENT_SOURCES+=("$file")
done < <(
  find "$SOURCE_ROOT" -type f -name '*.swift' -print0     | xargs -0 grep -l -E 'AppIntent|AppShortcutsProvider' 2>/dev/null     | LC_ALL=C sort
)
if [[ ${#INTENT_SOURCES[@]} -eq 0 ]]; then
  fail "no source file under $SOURCE_ROOT implements AppIntent/AppShortcutsProvider"
fi
log "intent sources: ${#INTENT_SOURCES[@]} file(s)"

# ---- 2) 逐文件生成 .swiftconstvalues（与 Xcode SWIFT_ENABLE_EMIT_CONST_VALUES 等价） ----
SOURCES_LIST="$TMP_DIR/sources.txt"
CONST_VALS_LIST="$TMP_DIR/constvals.txt"
: > "$SOURCES_LIST"
: > "$CONST_VALS_LIST"
index=0
for source in "${INTENT_SOURCES[@]}"; do
  index=$((index + 1))
  abs_source="$(cd "$(dirname "$source")" && pwd)/$(basename "$source")"
  const_name="$(printf '%03d' "$index")"
  include_args=("-I" "$BIN_PATH")
  # gather-core 的 CSQLite 是 C target：GatherHost 模块 transitive 依赖它，
  # 需要它的 modulemap 目录才能解析 import（SwiftPM 不把 C 模块 map 复制到 bin path）。
  core_csqlite_include="$ROOT_DIR/desktop/native/gather-core/Sources/CSQLite/include"
  if [[ -d "$core_csqlite_include" ]]; then
    include_args+=("-I" "$core_csqlite_include")
  fi
  const_path="$TMP_DIR/$const_name.swiftconstvalues"
  object_path="$TMP_DIR/$const_name.o"
  compile_args=(
    -c
    -module-name "$MODULE_NAME"
    -target "$TARGET_TRIPLE"
    -sdk "$SDK_ROOT"
    "${include_args[@]}"
    -module-cache-path "$TMP_DIR/module-cache"
    -Xfrontend -emit-const-values-path -Xfrontend "$const_path"
    -Xfrontend -const-gather-protocols-list -Xfrontend "$TMP_DIR/protocols.json"
    -o "$object_path"
    "$abs_source"
  )
  if [[ "${GATHER_APPINTENTS_VERBOSE:-0}" == "1" ]]; then
    log "swiftc ${compile_args[*]}"
  fi
  if ! "$SWIFTC" "${compile_args[@]}" >"$TMP_DIR/swiftc-$const_name.log" 2>&1; then
    echo "[appintents] swiftc failed for $abs_source:" >&2
    sed -n '1,12p' "$TMP_DIR/swiftc-$const_name.log" >&2
    fail "cannot emit App Intents const values (see log above)"
  fi
  if [[ ! -s "$const_path" ]]; then
    fail "swiftc produced an empty const-values file for $abs_source"
  fi
  printf '%s\n' "$abs_source" >> "$SOURCES_LIST"
  printf '%s\n' "$const_path" >> "$CONST_VALS_LIST"
done

# ---- 3) 调用 processor（Xcode AppIntentsMetadata.xcspec 的等价调用） ----
rm -rf "$RESOURCES_DIR/Metadata.appintents"
processor_args=(
  --output "$RESOURCES_DIR"
  --toolchain-dir "$TOOLCHAIN_DIR"
  --module-name "$MODULE_NAME"
  --sdk-root "$SDK_ROOT"
  --xcode-version "$XCODE_VERSION"
  --platform-family macOS
  --deployment-target "$DEPLOYMENT_TARGET"
  --target-triple "$TARGET_TRIPLE"
  --source-file-list "$SOURCES_LIST"
  --swift-const-vals-list "$CONST_VALS_LIST"
  --compile-time-extraction
)
if [[ -n "$BUNDLE_ID" ]]; then
  processor_args+=(--bundle-identifier "$BUNDLE_ID")
fi
# 与 Xcode 的 LM_BINARY_PATH 对齐：可执行文件存在时一并传入。compile-time
# extraction 的主要输入是 source/const-values，但 processor 会用它补充 bundle 元数据；
# 不存在时（例如只做局部验证）不传，不影响上面的编译期元数据。
APP_BINARY_PATH="$APP_BUNDLE/Contents/MacOS/Gather"
if [[ -f "$APP_BINARY_PATH" ]]; then
  processor_args+=(--binary-file "$APP_BINARY_PATH")
fi
if [[ "${GATHER_APPINTENTS_VERBOSE:-0}" == "1" ]]; then
  log "$PROCESSOR ${processor_args[*]}"
fi
if ! "$PROCESSOR" "${processor_args[@]}" >"$TMP_DIR/processor.log" 2>&1; then
  echo "[appintents] appintentsmetadataprocessor failed:" >&2
  sed -n '1,20p' "$TMP_DIR/processor.log" >&2
  fail "metadata extraction failed (Xcode/toolchain mismatch or stale SwiftPM modules)"
fi
ACTIONS_FILE="$RESOURCES_DIR/Metadata.appintents/extract.actionsdata"
VERSION_FILE="$RESOURCES_DIR/Metadata.appintents/version.json"
if [[ ! -s "$ACTIONS_FILE" || ! -s "$VERSION_FILE" ]]; then
  echo "[appintents] processor log:" >&2
  sed -n '1,20p' "$TMP_DIR/processor.log" >&2
  fail "processor produced no Metadata.appintents (App Intents symbols not found; check target membership/const-values emission)"
fi

# ---- 4) 产物自检：4 个 intent 标识必须都在 actions 里 ----
if ! python3 - "$ACTIONS_FILE" "$EXPECTED_INTENTS" <<'PY'
import json, sys

path, expected_raw = sys.argv[1], sys.argv[2]
expected = [item for item in expected_raw.split(",") if item]
data = json.load(open(path, encoding="utf-8"))
actions = data.get("actions") or {}
identifiers = set()
for key, value in actions.items():
    identifiers.add(key)
    if isinstance(value, dict):
        for field in ("identifier", "fullyQualifiedTypeName"):
            value_field = value.get(field)
            if isinstance(value_field, str) and value_field:
                identifiers.add(value_field)
                if "." in value_field:
                    identifiers.add(value_field.rsplit(".", 1)[-1])
missing = [item for item in expected if item not in identifiers]
print("[appintents] intents: " + ", ".join(sorted(identifiers)))
if missing:
    print("[appintents] missing required intents: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PY
then
  fail "Metadata.appintents is missing one or more required intent identifiers"
fi

log "OK: $RESOURCES_DIR/Metadata.appintents ($(wc -c < "$ACTIONS_FILE" | tr -d ' ') bytes actionsdata)"
