# 文档一致性最终扫尾（只读静态审计）

> 审计对象：`/Users/panzeyu2013/Desktop/code/develop/Gather`，审计开始时 HEAD `ab7752e`，工作区干净。
> 方式：只读静态核对；**未运行 build / test / 任何门禁脚本**，也未修改源码、脚本或其他文档。审计期间并行代理改动了若干 Delivery 文件（读取时 4 个）并新增 3 份 `final-sweep-{code,data,release}.md`；本报告不纳入这些并行改动，静态计数以本次读取时点为准。
> 并行修复提示：审计期间并行代理已修改 `docs/README.md`、`docs/DEVELOPMENT.md`（截至最后一次读取），其中 P1-1 的计数/迁移链、P1-4 的 protocol 门禁、P1-5 的 SchemaV2 文案已部分/全部修复；本报告行号与判定以 **HEAD ab7752e** 为准，集成时请用 `git diff` 复核工作区是否已覆盖。
> 数字口径：以 `architecture-remediation-status.md` §2、`refactor-progress.md` 顶部、`refactor-decisions.md` D-172 为“当前文档口径”；代码/基线的静态事实来自 `Schema.swift`、`SchemaV1.swift`、`Protocol-surface-baseline.json`、`cleanup-baseline.json`、`Package.swift` 与 git 元数据。测试数字未复跑，不能据此证明实际测试结果；本文只判断文档之间是否自洽。

## 0. 结论

**不通过：当前文档仍有发布口径级矛盾。** P0 = 2（均为 `final-report.md`：最终指标与仓库状态写反），P1 = 8（当前入口文档的版本/门禁/索引/路径/指标过期），P2 = 8（历史快照标识、计数尾差、决策编号）。核心原因不是事实缺证据，而是同一事实存在多个“当前口径”，且 `check-docs.sh` 只查 ADR 反引号路径、当前文档 md 链接、reviews 数量与 ADR schema 数字，不查 target 数、测试数、user_version 文案、提交状态，因此这些矛盾可以全绿通过。

当前权威值（仅按文档口径，非实测）：core **1,144/171**、app **617/68**、ratchet **54/230/0/0/0**、protocol **254/1,339/0/0**、schema **43/373/69/62/user_version=2**、8 个功能 target、9 道门禁、`origin/refactor..HEAD` **50** 个提交。旧值仍大面积出现在“最终报告”、ROADMAP 当前状态、docs README 当前基线、历史收尾报告中。

## 0.1 数字对账矩阵（只读静态）

> “旧值”不自动等于错误：已明确标注“Cut 6c/df73880 快照”的可保留；下表“判定”指该值是否仍被放在“当前/最终”口径中。

