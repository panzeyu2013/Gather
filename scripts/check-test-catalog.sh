#!/usr/bin/env bash
# 测试目录门禁（refactor-design-breaking-2026-10-21 §8.6 / §8.3）。
#
# 检查：
#   1. Tests 下每个 *.swift 是否有文件头注释（首个非空行以 // 开头）。
#   2. 统计 skip 站点：@Test/@Suite 的 .enabled(if:) / .disabled(...)、
#      行首 .disabled(...) / .enabled(if:...)、withKnownIssue(...)。
#   3. 每个 skip 站点必须带 owner、到期、原因（连续注释块内），缺失即列 file:line。
#   4. --self-test 用临时目录自测：缺元数据 exit 1，补齐后 exit 0。
#
# 当前以 warning 模式 exit 0；--strict 时存在缺口即 exit 1（CI 使用 --strict）。
# 注意：swift test 汇总行的 "N tests passed" 包含 skip；有效执行数 = 声明数 − skip 数。
# 用法：./scripts/check-test-catalog.sh [--strict] [--self-test]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export LC_ALL=en_US.UTF-8

# 3b-6：按 target 显式列根目录（不再用整个 Tests，避免将来新增的
# 非测试目录被误算）；GatherTestSupport 是 core 测试共享 fixture target，
# 同样需要文件头注释与禁用用例统计。
TEST_ROOTS=(
  "desktop/native/gather-core/Tests/GatherCoreTests"
  "desktop/native/gather-core/Tests/GatherTestSupport"
  "desktop/native/gather-app/Tests/GatherAppTests"
)

# 只允许 --self-test 的子进程覆盖扫描根，避免普通调用被环境变量绕过。
if [ "${CTC_SELF_TEST_CHILD:-0}" = "1" ] && [ -n "${CTC_TEST_ROOTS_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2206
  TEST_ROOTS=(${CTC_TEST_ROOTS_OVERRIDE})
fi

if [ "${CTC_SELF_TEST_CHILD:-0}" != "1" ]; then
  TEST_FILE_N=0
  for root in "${TEST_ROOTS[@]}"; do
    if [ ! -d "$root" ]; then
      echo "check-test-catalog: FAIL 缺少测试根：$root" >&2
      exit 1
    fi
    n=$(find "$root" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
    TEST_FILE_N=$((TEST_FILE_N + n))
  done
  if [ "$TEST_FILE_N" -lt 150 ]; then
    echo "check-test-catalog: FAIL 只扫到 ${TEST_FILE_N} 个测试文件（<150），疑似根路径错误" >&2
    exit 1
  fi
fi

STRICT=0
SELF_TEST=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --self-test) SELF_TEST=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "check-test-catalog: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

# 从 skip 站点向上收集“连续注释块 + 属性续行”，返回缺失的元数据名（逗号分隔）。
skip_metadata_missing() {
  local file="$1"
  local line="$2"
  local ctx j raw trimmed steps has_owner=0 has_due=0 has_reason=0 missing=""

  ctx="$(sed -n "${line}p" "$file")"
  j=$((line - 1))
  steps=0
  while [ "$j" -ge 1 ] && [ "$steps" -lt 20 ]; do
    raw="$(sed -n "${j}p" "$file")"
    trimmed="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$trimmed" ] || break
    case "$trimmed" in
      //*|\**|/\**)
        ctx="${raw}"$'\n'"${ctx}"
        j=$((j - 1))
        steps=$((steps + 1))
        ;;
      @Test*|@Suite*|\#if*|\#elseif*|\#else*|\#endif*|.*|\)*|\"*)
        ctx="${raw}"$'\n'"${ctx}"
        j=$((j - 1))
        steps=$((steps + 1))
        ;;
      *)
        break
        ;;
    esac
  done

  if printf '%s\n' "$ctx" | grep -qiE '(^|[^A-Za-z])owner[[:space:]]*[:：][[:space:]]*[^[:space:]]|负责人[[:space:]]*[:：][[:space:]]*[^[:space:]]'; then
    has_owner=1
  fi
  if printf '%s\n' "$ctx" | grep -qE '到期|截止|skip-until[[:space:]]*[:：]|deadline[[:space:]]*[:：]'; then
    has_due=1
  fi
  if printf '%s\n' "$ctx" | grep -qiE '原因[[:space:]]*[:：]|reason[[:space:]]*[:：]|rationale[[:space:]]*[:：]'; then
    has_reason=1
  fi

  if [ "$has_owner" -eq 0 ]; then missing="owner"; fi
  if [ "$has_due" -eq 0 ]; then missing="${missing:+${missing}、}到期"; fi
  if [ "$has_reason" -eq 0 ]; then missing="${missing:+${missing}、}原因"; fi
  printf '%s' "$missing"
}

