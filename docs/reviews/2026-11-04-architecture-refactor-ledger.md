# 架构重构 Wave 1–3 台账（2026-11-04 起）

本文件记录本轮架构重构的**门禁基线变动**与理由（`scripts/check-*.sh` 要求的
「在 docs/reviews/ 台账记账」）。实现细节看提交信息，这里只记「为什么允许上涨」。

## #12 会话页生命周期表驱动（d586eb62）

- 无门禁基线变动：只新增 `SessionPageModel`（GatherUI 内部 target，不计入 Protocol 公开面）。
- 测试：app 879 → 880（+1「注册表覆盖全部页面」）。

## #9 设置端口地基（Step 0–1）

- `check-protocol-surface --strict`：`public_types` 408 → **411**、`public_declarations`
  2433 → **2441**。新增 3 个类型均在 GatherProtocol/Settings/：
  `SettingsKey`（68 个已注册键的枚举，rawValue 与库里字符串逐字一致）
  `SettingsReading`（读取端口，1 个原语 + 4 个类型化扩展）
  `ClosureSettingsReader`（测试/过渡期适配器）。
- 为什么必须上涨而不是压到现有类型里：设置键要被 GatherPersistence（DB 读 PRAGMA）、
  GatherApplication（服务读参数）、GatherUI（设置页）同时 import，唯一可放的位置是
  GatherProtocol 最底层；`check-layering.sh` 明令 UI 不得 import Persistence。
- `zero_reference_types` 保持 0：三个新类型都有生产引用（`SettingsService`/`DB.swift`/
  `AppBootstrap`）。
- 行为不变的口径：`SettingsService.getDefaults()` 改为从枚举派生，并由
  `SettingsKeyTests` 用**迁移前逐字快照**当 oracle 钉住 68 项默认值（默认值漂移即红）。
  3 处已存在的调用点默认值漂移（`default_eps` 0.6 vs 0.65、`embedding_dim` 512 vs 128）
  **本次不修**——修它是行为变更，必须单独提交并点名。
- 命名冲突处置：原 `SettingsKey`（校验过的 key 字符串包装）改名 `SettingsKeyInput`，
  与同文件 `SettingsSetInput` / `SettingsResetInput` 一致；27 处调用点机械改名。

## #13 预览脚手架拆出生产 UI 模块

- 起因：2,178 行 DEBUG-only 预览代码住在 `GatherUI` 里，与页面/VM 同 target；
  调研结论是「原地压到 ≤800 行不可行」（结构性下限 750–850 行：81 个 throw 已是
  46.7%、fixture 已是纯数据），唯一可行路径是**换 target 所有权**。
- 结果：新增 `GatherPreviewData` target（只依赖 GatherProtocol）；
  `GatherUI/PreviewSupport` 5 文件 / **793 行**（Factory/Providers/ShellViews/缩略图/Library fixture），
  `GatherPreviewData` 7 文件 / **1,417 行**。**总行数 2,178 → 2,210（+32）**：
  多出来的是跨模块构造面 `PreviewAPIStubs`（13 个工厂）与注释，不是新增功能。
  口径要写明：这轮买的是**模块归属**，不是行数。
- 为什么 Library fixture 留在 GatherUI：`GalleryPhotoData` 是 `GalleryViewModel` 里的
  UI 类型（不是 Protocol DTO），搬过去会逼预览数据反向依赖 GatherUI → 成环。
- 门禁：`check-preview-surface.sh` 改为覆盖两个目录并求和（否则「把文件挪走」
  就能让 support_lines 假降）；已做自检（临时放一个未包裹 `#if DEBUG` 的文件
  确认 rc=1，删除后 rc=0）。必需文件按归属拆：`PreviewProviders.swift` 在 UI，
  `PreviewFixtures.swift`/`PreviewAPIs.swift` 在 GatherPreviewData。
- 未做：`.github` 与 build.sh 无改动（新 target 由 GatherUI 依赖自然进入构建图）；
  Release 下该模块为空（整目录 `#if DEBUG`）。

## #9 铺开：8 个服务改用 SettingsReading（Step 2–3）

- 生产闭包注入点 **9 → 0**：SessionService / SimilarityService / FaceKwService /
  CullingService / IndexerService / ProofFeedbackService / MetadataDeliveryService /
  MetadataRetentionService（静态工厂）/ PhotoAssetResolver（Persistence）全部改成
  `settings: any SettingsReading`；组合根 7 处 + FeatureAPIs 1 处改为传
  `SettingsService`（它已 conform 端口）。