| 指标 | 当前文档口径（来源） | 仍写旧数的主要位置 | 判定 |
| --- | --- | --- | --- |
| core | **1,144 / 171**（status `:33`、progress `:16`、D-172 `:1495`） | final-report `:67`/`:108`/`:188`/`:199`（1,128/159）；final-acceptance-build `:26`（1,100/165）；final-acceptance-tests `:10`；review-remediation `:35`；final-cleanup-summary `:29`；docs README `:40`；ROADMAP `:84`（1,092/157）；cleanup-backlog `:130`（1,100/165）；final-cleanup-core `:50` | 不一致 |
| app | **617 / 68**（status `:34`、progress `:16`） | final-report `:67`/`:110`/`:188`/`:199`（616/68）；docs README `:40`；review-remediation `:36`；final-cleanup-summary `:30`；final-cleanup-core `:52`；final-cleanup-app `:64` | 不一致 |
| ratchet | **54 / 230 / 0 / 0 / 0**（cleanup-baseline.json；status `:36`；D-172） | final-report `:68`（53/240/127）、`:127`（53/235/127）；final-acceptance-build `:50`（53/231）；review-remediation `:38`；final-cleanup-docs `:70`（53/235/127） | 不一致 |
| protocol | **254 / 1,339 / 0 / 0**（protocol-surface-baseline.json；status `:36`） | final-acceptance-build `:58`、final-acceptance-architecture `:10`/`:44`、D-171 `:1486`（254/1,338） | 历史快照 |
| schema | **43 / 373 / 69 / 62 / user_version=2**（代码 `Schema.swift:14`、`SchemaV1.swift:62-65`；ADR `:13`） | final-report `:61`/`:119`/`:186`（user_version=1）；review-remediation `:37`；final-cleanup-summary `:31`；docs/README、根 README、DEVELOPMENT 仍把当前库称“SchemaV1” | 部分不一致 |
| target | **8**（`gather-core/Package.swift:43-47` + `gather-app/Package.swift:84/99/114`） | final-report `:9`/`:49`/`:60`/`:184`（7 + GatherDomain）；ROADMAP `:282`、progress `:40`/`:179`（7，部分为历史） | 不一致 |
| Swift 文件 | **641**（本次静态 `find`，排除 .build） | progress `:13`（535）；final-report `:58`/`:70`（535）；final-cleanup-docs `:65`（535） | 当前指标过期 |
| Coordinator | **540 行**（审计开始时；并行改动后 543） | status `:38`、progress `:18`、final-report `:11`（366） | 当前指标过期 |
| GatherDelivery 文件 | **16**（本次静态 `find`） | status `:38`（14）；final-acceptance-build `:135`（14） | 快照/当前过期 |
| commits | **50**（`origin/refactor..HEAD`，HEAD `ab7752e`，审计开始时 clean） | final-report `:3`/`:168`/`:174`/`:198`（未提交/82603e0）；final-acceptance-build `:5`/`:170`（34）；status `:4`（HEAD cdf3962） | 不一致 |
| 门禁 | **9 道（6 道支持 strict）** | DEVELOPMENT `:388-398`（缺 protocol、把 self-test 当第 9）；final-report `:121`/`:189`（8）vs `:194`（9）；CI `ci.yml:43-58`（8） | 不一致 |

> 注：矩阵按 **HEAD ab7752e** 的文本统计；并行工作区已修改 `docs/README.md`/`docs/DEVELOPMENT.md`，其中部分行已按 P1-1/P1-4/P1-5 修复。集成时以 `git diff` 为准。

补充符号/数字残留说明：

- **1,114**：静态检索只作为 `ClusteringImpact` 的删除行数出现（`docs/archive/cuts/cut5-algorithm-audit.md:558/600`、`docs/refactor-decisions.md:1297`），**不是 core 测试数**；未发现任何文档把 1,114 当作测试总数。任务书中的“1100/1114”应分别按“旧测试数 1,100”和“删除行数 1,114”理解。
- **`Sources/GatherTestSupport`**：当前 README/docs README/DEVELOPMENT/ROADMAP 已无该错误路径；仅 `refactor-decisions.md:1461`（记录当时 DEVELOPMENT 未改）与 `final-cleanup-scan.md:15/465`（当时的扫描发现）作为历史文本保留。当前实际路径是 `Tests/GatherTestSupport`（`DEVELOPMENT.md:41`、`gather-core/Package.swift:111`）。
- **`GatherDomain`**：当前入口文档只剩 `final-report.md:60` 的 target 表（P0-1）与各处“GatherDomain→GatherApplication”的改名说明；README/docs README/DEVELOPMENT/ROADMAP/ADR 的当前 target 描述已使用 `GatherApplication`。历史评审/归档正文中的 `GatherDomain` 是快照，不应批量替换。
- **`SchemaV1` 命名**：当前 schema 是 V2（`Schema.swift:14`），但 README `:97`、docs README `:30/39`、DEVELOPMENT `:210` 仍把当前库称“SchemaV1 ... user_version=2”；数字对、名字错。V1 只应作为冻结快照/迁移起点出现。

## 1. P0（会直接误导发布/回滚/验收，先修）

### P0-1 `final-report.md` 的“最终指标/Goal 关闭”仍是 Cut 6c 旧值，并与同文件结论直接冲突

- 位置：`docs/final-report.md:60`、`:61`、`:67`、`:68`、`:184`、`:188`、`:189`、`:199`。
- 证据：
  - 同一文件 `:11` 与 `:194` 写当前值 **core 1,144/171、app 617/68、user_version=2、ratchet 54/230/0/0/0、Protocol 254/1,339**。
  - 但 §3 “最终指标（Cut 6c 冻结）”仍写 **7 target**、`GatherDomain`、`user_version=1`、**core 1,128/159 + app 616/68**、**ratchet 53/240/127**（`:60-68`）。
  - §8 “Goal 关闭材料”仍以 **7 target / core 1,128/159 / app 616/68 / 8 门禁** 判定通过（`:184-189`）。
  - §9 resume 预期仍是 **core 1,128/159、app 616/68、8 门禁 53/240/127**（`:199`）。
