# 测试审计（Cut 0 · 2026-10-21）

> 权威计划：`docs/reviews/refactor-design-breaking-2026-10-21.md`（§1 删除清单、§7.2 测试策略、§8.3 判定规则、§8.7 指标、§9 Cut 0）。
> 口径：**只读审计**，未改任何源码/测试/脚本。所有条数来自源码 `@Test` / `@Suite` 机械计数（命令见附录 A），并与 `docs/reviews/architecture-review-2026-10-21.md:368` 的实测台账（core 994 / 141 suites、app 298 / 32 suites）对账一致。
> 标注：**【已确认】**= 源码/计数据实；**【疑似】**= 需 Cut 1/2 决策确认。

> **状态（2026-10-22）**：历史快照（基线 core 994/141、app 298/32）。D1/D2/D3 等命令面测试已随
> Cut 1 删除；Cut 5 / 6a 的删除/新增/skip 变动见 §7「滚动对账」，当前实测
> **core 1,092/157、app 581/66**（§1–§6 的数字保持 Cut 0 口径，不随 Cut 回填）。
> 6a-1/6a-2 另删 63+1+31 个 lproj 键、12 个死符号；en 1,407→1,344→**1,313**、zh 10→**9**，
> 孤儿 key allowlist 收到 1（检测模型路径），详见 §7 与 D-160/D-161。
>
> **skip 门禁（2026-10-22 修复）**：`check-test-catalog.sh --strict` 已识别 `.enabled(if:)`、
> `.disabled`（`@Test`/`@Suite`）与 `withKnownIssue`，每条 skip 必须带 `skip-owner`、到期、原因；
> `FaceRealPhotoPipelineTests` 3 条已补元数据与手动 CI 条件（D9 仍未关闭）。
> `swift test` 的 “N tests passed” 包含 skip，**有效执行数 = 声明数 − skip 数**；
> 统计“通过”时不得把 skip 算作有效执行，门禁与负例见 §4.1。

> **状态（2026-10-24 测试分层优化 + 复审修复，当前）**：
> - 默认套件实测（M5 Pro / Debug / 串行 / 不含构建）：**core 1,246 例 / 184 套件**
>   （含新增的 matcher LSH 召回门；上一轮同机采样 10.1s 为并行负载下的读数）、
>   **app 650 例 / 74 套件 ≈ 12.0s**（含 5 条菜单可用性用例）；skip 11 条（默认）/
>   3 条（`GATHER_MODEL_TESTS=1`）。随机器负载浮动。
> - 已从默认套件迁出/精简：`FaceClusteringAccuracyTests`（统计基线，删除，保留 3 个确定性
>   behavior 用例到 `FaceClustererQualityRetryTests`）、`FaceMarginDecisionTests` 的 7 轮
>   sweep（只留 1 条 margin=0/0.01 生产路径用例）、`VectorIndexReconciliationTests` 的
>   1000×100 召回（只留配置/空索引/自召回；3.5MB fixture 与生成器删除）、
>   `MatcherReconciliationTests` 的 recall>=0.95 门、`IncrementalClustererPerformanceTests`
>   的墙钟门（改功能复用断言）、`ClusterGraph` n=32769（改为可注入 `maxBitsetEntries` 的
>   n=33 分支测试）、4MB 哈希三重载荷（改为 256B 注入分块 + 一次 4MB+1）、
>   `IndexerChecksumParityTests`（合并删除）。
> - 质量/性能指标迁到 `gather-core-benchmarks --quality/--margin/--smoke`；夜间 workflow
>   `.github/workflows/nightly.yml` 跑 `GATHER_MODEL_TESTS=1` 集成与 release benchmark。
> - skip 站点 **11**：真实照片 3 + 模型集成 8；每处均有 `skip-owner`/到期/原因。
> - 完整 `.app` bundle 只在 release/packaging 构建；PR 的 `gather-app` job 已删除
>   `Native bundle build` 步骤，日常测试不跑 `build.sh`。

---

## 1. 现状统计

### 1.1 总账

| 包 | 测试文件 | @Test | @Suite 声明 | suite 容器（含隐式类型） | 默认跳过 | .disabled | withKnownIssue |
| --- | --- | --- | --- | --- | --- | --- | --- |
| gather-core | 88（含 2 个无测试的 Support/Harness） | **994** | 93 | **141**（台账；本次按类型容器复算 138，差 3 为同行 `@Suite`+`struct` 声明） | 8（4 处 `.enabled(if:)`） | 0 | 0 |
| gather-app | 29（含 3 个 Support helper） | **298** | 32 | **32** | 0 | 0 | 0（仅 1 处注释提及） |

与计划目标：core 994 → `~700`（§7.2 写 `≥700`）、app 298 → `~250`。本审计给出的可达预算：**core 761 / app 253**（§3.5），符合 `≥700 / ≥250`；要再压到 ~700 需二轮合并（§3.5 末尾，【疑似】需拍板）。

### 1.2 core 按目录