- 顺带删掉两个死字段：MetadataDeliveryService.connection / MetadataRetentionService.connection。
- 5 个「幽灵键」转正（import_concurrency / asset_read_mode / similarity_* 三个）：
  它们从此可写、可 reset、进 getAll；默认值取此前的调用点硬编码值。

### 有意改变的行为（逐条列出，便于回溯）

1. **embedding_dim 未设置时的默认值 512 → 128**。128 是 SFace manifest 的 dimension，
   也是注册表原值；512 是调用点自带的历史默认值。它只进分析指纹（Vision 路径不用它），
   所以代价是：**已分析过的会话会被判过期、重跑一次**。
2. **import_concurrency 被写坏（NaN/inf/非数字）时回落 8**（旧行为是批大小变 0：
   静默一张都不导入）。这条改了 SessionServiceTests 的一条断言（0 → 1）。
3. **写坏的数值设置不再抛 SIM_THRESHOLD_INVALID，而是回落默认值 + 一行 warn 日志**。
   理由：设置是数据不是 API 入参；用户手改库写坏一个值不该让整条分析链失败。
   API 入参校验（rejectInvalid）不变。
4. `bool()` 定为**严格 "1" 方言**（仓里已有测试钉住「非 1 视为关闭」）；
   lazy_checksum 保持 `!= "false"`、metadata_sync_auto_confirm 保持 `== "0"`，
   各自用 string 比较，不共用折叠。

### 端口语义

- `storedValue(for:) -> String?`：nil = 未设置（不折叠默认值）；
- `string/double/int/bool` 扩展：未设置回落**键自带默认值**，非有限/不可解析回落并记 warn；
- `ClosureSettingsReader`：测试与过渡期适配器（36 个注入点零改动地继续用）。

### 测试

- core 1602 + 25、app 880 全绿（用例数不变：本轮只迁移，不新增场景）；
- 迁移中改写的断言 4 条（SessionService NaN 语义、SimilarityService corrupt 语义、
  DefaultSignatures 的 embeddingDim、SettingsKeyTests 的 bool 方言），均在上面的
  「有意改变的行为」里点名。

## #9 收尾：Host/UI 类型化设置键（69281240）

- 生产侧字符串设置键读取清零（Live*API / 组合根 / Runtime / MaintenanceService /
  TriagePolicy）；`clearableSettingKeys` 改为「默认值为空 ∩ 设置页真的暴露」派生。
- **行为变更**：`default_eps` 在 LiveFaceAPI 的本地默认 0.6 收口到注册表 0.65
  （此前 UI 显示 0.65、实际按 0.6 跑）。

### 勘误（对 0d46bbf5 提交信息的更正）

该提交信息称「删掉 MetadataDeliveryService/MetadataRetentionService 两个死 connection 字段」，
**不实**：当时只删了 MetadataDeliveryService 的那个；MetadataRetentionService 的
`connection` 字段仍在，直到 #8 端口化（下一节）才删。原因是我把两处改动写在同一个
编辑计划里，第二处因 old_string 不匹配被跳过却没复查产物。教训：机械编辑后必须用
`grep` 复核「声称删掉的东西真的没了」。

## #8 Step 0 + 1：死端口要求 + 元数据生命周期端口

- Step 0：删掉 4 条**零消费者**的端口要求（`PhotoRepository.countBySession`、
  `SimilarityHashRepository.deleteByPhotoIds`、`DuplicateGroupReading.getMemberStates`、
  `FaceRepository.getThumbnailPathsBySession`）。具体 Repo 方法保留（测试仍直接用），
  只删协议要求——端口是「给 Application 看的窗口」，没人用的窗口就是噪音。
- Step 1：新增 `Ports/MetadataLifecycleStore.swift`（2 + 9 方法），
  `MetadataDeliveryService` / `MetadataRetentionService` 从 `connection: DBConnection`
  改为吃端口，顺带删掉 Retention 的死 `connection` 字段。两个服务此前**零事务、零裸 SQL**，
  所以是纯签名替换。
- ADR-032 追加一行：解释 9 方法端口为何不违反接口隔离（按消费者切分 > 按方法数切分）。

## #8 Step 2–3：关键词索引 + 策展三仓储（Wave 1 收口）

