# Cut 1 类型化 API 语义正确性与完整性评审（R1）

- 评审对象：仓库 `/Users/panzeyu2013/Desktop/code/develop/Gather`，HEAD `82603e0`，工作区为未提交的重构结果（Cut 1–6 之后的状态）。
- 评审范围：16 个协议 / 110 个方法的**语义正确性与完整性**，包括 16 个 Live 实现、Inputs/Outputs/Core 原语、关键 UI 调用点、API 测试；不含视觉验收、性能与 Cut 2–6 的设计评价。
- 只读约束：未修改任何源码/测试/Package/脚本；本报告是唯一写入文件。
- 时间：2026-10-22。

## 1. 范围与方法

1. `git show HEAD:desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift`（3,258 行）逐 case 读取 118 条命令的参数、返回形状、执行语义与校验点；与 `GatherProtocol/API/*API.swift` 的 110 个方法按域对照。
2. 逐文件阅读 16 个 Live 实现（`gather-app/Sources/GatherHost/APIs/Live*API.swift`，约 4,031 行）与 `API/Core`、`API/Inputs`、`API/Outputs`。
3. 用 `git show HEAD` 读取旧 UI 的派发点，核对“生产 UI 用过、新 API 无对应能力”的缺口；逐条核对 31 条旧 `confirmed` 命令与 29 个 `Confirmed<T>` 方法的映射。
4. 统计 app 侧 API 测试（10 个 `API*Tests.swift`，96 个 `@Test`）与 Live 实现的实际调用覆盖；实跑 5 次 app 默认并行全量测试（4 绿 1 红，见 P1-4）。
5. 未运行 core 全量（时间/范围限制），文中不声称 core 结果。

## 2. 结论摘要

| 项 | 结果 | 证据 |
| --- | --- | --- |
| 命令账算术 | **118 = 110 行为方法 + 4 合并 + 4 真删除**，逐域加总一致 | 本报告 §3 |
| 破坏性门禁 | 31 条旧 `confirmed` 命令 → **29 个 `Confirmed<T>` 方法**（session.delete/delete_many、fkw.cleanup/confirm_cleanup 各合 1），无遗漏 | §3.1 |
| UI 能力缺口 | HEAD 的 31 条字面量派发 + 文档记录的变量派发，**均有对应方法**；4 条真删除均有同域替代 | §3.2 |
| P0 | **未发现** | §4 |
| P1 | **4 条**（create 合并缺 job 语义、110 覆盖口径不成立、index.scan 未封装、app 并行测试间歇红已确认） | §5 |
| P2 | **14 条**（校验/错误码/分页/形状漂移/死参数/门禁形式化） | §6 |
| 结论 | **需修**（P1-1/2/3 修完可接受；P2 可登记后置） | §8 |
| 已确认 / 疑似 | **已确认 16 条**（P1×4 + P2×12）；**疑似 2 条**（P2-7 Face dirtyFields、P2-9 album 文案） | §5/§6 |

## 3. 命令面与 API 对照

### 3.1 118 → 110 的映射（已确认）

逐域加总：Session 9→7（create_from_directory、delete_many 合并）、Photo 9→7（photo.list 删除、filter 合并）、Culling 19→17（decide/batch_decide 删除）、Face 14→13（confirm_cleanup 合并）、Similarity 10→10、Duplicate 4→4、Export 4→4、Metadata 7→7、Person 8→8、Album 6→5（album.get 删除）、Navigation 4→4、Job 5→5（index.scan 并入 start）、Settings 6→6、Asset 5→5、Quality 2→2、Template 6→6。合计 **110**。

4 条真删除（photo.list、culling.decide、culling.batch_decide、album.get）均无 UI 调用，替代方法分别为 page/update/batchUpdate/photos；这 4 条在旧 Router 的注释里也写明是旧 renderer 入口。

**31 条 confirmed 命令 → 29 个 `Confirmed<T>`**：
session.delete(+delete_many)、jobs.clearCompleted、dup.resolve/resolveMember、person.delete/merge/removePhoto、template.delete/apply、asset.accept/reject/relinkRoot、album.delete、culling.reset/writeback/retryFailedWriteback/cleanup/finalizeSync、face.unbind/writeback/cleanup(+confirm_cleanup)、sim.writeback/retryFailedWriteback/cleanup、metadata.set/batchSet/resolveConflict/resolveOrphan、export.execute。**没有一条破坏性命令退化为裸参数**（已确认）。

