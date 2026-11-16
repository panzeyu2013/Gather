# 标准加固：shellcheck 零告警 + 门禁接入 + Sources as! 清零 + 清理 ratchet 收紧（task-7）

- **日期**：2026-11-17（评审目录名；本文数据采样于 UTC 2026-11-16T16:32:57Z，本地时区 CST/UTC+8 已跨到 11-17）
- **执行**：standards-hardening（子代理，task-7；写作用域：`scripts/`、`desktop/native/gather-core/Sources/GatherAnalysis/Image/ImageMetadataProviders.swift`、`docs/cleanup-baseline.json`、本文档）
- **基线**：git HEAD `e5c54f37` + 当前工作区（其他子代理的未提交改动同时存在；本文不修改其文件，也不回退 lead 的机械修复）
- **验证上限（重要）**：Linux 主机，**无 macOS/Xcode** → 本轮**没有 `swift build` / `swift test`**。Swift 侧只做 `swiftc -parse` 语法检查 + Linux CoreFoundation 同源探针；shellcheck 用仓库内 `.gather/shellcheck`（gitignored）**0.10.0**，CI 版本由 ubuntu-latest 镜像自带（未 pin）。所有结论按此上限陈述。

## 0. 结论摘要

| # | 工作流 | 修复前 | 修复后 | 验证 |
|---|--------|--------|--------|------|
| 1 | shellcheck（0.10.0，`-S warning`） | **5 finding / 4 文件** | **0 finding**：22 个 tracked `*.sh`（含 `desktop/native/build.sh`）+ 2 个未跟踪新脚本 | 前后输出存档 `.gather/orig-check/shellcheck-before.txt` / `-after.txt` |
| 2 | 仓库卫生门禁新增 [f] 节 | 无 shellcheck 检查面 | [f] 节：tracked `*.sh` 全量 shellcheck，severity warning，finding 即 FAIL，缺工具打印安装提示 | `check-repo-hygiene.sh` **六节全 PASS**、exit 0；门禁仍为 15 道 / 1 个脚本（CI 已调用该脚本，无需改 ci.yml） |
| 3 | Sources `as!` 清零 | 1 处（`ImageMetadataProviders.swift:170`） | **0 处**（CFTypeID 判型 + `unsafeDowncast`） | `swiftc -parse` exit 0；ratchet `as_bang = 0` |
| 4 | 清理 ratchet 收紧 | `try_optional 261`，5 个指标 | `try_optional 260` + 新增 4 指标（`try_bang`/`as_bang`/`fatal_error` = 0，`nonisolated_unsafe` = 7） | `--write-baseline` 重生成基线；ratchet **PASS**（9/9 指标不超基线） |

改动规模：7 个 git 跟踪文件（+58/−22 行）+ 1 个未跟踪新脚本（`scripts/check-repo-hygiene.sh` 的 [f] 节）+ 本文档。

## 1. shellcheck 零告警

### 1.1 修复前（before）

本机工具：`/root/projects/Gather/.gather/shellcheck --version` → `version: 0.10.0`（与任务描述的 0.10.0 一致）。

扫描口径：`shellcheck -S warning`（只把 warning 及以上当失败；`info`/`style` 不算，避免莫名其妙的风格噪音），文件清单 = `git ls-files '*.sh'`。

修复前输出（5 findings / 4 文件，均为 warning）：

| 文件:行 | 规则 | 内容 |
|---------|------|------|
| `scripts/check-preview-surface.sh:155` | SC2043 | `for required in PreviewProviders.swift; do` —— 单元素循环 |
| `scripts/check-protocol-surface.sh:75` | SC2046 | `$(cat "$TMP/proto-files")` 未加引号的命令替换（word splitting） |
| `scripts/check-protocol-surface.sh:79` | SC2046 | 同上，第二处 |
| `scripts/check-test-catalog.sh:131` | SC2064 | `trap "rm -rf '$tmp'" EXIT` —— 立即展开而非信号时展开 |
| `scripts/test.sh:31` | SC2206 | `FLAGS=(${SWIFT_TEST_FLAGS:-})` —— 依赖 word splitting 建数组 |

