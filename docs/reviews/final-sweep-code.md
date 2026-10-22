# P1/P2 收口后代码残余最终清扫（只读）

- 仓库：`/Users/panzeyu2013/Desktop/code/develop/Gather`；审计起点 HEAD `ab7752e`（开始时干净；审计期间并行 agent 产生未提交改动，非本 agent 所改；行号以 HEAD 为准）。
- 方法：只读静态审计；**未运行 build / test / 门禁**，未改源码、测试、Package、脚本；唯一写入本文件。
- 证据口径：行号以 HEAD 为准；【已确认】= 有 file:line 或 grep 计数；【疑似】= 结构/命名推断，未做行为验证。

## 0. 结论

**P0：无。** 未发现新增的数据丢失、越权写、交付状态机旁路或编译级破坏。

**P1：2 条。** 都是“收口口径未完全兑现”，不是新功能缺陷：
1. `GatherDelivery/Writeback/WritebackService.swift` 仍 **1,472 行**；按既有“>1000 行=P1”口径，这是当前唯一 >1000 的 Application/UI/Delivery 文件，且 WP5“单文件 ≤800”未覆盖 Delivery。
2. Application 已无具体 Repo 属性/参数，但仍**静态引用具体 Persistence 类型**（`AssetRepo.rawExtensions`、`PhotoFilterQuery.simpleFields/metadataFields`），且 `WhereClauseResult.params` 公开泄漏 `DBValue`；依赖倒置只到“端口注入”一层。

**P2：10 组**，集中在：StateWriter 唯一写 owner 只有事实约束、Delivery 内联 SQL、`markWriting` deprecated public、`GatherProgressBar.width` 零调用、`translate` 6 份、`FileSystemDeliveryFilePort` 生产 0、旧模块名注释、TestSupport 测试替身重复、台账数字漂移、唯一 TODO。

**通过项：** Application 具体 Repo 属性/参数 0；Host 无 DeliveryRepo 写调用；StateWriter 是生产写调用的唯一落点；`orderedUnion/parseBbox/patchFields/toFaceKw/toWriteback` 均已收敛；旧文件头 0/639 错配；TestSupport 已合并；Ports 27 个协议均有 `any` 注入点，无死协议。

## 1. P1

### P1-1 Delivery 仍有 1,472 行单文件；>1000 行未清零

【已确认】`find … | xargs wc -l` 实测：

| 文件 | 行数 | 说明 |
| --- | ---: | --- |
| `gather-core/Sources/GatherDelivery/Writeback/WritebackService.swift` | **1,472** | Delivery 写回主执行器；preview/execute/retry/cleanup/租约/关键词合并都在此 |
| `gather-core/Sources/GatherDelivery/Coordinator/DeliveryCleanupFlow.swift` | **825** | >800，但 <1000（P2） |
| `gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures.swift` | **964** | >800，但 <1000（P2） |

- Application 侧已收口：最大 `Indexer/IndexerService+Scan.swift` 767、`MetadataService.swift` 739、`FaceKwService+Clusters.swift` 711；无 >800。
- >1000 全量清单（含其他模块）：`DeliveryRepo.swift` 1,546、`WritebackService.swift` 1,472、`AssetRepo.swift` 1,217、`FaceRepo.swift` 1,194、`GatherAnalysis/Similarity/ClusterGraph.swift` 1,119。
- 邻域提示：`GatherHost/SidecarXMPProvider.swift` 916 也 >800，但不在本次 Application/UI/Delivery 范围内。
- 影响：WritebackService 同时承担计划、执行、租约、镜像、关键词合并；1.5k 行使回归面与审阅成本偏高，和“单文件 ≤800 / >1000=0”的整改口径不一致。
- 建议：先做纯移动拆分（不改方法体/事务边界）：`WritebackPlan`（preview/计划）、`WritebackExecutor`（execute/租约循环）、`WritebackKeywords`（合并/持久化）、`WritebackDiagnostics`（trace/错误映射）；目标 ≤800。DeliveryCleanupFlow 按 file/db 两段拆；PreviewFixtures 按页面拆。

### P1-2 Application 仍静态引用具体 Persistence 类型（口径级；运行时风险低，若只看功能可降 P2）

【已确认】具体 Repo 属性/参数为 **0**：

- `CullingService.swift:84-98`、`FaceKwService.swift:79-87`、`SimilarityService.swift:150-158`、`IndexerService.swift:94-104` 等全部是 `any XxxRepository`。
- `grep -rnE '(let|var) \w+: (PhotoRepo|AssetRepo|…)' Sources/GatherApplication` = 0。
- `Application` 内 `DBConnection` / `.prepare(` = 0（`services_prepare` 已闭环）。

