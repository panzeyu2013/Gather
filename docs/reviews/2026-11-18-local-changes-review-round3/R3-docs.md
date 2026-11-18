# R3-5 第三轮独立评审：评审归档准确性 / 文档一致性 / 剩余后续最优性

- 评审人：review3-docs（task-40；第三轮独立评审，非任何改动作者，未参与 round-1/round-2 归档撰写）
- 评审对象：
  1. round-2 归档 `docs/reviews/2026-11-18-local-changes-review-round2/**`（00-overview + R2-core/app/tests/tooling/docs）与其修复提交 `5bcf915b`（代码/测试）、`7b00b69a`（门禁/基线）、`3486be0b`（文档 + 归档）；
  2. round-1 归档 `docs/reviews/2026-11-18-local-changes-review/**` 与 round-3/4 审计文档中被 2026-11-18 两轮评审修正的论断；
  3. 全部 docs 事实声明（README / docs/README / DEVELOPMENT / ROADMAP / test-runtime-audit / reviews 索引）与当前代码、脚本、baseline 的一致性；
  4. round-2 残余清单的完整性 / 最优性，以及 docs 与门禁的门禁级矛盾。
- **基线**：HEAD = `3486be0b`（本地 main，22 commits、234 files、+11587/−965 vs `origin/main` `e5c54f37`；工作树干净）。评审期间未修改任何 tracked 文件；探针全部在 `.gather/`（gitignored）。
  - 注：lead 的任务简报写 "+11587/−1165"，实测 `git diff --shortstat e5c54f37 HEAD` = `234 files changed, 11587 insertions(+), 965 deletions(-)`（−1165 疑为笔误，供 lead 核对）。
- **环境与验证上限**：Linux Ubuntu 22.04，**无 macOS/Xcode**。Swift 6.2（`.gather/swift62`）、shellcheck 0.10.0、python3、git。**未编译 AppKit/SwiftUI/CoreML target、未跑 `swift test`、未跑 macOS CI/check-warnings、无 Instruments/真机**。本轮实际做了：真实 `swiftc -typecheck`（含 3 个 P0 修复文件的**修复前/后**对拍）、`git archive HEAD` scratch 副本里的 `swift package dump-package` + `GatherProtocol`/`GatherPreviewData` Linux 构建、逐文件 `swiftc -parse` 全仓、16 道 Linux 门禁 + 5 个 `--strict`、`report-baseline.sh`、docs-facts / hygiene（含 Markdown 链接审计）、11 组对抗性门禁探针、跨文件访问级别/标签/Mutex 泛型最小探针。
- 说明：round-1/round-2 归档与各审计文档一律当"待验证假设"，逐条对代码/脚本/baseline 复核；分册中他人转述的结论只在能独立复现处采信。

## 0. 结论速览

| 维度 | 结果 |
|---|---|
| round-2 P0 修复（编译中断） | **4 个 P0 缺陷全部修复且经真实类型检查验证**（不是 -parse）：DateFormatting 旧版 typecheck 报错、HEAD 版 `-warnings-as-errors` typecheck rc=0；`private(set)` 跨文件可读最小探针 rc=0（旧 `private` 版 rc=1）；JSONValueCodingTests 旧版在 :128 报 `try cannot appear to the right...`、HEAD 版对真实 Linux 构建的 GatherProtocol 模块 typecheck rc=0。 |
| round-2 §2 修复项 | 16 项中 **13 项完全成立 + 1 项按字面成立**（#16 验收方式确实记录在 R2-docs，但未进 DEVELOPMENT/CI）**+ 2 项部分成立**（#14 归档 hash 修文"其父"表述错、round-1 "#已修"描述未改；#15 "NSCache 悬崖前提全部修正"不实）。 |
| round-2 §4 验证声明 | **全部可复跑复现**（manifest / 两个可移植 target 构建 / 1090 文件 parse 0 失败 / 纯 Foundation 修复文件 typecheck 0 errors / 16 道 Linux 门禁 + 5 --strict 全 PASS / `git diff --check` 干净）。 |
| 文档数字 | `report-baseline.sh` 与 docs/README、DEVELOPMENT、ROADMAP、test-runtime-audit、reviews 索引**全部一致**：targets 18（functional 9）/ API 16、195 / @Test 3267 / @Suite 419 / 断言 14959（baseline 14959）/ en 2682、zh-Hans 9 / schema 55-451-86-81 / 门禁 17 / perf 9 指标 / protocol 111 文件 17192 行。 |
| docs-facts / 链接审计 | `check-docs-facts.sh` OK；`check-repo-hygiene` 7/7 PASS（Markdown 链接 100 个 .md / 212 条相对链接全部解析到 tracked 文件）。 |
| 新增问题 | **0 个 P0、0 个 P1**；文档一致性 P2 × 2、P3 × 12（全部是单行~数行的归档/文档修正，不阻塞 CI）。 |
| 总体判断 | round-2 的修复在代码/门禁/文档三个层面均可复现为正确，**唯一真实阻塞仍是 macOS 首跑**（macOS build/test/check-warnings/UI）。剩余问题集中在"归档自述与当前树的不一致"和"round-2 残余清单未收全"，属合并前可顺手修完的文档债。 |