复现方式（HEAD 版本副本，不动工作区）：

```bash
for f in check-preview-surface.sh check-protocol-surface.sh check-test-catalog.sh test.sh; do
  git show "HEAD:scripts/$f" > ".gather/orig-check/head-$f"
done
.gather/shellcheck -S warning .gather/orig-check/head-*.sh   # 5 findings
```

### 1.2 逐项修复（before → after）

**(1) `scripts/check-preview-surface.sh:155` SC2043 —— 单元素循环改直判**

```diff
-    for required in PreviewProviders.swift; do
-      if [ ! -f "$PREVIEW_DIR/$required" ]; then
-        echo "FAIL(strict): 缺少 fixture 文件 $PREVIEW_DIR/$required" >&2
-        fail=1
-      fi
-    done
+    if [ ! -f "$PREVIEW_DIR/PreviewProviders.swift" ]; then
+      echo "FAIL(strict): 缺少 fixture 文件 $PREVIEW_DIR/PreviewProviders.swift" >&2
+      fail=1
+    fi
```

行为完全等价：同一文件、同一 FAIL 文案、同一 `fail=1`；没有循环变量被后续复用（已确认 `required` 只在循环内使用）。

**(2) `scripts/check-protocol-surface.sh:75,79` SC2046 —— 文件清单改 xargs 逐行传入**

```diff
-grep -hE '^public (struct|enum|indirect enum|final class|class|protocol|actor) [A-Za-z_][A-Za-z0-9_]*' \
-  $(cat "$TMP/proto-files") > "$TMP/decls" || true
+# 文件清单用 xargs 逐行传入：未加引号的 $(cat ...) 依赖 word splitting（SC2046），
+# 路径含空白时会拆错。与下方 module-metrics 的逐模块统计同一写法。
+xargs -I{} cat {} < "$TMP/proto-files" \
+  | grep -hE '^public (struct|enum|indirect enum|final class|class|protocol|actor) [A-Za-z_][A-Za-z0-9_]*' \
+  > "$TMP/decls" || true
...
-public_declarations=$(grep -hE '^[[:space:]]*public[[:space:]]' $(cat "$TMP/proto-files") | wc -l | tr -d ' ')
+public_declarations=$(xargs -I{} cat {} < "$TMP/proto-files" \
+  | grep -hE '^[[:space:]]*public[[:space:]]' | wc -l | tr -d ' ')
```

行为等价：`grep -h` 的多文件语义 = 逐文件拼接后过滤（`-h` 去文件名），输出行集合与行数完全一致；`xargs -I{}` 逐行读清单，路径含空格也不会拆错（旧写法的实际缺陷）。`|| true` 保持「无匹配不失败」。该写法与脚本自身 `module-metrics`（:151-152）一致，不引入新依赖。

**(3) `scripts/check-test-catalog.sh:131` SC2064 —— trap 延迟展开脚本级临时目录**

这里**不能**直接按 shellcheck 建议改成单引号：`tmp` 是 `run_self_test()` 的 `local`，EXIT trap 在函数返回后才执行，届时 `$tmp` 已出作用域（`set -u` 下 `rm -rf "$tmp"` 会报 unbound variable，可能掩盖 self-test 的退出码）。已在本机验证该反例（`tmp=[UNSET]`、exit 1）。正确修法是把临时目录提到脚本级再延迟展开：

```diff
 # 负例自测：临时目录内构造缺元数据 / 补齐元数据的 skip，验证 strict 开关是活的。
+# 临时目录放脚本级变量：EXIT trap 在函数返回后才执行，local 变量届时已出作用域，
+# 所以 trap 必须单引号延迟展开脚本级变量。
+SELFTEST_TMP=""
 run_self_test() {
-  local tmp root script out rc
-  tmp="$(mktemp -d)"
-  trap "rm -rf '$tmp'" EXIT
-  root="$tmp/root"
+  local root script out rc
+  SELFTEST_TMP="$(mktemp -d)"
+  trap 'rm -rf "$SELFTEST_TMP"' EXIT
+  root="$SELFTEST_TMP/root"
```

