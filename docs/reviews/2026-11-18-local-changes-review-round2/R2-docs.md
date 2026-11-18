# R2-5 第二轮独立评审：评审归档准确性 / 文档一致性 / 修复最优性

- 评审人：review2-docs（task-35；第二轮独立评审，非任何改动作者；与第一轮 review-tooling 不同人）
- 评审对象：
  1. round-1 归档 `docs/reviews/2026-11-18-local-changes-review/**`（00-overview + R1–R5）；
  2. 三个修复提交 `6e940350`（code/tests）、`9be6a000`（gates/baselines）、`0288ea8d`（docs）；
  3. 全部 docs 事实声明（README / DEVELOPMENT / ROADMAP / test-runtime-audit / reviews/**）与
     当前代码、脚本、baseline 的一致性；
  4. 修复本身的正确性 / 完整性 / 最优性。
- 基线：HEAD = `0288ea8d`（19 commits / 226 files / +10432−961 vs origin/main e5c54f37；
  评审对象自身是 5ea5c38f 的 16 commits / 220 files）。**评审期间工作区另有并行 agent 的未提交
  修复**（截至本报告：DateFormatting.swift、CullingViewModel.swift、JSONValueCodingTests.swift
  三处，正是本文的 3 个 P0）。下文分别标注 **HEAD 状态** 与 **工作区状态**；我未修改任何
  tracked 文件，探针只在 `.gather/`。
- 环境与验证上限：Linux Ubuntu 22.04，无 macOS/Xcode。**未编译 AppKit/SwiftUI target、未跑
  `swift test`、未跑 macOS CI、无 Instruments/真机 UI**。本轮实际做了：`swiftc -parse`
  （168 改动 + 全仓 1090 个 Swift 文件均 0 失败）、**纯 Foundation 文件真实 `-typecheck`**
  （新利用点，直接抓到 P0）、Swift 6.2 语言规则探针、纯 Foundation target 的 SwiftPM build、
  16 道 Linux 门禁 + 5 个 `--strict` 复跑、`git archive` scratch 副本负向探针（docs-facts /
  protocol-surface / repo-hygiene）、`report-baseline.sh` 对账、逐文件 docs diff。
- 说明：round-1 归档与各审计文档一律当"待验证假设"；同轮并行文档（R2-app / R2-tests）只在
  结论一致处引用，不作证据。

## 0. 结论速览

| 级别 | 数量 | 说明 |
|---|---|---|
| **P0（编译中断）** | **3** | 全部由修复提交 `6e940350` 自身引入，HEAD 可复现：DateFormatting 多尾闭包标签 ×4 处（GatherUI，macOS build 必红）；Preload 跨文件访问 `private pageAssignmentCount`；JSONValueCodingTests `try` 在 `==` 右侧（GatherCoreTests 编译失败）。round-1 的"331/168 文件 parse 全过"验证方式查不出（parse ≠ typecheck）。工作区已有/正在出现三处最小修复。 |
| P1 | 0 | 未发现新的确定性行为回归（P0 已在更高级别）。 |
| **P2** | **2** | ① docs-facts 的 CI wiring 断言仍可被"注释掉 run 行"绕过（gate 可被静默停用而门禁仍绿）；② round-1 归档"全部已修（见 §2）"状态与 HEAD 不符（3/19 被 P0 推翻、2/19 只做一半），且验收只用 parse。 |
| **P3** | **17** | 归档 hash/协议基线/计数不实；docs/README、ROADMAP、round-4 总览三处 docs 事实仍与代码相反；test-catalog 断言基线仍差 4；oracle 弱化；CORE-01 预载浪费；docs-facts 小节级仍可绕；残余清单缺 before-merge 分层等。 |

一句话：**修复方向与 14/19 项实现正确、门禁全绿，但"已修复"结论被 3 个编译中断推翻；
"docs 已同步"只做了一半；归档本身另有 1 个不存在的 commit hash 与 1 条未发生的"协议基线已更新"。**

## 1. Findings

> 级别：P0=崩溃/数据丢失/编译中断/安全；P1=很可能正确性回归/CI 红；P2=风险/鲁棒性/最优性；
> P3=nit/文档一致性。"macOS 不可验证"= 结论是否依赖 macOS 才能成立。

### 1.1 P0（HEAD 可复现的编译中断，均由修复提交引入）

| ID | Sev | 位置（HEAD） | 问题 | 证据（实际跑过什么） | 建议修复 | Conf | macOS 不可验证? |
|---|---|---|---|---|---|---|---|
| **R2D-01** | **P0** | `desktop/native/gather-app/Sources/GatherUI/Support/DateFormatting.swift:59,77,108,120,132`（commit `6e940350`） | `withFormatter<T>(key:make:_ body:)` 第三参数**无外部标签**，4 处调用写 `... } body: { formatter in ... }`。Swift 规则：第 2+ 个 trailing closure 的标签必须匹配**外部参数标签**，`_ body` 无标签 ⇒ 每处 `error: extraneous argument label 'body:' in call`。GatherUI 是 macOS target 的依赖 ⇒ `swift build`/CI 必红。 | `git show HEAD:...DateFormatting.swift` 取 HEAD blob（该文件只 import Foundation，**Linux 可真实 typecheck**）→ `swiftc -typecheck -swift-version 6` 报 **4 error（77/108/120/132）**；另用最小片段单独复现同一错误。**工作区已有未提交的一行修复**（`_ body:`→`body:`），该版本 typecheck EXIT 0 —— 必须提交，否则 HEAD 不可编译。 | 采用工作区这一行（外部标签改为 `body`，调用处不用改）。round-1 §2#8 应改判"修坏、待复验"。 | 高（语言规则与平台无关） | 否 |
| **R2D-02** | **P0** | `CullingViewModel+Preload.swift:188,196` vs `CullingViewModel.swift:156`（commit `6e940350`） | 新加过期守卫读取 `@ObservationIgnored private var pageAssignmentCount`。Swift `private` 是**文件作用域**，`+Preload.swift` 在另一文件 ⇒ `error: 'pageAssignmentCount' is inaccessible due to 'private' protection level` ×2。 | 两文件最小探针复现同一错误；`grep` 确认全仓只有 CullingViewModel.swift:156 一处声明、+Preload.swift:188/196 两处使用；该文件依赖 SwiftUI 无法 Linux typecheck，但访问级别是语言规则，确定。**工作区已有未提交修复**（去掉 `private`，改 internal + 注释）。 | 采纳工作区修复（internal，仍 `@ObservationIgnored`，不引入 Observation 依赖）。round-1 §2#10 应改判。 | 高 | 否 |
| **R2D-03** | **P0** | `desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift:128`（commit `6e940350`） | `#expect(try JSONValue.parse(json) == try JSONValue.parse(baseline), ...)`：Swift 禁止 `try` 出现在非赋值运算符右侧 ⇒ `error: 'try' cannot appear to the right of a non-assignment operator`；`GatherCoreTests` 整个 test target 编译失败（ci.yml 会跑 `swift test --package-path desktop/native/gather-core`）。 | 最小片段 probe 复现同一错误；同轮 review2-tests 用真实 GatherProtocol + Swift Testing harness 独立复现（PRE_FIX_BUILD_RC=0 / FIXED_BUILD_RC=1），结论一致；`git diff` 确认该行由修复提交新增。**工作区已有未提交修复**（先绑定 `let parsedJSON/parsedBaseline`）。 | 采纳工作区修复；修后必须 macOS `swift test`（至少 `--filter JSONValueCodingTests`）。round-1 §2#3 应改判。 | 高（跨平台语法规则） | 否 |

> 共同教训：三处都是**类型/标签/访问级别/运算符规则**错误，`swiftc -parse` 只做语法解析，
> 天然拦不住；其中 R2D-01 的文件是纯 Foundation，本可在 Linux 用 `-typecheck` 拦下。
> 建议把"纯 Foundation 源文件 Linux `-typecheck`（+ 可编译 target 的 `swift build`）"写进
> 修复验收清单，而不是"parse 全过"。

### 1.2 P2

| ID | Sev | 位置 | 问题 | 证据 | 建议修复 | Conf | macOS 不可验证? |
|---|---|---|---|---|---|---|---|
| **R2D-04** | **P2** | `scripts/check-docs-facts.sh:389-403`（R4-F2 修复） | CI wiring 断言只是 `('./scripts/'+name) not in ci_text` 的**全文子串**匹配：把真实 step 注释掉（`# run: ./scripts/check-repo-hygiene.sh`）后，门禁仍打印"CI 已接入全部 17 个门禁脚本"并 rc=0 ⇒ "防止步骤被悄悄删掉"的目标只覆盖"删除"，不覆盖"注释停用"。 | scratch 副本（`git archive HEAD` + 独立 git 仓库）：把 ci.yml 的 `run: ./scripts/check-repo-hygiene.sh` 改为注释 → `check-docs-facts.sh` **rc=0，输出 ok CI 已接入全部 17**。对照：原 R4-F2 探针（整段删除 step）现在确实 FAIL（修复对"删除"有效）。 | CI 侧按 YAML 解析 step 的 `run:` 行（或至少 `grep '^\s*run: \./scripts/'`），不接受注释行；再断言集合相等。 | 高 | 否 |
| **R2D-05** | **P2** | `00-overview.md:12-19,25-43`（"全部已修（见 §2）"）+ §4 验证 | 归档把 19 项全部标为已修，但 HEAD 上 3 项（#3/#8/#10）是被修复提交自己**弄成编译中断**、2 项（#18/#19）只做一半（见 §2）。§4 的"验证"只有 parse/门禁，未做任何 typecheck/编译，故与"已修"结论不匹配；归档对这一验证天花板只在 §3 第 1 条笼统提"需 macOS 首跑"。 | §2 与 §4 逐条对照 + 本文 P0 + §2 映射表。 | 把 §2 状态改为"已修（待 macOS 编译/测试复验）"并明确列出 3 个由修复引入的编译中断；§4 补"parse 不是类型检查"的边界。 | 高 | 否 |

### 1.3 P3（归档 / docs 事实 / 门禁残余）

| ID | Sev | 位置 | 问题 | 证据 | 建议修复 | Conf |
|---|---|---|---|---|---|---|
| R2D-06 | P3 | `00-overview.md:21` | 写"修复提交：`6e940350`、`9be6a000`、**`33ef7313`**（本轮评审归档与文档修正）"，但 `33ef7313` **不在任何分支上**（dangling 早期版本：overview 72 行 vs 现 74 行、1085 vs 1087 insertions），真实 docs 提交是 `0288ea8d`。 | `git cat-file -t 33ef7313`=commit；`git branch -a --contains` 空；`git log --all` 无；`git show --stat` 与 `0288ea8d` 同标题少 2 行。 | 改为 `0288ea8d`（或最终提交后回填）。 | 高 |
| R2D-07 | P3 | `00-overview.md:54 §3.8` + `§2 #18`（"protocol 基线说明性字段更新"）；`docs/protocol-surface-baseline.json:5` | 归档称 `protocol_lines`（17177→17192）"本轮仅更新文件"，但 **baseline 文件根本没更新**（仍 17177）；`git log -- docs/protocol-surface-baseline.json` 最后一次改动是上游 `e5c54f37`，三个修复提交的 stat 都没有它。同时 `check-protocol-surface.sh:245-248` 只 compare 4 个指标，F9 的两种建议（纳入比较/删除字段）都未落地。 | 读文件 + `git log` + `git show 9be6a000 --stat`；`--strict` 实测 `Protocol 文件/行 111 / 17192` vs baseline 17177；`compare_metric` 只有 public_types/public_declarations/zero_reference/router_envelope。 | 更新 baseline 为 17192 并在 note 标"信息字段"，或删字段；归档 §3.8 按实际改写。 | 高 |
| R2D-08 | P3 | `docs/README.md:47` | 同节标题已改为"2026-11-18 四轮加固后采样"，但正文仍写"合计 3,267 / 419，**均不低于基线 2,502 / 283**"——当前 ratchet baseline 已重钉为 **3267 / 419**。docs 与门禁自相矛盾，docs-facts 不校验此句。 | 读 docs/README:46-47；`check-test-catalog.sh:372-373` = 3267/419；`--strict` 输出 `@Test 3267/3267 · @Suite 419/419`。 | 改为"等于当前 ratchet 基线 3,267 / 419"。 | 高 |
| R2D-09 | P3 | `docs/ROADMAP.md:44` | "当前状态"段仍写"关闭前 best-effort `PRAGMA optimize`"，但代码已移除（CORE-02）；DEVELOPMENT 与 round-4 总览均已修正，`0288ea8d` 只改了 ROADMAP 第 3 行。 | 读 ROADMAP:43-44；`git show 0288ea8d -- docs/ROADMAP.md` 仅 2 行；`Database.close()` 无 optimize。 | 改为"评审后移除（见 DEVELOPMENT/round-4 总览）"。 | 高 |
| R2D-10 | P3 | `docs/reviews/2026-11-18-round4-perf/00-overview.md:83 §8.1` | 同一文档 §1/§3 已标注 optimize 移除，§8.1"未编译/未运行：**mmap/optimize**、prepare 复用…"仍把 optimize 当现存代码待验证（文档内自相矛盾）。 | 读 §8.1；`git show 0288ea8d` 对 round-4 overview 只改 §1/§3。 | §8.1 删 optimize 或注明"已移除，无需验证"。 | 高 |
| R2D-11 | P3 | `scripts/check-test-catalog.sh:486` + `00-overview.md:38` | 断言 ratchet baseline=14954，但实测/报告都是 **14958**：修复提交在 baseline 落盘前又新增 4 条 `#expect`（JSONValueCodingTests +2、ReviewFixTests +2），baseline 取的却是修复前值 ⇒ 仍可静默删 4 条断言；归档"重钉到**实测** 3267/419/14954"不准确。 | `--strict` → `断言 14958/14954`；`report-baseline.sh` → 合计 14958；`git show 6e940350` 新增 4 处 #expect。@Test/@Suite 已精确相等。 | `BASELINE_ASSERT` 改 14958（修完 P0 后按当时实测重钉）并记账；归档同步。 | 高 |
| R2D-12 | P3 | `docs/reviews/2026-11-17-round2-hardening/perf-core-round2.md:50-52`（`0288ea8d` 修正段） | 修正段写"`touched*` 集合仅保留给变体判定注释口径"，但最终提交已把 `touchedPhotoIds/touchedAssetIds/needsLiveRead` **整体删除**（grep 0 命中）；同段"批量快照与实时读**同义**"与归档 §3.7 的 CORE-01b 残余（并发写者可在批次窗口提交 manual 决策而被 imported 覆盖）互相矛盾。 | `grep -rn 'touchedPhotoIds|touchedAssetIds|needsLiveRead'` = 0；读当前 `CullingService+Commands.swift` 变体判定仍读 `preloadedDecisions`；对照 00-overview:53。 | 改为"touched* 已删除；变体判定仍读批前快照（残余 CORE-01b，窗口=整批）"。 | 高 |
| R2D-13 | P3 | `scripts/check-docs-facts.sh:372-390`（R4-F1 修复） | 门禁清单只查 `## 门禁` 小节内的**子串**：把小节内该行改成注释 `# ./scripts/check-layering.sh`，或删掉行但在小节正文（非代码块）写一句 `> 旧注：./scripts/check-layering.sh …`，都仍然 PASS。 | scratch 探针：注释化 → rc=0；删行+小节内正文提及 → rc=0；对照原 R4-F1 案例（删行+文末提及，小节外）→ 现在 FAIL（修复对该案例有效）。 | 解析 fenced code block 内行首 `./scripts/<name>` 集合（或机读清单），拒绝注释行/正文提及。 | 高 |
| R2D-14 | P3 | `scripts/check-repo-hygiene.sh:179-192`（R4-F3 修复） | `[b]` 文件面扩展已基本覆盖 tracked 文本文件：实算 1271 tracked 中只有 5 个未覆盖——2 个 `.gitignore`（文本）与 3 个二进制（`.icns/.mlmodel/.bin`，本就不该按 UTF-8 检查）。残余：BOM 仍不被拒绝（R4-F18 未修）；`.gitignore` 的 CRLF/BOM 不会被抓。 | `git ls-files` 扩展比对；scratch 探针：docs/README 加 BOM → hygiene rc=0；`.gitignore` 写 CRLF → rc=0。 | 补 `BOM_UTF8` 检查（messages 指向 `.editorconfig charset=utf-8`）；把 `.gitignore` 纳入或说明排除理由。 | 高 |
| R2D-15 | P3 | `docs/reviews/README.md:12-21` | 索引已补 round-1 行，但**没有任何 round-2 目录的占位/条目**（本轮 6 份 docs 已实际创建）。按该文件自己的约定"尚未创建的轮次先以纯文本占位"，收尾必须补行；且 hygiene [c] 只认 tracked 链接目标，docs 需 `git add`。 | `ls docs/reviews/2026-11-18-local-changes-review-round2/` 有文件；`grep round2 docs/reviews/README.md` = 0。 | 浏览器轮收尾加一行（先纯文本→tracked 后改链接）并跑 hygiene。 | 高 |
| R2D-16 | P3 | `JSONValueCodingTests.swift:48-70` + `test-hygiene-round2.md:80-84` | 修复把对象比较降级为"解析后值等价"，消除了 Foundation 键序 flake，但**失去对共享 encoder 配置漂移（`.sortedKeys/.prettyPrinted`）的检测**：对象只比值、配置改动不改解码值；round-1 建议的"两侧都加 `.sortedKeys` 再比字节"未被采用，而修正后的 test-hygiene 文档仍写"防 .sortedKeys/.prettyPrinted 配置漂移"（对对象不成立）。 | 读测试 48-70/116-130：对象分支 `continue` 跳字节比较；roundTrip 只比解析值；`grep sortedKeys` 测试内 0 命中。 | 对象值改"两侧同加 `.sortedKeys` 后字节相等"，保留漂移检测；文档句改准确。 | 高 |
| R2D-17 | P3 | `Database.swift` close 注释 + `docs/DEVELOPMENT.md:284-285` + round-4 docs | 移除 optimize 后写"需要刷新统计走**显式维护任务**"，但仓库不存在这样的维护任务/API（`grep ANALYZE/optimize` 在 Sources 只有该注释自身；Maintenance 服务无实现）。描述了一个不存在的兜底。 | `grep -rn 'ANALYZE|optimize' desktop/native --include='*.swift'`；Maintenance 目录无相关入口。 | 改为"依赖 SQLite 自动 ANALYZE 覆盖常规场景；如需手动刷新后续再加"，或真的加维护 API。 | 中 |
| R2D-18 | P3 | `CullingService+Commands.swift:413-436,447-452`（CORE-01 修复后） | 批量预载仍把**所有勾选照片自身**的决策行读进 `preloadedDecisions`，但主照片现在每张都实时 `getDecision`，批量结果只用于"同资产变体人工保护"；单变体照片（常见）的预载行**读而不用** ⇒ 每批多一次含 N 行的 IN 查询。归档 §2#5 与修正文档说"批量收益保留在变体预载"，表述不准确（预载仍含主照片 ID）。 | 读 :419-436（preloadIds 先插 photoId 再插变体）与 :447-452（只有 `variant.id != photoId` 才消费）；单变体时无消费者。 | `preloadIds` 只收集变体 ID（photoId 自身反正要实时读），或对无变体批次跳过批量查询；同步 docs。 | 高 |
| R2D-19 | P3 | `GalleryGrid.swift:43-51`（R2-A0 修复） | 线性回退救回了既有测试的 CI 红，但**改变了 API 注释承诺的语义**："缓存为空（首帧/筛选刚变更）返回 nil"——现在只要 `rows` 非空、映射为空就返回行号（生产 store 同时写两者，故实际不可达；未来"直接写 rows"的路径会把空映射 bug 掩盖成慢路径）。 | 读 :43-51 与测试 :172-198；`grep` 只有该测试直接写 `cache.rows`。 | 注释改为准确表述（"映射未命中时回退线性扫"），或生产/测试统一走 `store`。 | 高 |
| R2D-20 | P3 | `00-overview.md §3（:45-54）` | 残余清单缺"before-merge / later"分层，且漏收 round-1 的明确残余：R3-T02（4 个 formatter 缓存 0 测试，实测仍 0 命中：`fileSize/internetDateTimeString/parseFixedUTC/formatFixedUTC`）、R3-T06、R3-T07、R3-T08、R3-T10/T11/T12、R4-F15（cleanup-backlog 旧指标）、R4-F16/F17/F18/F19/F20/F21/F23/F25/F26、R5-17/18/19/21；§3 第 3 条还把已修的 F2 列为残余。 | 对照 R3 §2、R4 §1、R5 §1 与 §3 逐条编号；`grep -c fileSize/internetDateTimeString/parseFixedUTC/formatFixedUTC Tests/GatherAppTests/DisplayDateFormattersTests.swift` = 0。 | §3 拆"合并前必须"与"后续"，按 finding ID 全量登记（见 §5）。 | 高 |
| R2D-21 | P3 | `docs/reviews/2026-11-18-round4-perf/00-overview.md §8` + `00-overview.md §3` | R5-21 建议的 round-4 总览 §8 补三行（gallery pages/loadedPhotos 长会话无上限、控制中心 jobs 全量的未解决项、Observation 依赖 checklist、JSON 键序/停机取消语义）未落地：§8 仍是旧 5 条，round-1 §3 也未收。 | 读 round4 overview §8；`0288ea8d` 对该文件只改 §1/§3；`grep 'Observation' round4/00-overview.md` 0 命中。 | 收尾补 §8 并在 round-1 §3 引用。 | 高 |
| R2D-22 | P3 | `00-overview.md:74` 的“分册是修复前快照”caveat vs R1 §5 / R3 / R5 头部 | caveat 说“文中 file:line/结论对应修复前 HEAD”，但 ① R1 §5 整节是**修复后工作区**的二次复核（自述“工作区不再等于评审基线”）；② R3/R5 头部只写“16 commits/220 files”、未写快照 HEAD `5ea5c38f`，脱离 overview 单读分册时无法自证 line ref 属于旧快照（R1/R2/R4 头部有写）。 | 读各分册头部与 00-overview:74；R1:97-101 自述。 | caveat 改为“R1 §5 例外（修复后工作区）”；给 R3/R5 头部补“评审基线 HEAD 5ea5c38f（修复前快照）”。 | 高 |

## 2. round-1 归档"19 项已修复"逐项复核

> 复核方式：`git show 6e940350` / `9be6a000` 全量 diff + 当前代码上下文 + 门禁实跑 + 探针。
> 结论：**14 项成立 / 3 项被 P0 推翻（#3、#8、#10）/ 2 项只做一半（#18、#19）**。

| # | 声称修复 | 复核 | 依据 |
|---|---|---|---|
| 1 | navigationGroupSizeByPhotoID 命中路径无条件读 count；similarGroupAssets 防御读 page | ✅ | 代码 :235 `_ = navigationGroups.count`、:254 `_ = page?.assets.count`；与 R5-01/R2-A1 的 Observation 结论一致。 |
| 2 | GalleryLayoutCache.rowIndex 未命中回退线性扫 | ✅（语义见 R2D-19） | 代码 :45-50；测试 :193-196 可过（映射空→线性扫）。 |
| 3 | JSONValueCodingTests 改值等价 oracle | ❌ 被 P0 推翻 | `try` 在 `==` 右侧 → core 测试 target 编译失败（R2D-03）。 |
| 4 | LightboxView 命中后校验 `photos[index].id == currentID` | ✅ | 代码 :56-63；线性回退仍在。 |
| 5 | applyImportedPicks 未触碰照片恢复实时 getDecision | ✅（残余 CORE-01b 仍在，见 R2D-12/18） | 代码 :440-445 每张实时读；touched* 已删；变体判定仍读批前快照。 |
| 6 | 移除 close 的 PRAGMA optimize | ✅（docs 见 R2D-09/10/17） | `Database.swift:326-337` 仅 `connection.close()`。 |
| 7 | LegacyWallDateParsers 改 Mutex 锁盒子 | ✅ | 代码 :489-516；Linux Swift 6.2 `-strict-concurrency=complete -warnings-as-errors` typecheck 通过（锁内惰性创建+解析；无新 @unchecked Sendable）。 |
| 8 | DisplayDateFormatters 持锁格式化 + mediumShort 键补 calendar/timeZone | ❌ 被 P0 推翻 | 持锁/键修复本身正确（R3-T03 的 key 缺口确实补上），但 `_ body:` 标签导致 GatherUI 编译失败（R2D-01）；工作区一行修复后正确。 |
| 9 | writeTerminal 用 detached 任务等满 200ms | ✅（成本见 §4.3） | `JobService+Settle.swift:210-220`；detached 不受父取消影响，`await .value` 等满；新增 1 个 `try?`（cleanup 257/257 自洽）。 |
| 10 | runNeighborPreload await 后校验页代数/当前照片 | ❌ 被 P0 推翻 | 校验逻辑正确，但 `pageAssignmentCount` 跨文件 private（R2D-02）；另 detached 探测本身不可取消（残余见 §4.4）。 |
| 11 | ReviewFixTests 负向窗口前正向等 waiterStarted | ✅ | 代码 :1069-1105；两处均先等 `waiterStarted`。 |
| 12 | A14/A10/A11/A6（page.didSet 清 keyword 索引、packedSize clamp、id 集合复用、prune 先判 isEnabled） | ✅ | CullingViewModel:51、CullingGrid:298-302、GalleryViewModel+Derived:78-82（`loadedPhotosAndIDs` 与旧 `loadedPhotos` 同源，无语义差）、ThumbnailDiskCache:50-58。 |
| 13 | DBStatementCache 记录 owner + DEBUG 断言 | ✅（release 仍无检查，见 §4.6） | 代码 :31-53。 |
| 14 | test-catalog 三基线 2502/283/11509 → 3267/419/14954 | ⚠️ 部分 | #Test/#Suite 精确（3267/3267、419/419）；断言差 4（R2D-11）。 |
| 15 | check-protocol-surface xargs → while read + 扫描量下限 | ✅ | 新脚本对含单引号路径 rc=1 且输出干净 ratchet diff（515>514），旧脚本（5ea5c38f）同一探针 rc=1、stdout 空、stderr `xargs: unmatched single quote`；无 proto 文件时新脚本 rc=2 `FAIL 扫描量异常`。 |
| 16 | hygiene [b] 文件面扩展 | ✅（基本完成；残余见 R2D-14） | 实算仅 5/1271 未覆盖（2 个 .gitignore 文本 + 3 个二进制）。 |
| 17 | docs-facts 只查 `## 门禁` 小节 + CI wiring 断言 | ⚠️ 部分 | 原 F1/F2 案例已 FAIL（有效）；但小节内注释/正文提及、CI 注释停用仍 PASS（R2D-04/13）。 |
| 18 | design-system 10→6；cleanup try_optional 钉 257；.gitattributes perf-baseline；protocol 基线说明性字段更新 | ⚠️ 部分 | contentUnavailable 6/6 ✅、try_optional 257/257 ✅、.gitattributes +1 ✅；**protocol 基线未更新（R2D-07）**。 |
| 19 | docs 漂移修正（JSON 字节/close optimize/test-catalog/NSCache/采样日期/轮次/9 指标/report-baseline） | ⚠️ 部分 | JSON 字节 ✅（round2 概述 + test-hygiene）、close optimize ✅（DEVELOPMENT + round-4 §1/§3 + perf-db4）、NSCache ✅（round-3 perf-runtime）、采样日期/轮次 ✅（docs/README:43、ROADMAP:3）、9 指标/report 9 项 ✅（gates-round4）；**README 测试基线、ROADMAP:44、round-4 §8 仍错（R2D-08/09/10）**。 |

## 3. docs 事实一致性核对

| 声明 | 位置 | 独立核对 | 结论 |
|---|---|---|---|
| 17 道门禁 / CI 全接入 | docs/DEVELOPMENT §门禁、docs/README:51、docs-facts | `ls scripts/check-*.sh`=18 − appintents=17；docs-facts 实测"CI 已接入全部 17" | ✅（但见 R2D-04） |
| 9 功能 target / 18 total / 16 API / 195 方法 | docs/README:45、ROADMAP:36、docs-facts | `report-baseline.sh` 同数 | ✅ |
| schema 55 表/451 列/86 索引/81 外键 | README/ROADMAP/docs-facts | report-baseline 实测 + cross-check | ✅ |
| en 2682 / zh 9 键 | docs/README:55 | report-baseline 同数 | ✅ |
| perf ratchet 9 指标 + baseline | docs/DEVELOPMENT:264-275、gates-round4、perf-baseline.json | 9 指标 current==baseline；report 9 行 | ✅ |
| JSON"逐字节"→值等价 | round2 overview:59、test-hygiene-round2:77-85、测试文件头 | 三处已改；但 test-hygiene 仍称防 .sortedKeys 漂移（R2D-16） | ⚠️ |
| close 时 optimize 已移除 | DEVELOPMENT:283-285、round4 §1/§3、perf-db4 | 已改；ROADMAP:44、round4 §8 残留（R2D-09/10） | ⚠️ |
| test-catalog 基线 3267/419/14954 | 00-overview:38、check-test-catalog 注释 | 断言实测 14958（R2D-11）；docs/README:47 仍写 2502/283（R2D-08） | ⚠️ |
| protocol_lines 17177→17192 | 00-overview:54 | baseline 未更新（R2D-07） | ❌ |
| 9 项 report-baseline | round4 gates-round4 §4/§5 | 已改成 9 项 | ✅ |
| NSCache 淘汰悬崖未实测 | round3 perf-runtime R3 行 | 已补注 | ✅ |
| 采样日期/轮次措辞 | docs/README:43、ROADMAP:3 | 已改 | ✅ |
| docs/reviews 索引 | docs/reviews/README.md | round-1 已入索引；round-2 未入（R2D-15） | ⚠️ |
| 归档自身验证声明 | 00-overview §4 | 168 文件 parse 0 失败（复跑 ✅）、全仓 1090 文件 parse 0 失败（复跑 ✅）、两个 manifest ✅、GatherProtocol/GatherPreviewData Linux build rc=0（复跑 ✅）、16/17 门禁全 PASS（复跑 ✅）、`git diff --check` 干净（复跑 ✅）；但 parse≠编译（3 P0） | ⚠️ |

## 4. 修复最优性评估

### 4.1 移除 close 时 `PRAGMA optimize`（vs opt-in / 后台选项）
- **移除是合理的最小修复**：opt-in 要改 `Database.Options` 与所有调用点、后台执行又与 close 幂等/`stateLock` 语义纠缠；收益本身≈0（SQLite 自动 ANALYZE 覆盖常规场景），代价只是"不再定期刷新统计"。
- 残余：注释/文档说"走显式维护任务"，但该任务不存在（R2D-17）→ 建议改措辞而非本轮加 API。

### 4.2 DateFormatter 持锁格式化的串行化成本
- **可接受**。临界区 O(µs)；同锁还覆盖 fileSize/ISO/fixedUTC，但旧实现每次调用新建 formatter（O(10–100µs)×调用数），持锁版在调用密集路径（500 行元数据批次）仍明显更快；本文件锁内只有 `formatter.string`，无回调/重入 → 无死锁路径。
- 需 macOS 量化：若后台渲染线程与主线程并发调用，争用是否影响首帧；Linux 无法测。出现可观测回归再按 key 分锁，不建议本轮加复杂度。

### 4.3 detached 200ms 等待
- **语义恢复正确、成本可忽略**：detached 任务内 sleep 不继承父取消，`await .value` 严格等满 200ms（=旧 `Thread.sleep`）；只在"DB 写失败"罕见路径多一次 task 分配，不占线程池；停机路径最多晚 200ms 清理 activeRuns（R1 CORE-10 已记录）。
- 副作用：`try?` 让 cleanup `try_optional` 从 256 回到 257（与既有 baseline 相等）；round-4 文档已如实记录，属"指标自洽"而非收紧，可接受。

### 4.4 其他取舍（每项换到了什么风险）
- **JSON oracle 值等价**：消除 flake ✅，但丢失对象配置漂移检测（R2D-16）→ `.sortedKeys` 双侧字节比较只需 3 行，建议做。
- **CORE-01 恢复逐张实时读**：正确性恢复 ✅，但 N+1 从 ~2 次回到 ~N 次（500 张≈500 次点查），且预载主照片行读而不用（R2D-18）→ 只收集变体 ID 可把浪费降到 0。
- **preload detached 探测**：await 后校验 ✅，但 detached 任务本身不可取消（父页切换后旧计划仍会 stat/读盘）；R5-06 建议的 `Task`+取消检查更彻底。当前修复只保证"结果不消费"，浪费仍在（残余，非回归）。
- **Gallery rowIndex 线性回退**：救 CI ✅，但 nil 语义放松（R2D-19）。
- **test-catalog 基线收紧**：删用例保护生效 ✅；维护成本（合法删用例必须改 baseline+记账）符合本仓 ratchet 约定，可接受；断言差 4 说明"按实测重钉"流程还需精确化。
- **DBStatementCache owner 断言**：DEBUG 拦截 ✅ / release 仍静默复用（R1 已知）→ 若想彻底可 `precondition` 或按 `(connection, sql)` 键；当前 17 调用点全同连接，保守修复可接受。

## 5. 残余清单完整性（before-merge vs later）

round-1 §3 现列 8 条，全部写"后续"，**没有 before-merge 分层**，且漏项较多（R2D-20/21）。建议改为：

**合并前必须（阻塞）**
1. 提交工作区三处 P0 最小修复（DateFormatting `body:` / pageAssignmentCount internal / JSON 测试先绑定再断言），并跑 macOS `swift build` + `swift test`（core/app，至少受影响 filter）——这是本轮唯一真正的"未知区"。
2. 修正归档事实：`33ef7313`→`0288ea8d`（R2D-06）；§2#18/§3.8 协议基线（R2D-07）；§2#14 "实测 14954"→14958（R2D-11）；perf-core-round2 的 touched*/同义句（R2D-12）；§4 验证边界（R2D-05）。
3. docs 同步三处：docs/README:47（R2D-08）、ROADMAP:44（R2D-09）、round-4 §8.1（R2D-10）；docs/reviews/README 加 round-2 行并 tracked（R2D-15）。
4. `BASELINE_ASSERT` 精确重钉 14958（R2D-11）；protocol baseline 17177→17192 或删字段（R2D-07）。
5. 若保留 CI wiring 修复：改成 step 级解析（R2D-04）。

