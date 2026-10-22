# Gather 架构整改独立验收（HEAD df73880，2026-10-22）

> 性质：只读架构验收。未修改源码、测试、Package、脚本或 CI；唯一写入本文件。
> 对照：docs/reviews/architecture-remediation-plan.md（下称"计划"）、docs/reviews/architecture-remediation-status.md（下称"状态"）。
> 方法：Package.swift + 全仓 import 矩阵；wc/grep 实测；9 道门禁（其中 6 个以 --strict 运行；layering/cleanup/no-legacy 无 strict 开关）；core/app 实跑；schema 用 `gather-schema dump` 建库后以 sqlite3 逐表统计。所有数字均为 HEAD df73880 实测。
> **工作区漂移提示**：验收开始时 `git status` 为空；收尾时出现数十个 tracked 修改 + `GatherUI/Support/MenuCopy.swift` 新增（非本任务写入，疑似并行清理任务，且仍在增长）。本报告指标/行号以 HEAD 为准；当前工作树中 CullingService/IndexerService/SettingsService/DeliveryCoordinator/DeliveryModulePorts 等已有未提交改动，引用行号请用 `git show HEAD:<path>` 复核。

## 0. 结论

依赖方向与 target 图**正确**：无环、无反向 import；Host 的 SwiftUI import/文件为 0，UI 对 Gather 模块只 import GatherProtocol；Protocol 254 类型 / 1,338 声明 / 零引用 0 / Router 信封 0；Application 的 DBConnection 与 `prepare` 均为 0；Host shell 已迁 UI；sync 端口/Bridge 为 0；Schema 43 表/373 列/69 索引/62 FK、user_version=2、FK 违规 0；core 1,100/165、app 617/68 均 exit 0；9 道门禁全绿。

但计划验收并非全部达到，不能按"核心指标达到或超过目标"整体收口：

1. **Application 仍持具体 Repo**：5 个服务共 18 个具体 Persistence 仓储属性/参数，未做到"只注入 any XxxRepository"（WP3 设计）。
2. **Delivery 状态写 owner 未闭合**：Host 的 LiveMetadataAPI 仍有 5-6 处直调 `DeliveryRepo` 改交付状态，绕过 `DeliveryStateWriter`（源码注释自认"越界残余"）。
3. **"状态写入 35→8"口径不可复现**：按原口径的状态写调用点实测 24（GatherDelivery）+5（Host）=29；8 疑似为 writer 的 8 个交付级写方法，不是调用点。
4. **WP3 的 `>1000 行文件=0` 未达**：Application 仍有 4 个文件 1,073–1,438 行。

因此结论建议写为：**分层与关键不变量达标；WP2/WP3 的 owner/端口/文件规模有已确认残余，状态文件"全部达到"过强。**

## 1. Target 图与依赖方向

| 层 | 声明依赖（Package.swift） | 实际 import | 结论 |
| --- | --- | --- | --- |
| GatherProtocol | 0（core:59-62） | 仅 Foundation | 零依赖 ✅ |
| GatherPersistence | Protocol + CSQLite（:72-76） | 25×Protocol、3×CSQLite | 合规 |
| GatherDelivery | Protocol + Persistence（:79-83） | 14×Persistence、7×Protocol；0×Application/Analysis/UI/Host | 合规 ✅ |
| GatherAnalysis | Protocol（:85-90） | 4×Protocol | 合规 |
| GatherApplication | Protocol/Persistence/Delivery/Analysis（:94-98） | Protocol 27、Persistence 27、Delivery 15、Analysis 13 | 方向合规，端口化见 P1-1 |
| GatherUI | 仅 Protocol（app:83-95） | 146 条 `import GatherProtocol`；0 条 Persistence/Application/Analysis/Host | 只 Protocol ✅ |
| GatherHost | UI + 五层 core（:98-110） | Protocol 39、Application 33、Persistence 31、Analysis 29、Delivery 10、UI 16 | 合规 |
| GatherApp | Host + UI（:113-119） | 1×Host、2×UI、0×Protocol | 合规 |

