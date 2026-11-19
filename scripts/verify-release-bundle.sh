#!/usr/bin/env bash
# 最终发布包验收（release-audit P1 #2）：Gather.zip 从未解包验证 → 本脚本解包并复核
# 真正要分发的产物，而不是构建目录。分工：desktop/native/build.sh 负责构建期断言
# （签名/公证/双架构/授权 SDK/资产），本脚本负责「最终包」验收；CI release job 的
# Verify release zip step 与本地手工验收跑同一条命令。
#
# >>> usage
#   scripts/verify-release-bundle.sh <path/to/Gather.zip>
#
#   Gather.zip.sha256 必须已存在，生成命令：
#     ( cd release && shasum -a 256 Gather.zip > Gather.zip.sha256 )
#   环境变量（可选；CI 由 Resolve release SDK and version step 注入）：
#     GATHER_VERSION       期望版本；不设时只校验包内自洽
#     GATHER_SDK_VERSION   期望 SDK；不设时要求每切片 Mach-O sdk >= 26
#     GITHUB_SHA           期望提交；设置时 build-info.json 的 commit 必须是其前缀
#   scripts/verify-release-bundle.sh --self-test
#     负样本自测（Linux/macOS 均可，~1s）：mktemp 伪造 Gather.zip 与旁路 sha256，
#     断言缺 zip / 缺 sha / 坏 sha / 损坏 zip / 顶层布局异常 / 缺资产 / 缺 macOS
#     工具等输入全部 fail closed（退出码 1）；不写仓库、不生成可发布产物。
#   退出码：0 = 全部通过（--self-test 表示全部负样本都 fail closed）；
#           1 = 验收/自测失败；2 = 参数/用法错误。
# <<< usage
#
# 检查面（全部 fail closed；macOS 工具缺失也按失败处理，不做降级）：
#   [1] zip 存在且与旁路 sha256 一致
#   [2] 解包到临时目录，zip 顶层只有 Gather.app，必需资产齐全
#   [3] 版本与部署目标（CFBundleShortVersionString / CFBundleVersion / LSMinimumSystemVersion）
#   [4] Gather 双切片 + 每切片 minos/SDK；GatherLink.coplugin 双切片 + minos + 版本跟随 app
#   [5] Metadata.appintents 校验（复用 scripts/check-appintents.sh）
#   [6] build-info.json 语义（version/build/commit/dirty/archs/plugin/minos/sdk）
#   [7] codesign --verify --deep --strict + Developer ID + hardened runtime + 时间戳
#   [8] 已签名 entitlements 含 com.apple.security.automation.apple-events = true
#   [9] 公证验收：stapler validate + spctl 评估
#
# 注：Linux 上无 ditto/lipo/plutil/codesign 等工具，正式验收只能在 macOS 发布机
# 执行；发布链路还要求构建机是预装授权 Capture One Plugin SDK 的 self-hosted
# macOS 26 runner（hosted macos-26 不提供该 SDK，zip 里不会有 GatherLink.coplugin），
# 验收机需 Xcode 26+（SDK >= 26）与 Developer ID / 公证凭据。Linux 可跑的回归入口
# 是 --self-test（见上），只验证 shell 层失败路径，不替代 [3]–[9]。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '/^# >>> usage$/,/^# <<< usage$/p' "$0" | sed -e '1d' -e '$d' -e 's/^# //' -e 's/^#$//'
}

fail() {
  echo "verify-release-bundle: FAIL $*" >&2
  exit 1
}

note() { echo "verify-release-bundle: $*"; }

require_file() { [[ -s "$1" ]] || fail "missing or empty file in release zip: ${1#"$EXTRACT_DIR"/}"; }
require_dir() { [[ -d "$1" ]] || fail "missing directory in release zip: ${1#"$EXTRACT_DIR"/}"; }
require_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required tool not found: $1 (正式验收必须在 macOS 26+ 发布机执行：[4]-[9] 需要 Xcode 26 SDK 的 lipo/plutil/vtool/codesign/xcrun/spctl；Linux 只能跑 --self-test)"
}