- 补充：`status:56` 称“final-report 的 Cut 6c 数字仍为历史快照，§1.2 已注记当前架构指标”，但 §1.2 只是新增一段小结，§3/§8/§9 的旧值并未标注，读者仍会按旧表验收。
- 影响：按 §8/§9 验收会得到“预期值错误”的假失败，或把旧 6c 结果当成当前结果；同一报告不能作为单一验收源。
- 修复：在文件头加“**Cut 6c 快照；当前指标见 status §2 / D-172**”横幅；§3/§8/§9 全部标注“Cut 6c 时点”，或删除旧表只留 §1.2 的当前值 + 链接；把 7 target 改成 8 target（Protocol/Persistence/Delivery/Analysis/Application/UI/Host/App），`GatherDomain` 改成 `GatherApplication`，`user_version=1` 改成 2（V1 快照才为 1）。

### P0-2 `final-report.md` 把仓库状态写成“82603e0 未提交/重构前基线”，与审计开始时 clean + 50 commits 相反

- 位置：`docs/final-report.md:3`、`:168`、`:174`、`:198`。
- 证据：
  - `:3`：基线 HEAD `82603e0`、工作区未提交；`:168`、`:198` 重复“全部改动相对 82603e0 未 commit”。
  - `:174`：“HEAD 仍是重构前基线……整仓回退即回到 HEAD（会同时丢掉 Cut 0–6 的全部未提交工作）”。
  - 静态 git 事实（审计开始时）：`git rev-parse HEAD` = `ab7752e`；`git status` 干净；`git rev-list --count origin/refactor..HEAD` = **50**。HEAD 已包含重构与整改提交，不再是“重构前基线”；审计期间并行代理开始改若干 Delivery 文件（读取时 4 个），但未改变 HEAD/提交数。
- 同一节 `:175` 还写“**没有迁移链**；读到非 SchemaV1/user_version 不等的库时……改名为 incompatible 后建空 SchemaV1”。当前实际是 V1→V2 迁移（373 列 no-op、370 列补三列，`SchemaCatalog.swift:22-31`、`MigrationV1ToV2`），且未知/高版本默认 **fail closed**，只有显式 `resetPolicy` 才改名（`ADR.md:68-74`）。这会把用户“升级/恢复”路径说反。
- 影响：回滚/备份建议失效，owner 可能按“未提交”判断工作区；数据库恢复段还会误导为“一律重置”。这也解释了为何最终报告没有记录 50 commits。
- 修复：改为“HEAD ab7752e，分支 refactor，origin/refactor..HEAD=50，审计开始时工作区 clean”；删除/改写 §7 的“未提交回滚”段；§9 第 1 条同步；§7 数据库段改为“V1→V2 备份 + 迁移；未知/高版本 fail closed，显式 reset 才改名”。

## 2. P1（当前入口文档的事实/索引错误）

### P1-1 `docs/README.md` 的“当前基线”过期，且把当前库策略写成“无迁移链/整体重置”

- 位置：`docs/README.md:30`、`:39-41`、`:76`。
- 证据：
  - `:39-40` 写 **core 1,128/159、app 616/68** 作为“当前基线（2026-10-22 评审修复轮）”；当前口径为 **1,144/171、617/68**（status `:33-34`、progress `:16`、D-172 `:1495`）。
  - `:41` 写“无迁移链（不兼容库由 `Database.open(at:)` 整体重置）”。代码实际有 V1→V2 迁移（`SchemaCatalog.production`，`Migration/SchemaCatalog.swift:22-31`），且不兼容库默认 **fail closed**，只有显式 `resetPolicy=.renameToIncompatible` 才改名重建（`ADR.md:68-74`、`Database.swift:226-243`）。
  - `:76` 的 app 测试命令没有 `--no-parallel`，与根 `README.md:70`、`DEVELOPMENT.md:69/74` 的“始终 --no-parallel”相反。