行为等价验证：`--self-test` 新旧版本 stdout/stderr/退出码逐字节一致；运行后 `/tmp` 无新增残留临时目录（mtime 对照）。

**(4) `scripts/test.sh:31` SC2206 —— `read -r -a` 拆 FLAGS**

```diff
-FLAGS=(${SWIFT_TEST_FLAGS:-})
+# SC2206：SWIFT_TEST_FLAGS 是「按空白拆分」的一组 flag（不是单个带空格参数），
+# 原写法 ${SWIFT_TEST_FLAGS:-} 不加引号依赖 word splitting，且会顺带触发 glob 展开；
+# read -a 只做 IFS 拆分、不做 glob，空值时得到空数组（后续 ${FLAGS[@]+...} 兼容 bash 3.2）。
+read -r -a FLAGS <<< "${SWIFT_TEST_FLAGS:-}"
```

行为等价（逐 case 对比旧/新解析出的数组，含空值与未设置）：

| `SWIFT_TEST_FLAGS` | 旧 `FLAGS=(${...})` | 新 `read -r -a FLAGS` | 一致 |
|---|---|---|---|
| 未设置 | 空数组 | 空数组 | ✅ |
| `""` | 空数组 | 空数组 | ✅ |
| `--disable-sandbox` | `[--disable-sandbox]` | `[--disable-sandbox]` | ✅ |
| `--a --b` | `[--a, --b]` | `[--a, --b]` | ✅ |
| `--filter Foo --skip Bar` | 4 个词 | 4 个词 | ✅ |

唯一语义差异：输入含 glob 元字符（如 `--filter *.md`）时旧写法会被 shell 展开成文件名，新写法保持字面量——这是修复（flag 值本就不该被 glob 展开），且真实 `SWIFT_TEST_FLAGS` 不含 glob 字符；下游 `${FLAGS[@]+"${FLAGS[@]}"}`（bash 3.2 空数组兼容写法）原样保留。

### 1.3 修复后（after）

```bash
.gather/shellcheck --version | sed -n '2p'    # version: 0.10.0
.gather/shellcheck -S warning $(git ls-files '*.sh') scripts/check-repo-hygiene.sh scripts/report-baseline.sh
# exit 0（0 finding，共 24 个文件 = 22 tracked *.sh（含 build.sh）+ 2 个未跟踪新脚本）
```

### 1.4 仓库内唯一保留的 scoped disable

全仓现仅 1 处 `shellcheck disable`：`scripts/check-test-catalog.sh:32`（SC2206，自测子进程的测试根清单用空格分隔，**有意**按词拆分）。本次为该 disable 补了一行理由注释（原先是裸 disable）。除此之外没有新增任何 disable——上面 5 个 finding 都是真修复，不是压制。

## 2. 门禁接入：[f] shellcheck 节

### 2.1 设计（`scripts/check-repo-hygiene.sh`，:527-572）

- 文件集：`git ls-files -z -- '*.sh'`（= tracked `*.sh`，天然含 `desktop/native/build.sh`），`git ls-files` 本身按路径排序 → 输出确定；`read -r -d ''` 逐行读，路径含空格安全。
- 规则集固定：`-S warning -f gcc`；调用前 `unset SHELLCHECK_OPTS`，防止本机环境变量（例如 `SHELLCHECK_OPTS="-e SC2043"`）放宽门禁 —— 已验证 `SHELLCHECK_OPTS` 确实能压制 finding，所以这行是必要的确定性守卫。
- 失败条件：shellcheck 退出码非 0（0=无 finding，1=有 finding，2/3=工具或文件问题）→ [f] FAIL，并逐行打印 `file:line:col` 形式的 finding（`-f gcc`）。
- 扫描量下限：tracked `*.sh` < 15 直接 FAIL（与 [a] 同口径，防「静默 0 命中」）。
- 缺工具：`command -v shellcheck` 失败时 [f] FAIL 并打印安装提示（CI ubuntu-latest 预装；本地 `apt-get install shellcheck` / `brew install shellcheck`，或把 gitignored 的 `.gather/shellcheck` 放进 PATH）。其它五节不受影响。

