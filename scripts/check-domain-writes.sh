#!/usr/bin/env bash
# 写路径必发域门禁（#11 R3）：以「叶子写函数」为单位，要求"写了就发域"。
#
# 为什么需要（R2 的盲区）：check-domain-events.sh 的 R2 只匹配 postDomainChange( 字面量，
# 而 6 个文件通过 postCullingChange/postMetadataChange/publishChange 等 helper 间接发布；
# 新增一个 helper 调用点就能完全绕过门禁。本门禁按函数体判定，helper 也算「发域」。
#
# 判定单元 = 叶子写函数：函数体内**直接**调用某个协议写方法。写方法索引来自两处：
#   ① GatherProtocol/API/** 里签名含 Confirmed< 的方法（自动，权威）；
#   ② NONCONF 显式登记表（(协议, 方法) 二元组——必须按协议匹配，
#      因为 resolve/set/update/merge/split 在 LocalizedText/DescriptiveMetadata 等处撞名）。
#
# 通过条件（任一）：函数体含 postDomainChange( / 调用已登记 helper / 声明前一行的
#   `// DOMAIN-EVENT: none — <非空理由>`。理由必须非空，且不许文件级豁免。
#
# 用法：./scripts/check-domain-writes.sh [--list]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UI_DIR="desktop/native/gather-app/Sources/GatherUI"
PROTO_DIR="desktop/native/gather-core/Sources/GatherProtocol/API"

for d in "$UI_DIR" "$PROTO_DIR"; do
  if [ ! -d "$d" ]; then
    echo "check-domain-writes: FAIL 缺少扫描根 $d" >&2
    exit 1
  fi
done
UI_N=$(find "$UI_DIR" -type f -name '*.swift' | wc -l | tr -d ' ')
PROTO_N=$(find "$PROTO_DIR" -type f -name '*.swift' | wc -l | tr -d ' ')
if [ "$UI_N" -lt 200 ] || [ "$PROTO_N" -lt 10 ]; then
  echo "check-domain-writes: FAIL 扫描量异常（UI=$UI_N proto=$PROTO_N），疑似根路径错误" >&2
  exit 1
fi

python3 - "$UI_DIR" "$PROTO_DIR" "$@" <<'PY'
import os, re, sys

ui_dir = sys.argv[1]
proto_dir = sys.argv[2]
listonly = "--list" in sys.argv

# 协议写方法索引：带 Confirmed< 的签名
conf = set()
for dp, _d, fs in os.walk(proto_dir):
    for f in fs:
        if not f.endswith(".swift"): continue
        txt = open(os.path.join(dp, f), encoding="utf-8").read()
        for m in re.finditer(r"func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", txt):
            i, depth = m.end(), 1
            while i < len(txt) and depth:
                depth += {"(": 1, ")": -1}.get(txt[i], 0); i += 1
            if "Confirmed<" in txt[m.end():i]:
                conf.add(m.group(1))
print("Confirmed 写方法:", len(conf))

API_PROPS = {
  "cullingAPI":"CullingAPI","metadataAPI":"MetadataAPI","albumAPI":"AlbumAPI",
  "sessionAPI":"SessionAPI","settingsAPI":"SettingsAPI","personAPI":"PersonAPI",
  "faceAPI":"FaceAPI","similarityAPI":"SimilarityAPI","duplicateAPI":"DuplicateAPI",
  "navigationAPI":"NavigationAPI","jobAPI":"JobAPI","maintenanceAPI":"MaintenanceAPI",
  "exportAPI":"ExportAPI","assetAPI":"AssetAPI","photoAPI":"PhotoAPI","qualityAPI":"QualityAPI",
}
# 非 Confirmed 写方法（本轮只登记“确实要发域”的；其余留给后续收紧）
NONCONF = {
  ("MetadataAPI","applyTriageWriteback"),("MetadataAPI","undoTriageWriteback"),
  ("MetadataAPI","cleanupRetention"),("MetadataAPI","finalizeSync"),
  ("MetadataAPI","applyTemplate"),("MetadataAPI","undoTemplate"),
  ("MetadataAPI","applyDescriptive"),
  ("AlbumAPI","addCollectionItems"),("AlbumAPI","createStack"),
  ("AlbumAPI","removeCollectionItems"),("AlbumAPI","moveCollectionItem"),
  ("SessionAPI","ingest"),("SessionAPI","setSourceRoot"),
}
HELPERS = {"postCullingChange","postMetadataChange","postLibraryChange",
           "publishChange","publishMetadataChange"}