- 影响：读者会按旧测试数验收、误以为 V1 库一律重置、并可能跑出并行 flake。
- 修复：改为 1,144/171 + 617/68，并链接 status/D-172；把 `:41` 改成“V1→V2 备份 + no-op/370 列补列迁移；未知/高版本默认 fail closed，显式 reset 才改名”；`:76` 补 `--no-parallel`。**工作区进度：前两项已由并行代理修复；`:76` 仍缺 `--no-parallel`（截至最后一次读取）。**

### P1-2 `final-acceptance-*` 是 df73880 的“验收前快照”，却被当作当前最终验收引用

- 位置：`docs/reviews/final-acceptance-build.md:1`、`:5`、`:13`；`final-acceptance-tests.md:10`；`final-acceptance-architecture.md:10`；`final-acceptance-data.md:3`；引用处 `docs/final-report.md:11`、`docs/reviews/architecture-remediation-status.md:63`。
- 证据：四份报告的基线都是 **HEAD df73880**，数字是 **core 1,100/165、protocol 254/1,338、ratchet 53/231、34 commits**；当前 status/progress/D-172 已推进到 **1,144/171、1,339、54/230、50 commits**。报告头有“HEAD df73880”时点，但 final-report `:11` 称其为“最终独立验收”，status `:63` 称“最终验收报告”，没有“已被 D-172 取代”的提示。
- 影响：读者会把旧 P1/P2 清单当成当前未关闭项（或反过来把已修项当成仍红），也会把旧数字当成最终验收值。
- 修复：四份报告头统一加“**Pre-closure snapshot；当前结论见 status §2 / D-172**”；在 status 中增加“验收快照（df73880）→ 收口后（ab7752e）”对照表；保留快照数字，不回填。

### P1-3 `architecture-remediation-status.md` 的“P1 全部收口”和“build.sh 全流程通过”过强

- 位置：`docs/reviews/architecture-remediation-status.md:41`、`:61`。
- 证据：
  - `:41` 写“Release：真实 universal build + build.sh 全流程通过”。但 `final-acceptance-build.md:73` 记录原样 `build.sh` **exit 1**（SwiftPM manifest 沙箱），只有注入 `--disable-sandbox` 的 shim 路径 `:74` exit 0；状态没有限定“等价 shim”。
  - `:61` 写“计划中的 WP0–WP7b 与独立验收 P1 已全部收口”。该句没有限定“架构验收 P1”还是“全部验收 P1”。若按全部验收报告理解：`final-acceptance-tests.md:136-150` 的 P1-5（SchemaCatalog 非法链）、P1-6（备份失败不迁移）在静态可见测试中没有对应用例（疑似缺口，未执行测试）；P1-7（成功迁移后 FK 检查）已有 `SchemaMigrationTests.swift:251` 断言。`SchemaMigrationTests.swift` 现有 16 个 `@Test`，含 shape/FK 失败 guard，但没有 catalog 非法链/备份失败用例。
- 影响：发布证据被高估；验收 P1 清单与“全部收口”存在口径冲突。
- 修复：把 `:61` 改成“架构验收 P1 已收口；测试验收 P1-5/P1-6 见 backlog/豁免记录”；若已豁免需在 D-172 或 cleanup-backlog 明确写出，否则不要用“全部”。

### P1-4 “9 道门禁”的清单在 DEVELOPMENT、final-report、CI 三处不一致

- 位置：`docs/DEVELOPMENT.md:388-398`；`docs/final-report.md:121`、`:189`、`:194`；`docs/reviews/final-acceptance-build.md:46-58`；`.github/workflows/ci.yml:43-58`。
- 证据：
  - final-acceptance-build 的 9 道是：cleanup、docs、test-catalog、no-legacy、layering、duplicate、select-star、preview、**protocol**。
  - DEVELOPMENT 列了 9 条，但把 `check-test-catalog.sh --self-test` 算进来，**没有 protocol surface**。
  - final-report §5.3 标题“八道门禁”并只列 8 条（无 protocol），但 `:194` 结论写“9 门禁 strict”。
  - CI `gates` job 只跑 8 条，也没有 protocol surface。
