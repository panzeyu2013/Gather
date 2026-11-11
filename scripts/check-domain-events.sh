#!/usr/bin/env bash
# 领域事件契约门禁（#11）：通道名与发布点必须落在登记表里。
#
# 为什么需要：UI 的跨页刷新靠 4 条进程内通知（job-progress / job-terminal /
# c1-sync-status / domain-changed）。通道名是字符串、载荷是 Any，谁发哪个域
# 全靠约定——新增一个发布点或换一个域字面量，没有任何编译期或 CI 阻力。
#
# 本门禁只钉两件可静态判定的事（第 3 条「写路径必须发域」见文末说明）：
#   R1 通道名闭包：Notification.Name("gather.…") 只允许出现在两个文件；
#   R2 发布点白名单：postDomainChange 只能出现在登记的文件里，且每个文件只能
#      发登记的域（变量形式的变参发布单独登记）。
#
# 用法：./scripts/check-domain-events.sh            # 检查
#       ./scripts/check-domain-events.sh --list     # 打印当前登记表
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UI_DIR="desktop/native/gather-app/Sources/GatherUI"

if [ ! -d "$UI_DIR" ]; then
  echo "check-domain-events: FAIL 缺少扫描根：$UI_DIR" >&2
  exit 1
fi
SWIFT_N=$(find "$UI_DIR" -type f -name '*.swift' | wc -l | tr -d ' ')
if [ "$SWIFT_N" -lt 200 ]; then
  echo "check-domain-events: FAIL 只扫到 ${SWIFT_N} 个 Swift 文件（<200），疑似根路径错误" >&2
  exit 1
fi

python3 - "$UI_DIR" "$@" <<'PY'
import os, re, sys

ui_dir = sys.argv[1]
args = sys.argv[2:]

# R1：通道名只允许在这两个文件里定义。
CHANNEL_FILES = {
    "Support/GatherEventCenter.swift",
    "Support/GatherAppNotification.swift",
}

# R2：发布点白名单（文件 -> 允许的域字面量集合；None = 允许变量）
PUBLISHERS = {
    "Culling/CullingViewModel.swift": {"culling", "metadata"},
    "Gallery/GalleryView+Content.swift": {"culling"},
    "Similarity/SimilarityViewModel+Writeback.swift": {"metadata"},
    "Library/LibraryViewModel+Load.swift": {"library", "metadata"},
    "Persons/PersonsViewModel.swift": {"persons"},
    "Duplicates/DuplicatesViewModel.swift": {"duplicates"},
    # #11 补广播：同步条三个动作（清理/确认/结清）都改 deliveries 行。
    "Metadata/MetadataSyncBar.swift": {"metadata"},
    # #11 补广播：集合/堆栈是库级数据（侧栏计数、图库「加入集合」菜单都读它）。
    "Gallery/GalleryViewModel+Load.swift": {"library"},
    "Curation/CollectionView.swift": {"library"},
    "Curation/CollectionSidebar.swift": {"library"},
    # Wave3 task-24：迁移卡片在 importLibraryPackage / migrateExternalMetadata 成功后发事件。
    "ControlCenter/MigrationCenterCard.swift": {"library", "metadata"},
    # #11 补广播：这些写路径在「R3 补齐」时新增了域广播，按所属域登记。
    "ControlCenter/SessionControlViewModel.swift": {"library"},
    "Culling/IngestSheet.swift": {"library"},
    "Export/ExportViewModel+Delivery.swift": {"culling"},
    "Metadata/MetadataBatchSheet.swift": {"metadata"},
    "Metadata/MetadataEditorSheet.swift": {"metadata"},
    "Metadata/MetadataTemplateSheet.swift": {"metadata"},
    # Wave2 task-13：批量字段编辑的写路径（apply 后发 metadata 域事件）。
    "Metadata/MetadataBatchEditorSheet.swift": {"metadata"},
    "Metadata/KeywordLibrarySheet.swift": {"metadata"},
    # Wave4b task-44：场景标签写回同时刷新 metadata 与 culling 两域。
    "SemanticSearch/SemanticSearchSheetModel.swift": {"metadata", "culling"},
    # 变参：调用方传 domain（簇结构变化/绑定变化两类），只登记 1 个调用点。
    "FaceKeywording/FaceKeywordingViewModel+Review.swift": None,
    # 定义处本身不算发布点
    "Support/GatherEventCenter.swift": None,
}

KEYWORDS = sorted({d for v in PUBLISHERS.values() if v for d in v})

def rel(p):
    return os.path.relpath(p, ui_dir)

if "--list" in args:
    print("通道名文件：")
    for f in sorted(CHANNEL_FILES):
        print("  " + f)
    print("发布点（文件 -> 允许的域）：")
    for f, d in sorted(PUBLISHERS.items()):
        print("  %-58s %s" % (f, "变参" if d is None else sorted(d)))
    sys.exit(0)

fail = 0
channel_files = {}
publisher_sites = {}

for root, _dirs, files in os.walk(ui_dir):
    for name in files:
        if not name.endswith(".swift"):
            continue
        p = os.path.join(root, name)
        text = open(p, encoding="utf-8").read()
        r = rel(p)
        for m in re.finditer(r'Notification\s*\.\s*Name\s*\(\s*"gather\.[a-z0-9.-]+"', text):
            channel_files.setdefault(r, 0)
            channel_files[r] += 1
        for m in re.finditer(r"postDomainChange\(\s*(\.?[A-Za-z_][A-Za-z0-9_]*)?", text):
            arg = (m.group(1) or "").lstrip(".")
            publisher_sites.setdefault(r, []).append(arg or "?")

print("R1 通道名闭包（%d 个文件）：" % len(channel_files))
for f in sorted(channel_files):
    mark = "ok  " if f in CHANNEL_FILES else "FAIL"
    if f not in CHANNEL_FILES:
        fail = 1
    print("  %s %-52s %d 处" % (mark, f, channel_files[f]))

print("R2 发布点白名单（%d 个文件）：" % len(publisher_sites))
for f in sorted(publisher_sites):
    domains = publisher_sites[f]
    if f not in PUBLISHERS:
        print("  FAIL %-52s 未登记（新增发布点必须先登记）" % f)
        fail = 1
        continue
    allowed = PUBLISHERS[f]
    bad = [d for d in domains if d != "?" and allowed is not None and d not in allowed]
    if bad:
        print("  FAIL %-52s 发了未登记的域 %s（允许 %s）" % (f, sorted(set(bad)), sorted(allowed)))
        fail = 1
    else:
        print("  ok   %-52s %s" % (f, sorted(set(domains))))

# 反向：登记了却没有任何发布点，说明登记表腐烂（提醒级，不失败）
for f in sorted(PUBLISHERS):
    if f not in publisher_sites and f != "Support/GatherEventCenter.swift":
        print("  warn %-52s 已登记但未发现发布点" % f)

if not channel_files:
    print("  FAIL 没有扫到任何通道名定义（扫描器失效）")
    fail = 1

if fail:
    print("check-domain-events: FAILED")
    sys.exit(1)
print("check-domain-events: OK（通道名 %d 文件 / 发布点 %d 文件）" % (len(channel_files), len(publisher_sites)))
PY