# ---- --self-test：Linux 可跑的负样本自测 ----
# release-audit P1：shell 层（[1] sha256、[2] 解包/布局、[3] macOS 工具前置）在任何
# 残缺输入下都必须 fail closed，不能因为「本机解不出/缺工具」就跳过检查。自测只在
# mktemp 目录里伪造 Gather.zip + 旁路 sha256，用脚本自身跑负样本，断言「退出码 1 且
# stderr 命中预期」；不写仓库、不联网、不需要 macOS 工具，Linux/macOS 结果一致。
run_self_test() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "verify-release-bundle: --self-test requires python3 to build fixture zips" >&2
    return 1
  fi
  if ! command -v unzip >/dev/null 2>&1 && ! command -v ditto >/dev/null 2>&1; then
    echo "verify-release-bundle: --self-test requires unzip or ditto to extract fixture zips" >&2
    return 1
  fi
  SELF_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gather-verify-selftest.XXXXXX")"
  trap 'rm -rf "${SELF_TEST_TMP:-}"' EXIT
  local self_path work bin_dir tool
  self_path="$SCRIPT_DIR/$(basename "$0")"
  work="$SELF_TEST_TMP/fixtures"
  bin_dir="$SELF_TEST_TMP/restricted-bin"
  mkdir -p "$work" "$bin_dir"
  SELF_TEST_PASSED=0
  # 用例 8 需要一个「布局完整但本机缺 macOS 工具」的伪造包：把 PATH 收窄到只含
  # shell 层检查用到的命令（不含 lipo/plutil/vtool/codesign/xcrun/spctl/python3）。
  for tool in shasum sha256sum awk find wc tr mktemp rm dirname basename unzip; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$bin_dir/$tool"
    fi
  done

  st_sha() { # $1=zip：按脚本约定写旁路 sha256（验收只读首列校验和）
    local zip="$1" sum
    if command -v shasum >/dev/null 2>&1; then
      sum="$(shasum -a 256 "$zip" | awk '{print $1}')"
    else
      sum="$(sha256sum "$zip" | awk '{print $1}')"
    fi
    printf '%s  %s\n' "$sum" "$(basename "$zip")" > "$zip.sha256"
  }

  st_zip() { # $1=zip 路径；$2...=zip 内条目（内容写固定占位串）
    local zip="$1"
    shift
    python3 - "$zip" "$@" <<'PY_ST_ZIP'
import sys
import zipfile

zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path, "w") as archive:
    for entry in sys.argv[2:]:
        archive.writestr(entry, "fixture")