- Step 2（03ae0cba）：`Ports/KeywordIndexStore.swift` —— `KeywordIndexStore`(5) +
  `MetadataKeywordReading`(1)；`KeywordIndexSync` 删掉 `init(connection:)`。
  顺带修正注释不实：`sync` 声称「单事务 diff」，实际 `ensure` 与 `replacePhotoKeywords`
  各开一个事务。
- Step 3：`Ports/CurationStores.swift` —— `CollectionStore`(13) + `StackStore`(12) +
  `GlobalDuplicateReading`(5)；`CurationService` 的 3 处 `connection.transaction` 改为
  `transactions.transaction`。
- **`TransactionRunner` 加 `Sendable`**（CurationService 是 Sendable 值类型，要把它存成
  字段）。唯一生产实现 `DBConnection` 已是 @unchecked Sendable；测试 fake 改成
  `OSAllocatedUnfairLock` 锁盒 + 真 `Sendable`，**不占** @unchecked 的 cleanup 预算
  （baseline 仍 60，没有新增）。
- 同源不变量：CurationService 的 4 个依赖必须来自同一个 `DBConnection`（不同连接时
  嵌套事务退化成两个独立事务，外层回滚撤不掉内层）。组合根 Core.swift 已用一个表达式
  从同一个 db 构造；新增 `CurationService 端口纪律` 用例钉住「3 个跨仓储操作各走一次
  注入的 runner」，防止有人把事务改回 repo 内部。
- 协议没有默认参数：`nameExists(excluding:)` / `create(sortOrder:)` /
  `exactGroups(minSessionCount:limit:)` 等调用点补全实参（行为不变）。

## #3：8 条 job workflow 回迁 GatherApplication（Wave 2 首项）

- `ExecutorRegistry`（Host，522 行）→ `GatherApplication/Services/Workflows/WorkflowRegistry.swift`；
  `SessionIngestRunner`（Host）→ `Services/Ingest/`（它本来就是纯 Application 逻辑，
  只是当年落在 Host；checksum.backfill 的 ingest 分支依赖它，必须先搬）。
- 依赖的两个具体 Repo 收敛成端口：`photoRepo: PhotoRepo` → `any PhotoRepository`；
  `assetRepo: AssetRepo` → `any AssetRepository`（端口补 `reconcileRawJpegLinks`，
  metadata.scan 唯一用点；PortFakeAssetRepo 同步补桩）。
- **搬运中发现一处隐藏的跨界依赖**：`JSONValue(from:)`（Encodable → JSONValue）住在
  GatherUI 的 `Support/JSONValueDecoding.swift`，Host 里的 workflow 靠 import GatherUI
  才用得上。回迁后 core 不能依赖 UI，改为本文件内 3 行私有 helper（不涨 Protocol 公开面）。
  这条依赖本身就是「workflow 长在层与 UI 之间」的证据。
- 逐字搬运的证据：`diff` 旧 blob 与新文件共 93 行差异，全部是「公开化 + 新增 init +
  改名 + 3 处 encode 调用 + helper 注释」；**8 个 executor 的函数体一字未动**。
- C3（两个设置闭包 → SettingsReading）**暂不做**：`triageModelReview` 默认 "1"，
  换成空 reader 会让模型段从关闭变开启（现有测试显式传 false），需要单独的语义判定。

## #2 S1：冲突/孤儿处置下沉 MetadataDispositionService

- `LiveMetadataAPI` 990 → **586** 行；新增 `GatherApplication/Services/Metadata/
  MetadataDispositionService.swift`（439 行，含 15 个方法：conflicts / orphans /
  resolveConflict / resolveOrphan + 投影 / 守卫 / 文件阶段）。
- 新端口 `Ports/MetadataDispositionStore.swift`：`MetadataDispositionReading`（5 方法，
  唯一消费者，每个都用到）。写入口不搬——状态迁移仍走 GatherDelivery 的
  `DeliveryStateWriter`（CAS/租约语义的拥有者）。
- 适配器只留：`Confirmed<T>` 解包、`LiveAPIInput.requireSessionId`、
  `LiveAPIErrorMapping`（`map`/`mapAsync`）、DTO 组装。错误码集合零变化：
  app 的 13 条元数据 API 用例（含锁序、TOCTOU、跨会话门禁）全绿即回归证明。