【已确认】仍越界的静态具体类型：

1. `GatherApplication/Services/Export/ExportService+Plan.swift:402`：`let rawExtensions = AssetRepo.rawExtensions`（具体 Persistence Repo 的 static）。
2. `GatherApplication/Services/PhotoAssets.swift:13`：`public static let rawExtensions: Set<String> = AssetRepo.rawExtensions`；该属性生产 0 引用，仅测试 `PhotoFileTypesTests.swift:32`、`FilterEngineTests.swift:301` 钉住。
3. `GatherApplication/Services/FilterEngine.swift:47/49`：`FilterEngine.simpleFields / metadataFields = PhotoFilterQuery.simpleFields / metadataFields`；两个 public static 全仓 **0 调用点**，且 `PhotoFilterQuery` 是 Persistence 具体类。
4. `GatherApplication/Services/FilterEngine.swift:15-21`：`public struct WhereClauseResult { public let params: [DBValue] }`，Application 公共 API 直接暴露 Persistence 的 `DBValue`；Host `LiveAlbumAPI.swift:40/59/83` 只用它做校验、丢弃返回值。
5. 同类但更大的面：`GatherApplication/Services/MetadataService.swift:47` 的 `public typealias MetadataPhotoLookup = PhotoLookupRow`，以及 Culling/Face/Export 中大量 `PhotoProjectionRow/DeliveryItemRow` 行类型（既有设计，未单列为 P1）。

- 影响：这不是运行时缺陷，但说明“Application 只经端口看 Persistence”在编译面不成立：Application 仍可触达具体 Repo/查询类。`FilterEngine` 的两个 static 还是死 API。
- 建议：`rawExtensions` 统一改读 Protocol 的 `PhotoFileTypes.rawExtensions`（`PhotoFileTypes.swift:22`，已是真相源），删除 `PhotoAssets.rawExtensions` 别名并改两条测试；删除 `FilterEngine.simpleFields/metadataFields`；`WhereClauseResult` 改 internal/改为 `buildWhereClause` 只返回 `Void` 校验，或把该 DTO 移回 Persistence。

## 2. P2

### P2-1 StateWriter 是“事实唯一写 owner”，不是“编译期唯一”

【已确认】生产写调用只落在 `GatherDelivery/Coordinator/DeliveryStateWriter.swift:48-472`：`createOrGet/mergeInput/claimWriting/renewWriting/markWritten/markFailed/markConflict/confirm/linkSession/upsertItem/markItem/deleteItems/updateItem*/applyMetadataMutation/resetConfirmations/deleteSyncedDelivery*/…` 均只在该文件内调用。
【已确认】Host `LiveMetadataAPI.swift` 只在 `:185/:215/:240/:373/:402` 调 5 个 public 语义入口（`reopenConflict/retryOrphan/deleteOrphanDelivery/persistAcceptedRemoteFields/acceptExternalState`）；其余 `deliveryRepo` 使用全是读：`:103-104/:154-159/:194/:204/:420/:438/:448`。
【已确认】`DeliveryStateWriter` 只有 5 个 public 方法：`:319/:357/:388/:413/:422`；其余 20 个 internal。

残余：
- `DeliveryRepo` 的 23 个写方法仍是 `public`（`DeliveryRepo.swift:344-1407`），`DeliveryStateWriter.init(repo: DeliveryRepo)` 接收具体类型；Host 也持有 `DeliveryRepo`（`LiveMetadataAPI.swift:66/80/86`，只读用途）。因此“绕过 writer”在编译期仍可行，只是当前代码没这么做。
- `DeliveryRepo` 的 `markWriting` 已被标 deprecated（见 P2-2），但其余写方法没有降权。
- 建议：在 Persistence 增加最小 `DeliveryWriting` 协议（只暴露 writer 需要的迁移），`DeliveryRepo` 写方法降 internal；Host 只拿 `DeliveryStateWriter`，不拿 `DeliveryRepo`（读路径另给窄读端口）。

### P2-2 Delivery 仍有 2 处内联 sessions SQL（一处写）

【已确认】：
- `GatherDelivery/Writeback/WritebackService.swift:579-590`：`SELECT ds.session_id … JOIN delivery_sessions`，随后 `UPDATE sessions SET reload_acked_at = NULL`；写 `sessions` 的点不在 StateWriter 内。
- `GatherDelivery/Coordinator/DeliveryCoordinator.swift:396`（HEAD；当前工作区并行改动后为 399）：`SELECT reload_acked_at FROM sessions WHERE id = ?`。
- 两处注释都解释了原因（`SessionRepo` 投影仍带 legacy 列），但仍是 Delivery 直接持有 SQL/连接、绕过 `SessionRepository` 的残余。
- 建议：在 Persistence 增加 `SessionAckReading/Writing` 窄端口（单列读写），Delivery 只调端口；保持现有错误语义与事务边界。