# 取 skip 站点附近的测试函数名（多行属性时向下多找几行）。
skip_test_name() {
  local file="$1"
  local line="$2"
  local name
  name="$(sed -n "${line},$((line + 12))p" "$file" | grep -oE 'func [A-Za-z_][A-Za-z0-9_]*' | head -n 1 | sed 's/^func //' || true)"
  if [ -z "$name" ]; then
    name="(suite)"
  fi
  printf '%s' "$name"
}

# 负例自测：临时目录内构造缺元数据 / 补齐元数据的 skip，验证 strict 开关是活的。
run_self_test() {
  local tmp root script out rc
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT
  root="$tmp/root"
  mkdir -p "$root"
  script="$ROOT/scripts/check-test-catalog.sh"

  cat > "$root/BadTest.swift" <<'SWIFT'
// self-test fixture
import Testing
struct BadTest {
    // 到期：2026-12-31
    // 原因：self-test
    @Test(.enabled(if: false))
    func skipped() {}
}
SWIFT

  cat > "$root/BadSuite.swift" <<'SWIFT'
// self-test fixture
import Testing
@Suite(.disabled("self-test"))
struct BadSuite {
    @Test func skipped() {}
}
SWIFT

  cat > "$root/BadDisabled.swift" <<'SWIFT'
// self-test fixture
import Testing
struct BadDisabled {
    @Test(.disabled("self-test"))
    func skipped() {}
}
SWIFT

  set +e
  out="$(CTC_SELF_TEST_CHILD=1 CTC_TEST_ROOTS_OVERRIDE="$root" "$script" --strict 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "check-test-catalog: SELFTEST FAILED — 缺元数据 skip 应 exit 1，实际 $rc" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  case "$out" in
    *"BadTest.swift:6"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 未列出 BadTest.swift:6" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac
  case "$out" in
    *"BadSuite.swift:3"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 未列出 BadSuite.swift:3" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac
  case "$out" in
    *"BadDisabled.swift:4"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 未列出 BadDisabled.swift:4" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac

  rm -f "$root/BadTest.swift" "$root/BadSuite.swift" "$root/BadDisabled.swift"
  cat > "$root/GoodSkip.swift" <<'SWIFT'
// self-test fixture
import Testing
// skip-owner: self-test
// 到期：2026-12-31
// 原因：self-test fixture
@Suite(.disabled("self-test"))
struct GoodSkip {
    // skip-owner: self-test
    // 到期：2026-12-31
    // 原因：self-test fixture
    @Test(.enabled(if: false))
    func skipped() {}
}
SWIFT

  set +e
  out="$(CTC_SELF_TEST_CHILD=1 CTC_TEST_ROOTS_OVERRIDE="$root" "$script" --strict 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "check-test-catalog: SELFTEST FAILED — 补齐元数据后应 exit 0，实际 $rc" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  case "$out" in
    *"skip 元数据缺失     0"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 补齐后仍报缺失" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac

  echo "check-test-catalog: SELFTEST OK（缺元数据 exit 1；补齐 exit 0）"
}

if [ "$SELF_TEST" -eq 1 ]; then
  run_self_test
  exit $?
fi

total=0
header_missing=0
missing_list=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  total=$((total + 1))
  first=$(awk 'NF { print; exit }' "$f")
  case "$first" in
    //*) ;;
    *)
      header_missing=$((header_missing + 1))
      missing_list="${missing_list}${f}"$'\n'
      ;;
  esac
done < <(find "${TEST_ROOTS[@]}" -type f -name '*.swift' -not -path '*/.build/*' 2>/dev/null | sort)

# 同时覆盖：单行 @Test/@Suite trait、行首续行 trait、withKnownIssue 调用。
raw_hits="$(
  {
    grep -rnE '@(Test|Suite).*\.(disabled|enabled)[[:space:]]*\(' "${TEST_ROOTS[@]}" --include='*.swift' 2>/dev/null || true
    grep -rnE '^[[:space:]]*\.(disabled|enabled)[[:space:]]*\(' "${TEST_ROOTS[@]}" --include='*.swift' 2>/dev/null || true
    grep -rnE 'withKnownIssue[[:space:]]*\(' "${TEST_ROOTS[@]}" --include='*.swift' 2>/dev/null || true
  } | awk -F: '!seen[$1":"$2]++'
)"