- 构造点零改动：处置服务由适配器就地装配，依赖与原来完全同源
  （同一 `deliveryRepo`、同一 `XMPFileLock` 实例），因此 `FeatureAPIs` 与 6 处测试
  构造点一字未改。
- 未做：core 侧新增 `MetadataDispositionServiceTests`（需要 XMPProvider 假件 +
  交付行种子，成本高于本步收益）；当前以 app 侧端到端用例作回归网，
  后续做「整条写回链进 core 测试」时一并补。

## #1 C0+C1：GatherMetadataIO target（写盘实现离开宿主）

- 11 文件 / 4,189 行从 `GatherHost` 搬到新 target `GatherMetadataIO`（gather-core）：
  Sidecar 组 4 文件 1,834 行（`SidecarXMPProvider` + Patching + IPTC + IPTCReading）、
  Embedded 组 7 文件 2,355 行（EmbeddedJPEGSession / IPTCIIM / JPEGMetadataWriter /
  JPEGSegments / MetadataWriteRouter / XMPPacketReader / XMPPacketStore）。
- `WebDAVCredentials`（94 行）**不搬**：它只有 Security + URLSession，不含元数据 IO，
  已归到 `GatherHost/Output/`。
- 依赖方向（Stage 1）：target 暂时依赖 Protocol + Persistence + Delivery + Application。
  原因：Embedded 的 `XMPPacketReader` / `JPEGMetadataWriter` / `MetadataWriteRouter` 还借用
  Application 的解析与 baseline 工具，router 还用 Delivery 的 `DeliveryBackupPath` 白名单。
  C4/C5 会逐个去掉，最终只留 Protocol + Persistence。
- 宿主接触面收敛为 1 个工厂：写目标路由（`MetadataWriteRouter`）仍是 internal——
  它如果公开，等于把 `XMPProvider` 的 8 个 witness 一起漏成公开 API。改为
  `MetadataIOWiring.makeRouter(...)` 返回「`any XMPProvider` + 写路径闭包 + 目标种类闭包」，
  宿主不再 `as?` 下转具体类型（旧实现在注入 provider 时靠 cast 失败回退 sidecar，新实现
  用同一条分支显式表达，行为逐字一致）。
- 门禁改动：`check-layering.sh` 增加 `GatherMetadataIO` 扫描根 + 禁止 UI/入口 import 它；
  `check-protocol-surface.sh` 的生产扫描列表补上该目录（否则搬走的 DTO 会被误判为
  「零引用」——实测 `MetadataTargetPolicy` 立刻假阳性，已修）。
- 未做：C2 把 10 个 app 测试文件（2,715 行 / 87 用例）迁进 core；C3 加
  「delivered == 磁盘真写了」不变量套件。当前 app 测试仍覆盖这些实现。

## #1 C2：10 个元数据 IO 测试迁回 core

- `gather-app/Tests/GatherAppTests` → `gather-core/Tests/GatherCoreTests/MetadataIO/`：
  SidecarXMPProviderTests / +IPTCTests / MetadataWriteRouterTests / +ReadTests /
  EmbeddedRewriteSessionTests / EmbeddedMetadataWriterTests / JPEGSegmentsTests /
  XMPPacketReaderTests / JPEGMetadataWritebackTests / DeliveryFilePortTests（87 个用例）。
- 计数移位而非新增：core 1603 → **1690**（+87）、app 880 → **793**（-87），总数不变。
- 两个文件（SidecarXMPProvider*Tests）原本 `@testable import GatherUI` 但零符号使用，
  属死 import，迁移时一并删除——这也是它们能进 core 的前提（core 不能依赖 UI）。
- `GatherCoreTests` 目标依赖补 `GatherMetadataIO`。
- 未做：C3 的跨层不变量套件（`deliveries.status == written ⇒ 目标文件回读 == base_values`）。
  它需要真实 DeliveryCoordinator + 交付行种子；当前由 87 个 IO 层用例覆盖实现细节。

## #10 设计决策：**不统一**两套过滤模型（写于实施前）

调研结论（逐字段对照后）：图库 `FilterGroup` 与挑片 `CullingFilters` 真正重复的 SQL
仅 13 行（`CullingAssetPageQuery.swift:352-364` 的 COALESCE 列规范化），其余全是语义分歧：

- **空值口径**：星级图库用 `pmc.rating = 0`（无缓存行不算），挑片用 `COALESCE(..., 0)`（算）；
  色标图库只匹配字面 `None`，挑片把 `''/NULL/None` 都算——三种形态在生产里都真实存在
  （写回写 `''`、reset 写 `None`、未抽取为 NULL）。