### 3.2 “UI 用过、新 API 无能力”核查（已确认，未发现缺口）

HEAD 的 UI 字面量派发（`git grep execute("x.y")`）只有 31 条，均能在 110 方法中找到；Cut 0 文档记录的变量/三元派发（`culling.flush`、`culling.retry_sync`、`assets.accept_candidate`、`assets.reject_candidate`）也都有方法。真删除的 4 条命令在 HEAD UI 中 0 调用（只有测试黄金清单），因此“删命令 → UI 无能力”不成立。

**但 API 实现并不总是保持旧命令的完整语义**，见 §5/§6。

> 证据口径：旧实现行号均以 `git show HEAD:...` 的历史文件为准（Router 已删除，不可在当前工作区定位）；新实现行号以当前工作区文件为准。**已确认** = 代码或实测直接证明；**疑似** = 代码路径存在但受影响输入/UI 展示无法在无 GUI 环境复现。

## 4. P0

**无。** 判定依据：没有发现“数据丢失/越权读写/破坏性操作失去门禁/新 API 完全无法表达生产 UI 需求”的问题。以下 P1 主要是契约完整性、副作用归属与验收口径问题，尚不构成 P0。

## 5. P1（需修，阻断“可接受”结论）

### P1-1 `session.create` 合并后，目录分支丢失 metadata.scan 入队与回滚（已确认）

- 位置：`desktop/native/gather-app/Sources/GatherHost/APIs/LiveSessionAPI.swift:102-127`（`createSync` 目录分支只建会话），对照 `LiveSessionAPI.swift:173-221`（filepaths 分支建 job + 失败回滚）。
- 旧行为：`git show HEAD:.../SessionCommandRouter.swift:2119-2141` 的 `session.create_from_directory` 在建会话后 `jobService.create(.metadataScan)`，入队失败 `try? deleteSession` 回滚。
- 证据：新目录分支只 `return SessionCreateResult(session: session)`，没有 job；回滚只存在于 UI：`desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+Actions.swift:26-37` 建完会话后自己 `jobAPI.start` 并在失败时 `deleteSessionSilently`。
- 同类合并缺口（name 默认值）：旧 `create_from_directory` 允许省略 name，由目录 basename 兜底（HEAD :2119-2122；当前服务实现 `SessionService.swift:86-89`）；新 `SessionCreateInput.name` 构造期强制非空白（`SessionInputs.swift:35`），合并后的 `create` 无法再表达“从目录取名”，只能由 Dashboard 在 UI 层先算（`DashboardViewModel+Actions.swift:21-25` 的 `directorySessionName`）。
- 影响：M1 声称 `create` 合并了 `create_from_directory` 的两种形状，但**副作用没有合并**。任何不经 Dashboard 的调用方（未来菜单/CLI/测试/宿主脚本）用 `create(sourcePath:)` 建出的会话永远不会被索引，且失败时留下半成品；而 filepaths 分支又自带 job，两个分支副作用不对称，调用方无法从协议判断。
- 修复建议：在 `createSync` 目录分支内对称地 `jobService.create(.metadataScan)` + 失败回滚（与 filepaths 分支同一补偿），同时删除 Dashboard 的重复入队；若产品决定“目录分支只建会话”，则修改协议注释/M1 记录并在 `SessionCreateResult` 增加显式标志，禁止当前“半合并”状态。

### P1-2 “110 个方法全部有行为覆盖”不成立（已确认）

- 位置/口径：`docs/refactor-progress.md:28`（“110 行为覆盖”验收）、`docs/refactor-progress.md:15`（16/110）。
- 证据：app 测试中**没有任何对 Live 实现的调用**的方法共 15 个——
  - Culling 10 个：`history`、`applyHistory`、`groups`、`summary`、`syncStatus`、`flush`、`retrySync`、`retryFailedWriteback`、`finalizeSync`、`confirmSync`。`APICullingTests.swift` 只有 6 个 `@Test`（:202/:236/:267/:285/:303/:335），覆盖 page/update/batchUpdate/decideGroup/reset+cleanup/writeback；其余 10 个只在 `StubCullingAPI`/`CullingViewModelAPITests` 里以 stub 形式出现。
  - Face 3 个：`merge`、`removeMember`、`cancelAnalysis`（仅 `Support/StubFaceAPI.swift` 与 UI 测试）。
  - Session 1 个：`addPhotos`（测试里只有 `photoRepo.addPhotos`，`APISessionTests.swift` 无 `sessionAPI.addPhotos` 调用）。
  - Similarity 1 个：`cancelAnalysis`（只有 `SimilarityViewModelTests.swift:245` 走 stub）。