skip_total=0
enabled_n=0
disabled_n=0
known_n=0
suite_n=0
skip_missing_n=0
skip_missing_list=""

if [ -n "$raw_hits" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"
    trimmed="$(printf '%s' "$text" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # 跳过注释行（含 /// 文档注释与块注释 * 行），与旧脚本的 known_hits 过滤一致。
    case "$trimmed" in
      //*|\**|/\**) continue ;;
    esac

    skip_total=$((skip_total + 1))
    case "$text" in
      *withKnownIssue*) known_n=$((known_n + 1)) ;;
      *".enabled"*) enabled_n=$((enabled_n + 1)) ;;
      *".disabled"*) disabled_n=$((disabled_n + 1)) ;;
    esac
    case "$text" in
      *"@Suite"*) suite_n=$((suite_n + 1)) ;;
    esac

    missing="$(skip_metadata_missing "$file" "$line")"
    [ -n "$missing" ] || continue

    tname="$(skip_test_name "$file" "$line")"
    skip_missing_n=$((skip_missing_n + 1))
    skip_missing_list="${skip_missing_list}  - ${file}:${line}  test=${tname}（缺 ${missing}）"$'\n'
  done <<< "$raw_hits"
fi

# 到期校验（复审 P2）：skip 的「到期：YYYY-MM-DD」过期即失败，避免静默续期。
TODAY="${CTC_TODAY:-$(date +%Y-%m-%d)}"
skip_expired_n=0
skip_expired_list=""
if [ -n "$raw_hits" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="$(printf '%s' "$hit" | cut -d: -f1)"
    line="$(printf '%s' "$hit" | cut -d: -f2)"
    due_line="$(sed -n "$((line - 12)),$((line))p" "$file" 2>/dev/null | grep -E '到期|截止|skip-until' | tail -1 || true)"
    due="$(printf '%s' "$due_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1 || true)"
    [ -n "$due" ] || continue
    if [[ "$due" < "$TODAY" ]]; then
      skip_expired_n=$((skip_expired_n + 1))
      skip_expired_list="${skip_expired_list}  - ${file}:${line} 到期=${due}"$'\n'
    fi
  done <<< "$raw_hits"
fi

echo "check-test-catalog:"
echo "  测试文件            $total"
echo "  缺文件头注释        $header_missing"
echo "  skip 站点           ${skip_total}（.enabled ${enabled_n} / .disabled ${disabled_n} / withKnownIssue ${known_n}）"
echo "  其中 @Suite skip    $suite_n"
echo "  skip 元数据缺失     $skip_missing_n"
echo "  skip 已过到期日     ${skip_expired_n}（今天 ${TODAY}）"
echo "  口径                有效执行 = 声明数 − skip 用例数；@Suite skip 需按套件内 @Test 展开"

if [ "$header_missing" -gt 0 ]; then
  echo "WARN 以下测试文件首个非空行不是 // 注释："
  printf '%s' "$missing_list" | sed '/^$/d; s/^/  - /'
fi

if [ "$skip_missing_n" -gt 0 ]; then
  echo "WARN 以下 skip 站点缺少 owner/到期/原因（连续注释块内）："
  printf '%s' "$skip_missing_list"
fi

if [ "$skip_expired_n" -gt 0 ]; then
  echo "WARN 以下 skip 站点已过到期日，必须删除 gate 或重新评估（不能只续期）："
  printf '%s' "$skip_expired_list"
fi

