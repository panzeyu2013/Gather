# 清理欠账清单（Cut 0 盘点）

> 依据：`docs/reviews/refactor-design-breaking-2026-10-21.md` §1 / §8 / §9。
> 盘点日期：2026-10-21。仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`。
> 本文件只做**盘点**，不删除任何代码；删除动作在对应 Cut 内执行，且必须与本文件的验收命令一一对应。
> 标记约定：**【已确认】** = 有源码/命令证据；**【疑似】** = 静态扫描结论，需运行期或人工确认；**【需验证】** = 需 `EXPLAIN QUERY PLAN` / 基准 / 手工操作确认。

## 0. 证据口径与复现

- 引用计数：把 Swift **字符串字面量**（含 `"""..."""`）作为 SQL 文本提取，统计表名/列名出现次数；注释与普通标识符不计。core 源计数**排除** `Schema.swift` 与 `Migrations.swift`（DDL/迁移单独列出）。
- public 符号：正则提取 `public (final|nonisolated|@attr)* (struct|class|enum|protocol|actor|func|var|let|typealias|init)`；"零引用" = 自身文件外 core Sources 计数为 0 且 app Sources 计数为 0。
- 行号会随并行修改漂移；引用前重新 `read` 核对。本文件所有行号来自 2026-10-21 扫描。
- 复现命令见 §9。
- `docs/cleanup-baseline.json`（并行 Cut 0 产出）与本文 §5 数字口径不同处已注明；ratchet 以此 JSON 为准。

## 1. 摘要数字（Cut 0 冻结基线）

| 指标 | 数值 |
| --- | --- |
| Swift 文件 / 总行数 | 257 / 102,938（含 core `Package.swift` 77 行） |
| core Sources / Tests | 93 文件 / 37,604 行；88 文件 / 28,441 行 |
| app Sources / Tests | 46 文件 / 29,083 行；29 文件 / 7,733 行 |
| public 声明 | 2,298（type/func 1,012；var/let 1,286）；public 行 3,178 |
| 表 / 列 / 索引 / 外键 | 44 / 391 / 62 / 63 |
| 命令面 | 118（sync 82 + async 36） |
| 测试 | `@Test` core 994、app 301 |
| 删除面 | CL-01 已删 7 文件 / 4,052 行（118 命令）；CL-02/11 待删 Migrations 1,628 + MigrationTests 169 行 + 快照 |

## 2. §8.2 CL-01..CL-20 可执行清单

> 每条：位置 / 规模 / 处置 / 目标 Cut / 验收 / 风险。状态规则见 §7。

### CL-01 Router / JSON 命令面 / 生成器 —— status: done（2026-10-22，B8.4/B8.5）
- **历史位置（已删除）**：`SessionCommandRouter.swift`（3,258 行）、`Host/CommandRouter.swift`（51 行）、`Support/NativeCommandClient.swift`（77 行）；app 侧实测 14 个文件共 79 处 `.execute(`、74 条命令字面量。
- **实际删除**：7 文件 / 4,052 行（`git show HEAD:<path> | wc -l`）：SessionCommandRouter 3,258、CommandRouter 51、NativeCommandClient 77、CommandSurfaceRuntimeTests 296、NativeCommandClientTests 223、StubCommandRouter 38、check-command-surface.sh 109；另删除工作区测试支撑 AppCompositionTestSupport（约 73 行，按 D-080 差额推算，未进 HEAD）。118 命令 → 16 协议 / 110 方法。
- **验收结果**：`execute(`/`executeAsync(`/`enqueue(` 字面量 0；`SessionCommandRouter|CommandRouter|NativeCommandClient|WebResponse|StubCommandRouter` 源文件引用 0；check-no-legacy 的 R5 全部 enforced 0；app 455/55、core 1080/149 绿。
- **风险**：已由 API 输入类型/`Confirmed<T>`/`PhotoPathPolicy` 承接；行为覆盖见 [cut1-completion-report.md](archive/cuts/cut1-completion-report.md)。

### CL-02 迁移链 / 旧 Schema / 快照 —— status: done（2026-10-22，S5c-2b-3b-2b-3）
- **结果**：删除 `Migrations.swift`（1,628 行）与 `SchemaV1Transition.swift`（121 行）；`Schema.swift` 649→14（仅 `activeAnalysisJobStatusSQLList` + check-docs 版本镜像）。`MigrationTests` 改写为 fresh-only（43 表 / user_version=1 / 无 legacy 表列）。
- **现状**：`SchemaV1.swift` 是唯一 DDL 真相源；生产 `Database.open(at:)` 建库/重置（不兼容库含 -wal/-shm 整体改名）；`docs/archive/schema.snapshot-v35.json` 仅历史（schema 35），不参与门禁。
- **验收**：`MigrationRunner`/`SchemaV1Transition` 引用 = 0；fresh 库经 `SchemaV1.sql` 与 `Database.open` 两条路径同形。

### CL-03 outbox + writeback 双状态机 —— status: done（2026-10-22，S5c-2b-3b-2b-3）
- **结果**：删除 `MetadataOutboxRepo`(897)/`WritebackRepo`(205)/`MetadataSyncCoordinator`(1230) 与 4 个测试文件（1,983 行）；`metadata_outbox`/`metadata_outbox_sessions`/`writeback_items` 与 sessions 3 列随 SchemaV1 不再建表。
- **现状**：四域 confirm/cleanup/finalize/replay 全走 `DeliveryCoordinator` + `deliveries/delivery_sessions/delivery_items/delivery_intents`；`MetadataMutationService` 手动队列落 `delivery_items`（module=.metadata）；`MetadataSyncError` 收敛为 `DeliveryError` 的四个稳定码。
- **验收**：三旧表/3 列在 Sources/Tests 引用 = 0；`DeliveryCoordinatorTests`/`DeliveryRepoTests`/`DeliveryIntentRepoTests` 覆盖 confirm 单事务、cleanup 崩溃回放与外改冲突。

### CL-04 4 套 stale 守卫 —— status: deferred（2026-10-22，post-refactor r8 P1-3）
- **位置**【已确认】：Gallery `Gallery/GalleryViewModel.swift:241`（`fetchGeneration`，使用 :455/513/725-754）；Library `Library/LibraryViewModel.swift:334`（`latestRequestID`，:665-691）；Similarity `Similarity/SimilarityViewModel.swift:319`（`tierRequestID`，:472-482）；Culling `Culling/CullingView.swift:133`（`pageVersion`，:591-619、:805-814）。
- **未完成原因（r8 P1-3）**：`Support/RequestGate.swift` 自 4a-0 起就是零生产调用点（仅 `RequestGateTests` 引用）；`Support/ViewState.swift` 同样零生产调用点（R4 P2-8）。4 套私有代次从未迁移，本轮又不能改 Gallery/Library/Similarity/Culling 的业务 VM，无法给出“统一实现 + 对等测试 + 旧代码删除”的 done 证据。
- **处置（2026-10-22）**：不保留“以后可能用”的类型储备，删除 `Support/RequestGate.swift`（34 行）、`Support/ViewState.swift`（49 行）及 `Tests/GatherAppTests/RequestGateTests.swift`（4 例/58 行）、`ViewStateTests.swift`（8 例/98 行），共 **4 文件 / 239 行 / 12 例**；4 个 VM 的私有代次原样保留。
- **验收偏差**：原验收 `grep -rnE 'fetchGeneration|latestRequestID|tierRequestID|pageVersion' gather-app --include='*.swift'` = 0 **未达成**；实测仍 **37 行**（fetchGeneration 16 / latestRequestID 5 / tierRequestID 7 / pageVersion 11，其中 2 行双命中）。`RequestGate` 在生产与测试中的引用均为 0。
- **解除条件**：真正决定统一时，先按 4 个 VM 的代次语义（Library 同时比较 generation + requestID、分页与刷新共用一个计数）重新设计，再新建类型并补乱序/取消/重入测试；不得只建类型不接线。
- **残余**：`GatherUI/Support/LoadPhase.swift:9/18` 注释经 2026-10-22 16:48 复核已无 `ViewState` 引用（并行工作区已修；本轮按白名单未改 Sources）；`scripts/check-duplicate-symbols.sh` 的 RequestGate 规则与“Cut 4 落地”文案已于最终清理移除（见 [final-cleanup-docs.md](final-cleanup-docs.md)）。
- **风险**：守卫语义差异（Library 同时比较 generation + requestID）合并时丢条件；分页与刷新共用 generation 的副作用。

### CL-05 度门控 BFS + 双聚类 —— status: done（2026-10-22，5b-1 / 5b-2a）
- **历史位置（已删除）**【当时已确认，共 5 份 BFS + 1 回退】：`Similarity/ClusterEngine.swift` 的 `waveBfsOverFilteredRows`/`recomputedBfs`/`waveBfsOverRows`（3 份）；`Similarity/IncrementalClusterer.swift` 的 `groupComponent`/`groupComponentScanning`（2 份）；回退路径 `Services/SimilarityService.swift` 增量失败后的全量 buildState。双聚类 = ClusterEngine（753 行）+ IncrementalClusterer（748 行）。
- **实际删除（5b-2a，同一 PR）= 1,161 行**：ClusterEngine.swift **753**（整文件删除）+ IncrementalClusterer **748 → 340（−408）**；`buildState`/`ParsedHashes`/`ComponentGraph`/`connectedComponents` 随实现消失。BFS 由 **6 份 → 2 形态**（`DegreeGatedBFS.components` / `groups`，D-149 口径；盘点时按 5 份 + 1 回退记）。
- **现状**：唯一实现 = `ClusterGraph.swift`（784 → 943 行，迁入 HashEntry/ClusterResult/ClusterGraphError/defaultMaxBitsetEntries/runSequential/runTiers）+ `ClusterGraphPipeline.run/runTiers` 单趟产 result+state；Duplicate/AppComposition/Similarity 三个注入点同一实现。5b-1 另把多档 4 位图并成 1 份（32k 档 537MB → 134MB）。
- **验收结果**：`grep -rnE 'func .*[Bb]fs|groupComponent' GatherAnalysis/Similarity GatherDomain/Services` = **0 代码**（仅 2 行注释记述已删实现）；golden `cluster-fixtures.json` 17 例锁 pipeline（global + sequential）；增量 200 次随机 × 3 参数与全量 state 逐位一致；core 1060/152 绿。
- **残余**：>32768 streaming 组内序仍为 wave（旧 stack 未复刻，划分/种子/state 已逐位对账）；10k/100k 基准档位归 5d-2。

### CL-06 HNSW 死代码 —— status: done（2026-10-22，5b-2a + 5d-1）
- **历史位置（已删除）**【当时已确认】：`Face/VectorIndex.swift` 的 HnswConfig/HnswHits/CosineHnswIndex；`GatherCoreBenchmarks/main.swift` 的 benchHnsw；测试 `Reconciliation/VectorIndexReconciliationTests.swift` 的 HNSW 对账段。
- **实际删除（5b-2a）= 548 行**：`VectorIndex.swift` **866 → 370（−496：CosineHnswIndex 471 + FaceVector + HnswConfig/HnswHits + 3 个 error case）**，bench `main.swift` **333 → 281（−52：benchHnsw + bruteForceTopK）**；测试 323 → 213 行、5 → 3 例（−2：hnswTopK / rejectsDimensionMismatches），并取消 `GATHER_RECONCILIATION_VECTOR` gate（改默认运行）。
- **5d-1 收尾 = 2,418 + 453 行**：fixture `Tests/GatherCoreTests/Reconciliation/Fixtures/vector-fixtures.json` 删 `hnsw` 段 **2,418 行**（143,273 → 140,855 行，3.66MB → 3.63MB，`hnsw` 键消失）；生成器 `scripts/reconciliation/generate-vector-fixtures.mjs` 重写为只产 LSH（**1,016 → 563 行，−453**；删 HNSW 参照实现/DEFAULT_HNSW_CONFIG/getLevels/bruteTop1），`--check` 与入库 fixture 逐字节一致；bench README 删 hnsw 行。
- **验收结果**：`grep -rn 'CosineHnswIndex|HnswConfig|HnswHits|benchHnsw' --include=*.swift` = 5 行（全是"已删除"注释，无代码引用）；`swift test --filter VectorIndexReconciliationTests` 3 例绿；LSH 召回 fixture 数字未变（total 0.8436，5 桶 0.629/0.732/0.848/0.966/0.992）。
- **现状**：保留 `CosineLshIndex`（Clusterer 候选生成生产在用；Matcher 只剩实例级 `matchAgainstLibrary`，批量 `match(clusters:)` 自 5c-1 起走精确扫描、5d-2 起不再建 LSH）；`VectorIndexError` 被 LSH 共用。

### CL-07 两套缩略图 loader / 两套 @State —— status: pending，Cut 4
- **位置**【已确认】：`Support/PhotoThumbnailView.swift` — @State `:164-168`、`.task(id:)` `:211-218`、`load(for:)` `:222-260`；`FaceCropThumbnailView`（同文件）— @State `:289-293`、`.task` `:342-345`、`load(for:)` `:415-449`。
- **处置**：抽一个 `ThumbnailLoader`（状态机 + 缓存键 + 取消），两个 View 只保留布局/裁切差异；缓存键统一为 `photo:<path>#<size>#<preview>` 与 `facecrop:<path>#<size>` 两类，由 loader 生成。
- **验收**：同文件 `load(for:)` 仅 1 处；两 View 各有 #Preview；A/B 检查：切档位不闪图、不错图。
- **风险**：facecrop 键刻意不含 bbox（:408-412 注释说明），合并时误加 bbox 会导致每脸解码整图。

### CL-08 6 个 VM 的 errorMessage/notice —— status: pending，Cut 4
- **位置**【已确认，实测 7 个】：`Culling/CullingView.swift:102`、`Settings/SettingsView.swift:105`、`Export/ExportView.swift:31`、`Duplicates/DuplicatesView.swift:118`、`ControlCenter/SessionControlView.swift:26`、`FaceKeywording/FaceKeywordingView.swift:86`、`Similarity/SimilarityViewModel.swift:332`。计划写 6 个，实测 7 个。
- **处置**：统一 `GatherError` + `CommandError`（`ViewState<V>` 已于 2026-10-22 删除，见 CL-04）；删除存储型 `errorMessage: String?`。
- **验收**：`grep -rn 'var errorMessage: String?' app` = 0；错误横幅由 `LoadPhase.failed(CommandError)` / `CommandError` 驱动（不再使用已删的 `ViewState`）。
- **风险**：现有文案含本地化模板，改 GatherError 后需 en/zh 键位对齐（Localization 测试）。

### CL-09 SessionDraftCache / pending 容器 / isActive —— status: pending，Cut 4
- **位置**【已确认】：`Sources/GatherApp/RootView.swift:289-345 SessionDraftCache`（`pendingExportIntent:329`、`pendingCullingConflicts:331`、`pendingFaceAnalyze:335`）；`isActive` 传参 `:617/639/665/684`；`.id(languageVersion)` `:423`；`languageVersion` 状态 `:367/435`。RootView 共 1,005 行。
- **处置**：`SessionStore` + `SessionWorkspace` + `WorkspaceIntent`（take-and-clear）+ `isVisible`；删除 draftCache 与 4 个 pending 容器。
- **验收**：RootView ≤300 行；`grep 'isActive|SessionDraftCache' app` = 0；意图"消费即清"测试。
- **风险**：跨页跳转意图（index→culling/export/face）丢失；多窗口 tab 复用同一 draftCache 的时序。

### CL-10 .id(languageVersion) + l( 直调 —— status: pending，Cut 4
- **位置**【已确认】：`.id(languageVersion)` 仅 `RootView.swift:423` 1 处；`GatherLocalization.l(` 全 UI **1,439** 处（计划 1,497，漂移 -58，需在 Cut 4 重扫）；`Support/GatherLocalization.swift`（含 3 处 @unchecked Sendable）。
- **处置**：`LanguageStore` + Environment `L10n`；codemod `l(`→`l10n(`；删除 `.id` 与全局锁盒（菜单/Delegate 保留只读入口）。
- **验收**：`grep 'GatherLocalization.l(' app` = 0（菜单除外 allowlist）；`check-l10n.sh`；切语言页面状态保留（手工）。
- **风险**：1,439 处机械替换误改注释/格式串；`String(format:)` 需改 `l10n.format`。

### CL-11 兼容测试 —— status: done（命令面 2026-10-22 B8.4；迁移测试 2026-10-22 S5c-2b-3b-2b-3）
- **位置**【已确认】：命令面 `CommandSurfaceRuntimeTests.swift`（296 行）、`Support/StubCommandRouter.swift`（38 行）、`scripts/check-command-surface.sh`（109 行）已删除；`Tests/GatherCoreTests/Database/MigrationTests.swift:1-169` 与 errorMessage 断言仍待 Cut 2。
- **处置**：命令面测试已由 `Tests/GatherAppTests/API*Tests.swift` 行为测试替代；迁移测试在 Cut 2 S5c-2b 删除/改写。
- **验收**：命令面文件不存在（已满足）；`MigrationTests`/`schema.snapshot` 引用在 Cut 2 归零；errorMessage oracle 改为 GatherError 断言。
- **风险**：删除黄金清单后"某条命令漏迁"无提示——已用 Cut 0 的 118→API 映射表兜底，并在完成报告记录逐域测试。

### CL-12 测试 helper 重复 —— status: done（2026-10-22，Cut 0 收口 + 6b 复核）
- **位置**【已确认】：`LockedBox` ×3 — `app Tests/SimilarityViewModelTests.swift:55`、`LibraryViewModelTests.swift:20`、`GalleryViewModelTests.swift:22`；`AsyncGate` ×4 — `app Tests/SimilarityViewModelTests.swift:16`、`core Tests/FaceKeywordingServiceTests.swift:27`、`SimilarityServiceTests.swift:45`、`DuplicateServiceTests.swift:47`；`ResponseBox` — `app Tests/CommandSurfaceRuntimeTests.swift:31`；`JobEventSink` — `app Tests/GlobalInfraTests.swift:124`。
- **处置**：core/app 是**两个独立包**，不能共享同一文件：各自建 `Tests/Support/TestBoxes.swift`（各一份），并让 `check-duplicate-symbols.sh` 的 allowlist 只允许这 2 个位置。
- **结果（实测）**：`LockedBox` 1 份（`app Tests/Support/LockedBox.swift`）；`AsyncGate` 每包 1 份（app `Support/AsyncGate.swift` / core `GatherTestSupport/AsyncGate.swift`）；`ResponseBox` 随命令面删除；`JobEventSink` 仅 `GlobalInfraTests` 私有 1 份。`check-duplicate-symbols.sh --strict` OK（越界 0）。
- **附带**：`makeMigratedDB` → `makeTestDB`（1 定义 + 79 调用，40 文件），合并临时别名层；见 D-162。
- **验收**：`grep -rn 'class LockedBox|class AsyncGate|class ResponseBox|class JobEventSink' Tests` 只剩每包 1 份。
- **风险**：跨包无法 import 测试 target；合并后各测试文件的 `private` 语义变化导致命名冲突。

### CL-13 未接线/死 API —— status: done（删除面 2026-10-22 / 5b-2a；命名收尾 5d-2）
- **历史位置（已删除）**【当时已确认】：`Face/ClusteringImpact.swift:1-442`（`FaceClusteringImpact`/`Estimator`/`Parameters`/`Error`）仅被 `ClusteringImpactTests` 引用，无 Service/UI 入口；`Face/Encoder.swift` 四处 `embeddingDim` 形参在函数体内从未读取。
- **实际删除 = 1,114 行**：`ClusteringImpact.swift` **442**（整文件）+ `ClusteringImpactTests.swift` **672（9 例）**；`FaceEncoder` 的 4 处 `embeddingDim` 形参随签名收敛删除（函数体从未读取），维度改由 `FaceEncodeResult.embedding.count` + `modelInfo.embeddingDim` 决定。
- **验收结果**：ClusteringImpact 已随 5b-2a 消失（`grep -rn 'ClusteringImpact' --include=*.swift` = 0）；`embeddingDim` 仅剩落库/模型信息面（`FaceEncodeResult`、`LiveSettingsAPI`、`SettingsView+Model`、`FaceRepo`），Encoder 形参 0。
- **产品决策**：ClusteringImpact 选择删除而非接入"重聚类影响预览"——442 行算法 + 672 行测试且无任何 Service/UI 入口（D-149）。若后续需要"参数变更影响预估"，按 git 历史恢复并重新评审。
- **5d-2 命名收尾**：`GatherPersistence/Database/ImageCache.swift` → **`SHA256.swift`**（纯改名，SHA-256 逻辑未动；文件头/类型注释改为与 `FileHasher` 同一分工口径）。旧名仅余 `FileHasher.swift` 与 4 个 `GatherDomain/Services` 注释中的历史引用（不在 5d-2 可写范围，转 Cut 6 一并改注释）。

### CL-14 死表 / 死列 / 死索引 —— status: done（2026-10-22，S5c-2b-3b-2b-3；legacy 表/3 列随 SchemaV1 删除）
- **处置**：SchemaV1 不建 4 张表、13 列、4 个死索引；Repo 同步删。
- **验收**：`check-schema-v1.sh` 表/列/索引清单与 V1 一致；死表引用 = 0。

### CL-15 构建垃圾 —— status: done（Cut 0，2026-10-21）
- **位置**【已确认】：`desktop/native/swbuild.tmp.E9odRAWk`、`.NkPaZ2Mo`、`.dGpNC3SZ`（3 个空目录，0B）；根 `.DS_Store`（6,148B）。`.gitignore` 已由并行工作加入 `swbuild.tmp.*` 与 `.DS_Store`。
- **处置**：已物理删除 3 个空目录与根 `.DS_Store`；`.gitignore` 已加入 swbuild.tmp.*、.DS_Store、.gather/、*.sqlite.incompatible-*。
- **验收**：`find desktop/native -maxdepth 1 -name 'swbuild.tmp*'` = 0；`git status` 干净。
- **风险**：低。注意 **不要** 删 `.build/`（sandbox 缓存共用）。

### CL-16 历史文档 / ADR 漂移 —— status: done（2026-10-22，6b）
- **原位置**【已确认】：`docs/reviews/` 22 篇 + `assets/`；`docs/ADR.md` 的 schema 34/43 表等历史数字。
- **实际处置**：18 篇 reviews → `docs/archive/reviews/`（`assets/` 随迁，图片相对链接保持可用），`docs/reviews/` 留 4 篇 + README；10 篇 Cut 文档 → `docs/archive/cuts/`；新建 `docs/archive/README.md` 索引并写明"行号为当时快照"。全仓 md 入链按新路径重写，md 链接检查 0 缺失。
- **当前口径**：根 README / docs README / DEVELOPMENT / ROADMAP / ADR 改为 8 target、SchemaV1 43 表/373 列/69 索引/62 FK（user_version=2）、无 Router/118 命令、16 协议/110 方法、179 错误码、core 1,100/165 + app 617/68。
- **快照**：`docs/fixtures/schema.snapshot.json` → `docs/archive/schema.snapshot-v35.json`；ADR-006 注明历史、ADR-029 标题加"（schema 34，历史）"。
- **验收**：`./scripts/check-docs.sh --strict` PASS；自建 md 链接检查 0 缺失。
- **残余**：历史文档正文中的旧代码路径仍是快照值（不改正文结论）；无 redirect stub，旧路径靠 archive 索引映射。

### CL-17 重复常量 / 清单 —— status: pending，Cut 4/5
- **位置**【已确认】：`rawExtensions` 三入口 — 定义 `Database/Repositories/AssetRepo.swift:1190`、投影 `PhotoRepo.swift:163`（`AssetRepo.rawExtensions.sorted()`）、再导出 `Services/PhotoAssets.swift:12`；轮询间隔 — `ControlCenter/SessionControlView.swift:236/239`（15s/3s）、`Similarity/SimilarityViewModel.swift:398`（1s）、`Gallery/GalleryViewModel.swift:224`（注释引用 SessionControl 模式）。
- **处置**：扩展名清单收敛到 `PhotoFileTypes`（GatherProtocol）；轮询抽 `PollingPolicy`（active/idle/debounce 三档）。
- **验收**：`grep -rn 'rawExtensions' Sources` = 1 定义 + 只读引用；`PollingPolicy` 单元测试；无散落 `.seconds(` 常量。
- **风险**：RAW 判定被 SQL 拼接复用（AssetRepo:839），迁移时漏改导致导入漏文件。

### CL-18 吞错 / 弱类型残留 —— status: pending（评审修复后 ratchet 重定基线）
- **位置（2026-10-22 最终清理后实测）**：`try?` **235 行**（baseline 240，已下降 5）；`@unchecked Sendable` **53 行**；`services_prepare` **127**（Indexer 显式 FK 顺序 +1，已入 baseline）。重点文件：`CullingService.swift`、`MetadataService.swift`、`JobService.swift`、`CaptureOneBridge.swift`。
- **处置**：逐个消除或登记豁免（`docs/cleanup-baseline.json` + 注释说明锁依据）；`try?` 只允许用于"失败可观测"的分支并记 warn。
- **验收**：ratchet 只降不升；每个剩余 `@unchecked Sendable` 有锁/不可变依据注释。
- **风险**：把吞错改成 throw 会改变 UI 错误路径与测试断言；需分批。
- **最终复核（2026-10-22 收尾）**：`./scripts/check-cleanup-ratchet.sh` 实测 current/baseline = **53/53、235/240、127/127、0/0、0/0**（try? 因并行工作区再降 5，未回升；baseline 未收紧）；`@unchecked Sendable` 53 行、Services `prepare(` 127 处。本轮不改源码，状态维持 pending。

### CL-19 旧回归测试 / 重复覆盖 —— status: done（2026-10-22 复核，保留 60 例）
- **实测（2026-10-22）**：`app ReviewFixTests` 994 行 / 45 例、`app ReviewAcceptanceTests` 135/6、`app DeepModelAcceptanceTests` 37/1、`core ReviewAcceptanceTests` 83/5、`core DeepReviewAcceptanceTests` 53/3；合计 **1,302 行 / 60 例**（计划 1,299 行漂移 +3）。外部进程 4 例（zip/sh/awk）仍在。
- **决策**：不按 test-audit §3.5 压到 761/253——保留仍保护现存行为的 60 例；`ReviewFixTests` 的 9 个重叠用例不合并（收益低、易丢 F/B 回归）；外部进程 4 例保留（真实工具验收），未改夹具。
- **验收**：`./scripts/check-test-catalog.sh --strict` PASS（163 文件、缺头注释 0、禁用 0）。
- **残余**：4 例依赖 `/usr/bin/zip`、`/bin/sh`、`/usr/bin/awk`，非 hermetic；"重写为夹具"为可选未做项。

### CL-20 未用资源 / 调试开关 —— status: done（2026-10-22，6a-1/6a-2 收口；评审修复轮 en 1,322）
- **原判定**【当时已确认】：en.lproj 1,406 键，"键字符串是否出现在任一 Swift 字面量"比对得 **49 个疑似未用**；计划中的 "DEBUG-only 路由"不存在（`#if DEBUG` = 0）。
- **5d-1 复核（实测，2026-10-22）**：en 现 **1,407 键**（脚本按 `^"key" =` 匹配命中 1,406，漏 1 个含转义引号的键）；重跑得 **62 个未被任何 Swift 文件引用**（较 49 多 13：Cut 4 的 4b 期对 en 表删 11 重复 / 裁 3 冲突 / 补 10 键，键集合已变；两次均未人工复核）。`#if DEBUG` 现 **17 行（全部在 GatherUI，为 `#Preview` 守卫，不是 DEBUG-only 路由）**，Cut 0 的 "0" 已过期。**键一个未删。**
- **5d-2 复核**：62 个未引用键**一个未删**（按任务书刻意留 Cut 6）；本刀只做文档/基准/LSH skip，不改 `Resources/*.lproj`。
- **6a-1（实测）**：删 63 en + 1 zh key（en 1,407→1,344、zh 10→9），保留 `检测模型路径`（测试钉英文值）；存量孤儿实测 32（审计仅 1 是整键子串误判），31 个登记 `legacyUnusedOrphans`。
- **6a-2（实测）**：删 12 个死符号（净 -63 行）、31 个孤儿 key（en 1,344→**1,313**）、14 处旧 section 注释；`LocalizationParityTests` allowlist 32→1，删除 `legacyUnusedOrphans`，新增"孤儿键（en 表有、代码无）仅限 allowlist"断言。
- **调试开关**：`#Preview` 14 块 / `#if DEBUG` 16 行有效（grep 18 含 2 行注释），全部是 Preview 守卫，无 DEBUG-only 路由；暂不纳入 hard fail。
- **验收（最终收尾实测，2026-10-22）**：en **1,322** 键 / zh **9**；`^"` 计 1,322 条（简单匹配 `^"[^"]+"[[:space:]]*=` 得 1,321，差 1 为含转义引号的键 `确定要删除 \"%@\" 吗？…`）；孤儿 key allowlist 1（`检测模型路径`，测试构造）；parity 测试 7 例；app 581/66（6c 时点）。1,313 是 6c 时点值，评审修复轮新增 9 个 plural/#one/FaceModelPathIssue 键。
- **残余**：删键为静态证据 + parity 断言，未做真实 en 界面逐页 A/B（GUI 不可自动化；见 cut6 审计 §7.3-6）。

## 3. 死表 / 死列 / 死索引审计（CL-14）

### 3.1 方法与口径
- 44 张表取自 `Schema.swift` 的 `CREATE TABLE IF NOT EXISTS`，与 `docs/fixtures/schema.snapshot.json` 的 44 表逐一对应（集合一致）。
- "core 源引用" = 除 Schema/Migrations 外，Sources 中 SQL 字面量命中的次数；"测试" = core+app Tests 命中次数；app 写入次数极少（仅 photos 7、assets 13、writeback_items 2、persons 2）。
- 表名/列名也会出现在 README/注释中，已排除；SQL 拼接（`\(Self.rawExtensions)`）会让计数偏低，故低计数先标【疑似】再人工核。

### 3.2 44 表逐表判定

| 表（列/索引） | core 源引用 | 测试 | 判定 | SchemaV1 |
| --- | --- | --- | --- | --- |
| sessions (13/0) | 26 | 53 | 保留；含历史列 | 保留，见 §3.3 |
| analysis_runs (9/1) | 5 | 7 | 保留（活动流 `WorkspaceStatusService.swift:265`） | 保留 |
| photos (16/7) | 100 | 180 | 保留；metadata/result 为历史列 | 保留，删 2 列 |
| assets (5/0) | 11 | 33 | 保留；2 列只写 | 保留，删 2 列 |
| asset_files (14/4) | 25 | 27 | 保留 | 保留 |
| asset_members (6/1) | 12 | 11 | 保留 | 保留 |
| asset_link_candidates (9/1) | 10 | 2 | 保留 | 保留 |
| session_assets (5/1) | 13 | 7 | 保留 | 保留 |
| sidecar_bindings (7/0) | 8 | 3 | 保留 | 保留 |
| sidecar_binding_files (2/1) | 5 | 3 | 保留 | 保留 |
| **asset_file_metadata (15/0)** | **0** | **0** | **死表**【已确认】 | **删除** |
| sidecar_metadata_state (6/0) | 3 | 0 | 保留（`AssetRepo` 读写） | 保留 |
| asset_backfill_state (11/1) | 6 | 4 | 保留；2 列零引用 | 保留，删 2 列 |
| analysis_jobs (24/3) | 26 | 31 | 保留（核心队列） | 保留 |
| asset_analysis (11/2) | 9 | 11 | 保留 | 保留 |
| face_observations (19/2) | 24 | 25 | 保留；3 列疑似镜像 | 保留，见 §3.3 |
| face_identity_feedback (8/1) | 7 | 0 | 保留（FaceFeedbackRepo） | 保留 |
| face_analysis_state (6/1) | 6 | 5 | 保留 | 保留 |
| face_cluster_state (3/0) | 5 | 2 | 保留 | 保留 |
| face_clusters (10/2) | 28 | 21 | 保留；member_count 只写 | 保留，删 1 列 |
| face_cluster_members (7/2) | 23 | 13 | 保留 | 保留 |
| role_bindings (7/0) | 22 | 9 | 保留 | 保留 |
| similarity_hashes (6/3) | 11 | 20 | 保留 | 保留 |
| similarity_results (7/1) | 10 | 20 | 保留 | 保留 |
| similarity_result_members (4/2) | 6 | 1 | 保留 | 保留 |
| similarity_cluster_state (5/1) | 4 | 2 | 保留 | 保留 |
| similarity_cluster_meta (8/0) | 4 | 1 | 保留（V1 加 algorithm_version 等） | 保留 |
| **writeback_items (14/2)** | 16 | 4 | **替换** | delivery_items |
| app_settings (2/0) | 4 | 1 | 保留 | 保留 |
| persons (8/1) | 26 | 5 | 保留 | 保留 |
| person_embeddings (9/2) | 14 | 8 | 保留；3 列只写 | 保留，删 2 列 |
| person_photos (7/4) | 25 | 2 | 保留 | 保留 |
| photo_metadata_cache (22/5) | 23 | 10 | **镜像读模型，保留**（FilterEngine 依赖） | 保留，见 §3.3 |
| duplicate_groups (8/1) | 6 | 8 | 保留 | 保留 |
| duplicate_group_members (8/2) | 16 | 5 | 保留 | 保留 |
| **smart_albums (10/0)** | 5 | 1 | **疑似未接线**：仅 Router `album.*` | 候选删除 |
| **workflow_templates (6/0)** | 5 | 0 | **疑似未接线**：仅 Router `template.*` | 候选删除 |
| culling_decisions (11/2) | 14 | 9 | 保留 | 保留 |
| culling_history (5/1) | 9 | 7 | 保留（CullingView:698/794） | 保留 |
| navigation_groups (10/1) | 11 | 6 | 保留 | 保留 |
| **metadata_outbox (16/2)** | 44 | 14 | **替换** | deliveries |
| **metadata_outbox_sessions (4/1)** | 25 | 5 | **替换** | delivery_sessions |
| metadata_keyword_origins (6/1) | 8 | 8 | 保留 | 保留 |
| **schema_version (2/0)** | 1（误命中列名） | 4 | **迁移设施**【已确认】 | **删除**，用 user_version |

计数说明：核心非 schema/migration 引用；列/索引来自 DDL。

### 3.3 死列 / 镜像列 / 历史列

**A. 确认死列（无任何读点，SchemaV1 不建）**

| 表.列 | 证据 | 结论 |
| --- | --- | --- |
| asset_backfill_state.path_conflicts / sidecar_conflicts (Schema:160-161) | 除 DDL/迁移外 0 命中；其余列在 `AssetRepo.swift:129-199` 读写 | 删 2 列 |
| face_clusters.member_count (266) | 只写：`FaceRepo.swift:680` 重算、`:708` INSERT、`:1004` UPDATE；读取用 `COUNT(*)` 现算（`:743`），`:10` 注释明说"派生缓存" | 删 1 列 |
| person_embeddings.quality / face_bbox (395/394) | 只写：`PersonRepo.swift:404` INSERT 列表；查询只取 `person_id, embedding, face_observation_id`（`:749`） | 删 2 列（created_at 保留） |
| assets.capture_fingerprint / status (56-57) | 只有 INSERT（`AssetRepo.swift:997`、`:1124`），无 UPDATE/SELECT 谓词；`status` 恒 `'active'` | 删 2 列 |
| metadata_outbox.owner_session_id / created_by_session_id (518-519) | 只写 + 原样拷贝（`MetadataOutboxRepo.swift:446`、`AssetRepo.swift:708-713`），无 WHERE/ORDER BY；两索引因此无支撑（见 §3.4） | 随表替换消失 |
| schema_version.applied_at (557) | 除迁移 INSERT（`Migrations.swift:82`）外 0 读点 | 随表删除 |
| writeback_items.backup_path (353) | 只写（`WritebackRepo.swift:80`），`backupPath` 无消费方（仅 record 字段 `:15/35/51`） | 随表替换消失 |
| photos.metadata / photos.result (44-45) | 仅 INSERT 常量 `'{}'`（`PhotoRepo.swift:294`），全仓无 `UPDATE photos SET metadata/result`；读取只是透传（`CullingService.swift:2435-2436`、FilterEngine:86 投影） | 删 2 列（Cut 2 同步删透传字段） |

**B. 疑似 / 需产品决策**

| 项 | 证据 | 建议 |
| --- | --- | --- |
| sessions.writeback_status / failed_writeback_count | 只有 INSERT/UPDATE（`SessionRepo.swift:74/91/150/155`）+ 行投影；app 侧仅测试引用（7 处） | delivery 接管后删 2 列 |
| sessions.import_source | 只有 INSERT + `SessionRow` 投影（`:12/74/91`），app 生产代码 0 引用（7 处均在测试） | 疑似删；`source_path`/`truncated_import` 被 UI 使用，保留 |
| face_observations.source_file_size / source_file_mtime_ms / analysis_signature (220-222) | 与 `face_analysis_state`(247-260) 同值冗余；在 `FaceRepo.swift:357-393` 被 join 读取做陈旧判定 | **保留**（读路径依赖），但 V1 应合并到单一 analysis_state，避免双写 |
| photo_metadata_cache 的 width/height/file_size/file_mtime | 与 photos.width/height、asset_files 冗余；但 `FilterEngine.metadataFields`(FilterEngine:60-64) 允许按这些列过滤/排序 | **保留**（读模型），V1 只做列级去重需先改过滤 SQL |

**C. 镜像表说明（photo_metadata_cache）**
- 它是 `photos`（path/filename/宽高）+ `asset_file_metadata`（EXIF）+ `sidecar_metadata_state`（rating/label/keywords）的**反规范化读模型**，写入在 `MetadataCacheRepo.swift:134-141`（upsert），读取在 `FilterEngine`（`pmc.*`）与 `MetadataSyncCoordinator`。
- 与它完全同构的 `asset_file_metadata` 是**上一代镜像**（0 引用），确认删除；photo_metadata_cache 保留但应作为"唯一"镜像，V1 不再复制一份 asset_file_metadata。

**D. sessions 历史列**
- 导入时代：`import_source`、`source_path`、`truncated_import`（`Schema:12-14`；UI 仅用后两者）。
- outbox 时代：`writeback_status`、`failed_writeback_count`（`:11/18`）。
- C1 同步：`reload_acked_at`（`:15`，`MetadataSyncCoordinator.swift:944` 仍在使用）。
- 派生计数：`photo_count`/`index_seq`（UI 用 `photo_count` 显示"已索引 ≥N 张"，`SessionControlView.swift:466-471`；`index_seq` 是分析过期游标，保留）。

### 3.4 索引审计（62 个）

- **确认死索引（无查询支撑且非 FK 级联所需）**
  1. `idx_metadata_outbox_session_status`（Schema:637）— 前导列 `owner_session_id` 无读点；
  2. `idx_metadata_outbox_owner_module`（Schema:638）— 同上；
  3. `idx_asset_backfill_status`（Schema:591）— 查询只按主键 `session_id`（`AssetRepo.swift:129/188`），`status` 无谓词；
  4. `idx_similarity_cluster_state_component`（Schema:614）— 读路径为 `WHERE session_id = ? ORDER BY rowid`（`SimilarityClusterStateRepo.swift:109-110`），`component_index` 无谓词。
- **看似死但其实必须保留（FK 级联索引）**：`idx_writeback_items_photo`（Schema:616）、`idx_duplicate_members_photo`（631）——虽然查询不按 photo_id，但 `ON DELETE CASCADE` 子表需要前导索引（`PRAGMA foreign_keys = ON`，DB.swift:82），删了会让删照片变全表扫。**索引审计必须区分"查询索引"与"FK 级联索引"**。
- **需 EXPLAIN QUERY PLAN 验证（Cut 2）**：`idx_photos_created_at`（573，仅 `sortBy=created_at` 排序用）、`idx_metadata_cache_camera_make`（628，FilterEngine suggest LIKE）、`idx_writeback_items_session`（615，替换表后消失）、`idx_similarity_members_result_group`（613）、`idx_analysis_jobs_scope`（595，仅 `scope_type+scope_id`）、`idx_asset_backfill_status` 已列死。

### 3.5 SchemaV1 建议保留/删除清单

- **删除 4 表**：`asset_file_metadata`、`schema_version`、`smart_albums*`、`workflow_templates*`（* = 若产品确认未接线；确认前不删）。
- **替换 3 表 → 4 表**：`metadata_outbox`、`metadata_outbox_sessions`、`writeback_items` → `deliveries`、`delivery_sessions`、`delivery_items`、`delivery_intents`（§4.3 DDL）。
- **保留 37 表**（其中 `photo_metadata_cache` 作为唯一元数据镜像读模型）。
- **列**：删除 §3.3-A 的 8 组共 **13 列**（不含整表删除/替换）；`sessions` 的 3 列在 delivery 落地后删（共 16 列）；`face_observations` 3 列先保留、Cut 2 合并分析状态后再评估。
- **索引**：V1 按"查询清单 + FK 清单"重建，不照抄 62 个；删除 §3.4 的 4 个死索引，保留 FK 级联索引；其余用 EXPLAIN 校准。
- **CHECK 约束**：`sessions.status`、`photos.status`、`analysis_jobs.status`、`deliveries.status/items.status`、`duplicate_groups.resolution`、`face_clusters.status`、`culling_decisions.decision/color_label`（现只有后两者有 CHECK）。

## 4. 未使用 public 符号审计（CL-13）

### 4.1 容量
- public 声明 2,298；其中 **256 个 type/func 在"自身文件外 core Sources + app Sources"零引用**（含 99 个 `*Params` DTO）；256 个里 **85 个连测试都不引用**，211 个测试引用 ≤2 次。
- 根因：Router 用 `requiredString(params, ...)` 手工解析（`SessionCommandRouter.swift:1541-1553`），`Protocol/*.swift` 里的 99 个 `*Params` 结构体**从未被构造**——Cut 1 删除 Router 时应一并删除这些 DTO，而不是改造成 API 输入（API 输入另建）。

### 4.2 候选清单（≥30，全部标【已确认】零外部引用；"测试"列为引用次数）

| 符号 | 类型 | 位置 | 测试 | 判定 |
| --- | --- | --- | --- | --- |
| FaceClusteringImpact | struct | Face/ClusteringImpact.swift:159 | 2 | 删或接线（CL-13） |
| FaceClusteringParameters | struct | Face/ClusteringImpact.swift:128 | 45 | 同上（仅测试用） |
| FaceClusteringImpactEstimator | enum | Face/ClusteringImpact.swift:248 | 21 | 同上（仅测试用） |
| FaceImpactObservation | struct | Face/ClusteringImpact.swift:225 | 5 | 同上 |
| FaceClusteringImpactError | enum | Face/ClusteringImpact.swift:241 | 4 | 同上 |
| FaceEmbeddingShapeValidator | enum | Face/EmbeddingModel.swift:220 | 12 | 仅测试用；降 internal 或删 |
| FaceEmbeddingFingerprint | enum | Face/EmbeddingModel.swift:281 | 10 | 同上 |
| FaceEmbeddingModelShape | struct | Face/EmbeddingModel.swift:168 | 7 | 同上 |
| FaceProvider | enum | Face/Provider.swift:21 | 8 | 死枚举；删 |
| matchAgainstLibrary | func | Face/Matcher.swift:196 | 29 | 仅测试；合并到批量 match |
| reuseSimilarityHashes | static func | Services/SimilarityService.swift:446 | 7 | 仅测试；删 |
| validateNavigationParameters | func | Services/NavigationService.swift:30 | 10 | 仅测试；删 |
| metricFromPixels | func | Services/QualityService.swift:65 | 4 | 仅测试；降 internal |
| rawVariantSQL | static func | Repositories/PhotoRepo.swift:170 | 4 | 仅测试；降 internal |
| statFingerprint | static func | Face/EmbeddingModel.swift:332 | 5 | 仅测试；降 internal |
| rollScore / sizeScore | static func | Face/FaceQuality.swift:34/29 | 6 | 仅测试；降 internal |
| intersectionOverUnion | static func | Face/FaceQuality.swift:56 | 4 | 仅测试；降 internal |
| similarityTransform | static func | Face/Alignment.swift:200 | 4 | 仅测试；降 internal |
| coreML | static func | Face/EmbeddingModel.swift:56 | 3 | 仅测试；降 internal |
| excludeExactDuplicateHashes | func | Services/DuplicateService.swift:80 | 3 | 仅测试；删 |
| getClusterThumbnailPath | func | Repositories/FaceRepo.swift:801 | 3 | 仅测试；删 |
| canTransition | func | Repositories/MetadataOutboxRepo.swift:42 | 13 | 随 outbox 表删除 |
| ExportNaming | struct | Protocol/Export.swift:110 | 26 | 命令面 DTO；删 |
| FaceCluster / FaceObservation / BindingData / FaceModelsStatusData | struct | Protocol/Face.swift:235/176/220/161 | 5/4/2/3 | 命令面 DTO；删 |
| ResponseOk / ResponseErr / GroupData / ImageRef / EngineStatusData | struct | Protocol/Core.swift:223/259/549/550/75 | 4/5/0/0/0 | 命令面 DTO / 旧 IPC；删 |
| DimensionsRequest / DimensionsResult / DecodeRequest / DecodeResultPayload | struct | IPC/ImageCommands.swift:11/22/61/72 | 0 | Helper 旧协议；删或降级 |
| SettingsRow | struct | Repositories/SettingsRepo.swift:6 | 6 | 仅测试；降 internal |
| CullingPhotoRow | struct | Services/CullingService.swift:155 | 0 | Service 内行类型误 public（own=45）；降 internal |
| CullingUpdateContext | struct | Services/CullingService.swift:252 | 0 | 同上 |
| CullingHistorySink | class | Services/CullingService.swift:241 | 0 | 同上 |
| DBStatement | class | Database/DB.swift:241 | 0 | 无外部构造；降 internal |
| FaceIdentityFeedback | struct | Repositories/FaceFeedbackRepo.swift:4 | 0 | 无消费；删/降级 |
| VectorIndexError / HnswHits / LshHits | enum/struct | Face/VectorIndex.swift:794/90/561 | 9/0/0 | HnswHits 随 HNSW 删；VectorIndexError 保留 |
| CullingUpdateParams 等 99 个 `*Params` | struct | Protocol/*.swift（Culling.swift:288 等） | 2-4 | **Router 手工解析，DTO 从未构造**；Cut 1 删 |

> 计数口径："自身文件外 core Sources + app Sources"；测试引用数不代表生产可用性。

### 4.3 特别检查

- **FaceEncoder.embeddingDim**【已确认】：`Face/Encoder.swift:95/109/128/142` 四处形参，函数体（`:144-233`）从未读取；默认 512 只是签名装饰。V1 删除形参，维度由 `FaceEncodeResult.embedding.count` + `embedder.spec` 决定。
- **ClusteringImpact**【已确认】：442 行；`FaceClusteringImpact`/`Estimator`/`Parameters` 的引用 100% 在文件自身 + `ClusteringImpactTests`；**无任何 Service/UI 入口**（FaceKeywording 的"重聚类"按钮不走预估）。要么接 UI，要么删；不允许"以后可能用"。
- **CosineHnswIndex / HnswConfig**【已确认】：`VectorIndex.swift:56/90/104`；生产引用 0（仅 `GatherCoreBenchmarks/main.swift:210/323` + `VectorIndexReconciliationTests`）；生产 ANN 路径是 `CosineLshIndex`（`Clusterer.swift:233`、`Matcher.swift:126`）。按计划 §6 删除，保留 `VectorNeighborIndex` 协议。
- **ImageCache 残留**【已确认】：`Database/ImageCache.swift:1-102` 现仅含 `SHA256` 结构（纯 Swift SHA-256）；`:5-6` 注释说明原缓存已删；3 处 "ImageCache" 均为注释。处置=重命名文件（`SHA256.swift`），不是删代码。
- **CommandRouter 相关**【已确认】：`CommandRouter.swift:34` protocol、`:7` WebResponse、`NativeCommandClient.swift:27` final class；39 处引用 / 16 个文件（含 Package.swift 注释与 3 个测试文件；UI 调用点 12 个）。全部随 CL-01 删除。

## 5. 重复实现清单（CL-04/05/07/12/17 + 附加）

| # | 类别 | 位置（文件:行） | 份数 | 合并目标 |
| --- | --- | --- | --- | --- |
| 1 | stale 守卫 | GalleryViewModel.swift:241/725-754；LibraryViewModel.swift:334/665-691；SimilarityViewModel.swift:319/472-482；CullingView.swift:133/591-619 | 4 | `RequestGate`（2026-10-22 删除；CL-04 deferred，未统一） |
| 2 | 度门控 BFS | ClusterEngine.swift:329/512/587；IncrementalClusterer.swift:346/432（+ SimilarityService.swift:763 回退） | 5+1 | `ClusterGraph` 单一 BFS + `ClusterPipeline` |
| 3 | 双聚类 | ClusterEngine.swift（753 行）+ IncrementalClusterer.swift（766 行） | 2 | 同上；保留 parity 测试 |
| 4 | 缩略图 loader | PhotoThumbnailView.swift:222-260 与 FaceCropThumbnailView.swift:415-449；@State :164-168 vs :289-293；.task :211 vs :342 | 2 | `ThumbnailLoader` + 统一 cache key |
| 5 | 测试 helper | LockedBox ×3（SimilarityViewModelTests:55 / LibraryViewModelTests:20 / GalleryViewModelTests:22）；AsyncGate ×4（SimilarityViewModelTests:16 / FaceKeywordingServiceTests:27 / SimilarityServiceTests:45 / DuplicateServiceTests:47）；ResponseBox（CommandSurfaceRuntimeTests:31）；JobEventSink（GlobalInfraTests:124） | 9 | 每包 1 份 `Tests/Support`（跨包不能共享） |
| 6 | errorMessage 出口 | 7 个 VM：CullingView:102、SettingsView:105、ExportView:31、DuplicatesView:118、SessionControlView:26、FaceKeywordingView:86、SimilarityViewModel:332 | 7 | `GatherError` + `CommandError` 单一出口（`ViewState` 已删） |
| 7 | rawExtensions | AssetRepo.swift:1190（定义）、PhotoRepo.swift:163（排序投影）、PhotoAssets.swift:12（再导出） | 3 | `PhotoFileTypes`（Protocol） |
| 8 | 轮询间隔 | SessionControlView.swift:236/239、SimilarityViewModel.swift:398、GalleryViewModel.swift:224（注释引用） | 3+ | `PollingPolicy` |
| 9 | SQL 直写 Services | Services 下 15 个文件共 128 处 `prepare(`（DuplicateService 25、IndexerService 21、CullingService 15…） | 128 | Cut 2 收进 Repository；`check-db-boundary.sh` = 0 |

## 6. 清理 baseline 数字（Cut 0 冻结）

| 指标 | 数值 | 口径 |
| --- | --- | --- |
| Swift 文件 | 257 | core 93+88，app 46+29（排除 .build/swbuild.tmp） |
| 总 LOC | 102,938 | 同上；= 93/37,604 + 88/28,441 + 46/29,083 + 29/7,733 + Package.swift 77 |
| public 声明 / 行 | 2,298 / 3,178 | 声明器解析 / `^\s*public` 行 |
| 表 / 列 / 索引 / FK | 44 / 391 / 62 / 63 | Schema.swift DDL |
| 命令（sync/async） | 118（82/36） | Router `case "..."` |
| `@unchecked Sendable` | 40 行（非注释，Sources + app 功能页） | `docs/cleanup-baseline.json`；D-006 修正 scope 后重新生成 |
| `try?` | 348 行（非注释，Sources + app 功能页） | 同上；D-006 修正 scope 后重新生成 |
| Services `prepare(` | 128 | ratchet；core 全源 516 |
| `@Test` | 994 core / 301 app | grep `@Test` |
| skip / withKnownIssue | 0 / 0 | ratchet 口径（`.skipped` 字段 18 行不计） |
| TODO/FIXME | 0（非注释） | ratchet；含注释 21 |
| l10n 直调 `.l(` | 1,439 | 计划 1,497，漂移 -58 |
| `.id(languageVersion)` | 1 | RootView.swift:423 |
| Review 文档 | 23 个条目 | docs/reviews |
| lproj 键 | en 1,406 / zh-Hans 10 | zh 为最小表；49 键疑似未用 |
| 死表 / 死列 / 死索引 | 4（含 2 候选）/ 13 / 4 | 本文 §3 |
| 零外部引用 public type/func | 256（85 个连测试也不用） | 本文 §4 |
| 构建垃圾 | 已删除 | 3 个空 swbuild.tmp 与根 .DS_Store 已物理删除（C 任务） |

> 与 `docs/cleanup-baseline.json` 的差异：JSON 的 `try_optional=348`、`unchecked_sendable=40`、`services_prepare=128`、`todo_fixme=0`、`with_known_issue=0` 为 ratchet 官方基线，本表同口径复现一致；其余为本表补充的结构性基线。

## 7. 状态列与 owner 规则

### 7.1 状态定义
- `pending`：已盘点、未开工（必须填目标 Cut）。
- `in-progress`：当前 Cut 内正在删除/替换；**只能存在 ≤1 个 Cut**，跨 Cut 未完成必须在 Cut 退出评审时改 `blocked` 并写原因。
- `done`：替代实现 + 对等测试 + 旧代码删除**同一 PR** 完成；附验收命令输出。
- `blocked`：必须写 `阻塞原因 / 决策人 / 期望解除 Cut`；连续 2 个 Cut 未解除 → 升级架构评审，二选一（删或正式接线）。
- `deferred`：决定本轮不做（删除/降级/推迟），必须写理由与解除条件；不计入 done，也不阻塞 Cut 退出。

### 7.2 owner 规则
- 每条 CL 一个 owner（= 该 Cut 的模块负责人），不共享 owner；reviewer 由另一模块负责人担任。
- Cut 1 owner：CL-01/11；Cut 2：CL-02/03/14；Cut 4：CL-04/07/08/09/10/17；Cut 5：CL-05/06/13/20；Cut 6：CL-12/16/18/19；CL-15 归 Cut 0。
- `done` 判定必须附：删除行数、删除文件数、删除 public 符号数、删除表/列/索引数（§8.1 #4）。
- 每次改状态必须同 PR 更新本文件；CI 用 `check-death-list.sh` 校验：不允许 CL-01..CL-20 长期 `in-progress`。
- ratchet：`docs/cleanup-baseline.json` 只降不升；任何指标回升即 PR 拒绝。

## 8. 已确认 / 疑似 / 待决（供 Cut 0 评审）

- 【已确认】44 表与 snapshot 一致；118 命令；128 处 Services prepare；4 套 stale 守卫；5 份 BFS；3 表 outbox/writeback；3258/1628 行规模；`asset_file_metadata` 0 引用；`ImageCache.swift` 只剩 SHA256；`embeddingDim` 未读；`#if DEBUG` = 0。
- 【疑似】`smart_albums`/`workflow_templates` 未接线（仅 Router 命令可达，UI 0 调用）；`photo_metadata_cache` 列冗余；49 个 lproj 键未用；`sessions.import_source` 可删；`idx_asset_backfill_status` 等 4 索引无用（需 EXPLAIN 复核）。
- 【需验证】WAL/事务预算相关行为；10k 聚类基准；`FilterEngine` 排序对 `p.created_at` 索引的真实依赖；删除 `sessions.writeback_status` 对 C1 同步页面文案的影响。
- **计划漂移**：l10n 1,497→1,439；Router 依赖 24→20；ADR 34/43→实际 35/44；v34 fixture 不存在；CommandID 不存在；`#if DEBUG` 路由不存在；errorMessage VM 6→7；BFS 4→5。
- **未做**：CL-15 的物理删除（本任务只写文档，未获删除授权）；CL-01..CL-20 的删除动作均未执行。

## 9. 复现命令

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather
# 规模
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print | wc -l
# 表/列/索引/外键
grep -c 'CREATE TABLE IF NOT EXISTS' desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift
grep -c 'REFERENCES' desktop/native/gather-core/Sources/GatherCore/Database/Schema.swift
# 命令面
grep -c 'case "' desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
# 死表（应为 0）
grep -rn 'asset_file_metadata' --include=*.swift desktop/native | grep -v 'Schema.swift\|Migrations.swift'
# 未使用 public（示例）
grep -rn '\bCullingUpdateParams\b' --include=*.swift desktop/native
# 重复 helper
grep -rn 'class LockedBox\|class AsyncGate' --include=*.swift desktop/native/*/Tests
# ratchet
./scripts/check-cleanup-ratchet.sh
```

## 10. 最终收尾复核（2026-10-22，docs / scripts / 构建产物）

- **脚本**：`check-duplicate-symbols.sh` 删除 RequestGate 规则与“Cut 4 落地”文案（112→100 行，输出 4→3 项）；`check-docs.sh` 新增当前文档 md 链接存在性检查（165→211 行）。
- **stale 符号**：`cut6-cleanup-audit` 的“RequestGate 1 份”更正为 0；CL-04 残余改“脚本已修 / LoadPhase 注释经复核已无 ViewState”；`JobScopeCheckpoint` 生产引用为 0（旧“被 LiveSessionAPI/Dashboard 引用”结论有误），已于 2026-10-22 收尾清理删除，测试断言改用 `JobCreateParams.metadataScanRequestedPathsKey`。
- **死链**：非 archive 当前文档 **0 缺失**（`face-clustering-benchmark.md` 13 条旧 `GatherCore` 源码链接改到 `GatherAnalysis`/`GatherDomain`）；归档 33 条旧源码链接按快照保留并在 archive 索引注明。
- **构建产物**：删除 `release/Gather.app`（22 MB）与 4 个非活动 `.build` scratch（≈2.19 GiB）；保留并行构建正在写入的 `.build/scratch` 与两包增量缓存 `.build`。
- **A/B 档收尾清理（2026-10-22）**：26 文件头 + 4 交付端口注释；删 `JobScopeCheckpoint`（1 文件/22 行，测试改 `JobCreateParams.metadataScanRequestedPathsKey`）、`IndexerService.sha256File`、`GatherProgressBar` 4 参数、`GatherLocalization.appLocale`、2 私有常量、`VectorIndex.Candidate`、`FaceSimMutationPort`、2 个未调用 helper、`makeGatherTestDB`（22 处→`makeTestDB`）；57 文件 +84/−208。core **1,100/165**、app **617/68**、9 门禁、schema verify（43 表/373 列/69 索引/62 FK/user_version=2）绿。
- **实测**：en **1,322** / zh 9；测试文件 **166**；535 Swift 文件 / 138,829 行（17:00 采样；并行工作区仍在变）；ratchet **53/235/127/0/0**（baseline try? 240）；docs/test-catalog/ratchet 三门禁全 OK。详见 [final-cleanup-docs.md](final-cleanup-docs.md)。

---

*本文件由 Cut 0 盘点产出；任何删除动作前先在本表把对应项改为 `in-progress` 并写明目标 Cut 与 owner。*
