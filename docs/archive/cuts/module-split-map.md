# Cut 3 前置设计：模块拆分映射表（module split map）

> 状态：**设计稿（docs-only）**。本任务的唯一产出物就是本文件；未修改任何源码、`Package.swift`、脚本，未移动/删除文件，未做 git commit。
> 依据：`docs/reviews/refactor-design-breaking-2026-10-21.md` §2（目标图）/§6（算法归属）/§7（构建与门禁）/§9（Cut 3）、
> `docs/cleanup-backlog.md` §3（表/Repo）、§4（未用 public 符号）、§5（重复实现）、`docs/refactor-decisions.md` D-006（ratchet 扫描范围）/D-008（Album/Template 保留）、
> `desktop/native/gather-core/Package.swift`、`desktop/native/gather-app/Package.swift`、`desktop/native/build.sh`、`scripts/check-layering.sh`。
> 证据口径：本文件所有文件数/行数/符号引用均由 2026-10-21T23:38+0800 的一次静态扫描得出（命令见附录 A）；行号会漂移，引用前请重新 `read` 核对。
> **Cut 1 更新（2026-10-22）**：本文标注“删除（Cut 1）”的 Router/命令面文件已实际删除；Cut 2 的 MigrationTests 已由 556 行缩至 169 行（S5c-2a），其余为 Cut 3 设计快照。

---

## 0. 快照、口径与漂移

### 0.1 快照数字

| 项 | 数值 |
| --- | --- |
| 快照时刻 | 2026-10-21T23:38+0800 |
| `.swift` 文件总数（含 2 个 `Package.swift`） | 306 |
| 需归位的源/测试文件（不含清单） | 304 |
| 总行数 | 105,655 |
| `gather-core/Sources/GatherCore/**`（今日的库 target） | 136 |
| `gather-core/Sources/` 可执行（Helper / Benchmarks / FaceBenchmarks） | 3 |
| `gather-core/Tests/GatherCoreTests/**` | 89 |
| `gather-app/Sources/GatherApp/**` + 6 个根级功能目录 | 45 |
| `gather-app/Tests/GatherAppTests/**` | 31 |
| 其中 **Cut 1A 并行落地**的 `Sources/GatherCore/API/**` | 46 文件 / 2,708 行 |

### 0.2 与任务口径「257」的对照（重要）

任务给的是 **Cut 0 冻结基线**（`docs/cleanup-backlog.md` §1）：core Sources 93 + core Tests 88 + app Sources 46（该口径把 app 的 `Package.swift` 算进 46）+ app Tests 29 + core `Package.swift` 1 = **257**。

当前快照是 **306**，比基线多 49，来源可逐项对账：

| 增量 | 数量 | 说明 |
| --- | --- | --- |
| `gather-core/Sources/GatherCore/API/**` | +46 文件 | Cut 1 / 1A 在本文件写作期间并行落地（16 域协议、Inputs/Outputs、`GatherError`、`Core/` 校验类型）。**不属于 257 基线**，但 Cut 3 必须一并归位 → `GatherProtocol` |
| `gather-core/Tests/GatherCoreTests/Support/AsyncGate.swift` | +1 | Cut 0 D-004 的测试 helper 收敛产物 |
| `gather-app/Tests/GatherAppTests/Support/{AsyncGate,LockedBox}.swift` | +2 | 同上（每包 1 份） |
| 清单计数 | +1 | 基线只把 core 的 `Package.swift` 计入 257，本次把两个包都计入 |
| app Sources 口径 | −1 | 基线 46 含 `gather-app/Package.swift`，本次单列 |

**结论：去掉 46 个 API 文件后是 258 个「非 API」源/测试文件**，与 257 只差 1（上表的 ±1 口径差）。也就是说：任务要求的「257 个文件」已被完整覆盖，另有 46 个 Cut 1 新文件按同一规则归入 `GatherProtocol`。

> ⚠️ 漂移提示：快照之后 Cut 1B/1C 还会在 `gather-app/Sources/GatherApp/Host/APIs/**` 追加 Live 实现（本文件写作时该目录尚不存在）。这些文件按 §0.3 规则归 `GatherHost`；届时 §2.1 的文件数会增加，但**本文件的映射结论与越界点判定不变**。

### 0.3 归位规则（Cut 1/2 后续新文件的唯一判据）

本文件的表格是按下列**目录规则**生成的，不是逐条人工决定。Cut 1/2 结束时如新增文件，按此表直接归位即可，不需要重写本文件：

| 目录 / 文件模式 | 目标 target | 备注 |
| --- | --- | --- |
| `gather-core/Sources/GatherCore/API/**` | GatherProtocol | Cut 1 新增；含 16 域协议 + Inputs/Outputs + GatherError |
| `gather-core/Sources/GatherCore/Protocol/**`、`Logging/**` | GatherProtocol | DTO / 错误码 / JSONValue / Logger |
| `gather-core/Sources/GatherCore/Database/Schema.swift` | GatherSchema | Cut 2 改名为 `SchemaV1.swift` |
| `gather-core/Sources/GatherCore/Database/**`（其余） | GatherPersistence | `Migrations.swift` 例外 → 删除 |
| `gather-core/Sources/GatherCore/{Face,Image,Concurrent,Similarity}/**` | GatherAnalysis | 人脸 / 解码 / 位图 / 哈希 / 聚类 |
| `gather-core/Sources/GatherCore/IPC/**` | GatherAnalysis | **过渡归属**，见 E-03 与 §10 D-015 |
| `gather-core/Sources/GatherCore/Services/**` | GatherDomain | 28 个 Service/领域助手文件 |
| `gather-core/Sources/CSQLite/**` | CSQLite | 保持原位（C target，0 个 .swift） |
| `gather-core/Sources/{GatherCoreHelper,GatherCoreBenchmarks,GatherFaceBenchmarks}/**` | 同名可执行 | 保持原位 |
| `gather-app/Sources/GatherApp/Host/**` + `RootView.swift` | GatherHost | 组合根 / 委托 / 桥 |
| `gather-app/Sources/GatherApp/GatherApp.swift` | GatherApp | 仅 `@main` + Scene |
| `gather-app/Sources/GatherApp/**`（其余） | GatherUI | Shell / 页面 / Support |
| `gather-app/{Culling,Settings,Export,Duplicates,ControlCenter,FaceKeywording}/**` | GatherUI | Cut 3 移入 `Sources/GatherUI/Features/` |
| `gather-core/Tests/GatherCoreTests/Protocol/**` + `HelperMessageTests` + `LoggerTests` | GatherProtocolTests | |
| `.../Tests/GatherCoreTests/Database/**`（`*RepoTests`、`DatabasePragmaTests`） | GatherPersistenceTests | |
| `.../Tests/GatherCoreTests/{Face,Image,Concurrent,Similarity,Reconciliation,IPC}/**` | GatherAnalysisTests | |
| `.../Tests/GatherCoreTests/Services/**` | GatherDomainTests | |
| `.../Tests/GatherCoreTests/Support/**` + `Database/Repositories/RepoTestSupport.swift` | GatherTestSupport（测试专用库 target） | 见 §6.3 |
| `gather-app/Tests/GatherAppTests/**` | GatherAppTests | 单 target，内部分 UI/Host/Support 三组 |

### 0.4 判定口径
- **【已确认】**：本文件标出的引用/越界均有 `文件:行` 证据（附录 B 汇总）。
- **【疑似】**：需构建或运行验证的结论，单独标注。
- 行号取自 §0.1 快照；Cut 1/2 合并后会有 ±50 行漂移。

---

## 1. 目标与不变量

### 1.1 target 清单（12 个 target + 1 个测试专用）

| target | 类型 | 来源目录 | 产品名 | 过渡 / 最终 |
| --- | --- | --- | --- | --- |
| GatherProtocol | library | `Sources/GatherProtocol/{API,DTO,Logging}` | `GatherProtocol` | 最终 |
| GatherSchema | library（薄） | `Sources/GatherSchema` | `GatherSchema` | 最终（去留待决 D-014） |
| GatherPersistence | library | `Sources/GatherPersistence` | `GatherPersistence` | 最终 |
| GatherAnalysis | library | `Sources/GatherAnalysis` | `GatherAnalysis` | 最终（其中 `IPC/` 过渡） |
| GatherDomain | library | `Sources/GatherDomain` | `GatherDomain` | 最终 |
| GatherUI | library（SwiftUI） | `gather-app/Sources/GatherUI` | `GatherUI` | 最终 |
| GatherHost | library（SwiftUI） | `gather-app/Sources/GatherHost` | `GatherHost` | 最终（`RootView` 为过渡归属） |
| GatherApp | executable | `gather-app/Sources/GatherApp` | `gather-app` | 最终（仅 `@main`） |
| CSQLite | systemLibrary 风格 C target | `gather-core/Sources/CSQLite` | — | 最终 |
| GatherCoreHelper | executable | 原位 | `gather-core-helper` | **过渡**（helper 是否退役见 D-015） |
| GatherCoreBenchmarks | executable | 原位 | `gather-core-benchmarks` | 最终（工具） |
| GatherFaceBenchmarks | executable | 原位 | `gather-face-benchmarks` | 最终（工具） |
| GatherTestSupport | library（测试专用，非产品） | `gather-core/Tests/GatherTestSupport` | 无 | 最终（测试基建） |

测试 target 5 个：`GatherProtocolTests`、`GatherPersistenceTests`、`GatherAnalysisTests`、`GatherDomainTests`、`GatherAppTests`。

### 1.2 依赖图（编译器强制，无 umbrella）

```text
GatherProtocol            （0 依赖；DTO / API 协议 / GatherError / PhotoFileTypes / Logging）
  ├── GatherSchema        （0 依赖；仅 DDL 文本与表/列常量）
  ├── GatherPersistence   → Protocol, Schema, CSQLite
  ├── GatherAnalysis      → Protocol
  └── GatherUI            → Protocol（+ Analysis，例外 X-01）

GatherDomain   → Protocol + Schema + Persistence + Analysis
GatherHost     → UI + Domain + Persistence + Analysis + Protocol
GatherApp      → Host + UI（仅 @main / Scene）
```

**与设计文档 §2 的差异只有一处，且是有意为之**：

- **X-01（UI → Analysis）**：设计文档写「UI 只 import GatherProtocol」，但 `Support/PhotoThumbnailView.swift` 在缩略图热路径上直接调 `RAWDecoder`（3 处，E-04）。若强制 UI 只见 Protocol，必须新增 `ImageCodec` 协议 + 异步 Host 实现，代价是每次缩略图解码跨 target/actor，与 §6「缩略图统一 loader」的性能目标冲突。
  建议：**允许 `GatherUI → GatherAnalysis`，但只允许 `RAWDecoder` / `ImageDimensions` 两个符号**，并把白名单写进 `check-layering.sh`；同时 `GatherUI` 仍**不得** import `GatherPersistence` / `GatherDomain`（这条正是 Cut 3 的硬验收）。需登记为新决策 D-013。

### 1.3 不变量（Cut 3 退出时必须同时成立）

| ID | 不变量 | 检查手段 |
| --- | --- | --- |
| I-01 | 无 `GatherCore` umbrella target、无 `import GatherCore` | `grep -rn 'import GatherCore' desktop/native` = 0 |
| I-02 | UI 不 import Persistence/Domain | `scripts/check-layering.sh` + 显式 grep |
| I-03 | Analysis 不 import Persistence/CSQLite，且无 DB 符号 | grep `DBConnection\|prepare(\|import CSQLite` = 0 |
| I-04 | 每个 target 只 import 显式声明的直接依赖 | `--explicit-target-dependency-import-check error` 构建通过 |
| I-05 | 资源归属唯一：模型随 Analysis、本地化随 UI | `build.sh` 的 assert + 手工 `ls *.bundle` |
| I-06 | 每个测试 target 可单独 `swift test --filter` 运行 | CI 4 条 test 命令 |

---

## 2. 逐文件映射

> 路径前缀已省略：core 生产表省略 `desktop/native/gather-core/`，app 生产表省略 `desktop/native/gather-app/`，测试表省略 `.../Tests/GatherCoreTests/` 与 `.../Tests/GatherAppTests/`。
> 处置四类：**保持原位**（物理路径不变）、**移动**（换目录/换 target）、**新建**、**删除**（Cut 1/2 已计划删除，Cut 3 时不存在）；`移动+改名` 是移动的子类。

### 2.1 按 target 汇总

| target | 文件数 | 行数 |
| --- | --- | --- |
| GatherProtocol | 65 | 7,346 |
| GatherSchema | 1 | 649 |
| GatherPersistence | 20 | 7,356 |
| GatherAnalysis | 21 | 6,102 |
| GatherDomain | 28 | 16,738 |
| CSQLite | 0 | 0 |
| GatherUI | 35 | 22,201 |
| GatherHost | 6 | 3,052 |
| GatherApp | 1 | 343 |
| GatherCoreHelper | 1 | 30 |
| GatherCoreBenchmarks | 1 | 333 |
| GatherFaceBenchmarks | 1 | 129 |
| GatherProtocolTests | 19 | 3,287 |
| GatherPersistenceTests | 17 | 4,289 |
| GatherAnalysisTests | 24 | 6,498 |
| GatherDomainTests | 26 | 13,634 |
| GatherTestSupport | 2 | 146 |
| GatherAppTests（UI 组） | 19 | 6,038 |
| GatherAppTests（Host 组） | 5 | 1,031 |
| GatherAppTests（Support 组） | 4 | 148 |
| —（删除 8） | 8 | 6,127 |
| **合计** | **304** | **105,477** |

上表 304 个文件的 105,477 行不含清单；加 2 个 `Package.swift`（77 + 101 = 178 行）即 §0.1 的 306 文件 / 105,655 行。两个清单**原位重写**，不参与归位。另有 Cut 3 新建的 2 个文件（`GatherProtocol/PhotoFileTypes.swift`、`GatherHost/AppServices.swift`，见 §2.6）。