### 2.2 fail-mode 自测（证明门禁是活的，不是恒绿）

1. **注入 finding**：临时往 `scripts/test.sh` 追加一个 SC2034/SC2043 反例 → [f] 输出 `2 条 finding` 与 `scripts/test.sh:101:x` 行号，整脚本 exit 1；随即用备份还原（`cmp` 确认逐字节还原、shellcheck 复检 0 finding）。
2. **缺 shellcheck**：以 `PATH=/usr/bin:/bin` 运行 → [f] 打印安装提示并 FAIL，整脚本 exit 1；[a]-[e] 仍正常执行。

输出摘录：

```
[f] shellcheck（tracked *.sh，severity warning）
    FAIL shellcheck 0.10.0：2 条 finding（退出码 1）
    FAIL scripts/test.sh:101:1: warning: only_once_shfile appears unused. ... [SC2034]
    FAIL scripts/test.sh:101:25: warning: This loop will only ever run once. ... [SC2043]
```

### 2.3 门禁结果与「15 道」口径

`PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh` → **六节全 PASS**、exit 0：

```
[a] 脚本语法 / shebang 执行位 / CRLF      PASS  (bash -n：22 个 .sh，stderr 全空)
[b] .editorconfig 一致性                  PASS  (1218 个文本文件)
[c] Markdown 相对链接                     PASS  (67 个 .md / 165 个链接)
[d] 本地化表安全                          PASS  (en 2680 key / zh-Hans 9 key)
[e] scripts/ 无缓存/构建产物              PASS  (30 个 tracked 文件)
[f] shellcheck（tracked *.sh）            PASS  (0.10.0：22 个 tracked *.sh，0 finding)
----
check-repo-hygiene: OK
```

门禁数不变：CI `.github/workflows/ci.yml` 的 gates job 早已调用 `./scripts/check-repo-hygiene.sh`（本次**未改 ci.yml**），[f] 因此自动进 CI；仓库仍是 **15 道门禁 / 1 个脚本**，没有新增工作流步骤。本地运行注意：本机 PATH 里没有系统 shellcheck，需用 `.gather/shellcheck`（gitignored），command 见上；CI 不需要该前缀。

## 3. Sources `as!` 清零

### 3.1 位置与旧实现

`desktop/native/gather-core/Sources/GatherAnalysis/Image/ImageMetadataProviders.swift` 的 `json(_:)`：ImageIO 把数组型 XMP 属性（`dc:subject` 的 rdf:Bag）的元素返回为 `CGImageMetadataTag`，需要 CFTypeID 判型后递归取值。旧实现：

```swift
let object = value as AnyObject
if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
    return json(CGImageMetadataTagCopyValue(object as! CGImageMetadataTag))
}
```

### 3.2 为什么不能直接 `as?`

Swift 对 CoreFoundation 类型的条件转换有专门诊断（Linux Swift 6.2 同源探针实测，CFString 为例）：

```
error: conditional downcast to CoreFoundation type 'CFString' will always succeed
       did you mean to explicitly compare the CFTypeIDs of 'object' and 'CFString'?
```

仓库 `scripts/check-warnings.sh` 用 `-warnings-as-errors` 构建 Sources，因此 `as?` 不是可选项（旧代码注释也记录了这一点）。同一探针下 `unsafeDowncast(object, to: CFString.self)` 在 `-warnings-as-errors` 下**编译干净**。

### 3.3 新实现