FUNC = re.compile(r"^([ \t]*)(?:(?:@\w+(?:\([^)]*\))?|public|private|internal|fileprivate|static|final|nonisolated|override|mutating)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*[<(]")

findings = []
for dp, _d, fs in os.walk(ui_dir):
    for f in sorted(fs):
        if not f.endswith(".swift"): continue
        p = os.path.join(dp, f); rel = os.path.relpath(p, ui_dir)
        lines = open(p, encoding="utf-8").read().split(chr(10))
        recv = dict(API_PROPS)
        for ln in lines:
            m = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:any\s+)?([A-Za-z_][A-Za-z0-9_]*API)\b", ln)
            if m: recv[m.group(1)] = m.group(2)
        i = 0
        while i < len(lines):
            ln = lines[i]
            m = None if ln.strip().startswith("//") else FUNC.match(ln)
            if not m:
                i += 1; continue
            ind, name = len(m.group(1)), m.group(2)
            j = i + 1
            while j < len(lines):
                s = lines[j]
                if s.strip() == "}" and len(s) - len(s.lstrip()) <= ind:
                    break
                j += 1
            body = chr(10).join(lines[i:j+1])
            writers = set()
            for mm in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(", body):
                proto, meth = recv.get(mm.group(1)), mm.group(2)
                if not proto: continue
                if meth in conf or (proto, meth) in NONCONF:
                    writers.add(mm.group(1) + "." + meth)
            if writers:
                ok = ("postDomainChange(" in body) or any(h + "(" in body for h in HELPERS)
                opt = "DOMAIN-EVENT: none" in body or "DOMAIN-EVENT: none" in (lines[i-1] if i else "")
                findings.append((rel, name, i+1, sorted(writers), ok, opt))
            i = j + 1

gaps = [x for x in findings if not x[4] and not x[5]]
fail = 0

if len(conf) < 35:
    print("  FAIL 只解析到 %d 个 Confirmed 写方法（<35），解析器可能失效" % len(conf)); fail = 1
if len(findings) < 30:
    print("  FAIL 只识别到 %d 个叶子写函数（<30），解析器可能失效" % len(findings)); fail = 1

# R3-a：登记过的发布 helper，其**每个定义体**都必须真的发域（防止有人新增一个
# 同名但只打日志的 helper 冒充“已发域”）。允许各 VM 各自定义（现状如此）。
for dp, _d, fs in os.walk(ui_dir):
    for f in fs:
        if not f.endswith(".swift"):
            continue
        rel = os.path.relpath(os.path.join(dp, f), ui_dir)
        lines2 = open(os.path.join(dp, f), encoding="utf-8").read().split(chr(10))
        for h in sorted(HELPERS):
            idxs = [i for i, l in enumerate(lines2) if ("func " + h + "(") in l]
            for i in idxs:
                window = chr(10).join(lines2[i:i + 30])
                if "postDomainChange(" not in window:
                    print("  FAIL R3-a %s:%d 的 %s 没有真正发域（登记名必须落到 postDomainChange）"
                          % (rel, i + 1, h))
                    fail = 1

print("R3 叶子写函数 %d / 已发域 %d / 显式 none %d / 缺口 %d" % (
    len(findings), sum(1 for x in findings if x[4]),
    sum(1 for x in findings if x[5]), len(gaps)))

if gaps:
    for g in gaps:
        print("  FAIL R3 %-44s %-30s L%-5d %s" % (g[0], g[1], g[2], ",".join(g[3])))
    if not listonly:
        fail = 1

if fail:
    sys.exit(1)
print("check-domain-writes: OK")