| 目录 | 文件 | @Test | 说明 |
| --- | --- | --- | --- |
| `Services/` | 26 | **441** | 单一最大块；Culling/FaceKw/Indexer/Job 四个套件占 182 |
| `Protocol/` | 17 | **191** | 全部是「TS 字段名逐字一致」的 JSON 契约（`CullingContractTests.swift:2`、`SessionContractTests.swift:2` 等） |
| `Database/Repositories/` | 17（15 有效） | **166** | 11 个 Repo × CRUD 字段往返 |
| `Database/`（根） | 3 | **18** | `MigrationTests.swift` 10、`DatabasePragmaTests.swift` 8 |
| `Face/` | 12 | **97** | 聚类质量/对齐/嵌入/增量/影响面 |
| `Reconciliation/` | 7（1 Harness） | **24** | dHash/聚类/matcher/维度/向量 golden |
| `IPC/` | 1 | 19 | Helper 协议 |
| `Image/` | 1 | 13 | RAWDecoder（运行时生成图片，无二进制夹具） |
| `Similarity/` | 1 | 10 | IncrementalClusterer |
| `Concurrent/` | 2 | 9 | BatchRunner/BatchCursor |
| 根（Helper/Logger） | 2 | 6 | |
| **合计** | **88** | **994** | |

core 最大套件：`CullingServiceTests` 67（10 suites，323–1883）、`FaceKeywordingServiceTests` 48（12 suites，217–1454）、`IndexerServiceTests` 35（7 suites）、`JobServiceTests` 32、`WorkspaceStatusServiceTests` 30（138–561）、`SimilarityServiceTests` 30（9 suites）、`DuplicateServiceTests` 27（4 suites）。

### 1.3 app 按文件（298 = 全列出）

| 文件 | @Test | suite |
| --- | --- | --- |
| `ReviewFixTests.swift` | 44 | 1 |
| `GalleryViewModelTests.swift` | 27 | 1 |
| `SimilarityViewModelTests.swift` | 24 | 1 |
| `DashboardViewModelTests.swift` | 22 | 1 |
| `FaceKeywordingViewModelTests.swift` | 22 | 1 |
| `LibraryViewModelTests.swift` | 21 | 1 |
| `GlobalInfraTests.swift` | 15 | 3（l10n / EventCenter / Toast，9/154/241） |
| `IndexHeaderCopyTests.swift` | 13 | 2（9 / 136） |
| `SettingsSaveSemanticsTests.swift` | 12 | 1 |
| `JustifiedLayoutTests.swift` | 11 | 1 |
| `RootViewTests.swift` | 10 | 1 |
| `SidecarXMPProviderTests.swift` | 10 | 1 |
| `InboxItemsTests.swift` | 9 | 1 |
| `LayoutBudgetTests.swift` | 8 | 1 |
| `NativeCommandClientTests.swift` | 7 | 1 |
| `PersonsViewModelTests.swift` | 6 | 1 |
| `ReviewAcceptanceTests.swift` | 6 | 2 |
| `C1PreflightTests.swift` | 5 | 1 |
| `CullingSyncFlowTests.swift` | 5 | 3 |
| `CommandSurfaceRuntimeTests.swift` | 4 | 1 |
| `ErrorLocalizationCoverageTests.swift` | 4 | 1 |
| `GatherAppDelegateTests.swift` | 4 | 1 |
| `FaceReclusterConfirmTests.swift` | 3 | 1 |
| `SettingsCatalogTests.swift` | 3 | 1 |
| `WorkspaceStageMarksTests.swift` | 2 | 1 |
| `DeepModelAcceptanceTests.swift` | 1 | 1 |
| **合计** | **298** | **32** |

---

## 2. 判定规则（直接引用 §8.3，落到本仓的可执行判据）

1. 测试对象已删除 → 删（须与代码删除同一 Cut）。
2. 同行为多套件且无额外边界 → 合并为 `@Test(arguments:)`，保留输入矩阵。
3. 只验证实现细节（私有函数、字符串常量、内部排序、复制一份旧实现做「等价」对拍）→ 删或改行为断言。
4. `.disabled` / `withKnownIssue` 无到期条件 → 修或删。
5. 依赖真实 home / 网络 / 系统状态 → 改临时目录/注入；不能改则删。
6. 历史 bug 回归：被测代码仍在 → 留；代码已删 → 删。

本仓实测：`.disabled` **0**、`withKnownIssue` **0 实际使用**（`SimilarityViewModelTests.swift:804` 只是注释说明「不再用」），所以 §8.7 的「skip=0」当前已满足；真正的风险是 4 处 `.enabled(if:)` 带来的 8 条默认静默跳过（§4）。

> 上述为 Cut 0 快照；2026-10-24 当前为 **11 条** `.enabled(if:)`（真实照片 3 + 模型集成 8），已由 `check-test-catalog.sh --strict` 登记 owner/到期/原因，见 §4.1。

---

## 3. 四类清单（文件:行号 + 理由）

### 3.1 删除（D）

