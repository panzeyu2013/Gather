#!/usr/bin/env bash
# 文档一致性门禁（refactor-design-breaking-2026-10-21 §8.6 / CL-16）。
#
# 检查：
#   1. docs/ADR.md 中反引号包裹的仓库路径是否存在（宽松：仅看 */*.{swift,md,json,sh,plist,lproj,py,mm,h}，
#      跳过含空格/花括号/省略号/URL 的伪路径；相对路径依次在仓库根、desktop/native 与两个包源码根下解析）。
#      **显式标注“已删除”的行不参与存在性检查**：ADR-028 的删除清单与 Cut 1 的
#      已删脚本是历史记录，不应被当成文档漂移。
#   2. 当前文档（docs 非 archive + 根 README.md）的 md 相对链接存在性：跳过代码块/行内代码/
#      外链/纯锚点；归档正文是快照，不参与（见 docs/archive/README.md）。
#   3. docs/reviews 下历史 *.md 数量（>20 且未建 docs/archive 时 warning）。
#   4. schema 版本数字：Schema.swift 的版本常量与 ADR 中“当前 schema <n>”声明比较；
#   5. schema 形状数字：SchemaCurrent.expected* 与 README/DEVELOPMENT/docs/README/ADR
#      里的“44 表 / N 列”“user_version=N”声明比较（防止只改版本号假绿）；
#      若没有该声明，回退为全文所有 “schema <n>”（兼容旧写法，但历史 ADR 版本号
#      会造成假阳性）。Migrations.swift 已随 Cut 3 删除，不再作为回退源。
#
# 当前以 warning 模式 exit 0；--strict 时任一缺口 exit 1（Cut 6 归档/修正后启用）。
# 用法：./scripts/check-docs.sh [--strict]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ADR="docs/ADR.md"
SCHEMA_FILE="desktop/native/gather-core/Sources/GatherPersistence/Database/Schema.swift"

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *)
      echo "check-docs: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$ADR" ]; then
  echo "check-docs: FAIL — 缺少 $ADR" >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 已删除对象只保留在历史清单中（ADR-028 / Cut 1 收口），不要求文件仍存在。
grep -v '已删除' "$ADR" | grep -oE '`[^`]+`' | tr -d '`' | sort -u > "$TMP/tokens"

BASES=(
  "."
  "desktop/native"
  "desktop/native/gather-core"
  "desktop/native/gather-app"
  "desktop/native/gather-core/Sources/GatherProtocol"
  "desktop/native/gather-core/Sources/GatherPersistence"
  "desktop/native/gather-core/Sources/GatherAnalysis"
  "desktop/native/gather-core/Sources/GatherApplication"
  "desktop/native/gather-app/Sources/GatherApp"
  "desktop/native/gather-app/Sources/GatherUI"
  "desktop/native/gather-app/Sources/GatherHost"
)

