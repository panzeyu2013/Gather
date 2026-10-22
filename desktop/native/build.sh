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
# C1（Capture One）走 NSAppleScript 发送 Apple Events；hardened runtime 分发包
# 没有该 entitlement 会被 TCC 拒绝（-1743）。签名身份仍只由 CODESIGN_IDENTITY
# 决定，这里只是随签名一起提交的固定资产。
ENTITLEMENTS="$SCRIPT_DIR/Gather.entitlements"

if [[ "$OUTPUT_DIR" == "/" || "$APP_BUNDLE" != "$OUTPUT_DIR/Gather.app" ]]; then
  echo "refusing unsafe OUTPUT_DIR: $OUTPUT_DIR" >&2
  exit 2
fi

# WP7：gather-app/Package.swift 不再在 manifest 求值期执行 xcrun。真实 SDK
# 版本（Mach-O 的 LC_BUILD_VERSION.sdk，决定 macOS 26+ 是否启用 Liquid Glass）
# 由本脚本探测本机 SDK 后 export；显式传入的 GATHER_SDK_VERSION 优先。
# 探测失败不阻断构建：Package.swift 有固定默认值（26.0），不会静默退回 14.0。
if [[ -z "${GATHER_SDK_VERSION:-}" ]]; then
  SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || true)"
  if [[ -n "$SDK_VERSION" ]]; then
    export GATHER_SDK_VERSION="$SDK_VERSION"
  else
    echo "warning: xcrun --show-sdk-version unavailable; Package.swift default SDK version applies" >&2
  fi
fi
echo "SDK version for -platform_version: ${GATHER_SDK_VERSION:-<Package.swift default>}"

# 3b-6：两个包都开 SE-0409 严格依赖检查（target 只能 import 直接依赖）。
DEPENDENCY_CHECK=(--explicit-target-dependency-import-check error)
# app 的 SDK 版本在 manifest 求值期从 GATHER_SDK_VERSION 读取。SwiftPM 的
# manifest 缓存不把该环境变量计入 key：同一 .build 下增量构建可能沿用旧的
# -platform_version（实测 default 26.0 → env 27.0 不重链）。release 组装必须
# 关闭 manifest 缓存，保证本脚本探测到的 SDK 真正写进 Mach-O。
APP_BUILD_FLAGS=("${DEPENDENCY_CHECK[@]}" --manifest-cache none)
swift build --package-path "$CORE_PACKAGE" -c "$CONFIGURATION" "${DEPENDENCY_CHECK[@]}"
swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" "${APP_BUILD_FLAGS[@]}"

# Use SwiftPM's own bin path: the legacy .build/<config> layout is replaced by
# .build/out/Products/<Config> on newer toolchains (Xcode 16+/26/27), and
# build configuration names are capitalized there.
BIN_DIR="$(swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" "${APP_BUILD_FLAGS[@]}" --show-bin-path)"
APP_EXECUTABLE="$BIN_DIR/gather-app"
if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "native executable not found at $APP_EXECUTABLE" >&2
  exit 1
fi

# 3b-6 布局：Info.plist 归 GatherUI（Support，exclude 于 target），本地化表
# 在 GatherUI/Resources。资源 bundle 名由「包名 + target 名」决定：
#   gather-app  → gather-app_GatherUI.bundle
#   gather-core → gather-core_GatherAnalysis.bundle（FaceModels 随 Analysis）
UI_SUPPORT="$APP_PACKAGE/Sources/GatherUI/Support"
UI_RESOURCES="$APP_PACKAGE/Sources/GatherUI/Resources"
INFO_PLIST="$UI_SUPPORT/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi
# 本地化门只认非空 Localizable.strings：空 .lproj 目录会让英文界面静默全中文。
for lang in en zh-Hans; do
  STRINGS="$UI_RESOURCES/$lang.lproj/Localizable.strings"
  if [[ ! -s "$STRINGS" ]]; then
    echo "localization strings missing or empty: $STRINGS" >&2
    exit 1
  fi