PY_ST_ZIP
  }

  st_expect_fail() { # $1=用例名 $2=stderr 期望子串；其余=被测命令
    local name="$1" want="$2" rc=0 out_file err_file
    shift 2
    out_file="$SELF_TEST_TMP/stdout.txt"
    err_file="$SELF_TEST_TMP/stderr.txt"
    if "$@" >"$out_file" 2>"$err_file"; then
      rc=0
    else
      rc=$?
    fi
    if [[ "$rc" -ne 1 ]]; then
      echo "verify-release-bundle: self-test FAIL [$name]: expected exit 1, got $rc" >&2
      sed 's/^/  stderr: /' "$err_file" >&2 || true
      return 1
    fi
    if ! grep -Fq -- "$want" "$err_file"; then
      echo "verify-release-bundle: self-test FAIL [$name]: stderr does not contain '$want'" >&2
      sed 's/^/  stderr: /' "$err_file" >&2 || true
      return 1
    fi
    SELF_TEST_PASSED=$((SELF_TEST_PASSED + 1))
    note "[self-test] $name: fail closed OK"
    return 0
  }

  # 1) 缺 zip：路径写错/构建产物缺失必须立即失败，不能继续算 sha。
  st_expect_fail "missing zip" "release zip not found" \
    "$self_path" "$work/absent/Gather.zip"

  # 2) 缺旁路 sha256：没有校验和就不验收（fail closed，不做降级）。
  mkdir -p "$work/no-sha"
  printf 'not a zip archive\n' > "$work/no-sha/Gather.zip"
  st_expect_fail "missing checksum" "missing checksum file" \
    "$self_path" "$work/no-sha/Gather.zip"

  # 3) sha 行格式坏：非 64 位 hex 必须拒绝（防止空/截断校验和静默通过）。
  mkdir -p "$work/bad-sha-format"
  printf 'not a zip archive\n' > "$work/bad-sha-format/Gather.zip"
  printf 'not-a-checksum\n' > "$work/bad-sha-format/Gather.zip.sha256"
  st_expect_fail "malformed checksum" "malformed checksum line" \
    "$self_path" "$work/bad-sha-format/Gather.zip"

  # 4) sha 不匹配：zip 内容被替换必须红。
  mkdir -p "$work/bad-sha"
  printf 'not a zip archive\n' > "$work/bad-sha/Gather.zip"
  printf '%064d  Gather.zip\n' 0 > "$work/bad-sha/Gather.zip.sha256"
  st_expect_fail "sha256 mismatch" "sha256 mismatch" \
    "$self_path" "$work/bad-sha/Gather.zip"

  # 5) 校验和正确但 zip 损坏：解包失败必须红（ditto/unzip 两条路径的错误都含 "failed"）。
  mkdir -p "$work/corrupt-zip"
  printf 'this is not a zip archive\n' > "$work/corrupt-zip/Gather.zip"
  st_sha "$work/corrupt-zip/Gather.zip"
  st_expect_fail "corrupt zip" "failed" \
    "$self_path" "$work/corrupt-zip/Gather.zip"

  # 6) 顶层布局异常（Gather.app 之外还有条目）：解包后必须红。
  mkdir -p "$work/top-level"
  st_zip "$work/top-level/Gather.zip" \
    "Gather.app/Contents/Info.plist" "README.txt"
  st_sha "$work/top-level/Gather.zip"
  st_expect_fail "top-level layout" "top-level entries" \
    "$self_path" "$work/top-level/Gather.zip"

  # 7) 顶层只有 Gather.app 但必需资产缺失：不能以「解包成功」放行。
  mkdir -p "$work/missing-asset"
  st_zip "$work/missing-asset/Gather.zip" "Gather.app/Contents/Resources/AppIcon.icns"
  st_sha "$work/missing-asset/Gather.zip"
  st_expect_fail "missing bundle asset" "missing or empty file in release zip" \
    "$self_path" "$work/missing-asset/Gather.zip"

  # 8) 布局完整但本机缺 macOS 工具（lipo/plutil/...）：[3] 前置必须 fail closed，
  #    不做「缺工具就跳过 [4]–[9]」的降级；PATH 收窄到上面的 restricted-bin。
  mkdir -p "$work/full-layout"
  st_zip "$work/full-layout/Gather.zip" \
    "Gather.app/Contents/MacOS/Gather" \
    "Gather.app/Contents/Info.plist" \
    "Gather.app/Contents/Resources/build-info.json" \
    "Gather.app/Contents/PlugIns/GatherLink.coplugin/Contents/MacOS/GatherLink" \
    "Gather.app/Contents/PlugIns/GatherLink.coplugin/Contents/Info.plist" \
    "Gather.app/Contents/Resources/AppIcon.icns" \
    "Gather.app/Contents/Resources/Metadata.appintents/extract.actionsdata" \
    "Gather.app/Contents/Resources/Metadata.appintents/version.json" \
    "Gather.app/Contents/Resources/en.lproj/Localizable.strings" \
    "Gather.app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
  st_sha "$work/full-layout/Gather.zip"
  st_expect_fail "macOS tools missing" "required tool not found: lipo" \
    env PATH="$bin_dir" "$BASH" "$self_path" "$work/full-layout/Gather.zip"

  note "[self-test] PASS: $SELF_TEST_PASSED negative cases fail closed (fixtures under mktemp, repo untouched)"
  return 0
}