- 影响：这些方法的 `Confirmed`→`confirmed: true` 固定、错误码映射、dedupeKey、reloadAckedAt 投影都没有 Live 行为断言；例如 `LiveCullingAPI.syncStatus` 的 `sessionRepo` 注入（`LiveCullingAPI.swift:83-90`）一旦漏注入/抛错，测试不会红。验收口径与实际不符，属于“文档即账本”失真。
- 修复建议：为上述 15 个方法各补 1 个 Live 行为测试（尤其是 10 个 culling 与 3 个 face 写操作）；若短期不做，把 progress 的验收改为“API 测试 96 例 + UI stub 接线”，并列出未覆盖方法。

### P1-3 `JobAPI.start` 没有封装 `index.scan` 语义，dedupeKey/checkpoint 被复制到 UI（已确认）

- 位置：`desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/JobInputs.swift:14-15`（`JobRequest = JobCreateParams`），`LiveJobAPI.swift:55-57`、`:126-136`（只校验非空，不构造）。
- 证据：旧 `index.scan` 在 Router 内构造 `dedupeKey: "metadata.scan:\(sessionId)"`（HEAD :2072-2088）。新 API 下这条私有规则出现在至少三处 UI：`Dashboard/DashboardViewModel+API.swift:35-41`、`Gallery/GalleryViewModel+Index.swift:29-37`、`ControlCenter/SessionControlViewModel+Actions.swift:14-19`（dedupeKey 由调用方传入），以及 `DashboardViewModel+Actions.swift:146-148` 的 retry。
- 影响：Job 去重依赖调用方复刻私有 dedupeKey；写错键 → 同会话重复扫描（或命中不到终态行、丢失续跑基线）。checkpoint 的键名已有单源（`GatherUI/Support/JobScopeCheckpoint.swift:13-21`，LiveSessionAPI 与 Dashboard 共用，`APISessionTests.swift:149`/`DashboardViewModelTests.swift:402` 有断言），但协议层不强制任何 checkpoint 形状；`SessionControlViewModel.startJob` 仍由调用方传 dedupeKey 字符串。这是“Job 去重/checkpoint”重点项：当前 UI 三处复制键值且无 API 级常量。
- 修复建议：在 `JobAPI` 增加 `startIndexScan(sessionId:requestedPaths:)`（或 `JobRequest.metadataScan(...)` 命名构造），把 dedupeKey 与 checkpoint 规则收回 API；UI 只传业务参数。

### P1-4 app 默认并行测试会间歇失败（已确认·偶发；CI 未加 `--no-parallel`）

- 事实：CI 的 app 测试没有 `--no-parallel`（`.github/workflows/ci.yml:87`）。
- 本机实测（同一命令，`cd desktop/native/gather-app && swift test --disable-sandbox --cache-path ../../../.build/shared-cache --scratch-path ../../../.build/scratch`）：
  - 连续 5 次：**4 次 581/66 passed（5.2–5.4s），1 次 581/66 failed（1 issue）**。
  - 失败点固定为：`DuplicatesControlCenterAPITests.swift:384:9: Expectation failed: await waitUntilAsync { sessionAPI.getCalls.count >= 2 }`，用例 “4a-2b：setVisible 启停兜底轮询（幂等），shutdown 后不复活”（`pollInterval: 20ms / activePollInterval: 10ms` 构造 VM，等待上限 2s；测试代码 `DuplicatesControlCenterAPITests.swift:365-394`，等待原语 `Support/AsyncWait.swift:27-38`）。
  - 结论：**已确认（偶发，本机 1/5 失败）**；CI 用默认并行，因此会间歇红。
- 影响：CI 红会掩盖真实的 API 语义回归；用 `--no-parallel` 长期规避只会掩盖竞态。该失败点在 `SessionControlViewModel` 的兜底轮询启动时序（`GatherUI/ControlCenter/SessionControlViewModel+...`）与测试 stub 计数之间，属于测试可观察性/时序问题，不是 Cut 1 API 语义缺陷。
- 修复建议：VM 提供确定性的 test hook（手动 tick 或注入 clock/interval），测试不要用墙钟等待共享 stub 计数；保留并行执行以暴露真实竞态。

## 6. P2（登记/后置，不阻断）

