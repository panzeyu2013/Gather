# R3-tooling：门禁 / 工具链对抗性复核（第三轮）

- 评审对象：本地 `main` @ `3486be0b`（22 commits ahead of `origin/main` `e5c54f37`），重点为 round-2 门禁修复提交 `7b00b69a`；**评审期间工作区已有 round-3 工具链修复（未提交）**，本分册同时对抗性复核了这些修复（快照见 §2.4）。
- 方法：只读；对抗性探针全部在 `.gather/r3-tooling/` 的 `git archive` scratch 仓库执行（HEAD 树 / 叠加工作区脚本的 overlay 树），不修改受审工作树。Swift 探针用 Linux Swift 6.2（`.gather/swift62`），`-typecheck` 仅用于纯 stdlib 探针。
- 验证上限：**无 macOS/Xcode**，未编译 AppKit/SwiftUI/CoreML target、未跑 `swift test`/`check-warnings.sh`/AppIntents 自检、未在真实 GitHub Actions 上执行；CI 语义仅 PyYAML + 结构断言静态验证。

## 0. 结论

- **未发现 P0/P1**（本分册范围内无编译中断/崩溃/数据损失/CI 必红的新增项）。
- round-2 修复提交 `7b00b69a` 的 8 处改动在**正常路径上全部正确、无副作用**：HEAD 上 16/16 Linux 可跑门禁全绿，两轮输出逐字节一致，门禁运行不写工作树；关键基线精确（test-catalog 14959/14959；protocol 111/17192/514/3115；cleanup 9 指标全 0 涨幅）。
- round-2 的两个 P2（docs-facts CI wiring / 清单作用域）在 HEAD 上仍是**部分修复**（见 §2.2、§2.3）；**工作区 round-3 修复已把其中绝大多数绕过面关闭**（逐项对抗性复验，见 §2.3），但仍残留**表达式形态的静默禁用**（`if: ${{ false }}`、`continue-on-error: ${{ true }}`）等 P2/P3，见 §1。
- 另发现 round-3 工作区修复自身引入/遗留的 3 类问题：protocol **模块级** `--write-baseline` 缺 key 仍静默写（主指标已修）、docs-facts 新解析器的误报/脆弱点、cleanup 注释间隔绕过未闭且注释夸大。均为 P3。

## 1. Findings

> 状态列：**HEAD** = `3486be0b` 提交树；“工作区”= 2026-11-18T06:08Z 未提交 round-3 修复（sha256 见 §2.4）。所有 rc 均为 scratch 实测。