- 影响：本地/CI 门禁口径不同；protocol 254/1,339 的 ratchet 实际未进 CI。
- 修复：统一“9 道 = cleanup/docs/test-catalog/no-legacy/layering/duplicate/select-star/preview/protocol”；self-test 标为可选负例；CI gates 补 protocol；final-report §5.3 改成 9 条并明确“3 条无 --strict 开关”。**工作区进度：DEVELOPMENT 已补 protocol 并把 self-test 标为非门禁（HEAD 版仍缺）；CI 尚未补。**

### P1-5 `DEVELOPMENT.md` 的“新库执行 SchemaV1.sql 并写 user_version=2”与代码不符

- 位置：`docs/DEVELOPMENT.md:233-234`；相关命名 `:210`。
- 证据：`SchemaV1.createSQL` 明确写 `PRAGMA user_version = 1;`（`SchemaV1.swift:842`），它是 V1 历史快照；`Database.open` 建新库执行的是 `currentSnapshot.createSQL`（`Database.swift:445`），当前快照是 V2（`SchemaCatalog.swift:22-31`，`SchemaV2.ddl = SchemaV1.ddl`），版本镜像 `SchemaSQL.currentSchemaVersion=2`（`Schema.swift:14`）。因此“执行 SchemaV1.sql 并写 2”两半都不准确。
- 影响：开发/迁移文档会误导对“新库为何是 2、V1 夹具为何是 1”的理解。
- 修复：改为“新库执行 currentSnapshot（V2）的 createSQL，同一事务写 user_version=2；`SchemaV1.sql` 仅用于 V1 夹具/迁移起点，写 1”；`:210` 的“SchemaV1 ... user_version=2”改成“SchemaV2（DDL 与 V1 相同）”。**工作区进度：并行代理已按此修复（HEAD 版仍旧）。**

### P1-6 当前规模/组件指标仍写 535 文件、Coordinator 366、Delivery 14 文件

- 位置：`docs/refactor-progress.md:13`、`:18`；`docs/reviews/architecture-remediation-status.md:38`；`docs/final-report.md:11`；同类旧测试数还在 `docs/ROADMAP.md:84`（1,092/581，写成“2026-10-22 本机 test”）与 `docs/cleanup-backlog.md:130`（“当前口径”core 1,100/617）。
- 证据（静态计数，排除 `.build`）：
  - `find desktop/native -name '*.swift' -not -path '*/.build/*' | wc -l` = **641**（core Sources 231 + core Tests 111 + app Sources 231 + app Tests 66 + 2 Package.swift），不是 535。
  - `DeliveryCoordinator.swift` 审计开始时 **540** 行（并行改动后 543；`wc -l`），不是 366。
  - `GatherDelivery` 当前 **16** 个 `.swift`，不是 14。
- 影响：status/progress 的“当前指标”不可复算；D-172 之后的 P1 修复（confirm 单事务、lease owner、backup 校验）显然增加了 Coordinator 体量，但文档仍停留在 df73880 前。
- 修复：以当前树重新统计并加“采样时点”；或把这些值明确标为“df73880 快照”，不要放在“当前指标”段。

### P1-7 `docs/reviews/README.md` 与 `docs/archive/README.md` 的评审索引严重过期

- 位置：`docs/reviews/README.md:1-11`；`docs/archive/README.md:53-60`。
- 证据：两者都写“当前保留 4 篇”，但 `docs/reviews/` 在审计开始时已有 **26 篇 `.md`**（含 final-acceptance-* 4 篇、final-cleanup-scan、wp1、wp6、architecture-macro-*、post-refactor-r1..r8 等）；当前为 **30 篇**（新增本报告 + 3 份并行 `final-sweep-*`）；archive README 的“保留 4 篇”表也未列出 2026-10-22 新增的整改/验收报告。
- 影响：读者找不到最终验收/整改报告入口，或误以为这些报告已归档。
- 修复：把 reviews README 改为“4 篇核心 + 26 篇 2026-10-22 整改/验收/扫尾报告（含 4 份 final-sweep-*）”并分类列表；archive README 的“保留 4 篇”改成“Cut 6 时点保留 4 篇，后续新增见 reviews/README”。

### P1-8 当前开发指南/路线图仍有不存在的源码路径