ZIP_PATH=""
SELF_TEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) SELF_TEST=1; shift ;;
    -*) echo "verify-release-bundle: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$ZIP_PATH" ]]; then
        echo "verify-release-bundle: too many arguments (want exactly one Gather.zip)" >&2
        usage >&2
        exit 2
      fi
      ZIP_PATH="$1"
      shift
      ;;
  esac
done
if [[ "$SELF_TEST" == "1" ]]; then
  if [[ -n "$ZIP_PATH" ]]; then
    echo "verify-release-bundle: --self-test takes no bundle argument (got '$ZIP_PATH')" >&2
    usage >&2
    exit 2
  fi
  run_self_test
  exit 0
fi
if [[ -z "$ZIP_PATH" ]]; then
  echo "verify-release-bundle: missing <path/to/Gather.zip>" >&2
  usage >&2
  exit 2
fi

# ---- [1] zip 与 sha256 ----
[[ -f "$ZIP_PATH" ]] || fail "release zip not found: $ZIP_PATH"
[[ -s "$ZIP_PATH" ]] || fail "release zip is empty: $ZIP_PATH"
ZIP_DIR="$(cd "$(dirname "$ZIP_PATH")" && pwd)"
ZIP_BASENAME="$(basename "$ZIP_PATH")"
ZIP_PATH="$ZIP_DIR/$ZIP_BASENAME"
SHA_FILE="$ZIP_PATH.sha256"
if [[ ! -s "$SHA_FILE" ]]; then
  fail "missing checksum file: $SHA_FILE (generate with: cd \"$ZIP_DIR\" && shasum -a 256 \"$ZIP_BASENAME\" > \"$ZIP_BASENAME.sha256\")"
fi
if command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
else
  fail "neither shasum nor sha256sum is available"