**后续（不阻塞）**
- CORE-01b（变体并发窗口）与预载过滤优化（R2D-18）；CORE-03 测试缺口 + R3-T02 四个 formatter 测试 + R3-T03 环境变化 oracle。
- docs-facts/hygiene 加固：F4/F5/F16/F17/F18/F19/F20/F21/F23/F25/F26；cleanup-backlog 9 指标（F15）；test-runtime-audit suite 口径（R3-T12）。
- R5-17/18/19/21（perf-baseline notes、ratchet 盲区、gap key、round-4 残余补充）；R3-T06/T07/T08/T09/T10/T11；NSCache 淘汰悬崖真机实测；启动计时标签；shellcheck pin/actionlint。

## 6. Verified OK（我独立验证通过的部分）

**修复项（对应 §2）**
- #1 Observation 依赖补读、#2 rowIndex 回退、#4 Lightbox 身份校验、#5 applyImportedPicks 实时读、#6 optimize 移除、#7 Mutex DateFormatter、#9 detached 200ms、#11 ReviewFix 正向等待、#12 四项 P3 加固、#13 DBStatementCache owner、#15 protocol-surface 修复（旧脚本 xargs 失败 vs 新脚本干净 FAIL）、#16 hygiene 文件面（5/1271 未覆盖）、#14 @Test/@Suite 精确。
- 额外验证到位的 round-1 修复：R3-T03 的 `mediumShort` 键缺口确实补上（`environmentKey` 含 calendar/timeZone）；R3-T04 的 false-green 已加正向等待；R5-04 取消语义恢复。
- 修复引入的非预期副作用已被工作区并行修复覆盖（截至本报告 3 个文件 modified，均未提交）。