| ID | severity | 状态 | 位置 | 问题 | 证据 | 建议修复 | 置信度 | macOS 不可验 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R3T-01 | **P2** | 工作区残余 | `scripts/check-docs-facts.sh`（工作区版 jobs/steps 解析段，约 L418-470） | 工作区修复已识别字面量 `if: false` / `continue-on-error: true` / 附加参数 / 包装 / echo / release-job 接线，但**表达式形态仍可静默禁用**：step `if: ${{ false }}`、step `continue-on-error: ${{ true }}`、job `if: ${{ false }}`、job `if: ${{ 0 }}` → docs-facts 仍 rc=0 “精确接入全部 17 个门禁脚本（无禁用/短路）”，CI 上该门禁被跳过/失败不红 | overlay scratch：`wt-if-expr-false-step` rc=0、`wt-coe-expr-true` rc=0、`wt-if-expr-false-job` rc=0、`wt-if-expr-zero-job` rc=0；对照字面量：`wt-if-false-step`/`wt-continue-on-error`/`wt-if-false-job` rc=1 | 对 `if`/`continue-on-error` 做表达式归一：去掉 `${{ }}` 与空白后拒绝 `false`/`0`/`''`；或更稳妥地要求门禁 step **不得出现任何 `if:`**、`continue-on-error` 只能是 false/缺省（显式恒真的 `success()` 等可白名单） | 高 | 否 |
| R3T-02 | P3 | 工作区新增残余 | `scripts/check-protocol-surface.sh:260-271`（工作区版，模块级写基线守卫） | round-3 工作区修复只把**主指标** `--write-baseline` 缺 key 改为拒绝（rc=1），**模块级 baseline（`protocol-surface-modules-baseline.json`）守卫仍为 `[ -n "$base" ] \|\| continue`**：删一个模块 key 后 `--write-baseline` rc=0 并静默补写 | overlay scratch：删 `public_types_gatherdelivery` → normal rc=0（warning 模式）/strict rc=1；`--write-baseline` **rc=0 “模块基线已写入”** 且 key 被静默恢复（28）；主指标同法删 `zero_reference_types` → `--write-baseline` rc=1 “拒绝静默补写” ✅ | 模块守卫同样改为缺 key 拒绝写入（与主指标/cleanup/perf 一致） | 高 | 否 |
| R3T-03 | P3 | 工作区残余+注释不实 | `scripts/check-cleanup-ratchet.sh:80-103`（工作区版） | 新 Python 计数器已覆盖**跨行/双空格/Tab**，但 `@unchecked /* gap */ Sendable`（注释间隔，`swiftc -typecheck` 合法）仍不计入（60/60 ok）；而新注释写“多行、**注释间隔**、双空格、Tab 都计数”——与实现不符。另该指标新增 python3 运行时依赖（脚本头未声明；缺 python3 时 rc=127，属 fail-closed 但报错不友好） | overlay scratch：single/double/tab/newline 注入均 61/60 FAIL；`comment-gap` 60/60 ok；`swiftc -typecheck` 对换行/注释间隔两形态 rc=0（`CLANG_MODULE_CACHE_PATH=$PWD/.gather/cc`）；缺 python3 探针 rc=127 | 计数前做注释遮罩（或正则改为 `@unchecked(?:\s\|/\*.*?\*/)+Sendable`）；修正注释；头部声明 python3 依赖并在缺依赖时显式 FAIL | 高 | 否（Linux swiftc -typecheck 验证） |
| R3T-04 | P3 | 工作区残余 | `scripts/check-protocol-surface.sh:84`、`docs/protocol-surface-baseline.json` | 扫描量守卫由 100/400 收紧到 **105/510**，但仍低于基线 111/514：只保留“类型数最多的 105 个文件”（丢 6 文件、public_types 512）`--strict` 仍 rc=0（只 warn）。`protocol_files/protocol_lines` 仍不参与比较且 note 未标“信息字段”：删 1 个协议文件 strict rc=0，字段会再次静默漂移（与 HEAD 相同，R2T-09 的“二选一”建议未落实） | overlay scratch：top-105 strict rc=0（105/16900、types 512、warn 512<514）；top-104 strict rc=2 “FAIL 扫描量异常：proto_file_n=104 public_types=511”；删除单个 zero-type 文件 strict rc=0（110/17168） | 阈值由基线派生（如 ≥ `protocol_files_baseline - 5`），或把 files/lines 纳入 compare_metric（回落超容差 FAIL；否则 note 明示信息字段） | 高 | 否 |
| R3T-05 | P3 | 工作区新增误报 | `scripts/check-docs-facts.sh`（工作区版 `job_has_guard`/`step_has_guard`/jobs 解析） | 新精确匹配对“合法但非单行 run 形态”误报（fail-closed，但会堵正常维护）：① gates job 里任何**无关** step 的 `if: false` 会让该 job 所有门禁判 FAIL；② 单命令 block scalar（`run: \|\n  ./scripts/check-layering.sh`，实际会执行）判 FAIL；③ YAML 引号写法 `run: './scripts/check-layering.sh'` 判 FAIL；④ `jobs:` 行带行尾注释时 job 解析失败、17 条全报 un-wired | overlay scratch：`df-unrelated-if-false-step` rc=1、`df-block-scalar-single` rc=1、quoted-run rc=1、`jobs:` 行注释 rc=1（18 条 unwired） | 优先用 PyYAML 解析 `jobs[*].steps[*].run/if/continue-on-error`；若坚持文本解析，`job_has_guard` 只查 job 级（steps 之前的 2 空格缩进键）且按“门禁 step 自身”查 guard；支持 block-scalar 单命令/引号 run 的归一化 | 高 | 否 |
| R3T-06 | P3 | HEAD+工作区均存 | `scripts/check-repo-hygiene.sh:610-619`（UI_APIS）、`DesignSystem/Components/GatherEmptyState.swift:14`、`GatherBadge.swift:36` 等 | [g] 本地化用法门禁只认 SwiftUI UI API 与既有 wrapper；设计系统组件（`GatherEmptyState(icon:title:message:)`、`GatherBadge(_:)`、`GatherStatCard(label:)`、`NativeBanner(text:)` 等）接收**裸 String 展示文案**却不在 UI_APIS：把 CJK 字面量直接传给它们不会被抓。当前调用点均走 `l10n(...)`/变量（无现网违规），属门禁盲区 | overlay scratch：[g] 注入 `GatherEmptyState(icon: "tray", title: "未本地化的中文标题", ...)` → rc=0（ok 2264 处）；对照 `Text("中文")` → rc=1 “未包裹 CJK 字面量 1 处” | 把设计系统“裸 String 展示文案”构造器加入 UI_APIS（加入后现有 `l10n(...)` 调用仍通过、变量传参不误报） | 高 | 否 |
| R3T-07 | P3 | 工作区残余 | `scripts/test.sh:31-34`（工作区版） | `IFS=$' \t\n' read -r -a FLAGS` 修好了 Tab 分隔（n=2），但 `read` 遇换行即止：`SWIFT_TEST_FLAGS=$'--a\n--b'` 仍只得 `--a`（n=1），而注释称“按空白拆分”（换行也是空白） | overlay bash 同构：tab n=2 → `--a --b`；newline n=1 → `--a`；unset n=0 | 注释注明“不支持换行分隔”，或整串 `tr '\n' ' '` 后再 `read -a` | 高 | 否 |
| R3T-08 | P3 | HEAD+工作区均存 | `.github/workflows/ci.yml`（gates job）+ `check-repo-hygiene.sh:546-590` | ① 新 hygiene [f] 依赖 CI runner 预装 shellcheck（`-S warning`），版本未 pin、finding 集合随版本漂移（已知 R4-F26；本地 0.10.0：26 文件 0 finding）；② docs-facts 的自监视盲区：把 Docs facts step 从 CI 删掉后无任何门禁能发现（它自己不再运行）——round-2 已提，本轮未变 | CI 无 shellcheck 安装/版本步骤（`grep shellcheck ci.yml` 为空）；删 Docs facts step 后其余 15 门禁无法反映（静态推断，未改真实 CI） | CI 显式安装并 pin shellcheck 版本；自监视可加“与 docs 无关的 meta 断言”（如 ci.yml 必须含 check-docs-facts 自身），但同一门禁无法自证，建议放入另一门禁/CI lint | 高 | 否 |
| R3T-09 | P3 | 工作区文档口径 | `docs/reviews/2026-11-18-local-changes-review-round2/00-overview.md` §3.4（工作区版仍写） | 工作区文档已把 §2#5 改为“部分修复 + round-3 已精确 run 行”，但 §3.4 仍写“docs-facts 残余绕过面（P3）：`if: false` / `continue-on-error: true` / 步骤级禁用**仍未检测**”——与同一工作区的 round-3 修复矛盾（字面量已检测，仅表达式形态未闭）；§2#6“只认清单项形式”表述也弱于实际（现为 fenced-only） | 读工作区 `00-overview.md` §2#5/§2#6/§3.4 | docs-steward 收口：§3.4 改为“表达式形态（`if: ${{ false }}` 等）仍可绕过”，§2#6 改为“仅认 fenced 清单行” | 高 | 否 |