### P2-3 markWriting 仍 deprecated public；测试数字漂移

【已确认】`DeliveryRepo.swift:342-344`：`@available(*, deprecated, message: "生产已无调用；请使用 claimWriting…")`。
- 生产调用：0（仅声明命中）。
- `gather-app/Tests`：**8** 处，`APIExportMetadataTests.swift` 6、`APICullingTests.swift` 2。
- `gather-core/Tests`：**33** 处，集中在 `DeliveryRepoTests.swift` 16、`WritebackServiceTests.swift` 4、`DeliveryCoordinatorTests.swift` 4、`CullingServiceTests.swift` 4。
- `architecture-remediation-status.md:55` 写“app 12 处跨包测试直调”，实测 8；同处还写“CullingService+Delivery 仍有一处内联并集未去重”，但 HEAD `cdf3962` 已在 `CullingService+Delivery.swift:122` 改用 `orderedUnion`，该句已过期。
- 建议：测试统一改用 `claimWriting(leaseOwner: "test")` 或 `GatherTestSupport` 的构造 helper，再删 deprecated API；同步修正 status 的 8/12 与内联并集表述。

### P2-4 GatherProgressBar.width 零调用

【已确认】`GatherUI/Support/GatherCommonViews.swift:104` 声明 `public var width: CGFloat? = nil`，`:111` init 参数，`:134` `.frame(width: width)`。
- 全仓 `GatherProgressBar` 只有 3 处命中：定义、`Dashboard/JobRowView.swift:92` 注释、`:95` 唯一调用点；唯一调用只传 `fraction/fill/label/accessibilityText`，无 `width:`。
- A03 的另外 3 个废弃参数（track/border/height/cornerRadius）已删除，只剩 width。
- 建议：删 `width` 属性/参数/帧修饰；或若产品要保留可配置宽度，补一个真实调用点与预览。

### P2-5 translate 仍有 6 份同形实现

【已确认】6 个 `private static func translate(_ error: Error)`：
- `GatherHost/APIs/LiveDuplicateAPI.swift:133`
- `GatherHost/APIs/LiveFaceAPI.swift:267`
- `GatherHost/APIs/LiveSimilarityAPI.swift:264`
- `GatherHost/APIs/LiveTemplateAPI.swift:145`
- `GatherHost/APIs/LiveQualityAPI.swift:124`
- `GatherHost/APIs/LiveExportAPI.swift:179`

共同臂都是 `LiveAPIErrorMapping.translateCommon(error)`，之后各自映射域错误；B05-5 原为 7 份，现少 1 份，但公共臂未抽。
- 已完成：`orderedUnion` 唯一实现 `Persistence/Support/OrderedUnion.swift:12`（Application/Delivery/Host 共 8 个调用点）；`parseBbox` 唯一实现 `BBoxParsing.swift:13`；`patchFields` 全仓 0 命中（已收敛为 `CullingUpdatePatch.fields`，`Protocol/Culling.swift:268`）；`toFaceKwItem/toWritebackItem` 只在 `GatherHost/FaceKwWritebackBridge.swift:87/122` 一份，`LiveFaceAPI` 复用。
- 建议：`LiveAPIErrorMapping` 增 `translateDomain(_:)` 抽公共臂，6 个 API 只留域分支；先补表驱动等价测试再动。

### P2-6 FileSystemDeliveryFilePort 生产 0 引用

【已确认】`GatherDelivery/Types/DeliveryTypes.swift:278` 仍定义 public `FileSystemDeliveryFilePort: DeliveryFilePort`。
- 生产构造 0；全仓 6 处引用 = 定义 1 + 注释 1 + 测试 4（`CullingServiceTests.swift:1535`、`GatherTestSupport/ServiceConstructionTestSupport.swift:182/255/296`）。
- B08 原为“生产 0 / 测试 7”，现为“生产 0 / 测试 4”；仍是测试专用 seam。
- 建议：测试改用 `XMPDeliveryFilePort` 或测试内 fake，再删类型；若保留，明确标 test-only 并移出 public 面。

### P2-7 旧模块名注释：GatherDomain 25 处 / GatherCore 16 处

