#!/usr/bin/env bash
set -euo pipefail

# Native release assembly for Gather. The application is a self-contained
# Swift/SwiftUI bundle; no JavaScript build or renderer asset is required.
#
# WP6c：本脚本是「可复现发布」的唯一入口，环境变量契约见
# docs/DEVELOPMENT.md「可复现发布」：
#   GATHER_ARCHS=universal|arm64|x86_64  产物架构（app 与 GatherLink.coplugin）；
#                                        未设 = SwiftPM 主机默认
#   GATHER_VERSION / GATHER_BUILD_NUMBER 版本注入；未设 = git describe / Info.plist 回退；
#                                        BUILD_NUMBER 单独设置但无版本时警告并忽略
#   GATHER_SDK_VERSION                   LC_BUILD_VERSION.sdk；未设 = xcrun 探测，
#                                        探测失败回退 Package.swift 的 26.0
#   CODESIGN_IDENTITY                    Developer ID 签名身份；未设 = 不签名
#   GATHER_NOTARIZE=1                    公证 + staple（需要 GATHER_NOTARY_PROFILE
#                                        或 APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD）
#   GATHER_RELEASE=1                     发布模式：版本/universal/签名/公证/插件
#                                        任一缺失即 exit 1
#   GATHER_SWIFT_FLAGS                   追加给 swift build 的额外参数（默认空）。
#                                        受限环境下需要 --disable-sandbox：外层已经有
#                                        沙箱（CI runner / 容器）时 SwiftPM 自带的
#                                        sandbox-exec 会 apply 失败，构建直接报
#                                        "sandbox_apply: Operation not permitted"。
#                                        只做追加，脚本自己的 -c/--arch/--manifest-cache
#                                        等参数不受影响。
#   GATHER_SKIP_APPINTENTS_METADATA=1    跳过 App Intents 元数据提取（仅限本地排障；
#                                        Shortcuts 将看不到 Gather 的 6 个动作，
#                                        GATHER_RELEASE=1 下不应使用）。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# 单行失败助手：release 脚本里 30+ 处 exit 1/2 的入口统一成 fail/refuse，
# 消息格式保持一致（错误行只输出一行，便于 CI 日志定位）。
fail() { echo "$*" >&2; exit 1; }
refuse() { echo "$*" >&2; exit 2; }
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/release}"
# OUTPUT_DIR 允许相对路径，但统一按仓库根解析；随后拒绝会逃逸、重复斜杠、
# 结尾斜杠以及含 "." / ".." 段的形态。旧断言
#   "$APP_BUNDLE" != "$OUTPUT_DIR/Gather.app"
# 两边恒等，实际只拦住了 "/"（OUTPUT_DIR="//"、"/tmp/.." 等都能绕过）。
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi
case "$OUTPUT_DIR" in
  /|//*|*/|*//*) refuse "refusing unsafe OUTPUT_DIR: $OUTPUT_DIR" ;;
