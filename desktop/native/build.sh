#!/usr/bin/env bash
set -euo pipefail

# Native release assembly for Gather. The application is a self-contained
# Swift/SwiftUI bundle; no JavaScript build or renderer asset is required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/release}"
APP_BUNDLE="$OUTPUT_DIR/Gather.app"
CORE_PACKAGE="$SCRIPT_DIR/gather-core"
APP_PACKAGE="$SCRIPT_DIR/gather-app"

if [[ "$OUTPUT_DIR" == "/" || "$APP_BUNDLE" != "$OUTPUT_DIR/Gather.app" ]]; then
  echo "refusing unsafe OUTPUT_DIR: $OUTPUT_DIR" >&2
  exit 2
fi

swift build --package-path "$CORE_PACKAGE" -c "$CONFIGURATION"
swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION"

# Use SwiftPM's own bin path: the legacy .build/<config> layout is replaced by
# .build/out/Products/<Config> on newer toolchains (Xcode 16+/26/27), and
# build configuration names are capitalized there.
BIN_DIR="$(swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" --show-bin-path)"
APP_EXECUTABLE="$BIN_DIR/gather-app"
if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "native executable not found at $APP_EXECUTABLE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Gather"
cp "$APP_PACKAGE/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# SPM 资源 bundle（本地化表 .lproj 等）随可执行文件进入 app bundle，
# Bundle.module 运行时按 Contents/Resources/gather-app_GatherApp.bundle 解析。
RESOURCE_BUNDLE="$BIN_DIR/gather-app_GatherApp.bundle"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
  # N08：系统菜单文案（关于/隐藏/服务/窗口/帮助）由 macOS 按**主 bundle** 的
  # 本地化集合渲染。.lproj 只躺在 SPM 资源 bundle 里时，主 bundle 看起来是
  # 英文单语，于是中文界面配英文系统菜单。把本地化目录同时放进主 bundle，
  # 并在 Info.plist 声明 CFBundleLocalizations，两边才一致。
  for lproj in "$RESOURCE_BUNDLE"/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
  done
else
  echo "warning: SPM resource bundle not found; localization tables will be missing" >&2
fi

# The Capture One plugin is optional at build time because its SDK is licensed
# and is not part of this repository. When the SDK is present, build and embed
# the plugin; otherwise leave an explicit, non-fatal release note.
PLUGIN_SDK="$ROOT_DIR/Capture_One_Plugin_SDK_(Mac)_v1.0.1"
if [[ -d "$PLUGIN_SDK" && -f "$ROOT_DIR/desktop/coplugin/Makefile" ]]; then
  make -C "$ROOT_DIR/desktop/coplugin" TARGET_ARCH="$(uname -m)" all
  if [[ -d "$ROOT_DIR/desktop/coplugin/GatherLink.coplugin" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/PlugIns"
    cp -R "$ROOT_DIR/desktop/coplugin/GatherLink.coplugin" "$APP_BUNDLE/Contents/PlugIns/"
  fi
else
  echo "warning: Capture One SDK not found; skipping GatherLink.coplugin" >&2
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "warning: CODESIGN_IDENTITY is unset; app is unsigned" >&2
fi

echo "assembled $APP_BUNDLE"
