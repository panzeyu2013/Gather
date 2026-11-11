#!/usr/bin/env bash
# scripts/sample-similarity-annotation.sh
# Wave3 / task-19：感知级相似/重复标注集的**本地采样脚本**（只读文件系统，不联网）。
#
# 作用：扫描一个照片目录，按"拍摄时间相邻"把照片切成本地候选组，产出标注脚手架
# （JSON 或 CSV）。`class` 由 --class 指定（默认 burst），`groundTruth` 留空等人工填
# merge/separate —— 机器只负责"把候选组摆好"，判断必须由人做（评估物要有 ground truth）。
#
# 用法：
#   scripts/sample-similarity-annotation.sh --root ~/Pictures/wedding-2026-05 \
#       --class burst --max-groups 20 --per-group 6 --gap 2 --format json > /tmp/ann.json
#   scripts/sample-similarity-annotation.sh --root ... --format csv --out /tmp/ann.csv
#
# 四类（--class 取值，与工具/报告一致）：
#   burst                              连拍（同一瞬间的连续帧）
#   same_scene_different_time          同场景不同时刻
#   same_scene_different_people        同场景不同人物
#   different_client_similar_composition  客户不同但构图相似（建议用两次拍摄的目录混采）
#
# 设计约束：
# - 确定性：find 结果排序 + 等距抽样（--stride）→ 同一目录同一参数产出同一份脚手架；
# - 时间来源：优先 EXIF 拍摄时间（mdls kMDItemContentCreationDate，macOS），
#   缺失时退回文件 mtime（stdout 会提示 fallback 计数，采样偏差需人工注意）；
# - 只输出候选组，不改文件名、不复制/移动照片。
set -euo pipefail

ROOT=""
OUT=""
FORMAT="json"
CLASS="burst"
MAX_GROUPS=20
PER_GROUP=6
GAP=2
STRIDE=1
MAX_FILES=5000

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --max-groups) MAX_GROUPS="$2"; shift 2 ;;
    --per-group) PER_GROUP="$2"; shift 2 ;;
    --gap) GAP="$2"; shift 2 ;;
    --stride) STRIDE="$2"; shift 2 ;;
    --max-files) MAX_FILES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "sample-similarity-annotation: 未知参数：$1" >&2; exit 2 ;;
  esac
done

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "sample-similarity-annotation: --root 必须是已存在目录" >&2
  exit 2
fi
case "$FORMAT" in json|csv) ;; *) echo "bad --format: $FORMAT" >&2; exit 2 ;; esac
case "$CLASS" in
  burst|same_scene_different_time|same_scene_different_people|different_client_similar_composition) ;;
  *) echo "bad --class: $CLASS" >&2; exit 2 ;;
esac

TMPDIR_PATH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PATH"' EXIT
LIST="$TMPDIR_PATH/files.txt"
TIMED="$TMPDIR_PATH/timed.tsv"
: > "$TIMED"

# 1) 收集候选照片（RAW/JPEG/HEIC/PSD；排序保证可复现）。
find "$ROOT" -type f \( \
    -iname '*.cr3' -o -iname '*.cr2' -o -iname '*.nef' -o -iname '*.arw' -o \
    -iname '*.raf' -o -iname '*.orf' -o -iname '*.rw2' -o -iname '*.dng' -o \
    -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.heif' -o \
    -iname '*.tif' -o -iname '*.tiff' -o -iname '*.psd' \) \
  | LC_ALL=C sort | head -n "$MAX_FILES" > "$LIST"

FILE_N="$(wc -l < "$LIST" | tr -d ' ')"
if [ "$FILE_N" -eq 0 ]; then
  echo "sample-similarity-annotation: $ROOT 下没有支持的照片" >&2
  exit 1
fi

# 2) 取拍摄时间（epoch 秒）。EXIF 缺失/解析失败 → mtime，并计数提示。
fallback_n=0
while IFS= read -r file; do
  stamp=""
  if command -v mdls >/dev/null 2>&1; then
    raw="$(mdls -raw -name kMDItemContentCreationDate "$file" 2>/dev/null || true)"
    if [ -n "$raw" ] && [ "$raw" != "(null)" ]; then
      # mdls 典型输出：2024-05-01 10:00:00 +0000
      stamp="$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$raw" "+%s" 2>/dev/null || true)"
    fi
  fi
  if [ -z "$stamp" ]; then
    stamp="$(stat -f "%m" "$file" 2>/dev/null || echo 0)"
    fallback_n=$((fallback_n + 1))
  fi
  printf '%s\t%s\n' "$stamp" "$file" >> "$TIMED"
