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