【已确认】`GatherDomain` 在 `desktop/native/**/*.swift` 命中 25 行（含 `Package.swift` 与测试）。其中 6 处仍把旧路径当现状：
- `GatherHost/CaptureOneSyncStateAdapter.swift:5`
- `GatherHost/ImportPathRulesAdapter.swift:6`
- `GatherUI/Settings/SettingsViewModel+Catalog.swift:56`
- `GatherUI/Support/CaptureOneSyncStatePort.swift:5`
- `GatherUI/Dashboard/DashboardViewModel+Actions.swift:62`
- `gather-app/Tests/GatherAppTests/SimilarityViewModelTests.swift:99`

其余 19 处是“WP3a 从 GatherDomain 改名 / 不能 import GatherDomain”等历史说明，可保留；建议统一写成“旧模块名 GatherDomain”，避免被当成现存路径。
【已确认】`GatherCore` 仍有 16 处（含 Package/测试），其中 8 处属“把旧模块当现状”：`GatherUI/Dashboard/DashboardView.swift:2`、`GatherUI/Dashboard/DashboardViewModel.swift:2`、`GalleryView.swift:2`、`LibraryView.swift:2`、`SimilarityView.swift:2`（“宿主内直连 GatherCore”，但 UI 只 import Protocol）、`GatherApplication/Services/ExportService.swift:4`（“保持在 GatherCore”，实际已在 GatherApplication）、`GatherHost/SidecarXMPProvider.swift:19`（`GatherCore.MetadataService`）、`GatherHost/FaceKwWritebackBridge.swift:2`（“GatherCore 的 WritebackService”，实际在 GatherDelivery）。
【已确认】旧文件头：逐文件比对 639 个 Sources/Tests Swift 文件第一行纯路径注释与真实路径，**0 错配**；“26 行错误文件头”已闭环。
- 建议：只改“当前路径/当前模块”的句子，历史溯源句保留；不要批量替换全部 GatherDomain。

### P2-8 TestSupport 已合并；app 侧仍有重复 SimilarityAPI stub

【已确认】`Tests/GatherTestSupport` 4 文件 551 行，唯一 `makeTestDB`；`gather-app/Tests/GatherAppTests/ServiceConstructionTestSupport.swift` 只有 8 行 `@_exported import GatherTestSupport`；B04 已闭环。
【已确认】`Support/TestSupportReexports.swift` 11 行只转发 `AsyncGate/LockedBox`，无重复实现。
【疑似】`APISimilarityUITests.swift:25` 的私有 `StubSimilarityAPI` 与 `Support/StubSimilarityAPI.swift:67` 的 `B8SimilarityAPIStub` 重复：同协议、同 LockedBox 记录结构、同 result/preview/writeback 状态；私有版更简单（无 error/gate），但方法集合高度重叠。
- 建议：先对比两者可配置项，若无行为差异则删除私有副本；有差异则把私有版改成共享 stub 的 preset。

### P2-9 Ports/PortFake 无死协议；Package 依赖基本合理

【已确认】`Ports` 共 **27** 个协议（23 文件；Culling/Delivery/Duplicate/Similarity 各含 1 个窄读协议），全部至少 2 处 `any` 注入点，无零引用协议。
【已确认】`PortFakeSupport.swift` 860 行、22 个 fake，其中 18 个实现 Ports 协议；`CullingHistoryRepository/DeliverySummaryReading/DuplicateRepository/DuplicateGroupReading/ExportReportRepository/JobRepository/NavigationRepository/QualityRepository/TemplateRepository` 9 个无专用 fake，但都有真实 Repo/查询类测试覆盖，不是死协议。
【已确认】依赖边：`GatherUI` 仅 Protocol；`GatherDelivery` 仅 Protocol+Persistence；`GatherApplication` 的 Analysis/Delivery/Persistence/Protocol 均有实际 import；`GatherTestSupport` 只被两个测试 target 链接。
【疑似】`Package.swift:117/123` 两个 benchmark target 都声明 `GatherProtocol`，但 `GatherCoreBenchmarks/main.swift` 与 `GatherFaceBenchmarks/*.swift` 均未 `import GatherProtocol`，也未直接引用其类型；疑似冗余依赖。
【已确认】台账漂移：`architecture-remediation-status.md:38` 写“GatherDelivery 14 文件”，实测 **16**；`Package.swift:49` 注释“app 不链接它（GatherTestSupport）”，但 `gather-app/Package.swift:131` 的 `GatherAppTests` 明确链接它（仅测试链接，运行时确实不链，但注释容易被读成“完全不链”）。
- 建议：删 benchmark 的 Protocol 依赖或补直接 import 证据；status 的 14→16、8/12 修正；注释改为“app 运行时/产品不链接”。

### P2-10 唯一 TODO 与 deprecated 计数