## 1. Findings

> 级别：P0=崩溃/数据丢失/编译中断/安全；P1=很可能正确性回归/CI 红；P2=风险/鲁棒性/最优性；P3=nit/文档一致性。"macOS 不可验证"= 结论是否依赖 macOS 才能成立。全部为 docs-only 问题（除特别注明）。

| ID | Sev | 位置（HEAD 行号/commit） | 问题 | 证据（实际跑过什么） | 建议修复 | Conf | macOS 不可验证? |
|---|---|---|---|---|---|---|---|
| **R3D-01** | P3 | `docs/reviews/2026-11-18-local-changes-review-round2/00-overview.md:3,19-38`（`3486be0b`） | round-2 归档的"已修复项（round-2 fix）"**没有记录修复提交**：全文 grep 不到 `5bcf915b`/`7b00b69a`/`3486be0b`。对照 round-1 归档在 00-overview:21 明确写了 `6e940350`/`9be6a000`/`0288ea8d`。归档与修复提交同批提交后，读者无法从归档本身把 P0→提交映射起来（只能靠 git log message）。 | ① 实读三个提交：`5bcf915b` 6 files（DateFormatting / CullingViewModel / CullingService+Commands / MetadataKeywordWriter / SidecarXMPProvider+IPTCReading / JSONValueCodingTests）、`7b00b69a` 8 files（docs-facts / protocol-surface / hygiene / cleanup / test-catalog / report-baseline / 2 个 baseline）、`3486be0b` 14 files（6 个新归档 + 8 个既有 docs）；② 映射关系与 §2 归档 #1-#16 逐条吻合（见本文 §2 表）；③ `git grep 5bcf915b -- docs` = 0 命中。 | 在 §2 标题下补一行："修复提交：`5bcf915b`（代码/测试）、`7b00b69a`（门禁/基线）、`3486be0b`（文档+本归档）"，并给 #5-#11 → 7b00b69a、#1-#4/#12/#13 → 5bcf915b 的对应。 | 高 | 否 |
| **R3D-02** | P3 | `docs/reviews/2026-11-18-local-changes-review/00-overview.md:21`（`3486be0b` 修正行） | 修 dangling hash 时引入新错：写"`0288ea8d`（…；**其父** `33ef7313` 在 amend 后为 dangling）"。git 事实：`33ef7313` 与 `0288ea8d` 是**兄弟**（共同父 `9be6a000`），`33ef7313` 是 amend **前版本**，不是父提交。 | `git rev-list --parents -n1 0288ea8d` → `0288ea8d 9be6a000`；`git rev-list --parents -n1 33ef7313` → `33ef7313 9be6a000`；`git merge-base --is-ancestor 33ef7313 HEAD` → 非祖先。 | 改为"其 amend 前版本 `33ef7313` 已 dangling（同一父 `9be6a000`）"。 | 高 | 否 |
| **R3D-03** | P3 | `docs/reviews/2026-11-18-local-changes-review/00-overview.md:54`（§3.8）与 :42（#18） | round-1 归档 §3.8 经 `3486be0b` 改成"protocol_lines（17177→17192）不参与比较；本轮仅记录漂移，**未改基线文件**与比较语义"，但同一修复批次里的 `7b00b69a` **已经用 `--write-baseline` 把基线改成 17192**（并刷新 generated_at）；round-2 归档 §2 #9 也写"已更新"。两份归档对"基线文件是否更新"自相矛盾，读者会以为基线仍是 17177。 | 读 `docs/protocol-surface-baseline.json:5` = 17192；`git show 7b00b69a -- docs/protocol-surface-baseline.json`（17177→17192、generated_at 更新）；`./scripts/check-protocol-surface.sh --strict` → `Protocol 文件/行 111 / 17192`，PASS。 | §3.8 改为"round-1 仅记录漂移；2026-11-18 round-2 fix（`7b00b69a`）已按 `--write-baseline` 更新说明性字段为 17192，仍不参与比较"；:42 #18 同口径。 | 高 | 否 |
| **R3D-04** | P3 | `docs/reviews/2026-11-18-local-changes-review-round2/00-overview.md:12` | P0 计数错误：表格写 **P0 = 3**，但同一行正文实际描述 **4 个**不同 P0，§2 也给了 4 条 P0 修复（#1 DateFormatting、#2 pageAssignmentCount、#3 navigationGroupsVersion、#4 JSONValueCodingTests）。来源拆分也错："`6e940350`（2 个）"实为 **3 个**（DateFormatting/Preload 读/JSON 测试），`2cbe3e68`（1 个）为 navigationGroupsVersion。 | `git log -S` 逐项验证：`body: { formatter` → `6e940350`；`plannedAssignment`（+Preload 读 `pageAssignmentCount`）→ `6e940350`；`try JSONValue.parse(json) == try` → `6e940350`；`navigationGroupsVersion` 在 +Navigation 的使用 → `2cbe3e68`。3+1=4。 | P0 行改 4，并把"（2 个）"改"（3 个）"；或明确"R2-app 3 个 + R2-core/tests 1 个（与 R2-docs 的 3 个交集于 2）"。 | 高 | 否 |
| **R3D-05** | P3 | `docs/reviews/2026-11-18-local-changes-review-round2/00-overview.md:64,68`（§5 分册覆盖） | 分册计数与分册自身不符：① 写 "R2-core：1 P0 + 2 P2 + **8 P3**"，实际 `R2-core.md` findings 表有 **9** 条 P3（R2C-03/04/06/07/08/09/10/11/12）；② 写 "R2-docs：… + **5 P2** + 17 P3"，实际 `R2-docs.md` §0 自报 **P2 = 2**（R2D-04/05）+ P3 17。 | 逐行计数 R2-core findings 表：P3 = 9；`R2-docs.md:30` "**P2** | **2**"。 | 改成各自分册的自报口径（R2-core 9 P3；R2-docs 2 P2 + 17 P3），或删掉精确数字只写"见分册"。 | 高 | 否 |
| **R3D-06** | **P2** | `docs/reviews/2026-11-18-local-changes-review-round2/00-overview.md:37`（§2 #15） | 声称"NSCache 悬崖前提（round-2 证伪）**全部修正**"，**不实**：只有 round-3 `perf-runtime.md:18` 的 R3 行补了更正；round-3 **入口文档** `00-overview.md:15,49` 仍把"300dpi 2048px 图旧 cost 低估 17.4x、512MB 上限形同虚设"当作本轮关键成果（该前提已被 round-2 R2-A3/R5-05 复评证伪：缓存图来自 App 自编码预览 JPEG，无 RAW DPI 折算）。归档修复状态与仓库实际文本矛盾。 | 读三处原文：`round3/00-overview.md:15,49` 仍是 17.4x/上限失效表述；`perf-runtime.md:18` 已含"round-2 复评修正…前提不成立"；`round-2 00-overview.md:37` 声称"全部修正"。 | 在 round-3 `00-overview.md:15`（数字列）与 :49（正文）补"（2026-11-18 复评修正：前提不成立，见 perf-runtime R3 行）"，或把 round-2 #15 改为"部分修正（perf-runtime 已改，round-3 总览待改）"。 | 高 | 否 |
| **R3D-07** | **P2** | `round2/00-overview.md:37` + `R2-docs.md:59` + `round1/00-overview.md:13,56-64` | round-2 唯一的 **P2 finding R2D-05**（归档"全部已修"状态与 HEAD 不符、§4 验证缺"parse≠类型检查"边界）**没有被修**：`3486be0b` 对 round-1 归档只改 3 行（:21/:42/:54），:13 "全部已修（见 §2）"、§4 "验证（2026-11-18 修复后实跑）"原样保留、无 typecheck 边界说明；而 round-2 #15 反而把 "R2D-05 等 **P3**" 当作已修项列出（R2D-05 实为 **P2**）。修完后 §2 的 3 个"已修"在 HEAD 上已由 round-2 修复成立，但归档从未记录"其中 #3/#8/#10 初版曾编译中断、由 round-2 修复"这一关键事实。 | `git show 3486be0b -- docs/reviews/2026-11-18-local-changes-review/00-overview.md`（仅 3 hunk）；`sed -n '13p;56,64p'` 原文；`R2-docs.md:59` 明确标 P2。 | ① round-1 §2 状态补"已修（#3/#8/#10 初版编译中断，round-2 `5bcf915b` 修复，见 round-2 归档）"；② §4 补一句"parse 不是类型检查；本轮 3 个 P0 由 typecheck 才暴露"；③ round-2 #15 的 "R2D-05" 改为 R2D-06 或删 ID。 | 高 | 否 |
| **R3D-08** | P3 | `docs/reviews/2026-11-18-local-changes-review/00-overview.md:51`（§3.5） | round-1 残余清单仍写"**CORE-04**：`SidecarRegexCache.withRegex<T: Sendable>` 依赖 Darwin NSRange 的 Sendable 声明…macOS CI 首跑若报错改为非泛型返回形态"，但该约束已在 round-2 `5bcf915b` 移除（round-2 #13 已记为已修）。round-1 残余清单未同步，读者会以为风险仍开放。 | 读代码 `SidecarXMPProvider+IPTCReading.swift:24` = `static func withRegex<T>(`（无 `: Sendable`）；`git show 5bcf915b -- …SidecarXMPProvider+IPTCReading.swift`；round-2 00-overview:35（#13）。 | round-1 §3.5 标注"已由 round-2 `5bcf915b` 修复（去泛型约束）；macOS 首次构建仍需顺带确认"或从残余清单移除。 | 高 | 否（Darwin 侧仍待 macOS） |
| **R3D-09** | P3 | `docs/reviews/2026-11-18-round4-perf/perf-db4.md:191`（§7 验证上限） | 仍写"行为正确性（尤其 close 时 optimize 与 mmap 的 macOS 表现…）需 macOS CI 首跑复核"——optimize 已在 `Database.close()` 移除（CORE-02），该文件 §3 自己也标了"已移除"。round-2 #15 声称"round-4 总览的 close-optimize 残留全部修正"，但只修了 `00-overview.md`，分册 `perf-db4.md` 的 :191 未改。 | `sed -n '191p' perf-db4.md`；`grep -n optimize perf-db4.md`（:65 标题已标移除、:191 仍按现存代码描述）；对照 `Database.swift:329-333`（仅注释）。 | :191 改为"mmap（optimize 已移除，无需复核）与读写连接/只读池、WAL checkpoint…"。 | 高 | 否 |
| **R3D-10** | P3 | `desktop/native/gather-core/Sources/GatherPersistence/Database/Database.swift:333` | close 注释仍写"需要统计刷新时应走**显式维护任务**，而不是 close 隐式写库"——仓库不存在这样的维护任务/API（round-2 R2D-17 已指出；round-2 只修了 docs/DEVELOPMENT 与 round-4 总览，**代码注释未改**），且与 DEVELOPMENT"当前无自动任务"直接矛盾。 | `grep -rn '维护任务' Sources docs` → 只剩 `Database.swift:333`（另一命中是 round-3 perf-runtime 的后台维护任务表，与统计刷新无关）；`grep -rn 'ANALYZE\|PRAGMA optimize' Sources` → 仅该注释自身；DEVELOPMENT:283-285 已写"当前无自动任务"。 | 注释改为"依赖 SQLite 自动 ANALYZE 覆盖常规场景；如需手动刷新后续再加"（与 DEVELOPMENT 同口径）。 | 高 | 否 |
| **R3D-11** | P3 | `scripts/check-docs-facts.sh:382-404`（`7b00b69a` 修复的残余） | round-2 #6 声称"清单只认以 `./scripts/` 开头的行"，实现做了行首锚定但**未解析 fenced code block**：把清单行整行替换成同节任意位置的裸命令行（如门禁节末尾单独一行 `./scripts/check-layering.sh`）仍 PASS（R2D-13 建议的"fenced block + 行锚定"未落地）。同一门禁对 `if: false`/`continue-on-error` 仍无感（round-2 §3.4 已记录）。 | scratch `git archive HEAD` 副本逐项探针：删清单行+节内正文提及（非行首）→ rc=1 FAIL（修复有效）；删清单行+节内插入裸 `./scripts/check-layering.sh` 行 → **rc=0 PASS（绕过）**；ci.yml 注释 run 行 → rc=1 FAIL；`|| true` → rc=1 FAIL；`if: false` → rc=0（已知残余）。 | 在门禁节内只接受 fenced 代码块中的清单行（简单状态机记录 bash fenced block 区间），并可选拒绝同 step 块内 `if:`/`continue-on-error:`。 | 高 | 否 |
| **R3D-12** | P3 | `round2/00-overview.md:40-49`（§3 残余与后续） | round-2 §3 的"残余"只有 8 条，**未收全自己分册的未闭环项**（R2D-20 当年就要求"拆 before-merge/later 并按 finding ID 全量登记"，round-2 未做）。实读代码/文档确认仍未闭环的至少：R2D-13（见 R3D-11）、R2D-16（见 R3D-13）、R2D-17（见 R3D-10）、R2D-18（`CullingService+Commands.swift:416-426` 预载仍先插主照片 ID，主照片行读而不用）、R2D-19（`GalleryGrid.swift:44` 注释仍写"缓存为空返回 nil"，实现已线性回退）、R2D-20/21/22（round-1 §3 未重排、round-4 §8 未补 3 行、R1 §5/R3/R5 快照头未注明）；以及 R2C-08（`AssetRepo+Scan.swift:62` `limit: 14` 仍零余量）、R2C-09（SidecarRegexCache 无"body 内禁止重入"注释）、R2C-11（`MetadataDispositionService.swift:70-72` catch 仍静默返回 []）、R2T-07（hygiene 头部 [b] 检查面描述仍旧）、R2T-10（`check-perf-ratchet.sh:164` 写入路径缺 key 仍 `continue`）、R2T-14（test.sh 仅注释"按空白拆分"，未写不支持换行分隔）。 | 逐项读当前代码/脚本/文档验证（行号见上）；均不在 round-2 §3 的 8 条内。 | 在 round-2 §3 追加"合并前必须（macOS 首跑 + 归档修正）"与"后续（按 finding ID 全量列表）"两段；或在新 round-3 归档里维护统一台账。 | 高 | 否 |
| **R3D-13** | P3 | `docs/reviews/2026-11-17-round2-hardening/test-hygiene-round2.md:84` | 仍写 JSON oracle"stringify → parse 无损且与 baseline 编码值等价（**防 .sortedKeys/.prettyPrinted 配置漂移**）"。round-2 只补了 `!cached.contains("\n")`（能拦 prettyPrinted 换行），对象路径仍只比解析值，**.sortedKeys 漂移检测不到**（R2D-16 的文档更正未做）。 | 读 `JSONValueCodingTests.swift:70-75`（对象 `continue` 跳过字节比较）与 :127-134；`grep sortedKeys` 测试内 0 命中；round-2 R2D-16 原文未闭环。 | 该句改为"防 .prettyPrinted 换行漂移（对象 .sortedKeys 漂移不在本 oracle 覆盖内）"，或按 R2D-16 建议对对象加双侧 `.sortedKeys` 字节比较。 | 高 | 否 |
| **R3D-14** | P3 | `docs/README.md:51` | "17 个 `check-*.sh` 门禁（其中 **16 项在 2026-11-17** 本地全绿…）"：11-17 之后门禁已改（test-catalog 基线重钉 14959、cleanup 正则、hygiene BOM/.gitignore、docs-facts wiring 三处、perf 9 指标），本轮在 **2026-11-18** 重跑 16 道 Linux 门禁全 PASS，日期/口径应更新（属 nit，不影响门禁）。 | 本轮实跑 16 道 Linux 门禁 rc 全 0（含 5 个 `--strict`）+ `check-warnings` 无法在 Linux 跑；docs-facts 只校验"17 个"这个数，不校验日期。 | 改为"其中 16 项在 2026-11-18（round-2 修复后）本地全绿"（或"以 scripts/test.sh / CI 最近一次为准"）。 | 高 | 否 |