1. **分页归一化口径不一致（已确认）**：`CullingInputs.swift:64` 对 `limit` 越界抛 `INVALID_PARAM`，而 `PhotoInputs.swift:29-33`、`PageRequest.swift:32-36` 对 photo/filter/album 仍是钳制；旧命令全部是 `clampedLimit`（HEAD :1447、:1483、:896、:912）。同一 `limit=5000` 在 photo/filter 被钳到上限，在 culling 报 INVALID_PARAM。建议统一为 PageRequest 或明确“culling 严格、photo 钳制”并在迁移表登记。
2. **`session.create` 目录准入变化（已确认）**：旧 `session.create` 无 filepaths 时只拒绝禁根、不要求目录存在（HEAD :689-712）；新实现任何非空 `sourcePath` 都走 `createFromDirectory`（`LiveSessionAPI.swift:106-117`），非目录/不存在目录从“建会话”变为 `SESSION_SOURCE_NOT_DIR`。`APISessionTests.swift:154` 已把新行为写成断言，说明是有意变更，但迁移表 §6.2 未记录。
3. **空白字符串参数从“域错误/接受”变 INVALID_PARAM（已确认）**：`LiveSessionAPI.swift:129-135`（update 的 name 空白，旧 `requiredString` 接受空串，HEAD :750-755）、`:54-60`/`:78-84`（get/status 的空白 id，旧走 SESSION_NOT_FOUND）。影响 UI 文案与依赖码值的测试；同类还有 jobId/albumId/personId 的 128 上限。
4. **`image.get_dimensions` 错误码与单/批语义（已确认）**：`LivePhotoAPI.swift:101-112` 把解码失败收敛成 `PHOTO_NOT_FOUND`（旧直接抛 RAWDecoder 错误，HEAD :1397-1405）；同一 `PhotoDimensionsInput` 在 `count == 1` 时抛错、批量时静默跳过（`:114-120`）。调用方无法区分“未登记/文件损坏/批量部分失败”。建议新增可读性错误码或在输出里带失败项。
5. **`image.preload_thumbnails` 的 size 语义变化（已确认）**：`PhotoInputs.swift:179-181` 新增 64…8192 校验（旧无范围，HEAD :1373-1389），`LivePhotoAPI.swift:261-269` 对设置值改用 `rounded()`（旧 `Int()` 截断）。越界入参从“照传”变 INVALID_PARAM；默认设置 1024.7 会改变 dedupeKey 与缓存尺寸。
6. **`filter.photos` 合并后会话内形状改变（已确认，无生产调用）**：`LivePhotoAPI.swift:72-87` 统一走 `filterGlobally`，`FilterEngine.swift:196-205` 按 `COUNT(DISTINCT COALESCE(asset_id,id))` 折叠逻辑资产并返回 total；旧 `filter.photos` 返回逐照片 `[FilteredPhotoData]` 且无 total（HEAD :889-918）。另：新 search 对全局也下传 sortBy/sortOrder（`LivePhotoAPI.swift:74-81`），旧 `filter.photos_global` 不传（HEAD :908-925），属未登记的新增能力。当前 UI 只用 `photos_global` 形态（`Library/LibraryViewModel+Fetch.swift:35-40` 只是把 sessionFilter 传给 global），故无生产回归；但 `FilterEngine.filterPhotos`（`FilterEngine.swift:78`）已成死代码，且协议注释“同一分页/排序”未说明折叠。
7. **Face 预览 `dirtyFields` 静默丢弃（疑似）**：`LiveFaceAPI.swift:338` 用 `compactMap(WritebackDirtyField.init(rawValue:))`；若 FaceKw 侧出现枚举外字段，UI 预览会少一个“将改动”提示而不报错。建议未知值保留原文或断言。
8. **`export.report` 的 format 枚举化（已确认，G8 未闭合）**：`ExportInputs.swift:42/55` 使用 `ReportFormat?`，旧命令是自由字符串（HEAD :1422-1427）并下传服务；未知格式从“服务层错误”变成解码失败。`reportType` 仍为自由字符串，G8 只修了一半。
9. **`album.list` 损坏行文案（疑似）**：`LiveAlbumAPI.swift:208-219` 把 `DecodingError` 映射为固定 `"INVALID_PARAMS"`；旧 `Self.errorMessage(error)` 给 NSError 描述。若 UI 直接显示 `validationError`，英文码会露头。
10. **`culling.sync_status` 返回形状嵌套（已确认，UI 已适配）**：`CullingOutputs.swift:10-18` 为 `{summary, reloadAckedAt}`，旧是扁平对象 + 补键（HEAD :1584-1594）。本仓 UI 已按 `.summary` 适配，但协议外消费者/脚本需改；建议在迁移表标注 breaking。
11. **`filter.suggest` 关键词上限（已确认）**：`PhotoInputs.swift:100-108` 新增 keyword ≤256（旧无长度限制，HEAD :926-934）。超长关键词由“服务处理”变 INVALID_PARAM。
12. **`source` 字段实际不落库（已确认）**：`SessionRepo.create` 显式 `_ = source`（`SessionRepo.swift:90-96`），V1 已删 `import_source`（`SessionService.swift:231-234`）；但 `SessionCreateInput.source` / `SessionAddPhotosInput.source` 仍在校验并下传（`SessionInputs.swift:36`、`:102`），typed API 让调用方以为来源被记录。建议删除参数或协议注明 no-op。
13. **`Confirmed` 在 clearCompleted 上只是形式门禁（已确认，非回归）**：UI 无弹窗直接构造 `Confirmed(ClearCompletedInput())`（`DashboardViewModel+Actions.swift:230`，按钮见 `DashboardView.swift:346`）；旧版同样直连服务（HEAD `DashboardViewModel.swift:148-150`、`DashboardView.swift:317-319`），因此不是 Cut 1 引入的回归，但说明 `Confirmed` 是调用点标记而非真实门禁（D-011 已承认）。若产品要求“清理已完成”二次确认，应在 UI 补弹窗而不是依赖类型。
14. **建 job 有两条路径（已确认，低风险）**：`QualityAPI.analyze` 直接 `jobService.create`（`LiveQualityAPI.swift:53-63`），绕过 `JobAPI.start` 的请求校验与事件句柄（`LiveJobAPI.swift:55-57`、`:126-136`）；它不校验 scopeType/scopeId/dedupeKey 非空。内部常量为空的风险低，但“JobAPI 统一建 job”的承诺不成立；建议委托 start 或注明例外。