- 无环：Protocol→∅；Persistence/Delivery/Analysis→Protocol（Delivery 另加 Persistence）；Application→上述；Host→UI+core；App→Host+UI。未发现反向依赖。
- Host 内 `import SwiftUI` = 0 文件；Host 内无 `View/App/Scene/ViewBuilder` 声明；SwiftUI 只在 GatherApp 的 2 个文件（GatherApp.swift、GatherAppCommands.swift）。✅
- `./scripts/check-layering.sh` exit 0（UI 187 文件 0 越界、Application 0 SwiftUI、无 GatherCore 回潮）。
- 门禁盲区（P2）：check-layering 不含 Delivery 的 forbidden import，也没有 "Host 不得 import SwiftUI" 规则；本报告用人工 grep 补证。

## 2. 指标实测（计划目标 vs HEAD）

| 指标 | 计划目标 | 状态声明 | 本次实测 | 判定 |
| --- | ---: | ---: | ---: | --- |
| Protocol public 类型 | ≤260 | 254 | **254**（70 文件 / 6,514 行） | ✅ |
| Protocol public 声明 | — | 1,338 | **1,338** | ✅ |
| Protocol 零引用 | 0 | 0 | **0** | ✅ |
| Router 信封 | 0 | 0 | **0** | ✅ |
| Application DBConnection 文件 | 0 | 0 | **0**（仅注释提及） | ✅ |
| Application `connection.prepare` | ≤15 | 0 | **0** | ✅ |
| Delivery Coordinator | ≤600 | 366 | **366** | ✅ |
| Delivery 状态写入 | ≤8 | 8 | **24 + 5 Host**（见 P1-3） | ⚠️ 口径 |
| Delivery 模块适配器方法 | ≤5 | 5 | **5**（DeliveryModuleAdapter） | ✅ |
| AppComposition | ≤200/文件 | 107 | **107**；Composition 5 文件共 **610**，Core.swift **236** | ⚠️ 单文件超 |
| 7 VM PageVisibility | 统一 | 7 | **7 conformer**，默认 false/幂等/终态 | ✅（边界见 P2-6） |
| Host SwiftUI 外壳 | 0 | 0 | **0** | ✅ |
| sync API/端口 | 0 | 0 | **0**（无 SyncAPI/SyncAPIPortBridge；UI 10 个协议均为 async 数据/事件端口） | ✅ |
| Schema 版本 | 2+ | 2 | **user_version=2** | ✅（V2 为 no-op，见 P2-5） |
| Schema 形状 | — | 43/373/69/62 | **43 表 / 373 列 / 69 显式索引 / 62 FK**；FK 违规 0；CASCADE 52 / SET NULL 7 / RESTRICT 3 | ✅ |
| core 测试 | 绿 | 1,100/165 | **1,100 tests / 165 suites，exit 0** | ✅ |
| app 测试 | 绿 | 617/68 | **617 tests / 68 suites，exit 0**（串行） | ✅ |

Schema 数字的独立口径：用 `gather-schema dump` 的 DDL 在临时库建库后，sqlite3 统计 `sqlite_master`、`pragma_table_info`、`pragma_foreign_key_list`、`pragma foreign_key_check`。未采信本地旧二进制 `gather-schema verify`（其输出 user_version=1，是 WP6b 前构建产物；源码 GatherSchema/main.swift:33 已取 catalog.current）。

## 3. 设计一致性