fi
EXPECTED_SHA="$(awk 'NR==1{print $1}' "$SHA_FILE")"
[[ ${#EXPECTED_SHA} -eq 64 ]] || fail "malformed checksum line in $SHA_FILE: '$EXPECTED_SHA'"
case "$EXPECTED_SHA" in
  *[!0-9a-f]*) fail "malformed checksum line in $SHA_FILE: '$EXPECTED_SHA'" ;;
esac
[[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || fail "sha256 mismatch: $ZIP_BASENAME=$ACTUAL_SHA != $SHA_FILE=$EXPECTED_SHA"
note "[1] sha256 OK: $ACTUAL_SHA"

# ---- [2] 解包 + 布局 ----
EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gather-release-verify.XXXXXX")"
ENTITLEMENTS_DUMP="$(mktemp "${TMPDIR:-/tmp}/gather-release-entitlements.XXXXXX")"
trap 'rm -rf "${EXTRACT_DIR:-}"; rm -f "${ENTITLEMENTS_DUMP:-}"' EXIT
# ditto 保留 macOS 资源/符号链接（与 notarytool 使用的 zip 语义一致）；unzip 仅用于
# Linux 上验证本脚本的 shell 层失败路径。
if command -v ditto >/dev/null 2>&1; then
  ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR" || fail "ditto -x -k failed: $ZIP_PATH"
elif command -v unzip >/dev/null 2>&1; then
  unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR" || fail "unzip failed: $ZIP_PATH"
else
  fail "need ditto (macOS) or unzip to extract $ZIP_PATH"
fi
TOP_LEVEL_COUNT="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
[[ "$TOP_LEVEL_COUNT" == "1" ]] || fail "zip has $TOP_LEVEL_COUNT top-level entries (expected only Gather.app): $ZIP_PATH"
APP="$EXTRACT_DIR/Gather.app"
[[ -d "$APP" ]] || fail "zip top-level entry is not Gather.app: $ZIP_PATH"
APP_BIN="$APP/Contents/MacOS/Gather"
INFO_PLIST="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"
BUILD_INFO="$RESOURCES/build-info.json"
META_DIR="$RESOURCES/Metadata.appintents"
PLUGIN="$APP/Contents/PlugIns/GatherLink.coplugin"
PLUGIN_BIN="$PLUGIN/Contents/MacOS/GatherLink"
PLUGIN_PLIST="$PLUGIN/Contents/Info.plist"
for required in "$APP_BIN" "$INFO_PLIST" "$BUILD_INFO" "$PLUGIN_BIN" "$PLUGIN_PLIST" "$RESOURCES/AppIcon.icns"; do
  require_file "$required"
done
require_dir "$META_DIR"
require_file "$META_DIR/extract.actionsdata"
require_file "$META_DIR/version.json"
for lang in en zh-Hans; do
  require_file "$RESOURCES/$lang.lproj/Localizable.strings"
done
note "[2] bundle layout OK ($APP)"

# ---- [3] macOS 工具前置：[4]–[9] 无法在 Linux 上执行，缺工具即验收失败 ----
for tool in lipo plutil vtool codesign xcrun spctl python3; do
  require_cmd "$tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "required tool not found: /usr/libexec/PlistBuddy"

plist_raw() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

APP_SHORT="$(plist_raw CFBundleShortVersionString "$INFO_PLIST")"
APP_BUILD="$(plist_raw CFBundleVersion "$INFO_PLIST")"
[[ -n "$APP_SHORT" ]] || fail "Info.plist has no CFBundleShortVersionString: $INFO_PLIST"
[[ -n "$APP_BUILD" ]] || fail "Info.plist has no CFBundleVersion: $INFO_PLIST"
if [[ -n "${GATHER_VERSION:-}" ]]; then
  EXPECTED_VERSION="${GATHER_VERSION#v}"
  EXPECTED_VERSION="${EXPECTED_VERSION#V}"
  [[ "$APP_SHORT" == "$EXPECTED_VERSION" ]] || fail "CFBundleShortVersionString '$APP_SHORT' != GATHER_VERSION '$EXPECTED_VERSION'"
fi
EXPECTED_MINOS="$(plist_raw LSMinimumSystemVersion "$INFO_PLIST")"
[[ -n "$EXPECTED_MINOS" ]] || fail "Info.plist has no LSMinimumSystemVersion: $INFO_PLIST"
APP_ICON="$(plist_raw CFBundleIconFile "$INFO_PLIST")"
[[ "$APP_ICON" == "AppIcon" ]] || fail "CFBundleIconFile '$APP_ICON' != AppIcon: $INFO_PLIST"
note "[3] app version $APP_SHORT ($APP_BUILD), deployment target $EXPECTED_MINOS"

# ---- [4] 双切片 + minos/SDK + 插件版本 ----
check_archs() { # $1=二进制 $2=标签 $3..=必需切片；输出实际 lipo -archs
  local binary="$1" label="$2" archs want
  shift 2
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  [[ -n "$archs" ]] || fail "$label is not a readable Mach-O binary: $binary"
  for want in "$@"; do
    case " $archs " in
      *" $want "*) ;;
      *) fail "$label is missing the $want slice (lipo -archs: $archs): $binary" ;;
    esac
  done
  printf '%s\n' "$archs"
}

macho_field() { # $1=arch $2=二进制 $3=minos|sdk
  vtool -arch "$1" -show-build "$2" 2>/dev/null | awk -v field="$3" '$1 == field {print $2; exit}'
}

APP_ARCHS="$(check_archs "$APP_BIN" "Gather" arm64 x86_64)"
PLUGIN_ARCHS="$(check_archs "$PLUGIN_BIN" "GatherLink.coplugin" arm64 x86_64)"
for arch in arm64 x86_64; do
  APP_MINOS="$(macho_field "$arch" "$APP_BIN" minos)"
  APP_SDK="$(macho_field "$arch" "$APP_BIN" sdk)"
  [[ "$APP_MINOS" == "$EXPECTED_MINOS" ]] || fail "Gather $arch minos '$APP_MINOS' != LSMinimumSystemVersion '$EXPECTED_MINOS'"
  [[ -n "$APP_SDK" ]] || fail "Gather $arch has no LC_BUILD_VERSION sdk"
  APP_SDK_MAJOR="${APP_SDK%%.*}"
  [[ "$APP_SDK_MAJOR" =~ ^[0-9]+$ ]] || fail "cannot parse Gather $arch Mach-O sdk '$APP_SDK'"
  if (( APP_SDK_MAJOR < 26 )); then
    fail "Gather $arch links against SDK $APP_SDK (<26): Liquid Glass is disabled"
  fi
  if [[ -n "${GATHER_SDK_VERSION:-}" && "$APP_SDK" != "$GATHER_SDK_VERSION" ]]; then
    fail "Gather $arch Mach-O sdk '$APP_SDK' != GATHER_SDK_VERSION '$GATHER_SDK_VERSION'"
  fi
  PLUGIN_MINOS="$(macho_field "$arch" "$PLUGIN_BIN" minos)"
  [[ "$PLUGIN_MINOS" == "$EXPECTED_MINOS" ]] || fail "GatherLink.coplugin $arch minos '$PLUGIN_MINOS' != '$EXPECTED_MINOS'"
done
PLUGIN_SHORT="$(plist_raw CFBundleShortVersionString "$PLUGIN_PLIST")"
PLUGIN_BUILD="$(plist_raw CFBundleVersion "$PLUGIN_PLIST")"
[[ "$PLUGIN_SHORT" == "$APP_SHORT" ]] || fail "plugin CFBundleShortVersionString '$PLUGIN_SHORT' != app '$APP_SHORT'"
[[ "$PLUGIN_BUILD" == "$APP_BUILD" ]] || fail "plugin CFBundleVersion '$PLUGIN_BUILD' != app '$APP_BUILD'"
note "[4] architectures OK (app: $APP_ARCHS; plugin: $PLUGIN_ARCHS), plugin version matches app"

# ---- [5] App Intents 元数据（唯一检查实现：check-appintents.sh 的 6 个 intent 断言） ----
[[ -x "$ROOT_DIR/scripts/check-appintents.sh" ]] || fail "check-appintents.sh is missing or not executable: $ROOT_DIR/scripts/check-appintents.sh"
"$ROOT_DIR/scripts/check-appintents.sh" --app "$APP" || fail "App Intents metadata validation failed (Shortcuts discovery would be broken)"
note "[5] Metadata.appintents OK"

# ---- [6] build-info.json 语义：与最终产物交叉一致；release 必须是干净树、双架构、含插件 ----
# python3 只负责 JSON 解析与按固定键序取 9 个字段（解析失败即 fail closed），
# 断言留在 shell 里，失败信息直接指出字段名。
BI_VALUES="$(python3 - "$BUILD_INFO" <<'PY_BUILD_INFO'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as error:  # noqa: BLE001 - 验收脚本必须把损坏详情打出来
    print("build-info.json is not valid JSON: %s" % error, file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("build-info.json must be a JSON object", file=sys.stderr)
    sys.exit(1)
keys = ("version", "build", "commit", "dirty", "archs", "plugin", "minos", "sdk_version", "sdk_version_declared")
missing = [key for key in keys if key not in data]
if missing:
    print("build-info.json is missing keys: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print("\t".join(str(data[key]) for key in keys))
PY_BUILD_INFO
)" || fail "build-info.json is missing or corrupt (see above)"
IFS="$(printf '\t')" read -r BI_VERSION BI_BUILD BI_COMMIT BI_DIRTY BI_ARCHS BI_PLUGIN BI_MINOS BI_SDK BI_SDK_DECLARED <<< "$BI_VALUES"
[[ "$BI_VERSION" == "$APP_SHORT" ]] || fail "build-info version '$BI_VERSION' != CFBundleShortVersionString '$APP_SHORT'"
[[ "$BI_BUILD" == "$APP_BUILD" ]] || fail "build-info build '$BI_BUILD' != CFBundleVersion '$APP_BUILD'"
[[ "$BI_DIRTY" == "False" ]] || fail "build-info dirty='$BI_DIRTY'; release artifacts must be built from a clean tree"
[[ "$BI_MINOS" == "$EXPECTED_MINOS" ]] || fail "build-info minos '$BI_MINOS' != LSMinimumSystemVersion '$EXPECTED_MINOS'"
for want in arm64 x86_64; do
  case " $BI_ARCHS " in *" $want "*) ;; *) fail "build-info archs '$BI_ARCHS' is missing $want" ;; esac
  case " $BI_PLUGIN " in *" $want "*) ;; *) fail "build-info plugin '$BI_PLUGIN' is missing $want (universal release must embed the plugin)" ;; esac
