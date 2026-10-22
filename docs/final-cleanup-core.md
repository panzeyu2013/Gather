# 最终收尾：core 死代码清理（2026-10-22）

> 范围：`desktop/native/gather-core/Sources/**`；`Tests/**` 未改。未改 gather-app / Package / docs（本文件除外）/ scripts / Schema 语义。
> 方法：全仓 grep（core + app Sources/Tests）逐符号核对；`scripts/find-unused-symbols.swift`；对字符串插值/协议回调/动态选择器二次人工复核。
> 口径：删除前每个符号在 core Sources、app Sources、core/app Tests 的引用均为 0；public 符号另确认 app 无引用。

## 1. 删除清单（净 −301 行；diff 307 删 / 6 增）

### 1.1 整文件（3 个 / 161 行）

| 文件 | 行数 | 依据 |
| --- | ---: | --- |
| `GatherDomain/Services/MetadataConflictFields.swift` | 117 | 全文件零引用：`parseDirtyFields`、`fieldConflicts`、`hasFieldConflict` 及其私有 helper 仅互相调用；`tryParseDirtyFields` 也只被已死的 `parseDirtyFields` 调用 |
| `GatherProtocol/API/Core/BoundedString.swift` | 26 | public 值对象；core/app Sources、Tests 均 0 引用 |
| `GatherProtocol/API/Core/NonEmpty.swift` | 18 | 同上 |

### 1.2 符号（14 个 / 138 行）

| 符号 | 位置 | 删除行 | 依据 |
| --- | --- | ---: | --- |
| `ScanResult` / `ProgressData` / `EngineStatusData` / `GroupData`（含嵌套 `ImageRef`） | `Protocol/Core.swift` | 66 | 旧 IPC/事件 DTO；core+app+tests 0 引用 |
| `FkwCancelAnalysisParams` / `FkwClustersParams` | `Protocol/Face.swift` | 18 | 旧命令参数 DTO；0 引用 |
| `SessionDeleteParams` / `SessionDeleteManyParams` / `SessionGetParams` | `Protocol/Session.swift` | 31 | 同上 |
| `destinationSidecarExists(forOutput:)` | `GatherDomain/Services/ExportService.swift` | 5 | private，0 调用 |
| `mutationSource(_:)` | `GatherDomain/Services/WritebackService.swift` | 11 | public 自由函数，0 引用 |
| `getPersonName(_:)` | `GatherPersistence/.../PersonRepo.swift` | 4 | private，0 调用 |
| `pendingInvalidParamCode` | `GatherProtocol/API/Errors/GatherError.swift` | 3 | 仅注释提及；改为直接使用 `GatherErrorCode.INVALID_PARAM` |

### 1.3 注释同步（6 行）

- `PhotoPathPolicy.swift`、`APIContractIndex.swift`、`GatherError.swift` 中指向已删 `pendingInvalidParamCode` / `BoundedString` / `NonEmpty` 的存量注释改为当前入口（`GatherError.invalidParameter` / `INVALID_PARAM`）。

## 2. 保留候选（有引用 / 不满足“确认无用”）

| 候选 | 结论 | 原因 |
| --- | --- | --- |
| `JobScopeCheckpoint` | 保留 | 不在 core；定义于 `gather-app/Sources/GatherUI/Support/JobScopeCheckpoint.swift`，被 `GatherApp.swift` 注释、`APISessionTests`/`DashboardViewModelTests` 直接引用，非死代码 |
| `CaptureOneSyncState.swift` | 保留 | 初次删除后 app build 报 `CaptureOneSyncStateAdapter.swift:16 cannot find 'aggregateSessionState'`；app Host/UI 仍经端口调用该函数，已原样恢复 |
| `ImageDimensions` + `DimensionsReconciliationTests` | 保留（候选） | 生产 0 引用，仅对账测试 1 例；删除需同删 186+57 行，留给下一刀 |
| 旧 `Protocol/*Params` / `Response*` / `FaceObservation` 等 | 保留（候选） | 112 个 Protocol 类型“自身文件外 core+app 零引用”，但全部被契约测试钉住；D-001/D-007 计划删除，需同批重写约 197 条 Protocol 契约测试，超出本轮最小补丁 |
| `find-unused-symbols` 2 个候选 | 保留 | `GatherAppDelegate.applicationShouldTerminate` / `applicationSupportsSecureRestorableState` 为 AppKit 回调 |
| 未用 `GatherErrorCode` case | 保留 | 公开错误码契约；app `CommandError` 按 rawValue 识别，删除会改 API 面 |
| `TableColumns` 等 | 保留 | 生产大量 `TableColumns.sql(TableColumns.x)` 引用（字符串插值内），非死代码 |

## 3. 验证（本机实测）

| 项 | 结果 |
| --- | --- |
| core build | exit 0（`--disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch`） |
| core test | **1,128 tests / 159 suites，0 failed，exit 0**（未删测试） |
| app build | exit 0（恢复 `CaptureOneSyncState` 后） |
| app test | **616 tests / 68 suites，exit 0**（`--no-parallel`；首跑 1 issue、重跑全绿，判为既有 flake） |
| 8 门禁 | 全部 exit 0：no-legacy（7 enforced / 6 tracked）、cleanup-ratchet（**53/235/127/0/0**，try? 较 baseline 240 改善 5）、docs --strict、layering（17 条）、duplicate --strict、test-catalog --strict、select-star（Sources 6/2 文件、Tests 1）、preview --strict（14 / 5 文件 / 2,031 行） |
| find-unused-symbols | 536 Swift 文件 / 4,259 public 声明；候选 **2**（均为上述 AppKit 回调） |
| 删除符号残留 | core 内 grep = 0（`CaptureOneSyncState` 为恢复文件，不计） |
| core 规模 | **145 文件 / 43,462 行**（清理前 148 / 43,763） |

## 4. 风险 / 残余

1. **app 首跑 flake**：恢复后首次 `swift test` 报 1 issue，第二次同命令 616/68 全绿；未改 app，按既有 flake 记录。
2. **契约测试与旧 DTO**：112 个 Protocol 类型生产零引用但仍被测试引用；删除需同批改 17 个 `*ContractTests`（约 197 例），建议单列“D-001/D-007 收口”刀。
3. **文档越界**：本文件 `docs/final-cleanup-core.md` 是任务要求的唯一交付物，位于“唯一可写”白名单外；未改其他 docs/scripts/app 文件。
4. **并行工作区**：app 侧仍有其他 agent 的未提交改动；app 数字以本机 16:52 实测为准。