> 未发现新的 P0/P1；上表 P2 ×2 与 P3 ×12 均为 docs-only，不需要改代码行为。

## 2. round-2 修复 commit 与归档声明映射（独立核实；归档自身缺此表，见 R3D-01）

三个修复提交实测规模（`git show --numstat`）：`5bcf915b` 6 files、+41/−12；`7b00b69a` 8 files、+57/−18；`3486be0b` 14 files、+1094/−11。

| 归档项（round2/00-overview §2） | 提交 | 涉及文件（实测 `git show --stat`） | 独立验证 |
|---|---|---|---|
| #1 DateFormatting 标签 | `5bcf915b` | DateFormatting.swift（1 行） | 旧 blob typecheck 报错、新 blob `-warnings-as-errors` rc=0 |
| #2 pageAssignmentCount / #3 navigationGroupsVersion | `5bcf915b` | CullingViewModel.swift（2 处 private(set)） | 跨文件 `private(set)` 探针 rc=0；旧 `private` 探针 rc=1 |
| #4 JSONValueCodingTests | `5bcf915b` | JSONValueCodingTests.swift（+4 断言/格式守卫） | 旧文件 :128 typecheck FAIL；新文件对真实 GatherProtocol typecheck rc=0；断言 14959 |
| #5 docs-facts CI wiring / #6 清单作用域 | `7b00b69a` | check-docs-facts.sh（+41/−8） | 4 组探针：注释 run 行/正文提及/`|| true` 均 FAIL；裸命令行绕过仍存在（R3D-11） |
| #7 test-catalog 14959 | `7b00b69a` | check-test-catalog.sh（1 常量） | gate 输出 `14959/14959`；删 1 条 #expect → FAIL |
| #8 hygiene BOM/.gitignore | `7b00b69a` | check-repo-hygiene.sh（+4/−1） | BOM/CRLF 探针均 FAIL；[b] 扫描 1274 文件（含 2 个 .gitignore） |
| #9 protocol baseline | `7b00b69a` | protocol-surface(-modules)-baseline.json | baseline=111/17192；`--strict` PASS |
| #10 protocol 注释/守卫 100→400 | `7b00b69a` | check-protocol-surface.sh | 注释为 while-read 语义；移走 12 个 proto 文件（99<100）→ rc=2 |
| #11 cleanup 空白正则 | `7b00b69a` | check-cleanup-ratchet.sh | 注入 `@unchecked  Sendable`（双空格）→ 61/60 FAIL |
| #12 MetadataKeywordWriter fallback | `5bcf915b` | MetadataKeywordWriter.swift（+15） | 读代码：`GatherLogger` 在该文件已有使用/已 import；try_optional 仍 257 |
| #13 SidecarRegexCache 去 Sendable | `5bcf915b` | SidecarXMPProvider+IPTCReading.swift（1 行） | Linux Swift 6 复刻探针：无约束 `withRegex<T>` + 返回 `[NSRange]` 编译并运行 rc=0 |
| #14 applyImportedPicks 注释/文档 | `5bcf915b` + `3486be0b` | CullingService+Commands.swift；perf-core-round2.md；round-1 归档 | 注释已准确（微秒窗口/无 DB 级乐观锁）；文档已改 |
| #15 归档/文档修正 | `3486be0b` | 8 个既有 docs | ROADMAP:44、round-4 §8.1（:32/:83）、perf-core-round2 已改；**NSCache"全部修正"不实（R3D-06）、hash 行"其父"错（R3D-02）** |
| #16 验收方式变更 | （记录在 R2-docs） | — | R2-docs §1 记录方法；未写入 DEVELOPMENT/CI（属可选后续） |