done
[[ -n "$BI_SDK" && -n "$BI_SDK_DECLARED" ]] || fail "build-info sdk_version/sdk_version_declared is empty"
BI_SDK_MAJOR="${BI_SDK%%.*}"
[[ "$BI_SDK_MAJOR" =~ ^[0-9]+$ ]] || fail "cannot parse build-info sdk_version '$BI_SDK'"
if (( BI_SDK_MAJOR < 26 )); then
  fail "build-info sdk_version '$BI_SDK' is not >= 26"
fi
if [[ -n "${GATHER_SDK_VERSION:-}" && "$BI_SDK" != "$GATHER_SDK_VERSION" ]]; then
  fail "build-info sdk_version '$BI_SDK' != GATHER_SDK_VERSION '$GATHER_SDK_VERSION'"
fi
[[ -n "$BI_COMMIT" ]] || fail "build-info commit is empty"
if [[ -n "${GITHUB_SHA:-}" && "$GITHUB_SHA" != "$BI_COMMIT"* ]]; then
  fail "build-info commit '$BI_COMMIT' is not a prefix of GITHUB_SHA '$GITHUB_SHA'"
fi
note "[6] build-info.json OK: version=$BI_VERSION build=$BI_BUILD archs=$BI_ARCHS plugin=$BI_PLUGIN sdk=$BI_SDK"