| ID | 位置 | 条数 | 理由 | 何时可删 | 依据 |
| --- | --- | --- | --- | --- | --- |
| D1 | `gather-app/Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift:75-296` | 4 | 直连 `SessionCommandRouter`（`:204-211` `makeDefault`）验证 118 条命令 switch 派发；命令面删除即无对象 | Cut 1 代码删除后 | §1 CL-01/CL-11 |
| D2 | `.../Support/StubCommandRouter.swift:8-37` | 0（helper） | `CommandRouter`/`WebResponse` 的测试桩；10 个测试文件、18 个用例直接构造（清单见 §3.1 备注） | Cut 1 | §1 CL-11 |
| D3 | `.../NativeCommandClientTests.swift:10-154` | 7 | 测 `NativeCommandClient` + 两份 legacy 漏斗副本（`:157-181`）的「等价」对拍；对象删除 + 差分断言属实现细节 | Cut 1 | §8.3-1/3 |
| D4 | `gather-core/Tests/GatherCoreTests/Database/MigrationTests.swift:64-552` | 10 | 35 版迁移链、`schema.snapshot.json`（35/44）、v33 升 v34、备份裁剪；SchemaV1 后全无对象 | Cut 2 | §1 CL-02 |
| D5 | `.../Database/Repositories/WritebackRepoTests.swift:39-236` | 9 | `writeback_items` 表并入 `delivery_items`（§4.3） | Cut 2 | CL-03 |
| D6 | `.../Database/Repositories/MetadataOutboxRepoTests.swift:32-496` | 20 | `metadata_outbox*` 两表并入 `deliveries`；但 `:379`（路径归一）与 `:450`（sidecar 键折叠）两条断言必须迁到 delivery 仓储测试 | Cut 2 | CL-03 |
| D7 | `.../Services/MetadataWritebackStateMachineTests.swift:167-…` | 14 | 双状态机之一；合法/非法迁移矩阵迁入 `DeliveryStateMachineTests` | Cut 2 | CL-03 |
| D8 | `.../Face/ClusteringImpactTests.swift:85-649` | 9 | 被测 `FaceClusteringImpactEstimator` 在生产代码中**零调用**：全仓仅 `Sources/GatherCore/Face/ClusteringImpact.swift:248` 自引用（CL-13「无 UI 入口」） | Cut 5（随代码删） | 【已确认】grep |
| D9 | `.../Face/FaceRealPhotoPipelineTests.swift:38-80` | 3 | `.enabled(if: GATHER_FACE_FIXTURE != nil)`，CI 永绿但零执行；§8.3-4 要求到期条件 → 移入 `scripts/manual` 或删 | **2026-12-31 前**（已补 `skip-owner`/到期/原因，门禁可见；仍须受控 fixture 或移入 `scripts/manual`） | §8.3-4、§4.1 |
| D10 ✅ | ~~`.../Reconciliation/VectorIndexReconciliationTests.swift:121`~~（**已删，5b-2a**） | 1 | `hnswTopKMatchesFixture` 随 HNSW 删除（CL-06）；LSH 3 条保留（另有 `rejectsDimensionMismatches` 同批删除，合计 −2） | Cut 5 已完成 | CL-06 |
| D11 | `Protocol/*ContractTests.swift`（17 文件） | 160 | 「Codable key == TS 字段名」：TS 源 `packages/shared/src/protocol/*.ts` **已不存在**（仓库无 `packages/`），JSON envelope 同时删除 → 契约前提消失。保留约 30 条 enum rawValue（持久化契约）合并成 1 张表 | Cut 1（需先确认 DTO 是否保留 Codable） | 【已确认】`ls packages` 无输出；【疑似】保留面 |
| D12 | `.../Protocol/ErrorCodeContractTests.swift:11-73` | 1 | 删「177 冻结清单」这条；保留 `case 名 == rawValue` 与无重复断言 | Cut 1 | §1 备注 |
| D13 ✅ | ~~`.../Services/IndexerChecksumParityTests.swift:6-…`~~ | 1 | 2026-10-24 合并进 `FileHasherTests`：用注入 `chunkSize` 的小载荷覆盖跨块，一次 4MB+1 覆盖生产分块；重复文件删除 | 已完成 | §4 分层优化 |
| D14 | `core/Services/ReviewAcceptanceTests.swift:22-55`、`DeepReviewAcceptanceTests.swift:57-160` | 8 | 12 条「审查员探针」中 8 条只是同一行为的重复表述/诊断输出；保留 4 条行为断言（见 R9） | Cut 1 当轮 | CL-19 |

小计：**core 236 + app 11**（D2 是 helper，不计条数；D12 含在 Protocol 161 内单独列示）。备注：D2 的 18 个构造点分布在 `ReviewFixTests:136,316,341,349,364,544,564`、`FaceKeywordingViewModelTests:13,171,187,198,329,345`、`LayoutBudgetTests:50,81,131,177,196,278`、`SettingsSaveSemanticsTests:17`、`NativeCommandClientTests:12`、`IndexHeaderCopyTests:50`、`InboxItemsTests:46`、`FaceReclusterConfirmTests:31`、`CullingSyncFlowTests:105`、`WorkspaceStageMarksTests:20`；这些用例本身保留，只换注入（router → typed API fake）。

### 3.2 合并（M）