## 3. round-2 §4 验证声明复跑结果（全部成立）

在 `git archive HEAD` 的 scratch 副本（`.gather/r3docs/repo`）与当前工作树执行：

```text
swift package dump-package（gather-core / gather-app）            → rc=0 / rc=0
swift build --target GatherProtocol（Linux Swift 6.2）            → rc=0
swift build --target GatherPreviewData（Linux）                    → rc=0
swiftc -parse（逐文件）：git ls-files '*.swift' = 1090 个          → 0 failures
DateFormatting.swift（HEAD）swiftc -typecheck -swift-version 6 -warnings-as-errors → rc=0
DateFormatting.swift（6e940350 旧 blob）typecheck                 → 报 extraneous argument label（4 处调用）
JSONValueCodingTests.swift（HEAD）typecheck + 已构建 GatherProtocol → rc=0
JSONValueCodingTests.swift（6e940350 旧 blob）typecheck           → :128 'try' cannot appear to the right…
16 道 Linux 门禁（scripts/check-*.sh 18 − check-appintents − check-warnings）→ 全 rc=0
5 个 --strict（duplicate-symbols/test-catalog/preview-surface/select-star/protocol-surface）→ 全 rc=0
check-repo-hygiene 7/7（含 shellcheck 0 finding、链接 100 .md / 212 链接）→ PASS
git diff --check origin/main..HEAD                                → 干净
```