# ---- [7][8] 代码签名：deep/strict 校验、Developer ID、hardened runtime、时间戳、entitlements ----
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign --verify --deep --strict failed: $APP"
CODESIGN_DV="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
case "$CODESIGN_DV" in
  *'Authority=Developer ID Application'*) ;;
  *) fail "app is not signed with a Developer ID Application identity: $APP" ;;
esac
case "$CODESIGN_DV" in
  *'Runtime Version'*) ;;
  *) fail "app signature lacks hardened runtime (Runtime Version): $APP" ;;
esac
case "$CODESIGN_DV" in
  *'Timestamp'*) ;;
  *) fail "app signature lacks a secure timestamp (Timestamp): $APP" ;;
esac
codesign -d --entitlements :- "$APP" >"$ENTITLEMENTS_DUMP" 2>/dev/null || fail "codesign -d --entitlements failed: $APP"
[[ -s "$ENTITLEMENTS_DUMP" ]] || fail "signed app has no embedded entitlements: $APP"
APPLE_EVENTS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS_DUMP" 2>/dev/null || true)"
[[ "$APPLE_EVENTS" == "true" ]] || fail "signed entitlements must declare com.apple.security.automation.apple-events = true: $APP"
note "[7][8] code signature + entitlements (apple-events=true) OK"

# ---- [9] 公证：staple 后重打的最终 zip 必须能离线通过 Gatekeeper ----
xcrun stapler validate "$APP" || fail "stapler validate failed (not notarized or ticket missing): $APP"
spctl -a -t exec -vvv "$APP" || fail "spctl assessment failed (Gatekeeper rejects the app): $APP"
note "[9] notarization + Gatekeeper OK"

note "ALL CHECKS PASSED: $ZIP_PATH (version $APP_SHORT, build $APP_BUILD)"