| ID | 位置 | 现状→目标 | 理由 |
| --- | --- | --- | --- |
| M1 | `app/IndexHeaderCopyTests.swift:9-133` 与 `:136-245` | 13 → 6 | 两套同矩阵（空态/排队/百分比/失败/计数），仅消费方不同（`SessionControlView.indexHeaderCopy` vs `GalleryViewModel.indexHeaderCopy`）；参数化后可共用一张表 |
| M2 | `core/Services/CullingServiceTests.swift:323-1883`（10 suites） | 67 → 45 | `decide`(325,345) 与 `batchDecide/batchUpdate`(511,625,638,649) 同一判定；`history`(670-913) 与 `HistoryStackRule`(1782-1862) 重叠；`summary/reset`(930-1068) 可表格化 |
| M3 | `.../Services/FaceKeywordingServiceTests.swift:217-1454`（12 suites） | 48 → 36 | 参数校验/簇形状/命令分支是同一输入矩阵的 4 份拷贝（217/663/710/983） |
| M4 | `.../Services/WorkspaceStatusServiceTests.swift:138-561` | 30 → 24 | 12 条单状态用例（created/imported/indexed/analyzing/failed）属同一状态机投影，参数化后仍逐格断言 |
| M5 | `MetadataSyncCoordinatorTests.swift:224`、`MetadataWritebackStateMachineTests.swift`、`MetadataOutboxRepoTests.swift:272` | 三处 → 1 | 同一状态机在协调器/内核/仓储三处重复断言；合并进 `DeliveryStateMachineTests` |
| M6 | `app/GlobalInfraTests.swift:19-115` + `ErrorLocalizationCoverageTests.swift:15-27` + `NativeCommandClientTests.swift:48-89` | 3 处 → 1 张表 | 都是 `errorText(code)` 漏斗矩阵；合并为 `ErrorMappingTests` |
| M7 | `SessionServiceTests.swift:309-320` + `IndexerServiceTests.swift:911-955` + `PhotoAssetResolverTests` | 3 处 → `PathPolicyTests` | home/root/祖先目录守卫写了三遍 |
| M8 | `app/LayoutBudgetTests.swift:59,72,274,290` | 8 → 6 | 4 条「空页/页签不超预算」同规则同阈值 |
| M9 | `core/Database/Repositories/*`（11 文件，扣掉 D5/D6 后 137） | 137 → 115 | 字段往返矩阵逐 Repo 复制；抽 `RepoTestSupport` 公用断言 |
| M10 | `app/CullingSyncFlowTests.swift:49,95` | 5 → 4 | `deriveControls` 与 `syncFlowState` 输入域相同 |
| M11 | `app/ReviewFixTests.swift:194-301,433-470,595-700` | 44 → 36 | F05 裁切 4 条、F13 样本计数 2 条、B1 返回 5 条各自只差输入 |
| M12 | core Services 杂项（Indexer 35→30、Filter 21→18、Similarity 30→26、Duplicate 27→24、Quality 16→14、Job 32→30、Metadata 13→10、Session 16→13、Navigation 10→8、Export 16→14、PhotoAssetResolver 8→7） | -27 | 同「单点行为 + 校验矩阵」拆分过细，参数化合并 |
| M13 | core 其余（Face 聚类 97→87、Concurrent 9→7、Incremental 10→9） | -13 | 同上 |

小计：**core -102**（M2 22 + M3 12 + M4 6 + M9 22 + M12 27 + M13 13）、**app -54**。

app 合并明细（合计 -54）：C1Preflight 5→4、CullingSyncFlow 5→4、Dashboard 22→19、ErrorLocalization 4→3、FaceKeywordingVM 22→19、Gallery 27→23、GatherAppDelegate 4→3、GlobalInfra 15→10、InboxItems 9→7、IndexHeaderCopy 13→6、JustifiedLayout 11→9、LayoutBudget 8→6、Library 21→18、Persons 6→5、ReviewAcceptance 6→5、ReviewFix 44→36、RootView 10→8、SettingsSaveSemantics 12→10、SidecarXMP 10→9、SimilarityVM 24→20。

### 3.3 改写（R，条数基本不变）

