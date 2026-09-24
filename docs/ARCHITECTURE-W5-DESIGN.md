# W5 设计：类型化 async API（删除 SessionCommandRouter）

> 来源：只读设计子代理 `f1f57a79`。基线 HEAD `d7b3e11`。118 distinct 命令 / 128 case（sync switch 22 / async switch 106，含 2 个重复死分支）。

## 0. 关键结论
1. **118 → 111 命令**：建议弃用 7 个真死命令——`image.get_dimensions/preload_previews/preprioritize_thumbnail/preload_thumbnails`（全仓 0 调用，`PhotoThumbnailView` 直连 RAWDecoder）、`photo.list`、`culling.decide`、`culling.batch_decide`。
2. **系统性缺陷（本轮新发现）**：**50 处同步 `execute()` 调用命中只存在于 async switch 的命令 → 运行时 NOT_IMPLEMENTED**（生产 49 + 测试 1），分布 9 个文件：Culling 24 / Settings 6 / ControlCenter 6 / FaceKw 5 / Duplicates 4 / Export 2 / SimilarityVM 1 / C1StatusCapsule 1 / 测试 1（任务书只点名 CullingView，实为系统性）。**async-only typed API 结构性修复**。
3. `awaitSync` 生产仅剩 1 条可达路径（`CullingView:591 metadata.conflicts`）；typed API 无同步入口后 baseline 2→0。
4. **`fkw.unbind` 重复 case 更正**（证实 W2d #10）：两个分支**都要求 clusterId**；唯一差异是非法/缺失时错误码 `MISSING_PARAM:clusterId`（活 L1521）vs `INVALID_PARAM:clusterId`（死 L2080）。`export.preview` 两分支错误码相同。→ 计划文档中「存活版不校验 clusterId」的旧记录已过期。
5. **Services 删除被路由阻塞**：W5 删路由与 W2 删 Services 必须在**同一合并单元**收口。

## 1. 形态
- 18 个域子协议（Settings/Session/Photo/Jobs/Workspace/Quality/Navigation/Similarity/Duplicate/Face/Person/Template/Metadata/Export/Assets/Album/Filter/Index）+ `GatherCoreAPI` 组合根（原 `makeDefault` 365 行装配整体迁 core）。
- 全部方法 `async throws`、只用 `Protocol/` DTO、**无同步重载**（`awaitSync` 归零的结构保证）；破坏性命令 `confirmed` 显式入参 + 实现内校验。
- `GatherError = { payload: .code(GatherErrorCode,[params]) | .message(String); rawMessage 逐字 }`；`GatherErrorMapper` 单点映射（`CULLING_REVISION_CONFLICT::e::c`、`FILTER_FIELD_UNKNOWN::f`、`SQLiteFailure→.message`、`DecodingError→INVALID_PARAMS`）；app 唯一出口 `GatherErrorMessage.text(for:)`（替换 `NativeCommandClient.message(for:)` 50 处）。
- keyset 分页：`PageRequest{limit,after}` + `KeysetPageResult{items,nextCursor,total}`；`CullingPage` 原地 conformance；新增 `PhotoAssetPage`。
- Job 事件：`JobsAPI.events: AsyncStream<JobProgressEvent>`。
- CaptureOneBridge 去掉 `as? SessionCommandRouter` 强转改注入 `recordReloadAck` 闭包；`FaceKwWritebackBridge` 建议迁 core。

## 2. 迁移 8 步（每步可编译）
W5-0 冻结接口 → W5-1 Protocol 新增/搬迁（`SimilarityResult`、`FaceAnalysisResult`、`FaceClusterData`、`FkwUnbindResult`、`AssetRelinkRootResult` 等由 Services 迁入；新增 `Protocol/Photo.swift`、`Protocol/Pagination.swift`）→ W5-2 API 新增+测试（双轨）→ W5-3 app 错误出口替换 → W5-4a..4i 逐域切换（Settings+Jobs+Workspace → Session+Import → Library → Person → Gallery+Photo → Similarity → Duplicates+Navigation+Quality+Index → FaceKeywording → Culling）→ W5-5 CaptureOneBridge/导入/事件 → **W5-6 删除 6 文件**（`SessionCommandRouter`/`CommandRouter`/`NativeCommandClient`/`JSONValueDecoding`/`StubCommandRouter`/`NativeCommandClientTests`，与 W2 删 Services 同批）→ W5-7 门禁 → W5-8 文档。

## 3. 测试与验收
- app：`StubCommandRouter` → `StubGatherAPI`（编译器即黄金列表：必须实现全部 111 方法）；4 个 makeDefault 集成套件 → `GatherCoreAPI.open`；`NativeCommandClientTests` 断言迁 `GatherErrorMapperTests`。
- core 新增：18 域端到端、错误码逐字表（含 `CULLING_REVISION_CONFLICT::3::5`）、keyset 游标（末页 nil/边界/空页带游标）、破坏性门控表（约 25 方法）、编译期黄金列表。
- 验收：双包 0 error；app 172/19；core ≥ 基线；门禁 `SessionCommandRouter 17→0`、`awaitSync 2→0`、`StubCommandRouter 7→0` **转 enforced**；新增 enforced：app 无 `WebResponse`/`CommandRouter`/`NativeCommandClient`/`JSONValueDecoding`/`RouterCommandError`/`NativeCommandError`/`BridgeError`、无 `.execute(`。

## 4. 待裁决（14 项，摘要）
协议命名；组合根迁 core（XMPProvider 由 app 注入）；7 弃用清单；**W5 前置需 W2b/c/d/W3/W4 冻结 Runtime public 面**；Job 事件归属；错误码 `MISSING_PARAM`/`INVALID_PARAM` 是否只留映射兼容表；非码值英文消息去留；SettingsView 同步写改 async 范围；**CullingView 24 处同步→async 是 R5 直接改（建议）还是留 R6**；`photo.list_page` DTO 与 `GalleryPhotoData` 对齐；keyset 统一深度；`SettingsSnapshot` 去留；core 测试基线以 HEAD 948/131 或实施时点重冻；R7 联动（FaceCluster 重复类型、thumbnailBuild、image.* 附属服务）。