数字侧（`report-baseline.sh`，只读事实报告）：targets 18（functional 9）/ 域 API 16/195 / @Test 3267 / @Suite 419 / 断言 14959，ratchet baseline 14959 / en 2682 / zh-Hans 9 / schema 55-451-86-81 / 门禁 17 / perf ratchet 9 指标（current 全 = baseline）/ protocol 111 文件 17192 行。与 docs/README、DEVELOPMENT、ROADMAP、test-runtime-audit、reviews 索引逐项一致；`check-docs-facts.sh` OK。

round-2 归档自身引用数字复核：`0288ea8d` = 19 commits / 226 files / +10432−961（`git diff --shortstat e5c54f37 0288ea8d`）；core Sources 44 files +612/−154、core Tests 15 个 Swift 测试文件 +274/−92（另 1 个 json fixture）、app 109 files +1660/−639、app Swift 463 个、测试文件 333 个、`0288ea8d` tracked 1271 个 —— **均与归档/分册一致**。

## 4. 对抗性探针（scratch 副本，未动 tracked 文件）

| 探针 | 期望 | 实测 | 结论 |
|---|---|---|---|
| docs-facts：ci.yml 门禁 run 行改注释 | FAIL | rc=1 | 修复 #5 有效 |
| docs-facts：删清单行 + 节内正文提及（非行首） | FAIL | rc=1 | 修复 #6 有效 |
| docs-facts：删清单行 + 节内插入裸命令行 | PASS（绕过） | rc=0 | **残余（R3D-11）** |
| docs-facts：run 行加 `|| true` | FAIL | rc=1 | 修复 #5 有效 |
| docs-facts：step 加 `if: false` | PASS（残余） | rc=0 | round-2 §3.4 已记录 |
| hygiene：docs/README 加 UTF-8 BOM | FAIL | rc=1 | 修复 #8 有效 |
| hygiene：`.gitignore` 写 CRLF | FAIL | rc=1 | 修复 #8 有效 |
| cleanup：注入双空格 `@unchecked  Sendable` | FAIL（61>60） | rc=1 | 修复 #11 有效 |
| protocol：移走 12 个 proto 文件（111→99<100） | rc=2 | rc=2 | 修复 #10 有效 |
| test-catalog：注释掉 1 条 `#expect` | FAIL（14958<14959） | rc=1 | 修复 #7 精确 |