**门禁与事实（实跑）**
- 16 道 Linux 门禁全 PASS；5 个 `--strict` 全 PASS；hygiene 7/7 PASS；docs-facts PASS；perf ratchet 9 指标 current==baseline；cleanup 9 指标 257/257 等；design-system contentUnavailable 6/6。
- `report-baseline.sh`：targets 18（functional 9）/ API 16/195 / @Test 3267 / @Suite 419 / 断言 14958 / en 2682 / zh-Hans 9 / schema 55-451-86-81 / 门禁 17 / perf 9 指标。
- `swiftc -parse` 168 个改动 Swift 文件 0 失败；全仓 1090 个 tracked Swift 文件 0 失败；`swift package dump-package` core/app rc=0；`swift build --target GatherProtocol` rc=0（11.56s）、`swift build --target GatherPreviewData` rc=0（4.81s）——归档 §4 的 manifest/可移植 target 声明全部成立；`git diff --check origin/main..HEAD` 干净。

**docs 修正（对应 R2D-08/09/10 之外）**
- 9 指标：DEVELOPMENT 性能节、gates-round4 §1/§4/§5、report-baseline 输出三处一致 ✅。
- JSON 字节降级：round2 overview:59、test-hygiene-round2:77-85、测试文件头 ✅（口径问题见 R2D-16）。
- close optimize：DEVELOPMENT:283-285、round4 §1/§3、perf-db4 §3 ✅。
- NSCache：round3 perf-runtime R3 行 ✅。
- 采样日期/轮次：docs/README:43、ROADMAP:3 ✅。