- **GatherDelivery 只依赖 Protocol+Persistence：确认。** Package.swift:79-83；源码 import 矩阵无 Application/Analysis/UI/Host；Delivery 内也无 `import SwiftUI`。
- **Application 只用 Ports：部分不成立（P1-1）。** `DBConnection`/`prepare` 确为 0，但 5 个服务仍直接持具体 Repo；另有 2 个 Persistence 端口只声明+conformance、从未注入（P2-3）。
- **Delivery 单事务 finish：确认。** DeliveryDBPhase.applyCleanup/applyFinalize 各只有一个 `connection.transaction`（DeliveryDBPhase.swift:93、186），其中调用 `deleteSyncedDeliveryInTransaction`（:129/189）与 `finishIfPresent`（:209-214，最终 DeliveryIntentRepo.finishInTransaction:292，不再开事务）；`DeliveryStateWriter` 的 InTransaction 变体不嵌套事务。任一步失败整体回滚。✅
- **XMPFileLock 锁域/顺序：锁域正确，锁序未文档化。** 按 `TSPath.normalize(xmpPath)` 的 per-path actor、FIFO、非重入（XMPFileLock.swift:34-104）；cleanup/finalize/replay 的 verify→restore/remove→事后 verify 在同一 `fileLock.run`（DeliveryFilePhase.swift:72-96）；writeback 的 backup/read/write 与 orphan restore/remove 共用同一实例（WritebackService.swift:743/1052、LiveMetadataAPI.swift:227）。实测存在 **XMP→DB** 嵌套：持文件锁时 `persistItemFailure` 会走 stateWriter→DB（WritebackService.swift:489、925/973）；未发现 DB 事务内反向取 XMPFileLock，但计划要求的"锁顺序文档 + 压力测试"只有注释与一个最大并发=1 的用例，没有顺序断言/文档（P2-4）。
- **Schema 备份/回滚：事务回滚确认，自动恢复未实现。** 备份用 `VACUUM INTO` + 只读 quick_check + user_version 校验，保留 3 套（SchemaBackup.swift:33-35、50-135）；迁移 `BEGIN IMMEDIATE` 内执行 DDL + user_version + foreign_key_check + 目标形状校验，失败整体回滚并恢复 FK（SchemaMigrator.swift:42-73）；open 仅在备份成功后迁移（Database.swift:226-243）。失败后库停在旧版本、备份保留，但**不会自动从备份恢复**；"备份/回滚"应表述为"事务回滚 + 人工备份"，Status 的措辞容易读成自动 restore（P2-5）。

## 4. "做了但走样"清单

1. **逻辑/依赖漏回 Application（已确认）**：CullingService（PhotoRepo/CullingDecisionRepo/SimilarityResultRepo/MetadataCacheRepo/CullingHistoryRepo）、SimilarityService（PhotoRepo/SessionRepo/SimilarityResultRepo/SimilarityClusterStateRepo）、IndexerService（SessionRepo/PhotoRepo/AssetRepo/FaceRepo）、FaceKwService（PhotoRepo/SessionRepo/FaceRepo/PersonRepo）、SettingsService（SettingsRepo）。端口存在但服务不用，测试无法用 fake 替换；`CullingService.preferredRawExtensions = Set(PhotoRepo.rawExtensions)`（CullingService.swift:66）还把 Persistence 静态表当策略源。
2. **Delivery 巨型文件只是搬家（已确认）**：Coordinator 366 达标，但 WritebackService 1,294 行、CleanupFlow 674 行；GatherDelivery 实际 **14 个 Swift 文件**，Status 写 15；源码注释仍指向不存在的 `Ports/DeliveryModuleAdapter.swift`（DeliveryCoordinator.swift:16），若把它算入正好 15（疑似口径来源）。`DeliveryModulePorts.swift:14-15` 仍称"旧端口协议保留/14 个名字转发"，而 WP2c 已删除 FeatureDeliveryPorts；`replayPendingDeliveries` 旧别名仍在（DeliveryCoordinator.swift:361-365），AppRuntime.swift:151 仍调用。
3. **Host/UI 归属（疑似，非 import 越界）**：Host 的 SessionWorkspaceFactory 构造 7 个会话 VM（SessionWorkspaceFactory.swift:35-76，AppBootstrap.swift:242-243），UI 的 RootView 构造 3 个 shell VM（RootView.swift:74/83/86）——两个装配点；方向没错，但"Host 是唯一组合根"的语义被弱化。SessionWorkspaceFactory.swift:2/13 的"RootView 暂不消费/不会被调用"已过期。
4. **协议面通胀（已确认，程度有限）**：Protocol 254 已接近 260 上限；Delivery 在 Coordinator 公开方法之外又加 DeliveryEngine（6 方法）与 DeliveryModuleAdapter（5 方法 + capabilities/engine）两套并行入口；Persistence 另有 2 个未接线端口（P2-3）。未发现跨模块同名重复类型（7 个模块的类型名交集为空），Router 信封为 0。
5. **状态写 owner（已确认）**：Host 直调 5 处状态写 + resetConfirmations/deleteOrphanDelivery（LiveMetadataAPI.swift:169/180/203/387/395/396）；DeliveryStateWriter.swift:9 自认"Host 仍有 6 处直调，属越界残余"。状态机可被 Host 绕过，Delivery 的"唯一 writer"只在 GatherDelivery 内成立。