说明：R3T-01 是“先让 step 不跑/命令短路”类问题在工作区修复后的唯一残余；R3T-02/03/04 是工作区修复的**残余细节**，R3T-05/06/07/08 为门禁自身的误报/盲区/可维护性问题，均非本轮引入的行为回归。

## 2. Verified OK（独立复核通过）

### 2.1 HEAD 门禁套件（16/16 Linux 可跑门禁，两轮）
- `check-no-legacy / cleanup-ratchet / layering / domain-events / domain-writes / duplicate-symbols --strict / test-catalog --strict / preview-surface --strict / design-system / select-star --strict / protocol-surface --strict / coded-errors / backlog-evidence / repo-hygiene / docs-facts / perf-ratchet` → **16/16 PASS**（HEAD `3486be0b` 树与工作区树各跑两轮，输出逐字节一致；单门禁 0–9s）。
- 关键实测：`@Test 3267/3267 · @Suite 419/419 · #expect+#require 14959/14959`；protocol `111/17192/514/3115/zero 1/envelope 0`；cleanup 9 指标 `60/257/0/0/0/7/0/0/0` 全 ok；hygiene [b] HEAD 1274、工作区 1279（含已 staged 的 R3 文档）个文本文件全过；docs-facts “精确接入全部 17 个门禁脚本”。
- 门禁运行不写工作树（scratch `git status` 空）；两轮逐字节一致（确定性）。