Cut 3 结束时（Cut 1/2 的删除已生效）：生产 182 文件、测试 116 文件，共 298 个源/测试文件 + 2 个清单。

### 2.2 gather-core 生产文件（136 个，`Sources/GatherCore/**`）

| 源文件 | 行 | 目标 target | 处置 |
| --- | --- | --- | --- |
| API/AlbumAPI.swift | 21 | GatherProtocol | 移动 |
| API/APIContractIndex.swift | 42 | GatherProtocol | 移动 |
| API/AssetAPI.swift | 21 | GatherProtocol | 移动 |
| API/Core/BoundedString.swift | 26 | GatherProtocol | 移动 |
| API/Core/Confirmed.swift | 39 | GatherProtocol | 移动 |
| API/Core/NonEmpty.swift | 18 | GatherProtocol | 移动 |
| API/Core/PageRequest.swift | 55 | GatherProtocol | 移动 |
| API/Core/PhotoPathPolicy.swift | 18 | GatherProtocol | 移动 |
| API/Core/Validation.swift | 108 | GatherProtocol | 移动 |
| API/CullingAPI.swift | 37 | GatherProtocol | 移动 |
| API/DuplicateAPI.swift | 18 | GatherProtocol | 移动 |
| API/Errors/GatherError.swift | 62 | GatherProtocol | 移动 |
| API/ExportAPI.swift | 20 | GatherProtocol | 移动 |
| API/FaceAPI.swift | 35 | GatherProtocol | 移动 |
| API/Inputs/AlbumInputs.swift | 54 | GatherProtocol | 移动 |
| API/Inputs/AssetInputs.swift | 71 | GatherProtocol | 移动 |
| API/Inputs/CullingInputs.swift | 282 | GatherProtocol | 移动 |
| API/Inputs/DuplicateInputs.swift | 84 | GatherProtocol | 移动 |
| API/Inputs/ExportInputs.swift | 62 | GatherProtocol | 移动 |
| API/Inputs/FaceInputs.swift | 246 | GatherProtocol | 移动 |
| API/Inputs/JobInputs.swift | 43 | GatherProtocol | 移动 |
| API/Inputs/MetadataInputs.swift | 145 | GatherProtocol | 移动 |
| API/Inputs/PersonInputs.swift | 75 | GatherProtocol | 移动 |
| API/Inputs/PhotoInputs.swift | 226 | GatherProtocol | 移动 |
| API/Inputs/QualityInputs.swift | 39 | GatherProtocol | 移动 |
| API/Inputs/SessionInputs.swift | 134 | GatherProtocol | 移动 |
| API/Inputs/SettingsInputs.swift | 73 | GatherProtocol | 移动 |
| API/Inputs/SimilarityInputs.swift | 166 | GatherProtocol | 移动 |
| API/Inputs/TemplateInputs.swift | 52 | GatherProtocol | 移动 |
| API/JobAPI.swift | 21 | GatherProtocol | 移动 |
| API/MetadataAPI.swift | 24 | GatherProtocol | 移动 |
| API/NavigationAPI.swift | 19 | GatherProtocol | 移动 |
| API/Outputs/AlbumOutputs.swift | 18 | GatherProtocol | 移动 |
| API/Outputs/CullingOutputs.swift | 19 | GatherProtocol | 移动 |
| API/Outputs/FaceOutputs.swift | 22 | GatherProtocol | 移动 |
| API/Outputs/JobOutputs.swift | 27 | GatherProtocol | 移动 |
| API/Outputs/PersonOutputs.swift | 27 | GatherProtocol | 移动 |
| API/Outputs/PhotoOutputs.swift | 43 | GatherProtocol | 移动 |
| API/Outputs/SessionOutputs.swift | 22 | GatherProtocol | 移动 |
| API/PersonAPI.swift | 24 | GatherProtocol | 移动 |
| API/PhotoAPI.swift | 42 | GatherProtocol | 移动 |
| API/QualityAPI.swift | 16 | GatherProtocol | 移动 |
| API/SessionAPI.swift | 39 | GatherProtocol | 移动 |
| API/SettingsAPI.swift | 22 | GatherProtocol | 移动 |
| API/SimilarityAPI.swift | 31 | GatherProtocol | 移动 |
| API/TemplateAPI.swift | 20 | GatherProtocol | 移动 |
| Concurrent/BatchCursor.swift | 59 | GatherAnalysis | 移动 |
| Concurrent/BatchRunner.swift | 80 | GatherAnalysis | 移动 |
| Database/DB.swift | 411 | GatherPersistence | 移动 |
| Database/ImageCache.swift | 102 | GatherPersistence | 移动+改名（SHA256.swift，CL-13） |
| Database/Migrations.swift | 1628 | — | 删除（Cut 2 / CL-02） |
| Database/Repositories/AnalysisJobRepo.swift | 439 | GatherPersistence | 移动 |
| Database/Repositories/AssetRepo.swift | 1220 | GatherPersistence | 移动 |
| Database/Repositories/CullingDecisionRepo.swift | 213 | GatherPersistence | 移动 |
| Database/Repositories/CullingHistoryRepo.swift | 179 | GatherPersistence | 移动 |
| Database/Repositories/FaceFeedbackRepo.swift | 70 | GatherPersistence | 移动 |
| Database/Repositories/FaceRepo.swift | 1061 | GatherPersistence | 移动 |
| Database/Repositories/MetadataCacheRepo.swift | 248 | GatherPersistence | 移动 |
| Database/Repositories/MetadataKeywordOriginRepo.swift | 57 | GatherPersistence | 移动 |
| Database/Repositories/MetadataOutboxRepo.swift | 897 | GatherPersistence | 移动 |
| Database/Repositories/PersonRepo.swift | 876 | GatherPersistence | 移动 |
| Database/Repositories/PhotoRepo.swift | 356 | GatherPersistence | 移动 |
| Database/Repositories/RepositorySupport.swift | 260 | GatherPersistence | 移动 |
| Database/Repositories/SessionRepo.swift | 181 | GatherPersistence | 移动 |
| Database/Repositories/SettingsRepo.swift | 48 | GatherPersistence | 移动 |
| Database/Repositories/SimilarityClusterStateRepo.swift | 173 | GatherPersistence | 移动 |
| Database/Repositories/SimilarityResultRepo.swift | 199 | GatherPersistence | 移动 |
| Database/Repositories/SmartAlbumRepo.swift | 161 | GatherPersistence | 移动 |
| Database/Repositories/WritebackRepo.swift | 205 | GatherPersistence | 移动 |
| Database/Schema.swift | 649 | GatherSchema | 移动+改名（SchemaV1.swift，Cut 2） |
| Face/Alignment.swift | 307 | GatherAnalysis | 移动 |
| Face/Clusterer.swift | 533 | GatherAnalysis | 移动 |
| Face/ClusteringImpact.swift | 442 | GatherAnalysis | 移动 |
| Face/EmbeddingModel.swift | 646 | GatherAnalysis | 移动 |
| Face/Encoder.swift | 251 | GatherAnalysis | 移动 |
| Face/FaceQuality.swift | 85 | GatherAnalysis | 移动 |
| Face/IdentityPolicy.swift | 37 | GatherAnalysis | 移动 |
| Face/Inference.swift | 106 | GatherAnalysis | 移动 |
| Face/Matcher.swift | 304 | GatherAnalysis | 移动 |
| Face/Provider.swift | 94 | GatherAnalysis | 移动 |
| Face/VectorIndex.swift | 866 | GatherAnalysis | 移动 |
| Image/Dimensions.swift | 186 | GatherAnalysis | 移动 |
| Image/RAWDecoder.swift | 284 | GatherAnalysis | 移动 |
| IPC/HelperMessage.swift | 37 | GatherAnalysis | 移动（过渡：helper 线协议） |
| IPC/HelperProtocol.swift | 84 | GatherAnalysis | 移动（过渡：helper 线协议） |
| IPC/ImageCommands.swift | 138 | GatherAnalysis | 移动（过渡：helper 线协议） |
| Logging/Logger.swift | 72 | GatherProtocol | 移动 |
| Protocol/Assets.swift | 93 | GatherProtocol | 移动 |
| Protocol/Core.swift | 728 | GatherProtocol | 移动 |
| Protocol/Culling.swift | 687 | GatherProtocol | 移动 |
| Protocol/Duplicate.swift | 227 | GatherProtocol | 移动 |
| Protocol/Export.swift | 308 | GatherProtocol | 移动 |
| Protocol/Face.swift | 273 | GatherProtocol | 移动 |
| Protocol/Filter.swift | 339 | GatherProtocol | 移动 |
| Protocol/Indexer.swift | 36 | GatherProtocol | 移动 |
| Protocol/Jobs.swift | 194 | GatherProtocol | 移动 |
| Protocol/Metadata.swift | 416 | GatherProtocol | 移动 |
| Protocol/Navigation.swift | 98 | GatherProtocol | 移动 |
| Protocol/Person.swift | 220 | GatherProtocol | 移动 |
| Protocol/Quality.swift | 96 | GatherProtocol | 移动 |
| Protocol/Session.swift | 213 | GatherProtocol | 移动 |
| Protocol/Settings.swift | 86 | GatherProtocol | 移动 |
| Protocol/Similarity.swift | 188 | GatherProtocol | 移动 |
| Protocol/Template.swift | 176 | GatherProtocol | 移动 |
| Protocol/Workspace.swift | 188 | GatherProtocol | 移动 |
| Services/CaptureOneSyncState.swift | 57 | GatherDomain | 移动 |
| Services/CullingService.swift | 2572 | GatherDomain | 移动 |
| Services/DuplicateService.swift | 823 | GatherDomain | 移动 |
| Services/ExportService.swift | 1119 | GatherDomain | 移动 |
| Services/FaceKwService.swift | 2042 | GatherDomain | 移动 |
| Services/FilterEngine.swift | 568 | GatherDomain | 移动 |
| Services/ImageMetadataProviders.swift | 199 | GatherDomain | 移动 |
| Services/ImagePreloadService.swift | 82 | GatherDomain | 移动 |
| Services/IndexerService.swift | 1379 | GatherDomain | 移动 |
| Services/JobService.swift | 1014 | GatherDomain | 移动 |
| Services/MetadataConflictFields.swift | 116 | GatherDomain | 移动 |
| Services/MetadataContract.swift | 96 | GatherDomain | 移动 |
| Services/MetadataFingerprint.swift | 42 | GatherDomain | 移动 |
| Services/MetadataMutationService.swift | 205 | GatherDomain | 移动 |
| Services/MetadataProviders.swift | 139 | GatherDomain | 移动 |
| Services/MetadataService.swift | 660 | GatherDomain | 移动 |
| Services/MetadataSyncCoordinator.swift | 1230 | GatherDomain | 移动 |
| Services/NavigationService.swift | 553 | GatherDomain | 移动 |
| Services/PhotoAssetResolver.swift | 170 | GatherDomain | 移动 |
| Services/PhotoAssets.swift | 45 | GatherDomain | 移动 |
| Services/QualityService.swift | 615 | GatherDomain | 移动 |
| Services/SessionService.swift | 325 | GatherDomain | 移动 |
| Services/SettingsNumber.swift | 19 | GatherDomain | 移动 |
| Services/SettingsService.swift | 181 | GatherDomain | 移动 |
| Services/SimilarityService.swift | 1064 | GatherDomain | 移动 |
| Services/TemplateService.swift | 272 | GatherDomain | 移动 |
| Services/WorkspaceStatusService.swift | 323 | GatherDomain | 移动 |
| Services/WritebackService.swift | 828 | GatherDomain | 移动 |
| Similarity/ClusterEngine.swift | 753 | GatherAnalysis | 移动 |
| Similarity/Hash.swift | 44 | GatherAnalysis | 移动 |
| Similarity/IncrementalClusterer.swift | 766 | GatherAnalysis | 移动 |

**其余 5 个文件（不在 `Sources/GatherCore/` 下，一并列出以保证 306 个文件全覆盖）：**

| 源文件 | 行 | 目标 target | 处置 |
| --- | --- | --- | --- |
| `gather-core/Sources/GatherCoreHelper/main.swift` | 30 | GatherCoreHelper | 保持原位 |
| `gather-core/Sources/GatherCoreBenchmarks/main.swift` | 333 | GatherCoreBenchmarks | 保持原位 |
| `gather-core/Sources/GatherFaceBenchmarks/main.swift` | 129 | GatherFaceBenchmarks | 保持原位 |
| `gather-core/Package.swift` | 77 | （清单） | 原位重写（§4.1） |
| `gather-app/Package.swift` | 101 | （清单） | 原位重写（§4.2） |

另有 `gather-core/Sources/CSQLite/` 的 3 个**非 Swift** 文件（`module.modulemap`、`shim.h`、`placeholder.c`）保持原位，故 `CSQLite` 在 §2.1 中文件数为 0。136 + 5 + 45 + 89 + 31 = **306**，与 §0.1 一致。

### 2.3 gather-app 生产文件（45 个）

| 源文件 | 行 | 目标 target | 处置 |
| --- | --- | --- | --- |
| ControlCenter/SessionControlView.swift | 1073 | GatherUI | 移动 |
| Culling/CullingView.swift | 3525 | GatherUI | 移动 |
| Duplicates/DuplicatesView.swift | 834 | GatherUI | 移动 |
| Export/ExportView.swift | 1139 | GatherUI | 移动 |
| FaceKeywording/FaceKeywordingView.swift | 2098 | GatherUI | 移动 |
| Settings/SettingsView.swift | 1756 | GatherUI | 移动 |
| Sources/GatherApp/Dashboard/DashboardView.swift | 923 | GatherUI | 移动 |
| Sources/GatherApp/Dashboard/DashboardViewModel.swift | 740 | GatherUI | 移动 |
| Sources/GatherApp/Gallery/GalleryView.swift | 1362 | GatherUI | 移动 |
| Sources/GatherApp/Gallery/GalleryViewModel.swift | 876 | GatherUI | 移动 |
| Sources/GatherApp/Gallery/JustifiedLayout.swift | 134 | GatherUI | 移动 |
| Sources/GatherApp/GatherApp.swift | 343 | GatherApp | 保持原位（删 bootstrap :91-121） |
| Sources/GatherApp/Host/CaptureOneBridge.swift | 375 | GatherHost | 移动 |
| Sources/GatherApp/Host/CommandRouter.swift | 51 | — | 删除（Cut 1 / CL-01） |
| Sources/GatherApp/Host/FaceKwWritebackBridge.swift | 152 | GatherHost | 移动 |
| Sources/GatherApp/Host/GatherAppCommands.swift | 55 | GatherHost | 移动 |
| Sources/GatherApp/Host/GatherAppDelegate.swift | 553 | GatherHost | 移动 |
| Sources/GatherApp/Host/SessionCommandRouter.swift | 3258 | — | 删除（Cut 1 / CL-01） |
| Sources/GatherApp/Host/SidecarXMPProvider.swift | 912 | GatherHost | 移动 |
| Sources/GatherApp/Library/LibraryView.swift | 933 | GatherUI | 移动 |
| Sources/GatherApp/Library/LibraryViewModel.swift | 772 | GatherUI | 移动 |
| Sources/GatherApp/Persons/PersonsView.swift | 535 | GatherUI | 移动 |
| Sources/GatherApp/Persons/PersonsViewModel.swift | 200 | GatherUI | 移动 |
| Sources/GatherApp/RootView.swift | 1005 | GatherHost | 移动 |
| Sources/GatherApp/Similarity/SimilarityView.swift | 954 | GatherUI | 移动 |
| Sources/GatherApp/Similarity/SimilarityViewModel.swift | 1081 | GatherUI | 移动 |
| Sources/GatherApp/Support/C1StatusCapsule.swift | 287 | GatherUI | 移动 |
| Sources/GatherApp/Support/DateFormatting.swift | 78 | GatherUI | 移动 |
| Sources/GatherApp/Support/FaceClusterMontage.swift | 69 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherBadge.swift | 143 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherCommonViews.swift | 310 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherEventCenter.swift | 131 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherGlass.swift | 109 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherLocalization.swift | 437 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherTheme.swift | 189 | GatherUI | 移动 |
| Sources/GatherApp/Support/GatherToast.swift | 171 | GatherUI | 移动 |
| Sources/GatherApp/Support/JSONValueDecoding.swift | 26 | GatherUI | 移动 |
| Sources/GatherApp/Support/LoadPhase.swift | 13 | GatherUI | 移动 |
| Sources/GatherApp/Support/NativeCommandClient.swift | 77 | — | 删除（Cut 1 / CL-01） |
| Sources/GatherApp/Support/PhotoThumbnailView.swift | 766 | GatherUI | 移动 |
| Sources/GatherApp/Support/SessionTabBar.swift | 172 | GatherUI | 移动 |
| Sources/GatherApp/Support/SliderInputView.swift | 123 | GatherUI | 移动 |
| Sources/GatherApp/Support/ThumbnailDiskCache.swift | 144 | GatherUI | 移动 |
| Sources/GatherApp/Support/URLHelpers.swift | 17 | GatherUI | 移动 |
| Sources/GatherApp/Support/WritebackReportCard.swift | 81 | GatherUI | 移动 |

### 2.4 gather-core 测试（89 个）

| 源文件 | 行 | 测试 target | 处置 |
| --- | --- | --- | --- |
| Concurrent/BatchCursorTests.swift | 52 | GatherAnalysisTests | 移动 |
| Concurrent/BatchRunnerTests.swift | 169 | GatherAnalysisTests | 移动 |
| Database/DatabasePragmaTests.swift | 182 | GatherPersistenceTests | 移动 |
| Database/MigrationTests.swift | 556 | — | 删除（Cut 2 / CL-02） |
| Database/Repositories/AnalysisJobRepoTests.swift | 379 | GatherPersistenceTests | 移动 |
| Database/Repositories/AssetRepoTests.swift | 499 | GatherPersistenceTests | 移动 |
| Database/Repositories/CullingDecisionRepoTests.swift | 141 | GatherPersistenceTests | 移动 |
| Database/Repositories/CullingHistoryRepoTests.swift | 125 | GatherPersistenceTests | 移动 |
| Database/Repositories/FaceRepoTests.swift | 598 | GatherPersistenceTests | 移动 |
| Database/Repositories/MetadataCacheRepoTests.swift | 156 | GatherPersistenceTests | 移动 |
| Database/Repositories/MetadataKeywordOriginRepoTests.swift | 71 | GatherPersistenceTests | 移动 |
| Database/Repositories/MetadataOutboxRepoTests.swift | 517 | GatherPersistenceTests | 移动 |
| Database/Repositories/PersonRepoTests.swift | 391 | GatherPersistenceTests | 移动 |
| Database/Repositories/PhotoRepoTests.swift | 306 | GatherPersistenceTests | 移动 |
| Database/Repositories/RepositorySupportTests.swift | 47 | GatherPersistenceTests | 移动 |
| Database/Repositories/RepoTestSupport.swift | 103 | GatherTestSupport | 移动+改名（DatabaseTestSupport.swift） |
| Database/Repositories/SessionRepoTests.swift | 223 | GatherPersistenceTests | 移动 |
| Database/Repositories/SettingsRepoTests.swift | 58 | GatherPersistenceTests | 移动 |
| Database/Repositories/SimilarityResultRepoTests.swift | 168 | GatherPersistenceTests | 移动 |
| Database/Repositories/SmartAlbumRepoTests.swift | 164 | GatherPersistenceTests | 移动 |
| Database/Repositories/WritebackRepoTests.swift | 264 | GatherPersistenceTests | 移动 |
| Face/ClusteringImpactTests.swift | 670 | GatherAnalysisTests | 移动 |
| Face/FaceAlignmentTests.swift | 238 | GatherAnalysisTests | 移动 |
| Face/FaceClustererQualityRetryTests.swift | 212 | GatherAnalysisTests | 移动 |
| Face/FaceClusteringAccuracyTests.swift | 1287 | GatherAnalysisTests | 移动 |
| Face/FaceEmbeddingFingerprintTests.swift | 234 | GatherAnalysisTests | 移动 |
| Face/FaceEmbeddingModelTests.swift | 267 | GatherAnalysisTests | 移动 |
| Face/FaceIdentityArchitectureTests.swift | 208 | GatherAnalysisTests | 移动 |
| Face/FaceIncrementalClusterTests.swift | 485 | GatherAnalysisTests | 移动 |
| Face/FaceInferenceTests.swift | 153 | GatherAnalysisTests | 移动 |
| Face/FaceMarginDecisionTests.swift | 432 | GatherAnalysisTests | 移动 |
| Face/FaceMatcherMarginTests.swift | 155 | GatherAnalysisTests | 移动 |
| Face/FaceRealPhotoPipelineTests.swift | 90 | GatherAnalysisTests | 移动 |
| HelperMessageTests.swift | 38 | GatherProtocolTests | 移动 |
| Image/RAWDecoderTests.swift | 267 | GatherAnalysisTests | 移动 |
| IPC/HelperProtocolTests.swift | 270 | GatherAnalysisTests | 移动 |
| LoggerTests.swift | 57 | GatherProtocolTests | 移动 |
| Protocol/AssetsContractTests.swift | 117 | GatherProtocolTests | 移动 |
| Protocol/CullingContractTests.swift | 478 | GatherProtocolTests | 移动 |
| Protocol/DuplicateContractTests.swift | 158 | GatherProtocolTests | 移动 |
| Protocol/ErrorCodeContractTests.swift | 74 | GatherProtocolTests | 移动 |
| Protocol/ExportContractTests.swift | 235 | GatherProtocolTests | 移动 |
| Protocol/FaceContractTests.swift | 252 | GatherProtocolTests | 移动 |
| Protocol/FilterContractTests.swift | 253 | GatherProtocolTests | 移动 |
| Protocol/IndexerContractTests.swift | 48 | GatherProtocolTests | 移动 |
| Protocol/JobsContractTests.swift | 171 | GatherProtocolTests | 移动 |
| Protocol/MetadataContractTests.swift | 292 | GatherProtocolTests | 移动 |
| Protocol/NavigationContractTests.swift | 105 | GatherProtocolTests | 移动 |
| Protocol/PersonContractTests.swift | 156 | GatherProtocolTests | 移动 |
| Protocol/QualityContractTests.swift | 106 | GatherProtocolTests | 移动 |
| Protocol/SessionContractTests.swift | 309 | GatherProtocolTests | 移动 |
| Protocol/SimilarityContractTests.swift | 157 | GatherProtocolTests | 移动 |
| Protocol/TemplateContractTests.swift | 130 | GatherProtocolTests | 移动 |
| Protocol/WorkspaceContractTests.swift | 151 | GatherProtocolTests | 移动 |
| Reconciliation/ClustererReconciliationTests.swift | 136 | GatherAnalysisTests | 移动 |
| Reconciliation/ClusterReconciliationTests.swift | 120 | GatherAnalysisTests | 移动 |
| Reconciliation/DHashReconciliationTests.swift | 37 | GatherAnalysisTests | 移动 |
| Reconciliation/DimensionsReconciliationTests.swift | 55 | GatherAnalysisTests | 移动 |
| Reconciliation/Harness.swift | 30 | GatherAnalysisTests | 移动 |
| Reconciliation/MatcherReconciliationTests.swift | 212 | GatherAnalysisTests | 移动 |
| Reconciliation/VectorIndexReconciliationTests.swift | 321 | GatherAnalysisTests | 移动 |
| Services/CullingServiceTests.swift | 1924 | GatherDomainTests | 移动 |
| Services/DeepReviewAcceptanceTests.swift | 160 | GatherDomainTests | 移动 |
| Services/DuplicateServiceTests.swift | 935 | GatherDomainTests | 移动 |
| Services/ExportServiceTests.swift | 857 | GatherDomainTests | 移动 |
| Services/FaceKeywordingServiceTests.swift | 1549 | GatherDomainTests | 移动 |
| Services/FilterEngineTests.swift | 457 | GatherDomainTests | 移动 |
| Services/ImageMetadataProvidersTests.swift | 196 | GatherDomainTests | 移动 |
| Services/IndexerChecksumParityTests.swift | 27 | GatherDomainTests | 移动 |
| Services/IndexerServiceTests.swift | 1293 | GatherDomainTests | 移动 |
| Services/JobServiceTests.swift | 961 | GatherDomainTests | 移动 |
| Services/MetadataContractRulesTests.swift | 66 | GatherDomainTests | 移动 |
| Services/MetadataParallelBatchTests.swift | 126 | GatherDomainTests | 移动 |
| Services/MetadataServiceTests.swift | 191 | GatherDomainTests | 移动 |
| Services/MetadataSyncCoordinatorTests.swift | 707 | GatherDomainTests | 移动 |
| Services/MetadataWritebackStateMachineTests.swift | 495 | GatherDomainTests | 移动 |
| Services/NavigationServiceTests.swift | 271 | GatherDomainTests | 移动 |
| Services/PhotoAssetResolverTests.swift | 206 | GatherDomainTests | 移动 |
| Services/QualityServiceTests.swift | 545 | GatherDomainTests | 移动 |
| Services/ReviewAcceptanceTests.swift | 81 | GatherDomainTests | 移动 |
| Services/SessionServiceTests.swift | 362 | GatherDomainTests | 移动 |
| Services/SettingsNumberTests.swift | 31 | GatherDomainTests | 移动 |
| Services/SettingsServiceTests.swift | 154 | GatherDomainTests | 移动 |
| Services/SimilarityIncrementalServiceTests.swift | 272 | GatherDomainTests | 移动 |
| Services/SimilarityServiceTests.swift | 1002 | GatherDomainTests | 移动 |
| Services/TemplateServiceTests.swift | 191 | GatherDomainTests | 移动 |
| Services/WorkspaceStatusServiceTests.swift | 575 | GatherDomainTests | 移动 |
| Similarity/IncrementalClustererTests.swift | 398 | GatherAnalysisTests | 移动 |
| Support/AsyncGate.swift | 43 | GatherTestSupport | 移动 |

### 2.5 gather-app 测试（31 个）

| 源文件 | 行 | 归属 | 处置 |
| --- | --- | --- | --- |
| C1PreflightTests.swift | 83 | GatherAppTests / UI | 移动 |
| CommandSurfaceRuntimeTests.swift | 296 | — | 删除（Cut 1 / CL-01、CL-11） |
| CullingSyncFlowTests.swift | 162 | GatherAppTests / Host | 移动 |
| DashboardViewModelTests.swift | 646 | GatherAppTests / UI | 移动 |
| DeepModelAcceptanceTests.swift | 36 | GatherAppTests / UI | 移动 |
| ErrorLocalizationCoverageTests.swift | 98 | GatherAppTests / UI | 移动 |
| FaceKeywordingViewModelTests.swift | 425 | GatherAppTests / UI | 移动 |
| FaceReclusterConfirmTests.swift | 70 | GatherAppTests / UI | 移动 |
| GalleryViewModelTests.swift | 760 | GatherAppTests / UI | 移动 |
| GatherAppDelegateTests.swift | 137 | GatherAppTests / Host | 移动 |
| GlobalInfraTests.swift | 294 | GatherAppTests / UI | 移动 |
| InboxItemsTests.swift | 137 | GatherAppTests / UI | 移动 |
| IndexHeaderCopyTests.swift | 248 | GatherAppTests / UI | 移动 |
| JustifiedLayoutTests.swift | 178 | GatherAppTests / UI | 移动 |
| LayoutBudgetTests.swift | 304 | GatherAppTests / Host | 移动 |
| LibraryViewModelTests.swift | 738 | GatherAppTests / UI | 移动 |
| NativeCommandClientTests.swift | 223 | — | 删除（Cut 1 / CL-01、CL-11） |
| PersonsViewModelTests.swift | 142 | GatherAppTests / UI | 移动 |
| ReviewAcceptanceTests.swift | 134 | GatherAppTests / UI | 移动 |
| ReviewFixTests.swift | 888 | GatherAppTests / UI | 移动 |
| RootViewTests.swift | 93 | GatherAppTests / Host | 移动 |
| SettingsCatalogTests.swift | 53 | GatherAppTests / UI | 移动 |
| SettingsSaveSemanticsTests.swift | 215 | GatherAppTests / UI | 移动 |
| SidecarXMPProviderTests.swift | 335 | GatherAppTests / Host | 移动 |
| SimilarityViewModelTests.swift | 839 | GatherAppTests / UI | 移动 |
| Support/AppLanguageLock.swift | 34 | GatherAppTests / Support | 保持路径 |
| Support/AsyncGate.swift | 39 | GatherAppTests / Support | 保持路径 |
| Support/AsyncWait.swift | 44 | GatherAppTests / Support | 保持路径 |
| Support/LockedBox.swift | 31 | GatherAppTests / Support | 保持路径 |
| Support/StubCommandRouter.swift | 38 | — | 删除（Cut 1 / CL-01、CL-11） |
| WorkspaceStageMarksTests.swift | 54 | GatherAppTests / UI | 移动 |

### 2.6 四类处置统计

| 处置 | 文件数 | 明细 |
| --- | --- | --- |
| **保持原位** | 4（+2 清单） | 3 个可执行 `main.swift`；`GatherApp.swift`（删 `bootstrap()` 后只剩 `@main`+Scene，路径不变）。两个 `Package.swift` 原位重写，不计入 304 |
| **移动** | 292 | core 生产 135 + core 测试 88 + app 生产 41 + app 测试 28；其中 **移动+改名 3**：`Schema.swift→GatherSchema/SchemaV1.swift`、`ImageCache.swift→GatherPersistence/SHA256.swift`（CL-13）、`RepoTestSupport.swift→GatherTestSupport/DatabaseTestSupport.swift` |
| **新建** | 2 | `GatherProtocol/PhotoFileTypes.swift`（CL-17：`rawExtensions` 等 4 张表上移，解 E-01）；`GatherHost/AppServices.swift`（从 `GatherApp.bootstrap()` 抽出，解 E-08） |
| **删除** | 8（6,127 行） | Cut 1：`CommandRouter`(51)、`SessionCommandRouter`(3,258)、`NativeCommandClient`(77)、`CommandSurfaceRuntimeTests`(296)、`NativeCommandClientTests`(223)、`StubCommandRouter`(38)；Cut 2：`Migrations`(1,628)、`MigrationTests`(169) |

合计校验：292 + 4 + 8 = 304（= 304 个非清单文件）；再加 2 个 `Package.swift` = 306。

### 2.7 目标目录树（Cut 3 结束时）

```text
desktop/native/gather-core/
├── Package.swift                         # 重写（§4.1）
├── Sources/
│   ├── CSQLite/                          # 保持原位（module.modulemap / shim.h / placeholder.c）
│   ├── GatherProtocol/                   # 65 文件 / 7,346 行
│   │   ├── API/                          #   46：16 域协议 + Inputs/ Outputs/ Errors/ Core/
│   │   ├── DTO/                          #   18：原 Protocol/*.swift（Core、Culling、Face…）
│   │   ├── Logging/Logger.swift          #    1
│   │   └── PhotoFileTypes.swift          #    1（新建，CL-17）
│   ├── GatherSchema/SchemaV1.swift       #  1（原 Database/Schema.swift，Cut 2 改名）
│   ├── GatherPersistence/                # 20 文件 / 7,356 行
│   │   ├── Database/DB.swift
│   │   ├── Database/SHA256.swift         #   原 ImageCache.swift（CL-13 纯改名）
│   │   └── Database/Repositories/        #   18（含 RepositorySupport）
│   ├── GatherAnalysis/                   # 21 文件 / 6,102 行
│   │   ├── Face/  Image/  Concurrent/  Similarity/
│   │   ├── IPC/                          #    3（过渡，D-015）
│   │   └── Resources/FaceModels/         #    .copy 资源（§5.1）
│   ├── GatherDomain/Services/            # 28 文件 / 16,738 行
│   ├── GatherCoreHelper/main.swift       # 原位
│   ├── GatherCoreBenchmarks/main.swift   # 原位
│   └── GatherFaceBenchmarks/main.swift   # 原位
└── Tests/
    ├── GatherTestSupport/                # 2：DatabaseTestSupport.swift、AsyncGate.swift
    ├── GatherProtocolTests/              # 19
    ├── GatherPersistenceTests/           # 17
    ├── GatherAnalysisTests/              # 24
    └── GatherDomainTests/                # 26

desktop/native/gather-app/
├── Package.swift                         # 重写（§4.2）
├── Support/Info.plist                    # 从 Resources/ 移出（build.sh:37 同步）
└── Sources/
    ├── GatherUI/                         # 35 文件 / 22,201 行
    │   ├── Features/{Dashboard,Gallery,Library,Persons,Similarity}/
    │   ├── Features/{Culling,Settings,Export,Duplicates,FaceKeywording,ControlCenter}/
    │   ├── Support/                      #   18（原 Support 19 个 − NativeCommandClient）
    │   └── Resources/{en.lproj,zh-Hans.lproj}
    ├── GatherHost/                       #  7 文件（6 移动 + AppServices.swift 新建）
    │   ├── RootView.swift
    │   ├── AppServices.swift             #   新建：bootstrap + 服务装配
    │   ├── CaptureOneBridge.swift  FaceKwWritebackBridge.swift  SidecarXMPProvider.swift
    │   └── GatherAppDelegate.swift  GatherAppCommands.swift
    └── GatherApp/GatherApp.swift         # 仅 @main + Scene
```

---

## 3. 依赖边与越界点

今天所有 core 文件在同一个 target 内、app 只 import GatherCore，编译器看到的是一个平面命名空间——**下面这些边从未被检查过**。拆成 7 个 target 后它们第一次参与编译期判定，分三类：

- **A 类：拆分即失败**，必须在 Cut 3 先修（E-01…E-04）。
- **B 类：Cut 1 应已清除的 UI 越界**，Cut 3 是最后一道验收（E-05…E-08）。若 Cut 1 没清干净，UI target 根本编译不过。
- **C 类：现在合法、只需在 Package.swift 显式声明依赖**（E-09…E-12），以及**现在就干净、必须守住**的边（E-13…E-15）。

### 3.1 A 类：拆分即失败（必须先修）

| 编号 | 边 | 证据（file:line） | 拆分后的失败形态 | 修复动作 | 归属 |
| --- | --- | --- | --- | --- | --- |
| **E-01** | Analysis → Persistence | `Image/RAWDecoder.swift:193-195`：`if PhotoRepo.rawExtensions.contains(ext)` | `GatherAnalysis` 编译报 `cannot find 'PhotoRepo' in scope`；若给 Analysis 加 Persistence 依赖，则 Analysis 反向依赖 DB，拆分失去意义 | 新建 `GatherProtocol/PhotoFileTypes.swift`，把 `AssetRepo.rawExtensions`（`AssetRepo.swift:1190`）及同组 `bitmapExtensions`/`renderedExtensions`/`rawPairingExtensions` 上移；`AssetRepo`、`PhotoRepo`（`:163` 排序别名、`:176` `rawVariantSQL`）、`Services/PhotoAssets.swift:12`、`RAWDecoder` 改引用（CL-17） | 3a / Core-Analysis |
| **E-02** | Persistence → Domain（**真环**） | `Database/Repositories/AssetRepo.swift:387`：`verified = (try? IndexerService.sha256File(newPath)) == storedChecksum` | 全仓唯一一处 Persistence 调 Domain：`GatherPersistence` 无法 import `GatherDomain`，直接编译失败；若为它加依赖则 Persistence↔Domain 成环，SwiftPM 报 cyclic dependency | 把 `IndexerService.sha256File`（`IndexerService.swift:199`）的实现搬进 `GatherPersistence/SHA256.swift`（`ImageCache.swift` 改名后已有 `SHA256` 纯实现）；`IndexerService.sha256File` 保留为一行委托 | 3a / Core-Persistence |
| **E-03** | IPC 横跨 Protocol + Analysis | `IPC/HelperProtocol.swift:9` 构造 `SessionData`（Protocol）；`IPC/ImageCommands.swift:48/104/106` 调 `ImageDimensions`/`RAWDecoder`（Analysis） | 三种放法各有代价：① 放 `GatherProtocol` → Protocol 反向依赖 Analysis（失败）；② 放 `GatherAnalysis` → 合法，但 `gather-core-helper` 连带链接 CoreML/Vision；③ 另立 target → 超出 §1.1 的 target 清单 | **本次取 ②**：整个 `IPC/` → `GatherAnalysis`（过渡态，D-015 登记）。Cut 5 若 helper 保留，再拆 `GatherHelperWire`；`session:mock` 只为冒烟，删掉即可去掉 `SessionData` 依赖 | 3a / Core-Analysis |
| **E-04** | UI → Analysis | `Support/PhotoThumbnailView.swift:538/540/628`：`RAWDecoder.getPreview/getThumbnail/decodeRegion` | 若 UI 只 import Protocol：`cannot find 'RAWDecoder' in scope`（3 处）。这是缩略图**热路径**，不能简单改成跨 actor 的 API | 二选一，见 X-01：**(a) 允许 `GatherUI→GatherAnalysis`，白名单只放 `RAWDecoder`/`ImageDimensions`**（推荐，与 `scripts/check-layering.sh` 现有规则一致——它只禁 Persistence/Domain）；(b) 在 Protocol 定义 `ImageCodec` 协议、Host 实现，代价是每次解码跨 target + async（与 CL-07 的 ThumbnailLoader 目标冲突） | 3b / App-UI |

> E-02 的严重性被低估过：它不是"依赖方向不美观"，而是**当前代码里唯一的双向边候选**。Cut 2 的 Repo 重写必须顺带修掉，否则 Cut 3 一定卡住。

### 3.2 B 类：UI 越界（Cut 1 清除，Cut 3 验收为 0）

| 编号 | 边 | 证据 | 影响 | 修复动作 | 归属 |
| --- | --- | --- | --- | --- | --- |
| **E-05** | UI → Domain（9 文件持有 Service 类型） | `Dashboard/DashboardViewModel.swift:76/78`（SessionService/JobService）、`Gallery/GalleryViewModel.swift`、`Library/LibraryViewModel.swift`、`Similarity/SimilarityViewModel.swift`（JobService）、`Culling/CullingView.swift`、`Duplicates/DuplicatesView.swift`、`Export/ExportView.swift`、`FaceKeywording/FaceKeywordingView.swift`、`Settings/SettingsView.swift` | `GatherUI` 无法编译（`SessionService` 在 `GatherDomain`） | Cut 1 已把 16 域协议放进 `GatherProtocol/API/`（1A 已落地）：UI 改持有 `any SessionAPI` 等协议，实现由 Host 注入 | 1D，3b 验收 |
| **E-06** | UI → Host（14 文件） | `CommandRouter`/`SessionCommandRouter`/`NativeCommandClient`：`GalleryViewModel`、`GalleryView`、`SimilarityViewModel`、`SimilarityView`、`LibraryViewModel`、`DashboardViewModel`、`PersonsViewModel`、`ExportView`、`CullingView`、`SettingsView`、`DuplicatesView`、`SessionControlView`、`FaceKeywordingView`、`C1StatusCapsule` | Host 在 UI 之上，UI 引用 Host 类型 = 反向依赖，编译失败 | Cut 1 删除三个命令面文件（CL-01），UI 改协议；`C1StatusCapsule.setRouter(_:)`（`:64`）与 `let router: CommandRouter`（`:125`）改 `any WorkspaceStatusAPI` | 1D |
| **E-07** | UI → Domain（单点） | `Support/GatherEventCenter.swift:94`：`func wire(jobService: JobService)` | `GatherEventCenter.shared` 被 11 个 UI 文件引用，无法用"挪到 Host"绕过 | 改 `wire(jobs: any JobAPI)` 或直接消费 `JobAPI` 的进度 `AsyncStream`（1A 的 `JobAPI.swift` 已声明） | 1D / 3b |
| **E-08** | App → Persistence + Domain + Host | `GatherApp.swift:91-121`：`bootstrap()` 里 `DBConnection(path:)`、`SettingsRepo`、`MigrationRunner`、`SessionCommandRouter.makeDefault(db:)` | `GatherApp` 只剩 `@main` 后没有编译单元承载这些调用 | 抽 `GatherHost/AppServices.swift`：`openDatabase()`+`makeServices()`+`makeAPIs()`；`GatherApp` 只保留 `@State private var services: AppServices?` 与 Scene | 3b / App-Host |

### 3.3 C 类：现在合法，只需显式声明依赖

| 编号 | 边 | 证据 | 处置 |
| --- | --- | --- | --- |
| E-09 | Domain → Persistence（**宽面**） | 15 个 `Services/*.swift` 共 128 处 `connection.prepare(`（cleanup-backlog §5 #9） | 合法边，但 Cut 2 应清零（`check-db-boundary.sh`）。Cut 3 只声明依赖，不改代码 |
| E-10 | Domain → Persistence（单点） | `Services/PhotoAssets.swift:12`：`AssetRepo.rawExtensions` | 随 E-01 改为 `PhotoFileTypes.rawExtensions` |
| E-11 | Persistence → Protocol | 18 个 Repo 返回 `SessionData`/`PhotoRow` 等 DTO | 合法；Package.swift 显式写 `GatherProtocol` |
| E-12 | 测试跨模块 | `@testable import GatherCore` 87 文件 / 89 处；`makeMigratedDB()` 被 **27 文件**跨 Database(9)/Face(3)/Services(15) 使用 | 见 §6.3：抽 `GatherTestSupport`，这是测试拆分的**唯一硬阻断点** |

### 3.4 现在就干净、必须守住（回归检查）

| 编号 | 检查 | 结论 | 证据 |
| --- | --- | --- | --- |
| E-13 | Protocol 是否引用 DB/Repo/Service | **0 处** | Protocol/ 下唯一命中是注释（`Culling.swift:111`） |
| E-14 | core 是否 import SwiftUI/AppKit | **0 处** | `grep -rn 'import SwiftUI\|import AppKit' gather-core/Sources` = 0 |
| E-15 | Analysis/Protocol 是否 import CSQLite | **0 处**；只有 `Database/DB.swift:8` 与 `Database/Migrations.swift:11` 两处 | 因此 **Domain→CSQLite 天然为 0**，CSQLite 只挂在 Persistence 下 |

> 任务里列的「Domain→CSQLite」在当前代码中**不存在**（E-15），真正存在的是 E-01（Analysis→Persistence）与 E-02（Persistence→Domain）。风险点与直觉相反：不是"算法层想用 DB"，而是"算法层想用一张扩展名表"+"Repo 想用一个哈希工具函数"。

### 3.5 每个 target 的 import 白名单（写进 check-layering.sh）

| target | 允许 import | 明确禁止 | 现状越界 |
| --- | --- | --- | --- |
| GatherProtocol | Foundation | 其余全部 | 0 |
| GatherSchema | Foundation | 其余全部 | 0 |
| GatherPersistence | GatherProtocol、GatherSchema、CSQLite、Foundation、Darwin/Glibc | GatherAnalysis、GatherDomain、SwiftUI | E-02（1 处） |
| GatherAnalysis | GatherProtocol、Foundation、Vision、CoreML、CoreImage、ImageIO、UniformTypeIdentifiers、CryptoKit、CoreText、CoreGraphics | GatherPersistence、GatherDomain、SwiftUI | E-01（1 处） |
| GatherDomain | GatherProtocol、GatherSchema、GatherPersistence、GatherAnalysis、Foundation、Darwin | SwiftUI、AppKit | 0（E-09 只是"合法但过宽"） |
| GatherUI | GatherProtocol、**GatherAnalysis（白名单符号）**、SwiftUI、AppKit、Foundation、Combine、CoreGraphics | GatherPersistence、GatherDomain、GatherHost | E-05/06/07（Cut 1 清零） |
| GatherHost | 全部 core target + GatherUI + SwiftUI/AppKit + CoreML/Vision | —（组合根） | 0 |
| GatherApp | GatherHost、GatherUI、SwiftUI | 其余 | 0 |

### 3.6 修完后的边清单（Cut 3 之后应只剩这些）

```text
GatherPersistence → GatherProtocol, GatherSchema, CSQLite
GatherAnalysis    → GatherProtocol
GatherDomain      → GatherProtocol, GatherSchema, GatherPersistence, GatherAnalysis
GatherUI          → GatherProtocol, GatherAnalysis（仅 RAWDecoder/ImageDimensions）
GatherHost        → GatherUI, GatherDomain, GatherPersistence, GatherAnalysis, GatherProtocol
GatherApp         → GatherHost, GatherUI
GatherCoreHelper  → GatherProtocol, GatherAnalysis
Benchmarks ×2     → GatherProtocol, GatherAnalysis
```

---

## 4. Package.swift 草案

> 两个清单都**原位重写**（路径不变）。草案保留现有 CLT SwiftTesting 探测、Swift 6 语言模式、Liquid Glass linker flags；新增的只有 target 划分。

### 4.1 desktop/native/gather-core/Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription
import Foundation

let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

// —— 保留现状：CLT-only 环境下的 SwiftTesting 路径探测（逐 testTarget 复用）——
#if os(macOS)
private let cltFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
private let needsCLTSearchPaths =
    FileManager.default.fileExists(atPath: "\(cltFrameworksPath)/SwiftTesting.framework")
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
let testSwiftSettings: [SwiftSetting] = needsCLTSearchPaths ? [.unsafeFlags(["-F", cltFrameworksPath])] : []
let testLinkerSettings: [LinkerSetting] = needsCLTSearchPaths ? [
    .unsafeFlags([
        "-Xlinker", "-F", "-Xlinker", cltFrameworksPath,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworksPath,
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    ]),
] : []
#else
let testSwiftSettings: [SwiftSetting] = []
let testLinkerSettings: [LinkerSetting] = []
#endif

let package = Package(
    name: "gather-core",
    platforms: [.macOS(.v14)],
    products: [
        // 5 个库产品：gather-app 按需选，不再有 GatherCore umbrella
        .library(name: "GatherProtocol",    targets: ["GatherProtocol"]),
        .library(name: "GatherSchema",      targets: ["GatherSchema"]),
        .library(name: "GatherPersistence", targets: ["GatherPersistence"]),
        .library(name: "GatherAnalysis",    targets: ["GatherAnalysis"]),
        .library(name: "GatherDomain",      targets: ["GatherDomain"]),
        .executable(name: "gather-core-helper",     targets: ["GatherCoreHelper"]),
        .executable(name: "gather-core-benchmarks", targets: ["GatherCoreBenchmarks"]),
        .executable(name: "gather-face-benchmarks", targets: ["GatherFaceBenchmarks"]),
    ],
    targets: [
        .target(name: "CSQLite"),                                   // 保持原位（C shim）

        .target(name: "GatherProtocol",
                path: "Sources/GatherProtocol",
                swiftSettings: swift6Settings),

        .target(name: "GatherSchema",
                path: "Sources/GatherSchema",
                swiftSettings: swift6Settings),

        .target(name: "GatherPersistence",
                dependencies: ["GatherProtocol", "GatherSchema", "CSQLite"],
                path: "Sources/GatherPersistence",
                swiftSettings: swift6Settings),

        .target(name: "GatherAnalysis",
                dependencies: ["GatherProtocol"],
                path: "Sources/GatherAnalysis",
                resources: [.copy("Resources/FaceModels")],          // §5.1
                swiftSettings: swift6Settings),

        .target(name: "GatherDomain",
                dependencies: ["GatherProtocol", "GatherSchema", "GatherPersistence", "GatherAnalysis"],
                path: "Sources/GatherDomain",
                swiftSettings: swift6Settings),

        .executableTarget(name: "GatherCoreHelper",
                dependencies: ["GatherProtocol", "GatherAnalysis"],
                path: "Sources/GatherCoreHelper",
                swiftSettings: swift6Settings),

        .executableTarget(name: "GatherCoreBenchmarks",
                dependencies: ["GatherProtocol", "GatherAnalysis"],
                path: "Sources/GatherCoreBenchmarks",
                exclude: ["README.md"],
                swiftSettings: swift6Settings),

        .executableTarget(name: "GatherFaceBenchmarks",
                dependencies: ["GatherProtocol", "GatherAnalysis"],
                path: "Sources/GatherFaceBenchmarks",
                swiftSettings: swift6Settings),

        // 测试专用库：跨 target 的 fixture（makeTestDatabase 等），非产品
        .target(name: "GatherTestSupport",
                dependencies: ["GatherProtocol", "GatherSchema", "GatherPersistence", "CSQLite"],
                path: "Tests/GatherTestSupport",
                swiftSettings: swift6Settings),

        .testTarget(name: "GatherProtocolTests",
                dependencies: ["GatherProtocol", "GatherTestSupport"],
                path: "Tests/GatherProtocolTests",
                swiftSettings: testSwiftSettings + swift6Settings,
                linkerSettings: testLinkerSettings),

        .testTarget(name: "GatherPersistenceTests",
                dependencies: ["GatherPersistence", "GatherProtocol", "GatherSchema",
                               "CSQLite", "GatherTestSupport"],
                path: "Tests/GatherPersistenceTests",
                swiftSettings: testSwiftSettings + swift6Settings,
                linkerSettings: testLinkerSettings),

        .testTarget(name: "GatherAnalysisTests",
                dependencies: ["GatherAnalysis", "GatherProtocol", "GatherPersistence",
                               "GatherTestSupport"],
                path: "Tests/GatherAnalysisTests",
                swiftSettings: testSwiftSettings + swift6Settings,
                linkerSettings: testLinkerSettings),

        .testTarget(name: "GatherDomainTests",
                dependencies: ["GatherDomain", "GatherPersistence", "GatherAnalysis",
                               "GatherProtocol", "GatherTestSupport"],
                path: "Tests/GatherDomainTests",
                swiftSettings: testSwiftSettings + swift6Settings,
                linkerSettings: testLinkerSettings),
    ]
)
```

### 4.2 desktop/native/gather-app/Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription
import Foundation

let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let macOSDeploymentTarget = "14.0"
// —— macOSSDKVersion / designSDKVersion / liquidGlassLinkerSettings 保持原样 ——

let package = Package(
    name: "gather-app",
    defaultLocalization: "zh-Hans",              // 必须保留：lproj 处理依赖它
    platforms: [.macOS(.v14)],
    products: [.executable(name: "gather-app", targets: ["GatherApp"])],
    dependencies: [.package(path: "../gather-core")],
    targets: [
        .target(
            name: "GatherUI",
            dependencies: [
                .product(name: "GatherProtocol", package: "gather-core"),
                .product(name: "GatherAnalysis", package: "gather-core"),   // 仅 RAWDecoder/ImageDimensions（X-01）
            ],
            path: "Sources/GatherUI",
            resources: [.process("Resources")],                            // en.lproj / zh-Hans.lproj
            swiftSettings: swift6Settings
        ),
        .target(
            name: "GatherHost",
            dependencies: [
                "GatherUI",
                .product(name: "GatherDomain",      package: "gather-core"),
                .product(name: "GatherPersistence", package: "gather-core"),
                .product(name: "GatherAnalysis",    package: "gather-core"),
                .product(name: "GatherProtocol",    package: "gather-core"),
            ],
            path: "Sources/GatherHost",
            swiftSettings: swift6Settings
        ),
        .executableTarget(
            name: "GatherApp",
            dependencies: ["GatherHost", "GatherUI"],
            path: "Sources/GatherApp",
            swiftSettings: swift6Settings,
            linkerSettings: liquidGlassLinkerSettings      // 只挂在可执行上
        ),
        .testTarget(
            name: "GatherAppTests",
            dependencies: [
                "GatherUI", "GatherHost",
                .product(name: "GatherProtocol", package: "gather-core"),
                .product(name: "GatherAnalysis", package: "gather-core"),
            ],
            path: "Tests/GatherAppTests",
            swiftSettings: swift6Settings
        ),
    ]
)
```

### 4.3 target 属性表

| target | 类型 | path | 依赖 | 资源 | 过渡/最终 |
| --- | --- | --- | --- | --- | --- |
| GatherProtocol | library | Sources/GatherProtocol | — | — | 最终 |
| GatherSchema | library | Sources/GatherSchema | — | — | 最终（D-014） |
| GatherPersistence | library | Sources/GatherPersistence | Protocol, Schema, CSQLite | — | 最终 |
| GatherAnalysis | library | Sources/GatherAnalysis | Protocol | .copy("Resources/FaceModels") | 最终（IPC 过渡） |
| GatherDomain | library | Sources/GatherDomain | Protocol, Schema, Persistence, Analysis | — | 最终 |
| GatherUI | library | Sources/GatherUI | Protocol, Analysis | .process("Resources") | 最终 |
| GatherHost | library | Sources/GatherHost | UI + 4 core | — | 最终（RootView 过渡） |
| GatherApp | executable | Sources/GatherApp | Host, UI | — | 最终 |
| CSQLite | C target | Sources/CSQLite | — | — | 最终 |
| GatherCoreHelper | executable | 原位 | Protocol, Analysis | — | **过渡** |
| GatherCoreBenchmarks / GatherFaceBenchmarks | executable | 原位 | Protocol, Analysis | — | 最终（工具） |
| GatherTestSupport | library（非产品） | Tests/GatherTestSupport | Protocol, Schema, Persistence, CSQLite | — | 最终（测试基建） |
| 4 个 core 测试 target | testTarget | Tests/⟨Name⟩ | 见 §4.1 | — | 最终 |

### 4.4 构建标志：--explicit-target-dependency-import-check error

该标志是 **SwiftPM 命令行选项**（swift build --help / swift test --help 均可见，取值 none|warn|error；本机 Swift 6.4 已验证存在），**不能写进 Package.swift**，必须注入三条链路：

| 链路 | 位置 | 命令 |
| --- | --- | --- |
| 本地/CI 构建 | build.sh:20-21 | swift build --package-path "$CORE_PACKAGE" -c "$CONFIGURATION" --explicit-target-dependency-import-check error（app 同理） |
| CI 测试 | .github/workflows/ci.yml:45,47,65 | swift test --package-path … --explicit-target-dependency-import-check error |
| CI 构建 | ci.yml:79,81 | 同 build 命令 |
| 门禁脚本 | scripts/check-layering.sh | 不负责该标志，只做 import 文本检查（双保险） |

> 建议同时保留仓库既有约定 --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch；但**不要**把 --disable-sandbox 写进 build.sh——发布构建不需要。

### 4.5 GatherCore product 消失的影响面（import 风暴量化）

| 位置 | 文件数 | import 行数 | 改法 |
| --- | --- | --- | --- |
| gather-app/Sources/** + 6 功能目录 | 34（45 个生产文件中 34 个 import 了 core） | 34 | GatherUI 用 GatherProtocol(+Analysis)；GatherHost 用 4 个 |
| gather-app/Tests/** | 27（其中 17 个另有 plain import） | 44（27 处 `@testable` + 17 处 plain） | `@testable import GatherApp` → `GatherUI`(19) / `GatherHost`(5)；plain 的 `import GatherCore` → `GatherProtocol`(+Analysis) |
| gather-core/Tests/** | 87 | 89（`ReviewAcceptanceTests.swift` 有 3 处） | `@testable import GatherCore` → 对应模块的 `@testable import` |
| core 可执行 ×3 | 3 | 3 | → GatherProtocol + GatherAnalysis |
| **合计（当前树）** | **151 文件** | **170 行** | 文件数 < 行数：17 个 app 测试文件同时有 `@testable` 与 plain 两条 import；4 个文件（`MigrationTests`、`CommandSurfaceRuntimeTests`、`NativeCommandClientTests`、`StubCommandRouter`）在 Cut 1/2 删除 |
| **合计（Cut 1/2 之后）** | **147 文件** | **163 行** | 纯机械替换；建议一次 codemod + 编译驱动修复 |

---

## 5. 资源归属

### 5.1 FaceModels → GatherAnalysis（唯一模型资源）

| 项 | 现状 | Cut 3 后 |
| --- | --- | --- |
| 路径 | `gather-core/Sources/GatherCore/Resources/FaceModels/`（`SFace.mlpackage/`、`manifest.json`、`native_ramp_reference.json`、`LICENSE.txt`） | `gather-core/Sources/GatherAnalysis/Resources/FaceModels/`（**内容不动**） |
| 声明 | `Package.swift:52` `.copy("Resources/FaceModels")` | 同样一行，挪到 `GatherAnalysis` target |
| 代码查找 | `Face/EmbeddingModel.swift:554`：`Bundle.module.url(forResource: "SFace", withExtension: "mlpackage", subdirectory: "FaceModels")` | **代码不改**：`Face/` 整体进 Analysis，`Bundle.module` 自动指向新 bundle，`subdirectory:` 仍是 `FaceModels`（因为用 `.copy` 保留了子目录） |
| Bundle 名 | `gather-core_GatherCore.bundle` | **`gather-core_GatherAnalysis.bundle`** |
| 测试读取 | `FaceIdentityArchitectureTests.swift:201-203` 通过 `FaceEmbeddingModelFactory.bundledModelURL` 拿模型，再读同目录的 `native_ramp_reference.json` | 不变：测试走生产 API，不自己拼路径（**这是拆资源安全的唯一原因**；若测试直接用 `Bundle.module` 会失败，因为 test target 没有资源） |

> 结论：FaceModels 迁移**只需改 `.copy` 的归属 + build.sh 的 bundle 名**，生产代码 0 行改动。这是 Cut 3 里收益/风险比最高的一步。

### 5.2 lproj → GatherUI（本地化）

| 项 | 现状 | Cut 3 后 |
| --- | --- | --- |
| 路径 | `gather-app/Resources/{en.lproj,zh-Hans.lproj,Info.plist}` | `gather-app/Sources/GatherUI/Resources/{en.lproj,zh-Hans.lproj}`（Info.plist 移出，见 5.3） |
| 声明 | `Package.swift:89-91` `.process("Resources")`，`exclude: ["Tests", "Resources/Info.plist"]` | `GatherUI` 的 `.process("Resources")`；`exclude` 只剩 `["Tests"]`（或整体删除，因为 path 已不是 "."） |
| 代码查找 | `Support/GatherLocalization.swift:51`：`Bundle.module.url(forResource: language, withExtension: "lproj")` | **代码不改**：`Support/` 进 GatherUI |
| Bundle 名 | `gather-app_GatherApp.bundle` | **`gather-app_GatherUI.bundle`** |
| 键规模 | en 1,478 行 / 1,406 键；zh-Hans 12 行（最小表） | 不变（CL-20 的删键在 Cut 5/6） |
| 主 bundle 复制 | `build.sh:54-56`：把 SPM bundle 里的 `*.lproj` 再复制到 `Gather.app/Contents/Resources/`（N08：系统菜单本地化） | 逻辑不变，变量名改后仍命中；`Info.plist` 的 `CFBundleLocalizations`（en/zh-Hans）不变 |

### 5.3 Info.plist

- 从 `gather-app/Resources/Info.plist` 移到 `gather-app/Support/Info.plist`（**不能**让它随 `.process("Resources")` 进 SPM resource bundle：那会改变 app bundle 结构，且 `Contents/Info.plist` 才是真正生效的那份）。
- `build.sh:37`：`cp "$APP_PACKAGE/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"` → `cp "$APP_PACKAGE/Support/Info.plist" …`。

### 5.4 Bundle.module 名称变化与 build.sh 的对应（行级）

| build.sh 行 | 现状 | Cut 3 后 |
| --- | --- | --- |
| 20-21 | `swift build --package-path … -c "$CONFIGURATION"` | 追加 `--explicit-target-dependency-import-check error`（§4.4） |
| 37 | `cp "$APP_PACKAGE/Resources/Info.plist"` | `cp "$APP_PACKAGE/Support/Info.plist"` |
| 41 | `RESOURCE_BUNDLE="$BIN_DIR/gather-app_GatherApp.bundle"` | `gather-app_GatherUI.bundle`（或 glob，见下） |
| 42 | `CORE_RESOURCE_BUNDLE="$BIN_DIR/gather-core_GatherCore.bundle"` | `gather-core_GatherAnalysis.bundle`（或 glob） |
| 43-46 | assert `FaceModels/SFace.mlpackage` 存在（两种布局都查） | **不变**（bundle 内相对路径不变，只换 bundle 前缀） |
| 47 | `cp -R "$CORE_RESOURCE_BUNDLE" …/Resources/` | 不变 |
| 48-56 | `cp -R "$RESOURCE_BUNDLE"` + 复制 `*.lproj` 到主 bundle | 不变（变量改了即可） |
| 新增 | — | `assert en.lproj/Localizable.strings 存在`；bundle 找不到时硬失败而不是 warning |

**glob 化（§7.1 要求"不写死名字"）**：

```bash
find_bundle() {   # $1 = 包名前缀；输出唯一命中的 bundle 目录
  local hits
  hits=$(find "$BIN_DIR" -maxdepth 1 -type d -name "$1_*.bundle" | sort)
  local n; n=$(printf '%s\n' "$hits" | grep -c . || true)
  if [ "$n" -ne 1 ]; then
    echo "expected exactly 1 bundle matching $1_*.bundle, got $n" >&2; return 1
  fi
  printf '%s\n' "$hits"
}
RESOURCE_BUNDLE=$(find_bundle gather-app)          # gather-app_GatherUI.bundle
CORE_RESOURCE_BUNDLE=$(find_bundle gather-core)    # gather-core_GatherAnalysis.bundle
```

同时把 `build.sh:58` 的 `warning: SPM resource bundle not found` 改成 `exit 1`——本地化缺失属于发布阻断，不是警告（与 §5.4 的 assert 语义一致）。

### 5.5 scripts/ 中被 Cut 3 打断的硬编码路径（必须同 PR 修）

| 脚本 | 行 | 现状 | Cut 3 后 | 动作 |
| --- | --- | --- | --- | --- |
| `check-cleanup-ratchet.sh` | 23-27, 93 | `$CORE_SRC/GatherCore/Services`；`APP_FEATURE_SRC` 六个根级目录；baseline 的 glob | `$CORE_SRC/GatherDomain/Services`；功能页已在 `Sources/GatherUI` 内；glob 改 `.../GatherDomain/Services/**` | 改变量 + 重新生成 `docs/cleanup-baseline.json`（须 owner 签字，D-006 口径） |
| `check-no-legacy.sh` | 73, 75 | `$CORE/Sources/GatherCore/Services` | `$CORE/Sources/GatherDomain/Services` | 改路径；规则不变 |
| `check-command-surface.sh` | 13-15, 54, 59 | Router 路径 + 六 UI 目录 | — | **已删除（Cut 1，CL-01/CL-11）**，Cut 3 不用管 |
| `check-docs.sh` | 20-21, 53-54 | `Database/Schema.swift`、`Database/Migrations.swift`、两个 Sources 目录 | `Sources/GatherSchema/SchemaV1.swift`；`Migrations` 检查删除；目录改 4 个 core target | 改路径 + 删迁移检查 |
| `check-layering.sh` | 全文 | 目录探测（未拆分时 exit 0） | 拆分后自动生效 | **小改**：增加 `GatherUI` 的 Analysis 白名单、`GatherSchema`/`GatherTestSupport` 的 GatherCore 检查 |
| `check-duplicate-symbols.sh` / `check-test-catalog.sh` | — | 未见硬编码路径 | Tests 目录结构变化 | PR 内复跑确认 |
| `.github/workflows/ci.yml` | 45, 47, 65, 79, 81 | 包路径不变 | 包路径不变 | 只加 `--explicit-target-dependency-import-check error` |

### 5.6 资源验收命令

```bash
BIN=$(swift build --package-path desktop/native/gather-app -c release --show-bin-path)
ls -d "$BIN"/gather-*.bundle
ls "$BIN/gather-core_GatherAnalysis.bundle"/FaceModels/SFace.mlpackage "$BIN/gather-core_GatherAnalysis.bundle"/FaceModels/native_ramp_reference.json
ls "$BIN/gather-app_GatherUI.bundle"/*.lproj/Localizable.strings
./desktop/native/build.sh
ls release/Gather.app/Contents/Resources/ | grep -E 'bundle|lproj'
```

---

## 6. 测试 target 归属

### 6.1 两种方案对比

| 方案 | 做法 | 文件移动 | 优点 | 缺点 |
| --- | --- | --- | --- | --- |
| **A 单 target** | 保留 `GatherCoreTests`，deps = 4 模块 + Schema + CSQLite | 0 | 改动最小；`Tests/Support` 与 `makeMigratedDB` 原样可用 | 不强制分层；任一模块改动重编全部 994 用例；target 边界形同虚设 |
| **B 拆 4 + Support（推荐）** | 4 个 test target 与生产模块同构 + `GatherTestSupport` | 88 文件 | 编译期强制分层；`swift test --filter` 可分包跑；Cut 4/5 的 UI/算法重构可只跑相关包 | 需抽 `GatherTestSupport`（§6.3）；每个 target 的`@testable` 只能覆盖一个模块 |

推荐 **B**：Cut 4/5 还要大改 UI 与算法，如果测试仍是一个 994 用例的巨型 target，"改了 Domain 却只跑 Domain 测试"这件事做不到。

### 6.2 测试 target 依赖表（方案 B）

| test target | 文件数 | 依赖 | 为什么需要多依赖 |
| --- | --- | --- | --- |
| `GatherProtocolTests` | 19 | GatherProtocol (+GatherTestSupport 可选) | DTO Codable 往返、`GatherErrorCode` 契约、`Logger`、`HelperMessage` 编解码 |
| `GatherPersistenceTests` | 17 | Persistence, Protocol, **Schema**, **CSQLite**, GatherTestSupport | `DatabasePragmaTests` 直接 `import CSQLite`（全测试唯一一处）；Repo 返回 Protocol DTO |
| `GatherAnalysisTests` | 24 | Analysis, Protocol, **Persistence**, GatherTestSupport | `FaceIdentityArchitectureTests`/`FaceMarginDecisionTests`/`FaceIncrementalClusterTests` 3 个文件建内存库跑端到端 |
| `GatherDomainTests` | 26 | Domain, Persistence, Analysis, Protocol, GatherTestSupport | `FilterEngine`/`Culling`/`Similarity`/`FaceKw` 等服务测试要同时建库与跑算法 |
| `GatherAppTests` | 28 | GatherUI, GatherHost, Protocol, Analysis | 见 §6.6 |

### 6.3 唯一硬阻断点：`makeMigratedDB()`

| 事实 | 证据 |
| --- | --- |
| 定义在 `Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift:8` | `func makeMigratedDB() throws -> DBConnection` |
| 被 **27 个测试文件**使用 | Database 9（含自身）、Face 3、Services 15 |
| 另有 `insertSession`/`insertPhoto` 被 **27 个文件**使用 | Database 12、Face 3、Services 12 |
| 拆分后这 27 个文件分属 3 个 test target | Persistence / Analysis / Domain —— **一个测试文件不能属于两个 target**，helper 无法原地共享 |

**处置（必须与拆分同 PR）**：

1. 新建 `gather-core/Tests/GatherTestSupport/DatabaseTestSupport.swift`（由 `RepoTestSupport.swift` 改名移入），函数改为 `package` 访问级（Swift 5.9+，同包内可见，不需要 `public`）：
   ```swift
   package func makeTestDatabase() throws -> DBConnection   // D-003：makeMigratedDB 改名
   package func insertSession(_ db: DBConnection, _ id: String) throws
   package func insertPhoto(…)
   ```
2. 内部实现从 `MigrationRunner().migrate(db)` 改为 `SchemaV1` 建库（Cut 2 已删除迁移链）。
3. `Tests/GatherCoreTests/Support/AsyncGate.swift` 一并移入（`package actor AsyncGate`），因为它只被 3 个 Domain 测试使用，放 Support 里可避免复制第三份。
4. 27 个调用点只改函数名，断言不动（D-003 明确"保留 57 个业务用例"）。

> **不需要**放宽 Persistence 的访问级：已核实 `DBConnection.prepare`（`DB.swift:180`）、`DBStatement.run/get`（`:324`/`:340`）都是 `public`，GatherTestSupport 可以不 `@testable` 就建 fixture。

### 6.4 `@testable import` 改造清单（数量 + 示例）

| 测试 target / 位置 | 文件 | 其中需改 `@testable` | 改后 import | 示例 |
| --- | --- | --- | --- | --- |
| `GatherProtocolTests` | 19 | 19 | `@testable import GatherProtocol` | `Protocol/CullingContractTests.swift` |
| `GatherPersistenceTests` | 17 | 17 | `@testable import GatherPersistence` | `Database/Repositories/AssetRepoTests.swift:8` |
| `GatherAnalysisTests` | 24 | 23 | `@testable import GatherAnalysis` | `Face/FaceClusteringAccuracyTests.swift`（`Reconciliation/Harness.swift` 本就无 import） |
| `GatherDomainTests` | 26 | 26 | `@testable import GatherDomain` | `Services/CullingServiceTests.swift` |
| `GatherTestSupport` | 2 | 1 | 无（`package` 符号用普通 `import`） | `DatabaseTestSupport.swift`；`AsyncGate.swift` 本就无 import |
| **core 小计** | **88** | **86** | — | 当前树另有 `MigrationTests` 1 个（Cut 2 删除） |
| `GatherAppTests`（UI 组） | 19 | 19 | `@testable import GatherUI` | `GalleryViewModelTests.swift` |
| `GatherAppTests`（Host 组） | 5 | 5 | `@testable import GatherHost` | `GatherAppDelegateTests.swift` |
| `GatherAppTests`（Support 组） | 4 | 0 | 不改 | `Support/AsyncGate.swift` |
| **app 小计** | **28** | **24** | — | 当前树另有 3 个命令面测试（Cut 1 删除） |
| app 测试的 plain `import GatherCore` | 17 | 17（行） | `import GatherProtocol`（+ Analysis） | `SidecarXMPProviderTests.swift`（Cut 1 后 14） |
| core 可执行 | 3 | 3 | `import GatherProtocol` + `import GatherAnalysis` | `GatherCoreBenchmarks/main.swift` |

汇总：**core 测试 86 个文件必改**（另有 1 个支持文件只改函数名、2 个文件无需改），**app 测试 24 个文件必改**（4 个 Support 不改）。与 §4.5 的 **147 文件 / 163 行**同口径（§4.5 另含 34 个 app 生产文件与 3 个可执行）。

> 注意 `@testable` 的语义边界：`@testable import GatherUI` 能看见 UI 的 internal，但**看不见**它依赖的 Analysis 的 internal。跨模块访问内部符号（如 `GatherTestSupport` 的 `package` 函数）一律用普通 `import`，不要叠 `@testable`。

### 6.5 若坚持方案 A：`GatherCoreTests` 需要哪些依赖

```swift
.testTarget(
    name: "GatherCoreTests",
    dependencies: [
        "GatherProtocol", "GatherSchema", "GatherPersistence",
        "GatherAnalysis", "GatherDomain", "CSQLite",
    ],
    path: "Tests/GatherCoreTests",
    exclude: ["Reconciliation/Fixtures", "Reconciliation/README.md"],
    swiftSettings: testSwiftSettings + swift6Settings,
    linkerSettings: testLinkerSettings
)
```

- 6 个依赖缺一不可：`CSQLite` 供 `DatabasePragmaTests`；`Schema` 供 Cut 2 的 SchemaV1 断言；其余为被测模块。
- 此时 `GatherTestSupport` **不需要**（helper 留在 `Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift`）。
- 代价见 §6.1：不强制分层、全量重编。

### 6.6 `GatherAppTests`：单 target，内部分三组

| 组 | 文件数 | 依赖 | 成员 |
| --- | --- | --- | --- |
| UI 组 | 19 | `@testable import GatherUI` | C1Preflight、DashboardViewModel、DeepModelAcceptance、ErrorLocalizationCoverage、FaceKeywordingViewModel、FaceReclusterConfirm、GalleryViewModel、GlobalInfra、InboxItems、IndexHeaderCopy、JustifiedLayout、LibraryViewModel、PersonsViewModel、ReviewAcceptance、ReviewFix、SettingsCatalog、SettingsSaveSemantics、SimilarityViewModel、WorkspaceStageMarks |
| Host 组 | 5 | `@testable import GatherHost` | GatherAppDelegate、SidecarXMPProvider、CullingSyncFlow、LayoutBudget、RootView |
| Support 组 | 4 | 无 core/app import | AppLanguageLock、AsyncGate、AsyncWait、LockedBox |

target 声明：

```swift
.testTarget(
    name: "GatherAppTests",
    dependencies: [
        "GatherUI", "GatherHost",
        .product(name: "GatherProtocol", package: "gather-core"),
        .product(name: "GatherAnalysis", package: "gather-core"),
    ],
    path: "Tests/GatherAppTests",
    swiftSettings: swift6Settings
)
```

> Host 组的划分取决于 `RootView` 归属（D-016）：本文件按"RootView 留在 Host"给出，因此 `RootViewTests`/`LayoutBudgetTests` 归 Host 组。若最终把 RootView 拆进 UI，这两个文件退化为 UI 组，**target 数量不变**。

---

## 7. 迁移顺序：一次拆分 vs 两步

### 7.1 一次拆分（7 个 target 一个 PR）

| 步骤 | 内容 | 风险 |
| --- | --- | --- |
| 1 | 建 7 个目录，`git mv` 292 个文件 | 中：git 重命名检测（内容不变时应能识别） |
| 2 | 重写两个 `Package.swift` | 低 |
| 3 | 修 E-01/E-02/E-03/E-04 | **高**：E-02 是环，E-01 是算法层反依赖持久层 |
| 4 | 168 个文件改 import | 中：机械但量大 |
| 5 | 拆 4 个测试 target + GatherTestSupport + 114 个 `@testable` | **高**：`makeMigratedDB` 跨 3 个 target |
| 6 | 资源/Info.plist/build.sh/CI/scripts | 中：bundle 改名后运行时才暴露 |

- 优点：资源只改一次、无中间态、Cut 3 一次到位。
- 缺点：失败模式叠加——第 5 步卡住时，第 4 步已让主干变红，**无法判断是"import 漏改"还是"target 依赖写错"**；一个 300+ 文件的 PR 里 review 边界几乎不可能。
- 结论：**不推荐**，除非人力充足且愿意接受 2-3 天全红主干。

### 7.2 两步（推荐）：3a core → 3b app

理由：core 拆分是**依赖方向的真实变化**（E-01/E-02/E-03），app 拆分是**搬家 + 组合根抽离**（E-04/E-05~E-08 大部分已由 Cut 1 解决）。两类失败模式不同，混在一起排错成本翻倍。资源也天然分成两半：FaceModels 跟 3a，lproj 跟 3b，各自只改一次 bundle 名。

**3a（core，约 5.5 人日）**

1. 建 `Sources/{GatherProtocol,GatherSchema,GatherPersistence,GatherAnalysis,GatherDomain}`，`git mv` 135 个生产文件。
2. 修 **E-01**（`PhotoFileTypes`）、**E-02**（`SHA256` 下沉）、**E-03**（IPC → Analysis）。
3. 重写 core `Package.swift`（§4.1）。
4. FaceModels 随 `GatherAnalysis/Resources/` 移动；`swift build --target GatherAnalysis` + 一次模型加载冒烟。
5. 抽 `GatherTestSupport`（**先做这一步，再拆测试目录**），然后拆 4 个 test target、改 86 个 `@testable`（当前树 87，含 Cut 2 将删除的 `MigrationTests`）。
6. app 只改 import（34 个生产 + 17 个测试），`GatherApp` 仍是单 target、依赖 5 个 core product。
7. core 先开 `--explicit-target-dependency-import-check error`；app 先 `warn`，3b 再开 `error`。

**退出条件**：5 个库 target + 3 个可执行编译；4 个 test target 全绿（88 文件）；app 构建 + 启动；`gather-core_GatherAnalysis.bundle` 含 FaceModels。

**3b（app，约 4 人日）**

1. 抽 `GatherHost/AppServices.swift`（E-08），`GatherApp.swift` 只留 `@main` + Scene。
2. 建 `Sources/GatherUI`、`Sources/GatherHost`，`git mv` 35 + 6 个文件（含 6 个根级功能目录 → `GatherUI/Features/`）。
3. `Resources/{en,zh-Hans}.lproj` → `GatherUI/Resources`；`Info.plist` → `gather-app/Support/Info.plist`。
4. 重写 app `Package.swift`；`build.sh` 4 行 + glob + 硬断言；CI 加 flag；5 个 scripts 路径（§5.5）。
5. `GatherAppTests` 只改 import/path（27 文件）。
6. 全量开 `error`。

**退出条件**：`swift build --target GatherUI` 单独通过；UI 0 处 import Persistence/Domain；`gather-app_GatherUI.bundle` 断言通过；app 启动 + 手工冒烟（打开会话 → 图库 → 导出面板）。

### 7.3 文件所有权与冲突面

| owner | 独占文件 | 冲突方 | 冲突说明 |
| --- | --- | --- | --- |
| **Core-Protocol** | `API/` 46 + `Protocol/` 18 + `Logging` 1 + 新建 `PhotoFileTypes.swift` | Core-Analysis、Core-Persistence | E-01 的 4 张扩展名表由本 owner 定义，另两个 owner 只改引用 |
| **Core-Persistence** | `Database/` 22（−Migrations） + `SchemaV1.swift` | Core-Schema、Core-Domain | `Schema.swift` 归 Schema；`AssetRepo` 的 E-02 调用由本 owner 改 |
| **Core-Analysis** | `Face/` 11 + `Image/` 2 + `Concurrent/` 2 + `Similarity/` 3 + `IPC/` 3 + `Resources/FaceModels` | Core-Protocol、App-UI | 只允许 import Protocol；`RAWDecoder` 被 UI 调用 |
| **Core-Domain** | `Services/` 28 | Core-Persistence | `PhotoAssets.swift:12` 改引用 `PhotoFileTypes` |
| **Core-Tests** | 88 个测试 + `GatherTestSupport/` | 三个 Core owner | fixture 单点，**必须最先完成** |
| **App-UI** | 35 文件 + `Resources/*.lproj` | App-Host、Core-Analysis | 与 Host 之间有 `RootView` 传参；与 Analysis 之间有 `RAWDecoder`（X-01） |
| **App-Host** | 6 文件 + 新建 `AppServices.swift` | App-UI、Core-Domain | `GatherEventCenter` 的 `wire()` 签名由双方约定 |
| **Build** | 2 个 `Package.swift` + `build.sh` + `ci.yml` + 5 个 `scripts/*.sh` | 所有 owner | **Package.swift 必须单人所有**，否则依赖声明会互相覆盖 |

**冲突面结论**：真正的并发瓶颈只有两处——`Package.swift`（2 文件，串行）与 `GatherTestSupport`（1 目录，串行）。其余目录天然按 target 切开，可 3 人并行。

### 7.4 排期（人日，2 人并行）

| 阶段 | 内容 | 人日 |
| --- | --- | --- |
| 3a-1 | 目录迁移 + core Package.swift + 修 E-01/E-02/E-03 | 2.0 |
| 3a-2 | FaceModels 资源 + Analysis/Domain 编译收口 | 1.0 |
| 3a-3 | GatherTestSupport + 4 个 test target + 87 个 @testable | 1.5 |
| 3a-4 | app import 改造 + 两包联调 + 开 flag | 1.0 |
| 3b-1 | AppServices 抽离 + UI/Host 目录迁移 | 1.5 |
| 3b-2 | 资源/Info.plist/build.sh/CI/scripts | 1.5 |
| 3b-3 | GatherAppTests + 全量 error + 手工冒烟 | 1.0 |
| **合计** | | **9.5**（≈ 设计文档 §9 给的 1-2 周） |

### 7.5 回滚策略

- 3a / 3b 各自单 PR：`git revert` 即回到上一态；**不要**为了"可回滚"保留 umbrella target——那会让 Cut 3 的目标（编译期边界）永远达不到。
- 拆目录用 `git mv`（不是先复制再删），否则 `git log --follow` 断掉，Cut 5/6 的 blame 失效。
- build.sh 的改动放在 3b 末尾单独一个 commit，便于出问题时只回滚打包逻辑。

---

## 8. 验收

### 8.1 命令与判据

| # | 验收项 | 命令 | 期望 |
| --- | --- | --- | --- |
| A-1 | 7 个模块 target 编译（core 侧） | `cd desktop/native/gather-core && swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error` | exit 0；产出 5 个库（Protocol/Schema/Persistence/Analysis/Domain）+ 3 个可执行；配合 A-4/A-5 即「7 个模块 target（5 core 库 + UI + Host）全部编译」 |
| A-2 | 每个 target 单独编译 | `swift build --target GatherProtocol`（依次 5 个） | 全部 exit 0；`GatherAnalysis` 单独通过即证明无 DB 依赖 |
| A-3 | 4 个 core 测试 target | `swift test --explicit-target-dependency-import-check error`（core） | 4 个 test target 全绿；测试数按 D-009 口径记录 |
| A-4 | app 全量 | `cd ../gather-app && swift build --explicit-target-dependency-import-check error` | exit 0 |
| A-5 | **UI 独立构建** | `swift build --package-path desktop/native/gather-app --target GatherUI --explicit-target-dependency-import-check error` | exit 0（这是"UI 不再依赖 Host/Domain"的机器证明） |
| A-6 | UI 不 import Persistence/Domain | `grep -rnE '^\s*import\s+(GatherPersistence\|GatherDomain)' desktop/native/gather-app/Sources/GatherUI` | 0 行 |
| A-7 | Analysis 无 DB 符号 | `grep -rnE 'DBConnection\|prepare\(\|import CSQLite\|\bRepo\b' desktop/native/gather-core/Sources/GatherAnalysis` | 0 行（注释不计） |
| A-8 | 无 umbrella | `grep -rn 'import GatherCore' desktop/native`；`grep -n 'name: "GatherCore"' **/Package.swift` | 0 行（两条命中都必须为空） |
| A-9 | 分层门禁 | `./scripts/check-layering.sh` | 不再是 `baseline mode`；4 段 `ok` + `check-layering: OK` |
| A-10 | 资源断言 | `./desktop/native/build.sh` | 通过；`release/Gather.app/Contents/Resources/gather-core_GatherAnalysis.bundle/FaceModels/SFace.mlpackage` 存在；`gather-app_GatherUI.bundle/en.lproj/Localizable.strings` 存在 |
| A-11 | Preview 可构建 | Xcode 打开 `desktop/native/gather-app/Package.swift`，选 `GatherUI` 的任一 `#Preview` | 渲染成功（**人工验收项，无 GUI 自动化**；Cut 3 阶段要求"能渲染 1 个"，Cut 4 才要求 ≥12） |
| A-12 | 启动冒烟 | `open release/Gather.app` | 冷启动到工作台；打开一个会话 → 图库缩略图 → 切页 → 导出面板（验证 bundle 与 API 注入） |
| A-13 | 清理账 | — | 删除 8 文件 / 6,127 行；新建 2 文件；生产 182、测试 116 |

### 8.2 门禁接线（与 §4.4 对齐）

| 门禁 | 位置 | 判据 |
| --- | --- | --- |
| `--explicit-target-dependency-import-check error` | build.sh、ci.yml（4 处） | 任一越界 import → 编译失败 |
| `check-layering.sh` | 本地 + CI | UI 不得 import Persistence/Domain；Analysis 不得 import Persistence；Domain 不得 import SwiftUI；无 GatherCore |
| `check-db-boundary.sh`（Cut 2 产出） | CI | `GatherDomain/Services` 的 `prepare(` = 0 |
| `check-schema-v1.sh`（Cut 2 产出） | CI | SchemaV1 与 `GatherSchema` 常量一致 |
| `check-cleanup-ratchet.sh` | CI | 路径改到 `GatherDomain/Services`；baseline 只降不升 |

### 8.3 Cut 3 结束后的数字基线（供 Cut 4 对比）

| 指标 | 值 |
| --- | --- |
| target 数 | 7（Protocol / Schema / Persistence / Analysis / Domain / UI / Host）+ App + CSQLite + 3 工具 = **12**；另有 1 个测试专用 `GatherTestSupport` 与 5 个 test target |
| 生产文件 | 182 |
| 测试文件 | 116（core 88 + app 28） |
| 测试 target | 5 |
| 删除 | 8 文件 / 6,127 行 |