```swift
// CF 运行时判型 + 解包：CGImageMetadataTag 是 CF 类型，条件转换（as?）被
// 编译器判为恒真而报错（"conditional downcast to CoreFoundation type ...
// will always succeed"），-warnings-as-errors 下会直接挡住构建。这里先比对
// CFTypeID，再用 unsafeDowncast：typeID 相等已证明同型（等价 as! 的前提），
// 未知 CF 类型不会进入本分支，仍走下方 description 兜底、不崩。
let object = value as AnyObject
if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
    let tag = unsafeDowncast(object, to: CGImageMetadataTag.self)
    return json(CGImageMetadataTagCopyValue(tag))
}
```

行为保持论证：CFTypeID 相等 → 运行时对象就是 `CGImageMetadataTag`，`unsafeDowncast` 返回同一引用（无拷贝/无桥接转换），随后仍是同一个 `CGImageMetadataTagCopyValue` 调用，JSON 产物逐字段不变；typeID 不等时行为与旧版一致（不进分支，走 `String(describing:)` 兜底，不触发强制解包）。原先 `as!` 只在 typeID 相等时可达，所以对有效输入新旧**不可区分**；此次改动消除了「唯一的强制转换」这个静态风险点，并让 `as_bang` 指标可长期维持 0。`unsafeDowncast` 是 stdlib 对「已由前置条件证明的 downcast」提供的有检查语义原语（debug 断言 + 文档契约），比 `unsafeBitCast` 更表达意图（后者也能编译，但完全无检查）。

### 3.4 验证

- `.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <file>` → exit 0（无输出）。
- `grep -rn 'as!' desktop/native/*/Sources`（排除注释行）→ **0**。
- Linux 同源探针（CFString + `CFGetTypeID` + `unsafeDowncast`）在 `-warnings-as-errors` 下通过（探针文件在 `.gather/cfprobe/`）。
- **不能验证的部分**：没有 macOS SDK，无法 typecheck `CGImageMetadataTag` 的真实导入签名；未跑 `gather-core` 单测（`ImageMetadataProvidersTests.parsesEmbeddedKeywordArrays` 覆盖该 dc:subject 解包路径，属本轮验证缺口，由 macOS CI 的 build+test 兜底）。

## 4. 清理 ratchet 收紧

### 4.1 指标变更（`scripts/check-cleanup-ratchet.sh` + `docs/cleanup-baseline.json`）

| 指标 | 扫描面 | baseline（前） | 当前值 | baseline（后） | 说明 |
|------|--------|---------------|--------|---------------|------|
| `unchecked_sendable` | Sources | 60 | 60 | 60 | 未变 |
| `try_optional` | Sources | 261 | **260** | **260** | 收紧 1（脚本自身在提示「可收紧 baseline」） |
| `try_bang` | Sources | —（新增） | 0 | **0** | 零容忍：新代码不得引入 `try!` |
| `as_bang` | Sources | —（新增） | 0 | **0** | 本任务修复唯一 `as!` 后为 0；零容忍 |
| `fatal_error` | Sources | —（新增） | 0 | **0** | Sources 无 `fatalError`；零容忍（错误走 throws） |
| `nonisolated_unsafe` | Sources | —（新增） | **7** | **7** | 存量 7 处（并发约定禁止新增），按 ratchet 规则取当前值、只降不升 |
| `services_prepare` | gather-core Services | 0 | 0 | 0 | 未变 |
| `todo_fixme` | Sources + Tests | 0 | 0 | 0 | 未变 |
| `with_known_issue` | Tests | 0 | 0 | 0 | 未变 |

`nonisolated_unsafe` 的 7 处存量（均为既有静态可变状态，本轮**不动**，只登记防增长）：
`DB.swift:368`、`ExportService+Run.swift:705`、`PreviewAnalysis.swift:284`、`GatherUI/Export/PrintSupport.swift:16`、`PrintRenderingPort.swift:202`、`ImageDecoderPort.swift:70`、`ViewerOverlays.swift:28`。

### 4.2 实现方式（沿用脚本既有结构）