path_total=0
missing=0
missing_list=""

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    *" "*|*"{"*|*"}"*|*"..."*|http*|*"\\"*|*"<"*|*">"*) continue ;;
  esac
  case "$p" in
    */*.swift|*/*.md|*/*.json|*/*.sh|*/*.plist|*/*.lproj|*/*.py|*/*.mm|*/*.h) ;;
    *) continue ;;
  esac
  path_total=$((path_total + 1))
  found=0
  for base in "${BASES[@]}"; do
    if [ -e "$base/$p" ]; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then
    missing=$((missing + 1))
    missing_list="${missing_list}  - $p"$'\n'
  fi
done < "$TMP/tokens"

: > "$TMP/links"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  awk 'BEGIN { fence = 0 }
       /^[[:space:]]*```/ { fence = !fence; next }
       !fence { printf "%d\t%s\n", NR, $0 }' "$f" |
    while IFS=$'\t' read -r ln text; do
      targets=$(printf '%s\n' "$text" | sed 's/`[^`]*`//g' | grep -oE '\]\([^)]*\)' | sed -e 's/^](//' -e 's/)$//' || true)
      [ -n "$targets" ] || continue
      printf '%s\n' "$targets" | while IFS= read -r target; do
        printf '%s\t%s\t%s\n' "$f" "$ln" "$target"
      done
    done
done < <(find docs -type f -name '*.md' -not -path 'docs/archive/*' | sort; printf '%s\n' docs/archive/README.md README.md) >> "$TMP/links"

link_total=0
link_missing=0
link_missing_list=""
while IFS=$'\t' read -r f ln target; do
  [ -n "$target" ] || continue
  case "$target" in
    http*|mailto:*|"#"*|"<"*|*"<"*) continue ;;
  esac
  target=${target%%#*}
  target=${target%% \"*}
  [ -n "$target" ] || continue
  link_total=$((link_total + 1))
  case "$target" in
    /*) resolved="$target" ;;
    *) resolved="$(dirname "$f")/$target" ;;
  esac
  if [ ! -e "$resolved" ]; then
    link_missing=$((link_missing + 1))
    link_missing_list="${link_missing_list}  - ${f}:${ln} -> ${target}"$'\n'
  fi
done < "$TMP/links"

review_count=$(find docs/reviews -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
archive_state="present"
if [ ! -d docs/archive ]; then archive_state="missing"; fi

schema_ver=""
schema_src=""
if [ -f "$SCHEMA_FILE" ]; then
  schema_ver=$(grep -oE '(currentSchemaVersion|CURRENT_SCHEMA_VERSION|schemaVersion)[[:space:]]*=[[:space:]]*[0-9]+' "$SCHEMA_FILE" 2>/dev/null | head -n 1 | grep -oE '[0-9]+' | tail -n 1 || true)
  if [ -n "$schema_ver" ]; then schema_src="$SCHEMA_FILE"; fi
fi
# 比较 ADR 里**所有**版本声明。只取首条会漏掉旧快照段落里遗留的过期断言
# （schema 3→4 时 ADR 后文仍写“当前 schema 为 3”，门禁却判绿）。先把全文压成一行，
# 避免“当前 schema 为\n 3”这种折行漏检。
#
# 两种形态都要扫：
#   1) `当前 schema：N` / `当前 schema 为 N` / `当前 schema 是 N` / `当前 schema N`
#      （只允许分隔符后紧跟数字，避免把“当前 schema 以 `SchemaCurrent`（44 表…）”的 44
#      当版本号）；
#   2) `user_version = N` / `user_version=N`。后者覆盖“当前 schema 以
#      `SchemaCurrent`（44 表 / user_version=4）为准”这类句子——它与“当前 schema”
#      隔着 20 多个字节，前缀窗口会把 44 误当版本号。
adr_flat=$(tr '\n' ' ' < "$ADR" 2>/dev/null | tr -s ' ')
colon_versions=$(printf '%s' "$adr_flat" \
  | grep -oE '当前 schema[[:space:]]*(版本)?[[:space:]]*(为|是|=|：|:)?[[:space:]]*[0-9]+' 2>/dev/null \
  | grep -oE '[0-9]+$' || true)
user_version_versions=$(printf '%s' "$adr_flat" | grep -oE 'user_version[^0-9]{0,4}[0-9]+' 2>/dev/null | grep -oE '[0-9]+$' || true)
doc_versions=$(printf '%s\n%s\n' "$colon_versions" "$user_version_versions" | grep -E '^[0-9]+$' | sort -n | uniq | tr '\n' ' ' || true)
if [ -n "$doc_versions" ]; then
  schema_scope="当前 schema 声明（全部）"
else
  # set -euo pipefail 下 grep 无命中会让整条管道非 0：必须兜住，否则 ADR 缺声明时
  # 脚本直接中止、没有任何摘要（warning 模式也一样）。
  doc_versions=$(grep -oE 'schema[[:space:]]+[0-9]+' "$ADR" 2>/dev/null | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' ' || true)
  schema_scope="全文 schema 数字（未找到“当前 schema”声明）"
fi
schema_mismatch=0
schema_notes=""
if [ -z "$doc_versions" ]; then
  # 一条版本声明都找不到 = 门禁失去比对对象，按失败处理（不能静默判绿）。
  schema_notes="ADR 未找到任何 schema 版本声明; "
  schema_mismatch=1
fi

if [ -z "$schema_ver" ]; then
  schema_notes="无法在 Schema.swift 定位版本常量"
  schema_mismatch=1
else
  for v in $doc_versions; do
    if [ "$v" != "$schema_ver" ]; then
      schema_notes="${schema_notes}ADR schema $v != code $schema_ver; "
      schema_mismatch=1
    fi
  done
  if [ -z "$schema_notes" ]; then schema_notes="一致"; fi
fi

# 5) schema 形状数字：只比版本号会漏掉“384→385 已同步”这类假绿。以
#    SchemaCurrent.expected* 常量为唯一真相源，校验四份现行文档里的
#    “44 表 / N 列”与 user_version 声明；ADR 允许只有版本声明。
SHAPE_FILE="desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaCurrent.swift"
shape_note="未检查（缺 SchemaCurrent.swift）"
shape_mismatch=0
if [ -f "$SHAPE_FILE" ]; then
  code_tables=$(grep -oE 'expectedTableCount: Int = [0-9]+' "$SHAPE_FILE" | grep -oE '[0-9]+$' | tail -n 1 || true)
  code_columns=$(grep -oE 'expectedColumnCount: Int = [0-9]+' "$SHAPE_FILE" | grep -oE '[0-9]+$' | tail -n 1 || true)
  code_indexes=$(grep -oE 'expectedExplicitIndexCount: Int = [0-9]+' "$SHAPE_FILE" | grep -oE '[0-9]+$' | tail -n 1 || true)
  code_fks=$(grep -oE 'expectedForeignKeyCount: Int = [0-9]+' "$SHAPE_FILE" | grep -oE '[0-9]+$' | tail -n 1 || true)
  if [ -z "$code_tables" ] || [ -z "$code_columns" ] || [ -z "$code_indexes" ] || [ -z "$code_fks" ]; then
    shape_note="无法定位 SchemaCurrent.expected* 常量"
    shape_mismatch=1
  else
    shape_note="一致（${code_tables}/${code_columns}/${code_indexes}/${code_fks}）"
    for f in README.md docs/DEVELOPMENT.md docs/README.md "$ADR"; do
      [ -f "$f" ] || continue
      while IFS= read -r claim; do
        [ -n "$claim" ] || continue
        if [ "$claim" != "$code_columns" ]; then
          shape_note="${shape_note}；${f}: ${claim} 列 != code ${code_columns}"
          shape_mismatch=1
        fi
      done <<< "$(grep -oE "${code_tables} 表[[:space:]]*/[[:space:]]*[0-9]+ 列" "$f" | grep -oE '[0-9]+ 列' | grep -oE '^[0-9]+' | sort -u || true)"
      while IFS= read -r claim; do
        [ -n "$claim" ] || continue
        if [ "$claim" != "$schema_ver" ]; then
          shape_note="${shape_note}；${f}: user_version=${claim} != code ${schema_ver}"
          shape_mismatch=1
        fi
      done <<< "$(grep -oE 'user_version[[:space:]]*[=:]?[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+$' | sort -u || true)"
    done
  fi