- 位置：`docs/DEVELOPMENT.md:26`、`:218`、`:300`；`docs/ROADMAP.md:86`。
- 证据：
  - `DEVELOPMENT.md:218` 写 `Sources/GatherHost/RootView.swift`（148 行），实际文件是 `desktop/native/gather-app/Sources/GatherUI/Shell/RootView.swift`（153 行）；`GatherHost/RootView.swift` 不存在。
  - `:300` 写“见 RootView.swift 的 SidebarView”，但全仓已无 `SidebarView` 符号（拆分后是 `RootShellSidebar.swift`）。
  - `:26` 写 `Concurrent/BatchRunner.swift`，实际是 `GatherPersistence/Support/BatchRunner.swift`。
  - `ROADMAP.md:86` 写 `gather-core/Services/CullingService.swift`，实际是 `Sources/GatherApplication/Services/CullingService.swift`。
- 影响：开发者按指南找不到文件；与“目录结构唯一真相源”自相矛盾。
- 修复：逐条改为当前路径/符号；路径类改动建议同时加入 `check-docs` 的“代码块内路径白名单”检查（见 §4）。

## 3. P2（历史快照标识、计数尾差、编号/措辞）

1. **历史收尾报告未标“快照”**：`docs/review-remediation-report.md:35-40`、`:52`（core 1,128/616、user_version=1、53/240/127、未 commit）；`docs/final-cleanup-summary.md:29-34`、`:46`；`docs/final-cleanup-core.md:50-53`；`docs/final-cleanup-app.md:64-67`；`docs/cut6-cleanup-audit.md:4`、`:20-23`；`docs/test-audit.md:7-9`。这些报告是当时快照，数字可以保留，但需在头部署名“2026-10-22 时点，已被 ab7752e/status 取代”，否则读者会当成当前值。
2. **final-report 的文档/文件计数**：`:69` 写 55 篇/21,787 行（非 archive 26 篇），审计开始时静态为 docs 总 71 篇、非 archive 42 篇；当前 75/46（含 4 份新增 `final-sweep-*`）。测试文件从报告口径 166 变为当前 177（`find` 三个测试根）。`:58`/`:70` 的 535 文件/138,829 行同理。作为 6c 快照可保留，但不要放在“最终值”列。
3. **final-report 的门禁尾数**：`:127` 写 53/235/127、`:133` 写 select-star 6 处/2 文件、`:134` 写 preview 2,045 行、`:194` 写 ratchet 54/230/0（缺最后两项 /0/0）；当前脚本/验收口径分别是 54/230/0/0/0、4 处/1 文件、2,031 行。若不是快照，应改为当前；否则标 6c。
4. **决策编号**：`docs/refactor-decisions.md` 有重复标题 D-081（`:669`、`:692`）、D-162（`:1388`、`:1404`）、D-163（`:1396`、`:1413`），且缺 D-140、D-170；`:1424` 又在 D-163 内做“Goal 关闭”。引用 D-163 时无法确定指哪一条。建议重排编号，至少给重复项加 a/b 后缀并更新引用。
5. **ADR 的 MigrationTests 描述**：`docs/ADR.md:22` 写“fresh 校验 MigrationTests.swift（schema 1 / 43 表）”；当前该测试同时覆盖 V1 夹具（1）与 `Database.open` 当前库（2）。建议写成“V1 夹具 1 + 当前 V2”，避免被读成当前版本是 1。
6. **根 README 发布说明**：`README.md:79-80` 写“Set CONFIGURATION=release for a release build”，但 `build.sh:19` 默认就是 `CONFIGURATION=release`；该句暗示默认是 debug。建议改为“默认 release，可用 CONFIGURATION 覆盖”。
7. **final-cleanup-scan 的“当前文档过期”已过期**：`docs/reviews/final-cleanup-scan.md:15`、`:455-474` 仍称 README/docs README/DEVELOPMENT/ROADMAP 写 7 target/GatherDomain/user_version=1；这些具体项在后续提交已修（README 已 8 target/Application，DEVELOPMENT 已 8 target/Tests 夹具）。报告应加“§5.9 已由后续提交修复”的 resolver 注记，避免二次误导。
8. **CI 注释与 strict 措辞**：`.github/workflows/ci.yml:79` 仍写“user_version=1/外键 0 违规”，实际 verify 断言 2；`status:36` 与 `final-report:194` 写“9 道 strict”，但 cleanup/no-legacy/layering 没有 `--strict` 开关。建议改成“9 道门禁（6 道 strict）”。