## 7. 覆盖与局限

- 覆盖：round-1 归档 6 份文档全文/关键表；3 个修复提交全量 diff（16+7+17 文件）；docs/README、
  DEVELOPMENT（性能/门禁节）、ROADMAP、docs/reviews/README、round-1..4 相关修正文档；
  scripts（docs-facts/hygiene/test-catalog/protocol-surface/perf-ratchet/report-baseline）与 4 个
  baseline；`git archive` scratch 负向探针 6 组。
- 未覆盖/不能验证：macOS 编译（AppKit/SwiftUI target、`swift test`、check-warnings、UI 运行时、
  Instruments、NSCache 淘汰、DateFormatter 真实并发、SQLite 真机耗时）；R1–R5 分册的逐条技术探针
  （各自分册已记录，我只复跑结论级与 docs 一致性）；评审期间并行 agent 的未提交工作（我只标注
  状态，未审其质量）。
- 结论层级：P0 是编译器实证；docs/数字是脚本实跑；性能/并发取舍是静态推理 + Linux 探针，标注了
  需 macOS 复验。

## 8. 附：关键证据（可复现）

```text
# P0-01（HEAD blob 真实 typecheck；DateFormatting.swift 只 import Foundation）
git show HEAD:desktop/native/gather-app/Sources/GatherUI/Support/DateFormatting.swift > .gather/.../DateFormatting.swift
swiftc -typecheck -swift-version 6 DateFormatting.swift
→ error: extraneous argument label 'body:' in call ×4（77/108/120/132）
# 工作区版本（body:）→ typecheck EXIT 0

# P0-02（跨文件 private）
最小两文件探针 → error: 'pageAssignmentCount' is inaccessible due to 'private' protection level
# P0-03（try 在 == 右侧）→ error: 'try' cannot appear to the right of a non-assignment operator

# scratch 负向探针（.gather/r2docs-scratch/repo，git archive HEAD + 独立 git 仓库）
docs-facts：删门禁行+文末提及（原 F1 案例）→ rc=1 FAIL（修复有效）
docs-facts：小节内注释化 → rc=0 PASS；删行+小节内正文提及 → rc=0 PASS（残余，R2D-13）
docs-facts：ci.yml 注释掉 run: ./scripts/check-repo-hygiene.sh → rc=0 PASS（残余，R2D-04）
protocol-surface：O'Brien 路径新 public 类型 → rc=1、干净输出 public_types=515>514（旧脚本 rc=1 无 stdout + xargs 错）
protocol-surface：删空 proto swift 文件 → rc=2 "FAIL 扫描量异常：proto_file_n=0 public_types=0"
hygiene：docs/README 加 BOM → rc=0（F18 残余）；.gitignore CRLF → rc=0（文件面残余）

# 门禁与事实
16 道 Linux 门禁 + 5 --strict → 全 PASS；report-baseline 数字见 §6
168 个改动 Swift 文件 -parse → 0 失败；全仓 1090 个 tracked Swift 文件 -parse → 0 失败
swift build GatherProtocol → rc=0；swift build GatherPreviewData → rc=0
git diff --check origin/main..HEAD → 干净
```
