# Gather 破坏性重构进度台账

- Goal：goal-67d7de39-6376-4560-81c5-666a13e63d86（active，最大 40 轮；关闭材料见
  [final-report.md](final-report.md) §8，待 owner 执行 complete）
- 权威计划：docs/reviews/refactor-design-breaking-2026-10-21.md
- 基线 HEAD：82603e0
- Cut 1 收口：2026-10-22（工作区未提交；按规则不做 git commit/checkout/restore）
- **Cut 6 收口：2026-10-22（6a-1 / 6a-2 / 6b / 6c；工作区未提交）**；最终报告
  [final-report.md](final-report.md)
- 基线指标（Cut 0）：257 个 Swift 文件；Services 128 处 prepare(；@unchecked Sendable
  ratchet 口径 40（grep 全量 52）；try? 348；测试基线 core 994 / app 298；.disabled 0、
  withKnownIssue 0、.enabled(if:) 4 处（默认跳过 8 条）；错误码 179（D-010）。
- **最终指标（评审修复后，2026-10-22）**：**535** 个 Swift 文件 / **133,740** 行（364 / 122,692
  → +171 文件 / +11,048 行，文件增加主要来自拆分）；7 target；SchemaV1 **43 表/373 列/
  69 索引/62 FK**、user_version=1；16 协议/110 方法；**0 字符串命令**；179 错误码；
  en **1,322** / zh **9**、页面/VM `l()`=0、孤儿 key allowlist 1（`检测模型路径`）；
  #Preview **14**（5 文件/2,045 行）；core **1,128/159**、app **616/68**；ratchet
  **53/240/127/0/0**；`.enabled(if:)` 3 处/3 条（有效执行 1,125）。Cut 6c 时点为 core 1,092/157、app 581/66、en 1,313、ratchet 53/236/126。
- 本机限制：`build.sh` 被 DSH 沙箱拒绝（`sandbox_apply: Operation not permitted`，
  exit 1），bundle 交 CI；人工 GUI smoke 未做，均不写成通过。
- 决策记录：docs/refactor-decisions.md（D-036..D-164，D-163 最终关闭、D-164 CL-04 deferred）
- **r8 P1-3 清理（2026-10-22）**：删除 RequestGate/ViewState（4 文件/239 行/12 例），CL-04 → deferred；app 606/67 → 删除后 **594/65**（当前树 599/66，含并行工作区 +5 例）。详见文末“评审修复轮（post-refactor r8 P1-3）”。

## Cut 状态

| Cut | 状态 | 产出 | 验收 |
| --- | --- | --- | --- |
| 0 盘点/映射/审计/门禁 | 完成 | docs/test-audit.md；docs/cleanup-backlog.md；docs/archive/cuts/api-migration-map.md（118→16 协议/110 方法、113 处 UI、31 仅测试引用、4 删除/4 合并）；scripts/check-*.sh + cleanup-baseline.json；安全清理（LockedBox×3/AsyncGate×3/home 夹具/skip 到期）；app 298 tests 绿、core 受影响 121 tests 绿 | 四份文档 + 脚本可运行 + 清理测试绿 |
| 1 核心 API，删除 Router | **完成（2026-10-22，B8.4/B8.5）** | **0 字符串命令；16 协议/110 方法全部落地**；Router/CommandRouter/NativeCommandClient 删除（**7 文件**；生产+脚本 3,495 行，加 3 个测试文件共 4,052 行；D-080 早期口径 3,568 行）；app 455/55、core 1080/149 绿；D-036..081 | 0 字符串命令、110 行为覆盖、enforced 0 |
| 2 SchemaV1 + Database + Delivery | **完成（2026-10-22，S5c-2b-3b-2b-3）** | 生产 Database.open→SchemaV1（不兼容库重置含 -wal/-shm）+ 启动 replay；删旧同步栈 5 文件 4,081 行/4 测试 1,983 行；MetadataSyncError→DeliveryError；纯 V1 夹具；D-054..093 | 10 条 P0 门禁 + fresh DB 全功能 |
| 3 模块拆分 | **完成（2026-10-22，D-105）** | 7 target：Protocol/Persistence/Analysis/Domain/UI/Host/App；删伞 GatherCore；UI 只 import Protocol；Host 聚合；3b-4/5 端口/RAWDecoder/select-star 收口；D-103..105 | UI 不能 import Persistence；core 1057/149、app 461/55 |
| 4 UI + 本地化 | **完成（2026-10-22，4a-1..4c-2k + 4c-3）** | 状态层（SessionStore/Workspace/ViewState（2026-10-22 删除）/CommandError/LanguageStore）+ l10n codemod（1,481→0）+ 11 个巨型 View 拆分 + 14 个 #Preview；D-106..144 | RootView 壳 148（≤300）、#Preview 14（≥12）、l()=0、app 580/66、core 1057/149 绿 |
| 5 算法单趟化 | **完成（2026-10-22，5a / 5b-1 / 5b-2a / 5b-2b / 5c-1 / 5c-2 / 5d-1 / 5d-2）** | 5a ClusterGraph+Pipeline；5b-1 单趟 result+state + 多档并集；5b-2a 唯一实现切换（删 ClusterEngine 753 / ClusteringImpact 442+672 / HNSW 471+36 / 旧增量图 400+ / 6 份 BFS）；5b-2b 版本·签名·digest + diff/apply；5c-1 批量 match；5c-2 短事务三段（锁外聚类）；5d-1 fixture/生成器去 HNSW + ADR-011 superseded + backlog/test-audit/schema 注记；5d-2 批量 match 跳过 LSH + 10k 合成人脸 bench + Reconciliation README/ROADMAP HNSW 历史化 + ImageCache→SHA256，D-146..157 | core **1092/157** 绿；6 BFS→2；HNSW 代码引用 0（仅"已删除"注释）；10k face bench：release 精确 19.25s / 批量匹配 152.8ms（**§6.3 ≤5s 未达**），debug LSH 28.9s |
| 6 清扫与防腐 | **完成（2026-10-22，6a-1/6a-2/6b/6c）** | 6a-1/6a-2：删 63 en +1 zh key、31 孤儿 key、12 死符号/净 -63 行，en 1407→1313、zh 10→9，parity allowlist 32→1；6b：18 篇 reviews + 10 篇 cuts 归档、archive 索引、md 链接 0 缺失、README/DEVELOPMENT/ROADMAP/ADR 当前口径、makeMigratedDB→makeTestDB（80 处）、171 文件头、ImageCache/Migrations 注释 4+4、schema snapshot v35 归档；6c：L10n 注释 177→179 / 1,407→1,313、最终验收、本报告；D-158..163 | 6a：core 1092/157 + app 581/66 绿；6b：check-docs --strict PASS、md 链接 0 缺失；6c：core 1092/157 + app 581/66、8 门禁全过（strict 可用者带 --strict）、schema verify、preview strict；build.sh 本机沙箱受限、GUI smoke 待人工 |

## Cut 1 完成证据（B8.5）

### 1. 命令面与 API

- 命令：118 条（82 sync + 36 async）→ **0**。
  `grep -rnE 'execute(Async)?\( *"|enqueue\( *"' gather-app --include='*.swift' | wc -l` = 0。
- 协议：**16 个 / 110 个方法**（Session、Culling、Export、Job、Duplicate、Face、
  Similarity、Photo、Album、Person、Metadata、Settings、Navigation、Asset、Quality、
  Template；Template 6 个条件方法保留）。证据：`grep -hE '^    (public )?func ' gather-core/Sources/GatherCore/API/*API.swift | wc -l` = 110。
- Router 引用：`SessionCommandRouter|CommandRouter|NativeCommandClient|WebResponse|
  StubCommandRouter` 在 Sources/Tests 中 = 0（`check-no-legacy.sh` R5 全部 enforced 0）。
- 组合根：`AppComposition.make(db:)` 构造唯一服务实例；`AppRuntime` 负责 executor
  注册/JobService 启停/优雅停机；UI 只经 `AppServices.live(composition:)` 取域协议。

### 2. 删除清单（7 文件）

| 文件 | 行数（HEAD） |
| --- | ---: |
| Sources/GatherApp/Host/SessionCommandRouter.swift | 3,258 |
| Sources/GatherApp/Host/CommandRouter.swift | 51 |
| Sources/GatherApp/Support/NativeCommandClient.swift | 77 |
| Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift | 296 |
| Tests/GatherAppTests/NativeCommandClientTests.swift | 223 |
| Tests/GatherAppTests/Support/StubCommandRouter.swift | 38 |
| scripts/check-command-surface.sh | 109 |
| **合计** | **4,052** |

> 口径说明：D-080 记录的 3,568 行 = 生产 3 文件 3,386 + 脚本 109 + 工作区测试支撑
> AppCompositionTestSupport 约 73 行（未进 HEAD），**未计**上述 3 个测试文件 557 行；
> 本表按 `git show HEAD:<path> | wc -l` 实测 4,052 行为准。另删除
> RouterCulling/RouterNavigation/RouterMetadata、RouterFace/RouterFaceJob/
> FaceLegacySyncLoading、LegacySimilarityAPIAdapter 等 legacy adapter 与 118 个命令符号。

### 3. 测试与门禁

- app：**455 tests / 55 suites** 绿（`swift test --no-parallel`）。
- core：**1080 tests / 149 suites** 绿（`swift test`）。
- `./scripts/check-cleanup-ratchet.sh`：OK；55 / 287 / 132 / 0 / 0，全部等于 baseline。
- `./scripts/check-docs.sh`：PASS；ADR 缺失路径 0、schema 口径为“当前 schema 35”。
- `./scripts/check-no-legacy.sh`：OK；7 条 enforced 全过，R5 四类 0 file。
- `./scripts/check-layering.sh`、`check-duplicate-symbols.sh` 见完成报告。

### 4. Ratchet 收口（保留项说明）

- `unchecked_sendable` 59 → **55**：新增 19 处中，4 个 Live API 门面
  （LiveJobAPI/LiveDuplicateAPI/LiveMetadataAPI/LiveQualityAPI）的依赖全部是
  Sendable，删除多余 `@unchecked`，改由协议继承 + final + 编译器检查。
  保留 15 处：12 个 Live API 门面（依赖 Repo/Service 仍非 Sendable）、
  LivePhotoPathPolicy、AppRuntime（锁保护的可变生命周期）、JobObserverBag（锁保护的
  token 集合）。逐项理由见 docs/archive/cuts/cut1-completion-report.md §4。
- `services_prepare` 128 → **132**：净增 4 = DeliveryCoordinator 新增 5 处
  （4 条 cleanup 事务 SQL + 1 个仓储方法名 `intentRepo.prepare(`）减去 FaceKwService
  删除的 `refreshClusterMemberCounts` 1 处。4 条 SQL 是 S5c-2a 的“确认未变 + 删
  delivery_items/sessions/deliveries”原子事务，必须保留；抽出 Repo 属于 Cut 2/3
  的 Repository 收口，不在 B8.5 改生产逻辑。
- `try_optional` 348 → **287**（收紧 baseline，不回升）。
- baseline 已由 `--write-baseline` 更新，generated_at 2026-10-21T19:01:01Z。

### 5. 文档

- 新增 [cut1-completion-report.md](archive/cuts/cut1-completion-report.md)（目标/结果/指标/证据/
  删除清单/测试数字/遗留风险/下一步）。
- [api-migration-map.md](archive/cuts/api-migration-map.md) 标“已全部落地”，B0–B8 完成；
  §2/§6 行号标为 Cut 0 历史快照。
- [cleanup-backlog.md](cleanup-backlog.md) CL-01 done、CL-02 更新为 1,797 行待删、
  CL-11 部分完成。
- [README.md](README.md)、[DEVELOPMENT.md](DEVELOPMENT.md)、[ROADMAP.md](ROADMAP.md)、
  [ADR.md](ADR.md) 的 Router/118 命令描述改为裁剪后的类型化 API；ADR-028 删除清单
  与已删脚本路径标注“已删除”，check-docs 不再误报。
- [b8-router-removal-map.md](archive/cuts/b8-router-removal-map.md)、[test-audit.md](test-audit.md)、
  [cut1-execution-brief.md](archive/cuts/cut1-execution-brief.md) 加“历史快照/已完成”横幅。

### 6. 遗留与下一步

- **未做人工 GUI smoke**：新建/导入/索引/挑片/人脸/相似度/导出未在无 GUI 自动化下
  声称验收，记为待人工。
- 15 处 `@unchecked Sendable` 依赖 Repo/Service 变为 Sendable 后才能继续降；
  132 处 Services 内联 `prepare(` 需 Repository 化（Cut 2/3）。
- 下一步：**Cut 2 S5c-2b** —— writeback 执行器/finalize/syncStatus/FaceKw/旧表；
  D-054/055/060/062；随后 Cut 3a/3b。

## Cut 2 完成证据（S5c-2b-3b-2b-3）

- 建库：GatherApp 唯一入口 `Database.open(at:)`（user_version=1）；组合根 `AppComposition.make(database:)` 经 `database.connection` 构造服务；生产 `DBConnection`+`MigrationRunner` 引用 0。
- 启动 replay：`AppRuntime.start` 在 `jobService.start()` 后调度 `DeliveryCoordinator.replayPendingDeliveries()`（后台 Task、不阻塞启动，失败写 `deliveryReplayFailure` + error 日志）；`shutdown` 先 await 回放再关库。
- 删除：生产 5 文件 / 4,081 行（MetadataSyncCoordinator、MetadataOutboxRepo、WritebackRepo、Migrations、SchemaV1Transition）；测试 4 文件 / 1,983 行；`Schema.swift` 649→19（2026-10-22 复核实测；旧记 14 为漂移）。
- V1 缺列收口（D-092）：SessionRepo 11 列按名解码 / 交付聚合派生；SessionService 删 writeback_items + 显式 role_bindings；AssetRepo.relink 只迁 deliveries。
- 夹具：`makeMigratedDB`/`makeGatherTestDB` 只 exec SchemaV1.sql；MigrationTests fresh only；legacy 表/列引用（Sources/Tests）= 0。
- 门禁：core 1080/151、app 461/55（--no-parallel）；ratchet 53/242/126/0/0（baseline 已收紧）；no-legacy/docs/test-catalog/select-star 全过。

## Cut 4 完成证据（4a / 4b / 4c）

| 阶段 | 指标（实测） |
| --- | --- |
| 4a 状态层 | 4a-1 新增 15 文件（10 状态层 + 5 测试/37 例）；4a-2/3 接 SessionWorkspace（capacity 6）/WorkspaceIntent、7 VM setVisible/shutdown、RootView 去 draftCache/单槽、LanguageStore；7 VM errorMessage→CommandError |
| 4b 本地化 | 页面/VM 的 `l()` 调用 0（等价口径 `GatherLocalization.l(` = 0；Support 内部实现仍用裸 `l()`）；en 1407 条；parity 在用 key 1265；无 `.id(languageVersion)` |
| 4c View/Preview | 11 个巨型 View 拆分，页面目录 141 个 Swift 文件（含 VM/子视图）；壳 128–432 行（RootView 7 文件/886 行、壳 148）；#Preview 14；`check-preview-surface.sh --strict` PASS |

- 4c-3 错误收敛：Similarity 页级错误唯一来源 `phase.error`；`errorMessage` 改为只读代理（`actionError` 只承载操作级错误），View 全页错误只读 phase，文案/码不变。
- 4c-3 注释：`CullingDisplayFormat.swift:23` 的 LibraryColorOption 路径改为 `Library/LibraryView+Filters.swift`。
- 测试：app **580/66**（exit 0）、core **1057/149**（exit 0）；`--filter Similarity` **48/6**（exit 0）；app/core `swift build` exit 0。
- 门禁：ratchet 53/233/126/0/0 OK；layering 17 条 OK；docs PASS；preview strict 14 PASS。
- 口径漂移：D-129 记 parity key 994（4b-2l 时点）；4b-3 Host/App + 4c-1 PreviewSupport 后实测 **1265**，测试仍绿。按实测记，不照抄 994。
- 未做人工 GUI 验收（Preview 渲染、页面交互未目视）；无 GUI 自动化，不声称视觉通过。

## Cut 5 完成证据（5a / 5b-1 / 5b-2a / 5b-2b / 5c-1 / 5c-2 / 5d-1 / 5d-2）

| 阶段 | 产出（实测） |
| --- | --- |
| 5a | ClusterGraph.swift（HashGraphTable / NeighborhoodGraph / Hash+Streaming 图 / DegreeGatedBFS / ClusterWorkspace）+ ClusterGraphParityTests；fixture 实际 17 例（15 global）逐组/逐序；6 份 BFS 划分/种子一致、组内序三类（wave/stack/canonical）。 |
| 5b-1 | ClusterGraphPipeline.run / runTiers 单趟产 result+state；decideCluster 删第二趟 buildState、analyze 3→2 趟；多档 4 位图→1 并集（32k 537MB→134MB）。 |
| 5b-2a | 唯一实现：删 ClusterEngine 753 行 / ClusteringImpact 442 + 测试 672（9 例）/ ClusterGraphParityTests 717（12 例）；旧增量图（ParsedHashes/ComponentGraph/groupComponent/Scanning/buildState）全删，IncrementalClusterer 748→340；HNSW 471 + FaceVector 删（VectorIndex 866→370）、benchHnsw 删（bench 333→281）、对账测试 5→3 例且默认运行；ClusterGraph 迁 DTO/ClusterGraphError/defaultMaxBitsetEntries/sequential/模式分发（784→943）。 |
| 5b-2b | SchemaV1 `similarity_cluster_meta` +3 列（43 表/**373 列**，D-152）；`ClusterStateVersioning`（v1 签名 + FNV-1a64 行序无关 digest）、`ClusterStateEntry/Diff`；`SimilarityClusterStateRepo` 六列比对 + 单行 upsert + 只删 removed（旧全表 DELETE/重插删除）；core 1060/152 → **1073/153**（+13）。 |
| 5c-1 | `FaceMatcher.match(clusters:)` 批量：库/范数一次、簇循环零 DB、累加序不变（`bestScoresPerPerson` 逐位一致）；FaceKwService 去 N+1（成员一次分块 IN、feedback 一次，SELECT 2C+5 → **7 恒定**）；core **1085/155**（+12）。 |
| 5c-2 | 三段式：A 逐照片短事务+checkpoint+取消；B 一次读快照、DBSCAN/增量**在锁外**、isCancelled、失败只清签名；C index_seq 复核 + 写簇/成员/签名 + C2 best-effort reconcile/match；`FaceRepo` 签名清理/匹配行/`modelSpace`；并发读 0.019ms（旧阻塞到聚类结束）；core **1092/157**（+7）。 |
| 5d-1 | vector fixture 删 `hnsw` 段 **2,418 行**（143,273 → 140,855 行；3.66 → 3.63 MB）；生成器重写为只产 LSH（**1,016 → 563 行，−453**）、`--check` 逐字节一致；ADR-011 标 superseded；cleanup-backlog CL-05/06/13 收口 + CL-20 复核（未标 done）；test-audit §7 滚动对账；schema 审计 370→373 注记；bench README 删 hnsw 行；门禁 docs/no-legacy/layering/dup 全绿。 |
| 5d-2 | `FaceMatcher` 拆分 `prepareLibraryRows`（行校验/平铺，不建 LSH）与 `loadLibrary`（唯一建 LSH 入口 = 实例 `matchAgainstLibrary`）；批量 `match(clusters:)` 不再建索引，`lshMinPoints` 保留；测试 `batchDoesNotBuildLshIndexAndStaysExact`（不增 @Test 数）守"批量 0 建索引 + 结果逐位不变"。bench 新增 `--face-10k`（50 身份×200 样本×512 维；聚类按构建选路径 + FaceMatcher 批量）：release 精确 **19.25s** / 匹配 **152.8ms**（3 跑中位，内存粗估 39.1/19.6MB），debug LSH 12.98s / 15.56s（58.8/19.6MB）；**§6.3 精确 ≤5s 未达标**（19.25s，~3.85×）。Reconciliation README + ROADMAP HNSW 全文历史化；`ImageCache.swift` → `SHA256.swift`（纯改名）。 |

- 注入点（同一实现）：DuplicateService 默认 clusterProvider、AppComposition、SimilarityService 的 clusterProvider/multiClusterProvider 全部 = ClusterGraphPipeline.run(mode:) / runTiers(mode:)。
- 测试（5b-2a）：core **1060/152**（exit 0）；对比 5b-1 后 1071/153 = **−11 例 / −1 套件**（−9 ClusteringImpact、−12 parity、+12 ClusterGraphTests、−2 HNSW 专属）；此后 5b-2b/5c-1/5c-2 陆续 +13/+12/+7 → **1092/157**；5d-2 只改既有批量用例、@Test 数不变，core 全量 **1092/157** exit 0（5d-2 专项 `--filter 'Matcher|FileHasher|ChecksumParity'` 32/5 绿）。
- 门禁：ratchet **53/236/126/0/0** OK；layering OK（17 条）；duplicate PASS；no-legacy OK（7 enforced / 6 tracked）；test-catalog PASS；docs --strict OK；select-star Sources 6 / Tests 1 OK。
- golden：cluster-fixtures.json 17 例锁 pipeline（global + sequential）；wave 序/规范序/度门控/长哈希/多档/模式分发/streaming 各一组用例；增量 200 次随机 x 3 参数与全量 state 逐位一致。
- 未做 / 残余：10k 人脸精确 DBSCAN 的 **§6.3 ≤5s 目标未达**——release 单进程实测 19.25s（~3.85×），按 drift 记录、不写成达标，是否继续优化由 owner 定；"锁内 0s"属服务层（5c-2 并发读 0.019ms），bench 不覆盖。`FileHasher.swift` 与 4 个 GatherDomain 注释仍写旧文件名 `ImageCache.swift`（不在 5d-2 可写范围）。Cut 6 承接 CL-12/16/18/19/20（CL-20 的 62 个未引用 key 未删）。

## Cut 6 完成证据（6a / 6b / 6c）

| 阶段 | 产出（实测） |
| --- | --- |
| 6a-1 | 删 **63 en + 1 zh** key（en 1,407→1,344、zh 10→9），保留 `检测模型路径`（测试钉英文值）；存量孤儿实测 32，登记 31 个待 6a-2；app **581/66**（+1 孤儿断言）、core **1,092/157**；parity allowlist = pinned(1)+legacy(31)。 |
| 6a-2 | 删 **31 个孤儿 en key**（en 1,344→1,313）+ **12 个零引用符号**（净 −63 行）+ 14 处旧 section 注释路径；parity allowlist **32→1**，删 `legacyUnusedOrphans`；`find-unused` 候选 12→2（仅 AppKit delegate）、public 4,296→4,284；core 1,092/157、app 581/66。 |
| 6b | 归档 **18 篇 reviews + 10 篇 cuts**（49 个 assets 随迁，`docs/archive/README.md` 建旧→新索引）；`makeMigratedDB`→`makeTestDB` **80 处/40 文件**；**171** 个文件头旧 target 路径回填；ImageCache/Migrations 注释 4+4；HNSW 句改为历史；`schema.snapshot.json`→`archive/schema.snapshot-v35.json`；check-docs --strict PASS、md 链接 133 条/图片 47 条 0 缺失。 |
| 6c | L10n.swift 两处注释改为 **179 码 / en 1,313**；core build+test（strict）**1,092/157**、app build+test（strict + `--no-parallel`）**581/66**；`gather-schema verify` 43/1/0 + SQLite 复核 43/373/69/62；8 门禁全过（ratchet **53/236/126/0/0**、preview **14**）；新增 [final-report.md](final-report.md)。 |

- 6c 未做：`build.sh` 本机在第一个 release `swift build` 的 manifest 阶段被沙箱拒绝（`sandbox_apply: Operation not permitted`，exit 1），未生成 bundle；交由 CI `gather-app tests + bundle`。人工 GUI smoke（启动/导入/挑片/相似度/人脸/导出/中英切换/优雅停机）未执行，不得写成通过。
- 指标冻结：535 文件 / 133,740 行；7 target；0 字符串命令；16 协议/110 方法；en 1,313 / zh 9；页面/VM `l()`=0；ratchet current 53/236/126/0/0（baseline try? 242）；10k release 精确 19.25s（≤5s 目标未达，D-158 接受 ≤20s 基线）。
- 残余：CL-18 pending（try? 236 / unchecked 53，未批量改语义）；CL-20 done 但仅静态键证据（无 GUI en A/B）；CL-19 保留 60 例、4 例外部队列非 hermetic；ratchet baseline 未收紧为 236。

## 评审修复轮（post-refactor r8 P1-3，2026-10-22）

- **结论**：CL-04 的“4 套 stale 守卫统一”从未发生；`RequestGate` 自 4a-0 起零生产调用点（仅 `RequestGateTests`），`ViewState` 同样零生产调用点（R4 P2-8）。决定不保留“以后可能用”的类型储备，整文件删除并对 CL-04 记 deferred（理由/解除条件见 cleanup-backlog）。
- **删除**：4 文件 / 239 行 / 12 例——`GatherUI/Support/RequestGate.swift` 34、`GatherUI/Support/ViewState.swift` 49、`Tests/GatherAppTests/RequestGateTests.swift` 58（4 例）、`Tests/GatherAppTests/ViewStateTests.swift` 98（8 例）。4 个 VM 的私有代次原样保留（实测 37 行：fetchGeneration 16 / latestRequestID 5 / tierRequestID 7 / pageVersion 11）。
- **app**：删前 **606/67** → 本刀删除 12 例后 **594/65**；串行 exit 0（16.792s），默认并行连跑 3 次均 exit 0（7.363s / 7.511s / 7.776s）。当前树因并行工作区新增 5 例/1 套件为 **599/66**，最终串行 exit 0（17.199s），默认并行再跑 3 次均 exit 0（7.646/7.680/7.670s）。
- **core**：本刀只删 GatherUI 文件，core 源/测试未改；实测 **1,124 tests / 158 suites passed**，exit 0（任务基线 1,120；+4 例来自并行的 WritebackService 改动，非本刀）。
- **门禁**：8 个全过——ratchet **53/240/126/0/0**（baseline try? 242，未升）、docs --strict、test-catalog --strict（164 文件）、no-legacy（7 enforced + 6 tracked）、layering（17 条）、dup --strict（RequestGate 0 份，exit 0）、select-star、preview --strict（14 块/5 文件/2,045 行）。
- **台账**：cleanup-backlog CL-04 → deferred（新增 `deferred` 状态定义）；final-report 撤销“RequestGate 1 份”门禁证据、§6 增第 9 条残余、§5.1 增删除后 app 行；决策 D-164。
- **残余**：`GatherUI/Support/LoadPhase.swift:9/18` 注释经 2026-10-22 16:48 复核已无 `ViewState` 引用（并行工作区已修）；`scripts/check-duplicate-symbols.sh` 的 RequestGate 规则与“Cut 4 落地”文案已于最终清理移除（见下节）。

## 本轮（Cut 0）subagent

- 396d6868-115d-4066-95f8-b4e6994ae322：清理盘点（docs/cleanup-backlog.md）
- 13d15e65-5468-4a75-af49-26aa3f8e5c2a：118 命令 → API 映射（docs/archive/cuts/api-migration-map.md）
- 2e0a0a8b-03df-44b1-ad17-384825534c4b：构建垃圾 + 门禁脚本（scripts/、.gitignore、cleanup-baseline.json）
- da035a67-8856-4623-bd10-858ca4b61776：测试审计（docs/test-audit.md）

## 关联产物

- docs/archive/cuts/cut1-execution-brief.md：Cut 1 的 5 个阶段、文件所有权、验收（历史计划）。
- docs/archive/cuts/cut1-completion-report.md：Cut 1 完成报告（本 Cut 唯一交付索引）。
- docs/cleanup-backlog.md：CL-01..CL-20 清理账；CL-01 已 done。
- docs/archive/cuts/api-migration-map.md：118→16/110 映射 + Cut 1 落地状态。
- docs/test-audit.md：Cut 0 测试审计（历史快照）。
- docs/final-report.md：Cut 6c 最终报告（指标、删除清单、验证证据、残余项）。
- docs/cut6-cleanup-audit.md：Cut 6 清扫审计与执行计划（6c 前）。
- docs/archive/cuts/b8-router-removal-map.md：B8 删除映射（历史执行记录）。
- scripts/check-cleanup-ratchet.sh + docs/cleanup-baseline.json：清理 ratchet。
- scripts/check-docs.sh：文档一致性门禁（已支持“已删除”历史行与“当前 schema”声明）。

## 评审修复轮（2026-10-22，8 路 review）

- P0-1：Delivery cleanup/replay/orphan restore 加 revision/status/base_fingerprint 守卫；XMPFileLock 串行 restore/remove/writeback；三入口并发回归。
- P0-2：CI/README/DEVELOPMENT 统一 app --no-parallel；AsyncWait ContinuousClock + 10s 可配；4+2 flake 隔离；app 串行 616/68、默认并行 5/5。
- 数据完整性：mergeInput 全会话确认重置、writing 租约 claim/TTL/归位、metadata enqueue 单事务、SchemaV1 shape 指纹重置、Indexer 先删 person_photos、cleanup 跨模块 gate。
- 功能：metadata executePending 接线、acceptExternalState 只到 written+清确认、session.create job+回滚、JobCreateParams.metadataScan 工厂、15 个 API Live 测试。
- UI：workspace 两级可见性、endSession 接线、Gallery 懒加载、RequestGate/ViewState 删除（CL-04 deferred）。
- 测试/打包/本地化：catalog 识别 enabled(if)/suite disabled + CI strict；entitlements/SFace/lproj 断言；L10n.plural 7 模板 + parity 扩 Notice/三元；剩余 76 模板列 CL。
- 清理：ratchet baseline 53/240/127；删除 Sources/.build 379MB；新增 docs/review-remediation-report.md。
- 残余：GUI smoke、build.sh 本机完整执行（CI）、10k 19.25s、76 复数模板、进程外写盘不互斥、markWritten 未校验 owner、git 未 commit/混合态、少量 P2/CL。

## 最终收尾：docs / scripts / 构建产物（2026-10-22）

- **脚本**：`check-duplicate-symbols.sh` 删除 RequestGate 规则与“Cut 4 落地”文案（D-164 已删该类型），`--strict` 仍 exit 0（batchAsync 1、Tests/Support 外 0、535 文件）。
- **文档 stale 符号**：`cut6-cleanup-audit` §1.2/§4.2 的“RequestGate 1 份”→0 份；CL-04 残余、final-report §6.9、review-remediation 死代码清单（移除 `JobScopeCheckpoint`）同步；dup 脚本规则不再是门禁证据。
- **死链**：非 archive 当前文档 **0 缺失**（`face-clustering-benchmark.md` 13 条旧 `GatherCore` 源码链接改到 `GatherAnalysis`/`GatherDomain`；已删的 `ClusteringImpact.swift` 改代码文本）；归档 33 条旧源码链接按快照保留并已在 archive 索引注明。`check-docs.sh` 新增当前文档 md 链接存在性检查。
- **指标**：en **1,322** / zh 9、测试文件 **166**、#Preview 14、ratchet **53/235/127/0/0**（baseline 240）、**535** Swift 文件 / **138,829** 行（17:00 采样，并行工作区仍在变；6c 时点 535 / 133,740）。
- **构建产物**：删除 `release/Gather.app`（22 MB，9-29 旧 bundle）与 4 个非活动 `.build` scratch（≈1.63 GB）；保留并行构建正在写入的 `.build/scratch`、`.build/shared-cache` 与两包 `.build` 增量缓存。
- **门禁**：docs --strict、test-catalog --strict、cleanup-ratchet 全 OK；**未跑全量测试**（无源码改动）。详见 [final-cleanup-docs.md](final-cleanup-docs.md)。

## WP7 测试/构建基础设施（2026-10-22）

- **共享夹具 product**：gather-core `Package.swift` 新增 `.library(name: "GatherTestSupport")`（target 仍在 `Tests/GatherTestSupport`）；gather-app 的 `GatherAppTests` 依赖该 product。core 侧新增 `Tests/GatherTestSupport/Support/LockedBox.swift`（34 行，public；放 Support/ 子目录以满足 `check-duplicate-symbols` 的路径约定）。
- **删除 app 重复夹具**：`Tests/GatherAppTests/Support/{AsyncGate,LockedBox,TestDatabase}.swift` = **89 行 / 3 文件**（39+31+19）；新增 `Support/TestSupportReexports.swift`（20 行）用 typealias + 转发保持调用点零改动。建库统一入口 `makeTestDB()`；`makeGatherTestDB` 是临时转发（22 处调用点，等并行 Shell 迁移收尾后改名为 `makeTestDB` 并删除）。
- **manifest 去外部进程**：`gather-app/Package.swift` 删除 `Process`/Pipe/xcrun 的 SDK 探测（净 -1 行，+19/-20）；固定默认 `defaultSDKVersion = "26.0"`（Liquid Glass 最低 SDK），`GATHER_SDK_VERSION` trim 后非空则覆盖。实测 `swift package dump-package`：unset/空白 → 26.0、`27.0` → 27.0、`" 15.2 "` → 15.2。
- **链接产物实测**：`xcrun vtool -show-build` 的 `LC_BUILD_VERSION` = minos 14.0、unset → sdk **26.0**；fresh scratch + `GATHER_SDK_VERSION=27.0` → sdk **27.0**。发现 SwiftPM manifest 缓存不把该环境变量计入 key（同 scratch 下 26.0→27.0 不重链）；build.sh 的 app 构建与 CI app 测试加 `--manifest-cache none` 后同 scratch 也正确重链为 27.0。
- **build.sh / CI**：build.sh 构建前探测 `xcrun --show-sdk-version` 并 export（显式 `GATHER_SDK_VERSION` 优先，探测失败告警回落 manifest 默认）。CI app job 新增 “Resolve SDK version”（写 `$GITHUB_ENV`）；app 测试保留 `--no-parallel`。CI gather-core job 新增 `swift run ... gather-schema verify`（本机 = `tables=43 user_version=1 foreign_key_violations=0`）。
- **验证**：core 本刀基线 **1128/159** exit 0（17:35，改动前）→ 并行 WP1 瘦身 Protocol 后 **1060/159** exit 0（-68 例来自并行工作区，套件数不变，非本刀）；app **616/68** 串行 exit 0（16.78s），默认并行 **3/3** exit 0（7.305 / 7.240 / 7.261s）。8 门禁全过：ratchet **53/233/127/0/0**、test-catalog 165 文件、duplicate 0 越界、docs 142 链接 0 缺失、select-star 6/1、preview **14**。
- **未做/限制**：`build.sh` 未完整执行（DSH 沙箱拒绝 SwiftPM 的 sandbox-exec；只做 `bash -n` + 探测块单测，bundle 交 CI）。`docs/DEVELOPMENT.md` 不在本刀白名单（其目录树把 GatherTestSupport 写成 `Sources/`，实际在 `Tests/`，且无 SDK/env 说明），未改。app 测试 target 未补 core 的 CLT-only `-F/-rpath` 探测（既有差异，未扩大）。人工 GUI 未执行。

## WP1 Protocol 瘦身（2026-10-22，HEAD 30f51f0；工作区未提交）

- **范围**：仅 `GatherProtocol/**`、`Tests/GatherCoreTests/Protocol/**`、新增 `scripts/check-protocol-surface.sh` + `docs/protocol-surface-baseline.json`、台账；未改 app 源码/Package/其他 target/其他 docs。
- **盘点**：[`docs/reviews/wp1-protocol-inventory.md`](reviews/wp1-protocol-inventory.md)（347 类型逐条 file:line/引用证据；89 零引用；6 信封；96 删除清单）。
- **删除**：96 个顶层 public 类型，Protocol `git diff --numstat` **+11 / −1,284（净 −1,273）**；其中类型块 1,184 行，其余为声明前注释/空行清理。构成：89 零引用（942 行，88 struct + 1 enum `Response`）+ 5 个其余 Router 信封 + 2 个二级死亡（`BindingData` / `MetadataMutationTarget`）。信封整体 158 行（Core.swift:158-315）。
- **指标**：类型 **347→251**（≤260）、public 声明 **1,752→1,320**、零引用 **89→0**、Router 信封 **6→0**；Protocol 行 7,598→6,325。
- **保留**：13 个旧 `*Params`（均被 API 签名直接引用）；`APIContractIndex.swift` 记录“新增输入只进 API/Inputs，不复活 *Params/Response*”。
- **契约测试**：17 文件；删 **68** 例（纯 DTO 构造/JSON 往返），改写 **3** 例（`CullingUpdatePatch` / `AlbumUpdateParams` / `AnalysisJobType` 保留断言）；core **1,128/159 → 1,060/159** exit 0；app **616/68** exit 0（未改）。
- **门禁**：新增 `check-protocol-surface.sh --strict`（251/1,320/0/0，exit 0）；既有 8 门禁 strict 全过——layering 17、ratchet 53/233/127/0/0、test-catalog 165 文件/3 skip、duplicate 535 文件、docs 20 路径/143 链接、no-legacy 7 enforced+6 tracked、select-star 6/1、preview 14 块/5 文件/2,031 行。
- **schema**：`swift run --package-path ... --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch gather-schema verify` = 43 表 / user_version 1 / FK 违规 0（bare 命令在 DSH manifest 阶段被 sandbox 拒绝，记录为环境限制）。
- **残余**：13 个旧 Params 是 D-007 的合法复用面；无 GUI 验收；不 commit；并行工作区的其他改动未纳入本刀。

## WP2a Delivery target 纯移动（2026-10-22，HEAD 9922762；工作区未提交）

- **范围**：新增 `GatherDelivery` target/product；`Sources/GatherDelivery/{DeliveryCoordinator,WritebackService,MetadataMutationService,XMPFileLock}.swift` **4 文件 / 3,630 行**原样移入（Coordinator 1,964 行仅 3 处访问级别 `internal→public`，供 Domain 读交付基线；WritebackService 删 1 个未用的 `import GatherAnalysis`）。
- **端口下移**：`XMPProvider` + `MetadataWriteAttributes` → `GatherProtocol/Protocol/XMPProvider.swift`（93 行）；`MetadataContract` → Protocol（96 行）；`MetadataFingerprint`（39 行）、`PhotoAssetResolver`（171 行）→ Persistence；`MetadataMutationPort` 随 `MetadataMutationService` 留在 Delivery。
- **依赖方向**：Delivery → Protocol + Persistence（实测 import：Foundation 4 / Persistence 4 / Protocol 3；Domain/Analysis/UI/Host = 0）。Domain → Delivery、Host → Delivery、core/app 测试 target → Delivery 均已接线。
- **必要偏离（记账）**：Swift import 文件级 → 4 个 Domain 服务、9 个 Host 文件、5 个 app 测试、9 个 core 测试各加 1 行 `import GatherDelivery`（core 测试用 `@testable`）；core/app 两个 Package 加依赖。为让 WritebackService 在 Delivery 编译，`batchAsync`/`BatchCursor`（139 行）从 Analysis 移到 Persistence/Support（Analysis 内零使用；不属端口/DTO，单列）。
- **测试**：core **1,060/159** exit 0；app 串行 **616/68** exit 0（16.658s）；app 并行 **3/3** 次 616/68 exit 0（6.482 / 7.088 / 7.011s）。测试数不变。
- **门禁**：原 8 门禁全绿——layering OK；ratchet **53/233/120/0/0**（services_prepare 127→120、try_optional 240→233，移出 Domain/Services 所致）；test-catalog 165 文件 / 3 skip；duplicate 536 文件 batchAsync 1；docs 20 路径 / 143 链接；no-legacy 7 enforced + 6 tracked；select-star 6/1；preview 14。
- **schema**：`swift run ... gather-schema verify` = 43 表 / user_version 1 / FK 违规 0。
- **残余**：`check-protocol-surface.sh --strict` 红——① 脚本 prod-files 未含 `GatherDelivery`，`MetadataMutationResult` 被误报零引用（1）；② 端口下移使 Protocol 类型 251→254、声明 1,320→1,338，需修脚本后 `--write-baseline`。二者均在本刀白名单外，未改。另：9 个移动文件头仍写旧路径（纯移动未改内容）；不 commit；无 GUI 验收。

## 规则

- 不做 git commit / checkout / restore；不删除未确认文件。
- 每个 Cut 必须交清理账（删除/新增行数、删除文件数、删除符号数）。
- 新旧实现不得跨 Cut 并存；替代实现与删除同 Cut。
- 构建/测试统一带 --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch。