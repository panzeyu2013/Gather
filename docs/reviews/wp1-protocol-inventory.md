# WP1 Protocol 瘦身盘点（HEAD 30f51f0）

> 快照：2026-10-22，HEAD `30f51f0`（工作区干净 + 分析文档未跟踪）。
> 用途：WP1 执行前候选清单 + 执行后复核；只读计数，不改源码。
> 路径约定：Protocol 清单相对 `desktop/native/gather-core/Sources/GatherProtocol/`；引用证据相对 `desktop/native/`（`gather-core/...` / `gather-app/...`）。

## 0. 结论（实测）

| 指标 | 执行前 | 执行后 |
| --- | ---: | ---: |
| Protocol 文件 / 行 | 68 / 7,598 | 68 / 6,325 |
| 顶层 public 类型 | **347**（270 struct / 59 enum / 18 protocol） | **251** |
| public 声明行 | **1,752** | **1,320** |
| 零引用类型 | **89**（942 行） | **0** |
| Router 信封类型 | **6**（Core.swift:158-315，158 行） | **0** |

判定口径：**零引用 = 生产代码 0 引用 + Protocol 内 0 引用（注释/字符串剥离、排除声明本身）**；Tests 单列、不作为存活依据（D-001：Router 时代的 JSON 契约测试可删）。因此 89 个类型全部「只被 ContractTests 引用」，删除时同步删/改写测试。

- 89 个零引用类型：942 行（含声明前 `// TS:` 注释），88 struct + 1 enum（`Response`，同时是 6 个 Router 信封之一）。
- 6 个 Router 信封共 158 行：`Response` 已在 89 内；另外 5 个因彼此引用而不在 89 的初始口径内。
- 二级死亡 2 个：`BindingData`（仅被 `FaceCluster.binding` 引用）、`MetadataMutationTarget`（仅被 `MetadataMutationRequest.target` 引用）；随上游删除后归零。
- 合计删除 **96 个顶层 public 类型**：89 + 5（其余信封）+ 2（二级死亡）。347 − 96 = **251**，满足 ≤260。

## 1. 方法

1. **声明提取**：`grep -E '^public (struct|enum|indirect enum|final class|class|protocol|actor) [A-Za-z0-9_]+'` 逐文件提取；嵌套类型不计入 347（`FaceIdentityPolicy.Decision` 是唯一嵌套 public enum，已计入 1,752 声明行、未计入 347 顶层类型）。
2. **生产引用**（299 文件）：`desktop/native/gather-core/Sources/{GatherPersistence,GatherAnalysis,GatherDomain}` + `desktop/native/gather-app/Sources`，按 ASCII 标识符全词匹配；注释与字符串剥离。
3. **Protocol 内部引用**（68 文件）：同口径全词匹配，排除声明行本身；用于区分「API 输入/输出仍在引用」与「只有声明」。
4. **测试引用**（166 文件）：单列 `test` 计数；只用于说明删除后哪些 ContractTests 需要同步处理，不作为「仍被使用」的证据。
5. **动态/反射复核**：全仓搜 `Mirror(`、`_typeByName`、`NSClassFromString`、`String(describing:)`、`type(of:)`。`String(describing:)` 仅出现在错误日志/错误消息路径，未指向 96 个被删类型；无反射注册、无 `NSClassFromString`、无按类型名查表的运行时代码。96 个类型在测试中的使用均为 `init` / `JSONEncoder` / `JSONDecoder` 的静态 Codable 往返，无动态派发。
6. **复算**：`./scripts/check-protocol-surface.sh`（新增）用同一口径复算 251 / 1,320 / 0 / 0，`--strict` exit 0；基线 `docs/protocol-surface-baseline.json`。

## 2. 347 个顶层 public 类型全量清单（HEAD 30f51f0）

`prod` = 生产引用数；`proto` = Protocol 内引用数；`test` = 测试引用数。`判定` 中 `DELETE zero` = 初始 89 零引用；`DELETE envelope` = 其余 Router 信封；`DELETE secondary` = 上游删除后归零；`KEEP` = 保留。

| # | 类型 | kind | HEAD 位置 | prod | proto | test | 判定 | 引用证据（首个） |
| ---: | --- | --- | --- | ---: | ---: | ---: | --- | --- |
| 1 | `AlbumAPI` | protocol | API/AlbumAPI.swift:15 | 5 | 0 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:36; …(+4) |
| 2 | `AssetAPI` | protocol | API/AssetAPI.swift:15 | 5 | 0 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:35; …(+4) |
| 3 | `ConfirmationSource` | enum | API/Core/Confirmed.swift:13 | 0 | 2 | 0 | KEEP | gather-core/Sources/GatherProtocol/API/Core/Confirmed.swift:24; …(+1) |
| 4 | `Confirmed` | struct | API/Core/Confirmed.swift:22 | 83 | 33 | 177 | KEEP | gather-core/Sources/GatherPersistence/Database/Repositories/FaceFeedbackRepo.swift:31; …(+82) |
| 5 | `PageRequest` | struct | API/Core/PageRequest.swift:15 | 0 | 13 | 0 | KEEP | gather-core/Sources/GatherProtocol/API/Core/PageRequest.swift:38; …(+12) |
| 6 | `PhotoPathPolicy` | protocol | API/Core/PhotoPathPolicy.swift:15 | 2 | 1 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:35; …(+1) |
| 7 | `CullingAPI` | protocol | API/CullingAPI.swift:19 | 36 | 0 | 9 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:39; …(+35) |
| 8 | `DuplicateAPI` | protocol | API/DuplicateAPI.swift:13 | 10 | 0 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:48; …(+9) |
| 9 | `GatherError` | struct | API/Errors/GatherError.swift:15 | 131 | 29 | 65 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:268; …(+130) |
| 10 | `ExportAPI` | protocol | API/ExportAPI.swift:15 | 10 | 0 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:54; …(+9) |
| 11 | `FaceAPI` | protocol | API/FaceAPI.swift:21 | 10 | 0 | 12 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:42; …(+9) |
| 12 | `AlbumPhotosQuery` | struct | API/Inputs/AlbumInputs.swift:15 | 2 | 1 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:55; …(+1) |
| 13 | `AlbumDeleteInput` | struct | API/Inputs/AlbumInputs.swift:39 | 2 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:51; …(+1) |
| 14 | `AssetCandidatesQuery` | struct | API/Inputs/AssetInputs.swift:15 | 1 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAssetAPI.swift:33 |
| 15 | `AssetCandidateReference` | struct | API/Inputs/AssetInputs.swift:33 | 3 | 2 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAssetAPI.swift:41; …(+2) |
| 16 | `AssetRelinkInput` | struct | API/Inputs/AssetInputs.swift:51 | 2 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAssetAPI.swift:49; …(+1) |
| 17 | `CullingPageQuery` | struct | API/Inputs/CullingInputs.swift:35 | 4 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:54; …(+3) |
| 18 | `CullingHistoryQuery` | struct | API/Inputs/CullingInputs.swift:85 | 4 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:67; …(+3) |
| 19 | `CullingApplyHistoryInput` | struct | API/Inputs/CullingInputs.swift:108 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:94; …(+2) |
| 20 | `CullingUpdateInput` | struct | API/Inputs/CullingInputs.swift:147 | 3 | 1 | 16 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:107; …(+2) |
| 21 | `CullingBatchUpdateInput` | struct | API/Inputs/CullingInputs.swift:177 | 3 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:120; …(+2) |
| 22 | `CullingDecideGroupInput` | struct | API/Inputs/CullingInputs.swift:207 | 3 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:130; …(+2) |
| 23 | `CullingResetInput` | struct | API/Inputs/CullingInputs.swift:239 | 3 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:142; …(+2) |
| 24 | `CullingWritebackInput` | struct | API/Inputs/CullingInputs.swift:262 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:154; …(+2) |
| 25 | `DuplicateScanInput` | struct | API/Inputs/DuplicateInputs.swift:13 | 3 | 1 | 10 | KEEP | gather-app/Sources/GatherHost/APIs/LiveDuplicateAPI.swift:56; …(+2) |
| 26 | `DuplicateResolveInput` | struct | API/Inputs/DuplicateInputs.swift:41 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveDuplicateAPI.swift:91; …(+2) |
| 27 | `DuplicateResolveMemberInput` | struct | API/Inputs/DuplicateInputs.swift:64 | 3 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveDuplicateAPI.swift:103; …(+2) |
| 28 | `ExportInput` | struct | API/Inputs/ExportInputs.swift:15 | 9 | 2 | 15 | KEEP | gather-app/Sources/GatherHost/APIs/LiveExportAPI.swift:55; …(+8) |
| 29 | `ExportReportInput` | struct | API/Inputs/ExportInputs.swift:39 | 3 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LiveExportAPI.swift:137; …(+2) |
| 30 | `FaceBindInput` | struct | API/Inputs/FaceInputs.swift:16 | 3 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:73; …(+2) |
| 31 | `FaceMergeInput` | struct | API/Inputs/FaceInputs.swift:45 | 3 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:84; …(+2) |
| 32 | `FaceRemoveMemberInput` | struct | API/Inputs/FaceInputs.swift:74 | 3 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:94; …(+2) |
| 33 | `FaceAnalyzeInput` | struct | API/Inputs/FaceInputs.swift:100 | 3 | 1 | 9 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:107; …(+2) |
| 34 | `FaceReclusterInput` | struct | API/Inputs/FaceInputs.swift:146 | 3 | 1 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:145; …(+2) |
| 35 | `FaceUnbindInput` | struct | API/Inputs/FaceInputs.swift:180 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:168; …(+2) |
| 36 | `FacePreviewInput` | struct | API/Inputs/FaceInputs.swift:203 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:179; …(+2) |
| 37 | `FaceWritebackInput` | struct | API/Inputs/FaceInputs.swift:226 | 4 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:189; …(+3) |
| 38 | `JobListFilter` | struct | API/Inputs/JobInputs.swift:59 | 12 | 1 | 11 | KEEP | gather-app/Sources/GatherHost/APIs/LiveJobAPI.swift:36; …(+11) |
| 39 | `ClearCompletedInput` | struct | API/Inputs/JobInputs.swift:77 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveJobAPI.swift:50; …(+2) |
| 40 | `MetadataGetInput` | struct | API/Inputs/MetadataInputs.swift:15 | 2 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:77; …(+1) |
| 41 | `MetadataSetInput` | struct | API/Inputs/MetadataInputs.swift:40 | 2 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:116; …(+1) |
| 42 | `MetadataBatchSetInput` | struct | API/Inputs/MetadataInputs.swift:63 | 2 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:123; …(+1) |
| 43 | `MetadataResolveConflictInput` | struct | API/Inputs/MetadataInputs.swift:86 | 3 | 1 | 10 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:133; …(+2) |
| 44 | `MetadataResolveOrphanInput` | struct | API/Inputs/MetadataInputs.swift:125 | 6 | 1 | 15 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:187; …(+5) |
| 45 | `PersonDeleteInput` | struct | API/Inputs/PersonInputs.swift:14 | 3 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:111; …(+2) |
| 46 | `PersonMergeInput` | struct | API/Inputs/PersonInputs.swift:32 | 3 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:117; …(+2) |
| 47 | `PersonRemovePhotoInput` | struct | API/Inputs/PersonInputs.swift:55 | 3 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:123; …(+2) |
| 48 | `PhotoPageQuery` | struct | API/Inputs/PhotoInputs.swift:16 | 3 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:68; …(+2) |
| 49 | `PhotoQuery` | struct | API/Inputs/PhotoInputs.swift:57 | 2 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:72; …(+1) |
| 50 | `PhotoSuggestionQuery` | struct | API/Inputs/PhotoInputs.swift:101 | 1 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:89 |
| 51 | `PhotoDimensionsInput` | struct | API/Inputs/PhotoInputs.swift:124 | 1 | 1 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:95 |
| 52 | `ThumbnailPrioritizeInput` | struct | API/Inputs/PhotoInputs.swift:145 | 1 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:123 |
| 53 | `ThumbnailPreloadInput` | struct | API/Inputs/PhotoInputs.swift:171 | 1 | 1 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:134 |
| 54 | `PreviewPreloadInput` | struct | API/Inputs/PhotoInputs.swift:200 | 1 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:152 |
| 55 | `QualityAnalyzeInput` | struct | API/Inputs/QualityInputs.swift:13 | 4 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveQualityAPI.swift:49; …(+3) |
| 56 | `SessionCreateInput` | struct | API/Inputs/SessionInputs.swift:20 | 10 | 1 | 9 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:62; …(+9) |
| 57 | `SessionDeleteInput` | struct | API/Inputs/SessionInputs.swift:67 | 8 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:70; …(+7) |
| 58 | `SessionAddPhotosInput` | struct | API/Inputs/SessionInputs.swift:91 | 3 | 1 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:74; …(+2) |
| 59 | `SessionReference` | struct | API/Inputs/SessionInputs.swift:119 | 18 | 6 | 37 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:165; …(+17) |
| 60 | `SettingsKey` | struct | API/Inputs/SettingsInputs.swift:14 | 4 | 5 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:37; …(+3) |
| 61 | `SettingsValue` | struct | API/Inputs/SettingsInputs.swift:28 | 0 | 4 | 1 | KEEP | gather-core/Sources/GatherProtocol/API/Inputs/SettingsInputs.swift:44; …(+3) |
| 62 | `SettingsSetInput` | struct | API/Inputs/SettingsInputs.swift:42 | 5 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:41; …(+4) |
| 63 | `InterfaceLanguage` | enum | API/Inputs/SettingsInputs.swift:70 | 3 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:58; …(+2) |
| 64 | `SimilarityResultQuery` | struct | API/Inputs/SimilarityInputs.swift:16 | 6 | 1 | 10 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSimilarityAPI.swift:64; …(+5) |
| 65 | `SimilarityAnalyzeInput` | struct | API/Inputs/SimilarityInputs.swift:42 | 6 | 2 | 15 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSimilarityAPI.swift:73; …(+5) |
| 66 | `SimilarityPreviewWritebackInput` | struct | API/Inputs/SimilarityInputs.swift:83 | 3 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSimilarityAPI.swift:146; …(+2) |
| 67 | `SimilarityWritebackInput` | struct | API/Inputs/SimilarityInputs.swift:137 | 3 | 1 | 10 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSimilarityAPI.swift:194; …(+2) |
| 68 | `TemplateReference` | struct | API/Inputs/TemplateInputs.swift:14 | 1 | 1 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LiveTemplateAPI.swift:72 |
| 69 | `TemplateApplyInput` | struct | API/Inputs/TemplateInputs.swift:32 | 1 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LiveTemplateAPI.swift:78 |
| 70 | `JobAPI` | protocol | API/JobAPI.swift:14 | 24 | 0 | 17 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:32; …(+23) |
| 71 | `MetadataAPI` | protocol | API/MetadataAPI.swift:15 | 13 | 0 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:57; …(+12) |
| 72 | `NavigationAPI` | protocol | API/NavigationAPI.swift:14 | 8 | 0 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:37; …(+7) |
| 73 | `GlobalPhotoPage` | struct | API/Outputs/AlbumOutputs.swift:10 | 3 | 1 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:55; …(+2) |
| 74 | `CullingSyncStatus` | struct | API/Outputs/CullingOutputs.swift:10 | 4 | 1 | 20 | KEEP | gather-app/Sources/GatherHost/APIs/LiveCullingAPI.swift:83; …(+3) |
| 75 | `FaceModelsStatus` | struct | API/Outputs/FaceOutputs.swift:10 | 4 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:219; …(+3) |
| 76 | `FaceAnalysisResult` | struct | API/Outputs/FaceOutputs.swift:24 | 11 | 1 | 14 | KEEP | gather-core/Sources/GatherDomain/Services/FaceKwService.swift:531; …(+10) |
| 77 | `FaceClusterBinding` | struct | API/Outputs/FaceOutputs.swift:37 | 2 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/FaceKwService.swift:1016; …(+1) |
| 78 | `FaceClusterData` | struct | API/Outputs/FaceOutputs.swift:51 | 30 | 1 | 17 | KEEP | gather-core/Sources/GatherDomain/Services/FaceKwService.swift:1001; …(+29) |
| 79 | `FkwUnbindResult` | struct | API/Outputs/FaceOutputs.swift:97 | 4 | 1 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/FaceKwService.swift:1112; …(+3) |
| 80 | `JobEvent` | enum | API/Outputs/JobOutputs.swift:14 | 1 | 2 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LiveJobAPI.swift:63 |
| 81 | `JobHandle` | struct | API/Outputs/JobOutputs.swift:19 | 5 | 2 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LiveJobAPI.swift:55; …(+4) |
| 82 | `PersonCreateResult` | struct | API/Outputs/PersonOutputs.swift:11 | 3 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:87; …(+2) |
| 83 | `PersonPhotosResult` | struct | API/Outputs/PersonOutputs.swift:19 | 4 | 1 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:131; …(+3) |
| 84 | `PhotoPage` | struct | API/Outputs/PhotoOutputs.swift:14 | 3 | 1 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:68; …(+2) |
| 85 | `PhotoSearchResult` | struct | API/Outputs/PhotoOutputs.swift:25 | 2 | 1 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:72; …(+1) |
| 86 | `PhotoDimensions` | struct | API/Outputs/PhotoOutputs.swift:35 | 4 | 1 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/LivePhotoAPI.swift:95; …(+3) |
| 87 | `SessionCreateResult` | struct | API/Outputs/SessionOutputs.swift:10 | 9 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:62; …(+8) |
| 88 | `SimilarityResult` | struct | API/Outputs/SimilarityOutputs.swift:12 | 15 | 2 | 20 | KEEP | gather-core/Sources/GatherDomain/Services/SimilarityService.swift:570; …(+14) |
| 89 | `PersonAPI` | protocol | API/PersonAPI.swift:15 | 10 | 0 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:60; …(+9) |
| 90 | `PhotoAPI` | protocol | API/PhotoAPI.swift:18 | 7 | 0 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:34; …(+6) |
| 91 | `QualityAPI` | protocol | API/QualityAPI.swift:13 | 12 | 0 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:51; …(+11) |
| 92 | `SessionAPI` | protocol | API/SessionAPI.swift:18 | 22 | 0 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:31; …(+21) |
| 93 | `SettingsAPI` | protocol | API/SettingsAPI.swift:15 | 14 | 0 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:33; …(+13) |
| 94 | `SimilarityAPI` | protocol | API/SimilarityAPI.swift:20 | 10 | 0 | 9 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:45; …(+9) |
| 95 | `TemplateAPI` | protocol | API/TemplateAPI.swift:13 | 5 | 0 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/AppServices.swift:63; …(+4) |
| 96 | `LogLevel` | enum | Logging/Logger.swift:3 | 0 | 4 | 1 | KEEP | gather-core/Sources/GatherProtocol/Logging/Logger.swift:9; …(+3) |
| 97 | `GatherLogger` | enum | Logging/Logger.swift:14 | 65 | 0 | 16 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:794; …(+64) |
| 98 | `AssetCandidateListParams` | struct | Protocol/Assets.swift:9 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:14; …(+2) |
| 99 | `AssetCandidateMutationParams` | struct | Protocol/Assets.swift:18 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:28; …(+1) |
| 100 | `AssetLinkCandidateStatus` | enum | Protocol/Assets.swift:29 | 2 | 2 | 1 | KEEP | gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo.swift:272; …(+1) |
| 101 | `AssetLinkCandidateData` | struct | Protocol/Assets.swift:36 | 16 | 1 | 6 | KEEP | gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo.swift:224; …(+15) |
| 102 | `AssetVolumeData` | struct | Protocol/Assets.swift:68 | 14 | 1 | 2 | KEEP | gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo.swift:278; …(+13) |
| 103 | `AssetRelinkRootParams` | struct | Protocol/Assets.swift:83 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:99; …(+1) |
| 104 | `C1PreflightStatus` | struct | Protocol/C1.swift:18 | 6 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/CaptureOneBridge.swift:103; …(+5) |
| 105 | `CaptureOneBridgeError` | enum | Protocol/C1.swift:46 | 14 | 1 | 4 | KEEP | gather-app/Sources/GatherHost/CaptureOneBridge.swift:88; …(+13) |
| 106 | `CaptureOneBridging` | protocol | Protocol/C1.swift:69 | 15 | 0 | 0 | KEEP | gather-app/Sources/GatherHost/AppBootstrap.swift:44; …(+14) |
| 107 | `SessionStatus` | enum | Protocol/Core.swift:16 | 1 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/SessionService.swift:236 |
| 108 | `AnalysisStatus` | enum | Protocol/Core.swift:24 | 1 | 2 | 0 | KEEP | gather-core/Sources/GatherDomain/Services/SessionService.swift:237 |
| 109 | `WritebackStatus` | enum | Protocol/Core.swift:32 | 2 | 2 | 0 | KEEP | gather-core/Sources/GatherPersistence/Database/Repositories/DeliverySummaryQuery.swift:43; …(+1) |
| 110 | `JSONValue` | enum | Protocol/Core.swift:42 | 172 | 37 | 32 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:517; …(+171) |
| 111 | `ResponseID` | enum | Protocol/Core.swift:160 | 0 | 6 | 2 | DELETE envelope | gather-core/Sources/GatherProtocol/Protocol/Core.swift:221; …(+5) |
| 112 | `ErrorDetail` | struct | Protocol/Core.swift:184 | 0 | 2 | 1 | DELETE envelope | gather-core/Sources/GatherProtocol/Protocol/Core.swift:199; …(+1) |
| 113 | `ResponseErrorBody` | enum | Protocol/Core.swift:197 | 0 | 3 | 0 | DELETE envelope | gather-core/Sources/GatherProtocol/Protocol/Core.swift:259; …(+2) |
| 114 | `ResponseOk` | struct | Protocol/Core.swift:220 | 0 | 3 | 3 | DELETE envelope | gather-core/Sources/GatherProtocol/Protocol/Core.swift:237; …(+2) |
| 115 | `ResponseErr` | struct | Protocol/Core.swift:256 | 0 | 3 | 4 | DELETE envelope | gather-core/Sources/GatherProtocol/Protocol/Core.swift:273; …(+2) |
| 116 | `Response` | enum | Protocol/Core.swift:292 | 0 | 0 | 2 | DELETE zero+env | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:218; …(+1) |
| 117 | `GatherErrorCode` | enum | Protocol/Core.swift:321 | 34 | 9 | 13 | KEEP | gather-core/Sources/GatherDomain/Services/DuplicateService.swift:65; …(+33) |
| 118 | `WritebackAttributes` | struct | Protocol/Core.swift:536 | 21 | 5 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1294; …(+20) |
| 119 | `WritebackOptions` | struct | Protocol/Core.swift:549 | 6 | 5 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:126; …(+5) |
| 120 | `WritebackPreview` | struct | Protocol/Core.swift:564 | 20 | 2 | 23 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:129; …(+19) |
| 121 | `WritebackDirtyField` | enum | Protocol/Core.swift:577 | 2 | 2 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift:325; …(+1) |
| 122 | `WritebackItemPreview` | struct | Protocol/Core.swift:584 | 7 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/WritebackService.swift:599; …(+6) |
| 123 | `WritebackItem` | struct | Protocol/Core.swift:605 | 48 | 10 | 51 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:130; …(+47) |
| 124 | `WritebackResult` | struct | Protocol/Core.swift:655 | 38 | 5 | 53 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:131; …(+37) |
| 125 | `CleanupResult` | struct | Protocol/Core.swift:684 | 17 | 3 | 25 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:135; …(+16) |
| 126 | `AddPhotoResult` | struct | Protocol/Core.swift:695 | 4 | 1 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:74; …(+3) |
| 127 | `PickState` | enum | Protocol/Culling.swift:15 | 11 | 8 | 5 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:2582; …(+10) |
| 128 | `CullingDecisionValue` | enum | Protocol/Culling.swift:24 | 6 | 6 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1046; …(+5) |
| 129 | `CullingDecisionSource` | enum | Protocol/Culling.swift:31 | 2 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:2566; …(+1) |
| 130 | `CaptureOneColorLabel` | enum | Protocol/Culling.swift:39 | 16 | 8 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:261; …(+15) |
| 131 | `CullingScope` | enum | Protocol/Culling.swift:51 | 7 | 5 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:368; …(+6) |
| 132 | `MetadataSyncStatus` | enum | Protocol/Culling.swift:58 | 10 | 6 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:330; …(+9) |
| 133 | `CullingFilterQualityStatus` | enum | Protocol/Culling.swift:70 | 6 | 2 | 1 | KEEP | gather-app/Sources/GatherUI/Culling/CullingToolbar.swift:115; …(+5) |
| 134 | `CullingFilters` | struct | Protocol/Culling.swift:77 | 11 | 5 | 21 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:369; …(+10) |
| 135 | `AssetCullingState` | struct | Protocol/Culling.swift:112 | 10 | 4 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:514; …(+9) |
| 136 | `CullingQualityStatus` | enum | Protocol/Culling.swift:133 | 1 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1923 |
| 137 | `CullingQuality` | struct | Protocol/Culling.swift:139 | 11 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1893; …(+10) |
| 138 | `CullingAsset` | struct | Protocol/Culling.swift:180 | 20 | 3 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:371; …(+19) |
| 139 | `CullingPage` | struct | Protocol/Culling.swift:221 | 10 | 1 | 15 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:391; …(+9) |
| 140 | `CullingListPageParams` | struct | Protocol/Culling.swift:256 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:243; …(+1) |
| 141 | `CullingUpdatePatch` | struct | Protocol/Culling.swift:275 | 28 | 13 | 59 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:443; …(+27) |
| 142 | `CullingUpdateParams` | struct | Protocol/Culling.swift:288 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:262; …(+1) |
| 143 | `CullingUpdateResult` | struct | Protocol/Culling.swift:303 | 16 | 4 | 35 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:445; …(+15) |
| 144 | `CullingStateSnapshot` | struct | Protocol/Culling.swift:318 | 12 | 3 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:587; …(+11) |
| 145 | `CullingUpdatePatchField` | enum | Protocol/Culling.swift:331 | 8 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:732; …(+7) |
| 146 | `CullingHistoryEntry` | struct | Protocol/Culling.swift:338 | 12 | 2 | 8 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:221; …(+11) |
| 147 | `CullingHistoryOperation` | struct | Protocol/Culling.swift:355 | 20 | 1 | 11 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1096; …(+19) |
| 148 | `CullingHistoryParams` | struct | Protocol/Culling.swift:372 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:354 |
| 149 | `CullingHistoryApplyEntry` | struct | Protocol/Culling.swift:383 | 6 | 5 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:726; …(+5) |
| 150 | `CullingHistoryDirection` | enum | Protocol/Culling.swift:396 | 2 | 5 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:728; …(+1) |
| 151 | `CullingHistoryApplyParams` | struct | Protocol/Culling.swift:402 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:357; …(+1) |
| 152 | `CullingBatchUpdateParams` | struct | Protocol/Culling.swift:417 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:292; …(+1) |
| 153 | `CullingDecideGroupParams` | struct | Protocol/Culling.swift:430 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:299 |
| 154 | `CullingSyncStatusParams` | struct | Protocol/Culling.swift:443 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:304 |
| 155 | `CullingFlushParams` | struct | Protocol/Culling.swift:452 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:307 |
| 156 | `CullingRetrySyncParams` | struct | Protocol/Culling.swift:461 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:310 |
| 157 | `CullingFinalizeSyncParams` | struct | Protocol/Culling.swift:470 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:313; …(+1) |
| 158 | `MetadataSyncItem` | struct | Protocol/Culling.swift:481 | 6 | 2 | 4 | KEEP | gather-core/Sources/GatherPersistence/Database/Repositories/DeliverySummaryQuery.swift:249; …(+5) |
| 159 | `MetadataSyncSummary` | struct | Protocol/Culling.swift:502 | 30 | 6 | 30 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1208; …(+29) |
| 160 | `CullingGroupsParams` | struct | Protocol/Culling.swift:527 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:426 |
| 161 | `CullingDecideParams` | struct | Protocol/Culling.swift:536 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:406 |
| 162 | `CullingBatchDecideParams` | struct | Protocol/Culling.swift:549 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:409; …(+1) |
| 163 | `CullingSummaryParams` | struct | Protocol/Culling.swift:562 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:429 |
| 164 | `CullingWritebackTarget` | enum | Protocol/Culling.swift:571 | 5 | 5 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1266; …(+4) |
| 165 | `CullingWritebackParams` | struct | Protocol/Culling.swift:578 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:412; …(+1) |
| 166 | `CullingRetryWritebackParams` | struct | Protocol/Culling.swift:591 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:417 |
| 167 | `CullingConfirmSyncParams` | struct | Protocol/Culling.swift:602 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:423 |
| 168 | `CullingCleanupParams` | struct | Protocol/Culling.swift:611 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:420; …(+1) |
| 169 | `CullingResetParams` | struct | Protocol/Culling.swift:622 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:432; …(+1) |
| 170 | `CullingGroup` | struct | Protocol/Culling.swift:635 | 11 | 1 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1008; …(+10) |
| 171 | `CullingImage` | struct | Protocol/Culling.swift:654 | 3 | 2 | 2 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1035; …(+2) |
| 172 | `CullingSummary` | struct | Protocol/Culling.swift:669 | 7 | 1 | 12 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1114; …(+6) |
| 173 | `DupScanParams` | struct | Protocol/Duplicate.swift:14 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:15; …(+1) |
| 174 | `DupGroupsParams` | struct | Protocol/Duplicate.swift:25 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:25; …(+1) |
| 175 | `DupResolution` | enum | Protocol/Duplicate.swift:34 | 7 | 5 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/DuplicateService.swift:542; …(+6) |
| 176 | `DupResolveParams` | struct | Protocol/Duplicate.swift:40 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:32; …(+1) |
| 177 | `DupResolveMemberParams` | struct | Protocol/Duplicate.swift:53 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:39; …(+1) |
| 178 | `DupScanOptions` | struct | Protocol/Duplicate.swift:66 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:136; …(+1) |
| 179 | `DuplicateScanResult` | struct | Protocol/Duplicate.swift:75 | 12 | 1 | 13 | KEEP | gather-core/Sources/GatherDomain/Services/DuplicateService.swift:134; …(+11) |
| 180 | `DuplicateGroupType` | enum | Protocol/Duplicate.swift:88 | 1 | 3 | 2 | KEEP | gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures.swift:732 |
| 181 | `DuplicateGroup` | struct | Protocol/Duplicate.swift:94 | 20 | 4 | 8 | KEEP | gather-core/Sources/GatherDomain/Services/DuplicateService.swift:527; …(+19) |
| 182 | `DuplicateGroupMember` | struct | Protocol/Duplicate.swift:158 | 12 | 3 | 5 | KEEP | gather-core/Sources/GatherDomain/Services/DuplicateService.swift:767; …(+11) |
| 183 | `ExportPreviewParams` | struct | Protocol/Export.swift:9 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:125; …(+1) |
| 184 | `ExportExecuteParams` | struct | Protocol/Export.swift:20 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:138; …(+1) |
| 185 | `ExportCancelParams` | struct | Protocol/Export.swift:33 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:152; …(+2) |
| 186 | `ExportReportParams` | struct | Protocol/Export.swift:38 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:159; …(+1) |
| 187 | `ExportScope` | enum | Protocol/Export.swift:51 | 4 | 2 | 1 | KEEP | gather-app/Sources/GatherUI/Export/ExportConfirmation.swift:43; …(+3) |
| 188 | `ExportVariantPolicy` | enum | Protocol/Export.swift:58 | 6 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:719; …(+5) |
| 189 | `ExportFormat` | enum | Protocol/Export.swift:66 | 5 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:718; …(+4) |
| 190 | `ExportTiffCompression` | enum | Protocol/Export.swift:73 | 4 | 2 | 1 | KEEP | gather-app/Sources/GatherUI/Export/ExportView+Options.swift:81; …(+3) |
| 191 | `ExportWatermarkType` | enum | Protocol/Export.swift:80 | 0 | 2 | 1 | KEEP | gather-core/Sources/GatherProtocol/Protocol/Export.swift:94; …(+1) |
| 192 | `ExportWatermarkPosition` | enum | Protocol/Export.swift:86 | 4 | 2 | 1 | KEEP | gather-app/Sources/GatherUI/Export/ExportView+Options.swift:96; …(+3) |
| 193 | `ExportWatermark` | struct | Protocol/Export.swift:93 | 3 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:1045; …(+2) |
| 194 | `ExportNaming` | struct | Protocol/Export.swift:110 | 1 | 2 | 29 | KEEP | gather-app/Sources/GatherUI/Export/ExportViewModel+Execute.swift:157 |
| 195 | `ExportOptions` | struct | Protocol/Export.swift:123 | 19 | 7 | 33 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:194; …(+18) |
| 196 | `ExportPreviewFile` | struct | Protocol/Export.swift:164 | 3 | 3 | 8 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:317; …(+2) |
| 197 | `ExportPreview` | struct | Protocol/Export.swift:223 | 7 | 1 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:360; …(+6) |
| 198 | `ExportResult` | struct | Protocol/Export.swift:275 | 6 | 1 | 9 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:523; …(+5) |
| 199 | `ReportFormat` | enum | Protocol/Export.swift:292 | 2 | 5 | 2 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:644; …(+1) |
| 200 | `ReportData` | struct | Protocol/Export.swift:298 | 9 | 1 | 7 | KEEP | gather-core/Sources/GatherDomain/Services/ExportService.swift:643; …(+8) |
| 201 | `FkwAnalyzeParams` | struct | Protocol/Face.swift:12 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:15; …(+1) |
| 202 | `FkwBindParams` | struct | Protocol/Face.swift:32 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:25; …(+1) |
| 203 | `FkwUnbindParams` | struct | Protocol/Face.swift:47 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:32; …(+1) |
| 204 | `FkwMergeParams` | struct | Protocol/Face.swift:60 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:35; …(+1) |
| 205 | `FkwRemoveMemberParams` | struct | Protocol/Face.swift:73 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:42; …(+1) |
| 206 | `FkwPreviewParams` | struct | Protocol/Face.swift:86 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:49; …(+1) |
| 207 | `FkwWritebackParams` | struct | Protocol/Face.swift:97 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:59; …(+1) |
| 208 | `FkwConfirmSyncParams` | struct | Protocol/Face.swift:110 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:67 |
| 209 | `FkwConfirmCleanupParams` | struct | Protocol/Face.swift:121 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:69 |
| 210 | `FkwCleanupParams` | struct | Protocol/Face.swift:132 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:71; …(+1) |
| 211 | `FaceModelsStatusData` | struct | Protocol/Face.swift:143 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:81; …(+1) |
| 212 | `FaceObservation` | struct | Protocol/Face.swift:158 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:93; …(+2) |
| 213 | `ClusterMember` | struct | Protocol/Face.swift:183 | 5 | 4 | 9 | KEEP | gather-core/Sources/GatherDomain/Services/FaceKwService.swift:1019; …(+4) |
| 214 | `BindingData` | struct | Protocol/Face.swift:202 | 0 | 2 | 1 | DELETE secondary | gather-core/Sources/GatherProtocol/Protocol/Face.swift:224; …(+1) |
| 215 | `FaceCluster` | struct | Protocol/Face.swift:217 | 0 | 0 | 4 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:120; …(+3) |
| 216 | `FilterPhotosParams` | struct | Protocol/Filter.swift:15 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:98; …(+1) |
| 217 | `FilterPhotosGlobalParams` | struct | Protocol/Filter.swift:30 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:110; …(+1) |
| 218 | `FilterSuggestParams` | struct | Protocol/Filter.swift:45 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:121; …(+1) |
| 219 | `AlbumCreateParams` | struct | Protocol/Filter.swift:56 | 5 | 1 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:39; …(+4) |
| 220 | `AlbumListParams` | struct | Protocol/Filter.swift:75 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:142; …(+2) |
| 221 | `AlbumGetParams` | struct | Protocol/Filter.swift:80 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:148 |
| 222 | `AlbumUpdateParams` | struct | Protocol/Filter.swift:89 | 5 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:47; …(+4) |
| 223 | `AlbumDeleteParams` | struct | Protocol/Filter.swift:110 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:156; …(+1) |
| 224 | `AlbumGetPhotosParams` | struct | Protocol/Filter.swift:121 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:159 |
| 225 | `FilterOperator` | enum | Protocol/Filter.swift:134 | 4 | 2 | 4 | KEEP | gather-core/Sources/GatherDomain/Services/FilterEngine.swift:375; …(+3) |
| 226 | `FilterRule` | struct | Protocol/Filter.swift:151 | 2 | 2 | 29 | KEEP | gather-core/Sources/GatherDomain/Services/FilterEngine.swift:270; …(+1) |
| 227 | `FilterLogic` | enum | Protocol/Filter.swift:164 | 0 | 2 | 2 | KEEP | gather-core/Sources/GatherProtocol/Protocol/Filter.swift:192; …(+1) |
| 228 | `FilterCondition` | enum | Protocol/Filter.swift:170 | 1 | 2 | 0 | KEEP | gather-app/Sources/GatherUI/Library/LibraryViewModel.swift:56 |
| 229 | `FilterGroup` | struct | Protocol/Filter.swift:191 | 27 | 17 | 38 | KEEP | gather-core/Sources/GatherDomain/Services/FilterEngine.swift:80; …(+26) |
| 230 | `FilterSuggestion` | struct | Protocol/Filter.swift:202 | 3 | 1 | 2 | KEEP | gather-core/Sources/GatherDomain/Services/FilterEngine.swift:226; …(+2) |
| 231 | `GlobalPhotoResult` | struct | Protocol/Filter.swift:213 | 13 | 4 | 10 | KEEP | gather-core/Sources/GatherDomain/Services/FilterEngine.swift:126; …(+12) |
| 232 | `SmartAlbumData` | struct | Protocol/Filter.swift:257 | 19 | 1 | 7 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:43; …(+18) |
| 233 | `SmartAlbumDetailData` | struct | Protocol/Filter.swift:298 | 6 | 1 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift:39; …(+5) |
| 234 | `FaceIdentityPolicy` | enum | Protocol/IdentityPolicy.swift:5 | 13 | 0 | 7 | KEEP | gather-core/Sources/GatherAnalysis/Face/Matcher.swift:117; …(+12) |
| 235 | `IndexScanParams` | struct | Protocol/Indexer.swift:9 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/IndexerContractTests.swift:12; …(+1) |
| 236 | `IndexScanResult` | struct | Protocol/Indexer.swift:20 | 2 | 0 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/IndexerService.swift:232; …(+1) |
| 237 | `AnalysisJobType` | enum | Protocol/Jobs.swift:9 | 17 | 4 | 16 | KEEP | gather-core/Sources/GatherDomain/Services/JobService.swift:255; …(+16) |
| 238 | `AnalysisJobStatus` | enum | Protocol/Jobs.swift:21 | 16 | 4 | 15 | KEEP | gather-core/Sources/GatherDomain/Services/JobService.swift:459; …(+15) |
| 239 | `AnalysisJobData` | struct | Protocol/Jobs.swift:32 | 62 | 3 | 45 | KEEP | gather-core/Sources/GatherDomain/Services/JobService.swift:95; …(+61) |
| 240 | `JobCreateParams` | struct | Protocol/Jobs.swift:109 | 21 | 4 | 42 | KEEP | gather-core/Sources/GatherDomain/Services/JobService.swift:453; …(+20) |
| 241 | `JobListParams` | struct | Protocol/Jobs.swift:144 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:42; …(+2) |
| 242 | `JobCancelParams` | struct | Protocol/Jobs.swift:153 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:125; …(+1) |
| 243 | `JobRetryParams` | struct | Protocol/Jobs.swift:162 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:130; …(+1) |
| 244 | `JobClearCompletedParams` | struct | Protocol/Jobs.swift:171 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:135; …(+1) |
| 245 | `JobProgressUpdate` | struct | Protocol/Jobs.swift:180 | 32 | 1 | 27 | KEEP | gather-core/Sources/GatherDomain/Services/IndexerService.swift:682; …(+31) |
| 246 | `MetadataGetParams` | struct | Protocol/Metadata.swift:9 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:87; …(+1) |
| 247 | `MetadataSetParams` | struct | Protocol/Metadata.swift:18 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:94; …(+1) |
| 248 | `MetadataBatchUpdate` | struct | Protocol/Metadata.swift:31 | 0 | 5 | 6 | KEEP | gather-core/Sources/GatherProtocol/API/Inputs/MetadataInputs.swift:64; …(+4) |
| 249 | `MetadataBatchSetParams` | struct | Protocol/Metadata.swift:42 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:105; …(+1) |
| 250 | `MetadataField` | enum | Protocol/Metadata.swift:53 | 19 | 13 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataContract.swift:55; …(+18) |
| 251 | `MetadataMutationSource` | enum | Protocol/Metadata.swift:60 | 9 | 4 | 19 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:1863; …(+8) |
| 252 | `MetadataRatingOp` | enum | Protocol/Metadata.swift:69 | 0 | 2 | 1 | KEEP | gather-core/Sources/GatherProtocol/Protocol/Metadata.swift:75; …(+1) |
| 253 | `MetadataRatingPatch` | struct | Protocol/Metadata.swift:74 | 2 | 2 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataContract.swift:72; …(+1) |
| 254 | `MetadataLabelOp` | enum | Protocol/Metadata.swift:85 | 0 | 2 | 1 | KEEP | gather-core/Sources/GatherProtocol/Protocol/Metadata.swift:91; …(+1) |
| 255 | `MetadataLabelPatch` | struct | Protocol/Metadata.swift:90 | 2 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataContract.swift:78; …(+1) |
| 256 | `MetadataKeywordsOp` | enum | Protocol/Metadata.swift:101 | 0 | 2 | 1 | KEEP | gather-core/Sources/GatherProtocol/Protocol/Metadata.swift:109; …(+1) |
| 257 | `MetadataKeywordsPatch` | struct | Protocol/Metadata.swift:108 | 2 | 2 | 8 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataContract.swift:88; …(+1) |
| 258 | `MetadataPatch` | struct | Protocol/Metadata.swift:119 | 5 | 2 | 27 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataContract.swift:62; …(+4) |
| 259 | `MetadataMutationTarget` | struct | Protocol/Metadata.swift:132 | 0 | 2 | 2 | DELETE secondary | gather-core/Sources/GatherProtocol/Protocol/Metadata.swift:142; …(+1) |
| 260 | `MetadataMutationRequest` | struct | Protocol/Metadata.swift:141 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:120; …(+2) |
| 261 | `MetadataMutationResult` | struct | Protocol/Metadata.swift:158 | 7 | 0 | 34 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataMutationService.swift:55; …(+6) |
| 262 | `MetadataConflictField` | struct | Protocol/Metadata.swift:175 | 4 | 2 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:92; …(+3) |
| 263 | `MetadataConflict` | struct | Protocol/Metadata.swift:190 | 16 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:83; …(+15) |
| 264 | `MetadataConflictChoice` | enum | Protocol/Metadata.swift:205 | 14 | 8 | 1 | KEEP | gather-app/Sources/GatherUI/Culling/CullingConflictPanel.swift:11; …(+13) |
| 265 | `MetadataConflictListParams` | struct | Protocol/Metadata.swift:211 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:187 |
| 266 | `MetadataConflictResolveParams` | struct | Protocol/Metadata.swift:223 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:193; …(+1) |
| 267 | `MetadataOrphan` | struct | Protocol/Metadata.swift:269 | 18 | 2 | 18 | KEEP | gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:110; …(+17) |
| 268 | `MetadataOrphanAction` | enum | Protocol/Metadata.swift:288 | 1 | 5 | 1 | KEEP | gather-app/Sources/GatherUI/Library/LibraryViewModel+Load.swift:124 |
| 269 | `MetadataOrphanResolveParams` | struct | Protocol/Metadata.swift:295 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:222; …(+1) |
| 270 | `MetadataTags` | struct | Protocol/Metadata.swift:308 | 25 | 9 | 24 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataService.swift:64; …(+24) |
| 271 | `BatchMetadataResult` | struct | Protocol/Metadata.swift:406 | 4 | 1 | 4 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataService.swift:634; …(+3) |
| 272 | `MetadataFingerprintError` | enum | Protocol/Metadata.swift:421 | 2 | 0 | 0 | KEEP | gather-core/Sources/GatherDomain/Services/MetadataFingerprint.swift:19; …(+1) |
| 273 | `NavigationGroupType` | enum | Protocol/Navigation.swift:9 | 4 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/NavigationService.swift:149; …(+3) |
| 274 | `NavigationAnalyzeParams` | struct | Protocol/Navigation.swift:15 | 4 | 1 | 9 | KEEP | gather-app/Sources/GatherHost/APIs/LiveNavigationAPI.swift:45; …(+3) |
| 275 | `NavigationGroupSource` | enum | Protocol/Navigation.swift:30 | 2 | 2 | 1 | KEEP | gather-core/Sources/GatherDomain/Services/NavigationService.swift:155; …(+1) |
| 276 | `NavigationGroup` | struct | Protocol/Navigation.swift:36 | 34 | 4 | 31 | KEEP | gather-core/Sources/GatherDomain/Services/NavigationService.swift:98; …(+33) |
| 277 | `NavigationListParams` | struct | Protocol/Navigation.swift:68 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/NavigationContractTests.swift:42 |
| 278 | `NavigationSplitParams` | struct | Protocol/Navigation.swift:77 | 4 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveNavigationAPI.swift:37; …(+3) |
| 279 | `NavigationMergeParams` | struct | Protocol/Navigation.swift:90 | 4 | 1 | 8 | KEEP | gather-app/Sources/GatherHost/APIs/LiveNavigationAPI.swift:41; …(+3) |
| 280 | `PersonListParams` | struct | Protocol/Person.swift:9 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:14; …(+2) |
| 281 | `PersonGetParams` | struct | Protocol/Person.swift:14 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:20 |
| 282 | `PersonCreateParams` | struct | Protocol/Person.swift:23 | 3 | 1 | 11 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:87; …(+2) |
| 283 | `PersonUpdateParams` | struct | Protocol/Person.swift:34 | 3 | 1 | 10 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:95; …(+2) |
| 284 | `PersonDeleteParams` | struct | Protocol/Person.swift:51 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:23; …(+1) |
| 285 | `PersonMergeParams` | struct | Protocol/Person.swift:62 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:51 |
| 286 | `PersonRemovePhotoParams` | struct | Protocol/Person.swift:75 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:54; …(+1) |
| 287 | `PersonSearchPhotosParams` | struct | Protocol/Person.swift:88 | 3 | 1 | 13 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:131; …(+2) |
| 288 | `PersonData` | struct | Protocol/Person.swift:103 | 10 | 1 | 10 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:54; …(+9) |
| 289 | `PersonPhotoItem` | struct | Protocol/Person.swift:144 | 3 | 4 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:167; …(+2) |
| 290 | `PersonDetailData` | struct | Protocol/Person.swift:176 | 7 | 1 | 9 | KEEP | gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift:60; …(+6) |
| 291 | `PhotoFileTypes` | enum | Protocol/PhotoFileTypes.swift:17 | 6 | 0 | 20 | KEEP | gather-core/Sources/GatherAnalysis/Image/RAWDecoder.swift:198; …(+5) |
| 292 | `QualityAnalyzeParams` | struct | Protocol/Quality.swift:9 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/QualityContractTests.swift:14; …(+1) |
| 293 | `QualityGetParams` | struct | Protocol/Quality.swift:20 | 2 | 1 | 11 | KEEP | gather-app/Sources/GatherHost/APIs/LiveQualityAPI.swift:70; …(+1) |
| 294 | `QualityResultStatus` | enum | Protocol/Quality.swift:31 | 0 | 2 | 1 | KEEP | gather-core/Sources/GatherProtocol/Protocol/Quality.swift:40; …(+1) |
| 295 | `QualityResult` | struct | Protocol/Quality.swift:37 | 15 | 1 | 13 | KEEP | gather-core/Sources/GatherDomain/Services/QualityService.swift:193; …(+14) |
| 296 | `SessionCreateParams` | struct | Protocol/Session.swift:9 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:133; …(+1) |
| 297 | `SessionCreateFromDirectoryParams` | struct | Protocol/Session.swift:32 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:148 |
| 298 | `SessionAddPhotosParams` | struct | Protocol/Session.swift:43 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:154; …(+1) |
| 299 | `SessionUpdateParams` | struct | Protocol/Session.swift:56 | 3 | 1 | 3 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:66; …(+2) |
| 300 | `SessionData` | struct | Protocol/Session.swift:67 | 51 | 5 | 52 | KEEP | gather-core/Sources/GatherDomain/Services/SessionService.swift:66; …(+50) |
| 301 | `PhotoVariant` | struct | Protocol/Session.swift:111 | 2 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:2218; …(+1) |
| 302 | `PhotoData` | struct | Protocol/Session.swift:126 | 6 | 4 | 13 | KEEP | gather-core/Sources/GatherDomain/Services/CullingService.swift:2658; …(+5) |
| 303 | `SessionServiceError` | enum | Protocol/SessionErrors.swift:13 | 14 | 1 | 26 | KEEP | gather-core/Sources/GatherDomain/Services/SessionService.swift:53; …(+13) |
| 304 | `MLStatusData` | struct | Protocol/Settings.swift:12 | 9 | 1 | 4 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:80; …(+8) |
| 305 | `MLBackendOption` | struct | Protocol/Settings.swift:50 | 4 | 2 | 0 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:104; …(+3) |
| 306 | `MLModelPresence` | struct | Protocol/Settings.swift:60 | 5 | 4 | 2 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:106; …(+4) |
| 307 | `MLModelInfo` | struct | Protocol/Settings.swift:72 | 2 | 2 | 1 | KEEP | gather-app/Sources/GatherHost/APIs/LiveSettingsAPI.swift:112; …(+1) |
| 308 | `SimilarityGroupingMode` | enum | Protocol/Similarity.swift:9 | 14 | 9 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/SimilarityService.swift:106; …(+13) |
| 309 | `SimAnalyzeParams` | struct | Protocol/Similarity.swift:15 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:25; …(+1) |
| 310 | `SimCancelAnalysisParams` | struct | Protocol/Similarity.swift:30 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:35 |
| 311 | `SimResultParams` | struct | Protocol/Similarity.swift:39 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:43; …(+1) |
| 312 | `SimReclusterParams` | struct | Protocol/Similarity.swift:50 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:51; …(+1) |
| 313 | `SimilarityKeywordAssignment` | struct | Protocol/Similarity.swift:65 | 2 | 8 | 3 | KEEP | gather-app/Sources/GatherUI/Similarity/SimilarityViewModel+Writeback.swift:89; …(+1) |
| 314 | `SimPreviewWritebackParams` | struct | Protocol/Similarity.swift:76 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:58; …(+1) |
| 315 | `SimWritebackParams` | struct | Protocol/Similarity.swift:89 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:72; …(+1) |
| 316 | `SimWritebackItemsParams` | struct | Protocol/Similarity.swift:104 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:77 |
| 317 | `SimRetryFailedWritebackParams` | struct | Protocol/Similarity.swift:113 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:80 |
| 318 | `SimConfirmSyncParams` | struct | Protocol/Similarity.swift:124 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:38 |
| 319 | `SimCleanupParams` | struct | Protocol/Similarity.swift:133 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:83; …(+1) |
| 320 | `SimilarityImage` | struct | Protocol/Similarity.swift:144 | 11 | 4 | 14 | KEEP | gather-core/Sources/GatherDomain/Services/SimilarityService.swift:600; …(+10) |
| 321 | `SimilarityGroup` | struct | Protocol/Similarity.swift:155 | 8 | 2 | 8 | KEEP | gather-core/Sources/GatherDomain/Services/SimilarityService.swift:596; …(+7) |
| 322 | `SimilarityResultStats` | struct | Protocol/Similarity.swift:172 | 4 | 2 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/SimilarityService.swift:1368; …(+3) |
| 323 | `ClusterState` | struct | Protocol/Similarity.swift:197 | 19 | 0 | 4 | KEEP | gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph.swift:698; …(+18) |
| 324 | `TemplateCreateParams` | struct | Protocol/Template.swift:9 | 1 | 1 | 5 | KEEP | gather-app/Sources/GatherHost/APIs/LiveTemplateAPI.swift:49 |
| 325 | `TemplateListParams` | struct | Protocol/Template.swift:22 | 0 | 0 | 3 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:80; …(+2) |
| 326 | `TemplateGetParams` | struct | Protocol/Template.swift:27 | 0 | 0 | 1 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:86 |
| 327 | `TemplateUpdateParams` | struct | Protocol/Template.swift:36 | 1 | 1 | 6 | KEEP | gather-app/Sources/GatherHost/APIs/LiveTemplateAPI.swift:60 |
| 328 | `TemplateDeleteParams` | struct | Protocol/Template.swift:51 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:103; …(+1) |
| 329 | `TemplateApplyParams` | struct | Protocol/Template.swift:62 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:108; …(+1) |
| 330 | `WorkflowTemplateSimilarity` | struct | Protocol/Template.swift:75 | 1 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:195 |
| 331 | `WorkflowTemplateFace` | struct | Protocol/Template.swift:86 | 1 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:199 |
| 332 | `WorkflowTemplateFaceLibrary` | struct | Protocol/Template.swift:100 | 1 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:204 |
| 333 | `WorkflowTemplateDuplicate` | struct | Protocol/Template.swift:111 | 1 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:208 |
| 334 | `WorkflowTemplateWriteback` | struct | Protocol/Template.swift:122 | 1 | 2 | 3 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:212 |
| 335 | `WorkflowTemplateConfig` | struct | Protocol/Template.swift:137 | 6 | 6 | 7 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:52; …(+5) |
| 336 | `TemplateData` | struct | Protocol/Template.swift:160 | 10 | 4 | 2 | KEEP | gather-core/Sources/GatherDomain/Services/TemplateService.swift:72; …(+9) |
| 337 | `WorkspaceStage` | enum | Protocol/Workspace.swift:13 | 3 | 3 | 19 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:145; …(+2) |
| 338 | `WorkspaceIndexingStatus` | enum | Protocol/Workspace.swift:21 | 1 | 2 | 5 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:101 |
| 339 | `WorkspaceIndexingProgress` | struct | Protocol/Workspace.swift:28 | 3 | 3 | 21 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:102; …(+2) |
| 340 | `WorkspaceStaleAnalysisKind` | enum | Protocol/Workspace.swift:43 | 2 | 2 | 2 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:264; …(+1) |
| 341 | `WorkspaceStaleAnalysis` | struct | Protocol/Workspace.swift:49 | 4 | 3 | 6 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:82; …(+3) |
| 342 | `WorkspaceXmpCounts` | struct | Protocol/Workspace.swift:60 | 3 | 3 | 14 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:123; …(+2) |
| 343 | `WorkspaceFailedJob` | struct | Protocol/Workspace.swift:71 | 3 | 3 | 12 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:229; …(+2) |
| 344 | `WorkspaceRecommendedNext` | struct | Protocol/Workspace.swift:86 | 8 | 3 | 11 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:171; …(+7) |
| 345 | `WorkspaceSoftFlags` | struct | Protocol/Workspace.swift:97 | 4 | 3 | 12 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:110; …(+3) |
| 346 | `WorkspaceStatus` | struct | Protocol/Workspace.swift:108 | 28 | 1 | 35 | KEEP | gather-core/Sources/GatherDomain/Services/WorkspaceStatusService.swift:59; …(+27) |
| 347 | `WorkspaceStatusParams` | struct | Protocol/Workspace.swift:182 | 0 | 0 | 2 | DELETE zero | gather-core/Tests/GatherCoreTests/Protocol/WorkspaceContractTests.swift:129; …(+1) |

> 注：`FaceIdentityPolicy.Decision` 为嵌套 public enum（`Protocol/IdentityPolicy.swift:6`），不计入上表 347；其 1 行 `public enum` 计入 1,752 声明行。

## 3. 89 个零引用类型（prod=0 / proto=0）

这些类型在 `HEAD` 的全部生产 Sources 与 Protocol 内均为 0 引用；`test` 列是唯一引用来源，删除时同步删除/改写对应 ContractTests。

| # | 类型 | HEAD 位置 | 行数 | test 引用 | 测试证据（全部/前 4 条） |
| ---: | --- | --- | ---: | ---: | --- |
| 1 | `AssetCandidateListParams` | Protocol/Assets.swift:9 | 8-15（8） | 3 | gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:14; gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:18; gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:22 |
| 2 | `AssetCandidateMutationParams` | Protocol/Assets.swift:18 | 17-26（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:28; gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:30 |
| 3 | `AssetRelinkRootParams` | Protocol/Assets.swift:83 | 82-93（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:99; gather-core/Tests/GatherCoreTests/Protocol/AssetsContractTests.swift:101 |
| 4 | `Response` | Protocol/Core.swift:292 | 291-315（25） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:218; gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:226 |
| 5 | `CullingListPageParams` | Protocol/Culling.swift:256 | 255-272（18） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:243; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:251 |
| 6 | `CullingUpdateParams` | Protocol/Culling.swift:288 | 287-300（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:262; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:267 |
| 7 | `CullingHistoryParams` | Protocol/Culling.swift:372 | 371-380（10） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:354 |
| 8 | `CullingHistoryApplyParams` | Protocol/Culling.swift:402 | 401-414（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:357; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:369 |
| 9 | `CullingBatchUpdateParams` | Protocol/Culling.swift:417 | 416-427（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:292; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:296 |
| 10 | `CullingDecideGroupParams` | Protocol/Culling.swift:430 | 429-440（12） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:299 |
| 11 | `CullingSyncStatusParams` | Protocol/Culling.swift:443 | 442-449（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:304 |
| 12 | `CullingFlushParams` | Protocol/Culling.swift:452 | 451-458（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:307 |
| 13 | `CullingRetrySyncParams` | Protocol/Culling.swift:461 | 460-467（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:310 |
| 14 | `CullingFinalizeSyncParams` | Protocol/Culling.swift:470 | 469-478（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:313; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:315 |
| 15 | `CullingGroupsParams` | Protocol/Culling.swift:527 | 526-533（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:426 |
| 16 | `CullingDecideParams` | Protocol/Culling.swift:536 | 535-546（12） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:406 |
| 17 | `CullingBatchDecideParams` | Protocol/Culling.swift:549 | 548-559（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:409; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:410 |
| 18 | `CullingSummaryParams` | Protocol/Culling.swift:562 | 561-568（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:429 |
| 19 | `CullingWritebackParams` | Protocol/Culling.swift:578 | 577-588（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:412; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:414 |
| 20 | `CullingRetryWritebackParams` | Protocol/Culling.swift:591 | 590-599（10） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:417 |
| 21 | `CullingConfirmSyncParams` | Protocol/Culling.swift:602 | 601-608（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:423 |
| 22 | `CullingCleanupParams` | Protocol/Culling.swift:611 | 610-619（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:420; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:421 |
| 23 | `CullingResetParams` | Protocol/Culling.swift:622 | 621-632（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:432; gather-core/Tests/GatherCoreTests/Protocol/CullingContractTests.swift:435 |
| 24 | `DupScanParams` | Protocol/Duplicate.swift:14 | 13-22（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:15; gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:19 |
| 25 | `DupGroupsParams` | Protocol/Duplicate.swift:25 | 24-31（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:25; gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:27 |
| 26 | `DupResolveParams` | Protocol/Duplicate.swift:40 | 39-50（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:32; gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:34 |
| 27 | `DupResolveMemberParams` | Protocol/Duplicate.swift:53 | 52-63（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:39; gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:41 |
| 28 | `DupScanOptions` | Protocol/Duplicate.swift:66 | 65-72（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:136; gather-core/Tests/GatherCoreTests/Protocol/DuplicateContractTests.swift:138 |
| 29 | `ExportPreviewParams` | Protocol/Export.swift:9 | 8-17（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:125; gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:133 |
| 30 | `ExportExecuteParams` | Protocol/Export.swift:20 | 19-30（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:138; gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:147 |
| 31 | `ExportCancelParams` | Protocol/Export.swift:33 | 32-35（4） | 3 | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:152; gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:154; gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:155 |
| 32 | `ExportReportParams` | Protocol/Export.swift:38 | 37-48（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:159; gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift:162 |
| 33 | `FkwAnalyzeParams` | Protocol/Face.swift:12 | 11-29（19） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:15; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:19 |
| 34 | `FkwBindParams` | Protocol/Face.swift:32 | 31-44（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:25; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:27 |
| 35 | `FkwUnbindParams` | Protocol/Face.swift:47 | 46-57（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:32; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:33 |
| 36 | `FkwMergeParams` | Protocol/Face.swift:60 | 59-70（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:35; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:37 |
| 37 | `FkwRemoveMemberParams` | Protocol/Face.swift:73 | 72-83（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:42; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:44 |
| 38 | `FkwPreviewParams` | Protocol/Face.swift:86 | 85-94（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:49; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:52 |
| 39 | `FkwWritebackParams` | Protocol/Face.swift:97 | 96-107（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:59; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:62 |
| 40 | `FkwConfirmSyncParams` | Protocol/Face.swift:110 | 109-118（10） | 1 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:67 |
| 41 | `FkwConfirmCleanupParams` | Protocol/Face.swift:121 | 120-129（10） | 1 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:69 |
| 42 | `FkwCleanupParams` | Protocol/Face.swift:132 | 131-140（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:71; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:74 |
| 43 | `FaceModelsStatusData` | Protocol/Face.swift:143 | 142-155（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:81; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:86 |
| 44 | `FaceObservation` | Protocol/Face.swift:158 | 157-180（24） | 3 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:93; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:99; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:108 |
| 45 | `FaceCluster` | Protocol/Face.swift:217 | 216-255（40） | 4 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:120; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:136; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:144; gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:150 |
| 46 | `FilterPhotosParams` | Protocol/Filter.swift:15 | 14-27（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:98; gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:105 |
| 47 | `FilterPhotosGlobalParams` | Protocol/Filter.swift:30 | 29-42（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:110; gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:116 |
| 48 | `FilterSuggestParams` | Protocol/Filter.swift:45 | 44-53（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:121; gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:123 |
| 49 | `AlbumListParams` | Protocol/Filter.swift:75 | 74-77（4） | 3 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:142; gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:143; gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:144 |
| 50 | `AlbumGetParams` | Protocol/Filter.swift:80 | 79-86（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:148 |
| 51 | `AlbumDeleteParams` | Protocol/Filter.swift:110 | 109-118（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:156; gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:157 |
| 52 | `AlbumGetPhotosParams` | Protocol/Filter.swift:121 | 120-131（12） | 1 | gather-core/Tests/GatherCoreTests/Protocol/FilterContractTests.swift:159 |
| 53 | `IndexScanParams` | Protocol/Indexer.swift:9 | 8-17（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/IndexerContractTests.swift:12; gather-core/Tests/GatherCoreTests/Protocol/IndexerContractTests.swift:16 |
| 54 | `JobListParams` | Protocol/Jobs.swift:144 | 143-150（8） | 3 | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:42; gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:117; gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:120 |
| 55 | `JobCancelParams` | Protocol/Jobs.swift:153 | 152-159（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:125; gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:127 |
| 56 | `JobRetryParams` | Protocol/Jobs.swift:162 | 161-168（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:130; gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:131 |
| 57 | `JobClearCompletedParams` | Protocol/Jobs.swift:171 | 170-177（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:135; gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift:137 |
| 58 | `MetadataGetParams` | Protocol/Metadata.swift:9 | 8-15（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:87; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:89 |
| 59 | `MetadataSetParams` | Protocol/Metadata.swift:18 | 17-28（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:94; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:100 |
| 60 | `MetadataBatchSetParams` | Protocol/Metadata.swift:42 | 41-50（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:105; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:113 |
| 61 | `MetadataMutationRequest` | Protocol/Metadata.swift:141 | 140-155（16） | 3 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:120; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:128; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:137 |
| 62 | `MetadataConflictListParams` | Protocol/Metadata.swift:211 | 210-217（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:187 |
| 63 | `MetadataConflictResolveParams` | Protocol/Metadata.swift:223 | 219-266（48） | 2 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:193; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:200 |
| 64 | `MetadataOrphanResolveParams` | Protocol/Metadata.swift:295 | 294-305（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:222; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:224 |
| 65 | `NavigationListParams` | Protocol/Navigation.swift:68 | 67-74（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/NavigationContractTests.swift:42 |
| 66 | `PersonListParams` | Protocol/Person.swift:9 | 8-11（4） | 3 | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:14; gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:15; gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:16 |
| 67 | `PersonGetParams` | Protocol/Person.swift:14 | 13-20（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:20 |
| 68 | `PersonDeleteParams` | Protocol/Person.swift:51 | 50-59（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:23; gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:25 |
| 69 | `PersonMergeParams` | Protocol/Person.swift:62 | 61-72（12） | 1 | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:51 |
| 70 | `PersonRemovePhotoParams` | Protocol/Person.swift:75 | 74-85（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:54; gather-core/Tests/GatherCoreTests/Protocol/PersonContractTests.swift:56 |
| 71 | `QualityAnalyzeParams` | Protocol/Quality.swift:9 | 8-17（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/QualityContractTests.swift:14; gather-core/Tests/GatherCoreTests/Protocol/QualityContractTests.swift:17 |
| 72 | `SessionCreateParams` | Protocol/Session.swift:9 | 8-29（22） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:133; gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:142 |
| 73 | `SessionCreateFromDirectoryParams` | Protocol/Session.swift:32 | 31-40（10） | 1 | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:148 |
| 74 | `SessionAddPhotosParams` | Protocol/Session.swift:43 | 42-53（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:154; gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:158 |
| 75 | `SimAnalyzeParams` | Protocol/Similarity.swift:15 | 14-27（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:25; gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:29 |
| 76 | `SimCancelAnalysisParams` | Protocol/Similarity.swift:30 | 29-36（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:35 |
| 77 | `SimResultParams` | Protocol/Similarity.swift:39 | 38-47（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:43; gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:46 |
| 78 | `SimReclusterParams` | Protocol/Similarity.swift:50 | 49-62（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:51; gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:53 |
| 79 | `SimPreviewWritebackParams` | Protocol/Similarity.swift:76 | 75-86（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:58; gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:67 |
| 80 | `SimWritebackParams` | Protocol/Similarity.swift:89 | 88-101（14） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:72; gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:74 |
| 81 | `SimWritebackItemsParams` | Protocol/Similarity.swift:104 | 103-110（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:77 |
| 82 | `SimRetryFailedWritebackParams` | Protocol/Similarity.swift:113 | 112-121（10） | 1 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:80 |
| 83 | `SimConfirmSyncParams` | Protocol/Similarity.swift:124 | 123-130（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:38 |
| 84 | `SimCleanupParams` | Protocol/Similarity.swift:133 | 132-141（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:83; gather-core/Tests/GatherCoreTests/Protocol/SimilarityContractTests.swift:85 |
| 85 | `TemplateListParams` | Protocol/Template.swift:22 | 21-24（4） | 3 | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:80; gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:81; gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:82 |
| 86 | `TemplateGetParams` | Protocol/Template.swift:27 | 26-33（8） | 1 | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:86 |
| 87 | `TemplateDeleteParams` | Protocol/Template.swift:51 | 50-59（10） | 2 | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:103; gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:105 |
| 88 | `TemplateApplyParams` | Protocol/Template.swift:62 | 61-72（12） | 2 | gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:108; gather-core/Tests/GatherCoreTests/Protocol/TemplateContractTests.swift:110 |
| 89 | `WorkspaceStatusParams` | Protocol/Workspace.swift:182 | 181-188（8） | 2 | gather-core/Tests/GatherCoreTests/Protocol/WorkspaceContractTests.swift:129; gather-core/Tests/GatherCoreTests/Protocol/WorkspaceContractTests.swift:131 |

> 合计 942 行（按 `start-end` 含声明前连续 `//`/`///` 注释）；行号是 HEAD 快照，删除后已偏移。

## 4. 6 个 Router 信封（Core.swift:158-315）

| 类型 | HEAD 行范围 | prod | proto | test | 引用证据 |
| --- | --- | ---: | ---: | ---: | --- |
| `ResponseID` | Protocol/Core.swift:158-180（23 行） | 0 | 6 | 2 | gather-core/Sources/GatherProtocol/Protocol/Core.swift:221; gather-core/Sources/GatherProtocol/Protocol/Core.swift:225; …(+4) |
| `ErrorDetail` | Protocol/Core.swift:182-194（13 行） | 0 | 2 | 1 | gather-core/Sources/GatherProtocol/Protocol/Core.swift:199; gather-core/Sources/GatherProtocol/Protocol/Core.swift:205 |
| `ResponseErrorBody` | Protocol/Core.swift:196-215（20 行） | 0 | 3 | 0 | gather-core/Sources/GatherProtocol/Protocol/Core.swift:259; gather-core/Sources/GatherProtocol/Protocol/Core.swift:261; …(+1) |
| `ResponseOk` | Protocol/Core.swift:217-253（37 行） | 0 | 3 | 3 | gather-core/Sources/GatherProtocol/Protocol/Core.swift:237; gather-core/Sources/GatherProtocol/Protocol/Core.swift:293; …(+1) |
| `ResponseErr` | Protocol/Core.swift:255-289（35 行） | 0 | 3 | 4 | gather-core/Sources/GatherProtocol/Protocol/Core.swift:273; gather-core/Sources/GatherProtocol/Protocol/Core.swift:294; …(+1) |
| `Response` | Protocol/Core.swift:291-315（25 行） | 0 | 0 | 2 | gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:218; gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift:226 |

信封整体 158 行（含 6 个类型及注释）；生产 0 引用，仅 `SessionContractTests` 的 6 个 JSON 往返用例使用。`Response` 本身无任何 proto 引用，其余 5 个的 proto 引用全部来自同组信封。

## 5. 二级死亡（上游删除后归零）

| 类型 | HEAD 位置 | 唯一上游 | 删除前 prod/proto/test | 测试证据 |
| --- | --- | --- | --- | --- |
| `BindingData` | Protocol/Face.swift:201-214 | `FaceCluster.binding` | 0/2/1 | gather-core/Tests/GatherCoreTests/Protocol/FaceContractTests.swift:129 |
| `MetadataMutationTarget` | Protocol/Metadata.swift:131-138 | `MetadataMutationRequest.target` | 0/2/2 | gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:121; gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift:138 |

## 6. 删除与测试改动汇总

### 6.1 Protocol 删除（按文件）

| 文件 | 删除类型数 | 行数（含注释） | 类型 |
| --- | ---: | ---: | --- |
| Protocol/Assets.swift | 3 | 30 | `AssetCandidateListParams`, `AssetCandidateMutationParams`, `AssetRelinkRootParams` |
| Protocol/Core.swift | 6 | 153 | `ResponseID`, `ErrorDetail`, `ResponseErrorBody`, `ResponseOk`, `ResponseErr`, `Response` |
| Protocol/Culling.swift | 19 | 206 | `CullingListPageParams`, `CullingUpdateParams`, `CullingHistoryParams`, `CullingHistoryApplyParams`, `CullingBatchUpdateParams`, `CullingDecideGroupParams`, `CullingSyncStatusParams`, `CullingFlushParams`, `CullingRetrySyncParams`, `CullingFinalizeSyncParams`, `CullingGroupsParams`, `CullingDecideParams`, `CullingBatchDecideParams`, `CullingSummaryParams`, `CullingWritebackParams`, `CullingRetryWritebackParams`, `CullingConfirmSyncParams`, `CullingCleanupParams`, `CullingResetParams` |
| Protocol/Duplicate.swift | 5 | 50 | `DupScanParams`, `DupGroupsParams`, `DupResolveParams`, `DupResolveMemberParams`, `DupScanOptions` |
| Protocol/Export.swift | 4 | 38 | `ExportPreviewParams`, `ExportExecuteParams`, `ExportCancelParams`, `ExportReportParams` |
| Protocol/Face.swift | 14 | 213 | `FkwAnalyzeParams`, `FkwBindParams`, `FkwUnbindParams`, `FkwMergeParams`, `FkwRemoveMemberParams`, `FkwPreviewParams`, `FkwWritebackParams`, `FkwConfirmSyncParams`, `FkwConfirmCleanupParams`, `FkwCleanupParams`, `FaceModelsStatusData`, `FaceObservation`, `BindingData`, `FaceCluster` |
| Protocol/Filter.swift | 7 | 72 | `FilterPhotosParams`, `FilterPhotosGlobalParams`, `FilterSuggestParams`, `AlbumListParams`, `AlbumGetParams`, `AlbumDeleteParams`, `AlbumGetPhotosParams` |
| Protocol/Indexer.swift | 1 | 10 | `IndexScanParams` |
| Protocol/Jobs.swift | 4 | 32 | `JobListParams`, `JobCancelParams`, `JobRetryParams`, `JobClearCompletedParams` |
| Protocol/Metadata.swift | 8 | 122 | `MetadataGetParams`, `MetadataSetParams`, `MetadataBatchSetParams`, `MetadataMutationTarget`, `MetadataMutationRequest`, `MetadataConflictListParams`, `MetadataConflictResolveParams`, `MetadataOrphanResolveParams` |
| Protocol/Navigation.swift | 1 | 8 | `NavigationListParams` |
| Protocol/Person.swift | 5 | 46 | `PersonListParams`, `PersonGetParams`, `PersonDeleteParams`, `PersonMergeParams`, `PersonRemovePhotoParams` |
| Protocol/Quality.swift | 1 | 10 | `QualityAnalyzeParams` |
| Protocol/Session.swift | 3 | 44 | `SessionCreateParams`, `SessionCreateFromDirectoryParams`, `SessionAddPhotosParams` |
| Protocol/Similarity.swift | 10 | 108 | `SimAnalyzeParams`, `SimCancelAnalysisParams`, `SimResultParams`, `SimReclusterParams`, `SimPreviewWritebackParams`, `SimWritebackParams`, `SimWritebackItemsParams`, `SimRetryFailedWritebackParams`, `SimConfirmSyncParams`, `SimCleanupParams` |
| Protocol/Template.swift | 4 | 34 | `TemplateListParams`, `TemplateGetParams`, `TemplateDeleteParams`, `TemplateApplyParams` |
| Protocol/Workspace.swift | 1 | 8 | `WorkspaceStatusParams` |
| **合计** | **96** | **1184** | |

### 6.2 ContractTests 改动（17 文件）

删除 68 个用例（用例体只构造被删 DTO）；改写 3 个混合用例，保留仍存活的类型断言：

| 文件 | 删除用例数 | 改写 |
| --- | ---: | --- |
| AssetsContractTests.swift | 3 | — |
| CullingContractTests.swift | 5 | `cullingUpdatePatchAndParamsRoundTrip` → `cullingUpdatePatchRoundTrip`（仅保留 `CullingUpdatePatch` 断言） |
| DuplicateContractTests.swift | 5 | — |
| ExportContractTests.swift | 4 | — |
| FaceContractTests.swift | 11 | — |
| FilterContractTests.swift | 4 | `albumGetUpdateDeleteParamsRoundTrip` → `albumUpdateParamsRoundTrip`（仅保留 `AlbumUpdateParams` 断言） |
| IndexerContractTests.swift | 1 | — |
| JobsContractTests.swift | 3 | `analysisJobTypeDecodesFromTSStrings`（删 `JobListParams`，保留 `AnalysisJobType` 解码） |
| MetadataContractTests.swift | 8 | — |
| NavigationContractTests.swift | 1 | — |
| PersonContractTests.swift | 3 | — |
| QualityContractTests.swift | 1 | — |
| SessionContractTests.swift | 9 | — |
| SimilarityContractTests.swift | 6 | — |
| TemplateContractTests.swift | 3 | — |
| WorkspaceContractTests.swift | 1 | — |
| **合计** | **68** | **3** |

### 6.3 保留的旧 `*Params`（13 个，均被 API 签名直接引用）

`SessionUpdateParams`、`PersonCreateParams`、`PersonUpdateParams`、`PersonSearchPhotosParams`、`AlbumCreateParams`、`AlbumUpdateParams`、`NavigationSplitParams`、`NavigationMergeParams`、`NavigationAnalyzeParams`、`JobCreateParams`、`QualityGetParams`、`TemplateCreateParams`、`TemplateUpdateParams`。

删除的 83 个 `*Params` 均不在任何 API 协议/Inputs 的签名中；它们与 6 个信封同属 Router 时代 JSON 契约面。`APIContractIndex.swift` 已记录 WP1 口径：新增输入必须放 `API/Inputs/`，不得复活旧 `*Params` 或 `Response*`。

## 7. 执行后复核

- `./scripts/check-protocol-surface.sh --strict`：`public_types=251`、`public_declarations=1,320`、`zero_reference_types=0`、`router_envelope_types=0`，exit 0；基线 `docs/protocol-surface-baseline.json`。
- core：`swift test ...` **1,060 tests / 159 suites**，exit 0（删除 68 例；套件数不变）。
- app：`swift test ... --no-parallel` **616 tests / 68 suites**，exit 0。
- 未改 app 源码、Package、其他 target、其他 docs；不 commit。

