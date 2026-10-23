# 架构整改执行状态（WP0–WP7b，2026-10-22）

> 计划：docs/reviews/architecture-remediation-plan.md。本文件是执行状态索引；详细设计见 macro 报告与 wp6 设计。
> 工作区：分支 refactor，HEAD 见 git log；本地 commit，未 push。

## 1. 已完成 WP

| WP | 结果 | 关键提交 |
| --- | --- | --- |
| WP0 | 基线冻结 | — |
| WP1 | Protocol 347→251 类型、1,752→1,320 声明、零引用 89→0、Router 信封 6→0；新增 protocol surface ratchet | 65c0179 |
| WP2a | GatherDelivery target 提取（4 文件 3,630 行），Delivery 仅依赖 Protocol+Persistence | 62551b6 |
| WP2b | Coordinator 1,964→319；状态写入 33→8；模块适配器 15→0；DB 删除+intent.finish 单事务 | b6db25a |
| WP2c | 删除 FeatureDeliveryPorts 与 14 个旧转发；服务直接持 DeliveryModuleAdapter | 7bbfc94 |
| WP3a | GatherDomain→GatherApplication（21 文件/15,211 行纯 rename） | b97d10f |
| WP3b-1 | 8 组 Repo Ports；DBConnection 文件 13→5，prepare 120→76 | 9387fa4 |
| WP3b-2 | Similarity/FaceKw/Culling/Indexer SQL 下沉；DBConnection 5→1，prepare 76→25 | 93304b5 |
| WP3b-3 | Duplicate SQL 下沉；DBConnection 1→0，prepare 25→0；services_prepare ratchet 0 | 6bccb77 |
| WP4a | RootShell/RootView 882 行迁 GatherUI/Shell | bf9adba |
| WP4b | 删 27 sync 核 + 18 UI sync 端口 + Bridge；3 个 Live provider 迁 Host | 66adef8 |
| WP4c | AppComposition 421→107；Composition/ 4 文件；AppServices 301→161 | c644e6b |
| WP5a | CullingService 2,496→138 门面 + 6 文件 2,370 行 | efc6598 |
| WP5b | FaceKwService 2,528→171 门面 + 5 文件 2,406 行 | c475974 |
| WP6a | Schema migration framework；Database.swift 679→505 | 67eb35d |
| WP6b | Schema V2 no-op 迁移 + 备份/回滚；user_version=2 | 95f0075 |
| WP6c | universal/arm64/x86_64、版本注入、签名/公证接口、release CI | f0eb94d |
| WP7 | GatherTestSupport product；manifest 去 xcrun；CI schema verify；app 复用夹具 | d2527a8 |
| WP4d | PageVisibility 协议；7 VM 默认不可见/幂等；GatherAppCommands 迁 GatherApp，Host SwiftUI=0 | 01143ad |
| WP7b | Job/Delivery trace id + 阶段日志（info/warn）；不改 Schema/API/状态机/时序 | 1031954 |

## 2. 当前指标（HEAD 工作区实测）

- core：**1,166 tests / 175 suites**，exit 0（P1/P2 收口 + fake-repo/trace/replay 并发测试后；含 3 个真实照片 skip，有效 1,163）。
- app：**624 tests / 69 suites**，串行 + 并行 3 次 exit 0（新增 DeliveryErrorPresentation 7 例）。
- Schema：43 表 / 373 列 / 69 索引 / 62 FK / user_version=2 / FK 违规 0。
- 门禁：9 道 strict 全绿；ratchet 54/230/0/0/0；protocol surface 255/1,340/0/0；preview 14。
- Application：DBConnection 0、connection.prepare 0；services_prepare ratchet 0。
- Delivery：Coordinator 543 行；GatherDelivery 20 文件；状态写入按 writer 交付级入口 8 个（调用点口径见验收报告）；模块适配器 5 方法。
- Protocol：255 个 public 类型 / 1,340 声明；零引用 0；Router 信封 0。
- Host：RootShell 已在 UI；UI sync 端口 0；AppComposition 107 行。
- Release：真实 universal app 构建通过（本机需给 SwiftPM 注入 `--disable-sandbox`）；GatherLink.coplugin 因 DSH 嵌套 sandbox 的 module cache 拒绝未能构建；签名/公证未验证（无凭据）。

### WP7b trace 口径（2026-10-22）