【已确认】全仓源码 `TODO` 仅 1 处：`DeliveryRepo.swift:1402`，内容是 Cut 2/S3 的会话级写回态接线说明；当前交付摘要有 `DeliverySummaryQuery` 投影，但该 TODO 是否仍需保留建议复核。
- `FIXME/XXX/HACK`：0。
- `@available(*, deprecated)`：1 处（`markWriting`，P2-3）。
- 建议：删除或把 TODO 转成设计文档引用；不要留“无 owner 的 TODO”。

## 3. 已确认通过（可复算）

- Application 具体 Repo 属性/参数：0；`DBConnection`/ `.prepare(`：0。
- Host 无 `DeliveryRepo` 写方法直调；只读引用与 5 个 writer 语义入口。
- StateWriter 是 delivery 表生产写调用唯一落点；全仓 `DeliveryRepo` 写调用仅在 `DeliveryStateWriter.swift`。sessions ack 仍有 2 处内联 SQL（P2-2）。
- `orderedUnion` / `parseBbox` 各 1 份；`patchFields` 0；`toFaceKwItem/toWritebackItem` 各 1 份；`GatherProgressBar` 只有 1 个调用点。
- 旧 feature delivery 端口（`FeatureDeliveryPorts/CullingDeliveryPort/FaceKwDeliveryPort/SimilarityDeliveryPort/DeliverySink`）源码 0 命中，仅历史注释。
- 旧 sync 端口（`SyncService/SyncPort/syncPort/SyncBridge`）0 命中；`MetadataSyncStatus/Item/Summary`、`CullingSyncStatus`、`syncStatus/flush/retrySync/finalizeSync` 是协议契约（`Protocol/Culling.swift:58/366/387`、`API/Outputs/CullingOutputs.swift:10`、`API/CullingAPI.swift:31-35`），不是死代码；B07 建议保留。
- 旧文件头：0/639（Sources/Tests）错配。
- `GatherDomainChange`、`makeGatherTestDB`、`JobScopeCheckpoint`、`VectorIndex.Candidate`、`FaceSimMutationPort`、`GatherLocalization.appLocale`、`IndexerService.sha256File`：均 0 命中，已闭环。
- TestSupport：core 唯一实现 + app re-export，无 `makeTestDB` 重复。

## 4. 未执行 / 限制

- 未运行 `swift build/test`、9 道门禁、`gather-schema verify`；以上为静态证据，未经编译器/测试再验证。
- 未做 GUI / 原生人工验收；未验证 release/签名/公证。
- 行号以 HEAD `ab7752e` 为准；并行 agent 的未提交改动可能使行号/数字漂移。
- 未逐项验证 `PortFake` 的 22 个 fake 是否与真实 Repo 行为完全等价；只确认覆盖关系。

## 5. 建议修复顺序

1. P1-1：拆 `WritebackService`（纯移动，先抽 plan/diagnostics/keywords，再抽 executor）；随后 `DeliveryCleanupFlow` 825、`PreviewFixtures` 964。
2. P1-2：删 `FilterEngine.simpleFields/metadataFields`（死 static）与 `PhotoAssets.rawExtensions`（仅测试）别名；`ExportService+Plan:402` 改 `PhotoFileTypes.rawExtensions`；评估 `WhereClauseResult` 的 `DBValue` 出口。
3. P2-1/P2-2：加 `DeliveryWriting` 窄协议并降权 `DeliveryRepo` 写方法；sessions ack 读写下沉 Persistence 窄端口；Host 只持 writer。
4. P2-3/P2-4：测试迁移后删 `markWriting`；删 `GatherProgressBar.width`。
5. P2-5：抽 `translateDomain` 公共臂；P2-6 删/收 `FileSystemDeliveryFilePort`；P2-8 合并 Similarity stub。
6. P2-7/P2-9/P2-10：清 6 处 GatherDomain 现状注释与 GatherCore 过期句；修 status 14→16、8/12、内联并集已修；处理唯一 TODO。

## 6. 结论

- **可以宣布“P0 已清零、P1 主体已收口”，但不能宣布“代码残余全部清零”。**
- 真正的残余不是功能断路，而是三类“收口未彻底”：Delivery 仍有一个 1.5k 行主执行器；Application 仍能触达具体 Persistence 类型/公共 DBValue；StateWriter 的唯一 owner 只靠约定、Delivery 仍有内联 sessions SQL。
- 其余为低风险清理项（deprecated API、零调用 width、旧注释、测试 stub 重复、台账数字）。建议按上述 1→6 顺序做纯移动/降权/删死代码，每步保持测试构造点与事务边界不变。