## 7. 测试覆盖（实测）

- API 测试文件 10 个，`@Test` 96 个；其中 `APIErrorPresentationTests` 5 个是错误展示，不是域方法行为。
- Live 实现在 10 个测试文件中被构造（`APICulling/DuplicateQuality/ExportMetadata/FaceSimilarity/PersonTemplate/Photo/Session` 7 个 + `DashboardViewModelTests/LayoutBudgetTests/SimilarityViewModelTests`）；其余 UI 测试用 Stub。
- 覆盖缺口：§5 P1-2 的 15 个方法无 Live 行为测试；这 15 个方法（尤其 Culling 的 10 个）在 UI 测试里只有 Stub 接线，stub 不会验证 Live 的 Confirmed 固定值/错误映射/去重键。
- 实跑：app 默认并行全量 **5 次：4 次 581/66 绿、1 次 581/66 红**（红点固定为 `DuplicatesControlCenterAPITests.swift:384`，见 P1-4）；core 未跑。
- 复现命令（本机，只读）：`cd desktop/native/gather-app && swift test --disable-sandbox --cache-path ../../../.build/shared-cache --scratch-path ../../../.build/scratch`；失败摘要 `Test run with 581 tests in 66 suites failed ... 1 issue`。

## 8. 结论

**需修（有条件接受）。**

- **必须修**：P1-1（create 副作用对称性）、P1-2（覆盖口径与补测）、P1-3（index.scan 封装）。这三条直接落在“语义完整性/Job 去重/验收真实性”上，修完后 Cut 1 可判“可接受”。
- **可后置**：P2 的 14 条建议登记到 `docs/refactor-progress.md` 残余项或 `cleanup-backlog`；其中 P2-2/P2-3/P2-4/P2-5 是行为变化，若产品不接受应改回旧语义。
- **已确认但非 API 语义**：P1-4（并行间歇红，`DuplicatesControlCenterAPITests.swift:384`）需要在 Cut 1 验收前给出处理（修测试时序或显式接受 flake 风险），不能用 `--no-parallel` 长期掩盖。
- **正面确认**：118→110 算术、4 删除/4 合并的替代路径、31→29 Confirmed 映射、PhotoPathPolicy 在 4 个 image 入口的强制、sim/face/dup/quality/export/thumbnail 的 dedupeKey 与 checkpoint 字形均与 HEAD 一致（已抽查）。