- trace：`job:<id>`、`delivery:<id>/rev:<revision>/<phase>`（phase=confirm/file/db/intent/backup/lease）。
- confirm 是 (session, module) 级事务、没有单条 delivery id：id 段用 `session:<sessionId>`、revision 固定 0（唯一例外）。
- 日志点：JobService claim 成功的 start 与 settle/finishMiss/取消宽限/停机兜底的 terminal（cancelled 也带 reason）；DeliveryCoordinator confirm 的 DB 边界；cleanup/finalize/replay 的 file/db/backup 边界；WritebackService/MirrorWriter 的写租约冲突（lease）；失败一律 warn 且带 phase + reason。
- 测试：`Tests/GatherCoreTests/Logging/TraceLoggingTests.swift`（14 用例，`@Suite(.serialized)` + `GatherLogger.output` 捕获；按唯一 job id/xmp 过滤并行串扰）。
- 约束：不改 Schema/公开 API/状态机/返回值与业务时序；`GatherLogger.log` 不抛错，日志失败不影响业务。

## 3. 剩余

1. 发布验证（外部）：真实 Developer ID/notarytool/staple/spctl、CI release job 未实跑；x86_64 运行期未在 Rosetta 验证；插件 x86 构建仅静态/lipo 证据。
2. 可观测性：trace 已覆盖 lease/backup/cancel/lease-lost；结构化阶段耗时（duration）未做。
3. P2 残余：markWriting 仍 public deprecated（跨包测试直调）；replay claim 按 coordinator 隔离且跨 replay 调用共享（仍仅进程内，无 DB 跨进程 claim），并发同一 intent 由 claim 跳过并报 `XMP_CLEANUP_REPLAY_CLAIMED`，不产生 `ADVANCE_FAILED` 假失败（测试 `DeliveryCoordinatorTests.concurrentReplaySameIntentClaimsOnceAndSkipsWithoutAdvanceFailure`，本任务未运行）；临时文件 sweep 仅 replay 起点、锁外、24h 阈值，只清 `.tmp-/.restore-` 不碰备份（详见 `docs/delivery-lock-order.md` §5）；历史非受控 backup_path 会 fail-closed；MirrorWriter 租约 trace 无确定性测试。Culling 内联并集已改用 orderedUnion。
4. 文档：final-report 的 Cut 6c 数字仍为历史快照，§1.2 已注记当前架构指标；其余历史报告保留快照口径。
5. 未 push；本地 commit 序列等待 owner review。

## 4. 结论

计划中的 WP0–WP7b 与独立验收 P1 已全部收口：Application 5 服务改 any 端口、Host 写交付状态收敛到 StateWriter、markWritten/markFailed/markConflict owner CAS、confirm 单事务门禁、confirmSync 委托 Coordinator、370 列 V1 迁移、4 个 >1000 行服务拆分、WP3b fake-repo 与 trace 边界测试。核心指标：Application SQL 0（目标 ≤15）、Delivery Coordinator 543（目标 ≤600）、adapters 5（目标 ≤5）、Protocol 255 类型（目标 ≤260）、Host shell 迁移、sync 0、Composition 107、Schema V2。
本轮架构 P1 进一步收口：DeliveryRepo/AssetRepo/FaceRepo/ClusterGraph 四个 >1000 行文件已拆到 ≤800；SidecarXMPProvider/PersonRepo/DeliveryCleanupFlow 也已拆到 ≤800（仅 SchemaV1 DDL 846、DEBUG PreviewFixtures 964 保留）；AssetRepo 不再直接 UPDATE deliveries，路径迁移/Intent payload 归 DeliveryRepo.relocatePaths；2 处内联 sessions SQL 下沉 SessionReloadAckRepo；reload-ack 与 markWritten 改为同事务；StateWriter 的 markFailed/markConflict 强制显式 leaseOwner。
**已进一步收口**：`DeliveryWriting` 窄协议 + `DeliveryStateWriter` 依赖 `any DeliveryWriting`；`markWriting` 从 public deprecated 降为 `package`，跨包测试经 `GatherTestSupport.markWritingForTesting`；item 级 `markItem` 支持 leaseOwner 并加 `EXISTS(deliveries.lease_owner)` CAS，Writeback 传 owner。
**已补**：4 个 Query 的 SQL 边界 20 例（真实 SQLite）；Job/Delivery trace `duration_ms`。
**已补**：replay claim 以 DB storagePath + xmpPath + intent id 为作用域，并用 `flock` 跨进程排他；`markFailed/markConflict` 已移除空串默认，生产 StateWriter 显式传 owner，测试经 package/GatherTestSupport seam。
**仍未清零**：SchemaV1（846 DDL）/PreviewFixtures（964 DEBUG）仍 >800；跨进程 claim 无专门并发测试；发布侧 app icon/签名/公证/macos-26 release job 仍未闭环。
最终验收报告：[final-acceptance-build.md](final-acceptance-build.md)、[architecture](final-acceptance-architecture.md)、[data](final-acceptance-data.md)、[tests](final-acceptance-tests.md)、[cleanup](final-cleanup-scan.md)。