### 2.2 round-2 修复提交 `7b00b69a` 逐项复核（HEAD 树）
- **R2T-03 断言基线 14959 ✅**：HEAD 实测 14959 与基线精确相等；scratch 注释/删除 1 条 `#expect` → 14958 FAIL；删 1 个 `@Test` → 3266 FAIL。算术核对：`6e940350` net +4 断言、`5bcf915b` net +1（+3/−2）→ 14954+5=14959；`git archive 5ea5c38f` 上旧脚本实测 14954（与注释一致）。
- **R2T-05 protocol 注释 ✅**：`check-protocol-surface.sh:73-76` 已改 while-read 并如实说明旧 xargs 单引号问题；scratch 建 `GatherProtocol/Probe Note's.swift` → rc=0 且指标 112/17193（旧版会失败）；模块 metrics 与基线逐项相等。
- **R2T-06/R2T-08 BOM + .gitignore ✅**：BOM 前缀探针在 `docs/README.md`、`LICENSE`、`.gitignore`、`desktop/.gitignore` 全部 FAIL（“has UTF-8 BOM”）；`.gitignore` 行尾空白/CRLF/缺末行换行负例全部 FAIL；干净树 [b] 1274 全过且两轮一致；覆盖面枚举 = tracked 1277 − 3 个二进制（icns/mlmodel/bin），无漏文本文件（basename 匹配同时覆盖根与 `desktop/`）。
- **R2T-11 空白正则：部分 ✅**：单空格/双空格/Tab 均计数（61/60 FAIL）；HEAD 上换行/注释间隔仍绕过（见 §1 R3T-03，工作区已修换行、注释间隔仍存）。
- **R2T-09 protocol 基线字段：部分 ✅**：`protocol_files/protocol_lines` 17177→17192 与实测一致、`generated_at` 更新；模块基线只更新 `generated_at`，数值与实测一致；但字段仍不参与比较（R3T-04）。
- **R2T-13 report-baseline 头部 ✅**：头部“tables/indexes/FKs 与 DDL 字面量实测交叉核对（columns 取 expected 常量）”与实现一致；脚本只读（跑两轮工作树不变）、输出确定性、9 项 perf 与 `check-perf-ratchet` 逐项一致、测试计数 3267/419/14959、门禁数 17。
- **R2T-01/R2T-02：HEAD 上部分修复**。HEAD 已修复（探针 rc=1）：删 step、YAML 整行注释 step、`\|\| true` 掩码、去掉文档声明的 `--strict`、命令跨行拆写、清单行注释、节内正文提及（带后缀）；HEAD 未修复（探针 rc=0）：step `if: false`、`continue-on-error: true`、job `if: false`、`run: true # cmd`、echo 注入、`\|\| echo`、追加 `--help`/`--write-baseline`、release(tag-only) job 接线、name 字段注入、裸 `./scripts/` 正文行——**其中除表达式形态外已被工作区 round-3 修复关闭（§2.3）**。
- 范围审计：origin/main→HEAD 的基线变更**无放宽**（cleanup `try_optional 261→257`+4 零容忍指标；design `font.callout 86→0`、`literalSpacing 89→86`、`empty 28→6`、`theme 15→1`；protocol/perf 基线未放宽；test-catalog 重钉有账可核）。`git diff --check origin/main..HEAD` 干净。

### 2.3 工作区 round-3 工具链修复（未提交）对抗性复验
- **docs-facts 精确接线**：下列改法全部转为 FAIL：删 run 行；YAML 整行注释 step；字面量 `if: false`（step/job）；`continue-on-error: true`；shell 注释遮蔽（`run: true # cmd`）；`echo cmd`；`cmd \|\| echo`/`cmd \|\| true`；追加 `--help`/`--write-baseline`；release-job-only 接线；name 字段注入；`run: \|` 块内 exit 0/多命令/附加参数；命令跨行；去掉 `--strict`；删 `check-warnings.sh app` invocation（docs 已拆 core/app 两行）；fenced-only 清单：裸正文行/清单行注释/删清单行全部 FAIL，`## 门禁` 前缀重命名仍 pass。
- **hygiene [c] 链接**：带 title 的坏链、引用式坏链、尖括号坏链、坏图片链全部 FAIL；指向 tracked 文件的带 title/引用式链接 pass（无假阳性）；未定义引用按文档约定跳过。
- **cleanup**：注入单/双空格、Tab、**换行** `@unchecked Sendable` 均 61/60 FAIL（工作区修复生效）；注释间隔仍 60/60 ok（R3T-03）。
- **写基线缺 key**：cleanup/perf/protocol 主指标 `--write-baseline` 均 rc=1 “拒绝静默补写”（HEAD 上 rc=0 静默写，已闭环）；protocol **模块级**仍静默（R3T-02）。
- **protocol 守卫**：104 文件 rc=2 FAIL 关闭；105 文件（512 类型）仍 pass（R3T-04）。
- **test.sh**：Tab 分隔 flags 已可拆（n=2），换行仍 n=1（R3T-07）。
- 工作区 16/16 门禁两轮全绿、输出逐字节一致；基线工作区只改 `generated_at`（值不变，无放宽）。