- `METRICS` 顺序与 `metric()` 的 case、`write_baseline()` 的 metrics/scopes 同步扩展（新指标紧跟 `try_optional`，扫描面同为 `desktop/native/*/Sources/**/*.swift`）；`--help` 的 header 行区间随 header 增行同步调整（`sed -n '2,21p'`）。
- 统计口径不变：`count_matches` 用 ERE 计「非纯注释行」（行首 `//` 或 `*` 不计）；`nonisolated_unsafe` 的正则为 `nonisolated(unsafe)`（字面括号）。
- 新指标对既有脚本行为无副作用：`--write-baseline` 的「防膨胀」检查对 baseline 中不存在的 key 跳过（新增 key 第一次写入不会被 REFUSED），已有 key 仍受「只能等于或小于 baseline」约束。
- 基线由 `./scripts/check-cleanup-ratchet.sh --write-baseline` 重生成：`generated_at` 更新为 `2026-11-16T16:32:57Z`、`generated_by` 仍为该脚本（9 个指标、schema 1），保证 JSON 与脚本同源。

### 4.3 结果

```
metric                  current baseline  status
unchecked_sendable           60       60  ok
try_optional                260      260  ok
try_bang                      0        0  ok
as_bang                       0        0  ok
fatal_error                   0        0  ok
nonisolated_unsafe            7        7  ok
services_prepare              0        0  ok
todo_fixme                    0        0  ok
with_known_issue              0        0  ok
----
check-cleanup-ratchet: OK（全部指标不超过 baseline）
```

## 5. 验证记录（可复现命令与结果）

| # | 命令 | 结果 |
|---|------|------|
| 1 | `for f in $(git ls-files '*.sh'); do bash -n "$f" \|\| ...; done`（stderr 必须为空） | 22 个 tracked `*.sh` 全部 BAD=0、stderr 空 |
| 2 | `.gather/shellcheck -S warning $(git ls-files '*.sh') scripts/check-repo-hygiene.sh scripts/report-baseline.sh` | exit 0（0 finding） |
| 3 | `PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh` | 六节 PASS，exit 0 |
| 4 | `./scripts/check-cleanup-ratchet.sh` | 9/9 ok，exit 0 |
| 5 | `.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex desktop/native/gather-core/Sources/GatherAnalysis/Image/ImageMetadataProviders.swift` | exit 0（无输出） |
| 6 | `python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/ci.yml"))'`（**未编辑** ci.yml，仅校验其仍可解析） | OK，jobs = boundary/gates/gather-core/gather-app/release |
| 7 | `python3 -c 'import json; json.load(open("docs/cleanup-baseline.json"))'` | OK，metrics=9、schema=1 |
| 8 | `./scripts/check-test-catalog.sh --strict`、`--self-test` | exit 0；与改造前（HEAD 版本）输出/退出码逐字节一致 |
| 9 | `./scripts/check-preview-surface.sh --strict`、`./scripts/check-protocol-surface.sh --strict` | exit 0；与 HEAD 版本输出/退出码一致 |
| 10 | `./scripts/report-baseline.sh`（gate-smith 的只读报告脚本，会读取 cleanup-baseline.json） | exit 0：9 个 metrics 字段均正常输出，未被新 key 破坏 |

行为等价对比方法：把 HEAD 版本 3 个 check 脚本写到 `.gather/orig-check/head-*.sh` 再与工作区版本同参数各跑一次，`diff -q` stdout/stderr 且比较退出码（全部 SAME）；`check-test-catalog.sh --self-test` 额外验证临时目录无残留。

## 6. 风险与后续

