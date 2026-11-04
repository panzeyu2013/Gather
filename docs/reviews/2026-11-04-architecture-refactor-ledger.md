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