done

find_bin_bundle() {
  local name="$1"
  find "$BIN_DIR" -maxdepth 1 -type d -name "$name" -print -quit
}

CORE_RESOURCE_BUNDLE="$(find_bin_bundle 'gather-core_GatherAnalysis.bundle')"
APP_RESOURCE_BUNDLE="$(find_bin_bundle 'gather-app_GatherUI.bundle')"
if [[ -z "$CORE_RESOURCE_BUNDLE" ]]; then
  echo "missing core resource bundle gather-core_GatherAnalysis.bundle in $BIN_DIR" >&2
  echo "  found bundles: $(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -exec basename {} \; | sort | tr '\n' ' ')" >&2
  exit 1
fi
if [[ -z "$APP_RESOURCE_BUNDLE" ]]; then
  echo "missing app resource bundle gather-app_GatherUI.bundle in $BIN_DIR" >&2
  echo "  found bundles: $(find "$BIN_DIR" -maxdepth 1 -type d -name '*.bundle' -exec basename {} \; | sort | tr '\n' ' ')" >&2
  exit 1
fi

# FaceModels 是打包产物里的硬依赖：运行期写死
# Bundle.module url(forResource: "SFace", withExtension: "mlpackage", subdirectory: "FaceModels")
# （GatherAnalysis/Face/EmbeddingModel.swift），缺失时首次人脸/相似度路径直接抛
# FaceEmbeddingError.modelNotFound。这里断言精确资产，任意 .mlpackage 不再算通过。
FACE_MODELS_DIR="$(find "$CORE_RESOURCE_BUNDLE" -type d -name FaceModels -print -quit)"
if [[ -z "$FACE_MODELS_DIR" ]]; then
  echo "required FaceModels directory is missing from $CORE_RESOURCE_BUNDLE" >&2
  exit 1
fi
S_FACE_PACKAGE="$FACE_MODELS_DIR/SFace.mlpackage"
if [[ ! -d "$S_FACE_PACKAGE" ]]; then
  echo "required model package is missing or not a directory: $S_FACE_PACKAGE" >&2
  echo "  runtime resolves Bundle.module url(forResource: \"SFace\", withExtension: \"mlpackage\", subdirectory: \"FaceModels\")" >&2
  echo "  found .mlpackage: $(find "$FACE_MODELS_DIR" -maxdepth 1 -name '*.mlpackage' -exec basename {} \; | sort | tr '\n' ' ')" >&2
  exit 1
fi
if [[ ! -f "$S_FACE_PACKAGE/Manifest.json" ]]; then
  echo "SFace.mlpackage is not a valid CoreML package (missing Manifest.json): $S_FACE_PACKAGE" >&2
  exit 1
fi
FACE_MANIFEST="$FACE_MODELS_DIR/manifest.json"
if [[ ! -s "$FACE_MANIFEST" ]]; then
  echo "required FaceModels manifest is missing or empty: $FACE_MANIFEST" >&2
  exit 1
fi
FACE_MANIFEST_MODEL="$(plutil -extract model raw -o - "$FACE_MANIFEST" 2>/dev/null || true)"
if [[ "$FACE_MANIFEST_MODEL" != "SFace" ]]; then
  echo "FaceModels manifest does not describe SFace (model=${FACE_MANIFEST_MODEL:-<unreadable>}): $FACE_MANIFEST" >&2
  exit 1
fi
for asset in native_ramp_reference.json LICENSE.txt; do
  if [[ ! -s "$FACE_MODELS_DIR/$asset" ]]; then
    echo "required FaceModels asset is missing or empty: $FACE_MODELS_DIR/$asset" >&2
    exit 1
  fi
done