## 5. P0 / P1 / P2

### P0
- 无。未发现数据丢失、构建断裂或越权写文件的当前路径；单事务 finish 与 XMPLock/守卫已闭环已知 TOCTOU。

### P1（已确认，建议本轮记账）
- **P1-1 Application 未做到"只 any 端口"**：CullingService.swift:83-86/101-104、SimilarityService.swift:148-151/213-216、IndexerService.swift:96-98/152-155、FaceKwService.swift:77-80/129-132、SettingsService.swift:107；共 5 服务/18 个具体仓储。影响：这 5 个服务与 SQLite Repo 具体类型绑死，fake-repo 无法替换；WP3 "核心测试可改用 fake repo ≥50%" 未测量，但该子目标至少对这 5 个服务不成立。
- **P1-2 Host 直写交付状态**：LiveMetadataAPI.swift:169/180/203/387/396（另 :395 resetConfirmations、:231 deleteOrphanDelivery）；绕过 DeliveryStateWriter/DeliveryModuleAdapter。影响：Delivery 状态机不是唯一 owner；状态写入计数与"单 owner"结论失真。
- **P1-3【已确认：不可复现；疑似：8=方法数】"状态写入 8"口径漂移**：按原口径（调用点）实测 GatherDelivery **24** 处（WritebackService 15、MirrorWriter 5、CleanupFlow 2、ReplayFlow 1、Coordinator 1）+ Host **5** 处 = **29**；writer 共 20 个写方法（含删除），其中交付级 8 个（mergeInput/claimWriting/markWriting/renewWriting/markWritten/markFailed/markConflict/confirm）。"35→8"只有把"调用点"改成"交付级写方法数"时成立，不能直接宣称 ≤8。
- **P1-4 WP3 的 `>1000 行文件=0` 未达**：Application 仍有 `SimilarityService.swift:1`（1,438）、`IndexerService.swift:1`（1,164）、`ExportService.swift:1`（1,102）、`JobService.swift:1`（1,073）；WP5 的 Culling/Face 已 ≤800（最大 711/704），但 WP3 整体文件规模指标未收口。

### P2
- **P2-1【已确认】Delivery 文件规模**：`WritebackService.swift:1` 1,294 行、`DeliveryCleanupFlow.swift:1` 674 行；计划只卡 Coordinator ≤600，故不判失败，但"巨型 Coordinator"只是转移。
- **P2-2【已确认】Composition 单文件超限**：`Composition/Core.swift:1` **236** 行 > 200/文件（AppComposition 107 达标）；同文件 :14 的 `import GatherUI` 未使用。
- **P2-3【已确认】死端口/端口通胀**：SimilarityRepository（SimilarityRepository.swift:5/47）与 SimilarityClusterStateRepository（:28/48）仅声明+conformance，无注入；SimilarityService 仍用具体 SimilarityResultRepo/SimilarityClusterStateRepo（SimilarityService.swift:150-151）。Protocol 零引用按门禁口径为 0，但有 9 个类型仅被 Protocol 自身引用（ConfirmationSource/ExportWatermarkType/FilterLogic/MetadataBatchUpdate/MetadataContractError/MetadataKeywordsOp/MetadataLabelOp/MetadataRatingOp/QualityResultStatus），是 API DTO 组件，非死类型；审计时应把这种"协议内自洽"与真实生产引用分开看。
- **P2-4【已确认】锁序文档/压力测试缺口**：XMPFileLock.swift:14-16 只有"不得重入"注释；无 XMP→DB 锁序文档/断言；DeliveryFilePhaseTests 只有并发=1 的用例。另【疑似】单事务前提是 connection 与 deliveryRepo/intentRepo 同源，而 DeliveryCoordinator.swift:69-95 的 public init 允许分开传入，无断言。
- **P2-5【已确认】Schema 只完成"版本位"**：SchemaV2.swift:10-18、MigrationV1ToV2.swift:16-18 是 no-op；V1→V2 数据保留仅因 DDL 相同；无真实载荷迁移（V3 未开始）。备份保留但无自动 restore。
- **P2-6【已确认】PageVisibility 覆盖边界**：7 个会话 VM 已统一（PageVisibility.swift:22-36；默认 false/幂等/终态；WorkspaceVisibilityTests.swift:283 矩阵）；Dashboard 仍是 `package var isVisible = true`（DashboardViewModel.swift:230）并由 Shell 直接改（RootShellWorkspace.swift:152-157），不在契约内；Culling 用 `isActive`、其余 6 个用 `isVisible`。LoadPhase 也只在 4 个 VM 上存在，未成协议。
- **P2-7【已确认】门禁盲区**：`scripts/check-layering.sh:66-70` 未覆盖 Delivery forbidden import 与 Host SwiftUI；`scripts/check-cleanup-ratchet.sh:66` 的 `services_prepare` 只统计字面 `prepare(`，不覆盖 `connection.prepare` 之外的 DB 耦合；本次靠人工 grep 补证。

