#!/usr/bin/env bash
set -euo pipefail

# Native release assembly for Gather. The application is a self-contained
# Swift/SwiftUI bundle; no JavaScript build or renderer asset is required.
#
# WP6c：本脚本是「可复现发布」的唯一入口，环境变量契约见
# docs/DEVELOPMENT.md「可复现发布」：
#   GATHER_ARCHS=universal|arm64|x86_64  产物架构；未设 = SwiftPM 主机默认
#   GATHER_VERSION / GATHER_BUILD_NUMBER 版本注入；未设 = git describe / Info.plist 回退
#   CODESIGN_IDENTITY                    Developer ID 签名身份；未设 = 不签名
#   GATHER_NOTARIZE=1                    公证 + staple（需要 GATHER_NOTARY_PROFILE
#                                        或 APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD）
#   GATHER_RELEASE=1                     发布模式：版本/签名/公证任一缺失即 exit 1

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

# 发布模式：本地默认 0（缺凭据只警告），CI release job 显式设 1（缺凭据 exit 1）。
# RELEASE=1 是设计文档里的旧别名，保留兼容。
RELEASE_MODE="${GATHER_RELEASE:-${RELEASE:-0}}"
case "$RELEASE_MODE" in
  1|true|TRUE|yes|YES) RELEASE_MODE=1 ;;
  *) RELEASE_MODE=0 ;;
esac

# WP6c：架构选择。GATHER_ARCHS 未设时保持改造前的行为（不传 --arch，由 SwiftPM
# 按主机默认构建）。universal 用 SwiftPM 的多 --arch 产出 fat Mach-O，组装后由
# lipo 断言两个切片都在。
GATHER_ARCHS="${GATHER_ARCHS:-}"
ARCH_FLAGS=()
EXPECTED_ARCHS=()
case "$GATHER_ARCHS" in
  "")
    ;;
  universal)
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    EXPECTED_ARCHS=(arm64 x86_64)
    ;;
  arm64)
    ARCH_FLAGS=(--arch arm64)
    EXPECTED_ARCHS=(arm64)
    ;;
  x86_64)
    ARCH_FLAGS=(--arch x86_64)
    EXPECTED_ARCHS=(x86_64)
    ;;
  *)
    echo "invalid GATHER_ARCHS='$GATHER_ARCHS' (expected universal|arm64|x86_64)" >&2
    exit 2
    ;;
esac

# WP6c：版本注入。优先显式 GATHER_VERSION，其次 git 最近 tag（git describe）。
# 两者都没有时**保留 Info.plist 现有回退值（3.0.0）**，不凭空造版本号。
# CFBundleVersion 用 GATHER_BUILD_NUMBER，否则 git 提交数（单调递增、可公证），
# 再否则由版本号派生的数字串。
VERSION_SOURCE="plist"
SHORT_VERSION=""
BUILD_NUMBER=""
BUILD_SOURCE="plist"

if [[ -n "${GATHER_VERSION:-}" ]]; then
  SHORT_VERSION="$GATHER_VERSION"
  VERSION_SOURCE="GATHER_VERSION"
elif GIT_TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null)"; then
  SHORT_VERSION="$GIT_TAG"
  VERSION_SOURCE="git describe --tags"
fi
SHORT_VERSION="${SHORT_VERSION#v}"
SHORT_VERSION="${SHORT_VERSION#V}"