# UI bundle 必须已经包含两种本地化，否则主 bundle 的系统菜单会退回英文单语。
# 只判断目录存在不够：空 Localizable.strings 会让整页 key 回退。
for lang in en zh-Hans; do
  STRINGS=""
  for candidate in "$APP_RESOURCE_BUNDLE/Contents/Resources/$lang.lproj" "$APP_RESOURCE_BUNDLE/$lang.lproj"; do
    if [[ -s "$candidate/Localizable.strings" ]]; then
      STRINGS="$candidate/Localizable.strings"
      break
    fi
  done
  if [[ -z "$STRINGS" ]]; then
    echo "localization bundle $lang.lproj/Localizable.strings is missing or empty in $APP_RESOURCE_BUNDLE" >&2
    exit 1
  fi
done

# 组装前校验 entitlements 资产本身：文件被删、plist 坏掉或 Apple Events 键被移除
# 都要在打包门就红，不能等到分发后 TCC 拒绝。
# 不开 com.apple.security.app-sandbox：现有签名/运行模型没有沙盒容器，授权路径、
# SPM 资源 bundle 与 Capture One 插件都按非沙盒语义工作；沙盒化需要单独的容器
# 迁移与 files.* entitlement，不能随这次发布门一起打开。
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "required entitlements file is missing: $ENTITLEMENTS" >&2
  exit 1
fi
if ! plutil -lint "$ENTITLEMENTS" >/dev/null 2>&1; then
  echo "entitlements file is not a valid plist: $ENTITLEMENTS" >&2
  exit 1
fi
APPLE_EVENTS_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS" 2>/dev/null || true)"
if [[ "$APPLE_EVENTS_ENTITLEMENT" != "true" ]]; then
  echo "entitlements must declare com.apple.security.automation.apple-events = true: $ENTITLEMENTS" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Gather"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"

# SPM 资源 bundle 随可执行文件进入 app bundle；Bundle.module 运行时按
# Contents/Resources/<package>_<target>.bundle 解析。
cp -R "$CORE_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
cp -R "$APP_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

# N08：系统菜单文案（关于/隐藏/服务/窗口/帮助）由 macOS 按**主 bundle** 的
# 本地化集合渲染。.lproj 只躺在 SPM 资源 bundle 里时，主 bundle 看起来是
# 英文单语，于是中文界面配英文系统菜单。把 GatherUI/Resources 的本地化目录
# 同时放进主 bundle，并在 Info.plist 声明 CFBundleLocalizations，两边才一致。
for lproj in "$UI_RESOURCES"/*.lproj; do
  if [[ -d "$lproj" ]]; then
    cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
  fi
done
for lang in en zh-Hans; do
  if [[ ! -s "$APP_BUNDLE/Contents/Resources/$lang.lproj/Localizable.strings" ]]; then
    echo "main bundle localization is missing or empty: $APP_BUNDLE/Contents/Resources/$lang.lproj/Localizable.strings" >&2
    exit 1
  fi
done

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
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"

  # 签名后复核：entitlement 必须真的进入代码签名，而不只是仓库里有文件。
  SIGNED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/gather-signed-entitlements.XXXXXX")"
  trap 'rm -f "${SIGNED_ENTITLEMENTS:-}"' EXIT
  if ! codesign -d --entitlements :- "$APP_BUNDLE" >"$SIGNED_ENTITLEMENTS" 2>/dev/null; then
    echo "codesign -d --entitlements failed for $APP_BUNDLE" >&2
    exit 1
  fi
  if [[ ! -s "$SIGNED_ENTITLEMENTS" ]]; then
    echo "signed app has no embedded entitlements (expected $ENTITLEMENTS): $APP_BUNDLE" >&2
    exit 1
  fi
  SIGNED_APPLE_EVENTS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  if [[ "$SIGNED_APPLE_EVENTS" != "true" ]]; then
    echo "com.apple.security.automation.apple-events is absent from the signed app's entitlements: $APP_BUNDLE" >&2
    exit 1
  fi
else
  echo "warning: CODESIGN_IDENTITY is unset; app is unsigned (entitlements apply only when signing)" >&2
fi

echo "assembled $APP_BUNDLE"