## 6. 复现命令与限制

已执行（全部从仓库根目录）：

~~~bash
./scripts/check-layering.sh                                  # exit 0
./scripts/check-protocol-surface.sh --strict                 # 254/1338/0/0, exit 0
./scripts/check-cleanup-ratchet.sh                           # 53/231/0/0/0
./scripts/check-duplicate-symbols.sh --strict                # exit 0
./scripts/check-no-legacy.sh                                 # exit 0
./scripts/check-docs.sh --strict                             # exit 0
./scripts/check-test-catalog.sh --strict                     # exit 0
./scripts/check-select-star.sh --strict                      # exit 0（Sources 4 < baseline 6）
./scripts/check-preview-surface.sh --strict                  # exit 0（#Preview 14）

swift test --package-path desktop/native/gather-core --disable-sandbox   --cache-path .build/shared-cache --scratch-path .build/scratch   --explicit-target-dependency-import-check error
# 1,100 tests / 165 suites, exit 0

CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test   --package-path desktop/native/gather-app --no-parallel --disable-sandbox   --cache-path .build/shared-cache --scratch-path .build/scratch   --explicit-target-dependency-import-check error
# 617 tests / 68 suites, exit 0
~~~

未执行 / 限制：
- 未做 GUI 人工 smoke、截图或视觉验收（本环境无 GUI 自动化）；未跑 build.sh 的 universal/sign/notarize/staple 全流程，未验证 x86_64/Rosetta、真实 Developer ID 与 CI release job。
- app 测试只跑了串行 1 次；Status 的"串行 + 并行 3 次"未复跑。
- WP3 的 fake-repo 比例、Application 端口测试替身覆盖率未定量测量；P1-1 按具体 Repo 属性/参数计数判定。
- 本地 `.build` 中的 gather-schema 是旧产物（verify 输出 v1），schema 结论以 dump + sqlite3 实测为准；CI 应重建后再跑 `swift run ... gather-schema verify`。
- 本报告只写本文件，未改源码/测试/Package/脚本。验收开始时工作区 clean；收尾 `git status` 出现数十个 tracked 修改、`GatherUI/Support/MenuCopy.swift` 新增及 4 个其他未跟踪验收报告，均非本任务写入（并行任务），未读取/修改。所有数字与 `file:line` 以 HEAD df73880 为准；工作树若继续变动，应以 `git show HEAD:<path>` 复核。

## 7. 是否达到计划指标

**分层结构、Protocol 收敛、Application 去 DB、Delivery 单事务、Host shell 迁移、sync 清除、Schema V2、测试绿：达到。**
**Application 端口化（WP3 设计）、`>1000 行=0`（WP3 验收）、"状态写入 ≤8"（WP2 原始口径）、"锁顺序文档+压力测试"（WP2 验收）：未完全达到。**
建议把本文 P1-1～P1-4 记入台账（D-xxx/CL-xx），并在 Status §2/§4 把"全部完成/达到或超过目标"降级为"主结构达标，WP2/WP3 有已确认残余"。在 P1-2 关闭前，不应宣称"交付状态只有唯一 owner"。