1. **shellcheck 版本漂移（本任务最需要关注的风险）**：本地用 0.10.0；CI 的 ubuntu-latest 镜像自带版本会随镜像换代变化，而 workflow 里没有安装/固定版本步骤。版本差异可能新增/删除规则 → CI 上 [f] 可能报本地没见过的 finding。缓解：门禁 PASS/FAIL 行会打印实际版本（`shellcheck 0.10.0：22 个 tracked *.sh，0 finding`），排障先看版本；新版本规则若合理就修代码，若确认误报就加「带理由的 scoped disable」。更彻底的做法是在 CI 固定版本（例如 apt 装指定版本或 docker 镜像），但那属于 ci.yml/流程改动，不在本任务写作用域（未改 ci.yml）。**不要**为了让门禁变绿而全局调 severity。
2. **验证上限（必须声明）**：无 macOS/Xcode → 本轮没有任何编译/单测证据；Swift 改动只到 `-parse` 与 Linux 同源探针。真实 macOS 侧的 typecheck 由 `check-warnings.sh`（`-warnings-as-errors`）与 gather-core/gather-app 测试在 CI 兜底；若 `unsafeDowncast` 对该 SDK 导入类型有兼容问题，会在 CI 立刻暴露（而不是静默）。
3. **工作区并发漂移**：其他子代理仍在改 Sources；ratchet 的 9 个计数是采样时刻的值（baseline `generated_at` 已记录）。合并后建议重跑 `./scripts/check-cleanup-ratchet.sh`；若有人新增了 `try?`/`fatalError` 等，门禁会按设计 FAIL，届时按指标修代码而不是改基线（`--write-baseline` 对已有 key 有防膨胀保护）。
4. **[f] 的自指限制**：只扫 **tracked** `*.sh`，所以新脚本在 `git add` 之前不在扫描面内（`check-repo-hygiene.sh`、`report-baseline.sh` 目前是未跟踪文件）。本轮已对这两个新脚本单独跑过 `shellcheck -S warning`（0 finding），提交后会自动纳入 [f]。
5. **本地运行门槛**：本机 PATH 无系统 shellcheck 时 [f] 会按设计 FAIL 并打印安装提示——这是预期行为（CI 有预装）。本地复跑请用 `PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh`；若希望去掉这个前缀，应向系统装 shellcheck，而不是在门禁里硬编码 gitignored 路径（会破坏 CI/本地同口径）。
6. **未触碰的文件**：`.github/workflows/ci.yml` 未编辑（PyYAML 校验通过）；`scripts/design-system-baseline.json` 未触碰（另一 agent 的范围）；其他 teammate 的 Swift/UI/docs 改动一律未动、未回退。

## 7. 变更文件清单（本任务）

| 文件 | 行号 | 变更 |
|------|------|------|
| `scripts/check-preview-surface.sh` | 154-159 | SC2043：单元素 for → 直接 `if [ ! -f ]` |
| `scripts/check-protocol-surface.sh` | 74-83 | SC2046：两处 `$(cat filelist)` → `xargs -I{} cat {}` 逐行传入（附原因注释） |
| `scripts/check-test-catalog.sh` | 31-32、127-136 | SC2064：临时目录提到脚本级 `SELFTEST_TMP` + 单引号 trap；顺带给原 SC2206 disable 补理由 |
| `scripts/test.sh` | 31-34 | SC2206：`FLAGS=(...)` → `read -r -a FLAGS <<< ...`（附原因注释） |
| `scripts/check-repo-hygiene.sh` | 4-5、26-29、36-39（header/usage）、527-571（[f] 节） | 新增 [f] shellcheck 节 + header 文档/「六节」口径 |
| `scripts/check-cleanup-ratchet.sh` | 4-13（header）、35（METRICS）、84-87（case）、108-123（write_baseline）、56（--help 行区间） | 新增 4 指标 + 文档/基线模板同步 |
| `docs/cleanup-baseline.json` | 1-25 | `try_optional` 261→260；新增 4 指标与 scopes；`--write-baseline` 重生成 |
| `desktop/native/gather-core/Sources/GatherAnalysis/Image/ImageMetadataProviders.swift` | 166-175 | `as! CGImageMetadataTag` → CFTypeID 判型 + `unsafeDowncast`（附原因注释） |
| `docs/reviews/2026-11-17-quality-hardening/standards.md` | 本文 | 证据与风险记录 |