## 5. 剩余后续的完整性 / 最优性评估

**必须在合并前完成（阻塞）**

1. **macOS 首跑**（唯一真实阻塞，与 round-2 §3.1 相同）：`swift build`（含 AppKit/SwiftUI target，尤其 CullingViewModel/+Preload/+Navigation、DateFormatting 所在 GatherUI）、`swift test`（至少 gather-core 的 JSONValueCodingTests 与 app 相关 filter）、`check-warnings.sh core|app`、UI 冒烟/Instruments。Linux 侧已把能证的部分证到：P0 修复均为真实 typecheck/探针级正确。
2. **归档与文档修正（R3D-02/03/04/05/06/07/09/10）**：全部是单行级改动，建议合并前一次性改掉，否则归档会永久带着与当前树相反的事实。
3. **reviews 索引补 round-3 轮次行/占位**（`docs/reviews/README.md`）：按该文件自述约定"尚未创建的轮次先以纯文本占位"；R3 归档文件 tracked 后链接才过 `check-repo-hygiene` [c]（**新增 md 里不要引用未 tracked 的链接目标**）。

**后续（不阻塞合并）**：R3D-08/11/12/13/14 与 §1-R3D-12 所列 round-2 未闭环 P3（CORE-01b 并发窗口、CORE-03 回归测试、DBStatementCache 零余量、regex 锁重入注释、MetadataDisposition 静默 catch、hygiene 头部自描述、write-baseline 缺 key、test.sh flag 注释、预载主照片无用读、GalleryRowCache 注释、round-4 §8 补 3 行等）。