done < "$LIST"

# 3) 按时间 + gap 切组（时间戳相同的视为同组）。
GROUPED="$TMPDIR_PATH/grouped.tsv"
: > "$GROUPED"
group_id=0
prev_stamp=""
while IFS=$'\t' read -r stamp file; do
  if [ -z "$prev_stamp" ] || [ $((stamp - prev_stamp)) -gt "$GAP" ]; then
    group_id=$((group_id + 1))
  fi
  printf '%s\t%s\t%s\n' "$group_id" "$stamp" "$file" >> "$GROUPED"
  prev_stamp="$stamp"
done < <(sort -n -k1,1 "$TIMED")

# 4) 只保留 >=2 张的组，等距抽样到 --max-groups，每组取前 --per-group 张。
GROUPS_FILE="$TMPDIR_PATH/groups.txt"
awk -F'\t' '{ c[$1]++ } END { for (g in c) if (c[g] >= 2) print g }' "$GROUPED" \
  | sort -n | awk -v stride="$STRIDE" 'NR % stride == 0' \
  | head -n "$MAX_GROUPS" > "$GROUPS_FILE"

KEPT_GROUPS="$(wc -l < "$GROUPS_FILE" | tr -d ' ')"
if [ "$KEPT_GROUPS" -eq 0 ]; then
  echo "sample-similarity-annotation: 没有成组的照片（gap=$GAP 太小？）" >&2
  exit 1
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_json() {
  printf '{\n'
  printf '  "version": 1,\n'
  printf '  "generatedBy": "sample-similarity-annotation.sh",\n'
  printf '  "root": "%s",\n' "$(json_escape "$ROOT")"
  printf '  "gapSeconds": %s,\n' "$GAP"
  printf '  "stride": %s,\n' "$STRIDE"
  printf '  "note": "groundTruth 为空：人工填 merge/separate；class 可按组改成四类之一",\n'
  printf '  "groups": [\n'
  first=1
  while IFS= read -r gid; do
    [ "$first" -eq 1 ] && first=0 || printf ',\n'
    printf '    {"id": "g%03d", "class": "%s", "groundTruth": null, "photos": [' "$gid" "$CLASS"
    inner=1
    while IFS=$'\t' read -r _ stamp file; do
      [ "$inner" -eq 1 ] && inner=0 || printf ', '
      printf '"%s"' "$(json_escape "$file")"
    done < <(awk -F'\t' -v g="$gid" '$1 == g' "$GROUPED" | head -n "$PER_GROUP")
    printf ']}'
  done < "$GROUPS_FILE"
  printf '\n  ]\n}\n'
}

emit_csv() {
  printf 'group_id,class,ground_truth,photo_path\n'
  while IFS= read -r gid; do
    while IFS=$'\t' read -r _ stamp file; do
      printf 'g%03d,%s,,%s\n' "$gid" "$CLASS" "$file"
    done < <(awk -F'\t' -v g="$gid" '$1 == g' "$GROUPED" | head -n "$PER_GROUP")
  done < "$GROUPS_FILE"
}

if [ "$FORMAT" = "json" ]; then
  BODY="$(emit_json)"
else
  BODY="$(emit_csv)"
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$BODY" > "$OUT"
  echo "sample-similarity-annotation: $KEPT_GROUPS 组 -> $OUT（扫描 $FILE_N 张，mtime 兜底 $fallback_n 张）" >&2
else
  printf '%s\n' "$BODY"
  echo "sample-similarity-annotation: $KEPT_GROUPS 组（扫描 $FILE_N 张，mtime 兜底 $fallback_n 张）" >&2
fi