fi

echo "check-docs:"
echo "  ADR 反引号路径      ${path_total}（缺失 ${missing}）"
echo "  当前文档 md 链接    ${link_total}（缺失 ${link_missing}；docs 非 archive + 根 README）"
echo "  docs/reviews 历史   ${review_count} 篇（docs/archive: ${archive_state}）"
if [ -n "$schema_src" ] && [ "$schema_src" != "$SCHEMA_FILE" ]; then
  echo "  schema 版本         代码 ${schema_ver}（源：${schema_src}；Schema.swift 无版本常量）"
else
  echo "  schema 版本         代码 ${schema_ver}（源：${schema_src}）"
fi
echo "  ADR schema 数字     ${doc_versions}（${schema_scope}）"
echo "  schema 形状         ${shape_note}"

fail=0

if [ "$missing" -gt 0 ]; then
  echo "WARN ADR 中以下反引号路径在仓库内不存在（疑似文档漂移）："
  printf '%s' "$missing_list"
  fail=1
fi

if [ "$link_missing" -gt 0 ]; then
  echo "WARN 当前文档中以下 md 相对链接不存在（archive 快照不检查）："
  printf '%s' "$link_missing_list"
  fail=1
fi

if [ "$review_count" -gt 20 ] && [ "$archive_state" = "missing" ]; then
  echo "WARN docs/reviews 有 $review_count 篇历史文档且 docs/archive 未建立（Cut 6 归档目标）。"
  fail=1
fi

if [ "$schema_mismatch" -ne 0 ]; then
  echo "WARN schema 版本不一致：$schema_notes"
  fail=1
fi

if [ "$shape_mismatch" -ne 0 ]; then
  echo "WARN schema 形状数字与当前文档不一致：$shape_note"
  fail=1
fi

echo "----"
if [ "$STRICT" -eq 1 ]; then
  if [ "$fail" -ne 0 ]; then
    echo "check-docs: FAILED (--strict)" >&2
    exit 1
  fi
  echo "check-docs: OK (--strict)"
else
  if [ "$fail" -ne 0 ]; then
    echo "check-docs: WARN (warning mode; 使用 --strict 作为硬门禁)"
  else
    echo "check-docs: PASS (warning mode; 使用 --strict 作为硬门禁)"
  fi
fi