- **粒度**：图库「任一变体命中即整组入选」，挑片「首选行命中」；变体星级不同时两页结果不同。
- **游标契约**：`CullingPageCursor`（多键 + 方向）vs `PhotoPage.cursor: Int64`，
  `PhotoFilterQuery` 明确不做多键排序。
- **专有维度**：挑片态/未审/质量/冲突/triage 在图库是未知字段（直接抛错）。

因此否决 (a) 共享 DSL 与 (b) 模型归一（会涨协议公开面且仍解不了空值/粒度分歧），
改走 **(c′) 等价契约测试 + Persistence 层共享「列规范化」谓词原子**：

1. `FilterSemanticsContractTests`：把「两页在共享维度上同集合」「已知分歧显式断言」
   「图库对挑片专有维必须抛错」「`pageFilter` 七维映射表」钉成用例；
2. `FilterFieldSQL`（Persistence，~40 行）：只做 `COALESCE(NULLIF(col,''), ...)` 这类
   列规范化，**不建 DSL、不进 Protocol**，维持 411/2441 不变；
3. 语义变更（图库星级/色标的空值口径）单独提交并点名——结果集变多是**有意**的。

风险记录：对 label 无差别套 COALESCE 会让 `label exists` 变恒真，只能 op-aware（仅 eq/in）。

## #10 Step 2：列规范化原子 + 空值口径统一（**有意改变图库结果集**）

- 新增 `Persistence/Database/Queries/FilterFieldSQL.swift`：
  `rating(col)` = `COALESCE(col, 0)`、`label(col)` = `COALESCE(NULLIF(col, ''), 'None')`。
  两套查询都改为引用这两个原子（挑片原本就是内联同款表达式，图库是这次对齐的）。
- **行为变更（有意）**：图库的 `rating eq/in` 现在把「没有 photo_metadata_cache 行」
  按 0 星算（此前要求有缓存行），`label eq/in "None"` 把 `''` 与 NULL 也算 None
  （此前只认字面 None）。这修的是图库**自身**的不一致：投影 `COALESCE(pmc.rating,0)`
  早就把它当 0 星，谓词却当「没有」。代价是这两个条件的结果集变多。
- 只对 `eq/in` 生效：套到 `neq/gt/exists` 会改「未填写」语义（`label exists` 会恒真）。
- 结果：label 两页**已同集合**（3 == 3）；rating 仍是 3(图库) vs 2(挑片)，
  但差异已收窄为纯**行粒度**（任一行 vs 首选行），不再是空值口径——粒度是否统一
  属产品决策（改图库为 preferred-row 要动 4 处 SQL + facet），不在本轮范围。
- 测试：`FilterSemanticsContractTests` 相应改为「已同集合」/「仅剩粒度差」；
  `PhotoFilterQueryTests` 的 SQL 形状断言改为按字段套用规范化表达式。

## #2 S3（部分）：淘汰移出抽纯规划器

- 阻塞点：整段 `moveRejected` 需要在 `XMPFileLock.run`（`@Sendable` 闭包）里捕获 `self`，
  而它的依赖（`any PhotoRepository` 等）不是 Sendable，整段下沉会新增一处
  `@unchecked Sendable`——当时预算正好 60/60。
- 本轮解法：把**不需要锁、不需要写盘**的决策部分抽成纯函数
  `RejectedMovePlanner.plan(requestedIds:candidates:rejectedIds:sessionSourcePath:explicitDestinationRoot:)`：
  资产展开、skipped 归因、sharesSidecar 判定、目标目录安全校验。适配器只负责取数
  （三处读）与锁内搬移。
- 收益：这四条不变量第一次能在 core 侧单测（4 个用例，不需要 DB / 文件系统 / app target）。
- 仍未解决：锁内搬移循环仍在适配器里（它才是需要 `@unchecked` 的部分）。要彻底下沉
  需先决定路线：三仓储端口 Sendable 化 / 削减既有 @unchecked / 接受预算上涨。

## #1 C3：跨层不变量（deliveries == written ⇒ 磁盘回读 == 写入值）

- 新增用例（在 `MetadataIO/JPEGMetadataWritebackTests.swift`）：真实 JPEG + 真实
  `SidecarXMPProvider` + 真实 `WritebackService`，写完后同时断言两件事：
  ① `deliveries.status == "written"`；② `readAttributes` 回读的 caption == 写入值。