### 2.4 评审期间工作区快照（移动目标）
- 时间：2026-11-18T06:08Z；HEAD `3486be0b`；工作区工具链修复未提交。sha256：`check-docs-facts.sh 25bb64b9…`、`check-repo-hygiene.sh e6b16559…`、`check-cleanup-ratchet.sh 1adc4ee0…`、`check-perf-ratchet.sh 27b2ab6c…`、`check-protocol-surface.sh 49367a73…`、`test.sh 246c786b…`、`ci.yml 35cee15e…`、`DEVELOPMENT.md 1e17518f…`。
- 结论以该快照为准；提交前如有再改动需重跑 §2 的探针与 16 门禁。

## 3. 复现入口（scratch，gitignored）

- docs-facts：`.gather/r3-tooling/probes-docs-facts.sh`（HEAD B1–B25）、`probes2.sh`（追加 flag/裸行/release-only）、`probes-worktree.sh`（工作区版主探针）、`probes-wt2.sh`（hygiene 链接 + 误报）、`probes-wt3.sh`（module guard/解析边界）。
- 其它门禁：`probes-hygiene.sh`（BOM/.gitignore/覆盖面）、`probes-cleanup.sh`（@unchecked + swiftc typecheck）、`probes-protocol.sh`（guard/基线）、`probes-testcatalog.sh`（断言删/注释/自测/report-baseline）、`probes-suite.sh`（HEAD 16 门禁两轮 + fail-closed）、`probes-fc3.sh`、`probes-misc.sh`、`probes-g-tseq.sh`（[g]/短路注入）。
- scratch 仓库：`.gather/r3-tooling/probe`（`git archive HEAD` + `git init`）、`probe-wt`（HEAD + 工作区脚本 overlay）、`probe-old`（`git archive 5ea5c38f`）；探针后 `git reset/checkout/clean` 复位；工作区 16 门禁日志在 `.gather/r3-tooling/suite-wt/`。

## 4. Coverage & Limitations

- 无 macOS/Xcode：未编译 AppKit/SwiftUI/CoreML、未跑 `swift test`/`check-warnings.sh`/AppIntents 自检、未验证 CI macOS runner 行为；`ci.yml` 只做 PyYAML+结构断言（无 actionlint），`if: ${{ false }}` 等绕过是**静态**证明（GitHub 表达式语义按官方文档判断），未在真实 Actions 上执行。
- shellcheck 用本地 0.10.0，CI runner 版本未 pin（R3T-08）。
- 评审期间工作树是移动目标（lead 的 round-3 修复、docs-steward 并行改文档）：§2.1/§2.3 均按 §2.4 快照验证；**提交后需按最终提交重跑一次 16 门禁**。
- 未重复 round-1/2 已充分验证的语义面（localization 解析器、domain-writes 规则集等）；本分册聚焦门禁/工具链。

## 5. 给 lead 的处置建议（按性价比）

1. **R3T-01（P2，建议本轮修）**：在 docs-facts 里把 `if`/`continue-on-error` 值做表达式归一（去掉 `${{ }}`/空白后拒绝 false/0/空），或要求门禁 step 不允许出现 `if:`、`continue-on-error` 只能为 false。合入后重跑本分册 §2.3 的探针即可闭环。
2. **P3 顺手修**：R3T-02（protocol 模块写基线守卫一行改动）、R3T-03（cleanup 注释间隔 + 注释/依赖声明）、R3T-04（守卫阈值派生或字段纳入比较）、R3T-05（docs-facts 解析改 PyYAML 或缩窄 guard 检测）、R3T-07（test.sh 注释）、R3T-09（round-2 归档 §3.4 口径，交 docs-steward）。
3. **follow-up**：R3T-06（[g] 设计系统组件盲区）、R3T-08（shellcheck pin + 自监视）。
4. 提交前提醒：本文件在 06:08Z 前被 staged 的是旧版本，最终提交时请重新 `git add` 本文件；本文件已满足 hygiene [b]（LF/无行尾空白/末行换行），正文不含相对 Markdown 链接。
