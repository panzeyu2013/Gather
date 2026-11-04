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