# 6) 用例/套件 ratchet：删一条 @Test 或 @Suite 不会让任何用例变红，是历史空白。
#    下限按实测值钉死；新增用例只会让数字变大，删用例必须显式改这里并在台账记账
#    （与 cleanup/protocol ratchet 同一套"只许收紧"的约定）。
#    2026-10-28 两轮合并 + 三轮评审后累计收紧：2115/225 → 2195/241（feat 合入 +73/+15；
#    契约测试与回归 +7/+1）。见 docs/reviews/{feat-merge,sidecar-merge,final-review}-2026-10-2*.md。
#    2026-10-29 tests 合入：+10/+1（ModelReviewRepo 5 / ModelReviewService 编排 5，
#    覆盖此前 0%/10.6% 的模型初审落库与缓存路径）→ 2205/242。
#    2026-10-30 interaction 合并 + 评审补测：+9/+1（commit 串行化/refresh 代/keep/
#    invalidateAll/rowIndex/Toast/布局缓存）→ 2264/249；同时修正 @Suite 计数正则
#    （此前漏掉裸 @Suite 与 @MainActor @Suite，少计 4 个）。
#    2026-10-30 p1-next 合并：+174/+24（11 个 core 测试文件 + 2 个 app 测试文件；
#    CollectionRepo/SavedSearch/KeywordFacet/KeywordPath/MetadataDeliveryLifecycle/
#    MetadataRetention/PreviewAnalysis/ProofFeedback/SemanticIndex/TriageCalibration/
#    ContactSheetPresentation + EmbeddedRewriteSession/XMPPacketReader）→ 2438/273。
#    2026-10-30 全量修复波：+21/+3（SchemaCurrent 的 CHECK/CASCADE 用例、策展可见性
#    2 例、保留期会话作用域 1 例、内嵌 XMP 读 4 例、堆栈折叠 10 例 + 1 个新套件）→ 2459/276。
#    2026-10-30 残余波：+21/+3（schema 触发器/CASCADE 2 例、保留期下推 3 例、校样字段级
#    重放 2 例、C1 往返 9 例 + 2 个新套件、保存查询搜索串 5 例 + 1 个新套件）→ 2480/279。
#    2026-10-31 V1 预演：+1（多个 0x0404 IIM 写回必须显式失败，不得只改首段）→ 2481/279。
#    2026-10-31 universal 修复：+1（Float16 手写编解码逐位一致）→ 2482/279。
#    2026-10-31 C1 检测：+1/+1（C1 16 版本化 bundle id + 标准路径兜底）→ 2483/280。
#    2026-10-31 死代码清理：-1（删除 ImageDimensions 旧纯 Swift 实现的唯一对账用例；
#    生产已由 ImageIODimensionsProvider 承接，该实现零生产引用）→ 2482/280。
#    2026-10-31 按钮语义化：+2/+1（ButtonStylePolicy 门禁 + errorFill 高对比断言）→ 2484/281；
#    2026-10-31 自动命名测试：+8/+1（SessionNameAutoFill 状态机）→ 2492/282。
#    2026-10-31 合并后审核补测：门禁加正/负样本与遮罩用例（+2）、自动命名补初始目录/
#    同目录/空名/空白名（+4）→ 2498/282。
#    2026-10-31 残留收口：errorFill 补 1.4.11 边界用例（+1）→ 2499/282；同一改动把
#    计数从「grep 原文」改成「先剥注释再数」，@Test/@Suite 无变化，断言 -2（注释里的
#    #expect( 不再计入，AsyncWait.swift 的说明性注释原本虚增 2 条）。
#    2026-10-31 渲染采样：新增 ButtonRenderTests（3 例 + 1 个套件，把「按钮真的用了
#    哪个 token」从文档承诺变成像素证据）→ 2502/283。
BASELINE_TEST_DECL=2502
BASELINE_SUITE_DECL=283
# 计数前先剥注释：注释里的 `#expect(` / `@Test` 不是真声明（例如 AsyncWait.swift 的
# 说明性注释），旧实现直接 grep 源码文本，ratchet 数字系统性偏高。词法遮罩保留字符串
# 原样，否则 "https://…" 里的 // 会被当成行注释截断本行、连带漏数后面的断言。
# 扫描根固定为两个包的 Tests（不受 --self-test 的 CTC_TEST_ROOTS_OVERRIDE 影响，
# 否则自测子进程里 ratchet 会拿临时夹具的数字去比全仓基线）。
read -r test_decl suite_decl assert_n < <(python3 - <<'PY'
import re
from pathlib import Path

DIRS = [Path('desktop/native/gather-core/Tests'), Path('desktop/native/gather-app/Tests')]


def mask_comments(text):
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == '"':
            # 三引号多行字符串 / 普通字符串（含转义）：原样跳过，内容保留。
            if text.startswith('"""', i):
                j = text.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == '"' or text[j] == '\n':
                    j += 1
                    break
                j += 1
            i = j
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            if j < 0:
                j = n
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        if text.startswith('/*', i):
            depth = 0
            j = i
            while j < n:
                if text.startswith('/*', j):
                    depth += 1
                    j += 2
                    continue
                if text.startswith('*/', j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                    continue
                j += 1
            for k in range(i, min(j, n)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


chunks = []
for base in DIRS:
    for path in sorted(base.rglob('*.swift')):
        chunks.append(mask_comments(path.read_text(encoding='utf-8', errors='replace')))
blob = '\n'.join(chunks)
print(
    len(re.findall(r'^[ \t]*@Test([ \t]|\()', blob, re.M)),
    len(re.findall(r'^[ \t]*(?:@[A-Za-z_]+[ \t]+)*@Suite([ \t(]|$)', blob, re.M)),
    len(re.findall(r'#(?:expect|require)\(', blob)),
)
PY
)
if [ -z "${test_decl:-}" ] || [ -z "${suite_decl:-}" ] || [ -z "${assert_n:-}" ]; then
  echo "check-test-catalog: FAIL 计数脚本没有输出（python3 可用？）" >&2
  exit 1
fi
ratchet_bad=0
if [ "${test_decl:-0}" -lt "$BASELINE_TEST_DECL" ]; then
  echo "FAIL @Test 声明数回落：${test_decl} < baseline ${BASELINE_TEST_DECL}（删用例必须显式下调 baseline 并记账）" >&2
  ratchet_bad=1
fi
if [ "${suite_decl:-0}" -lt "$BASELINE_SUITE_DECL" ]; then
  echo "FAIL @Suite 声明数回落：${suite_decl} < baseline ${BASELINE_SUITE_DECL}" >&2
  ratchet_bad=1
fi
echo "  用例/套件 ratchet  @Test ${test_decl}/$BASELINE_TEST_DECL · @Suite ${suite_decl}/$BASELINE_SUITE_DECL"

# 7) 断言 ratchet：只数声明拦不住"删真用例、补空壳用例"。断言数（#expect / #require）
#    才是"检查了多少事"的代理指标——把真用例删掉换成空函数，断言数会掉。
#    2026-10-29 tests 合入 +40（同上 10 例）。
#    2026-10-30 interaction 合并 + 评审补测：+265（含 @Suite 计数修正后的 4 个套件、
#    commit 串行化/refresh 代/keep/invalidateAll/rowIndex/Toast/布局缓存回归）。
#    2026-10-30 p1-next 合并：+771（同上 13 个测试文件）。
#    2026-10-30 全量修复波：+62（同上新增用例）。
#    2026-10-30 残余波：+107（同上新增用例）。
#    2026-10-31 V1 预演：+5（同上 1 例）。
#    2026-10-31 universal 修复：+2（同上 1 例）。
#    2026-10-31 C1 检测：+3（同上 1 例）。
#    2026-10-31 死代码清理：-3（同上删除的对账用例内 3 条断言）。
#    2026-10-31 按钮语义化：+4（门禁 3 断言 + errorFill 高对比 1 断言）→ 11460。
#    2026-10-31 自动命名测试：+14（8 用例断言）→ 11474（相对 11459 净 +15：+18−3 死代码）。
#    2026-10-31 合并后审核补测：+24（门禁正/负样本、遮罩回归、自动命名 4 例）→ 11498。
#    2026-10-31 残留收口：errorFill 边界断言 +2（源码 11,500）− 注释内 2 条（剥注释后不计数）
#    → 11498，与上一轮持平；基线仍按剥注释口径钉死。
#    2026-10-31 渲染采样：+11（3 例的像素断言）→ 11509。
BASELINE_ASSERT=11509
if [ "$assert_n" -lt "$BASELINE_ASSERT" ]; then
  echo "FAIL 断言数回落：$assert_n < baseline $BASELINE_ASSERT（删断言/换空壳用例必须显式下调并记账）" >&2
  ratchet_bad=1
fi
echo "  断言 ratchet        #expect+#require $assert_n/$BASELINE_ASSERT"

echo "----"
if [ "$STRICT" -eq 1 ]; then
  if [ "$header_missing" -gt 0 ] || [ "$skip_missing_n" -gt 0 ] || [ "$skip_expired_n" -gt 0 ] \
     || [ "$ratchet_bad" -ne 0 ]; then
    echo "check-test-catalog: FAILED (--strict)" >&2
    exit 1
  fi
  echo "check-test-catalog: OK (--strict)"
else
  echo "check-test-catalog: PASS (warning mode; 使用 --strict 作为硬门禁)"
fi