**对 round-2 修复最优性的判断（抽出结论，细节见 §2/§4）**

- 门禁类修复方向正确、最小：docs-facts 从"全文子串"升级到"行首命令 + 非注释行 + `|| true` 拒绝"，是低成本高收益；剩余 fenced-block/step 级解析属加固而非必须。
- test-catalog 14959 是**精确**重钉（删 1 条即红），符合 ratchet 约定；`report-baseline`、docs/README 同步正确。
- hygiene BOM + `.gitignore` 文件面补齐后覆盖 1274/1277（3 个二进制合理排除），正常路径等价，无假阳性。
- protocol 基线采用了"保留说明性字段 + `--write-baseline` 更新值"的温和方案（未纳入比较），与"避免对注释行过度敏感"的取舍一致；代价是 `protocol_lines` 漂移仍不会被门禁发现，建议后续在 baseline note 标明"信息字段，不参与比较"。
- SidecarRegexCache 去 `T: Sendable` 在 Linux 复刻探针下编译+运行通过；Darwin 的 `NSRange` 隐式 Sendable 仍只能等 macOS CI（本机不可证）。
- MetadataKeywordWriter 逐行 fallback 只在 DB 级错误时触发（N≤500），语义恢复正确、无热路径成本；新增 `GatherLogger` 调用所在文件已有 import/使用，编译 plausibility 成立。

## 6. 覆盖与局限

- 覆盖：round-2 归档 6 份文件全文 + 三个修复提交全量 diff + round-1 归档修正行 + round-3/4 相关修正段 + README/docs/README/DEVELOPMENT/ROADMAP/test-runtime-audit/reviews 索引 + 14 个 scripts/baseline；实跑 16 门禁 + 5 strict、report-baseline、docs-facts、hygiene、11 组负向门禁探针 + 5 组编译级探针、git archive scratch 构建。
- **未验证/不可验证**：macOS 编译与运行时（AppKit/SwiftUI/CoreML）、`swift test`、`check-warnings`、UI/Instruments、Darwin `NSRange`/DateFormatter/JSONEncoder 标注；round-2 分册里数百条技术探针只做了抽样复跑（doc 一致性相关全查）；"17,295 次格式化 oracle 对拍"等分册工作量数字未独立复算。
- 结论层级：P0/P1 无新增；编译级结论来自真实 swiftc typecheck/build（本机）；门禁/数字结论来自仓库脚本实跑；涉及 macOS 行为的均显式标注。