## 4. 文档门禁静态结论（未执行脚本）

按 `scripts/check-docs.sh` 的四项规则对当前文档做静态复算（截至本次复算已纳入并行 3 份 `final-sweep-*`，reviews 共 30 篇；若之后继续新增文档，以运行门禁为准）：

- ADR 反引号路径：**20 条，0 缺失**（与 final-acceptance-build `:51` 的 20/0 一致）。
- 当前文档（docs 非 archive + 根 README + archive README）md 相对链接：审计开始时**约 151 条，0 缺失**（本次静态解析；final-acceptance-build 记录的是 df73880 时点 146 条）。
- `docs/reviews` 历史文档：**审计开始时 26 篇；当前 30 篇**（含本报告 + 3 份并行 `final-sweep-*`）；`docs/archive` 存在，不触发 warning。
- schema 声明：代码 `currentSchemaVersion=2`（`Schema.swift:14`），ADR 当前声明“当前 schema：2”（`ADR.md:13`），一致。

补充两项门禁外核对：

- **报告链接/文件名**：本次静态解析 docs 非 archive + 根 README + archive README 的 md 相对链接约 **151 条、0 缺失**；`final-report`、`status`、`final-acceptance-*`、`final-cleanup-*` 之间的互链均可解析，未发现文件名拼错或相对路径失效。**但行内代码中的路径**（DEVELOPMENT/Roadmap/验收报告的 `Sources/...`）不在门禁范围，已发现 P1-8 的 4 条失效。
- **发布命令/release 变量**：`DEVELOPMENT.md:94-121` 的变量表与 `build.sh:9-15`、`.github/workflows/ci.yml:146-153` 静态一致（`GATHER_ARCHS`/`GATHER_VERSION`/`GATHER_BUILD_NUMBER`/`CODESIGN_IDENTITY`/`GATHER_NOTARIZE`/`GATHER_NOTARY_PROFILE`+`APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD`/`GATHER_RELEASE`）；根 README 只给 `CONFIGURATION`/`OUTPUT_DIR`/`CODESIGN_IDENTITY` 最小集，属入口分工，不算矛盾，但 `CONFIGURATION=release` 的默认值说明有误导（P2-6）。

因此**若只按 check-docs 的现有规则，文档门禁当前应可通过（静态判断，未执行）**；但它不会发现本文 P0/P1 中的 target 数、测试数、user_version 文案、提交状态、路径代码块、索引计数问题。建议后续给 check-docs 增加：
1. 关键文档（README/docs README/DEVELOPMENT/ROADMAP/status/final-report）的“当前指标”正则/表格断言；
2. 禁止 `user_version=1` 出现在当前指标段（V1 快照句子除外）；
3. 关键源码路径（RootView/CullingService/BatchRunner 等）存在性检查；
4. 历史快照横幅检查（含 `superseded`/日期/HEAD）。

## 5. 建议修复顺序

1. **先修 final-report**（P0-1/P0-2）：加快照横幅、改仓库状态、统一 §3/§8/§9 到 1,144/617/8 target/user_version=2/54/230/9 门禁，或全部降级为 6c 快照并指向 status。
2. **再修当前入口**（P1-1/4/5/8）：docs README 当前基线 + 库策略 + --no-parallel；DEVELOPMENT 门禁清单、SchemaV1.sql 文案、RootView/BatchRunner 路径；ROADMAP §3.1 数字与 CullingService 路径。
3. **统一验收口径**（P1-2/3/6/7）：final-acceptance 加 pre-closure 横幅；status 的 build.sh/P1 措辞加限定；当前规模指标重采；reviews/archive 索引补 26 篇（含 final-sweep）。
4. **最后做 P2 快照标注与编号整理**，并把 check-docs 扩容，防止再次漂移。

## 6. 残余与限制

- 未执行 build/test/门禁；1,144/171、617/68 等测试数字仅按 status/progress/D-172 的文档口径对账，未独立复跑验证。
- 代码/基线静态事实（schema 常量、target 声明、文件/行数、Coordinator 行数、baseline JSON、git 提交数）为本次只读检查所得；行数统计排除 `.build`。
- 本文只写 `docs/reviews/final-sweep-docs.md`；未改任何其他文件。