if [[ -n "$SHORT_VERSION" ]]; then
  if [[ ! "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}([-.+][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    echo "invalid version '$SHORT_VERSION' from $VERSION_SOURCE (expected e.g. 3.0.0 or 3.0.0-beta.1)" >&2
    exit 2
  fi
  if [[ -n "${GATHER_BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$GATHER_BUILD_NUMBER"
    BUILD_SOURCE="GATHER_BUILD_NUMBER"
  elif BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)" && [[ -n "$BUILD_NUMBER" ]]; then
    BUILD_SOURCE="git rev-list --count"
  else
    BUILD_NUMBER="$(printf '%s' "$SHORT_VERSION" | LC_ALL=C tr -c '0-9.' '.' | sed -e 's/\.\{2,\}/./g' -e 's/^\.//' -e 's/\.$//')"
    BUILD_SOURCE="version"
  fi
  if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "invalid build number '$BUILD_NUMBER' from $BUILD_SOURCE (expected digits and dots)" >&2
    exit 2
  fi
elif [[ -n "${GATHER_BUILD_NUMBER:-}" ]]; then
  echo "warning: GATHER_BUILD_NUMBER is set but no version was resolved; ignoring it" >&2
fi

if [[ "$RELEASE_MODE" == "1" && -z "$SHORT_VERSION" ]]; then
  echo "release mode requires GATHER_VERSION or a git tag (Info.plist 3.0.0 is only a local fallback)" >&2
  exit 1
fi

if [[ -n "$SHORT_VERSION" ]]; then
  echo "version: $SHORT_VERSION (build $BUILD_NUMBER; source: $VERSION_SOURCE / $BUILD_SOURCE)"
else
  echo "version: no GATHER_VERSION and no git tag; Info.plist fallback applies"
fi
if [[ ${#ARCH_FLAGS[@]} -gt 0 ]]; then
  echo "architectures: $GATHER_ARCHS"
else
  echo "architectures: SwiftPM host default (set GATHER_ARCHS=universal|arm64|x86_64 to pin)"
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
swift build --package-path "$CORE_PACKAGE" -c "$CONFIGURATION" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} "${DEPENDENCY_CHECK[@]}"
swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} "${APP_BUILD_FLAGS[@]}"

# Use SwiftPM's own bin path: the legacy .build/<config> layout is replaced by
# .build/out/Products/<Config> on newer toolchains (Xcode 16+/26/27), and
# build configuration names are capitalized there.
BIN_DIR="$(swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} "${APP_BUILD_FLAGS[@]}" --show-bin-path)"
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
BUNDLE_INFO="$APP_BUNDLE/Contents/Info.plist"
cp "$INFO_PLIST" "$BUNDLE_INFO"

# WP6c：版本注入只改**产物**的 Info.plist，仓库里的 Info.plist 保留 3.0.0 作为
# 未注入时的回退值。写后立即读回断言，避免 plutil 静默失败。
if [[ -n "$SHORT_VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$BUNDLE_INFO"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$BUNDLE_INFO"
  INJECTED_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE_INFO")"
  INJECTED_BUILD="$(plutil -extract CFBundleVersion raw -o - "$BUNDLE_INFO")"
  if [[ "$INJECTED_SHORT" != "$SHORT_VERSION" || "$INJECTED_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "version injection failed: expected $SHORT_VERSION ($BUILD_NUMBER), got $INJECTED_SHORT ($INJECTED_BUILD)" >&2
    exit 1
  fi
  echo "injected CFBundleShortVersionString=$INJECTED_SHORT CFBundleVersion=$INJECTED_BUILD"
else
  FALLBACK_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE_INFO")"
  echo "version: kept Info.plist fallback CFBundleShortVersionString=$FALLBACK_SHORT"
fi
if ! plutil -lint "$BUNDLE_INFO" >/dev/null; then
  echo "assembled Info.plist is not a valid plist: $BUNDLE_INFO" >&2
  exit 1
fi

# WP6c：universal 断言。只认 lipo 的实际切片，不认传递过的 --arch 参数。
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Gather"
if [[ ${#EXPECTED_ARCHS[@]} -gt 0 ]]; then
  BINARY_ARCHS="$(lipo -archs "$APP_BINARY")"
  for want in "${EXPECTED_ARCHS[@]}"; do
    case " $BINARY_ARCHS " in
      *" $want "*)
        ;;
      *)
        echo "binary is missing the $want slice (lipo -archs: $BINARY_ARCHS): $APP_BINARY" >&2
        exit 1
        ;;
    esac
  done
  echo "binary architectures: $BINARY_ARCHS"
fi

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
  if [[ "$GATHER_ARCHS" == "universal" ]]; then
    echo "warning: GatherLink.coplugin is built for the host arch only (make TARGET_ARCH=$(uname -m)); the app binary is universal" >&2
  fi
  make -C "$ROOT_DIR/desktop/coplugin" TARGET_ARCH="$(uname -m)" all
  if [[ -d "$ROOT_DIR/desktop/coplugin/GatherLink.coplugin" ]]; then
    mkdir -p "$APP_BUNDLE/Contents/PlugIns"
    cp -R "$ROOT_DIR/desktop/coplugin/GatherLink.coplugin" "$APP_BUNDLE/Contents/PlugIns/"
  fi
else
  echo "warning: Capture One SDK not found; skipping GatherLink.coplugin" >&2
fi

# WP6c：bundle 排障元数据。固定键序、不含时间戳，同样的输入产出同样的字节。
# 键值都来自受控集合（版本已过正则、commit 是十六进制、archs 来自 lipo），这里
# 再剔除 SDK 版本里的引号/反斜杠；写完用 plutil 按 JSON 解析一次做校验
# （plutil -lint 只接受 plist，不接受 JSON 输入）。
BUILD_INFO="$APP_BUNDLE/Contents/Resources/build-info.json"
BUILD_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
FINAL_INFO_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE_INFO")"
FINAL_INFO_BUILD="$(plutil -extract CFBundleVersion raw -o - "$BUNDLE_INFO")"
FINAL_ARCHS="$(lipo -archs "$APP_BINARY" 2>/dev/null || uname -m)"
SAFE_SDK_VERSION="$(printf '%s' "${GATHER_SDK_VERSION:-default}" | LC_ALL=C tr -d '\"\\\\')"
cat > "$BUILD_INFO" <<JSON
{"version":"$FINAL_INFO_SHORT","build":"$FINAL_INFO_BUILD","commit":"$BUILD_COMMIT","archs":"$FINAL_ARCHS","sdk_version":"$SAFE_SDK_VERSION"}
JSON
if ! plutil -convert xml1 -o /dev/null "$BUILD_INFO" 2>/dev/null; then
  echo "build-info.json is not valid JSON: $BUILD_INFO" >&2
  exit 1
fi

SIGNED=0
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # WP6c：notarytool 要求安全时间戳；ad-hoc 身份（"-"）没有时间戳服务，跳过该
  # flag。--options runtime 保留 hardened runtime。
  TIMESTAMP_FLAG=()
  if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    TIMESTAMP_FLAG=(--timestamp)
  fi

  sign_nested() {
    local target="$1"
    codesign --force --options runtime \
      ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} \
      --sign "$CODESIGN_IDENTITY" "$target"
  }

  # 显式签嵌套项（替换 --deep）：内层先签、主 bundle 后签，否则 --deep 会覆盖
  # 已签名子项，公证会拒绝。SwiftPM 资源 bundle 没有可执行代码，但签一遍可以
  # 让 codesign --verify --deep --strict 通过且封条一致。
  for nested_dir in "Contents/PlugIns" "Contents/Frameworks"; do
    if [[ -d "$APP_BUNDLE/$nested_dir" ]]; then
      for nested in "$APP_BUNDLE/$nested_dir"/*; do
        if [[ -e "$nested" ]]; then
          sign_nested "$nested"
        fi
      done
    fi
  done
  for nested in "$APP_BUNDLE/Contents/Resources"/*.bundle "$APP_BUNDLE/Contents/Resources"/*.framework; do
    if [[ -e "$nested" && ( -f "$nested/Contents/Info.plist" || -f "$nested/Info.plist" ) ]]; then
      sign_nested "$nested"
    fi
  done

  codesign --force --options runtime \
    ${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"} \
    --entitlements "$ENTITLEMENTS" \
    --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
  SIGNED=1

  if ! codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"; then
    echo "codesign --verify --deep --strict failed for $APP_BUNDLE" >&2
    exit 1
  fi

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
  if [[ "$RELEASE_MODE" == "1" ]]; then
    echo "release mode requires CODESIGN_IDENTITY; refusing to ship an unsigned bundle" >&2
    exit 1
  fi
  echo "warning: CODESIGN_IDENTITY is unset; app is unsigned (entitlements apply only when signing)" >&2
fi

# WP6c：公证 + staple。GATHER_NOTARIZE=1 才进入；凭据两种来源：
#   GATHER_NOTARY_PROFILE（notarytool --keychain-profile）
#   APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD（--apple-id/--team-id/--password）
# 凭据缺失时：本地明确 skip 且 exit 0；GATHER_RELEASE=1 时 exit 1（发布门不静默）。
NOTARIZE="${GATHER_NOTARIZE:-0}"
case "$NOTARIZE" in
  1|true|TRUE|yes|YES) NOTARIZE=1 ;;
  *) NOTARIZE=0 ;;
esac
NOTARIZED=0
if [[ "$NOTARIZE" == "1" ]]; then
  NOTARY_ARGS=()
  NOTARY_MISSING=""
  if [[ -z "${CODESIGN_IDENTITY:-}" || "${CODESIGN_IDENTITY:-}" == "-" ]]; then
    NOTARY_MISSING="a Developer ID signing identity (CODESIGN_IDENTITY)"
  elif [[ -n "${GATHER_NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$GATHER_NOTARY_PROFILE")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  else
    NOTARY_MISSING="notary credentials (GATHER_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD)"
  fi

  if [[ -n "$NOTARY_MISSING" ]]; then
    echo "warning: GATHER_NOTARIZE=1 but $NOTARY_MISSING is unavailable; notarization skipped" >&2
    if [[ "$RELEASE_MODE" == "1" ]]; then
      echo "release mode requires notarization; refusing to skip" >&2
      exit 1
    fi
    echo "notarization skipped (local build); set $NOTARY_MISSING to enable it" >&2
  else
    ZIP_PATH="$OUTPUT_DIR/Gather.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl -a -t exec -vvv "$APP_BUNDLE"
    NOTARIZED=1
  fi
fi

if [[ "$SIGNED" == "1" ]]; then
  SIGN_STATE="signed ($CODESIGN_IDENTITY)"
else
  SIGN_STATE="unsigned"
fi
if [[ "$NOTARIZED" == "1" ]]; then
  NOTARY_STATE="notarized + stapled ($OUTPUT_DIR/Gather.zip)"
else
  NOTARY_STATE="not notarized"
fi

echo "assembled $APP_BUNDLE"
echo "  version:       $(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE_INFO") ($(plutil -extract CFBundleVersion raw -o - "$BUNDLE_INFO"))"
echo "  architectures: ${FINAL_ARCHS}"
echo "  signing:       $SIGN_STATE"
echo "  notarization:  $NOTARY_STATE"