- 为什么此前没有：写盘实现住在 app target 时，「状态机说已写」与「磁盘内容」分居两个
  target，没有任何用例把两者放在一起比过——这正是 #1 要兑现的收益。
- 口径注意：用例只比 sidecar 口径。内嵌 title 属于 APP1，要读它得走 ImageIO 解析
  （另一条用例已覆盖）；混在一起会让这条不变量失焦——首版就是因为比了内嵌 title
  而误红，已改正并写进注释。

## #11（第一步）：领域事件契约门禁 + 第 5 条游离通道归口

- 现状：4 条进程内通知的通道名是字符串、载荷是 `Any`（17 处 `as?` 下转），
  「哪个写路径该发哪个域」只是约定；另有第 5 条 `.c1AutoReloadFailed` 游离在
  `CullingViewModel+Writeback` 里。
- 本轮：
  1. 第 5 条通道归口到 `GatherEventCenter`（与其余 4 条并列登记），生产者改指它；
  2. 新增 `scripts/check-domain-events.sh`：
     R1 通道名闭包（`Notification.Name("gather.…")` 只允许出现在 2 个文件）、
     R2 发布点白名单（8 个文件；每个文件只能发登记的域，变参发布单独登记）。
  3. 接入 CI gates job 与 `docs/DEVELOPMENT.md` 门禁清单。
- 自检：往 `Support/` 塞一个未登记的 `postDomainChange(.similarity)` → rc=1；
  删除后 rc=0（脚本本身不自证就等于没写门禁）。
- 未做（下一步）：R3「写路径必须发域」配对规则 + 类型化 envelope（`TypedEventChannel`）。
  调研已确认：今天有 6 类破坏性写完全没广播（`applyTriageWriteback` / cleanupRetention /
  集合栈写 / 模板套用 / 导入 / 设置），必须先落「域→生产者」映射表才谈得上 R3；
  且 R3 需要 `// DOMAIN-EVENT: none — <原因>` 的显式 opt-out，不能文件级豁免。

## #6 S0：MetadataService 纯函数簇切出（第一刀）

- `MetadataService.swift`：**1,645 → 1,417 行**（-228）；新增
  `Services/Metadata/MetadataAttributes.swift`（268 行，`public enum` 命名空间）。
- 切出的是研究里说的「二八」部分：36 个函数中 17 个 `static`（254 行），全部无 `self`、
  无 IO、无事务——搬它们是等价变换。四个公开入口（mergeAttributes / mergeDescriptive /
  embeddedAttributesFromParse / normalizeKeywordList 的一部分）在门面保留同名转发，
  所以 18 处跨 target 调用点（含 `GatherMetadataIO` 的内嵌 JPEG 读路径）**一行未改**。
- 踩到一处签名细节：`mergeDescriptive` 的入参/返回都是 optional（`nil` 表示「无描述性
  元数据」），委托写成非 optional 会编译失败——已按原签名保留。
- 未做（后续步）：S1-S5（MetadataDiskReader / PhotoMetadataProjector / Extraction /
  AttributeWriter / KeywordWriter）与「三仓储端口 Sendable 化」前置；后者是解开
  #2 S3 锁内循环的关键。

## #6 前置：两个仓储端口 Sendable 化（零预算）

- `MetadataRepository` / `PhotoRepository` 协议加 `: Sendable`；
  `PhotoRepo` / `MetadataKeywordOriginRepo` 声明 `Sendable`——它们各自只有一个
  `let connection: DBConnection`（DBConnection 已是 @unchecked Sendable），
  按「final class + 全 let + 全 Sendable 属性」隐式满足，**不需要新增 @unchecked**。
- `MetadataCacheRepo` 早已是 Sendable，所以 MetadataRepository 是零成本。
- 测试替身（PortFakePhotoRepo / PortFakeMetadataRepo）带可变记录器，只能 @unchecked；
  它们位于 Tests，**不进** cleanup-ratchet 的计数范围（baseline scope 只扫 Sources）。
- 意义：这一步同时解开两个死结——#6 的 S3/S4（Extraction/AttributeWriter 要存这些端口）
  与 #2 S3 剩余的「锁内搬移循环」（需要捕获 `any PhotoRepository`）。
- 门禁读数未变：unchecked 60 / try? 255 / prepare 0。