esac
case "/$OUTPUT_DIR/" in
  */../*|*/./*) refuse "refusing non-normalized OUTPUT_DIR (contains '.' or '..'): $OUTPUT_DIR" ;;
esac
APP_BUNDLE="$OUTPUT_DIR/Gather.app"
APP_PACKAGE="$SCRIPT_DIR/gather-app"
# C1（Capture One）走 NSAppleScript 发送 Apple Events；hardened runtime 分发包
# 没有该 entitlement 会被 TCC 拒绝（-1743）。签名身份仍只由 CODESIGN_IDENTITY
# 决定，这里只是随签名一起提交的固定资产。
ENTITLEMENTS="$SCRIPT_DIR/Gather.entitlements"
# Capture One 授权 SDK 不在仓库内（.gitignore 排除），插件构建段在 SDK 存在时按
# GATHER_ARCHS 逐切片构建。路径定义提到发布门之前，缺 SDK 时在构建前 fail fast。
PLUGIN_SDK="$ROOT_DIR/Capture_One_Plugin_SDK_(Mac)_v1.0.1"
PLUGIN_DIR="$ROOT_DIR/desktop/coplugin"
PLUGIN_BUNDLE="$PLUGIN_DIR/GatherLink.coplugin"
PLUGIN_BINARY="$PLUGIN_BUNDLE/Contents/MacOS/GatherLink"
# P2-6：插件部署目标对齐 app（26.0）。Makefile 默认值也已对齐；这里仍显式覆盖
# TARGET，避免 Makefile 与脚本再次漂移（make 命令行变量优先）。
PLUGIN_DEPLOYMENT_TARGET="26.0"

# 发布模式：本地默认 0（缺凭据只警告），CI release job 显式设 1（缺凭据 exit 1）。
RELEASE_MODE="${GATHER_RELEASE:-0}"
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
    refuse "invalid GATHER_ARCHS='$GATHER_ARCHS' (expected universal|arm64|x86_64)"
    ;;
esac

# 公证凭据解析前移：发布门与公证步骤共用同一份判定（NOTARY_ARGS 为 notarytool
# 参数，NOTARY_MISSING 为具名缺失原因）。本地缺凭据只警告并跳过公证；发布门缺
# 凭据在构建前 exit 1，不再等整次构建 + 签名之后才失败。
NOTARIZE="${GATHER_NOTARIZE:-0}"
case "$NOTARIZE" in
  1|true|TRUE|yes|YES) NOTARIZE=1 ;;
  *) NOTARIZE=0 ;;
esac
NOTARY_ARGS=()
NOTARY_MISSING=""
if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" || "${CODESIGN_IDENTITY:-}" == "-" ]]; then
    NOTARY_MISSING="a Developer ID signing identity (CODESIGN_IDENTITY)"
  elif [[ -n "${GATHER_NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$GATHER_NOTARY_PROFILE")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  else
    NOTARY_MISSING="notary credentials (GATHER_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD)"
  fi
fi

# 发布门：版本之外还必须 universal + Developer ID 签名 + 公证凭据 + 授权 C1 SDK，
# 任一缺失都在构建前失败，避免产出「看起来 release、实际不可分发」的 bundle。
if [[ "$RELEASE_MODE" == "1" ]]; then
  [[ "$GATHER_ARCHS" == "universal" ]] || fail "release mode requires GATHER_ARCHS=universal (got '${GATHER_ARCHS:-host-default}')"
  if [[ -z "${CODESIGN_IDENTITY:-}" || "${CODESIGN_IDENTITY:-}" == "-" ]]; then
    fail "release mode requires a Developer ID identity (CODESIGN_IDENTITY; ad-hoc '-' is not shippable)"
  fi
  [[ "$NOTARIZE" == "1" ]] || fail "release mode requires GATHER_NOTARIZE=1"
  [[ -z "$NOTARY_MISSING" ]] || fail "release mode requires notarization credentials: $NOTARY_MISSING"
  if [[ ! -d "$PLUGIN_SDK" || ! -f "$PLUGIN_DIR/Makefile" ]]; then
    fail "release mode requires the licensed Capture One plugin SDK at '$PLUGIN_SDK' and $PLUGIN_DIR/Makefile; install them on the release runner first"
  fi
fi

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
  echo "warning: GATHER_BUILD_NUMBER is set but no version was resolved; ignoring it (set GATHER_VERSION or create a git tag to apply it)" >&2
fi

if [[ "$RELEASE_MODE" == "1" && -z "$SHORT_VERSION" ]]; then
  fail "release mode requires GATHER_VERSION or a git tag (Info.plist 3.0.0 is only a local fallback)"
fi

if [[ -n "$SHORT_VERSION" ]]; then
  echo "version: $SHORT_VERSION (build $BUILD_NUMBER; source: $VERSION_SOURCE / $BUILD_SOURCE)"
else
  echo "version: no GATHER_VERSION and no git tag; Info.plist fallback applies"
fi
echo "architectures: ${GATHER_ARCHS:-SwiftPM host default (set GATHER_ARCHS=universal|arm64|x86_64 to pin)}"

# P2-5：旧 zip 不能冒充本次产物。无论是否公证，组装前先删掉 OUTPUT_DIR 里的
# 旧包与旧校验和；构建失败时也不留下可被误传的“上一次成功包”。
rm -f "$OUTPUT_DIR/Gather.zip" "$OUTPUT_DIR/Gather.zip.sha256"

# WP7：Package.swift 只读 GATHER_SDK_VERSION（manifest 不执行外部进程）；
# 真实 SDK（Mach-O 的 LC_BUILD_VERSION.sdk，决定 macOS 26+ 是否启用
# Liquid Glass）由本脚本探测本机后 export，显式传入的值优先级最高。
# 部署目标已是 26.0，探测失败时默认值仍满足 SDK>=26；这里记录来源，
# release 模式在探测失败时 fail closed（无法记录真实 SDK 属环境异常）。
if [[ -z "${GATHER_SDK_VERSION:-}" ]]; then
  SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  if [[ -n "$SDK_VERSION" ]]; then
    export GATHER_SDK_VERSION="$SDK_VERSION"
    SDK_VERSION_SOURCE="xcrun"
  else
    SDK_VERSION_SOURCE="Package.swift default (26.0)"
    if [[ "$RELEASE_MODE" == "1" ]]; then
      fail "release mode requires xcrun --sdk macosx --show-sdk-version to record the real SDK (Liquid Glass needs >= 26)"
    fi
    echo "warning: xcrun --sdk macosx --show-sdk-version unavailable; Package.swift default SDK 26.0 applies" >&2
  fi
else
  SDK_VERSION_SOURCE="GATHER_SDK_VERSION"
fi
DECLARED_SDK_VERSION="$(printf '%s' "${GATHER_SDK_VERSION:-}" | LC_ALL=C tr -d '[:space:]')"
echo "SDK version for -platform_version: ${DECLARED_SDK_VERSION:-<Package.swift default 26.0>} (source: $SDK_VERSION_SOURCE)"

# 3b-6：两个包都开 SE-0409 严格依赖检查（target 只能 import 直接依赖）。
DEPENDENCY_CHECK=(--explicit-target-dependency-import-check error)
# app 的 SDK 版本在 manifest 求值期从 GATHER_SDK_VERSION 读取。SwiftPM 的
# manifest 缓存不把该环境变量计入 key：同一 .build 下增量构建可能沿用旧的
# -platform_version（历史实测：只改 env 不重链）。release 组装必须
# 关闭 manifest 缓存，保证本脚本探测到的 SDK 真正写进 Mach-O。
APP_BUILD_FLAGS=("${DEPENDENCY_CHECK[@]}" --manifest-cache none)
# 追加参数（见文件头 GATHER_SWIFT_FLAGS）：默认空数组，bash 3.2 下空数组展开要加守卫。
EXTRA_FLAGS=()
if [[ -n "${GATHER_SWIFT_FLAGS:-}" ]]; then
  read -r -a EXTRA_FLAGS <<< "$GATHER_SWIFT_FLAGS"
fi
# core 不再单独构建（release-audit P2 #5）：app 包以 `.package(path: "../gather-core")`
# 依赖 core，`swift build --package-path gather-app` 会在 **app 的 .build** 内构建
# 所需 core library products（含 GatherAnalysis 的 FaceModels 资源 bundle，下面
# 直接从 app BIN_DIR 查找）；旧实现额外跑一次 `--package-path gather-core`，产物落在
# gather-core/.build，与组装路径不是同一份，纯重复（core 的 4 个 executable target
# 与 GatherTestSupport 白编一遍，每次发布约 1–3 分钟）。core 侧的严格编译契约
# （-warnings-as-errors + --explicit-target-dependency-import-check）仍由 CI
# gather-core job 的 scripts/check-warnings.sh core 覆盖。
swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} "${APP_BUILD_FLAGS[@]}" \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}

# Use SwiftPM's own bin path: the legacy .build/<config> layout is replaced by
# .build/out/Products/<Config> on newer toolchains (Xcode 16+/26/27), and
# build configuration names are capitalized there.
BIN_DIR="$(swift build --package-path "$APP_PACKAGE" -c "$CONFIGURATION" \
  ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} "${APP_BUILD_FLAGS[@]}" \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} --show-bin-path)"
APP_EXECUTABLE="$BIN_DIR/gather-app"
[[ -x "$APP_EXECUTABLE" ]] || fail "native executable not found at $APP_EXECUTABLE"

# 3b-6 布局：Info.plist 归 GatherUI（Support，exclude 于 target），本地化表
# 在 GatherUI/Resources。资源 bundle 名由「包名 + target 名」决定：
#   gather-app  → gather-app_GatherUI.bundle
#   gather-core → gather-core_GatherAnalysis.bundle（FaceModels 随 Analysis）
UI_SUPPORT="$APP_PACKAGE/Sources/GatherUI/Support"
UI_RESOURCES="$APP_PACKAGE/Sources/GatherUI/Resources"
INFO_PLIST="$UI_SUPPORT/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist not found at $INFO_PLIST"

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
  fail "required FaceModels directory is missing from $CORE_RESOURCE_BUNDLE (runtime resolves Bundle.module url(forResource: \"SFace\", withExtension: \"mlpackage\", subdirectory: \"FaceModels\"))"
fi
S_FACE_PACKAGE="$FACE_MODELS_DIR/SFace.mlpackage"
FACE_MANIFEST="$FACE_MODELS_DIR/manifest.json"
# FaceModels 的 5 项精确资产断言（不退化为「目录存在」）：CoreML 模型包 + 可解析
# manifest + 权重/授权资产；缺任意一项首次人脸/相似度路径直接抛 modelNotFound。
require_face_asset() { # $1=路径 $2=dir|file
  if [[ "$2" == "dir" ]]; then
    [[ -d "$1" ]] || fail "required FaceModels model package is missing or not a directory: $1"
  else
    [[ -s "$1" ]] || fail "required FaceModels file is missing or empty: $1"
  fi
}
require_face_asset "$S_FACE_PACKAGE" dir
require_face_asset "$S_FACE_PACKAGE/Manifest.json" file
require_face_asset "$FACE_MANIFEST" file
FACE_MANIFEST_MODEL="$(plutil -extract model raw -o - "$FACE_MANIFEST" 2>/dev/null || true)"
[[ "$FACE_MANIFEST_MODEL" == "SFace" ]] || fail "FaceModels manifest does not describe SFace (model=${FACE_MANIFEST_MODEL:-<unreadable>}): $FACE_MANIFEST"
for asset in native_ramp_reference.json LICENSE.txt; do
  require_face_asset "$FACE_MODELS_DIR/$asset" file
done

# 组装前校验 entitlements 资产本身：文件被删、plist 坏掉或 Apple Events 键被移除
# 都要在打包门就红，不能等到分发后 TCC 拒绝。
# 不开 com.apple.security.app-sandbox：现有签名/运行模型没有沙盒容器，授权路径、
# SPM 资源 bundle 与 Capture One 插件都按非沙盒语义工作；沙盒化需要单独的容器
# 迁移与 files.* entitlement，不能随这次发布门一起打开。
[[ -f "$ENTITLEMENTS" ]] || fail "required entitlements file is missing: $ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null 2>&1 || fail "entitlements file is not a valid plist: $ENTITLEMENTS"
APPLE_EVENTS_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS" 2>/dev/null || true)"
[[ "$APPLE_EVENTS_ENTITLEMENT" == "true" ]] || fail "entitlements must declare com.apple.security.automation.apple-events = true: $ENTITLEMENTS"

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
    fail "version injection failed: expected $SHORT_VERSION ($BUILD_NUMBER), got $INJECTED_SHORT ($INJECTED_BUILD)"
  fi
  echo "injected CFBundleShortVersionString=$INJECTED_SHORT CFBundleVersion=$INJECTED_BUILD"
else
  FALLBACK_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE_INFO")"
  echo "version: kept Info.plist fallback CFBundleShortVersionString=$FALLBACK_SHORT"
fi
plutil -lint "$BUNDLE_INFO" >/dev/null || fail "assembled Info.plist is not a valid plist: $BUNDLE_INFO"

# WP6c：universal 断言。只认 lipo 的实际切片，不认传递过的 --arch 参数。
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Gather"
if [[ ${#EXPECTED_ARCHS[@]} -gt 0 ]]; then
  BINARY_ARCHS="$(lipo -archs "$APP_BINARY")"
  for want in "${EXPECTED_ARCHS[@]}"; do
    case " $BINARY_ARCHS " in
      *" $want "*) ;;
      *) fail "binary is missing the $want slice (lipo -archs: $BINARY_ARCHS): $APP_BINARY" ;;
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
# 应用图标必须位于主 bundle 的 Contents/Resources（CFBundleIconFile=AppIcon）。
if [[ -f "$UI_RESOURCES/AppIcon.icns" ]]; then
  cp "$UI_RESOURCES/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
  if [[ "$RELEASE_MODE" == "1" ]]; then
    fail "release mode requires GatherUI/Resources/AppIcon.icns"
  fi
  echo "warning: AppIcon.icns is missing; the app will use the generic icon" >&2
fi
# 本地化门唯一实现（终态复核）：主 bundle 的 .lproj 决定系统菜单语言，嵌套 SPM
# 资源 bundle 的 .lproj 是 Bundle.module 的查表来源，两者都必须带非空
# Localizable.strings；只查源目录会漏掉资源处理阶段的丢文件（空表静默回退）。
UI_RESOURCE_BUNDLE_NAME="$(basename "$APP_RESOURCE_BUNDLE")"
for lang in en zh-Hans; do
  FOUND_STRINGS=""
  for candidate in \
      "$APP_BUNDLE/Contents/Resources/$lang.lproj" \
      "$APP_BUNDLE/Contents/Resources/$UI_RESOURCE_BUNDLE_NAME/Contents/Resources/$lang.lproj" \
      "$APP_BUNDLE/Contents/Resources/$UI_RESOURCE_BUNDLE_NAME/$lang.lproj"; do
    if [[ -s "$candidate/Localizable.strings" ]]; then
      FOUND_STRINGS=1
      break
    fi
  done
  [[ -n "$FOUND_STRINGS" ]] || fail "localization $lang.lproj/Localizable.strings is missing or empty in the assembled bundle (main bundle or $UI_RESOURCE_BUNDLE_NAME)"
done

# The Capture One plugin is optional at build time because its SDK is licensed
# and is not part of this repository. When the SDK is present, build one slice
# per requested app architecture and lipo them together: a universal app must
# not embed a host-only plugin (Intel users would silently lose the C1 entry).
# The SDK framework itself ships x86_64+arm64, and the plugin only uses
# Foundation/AppKit/SDK types, so every GATHER_ARCHS slice is expected to build.
# 路径变量与 PLUGIN_DEPLOYMENT_TARGET 在文件头（发布门在构建前据此 fail fast）。
# build-info 用：未嵌入时为 none，嵌入后记录实际切片。
PLUGIN_INFO="none"

PLUGIN_ARCHS=()
if [[ ${#EXPECTED_ARCHS[@]} -gt 0 ]]; then
  PLUGIN_ARCHS=("${EXPECTED_ARCHS[@]}")
else
  PLUGIN_ARCHS=("$(uname -m)")
fi

plugin_has_arch() {
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -d "$PLUGIN_SDK" && -f "$PLUGIN_DIR/Makefile" ]]; then
  PLUGIN_BUILT_ARCHS=()
  # 构建中间物统一放仓库 .build/：release/ 只留产物。旧实现把 TMPDIR 与模块缓存
  # 放在 OUTPUT_DIR，每打一次包就在发布目录留下 ~270MB 的模块缓存（进程结束不清理）。
  PLUGIN_SLICES_DIR="$ROOT_DIR/.build/gather-plugin-slices"
  PLUGIN_TMP="$ROOT_DIR/.build/gather-plugin-tmp"
  PLUGIN_MODULE_CACHE="$ROOT_DIR/.build/gather-plugin-module-cache"
  rm -rf "$PLUGIN_SLICES_DIR" "$PLUGIN_TMP"
  mkdir -p "$PLUGIN_SLICES_DIR" "$PLUGIN_TMP" "$PLUGIN_MODULE_CACHE"
  # 插件用 swiftc 直接编译，模块缓存默认落在系统临时目录；受限环境（CI 容器/
  # 本机沙箱）可能不可写，导致跨架构切片静默复用上一架构的产物。把 TMPDIR、
  # CLANG_MODULE_CACHE_PATH 与 MODULE_CACHE_PATH 固定到 .build/ 下；
  # swiftc 直编只认 -module-cache-path（Makefile 从 MODULE_CACHE_PATH 生成）。
  # 清掉旧架构戳与旧二进制，强制每个切片都按当前源码重编译，失败时不会把
  # 上一架构的二进制误当成本架构产物。
  rm -f "$PLUGIN_BUNDLE"/.arch-* "$PLUGIN_BINARY"
  for arch in "${PLUGIN_ARCHS[@]}"; do
    if TMPDIR="$PLUGIN_TMP" CLANG_MODULE_CACHE_PATH="$PLUGIN_MODULE_CACHE" \
        MODULE_CACHE_PATH="$PLUGIN_MODULE_CACHE" \
        make -B -C "$PLUGIN_DIR" TARGET_ARCH="$arch" \
        TARGET="$arch-apple-macosx$PLUGIN_DEPLOYMENT_TARGET" all; then
      if [[ -f "$PLUGIN_BINARY" ]]; then
        SLICE_ARCHS="$(lipo -archs "$PLUGIN_BINARY")"
        if plugin_has_arch "$arch" "$SLICE_ARCHS"; then
          cp "$PLUGIN_BINARY" "$PLUGIN_SLICES_DIR/GatherLink-$arch"
          PLUGIN_BUILT_ARCHS+=("$arch")
        else
          echo "warning: GatherLink.coplugin $arch build produced '$SLICE_ARCHS' instead" >&2
        fi
      else
        echo "warning: GatherLink.coplugin build for $arch produced no binary" >&2
      fi
    else
      echo "warning: GatherLink.coplugin $arch slice failed to build" >&2
    fi
  done
  if [[ ${#PLUGIN_BUILT_ARCHS[@]} -gt 0 ]]; then
    PLUGIN_SLICES=()
    for arch in "${PLUGIN_BUILT_ARCHS[@]}"; do
      PLUGIN_SLICES+=("$PLUGIN_SLICES_DIR/GatherLink-$arch")
    done
    lipo -create ${PLUGIN_SLICES[@]+"${PLUGIN_SLICES[@]}"} -output "$PLUGIN_BINARY"
    chmod +x "$PLUGIN_BINARY"
    PLUGIN_ACTUAL_ARCHS="$(lipo -archs "$PLUGIN_BINARY")"
    # 插件 minos 必须与部署目标一致（按切片构建后 lipo 的最终产物）。
    PLUGIN_MINOS="$(vtool -show-build "$PLUGIN_BINARY" 2>/dev/null | awk '$1=="minos"{print $2; exit}' || true)"
    if [[ -n "$PLUGIN_MINOS" && "$PLUGIN_MINOS" != "$PLUGIN_DEPLOYMENT_TARGET" ]]; then
      echo "warning: GatherLink.coplugin minos is $PLUGIN_MINOS (expected $PLUGIN_DEPLOYMENT_TARGET)" >&2
      if [[ "$RELEASE_MODE" == "1" ]]; then
        rm -rf "$PLUGIN_SLICES_DIR"
        fail "release mode requires GatherLink.coplugin minos $PLUGIN_DEPLOYMENT_TARGET (got ${PLUGIN_MINOS:-unknown})"
      fi
    fi
    # otool 对 universal 文件会为每个切片重复打印同一条 LC_RPATH；sort -u
    # 去重，避免 install_name_tool -delete_rpath 第二次找不到而失败。
    PLUGIN_RPATHS="$(otool -l "$PLUGIN_BINARY" 2>/dev/null | awk '$1=="path"{print $2}' | sort -u || true)"
    PLUGIN_MISSING_ARCHS=()
    for want in "${PLUGIN_ARCHS[@]}"; do
      if ! plugin_has_arch "$want" "$PLUGIN_ACTUAL_ARCHS"; then
        PLUGIN_MISSING_ARCHS+=("$want")
      fi
    done
    if [[ ${#PLUGIN_MISSING_ARCHS[@]} -gt 0 ]]; then
      echo "plugin is missing slice(s): ${PLUGIN_MISSING_ARCHS[*]} (lipo -archs: $PLUGIN_ACTUAL_ARCHS)" >&2
      if [[ "$RELEASE_MODE" == "1" ]]; then
        rm -rf "$PLUGIN_SLICES_DIR"
        fail "release mode requires a GatherLink.coplugin matching GATHER_ARCHS (${PLUGIN_ARCHS[*]})"
      fi
      echo "warning: embedding a partially-architected GatherLink.coplugin; universal app + this plugin is not release-ready" >&2
    fi
    # 架构戳与最终产物保持一致：universal 插件同时满足任一单架构的 make 依赖。
    rm -f "$PLUGIN_BUNDLE"/.arch-*
    for arch in "${PLUGIN_BUILT_ARCHS[@]}"; do
      touch "$PLUGIN_BUNDLE/.arch-$arch"
    done
    # 让 universal 二进制比架构戳新：下次 make 只在源码变化时重编译。
    touch "$PLUGIN_BINARY"
    echo "plugin architectures: $PLUGIN_ACTUAL_ARCHS (expected: ${PLUGIN_ARCHS[*]})"
    rm -rf "$PLUGIN_SLICES_DIR"
    mkdir -p "$APP_BUNDLE/Contents/PlugIns"
    cp -R "$PLUGIN_BUNDLE" "$APP_BUNDLE/Contents/PlugIns/"
    EMBEDDED_PLUGIN="$APP_BUNDLE/Contents/PlugIns/GatherLink.coplugin"
    EMBEDDED_PLUGIN_BINARY="$EMBEDDED_PLUGIN/Contents/MacOS/GatherLink"
    # P2-4：.arch-* 是 Makefile 的增量构建戳，不是插件资产。cp -R 会连隐藏
    # 文件一起复制；源目录保留给 make，只清产物副本。
    rm -f "$EMBEDDED_PLUGIN"/.arch-*
    PLUGIN_INFO="$PLUGIN_ACTUAL_ARCHS"
    # P2-6：Makefile 的 rpath 是构建机 SDK 目录，且与 framework 的 install
    # name（@rpath/Frameworks/...）拼起来会多一层 Frameworks，用户机器上不可
    # 能解析。只从嵌入副本删掉这类相对 rpath（@/绝对路径保留），源 bundle 与
    # Makefile 不动；Capture One 宿主自己的 rpath 仍负责解析。
    while IFS= read -r plugin_rpath; do
      [[ -n "$plugin_rpath" ]] || continue
      case "$plugin_rpath" in
        @*|/*) ;;
        *)
          echo "removing build-machine relative LC_RPATH '$plugin_rpath' from embedded plugin" >&2
          install_name_tool -delete_rpath "$plugin_rpath" "$EMBEDDED_PLUGIN_BINARY"
          ;;
      esac
    done <<< "$PLUGIN_RPATHS"
    EMBEDDED_RPATHS="$(otool -l "$EMBEDDED_PLUGIN_BINARY" 2>/dev/null | awk '$1=="path"{print $2}' || true)"
    while IFS= read -r plugin_rpath; do
      [[ -n "$plugin_rpath" ]] || continue
      case "$plugin_rpath" in
        @*|/*) ;;
        *) echo "embedded GatherLink.coplugin still has a relative LC_RPATH: $plugin_rpath" >&2 ; exit 1 ;;
      esac
    done <<< "$EMBEDDED_RPATHS"
    # P2-7：插件版本跟随 app 的最终 Info.plist（含本地 3.0.0 回退），只改产物
    # 副本；源 GatherLink/Info.plist 的 1.0.0 仍是独立插件包的回退值。
    EMBEDDED_PLUGIN_INFO="$EMBEDDED_PLUGIN/Contents/Info.plist"
    [[ -f "$EMBEDDED_PLUGIN_INFO" ]] || fail "embedded GatherLink.coplugin has no Info.plist: $EMBEDDED_PLUGIN_INFO"
    APP_PLIST_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$BUNDLE_INFO")"
    APP_PLIST_BUILD="$(plutil -extract CFBundleVersion raw -o - "$BUNDLE_INFO")"
    plutil -replace CFBundleShortVersionString -string "$APP_PLIST_SHORT" "$EMBEDDED_PLUGIN_INFO"
    plutil -replace CFBundleVersion -string "$APP_PLIST_BUILD" "$EMBEDDED_PLUGIN_INFO"
    INJECTED_PLUGIN_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "$EMBEDDED_PLUGIN_INFO")"
    INJECTED_PLUGIN_BUILD="$(plutil -extract CFBundleVersion raw -o - "$EMBEDDED_PLUGIN_INFO")"
    if [[ "$INJECTED_PLUGIN_SHORT" != "$APP_PLIST_SHORT" || "$INJECTED_PLUGIN_BUILD" != "$APP_PLIST_BUILD" ]]; then
      fail "plugin version injection failed: expected $APP_PLIST_SHORT ($APP_PLIST_BUILD), got $INJECTED_PLUGIN_SHORT ($INJECTED_PLUGIN_BUILD)"
    fi
    echo "injected plugin CFBundleShortVersionString=$INJECTED_PLUGIN_SHORT CFBundleVersion=$INJECTED_PLUGIN_BUILD"
    # install_name_tool 在 universal 二进制上可能把 linker 的 ad-hoc 签名改坏；
    # 没有 Developer ID 时这里补回 ad-hoc，保证 arm64 本地加载不被签名校验拒绝。
    # 有 CODESIGN_IDENTITY 时由后面的嵌套签名统一覆盖。
    [[ -n "${CODESIGN_IDENTITY:-}" ]] || codesign --force --sign - "$EMBEDDED_PLUGIN_BINARY"
  else
    rm -rf "$PLUGIN_SLICES_DIR"
    echo "warning: GatherLink.coplugin was not built (all slices failed)" >&2
    [[ "$RELEASE_MODE" != "1" ]] || fail "release mode requires a GatherLink.coplugin; refusing to ship without it"
  fi
else
  # 发布模式缺 SDK 已在发布门 exit 1（路径变量见文件头），这里只剩本地跳过。
  echo "warning: Capture One plugin SDK or Makefile not found; skipping GatherLink.coplugin" >&2
fi

# Wave3 收尾 / task-25：Shortcuts 发现性所需的 App Intents 编译期元数据。
# SwiftPM 不会执行 Xcode 的 ExtractAppIntentsMetadata，所以这里在 app 组装完成、
# 签名之前补一步（产物 Contents/Resources/Metadata.appintents，不参与运行时逻辑）。
# 实现细节与失败诊断在 scripts/build-appintents-metadata.sh；本脚本只负责接线。
if [[ "${GATHER_SKIP_APPINTENTS_METADATA:-0}" == "1" ]]; then
  if [[ "$RELEASE_MODE" == "1" ]]; then
    fail "release mode requires App Intents metadata (unset GATHER_SKIP_APPINTENTS_METADATA)"
  fi
  echo "warning: GATHER_SKIP_APPINTENTS_METADATA=1; Shortcuts will not discover Gather actions" >&2
else
  APPINTENTS_METADATA_SCRIPT="$ROOT_DIR/scripts/build-appintents-metadata.sh"
  [[ -x "$APPINTENTS_METADATA_SCRIPT" ]] || fail "error: App Intents metadata helper is missing or not executable: $APPINTENTS_METADATA_SCRIPT"
  APPINTENTS_ARCH="${EXPECTED_ARCHS[0]:-$(uname -m)}"
  APPINTENTS_METADATA_FLAGS=()
  if [[ "$RELEASE_MODE" == "1" ]]; then
    APPINTENTS_METADATA_FLAGS=(--strict)
  fi
  "$APPINTENTS_METADATA_SCRIPT" \
      --app-bundle "$APP_BUNDLE" \
      --bin-path "$BIN_DIR" \
      --target-triple "$APPINTENTS_ARCH-apple-macos26.0" \
      ${APPINTENTS_METADATA_FLAGS[@]+"${APPINTENTS_METADATA_FLAGS[@]}"} \
      || fail "error: App Intents metadata assembly failed; refusing to ship a bundle without Shortcuts metadata"
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
# P2-3：dirty 标记（git 状态读取失败时写 unknown，不伪造成 false）。
if GIT_STATUS="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)"; then
  if [[ -n "$GIT_STATUS" ]]; then
    BUILD_DIRTY_JSON=true
  else
    BUILD_DIRTY_JSON=false
  fi
else
  BUILD_DIRTY_JSON='"unknown"'
fi
# P2-3：sdk/minos 取 Mach-O 的 LC_BUILD_VERSION 实际值，而不是环境变量。
# vtool 不可用时回退到声明值并保留来源区分（sdk_version_declared）。
PRIMARY_ARCH="${FINAL_ARCHS%% *}"
MACHO_MINOS=""
MACHO_SDK=""
if command -v vtool >/dev/null 2>&1; then
  MACHO_MINOS="$(vtool -arch "$PRIMARY_ARCH" -show-build "$APP_BINARY" 2>/dev/null | awk '$1=="minos"{print $2; exit}' || true)"
  MACHO_SDK="$(vtool -arch "$PRIMARY_ARCH" -show-build "$APP_BINARY" 2>/dev/null | awk '$1=="sdk"{print $2; exit}' || true)"
fi
ACTUAL_SDK_VERSION="${MACHO_SDK:-${DECLARED_SDK_VERSION:-default}}"
SAFE_SDK_VERSION="$(printf '%s' "$ACTUAL_SDK_VERSION" | LC_ALL=C tr -d '\"\\\\')"
SAFE_MINOS="$(printf '%s' "${MACHO_MINOS:-unknown}" | LC_ALL=C tr -d '\"\\\\')"
SAFE_DECLARED_SDK="$(printf '%s' "${DECLARED_SDK_VERSION:-default}" | LC_ALL=C tr -d '\"\\\\')"
SAFE_PLUGIN_INFO="$(printf '%s' "$PLUGIN_INFO" | LC_ALL=C tr -d '\"\\\\')"
if [[ -n "$MACHO_SDK" && -n "$DECLARED_SDK_VERSION" && "$MACHO_SDK" != "$DECLARED_SDK_VERSION" ]]; then
  echo "warning: Mach-O sdk ($MACHO_SDK) does not match GATHER_SDK_VERSION ($DECLARED_SDK_VERSION); manifest cache or linker flags are stale" >&2
fi
if [[ -n "$MACHO_SDK" ]]; then
  SDK_MAJOR="${MACHO_SDK%%.*}"
  if [[ "$SDK_MAJOR" =~ ^[0-9]+$ ]] && (( SDK_MAJOR < 26 )); then
    if [[ "$RELEASE_MODE" == "1" ]]; then
      # 复审 P2：发布模式必须 fail-closed（此前只 warning，会产出无 Liquid Glass 的包）。
      fail "error: release bundle links against SDK $MACHO_SDK (<26): Liquid Glass is disabled. The release runner must provide Xcode 26+."
    else
      echo "note: Mach-O sdk $MACHO_SDK (<26); Liquid Glass disabled (expected on older toolchains)" >&2
    fi
  fi
fi
cat > "$BUILD_INFO" <<JSON
{"version":"$FINAL_INFO_SHORT","build":"$FINAL_INFO_BUILD","commit":"$BUILD_COMMIT","dirty":$BUILD_DIRTY_JSON,"archs":"$FINAL_ARCHS","plugin":"$SAFE_PLUGIN_INFO","minos":"$SAFE_MINOS","sdk_version":"$SAFE_SDK_VERSION","sdk_version_declared":"$SAFE_DECLARED_SDK"}
JSON
plutil -convert xml1 -o /dev/null "$BUILD_INFO" 2>/dev/null || fail "build-info.json is not valid JSON: $BUILD_INFO"

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

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || fail "codesign --verify --deep --strict failed for $APP_BUNDLE"

  # 签名后复核：entitlement 必须真的进入代码签名，而不只是仓库里有文件。
  SIGNED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/gather-signed-entitlements.XXXXXX")"
  trap 'rm -f "${SIGNED_ENTITLEMENTS:-}"' EXIT
  codesign -d --entitlements :- "$APP_BUNDLE" >"$SIGNED_ENTITLEMENTS" 2>/dev/null || fail "codesign -d --entitlements failed for $APP_BUNDLE"
  [[ -s "$SIGNED_ENTITLEMENTS" ]] || fail "signed app has no embedded entitlements (expected $ENTITLEMENTS): $APP_BUNDLE"
  SIGNED_APPLE_EVENTS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
  [[ "$SIGNED_APPLE_EVENTS" == "true" ]] || fail "com.apple.security.automation.apple-events is absent from the signed app's entitlements: $APP_BUNDLE"
else
  # 发布模式缺签名身份已在发布门 exit 1，这里只剩本地未签名提示。
  echo "warning: CODESIGN_IDENTITY is unset; app is unsigned (entitlements apply only when signing)" >&2
fi

# WP6c：公证 + staple。凭据来源与可用性判定在发布门已完成（NOTARY_ARGS /
# NOTARY_MISSING）：发布模式缺凭据在构建前 exit 1，这里只剩本地缺凭据的 skip。
NOTARIZED=0
if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -n "$NOTARY_MISSING" ]]; then
    echo "warning: GATHER_NOTARIZE=1 but $NOTARY_MISSING is unavailable; notarization skipped (set it to enable)" >&2
  else
    ZIP_PATH="$OUTPUT_DIR/Gather.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl -a -t exec -vvv "$APP_BUNDLE"
    # 提交公证的 zip 不含 ticket；staple 后必须重打，CI 上传/校验的才是可离线验证的包。
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    NOTARIZED=1
  fi
fi

SIGN_STATE="unsigned"
if [[ "$SIGNED" == "1" ]]; then SIGN_STATE="signed ($CODESIGN_IDENTITY)"; fi
NOTARY_STATE="not notarized"
if [[ "$NOTARIZED" == "1" ]]; then NOTARY_STATE="notarized + stapled ($OUTPUT_DIR/Gather.zip)"; fi
echo "assembled $APP_BUNDLE"
echo "  version:       $FINAL_INFO_SHORT ($FINAL_INFO_BUILD)"
echo "  architectures: ${FINAL_ARCHS}"
echo "  signing:       $SIGN_STATE"
echo "  notarization:  $NOTARY_STATE"