---

## 9. 风险

| ID | 风险 | 触发条件 | 影响 | 概率 | 检测手段 | 对策 |
| --- | --- | --- | --- | --- | --- | --- |
| **R-01** | 移动文件导致 build.sh / CI 路径失效 | 目录搬家（292 文件） | 发布构建红、CI 红 | 高 | `./desktop/native/build.sh` + CI 全绿 | build.sh 用 glob 找 bundle（§5.4）；scripts 路径表（§5.5）与拆分同 PR；CI 只依赖包路径（不变） |
| **R-02** | 资源 bundle 改名后运行时找不到模型/本地化 | `.copy`/`.process` 跟错 target，或 build.sh 变量没改 | 启动后无人脸模型（硬崩）或界面空白文案 | 中 | A-10 + 模型加载冒烟 | `Bundle.module` 全部留在同一 target 的文件里（本方案已满足：模型只在 Face，本地化只在 UI）；build.sh 由 warning 改 `exit 1` |
| **R-03** | 测试 `@testable` 断裂 | 114 个文件（core 87 + app 27）的 import 未按模块改 | 4 个 test target 全红 | 高（如果不用脚本） | `swift test` 逐 target | 按目录批量替换（§6.4 表），一次编译驱动修复；**先抽 GatherTestSupport 再动目录** |
| **R-04** | GatherCore 伞被禁用后的 import 风暴 | 删掉 `GatherCore` product | 151 文件 / 170 行 import 需改（Cut 1/2 后 147 文件 / 163 行）；漏改表现为 `no such module` 刷屏 | 高 | A-8 的 grep = 0 + 两包编译 | 3a 只改 core+app 的 import（不改逻辑），3b 再动目录；用 codemod 而不是手改 |
| **R-05** | E-02 环未修 | 直接给 Persistence 加 Domain 依赖"图省事" | SwiftPM `cyclic dependency`，整个包无法 `describe` | 中 | `swift package describe` / 图论检查 | 把 `sha256File` 下沉到 Persistence 的 `SHA256.swift`；review 时禁止 Persistence 出现 `Service` 字样 |
| **R-06** | E-01 用错误方式"修复" | 给 Analysis 加 Persistence 依赖 | 拆分名存实亡，Analysis 反向依赖 DB，Cut 5 的算法测试无法脱离 SQLite | 中 | `check-layering.sh`：Analysis 禁 import Persistence | 扩展名表上移 Protocol（`PhotoFileTypes`），**不允许** Analysis→Persistence |
| **R-07** | X-01（UI→Analysis）悬而未决 | 3b 开始前没定 | UI 无法定稿，缩略图改造返工 | 中 | 决策记录 | 3b 动工前把 D-013 定稿（推荐：允许，白名单 2 个符号） |
| **R-08** | `makeMigratedDB` 抽取顺序错 | 先拆测试目录、后抽 Support | 3 个 test target 同时缺 fixture，红灯无法定位 | 中 | — | 固定顺序：Support → 目录 → import（§7.2 3a-3） |
| **R-09** | ratchet 基线漂移 | `check-cleanup-ratchet.sh` 路径变、`cleanup-baseline.json` 未重生成 | 门禁误报，团队开始忽略门禁 | 高 | 跑一次门禁 | 路径与 baseline 在 3a 的同一 PR 更新，PR 描述附旧/新计数 |
| **R-10** | Preview 失效 | GatherUI 依赖 Analysis，Preview 触发 CoreML 模型加载 | Preview 白屏/报错，Cut 4 的"12 个 Preview"无法达标 | 中 | 手工 A-11 | Preview 用 mock API 且不触发模型加载；模型只在`FaceKw`路径实例化（single-flight 已在 §6 计划） |

**最大风险（单一）**：不是代码，而是 **R-03 + R-08 的组合**——`makeMigratedDB` 横跨 Persistence/Analysis/Domain 三个测试 target，若没有先抽 `GatherTestSupport`，4 个测试 target 会同时红，且错误信息全部指向"符号找不到"，与 import 改造错误混在一起，定位成本远高于其他项。

---

## 10. 待决事项（需在 Cut 3 动工前签字）

| ID | 事项 | 选项 | 建议 |
| --- | --- | --- | --- |
| **D-013** | `GatherUI` 是否允许依赖 `GatherAnalysis`（X-01 / E-04） | (a) 允许，白名单 `RAWDecoder`/`ImageDimensions`；(b) 仅 Protocol + `ImageCodec` 协议 | **(a)**：缩略图是同步热路径；与 `check-layering.sh` 现有规则一致（它只禁 Persistence/Domain）；(b) 会把 CL-07 的 ThumbnailLoader 复杂度翻倍 |
| **D-014** | `GatherSchema` 是否独立成 target | (a) 独立（本文件方案）；(b) 并回 `GatherPersistence` | **(a)**：`check-schema-v1.sh` 需要一份不链接 SQLite 的 DDL 来源；代价是多 1 个 0 依赖薄 target。若 Cut 2 最终把 SchemaV1 放在 Persistence 内，则本 target 取消 |
| **D-015** | `GatherCoreHelper` / `IPC` 的去留 | (a) 保留（IPC 暂放 Analysis）；(b) Cut 5 删除 helper 与 IPC | **(a) 本 Cut**；(b) 待确认是否仍有外部工具调用 `gather-core-helper`（线协议无版本号，删除前需公告） |
| **D-016** | `RootView` 归属 | (a) 留 `GatherHost`（本文件方案）；(b) Cut 4 拆分后进 `GatherUI/Shell` | **(a) 在 Cut 3**：避免在拆分 PR 里重写 1,005 行的组合逻辑；(b) 留到 Cut 4，届时 `RootViewTests`/`LayoutBudgetTests` 改归 UI 组 |
| **D-017** | core 测试 target 拆 4（方案 B）还是单 target（方案 A） | A / B | **B**：Cut 4/5 需要"只跑受影响模块"的能力；代价是 88 文件移动 + Support 抽取（本就必需） |

---

## 附录 A：复现命令

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather

# 1) 全量文件与行数（排除 .build）
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print | wc -l
find desktop/native -path '*/.build' -prune -o -name '*.swift' -print0 \
  | xargs -0 wc -l | tail -1

# 2) 按目录计数（本文件 §2 的表就是这一条生成的）
for d in gather-core/Sources/GatherCore gather-core/Sources/GatherCore/API \
         gather-core/Tests/GatherCoreTests gather-app/Sources gather-app/Tests; do
  printf '%-42s %s\n' "$d" "$(find desktop/native/$d -name '*.swift' | wc -l)"
done

# 3) 越界证据
grep -rn 'PhotoRepo.rawExtensions' desktop/native/gather-core/Sources        # E-01
grep -rn 'IndexerService.sha256File' desktop/native/gather-core/Sources      # E-02
grep -rn 'RAWDecoder\.' desktop/native/gather-app/Sources                   # E-04
grep -rn 'import CSQLite' desktop/native/gather-core/Sources                 # E-15
grep -rn 'import SwiftUI\|import AppKit' desktop/native/gather-core/Sources  # E-14

# 4) import 改造面
grep -rl '@testable import GatherCore' desktop/native/gather-core/Tests | wc -l   # 87
grep -rl '@testable import GatherApp'  desktop/native/gather-app/Tests  | wc -l   # 27
grep -rl 'import GatherCore' desktop/native/gather-app/Sources | wc -l            # 34

# 5) 资源与 bundle 名
grep -n 'BUNDLE\|bundle' desktop/native/build.sh | sed -n '1,12p'
grep -rn 'Bundle.module' desktop/native/gather-core/Sources desktop/native/gather-app/Sources

# 6) 门禁现状（未拆分时 exit 0 的基线模式）
./scripts/check-layering.sh
```

## 附录 B：证据索引（越界点 → file:line）

| 编号 | 位置 | 片段 |
| --- | --- | --- |
| E-01 | `gather-core/Sources/GatherCore/Image/RAWDecoder.swift:193-195` | `if PhotoRepo.rawExtensions.contains(ext) {` |
| E-01 | `gather-core/Sources/GatherCore/Database/Repositories/AssetRepo.swift:1190-1197` | `static let rawExtensions: Set<String>`（4 张扩展名表的定义处） |
| E-01 | `gather-core/Sources/GatherCore/Database/Repositories/PhotoRepo.swift:163,176` | `public static let rawExtensions: [String] = AssetRepo.rawExtensions.sorted()` / `rawVariantSQL(alias:)` |
| E-01 | `gather-core/Sources/GatherCore/Services/PhotoAssets.swift:12` | `public static let rawExtensions: Set<String> = AssetRepo.rawExtensions` |
| E-02 | `gather-core/Sources/GatherCore/Database/Repositories/AssetRepo.swift:387` | `verified = (try? IndexerService.sha256File(newPath)) == storedChecksum` |
| E-02 | `gather-core/Sources/GatherCore/Services/IndexerService.swift:199` | `public static func sha256File(_ filePath: String) throws -> String` |
| E-03 | `gather-core/Sources/GatherCore/IPC/HelperProtocol.swift:9` | `public static let mockSession = SessionData(…)` |
| E-03 | `gather-core/Sources/GatherCore/IPC/ImageCommands.swift:48,104,106` | `ImageDimensions.read` / `RAWDecoder.getThumbnail` / `RAWDecoder.getPreview` |
| E-04 | `gather-app/Sources/GatherApp/Support/PhotoThumbnailView.swift:538,540,628` | `RAWDecoder.getPreview/getThumbnail/decodeRegion` |
| E-05 | `gather-app/Sources/GatherApp/Dashboard/DashboardViewModel.swift:76,78` | `private let sessionService: SessionService` / `jobService: JobService` |
| E-06 | `gather-app/Sources/GatherApp/RootView.swift:350,383` | `let router: SessionCommandRouter` |
| E-06 | `gather-app/Sources/GatherApp/Support/C1StatusCapsule.swift:64,125` | `func setRouter(_ router: CommandRouter)` / `let router: CommandRouter` |
| E-07 | `gather-app/Sources/GatherApp/Support/GatherEventCenter.swift:94` | `public func wire(jobService: JobService)` |
| E-08 | `gather-app/Sources/GatherApp/GatherApp.swift:110,119,121` | `DBConnection(path:)` / `MigrationRunner(...).migrate` / `SessionCommandRouter.makeDefault(db:)` |
| E-09 | `gather-core/Sources/GatherCore/Services/*.swift` 15 文件 128 处 | `connection.prepare(` |
| E-13 | `gather-core/Sources/GatherCore/Protocol/Culling.swift:111` | 唯一一条提到 `CullingDecisionRepo` 的注释 |
| E-15 | `gather-core/Sources/GatherCore/Database/DB.swift:8`、`Migrations.swift:11` | `import CSQLite`（全仓仅 2 处） |
| 资源 | `gather-core/Sources/GatherCore/Face/EmbeddingModel.swift:554` | `Bundle.module.url(forResource: "SFace", …, subdirectory: "FaceModels")` |
| 资源 | `gather-app/Sources/GatherApp/Support/GatherLocalization.swift:51` | `Bundle.module.url(forResource: language, withExtension: "lproj")` |
| 构建 | `desktop/native/build.sh:37,41,42,43,54` | Info.plist 路径 / 两个 bundle 名 / FaceModels 断言 / lproj 复制 |
| 测试 | `gather-core/Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift:8` | `func makeMigratedDB() throws -> DBConnection` |

---

*本文件为 Cut 3 的前置设计，不含任何代码改动。执行顺序、验收与风险见 §7-§9；需要产品/架构签字的 5 项见 §10。*