| ID | 位置 | 改法 | 理由 |
| --- | --- | --- | --- |
| R1 | `core/Database/DatabasePragmaTests.swift:17-182`（8） | 改为新 `Database` 的 1W+NR、readonly/query_only、busy_timeout、interrupt、close 语义 | §4.4 |
| R2 | `core/Protocol/` 保留面（≈30） | 只留 enum rawValue ↔ DB/UI 字符串（pickState/status/module），删 key 顺序断言 | §4.2 |
| R3 | `app/SimilarityViewModelTests.swift:518,815-825`；`SettingsSaveSemanticsTests.swift:31,49,76,94,158` | `errorMessage: String?` → `ViewState<…>.failed(GatherError)`；文案断言改码断言 | CL-08/§5.2 |
| R4 | `FaceKeywordingViewModelTests.swift:340,360`；`FaceReclusterConfirmTests.swift:61-68` | `notice: String?` → `ViewState.notice(L10n key)` | CL-08 |
| R5 | `app/Support/AppLanguageLock.swift:13-33`（16 文件 / 32 用例 / 41 调用点） | 删锁，改 `Environment(\.l10n)` 注入；断言用 fake L10n | §5.3、进程级全局 |
| R6 | `app/ReviewAcceptanceTests.swift:22-40,59-65`；`DeepModelAcceptanceTests.swift:23` | 外部 `/usr/bin/zip`、`/bin/sh`、`/usr/bin/awk` → 预置 zip 夹具 + 注入 runner；否则标 manual | §8.3-5 |
| R7 | `core/Face/FaceEmbeddingFingerprintTests.swift:194-205` | 写 `NSHomeDirectory()` → 注入 home 或临时目录 | 沙箱下**已知失败**（台账 1 失败即此条） |
| R8 | `app/SettingsSaveSemanticsTests.swift:164-174` | 读 home 计算期望值 → 纯字符串/注入路径 | 同上 |
| R9 | `core/Services/ReviewAcceptanceTests.swift:22-55`、`DeepReviewAcceptanceTests.swift:57-160`（12 → 4） | 8 条按 D14 删除；余 4 条去 `print` 证据行与「探针」命名，按行为重命名，断言不动 | CL-19 |
| R10 | `app/RootViewTests.swift`、`ReviewFixTests.swift:595-700` 导航断言 | `RootNavigation` → `SessionStore` 语义（activate/back/workspace） | §5.2 |
| R11 | `core/Reconciliation/*`（24） | golden 保留；注释中「由 scripts/reconciliation/*.mjs 生成」已失效（目录不存在）→ 改为「静态 golden，变更需人工签核」 | **已修（2026-10-24 复审）**：4 处注释改为冻结 golden 口径 |

### 3.4 保留（K，不动或只改注释）

| ID | 位置 | 条数 | 理由 |
| --- | --- | --- | --- |
| K1 | `core/Services/ExportServiceTests.swift` | 16 | §7.2 明确保留 ExportContractTests；fingerprint/续跑是交付核心 |
| K2 | `core/Reconciliation/`（无 HNSW 段；实际 22） | 23 | 算法 golden（dHash/聚类/matcher/维度/LSH） |
| K3 | `core/Image/RAWDecoderTests.swift` | 13 | 运行时生成图片，无二进制夹具 |
| K4 | `core/IPC/HelperProtocolTests.swift` + `HelperMessageTests.swift` | 23 | helper 进程保留则保留【疑似】helper 是否随新架构保留 |
| K5 | `core/Services/JobServiceTests.swift`、`DuplicateServiceTests.swift`、`QualityServiceTests.swift`、`FilterEngineTests.swift` | 96 | 纯行为 + 边界 |
| K6 | `app/SidecarXMPProviderTests.swift` | 10 | 真实文件 + 临时目录（hermetic）；XMP 语义不可替代 |
| K7 | `app/JustifiedLayoutTests.swift` | 11 | 纯布局算法 |
| K8 | `app/SettingsCatalogTests.swift` | 3 | UI 键目录 ↔ 默认表 ↔ 可调参数 |
| K9 | `app/Gallery/Library/Dashboard/Persons/Similarity/FaceKeywording VM 测试` | 122 | 只把 router 注入换成 fake API（见 D2 备注），断言保留 |
| K10 | `core/Services/WorkspaceStatusServiceTests` 收敛后 24 条 | 24 | 工作区状态是 UI 唯一入口的投影 |
| K11 | `app/GatherAppDelegateTests.swift`、`WorkspaceStageMarksTests.swift`、`C1PreflightTests.swift` | 11 | 宿主启动/预检状态机 |
| K12 | `core/Face/FaceMarginDecisionTests.swift` | 1 | 2026-10-24 精简为 margin=0/0.01 的生产路径行为用例；7 轮 sweep 已迁 benchmark |

### 3.5 账目预算（与 §1.2/§1.3 对齐）

core（994 → **761**，-23%）：

| 区域 | 现状 | 删除 | 合并 | 新增 | 目标 |
| --- | --- | --- | --- | --- | --- |
| Database/Repositories | 166 | -29 | -22 | 0 | 115 |
| Database（迁移/PRAGMA） | 18 | -10 | 0 | +40 | 48 |
| Protocol | 191 | -161 | 0 | 0 | 30 |
| Services | 441 | -23 | -67 | +30 | 381 |
| Face | 97 | -12 | -10 | 0 | 75 |
| Reconciliation | 24 | -1 | 0 | 0 | 23 |
| Concurrent/IPC/Image/Similarity/Logger/Helper | 57 | 0 | -3 | +5 | 59 |
| 新 API/错误映射 | 0 | 0 | 0 | +30 | 30 |
| **合计** | **994** | **-236** | **-102** | **+105** | **761** |

app（298 → **253**）：删除 -11（D1/D3）、合并 -54（M1/M8/M10/M11 + VM 表收敛）、新增 +20（SessionStore 10 / L10nParity 8 / LayerBoundary 2）。

> 若要压到计划字面的 **~700**，需在 Cut 5/6 做第二遍合并：Services 381→330（-51）、Repositories 115→105（-10），合计 -61 → **700**。【疑似】需 Cut 2 落地后按真实覆盖再定；不建议在第一遍就砍到这个数（会丢掉错误码逐条断言）。

---

## 4. skip / withKnownIssue / 非 hermetic 统计

| 类别 | 数量 | 具体位置 |
| --- | --- | --- |
| `@Test(.disabled)` | **0** | — |
| `withKnownIssue` 实际使用 | **0** | `app/SimilarityViewModelTests.swift:804` 仅注释 |
| `.enabled(if:)` 条件 | **11 条**（2026-10-24：真实照片 3 + 模型集成 8；均已登记 owner/到期/原因，见 §4.1） | `FaceRealPhotoPipelineTests`（3，`GATHER_FACE_FIXTURE`）；`FaceIdentityArchitectureTests`（1）、`FaceEmbeddingModelTests`（3）、`FaceInferenceTests`（4），`GATHER_MODEL_TESTS=1` |
| `.serialized` | 20 处 / 14 文件 | 7 个 Repo 套件、`MigrationTests:64`、`LoggerTests:10`、`FaceIdentityArchitectureTests:6`、`CommandSurfaceRuntimeTests:75`、`GlobalInfraTests:9,241` |
| 写真实 home | **1** | `FaceEmbeddingFingerprintTests.swift:194-205`（沙箱下已知失败，台账唯一红） |
| 读 home 作断言输入 | 3 文件 4 处 | `SettingsSaveSemanticsTests.swift:168`、`IndexerServiceTests.swift:916,931,949`、`SessionServiceTests.swift:309-311` |
| 启动外部进程 | 6 用例 | `app/ReviewAcceptanceTests.swift:22-40`（2）、`:59-65` 被 `:73,99,120` 复用（3）、`DeepModelAcceptanceTests.swift:23`（1）；依赖 `/usr/bin/zip`、`/bin/sh`、`/usr/bin/awk` |
| 进程级语言全局 + 互斥锁 | **32 用例 / 16 文件 / 41 调用点** | `Support/AppLanguageLock.swift:13-33`；使用方见 §3.3-R5；根因 `GatherLocalization.appLanguage` 是进程全局 |
| 依赖当前工作目录 | 1 | `SessionServiceTests.swift:316-320`（`TSPath.resolve` 用 `currentDirectoryPath`） |
| 依赖 OS 框架（Vision/CoreML/ImageIO） | 24 | `FaceEmbeddingModelTests`(3 gated)、`FaceInferenceTests`(4 gated)、`FaceIdentityArchitectureTests`(1 gated)、`RAWDecoderTests`(13, ImageIO)、`FaceRealPhotoPipelineTests`(3 gated)、`ExportServiceTests`（ImageIO 条件编译） |
| 依赖时序/RunLoop/超时 | 9 | `LayoutBudgetTests`(8, `NSHostingView.fittingSize` + `RunLoop.run`)、`CommandSurfaceRuntimeTests.swift:277-282`（5s 超时） |
| 依赖仓库内 fixture 路径（`#filePath`） | 26 | `Reconciliation/Harness.swift:12-17`、`ErrorLocalizationCoverageTests.swift:40-46`、`MigrationTests.swift:17-33`（D4 删除） |
| 网络 | **0** | `SidecarXMPProviderTests.swift:56-80` 的 `http://` 是 RDF 命名空间，非网络【已确认】 |

结论：Cut 0 快照中真正「无法判定成败」的条件跳过 + 1 条 home 写失败；语言全局是最广的隐性耦合（32 条），Cut 4 必须与 `AppLanguageLock` 一起删。2026-10-24 当前 skip 为 11 条（真实照片 3 + 模型集成 8），门禁口径见 §4.1。

### 4.1 skip 门禁与“有效执行”口径（2026-10-22）

- **识别范围**：`@Test(... .enabled(if:) / .disabled(...))`、`@Suite(.disabled(...))`、
  行首续行 `.disabled(...)` / `.enabled(if:...)`、`withKnownIssue(...)`；同一 `file:line` 去重。
- **元数据**：skip 站点上方连续注释块必须同时出现 `skip-owner`（或 `owner:`）、到期
  （或 `skip-until`/`deadline`）、原因（或 `reason`）。缺任一项 `--strict` 打印
  `file:line` 并 exit 1；warning 模式只打印不阻断。
- **手动条件**：无法默认执行的 fixture 在同一注释块写清 `手动 CI 条件`（例：
  `GATHER_FACE_FIXTURE=... swift test --filter FaceRealPhotoPipelineTests`）。到期后必须删除
  gate、受控 fixture 化或移入 `scripts/manual`，不能只续期。
- **有效执行口径**：`swift test` 汇总行的 `N tests passed` **包含**被 skip 的用例；
  文档/台账写“通过”时应写“声明 N / skip S / 有效执行 N−S”，不能把 skip 计入通过。
  `@Suite(.disabled)` 的 skip 数需按套件内 `@Test` 展开，脚本只报站点、不展开。
- **负例自测**：`./scripts/check-test-catalog.sh --self-test` 在临时目录构造缺元数据的
  `@Test(.enabled(if:))`、`@Test(.disabled)`、`@Suite(.disabled)`，期望 exit 1；补齐后 exit 0。
- **本轮实测（2026-10-22，core 全量）**：汇总行 `1124 tests in 158 suites passed`，其中 3 条
  `.enabled(if:)` skip；有效执行 **1121**。app 全量未跑（本轮验收只要求 core）。
- **CI**：`.github/workflows/ci.yml` 的 Test catalog step 已使用 `--strict`。

---

## 5. 新测试策略落地表

| 套件（新） | 归属 target | 覆盖什么 | 关键断言 | 目标条数 | 落点 |
| --- | --- | --- | --- | --- | --- |
| `SchemaV1Tests` | GatherPersistence | 44 表存在与列/类型/NOT NULL/默认值；CHECK 集合 == Swift `allCases`（sessions/photos/jobs/deliveries/items/groups/clusters）；FK `ON DELETE CASCADE`；唯一约束 `person_photos`/`delivery_items`；索引；`user_version=1`；旧库被改名为 `.incompatible-<ts>` 后重建 | 表参数化后逐表断言；「enum.allCases == CHECK」一条一域 | **40** | `gather-core/Tests/GatherPersistenceTests/Schema/` |
| `APIEnvironmentTests` | GatherDomain（+ app 组合根） | 15 个域协议 × 最小 happy path + 一个错误路径；参数校验/路径授权/确认门禁下沉到输入类型；`Confirmed<T>` 不可裸构造；`GatherError.code/params/retryable` 映射；`JobAPI` AsyncStream 事件序 | 每协议 `happy`/`error` 两条参数化（按方法传入输入矩阵） | **25** | `gather-core/Tests/GatherDomainTests/API/` |
| `DeliveryStateMachineTests` | GatherDomain | 合法/非法转移矩阵；confirm 单事务（deliveries + items + sessions.writeback 一次提交）；cleanup intent `prepared→fileDone→applied` 回放；`revision`/base_fingerprint；lease/heartbeat 到期恢复 | 非法转移逐条 `#expect(throws:)`；崩溃点注入后只补 DB 段 | **30** | `gather-core/Tests/GatherDomainTests/Delivery/` |
| `SessionStoreTests` | GatherUI | activate/deactivate；每会话独立 workspace；LRU/上限；`isVisible` 启停轮询；`WorkspaceIntent` take-and-clear（含 faceKwInitialRole 语义）；切语言保留页面状态 | 意图取两次第二次为空；不可见时零请求 | **10** | `gather-app/Tests/GatherUITests/Shell/` |
| `L10nParityTests` | GatherUI | en 表逐键覆盖 zh 源键；占位符序列一致；无孤儿键；`GatherLocalization.l(` 归零（菜单除外）；错误码文案覆盖 | 表驱动，失败打印前 10 个 key | **8** | `gather-app/Tests/GatherUITests/Localization/` |
| `LayerBoundaryTests` | 脚本为主 | `-explicit-target-dependency-import-check error`；UI 不 import Persistence/Domain；无 umbrella；Services 0 处 `prepare(`；旧模块名 0 引用 | `check-layering.sh`/`check-db-boundary.sh`/一条 import 快照测试 | **2** | `scripts/` + `gather-app/Tests/GatherUITests/Boundary/` |
| 其余新增 | core | `PathPolicyTests`（M7 归并）、`ErrorMappingTests`（M6 归并） | 守卫矩阵 / 码→文案→retryable | **10** | 随归属 target |

合计新增 **125**（core 105 / app 20），与 §3.5 预算一致。

---

## 6. 删除顺序与风险

### 6.1 顺序（先有替代、再删旧）

| 阶段 | 动作 | 依赖 |
| --- | --- | --- |
| **Cut 0（现在）** | ① D9（`FaceRealPhotoPipelineTests` 移 manual/加到期条件）；② CL-12 helper 去重：`LockedBox` 三份（`SimilarityViewModelTests:55`/`LibraryViewModelTests:20`/`GalleryViewModelTests:22`）收进 `Tests/Support`；③ 记录 baseline 计数（本文） | 无代码依赖，**可立即** |
| **Cut 1** | API 测试先落地 → 删 D1/D2/D3/D11/D12/D14；同时改 18 个 Stub 构造点 + 27 个 `router:` 传入点 | Router/WebResponse/NativeCommandClient 删除 |
| **Cut 2** | `SchemaV1Tests`/`DeliveryStateMachineTests` 先绿 → 删 D4/D5/D6/D7；改 R1；改 `RepoTestSupport.swift:8` `makeMigratedDB()`（**57 个用例、17 文件共用此入口**，一处切换） | MigrationRunner/outbox/writeback 删除 |
| **Cut 4** | `SessionStoreTests`/`L10nParityTests` 先绿 → 删 `AppLanguageLock`、改 R3/R4/R10、改 M1 | Environment L10n + SessionStore |
| **Cut 5（已完成）** | 删 D8（−9，随 ClusteringImpact）、D10（−2，随 HNSW）；D13 **未删**（checksum 流式/一次性双实现仍在，1 例绿）；改 R11 注释；新增 ClusterGraphTests 12 / 版本·签名 13 / 批量 match 12 / 短事务 7 | ClusteringImpact/HNSW 删除 ✅ |
| **Cut 6** | 二轮合并（Services 大套件）、清理 §3.2 剩余项 | 前三阶段稳定 |

**必须等代码删后才能删**：D1–D7、D11、D12（对象仍在）；**可立即**：D9、helper 去重、baseline 固化；**不可提前**：R5（提前删锁 = 32 条并发 flake）、D4（提前删 = 失去唯一迁移覆盖）。

### 6.2 风险

| 风险 | 触发点 | 影响 | 对策 |
| --- | --- | --- | --- |
| 契约测试先删、API 测试未绿 | Cut 1 | 118 条命令行为出现覆盖真空 | **同一 PR**：先加 API 测试再删 D11/D1；PR 模板要求「删除前测试已绿」 |
| 146 个用例含内联 SQL（`db.prepare`），绑定旧列集 | Cut 2 | SchemaV1 改列后测试静默失真（列名写错会报错，但语义断言可能空转） | `SchemaV1Tests` 做列级对账；Repo 测试改走 Repository API，不再内联 SQL |
| 语言锁提前移除 | Cut 4 之前 | 16 文件/32 条并行 flake | 锁与 `LanguageStore` 同 PR 删除，期间保留 |
| 合并过度丢边界 | Cut 6 | 参数化只保留 happy 输入、丢错误码逐字断言 | 每张参数表必须含 ≥1 非法输入行；A/B 变异抽查（删守卫应变红） |
| 默认跳过伪装绿灯 | 现状/持续 | skip 被计入 “passed”，有效覆盖虚高 | `check-test-catalog.sh --strict` 识别 `.enabled`/`.disabled`/`@Suite` skip/`withKnownIssue`，强制 owner/到期/原因；CI 同口径；有效执行按“声明−skip”记账；D9 的 3 条已登记但未关闭 |
| 统计口径漂移 | 每 Cut | 994/141 与 §8.7 指标对不上 | 附录 A 脚本进 CI，输出写入 cleanup-baseline.json |
| 性能型用例拖慢 | ~~`FaceMarginDecisionTests`、`FaceClusteringAccuracyTests`、`VectorIndex`~~ | 全量测试时长上升 | **已实施（2026-10-24）**：统计/性能类迁 `gather-core-benchmarks`（`--quality`/`--margin`/`--smoke`）+ 夜间 workflow；默认套件只留确定性行为用例 |

---

## 7. 滚动对账（Cut 5 / 6a 实测）

> 口径：`swift test` 的 "Test run with N tests in M suites"（core）与 `@Test` 机械计数同值；
> app 未随 5b/5c 改动（Cut 4 收口 580/66），6a-1 新增 1 条孤儿断言后为 **581/66**。
> 行号会漂，引用前重 grep。

| 阶段 | 前 → 后（core） | Δ例 | Δ套件 | 删除 / 新增明细 |
| --- | --- | --- | --- | --- |
| 5b-1 | → 1071/153 | +5 | — | 单趟 result+state 不变量、多档并集 |
| 5b-2a | 1071/153 → 1060/152 | **−11** | −1 | 删 **−23**（ClusteringImpact 9、ClusterGraphParity 12、HNSW 2）；增 **+12**（ClusterGraphTests） |
| 5b-2b | 1060/152 → 1073/153 | +13 | +1 | 版本/签名/digest、diff/apply 行级 upsert |
| 5c-1 | 1073/153 → 1085/155 | +12 | +2 | 批量 match 逐位一致、去 N+1 的 SELECT 计数 |
| 5c-2 | 1085/155 → 1092/157 | +7 | +2 | 短事务/取消/index_seq/并发读、签名清理 |
| 5d-1 | 1092/157 → 1092/157 | 0 | 0 | 只删 fixture/生成器（无测试对象变化）；`VectorIndexReconciliationTests` 3 例仍绿 |
| 5d-2 | 1092/157 → 1092/157 | 0 | 0 | 只改既有 `FaceMatcherBatchTests` 用例（批量 LSH skip 断言不增 @Test）+ 新增 bench `--face-10k`（非测试） |
| 6a-1 | 1092/157 → 1092/157（app 580→581/66） | 0 | 0 | 删 63 en + 1 zh key（en 1,407→1,344、zh 10→9）；存量孤儿 32（审计 1 是整键子串误判），31 登记 `legacyUnusedOrphans`；app +1 孤儿 parity 断言 |
| 6a-2 | 1092/157 → 1092/157（app 581/66） | 0 | 0 | 删 12 死符号（净 -63 行）、31 孤儿 key（en 1,344→**1,313**）、14 处旧 section 注释；parity allowlist 32→1；public 4,296→4,284；find-unused 12→2（AppKit delegate） |

- **5b/5c 合计**：删 **23 例**、增 **44 例**，净 **+21 例 / +4 套件**（1071/153 → 1092/157）；其中 5c 两段合计 **+19 例**。
- **skip 口径**：`.enabled(if:)` **4 处 / 8 条 → 3 处 / 3 条**（HNSW suite gate 随 5b-2a 删除）；`.disabled` **0**、`withKnownIssue` **0** 不变。
- **Reconciliation**：**24 → 22 例**（Cluster 3 / Clusterer 4 / DHash 1 / Dimensions 1 / Matcher 10 / Vector 3）；fixture `vector-fixtures.json` 143,273 → 140,855 行（−2,418）。**2026-10-24：该 fixture、生成器与 Vector 召回门已删除；Matcher 现 9 例。**
- **口径偏差**：Cut 0 预算 core 761 / app 253 未按原样执行——各 Cut 按"删除对象 + 替代断言同 PR"落地，net 落到 **1,092 / 581**；app 高于预算是 Cut 4 新增的状态层/本地化/边界测试所致，不是新增冗余。
- **6a 资源口径**：en 1,494 / zh 9；孤儿 key allowlist 1（`检测模型路径` 由测试构造）；`#Preview` 18 块 / 13 文件、`#if DEBUG` 16 行有效（全部 Preview 守卫）；`.disabled`/`withKnownIssue` 仍 0。

## 附录 A：复算命令（只读）

```bash
cd desktop/native
# core / app 的 @Test 与 @Suite 计数
grep -rc '^[[:space:]]*@Test' --include='*.swift' gather-core/Tests | awk -F: '{s+=$2} END{print "core",s}'
grep -rc '^[[:space:]]*@Test' --include='*.swift' gather-app/Tests | awk -F: '{s+=$2} END{print "app",s}'
grep -rho '@Suite' --include='*.swift' gather-core/Tests | wc -l
# skip / 全局状态 / 外部进程
grep -rn '\.disabled\|withKnownIssue\|enabled(if:' --include='*.swift' gather-*/Tests
grep -rn 'NSHomeDirectory\|homeDirectoryForCurrentUser' --include='*.swift' gather-*/Tests
grep -rn 'AppLanguageLock' --include='*.swift' gather-app/Tests | wc -l
# 依赖删除对象的用量
grep -rn 'MigrationRunner\|makeTestDB' --include='*.swift' gather-core/Tests | wc -l      # 40 文件 / 80 处（1 定义 + 79 调用）
grep -rn 'StubCommandRouter' --include='*.swift' gather-app/Tests | wc -l                  # 18 用例
grep -rn 'ClusteringImpact' --include='*.swift' gather-core/Sources | wc -l                # 仅自身
```

## 附录 B：与台账/文档的差异

1. `docs/refactor-progress.md:6` 记「skip/withKnownIssue 计数 98」——本审计实测 `.disabled` 0、`withKnownIssue` 0、`enabled(if:)` 4 处（默认跳过 8 条）。差异疑似把 `.serialized`(20)、`#require`(183) 或注释里的「跳过」计入；**建议以本文口径替换 baseline**，否则 ratchet 门禁无法只降不升。
2. `docs/DEVELOPMENT.md:196`、`docs/ROADMAP.md:81` 的台账数字（951/134、795/112）已过期；当前口径为 **994/141、298/32**。
3. 计划 §8.7 写「core 994 → 约 700」；本文算得可达落点 **761**（≥700 达标），压到 ~700 需第二遍合并（§3.5 末）。
