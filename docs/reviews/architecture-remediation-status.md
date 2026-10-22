# 架构整改执行状态（WP0–WP7b，2026-10-22）

> 计划：docs/reviews/architecture-remediation-plan.md。本文件是执行状态索引；详细设计见 macro 报告与 wp6 设计。
> 工作区：分支 refactor，HEAD 1031954；本地 commit，未 push。

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

- core：**1,114 tests / 165 suites**，exit 0（最终清理 + schema guard 测试后；含 3 个真实照片 skip，有效 1,111）。
- app：617 tests / 68 suites，串行 + 并行 3 次 exit 0（WP4d 新增 PageVisibility 矩阵 1 例）。
- Schema：43 表 / 373 列 / 69 索引 / 62 FK / user_version=2 / FK 违规 0。
- 门禁：9 道 strict 全绿；ratchet 53/231/0/0/0；protocol surface 254/1,338/0/0；preview 14。
- Application：DBConnection 0、connection.prepare 0；services_prepare ratchet 0。
- Delivery：Coordinator 366 行（WP7b 日志 +47）；CleanupFlow 674 / ReplayFlow 400（日志边界）；GatherDelivery 15 文件；状态写入 8；模块适配器 5 方法。
- Protocol：254 个 public 类型 / 1,338 声明；零引用 0；Router 信封 0。
- Host：RootShell 已在 UI；UI sync 端口 0；AppComposition 107 行。
- Release：真实 universal build + build.sh 全流程通过；签名/公证未验证（无凭据）。

### WP7b trace 口径（2026-10-22）

- trace：`job:<id>`、`delivery:<id>/rev:<revision>/<phase>`（phase=confirm/file/db/intent/backup/lease）。
- confirm 是 (session, module) 级事务、没有单条 delivery id：id 段用 `session:<sessionId>`、revision 固定 0（唯一例外）。
- 日志点：JobService claim 成功的 start 与 settle/finishMiss/取消宽限/停机兜底的 terminal（cancelled 也带 reason）；DeliveryCoordinator confirm 的 DB 边界；cleanup/finalize/replay 的 file/db/backup 边界；WritebackService/MirrorWriter 的写租约冲突（lease）；失败一律 warn 且带 phase + reason。
- 测试：`Tests/GatherCoreTests/Logging/TraceLoggingTests.swift`（14 用例，`@Suite(.serialized)` + `GatherLogger.output` 捕获；按唯一 job id/xmp 过滤并行串扰）。
- 约束：不改 Schema/公开 API/状态机/返回值与业务时序；`GatherLogger.log` 不抛错，日志失败不影响业务。

## 3. 剩余

1. WP7b：trace 与阶段日志已落地；结构化阶段耗时（duration）未做。
2. WP6c 发布验证：真实 Developer ID/notarytool/staple/spctl、CI release job 未实跑；x86_64 运行期未在 Rosetta 验证。
3. 架构 P1：Application 5 服务仍持 18 个具体 Repo；Host LiveMetadataAPI 5-6 处直调 DeliveryRepo；Application 仍有 4 个 >1000 行文件；“状态写入 8”是 writer 交付级方法数，调用点口径为 24+5。
4. 数据 P1：markWritten 未校验 lease owner；confirm 门禁在事务外/confirmSync 旁路；370 列 V1 无迁移路径；finalize 备份顺序已修。
5. 测试 P1：Schema guard 失败用例已补；WP3b 仍缺 fake-repo 功能断言；菜单测试已恢复；trace 的 cancelled/lease-lost/finalize backup 与 reason 脱敏已补用例（本轮未跑全量）。
6. 文档：final-report 的 Cut 6c 数字仍为历史快照，§1.2 已注记当前架构指标；其余历史报告保留快照口径。
7. 未 push；本地 commit 序列等待 owner review。

## 4. 结论

计划中的 WP0–WP7b 已完成，核心指标达到或超过目标：Application SQL 0（目标 ≤15）、Delivery Coordinator 366（目标 ≤600）、adapters 5（目标 ≤5）、Protocol 254（目标 ≤260）、Host shell 迁移、sync 0、Composition 107、Schema V2；Job/Delivery 已具备可关联 trace 与阶段日志。**但独立验收确认存在 P1 残余**（具体 Repo、Host 直写、状态写入口径、Application 文件规模、markWritten/confirm/370 列迁移），因此“全部计划指标达到”应改为“核心架构达标、P1 待收口”。
最终验收报告：[final-acceptance-build.md](final-acceptance-build.md)、[architecture](final-acceptance-architecture.md)、[data](final-acceptance-data.md)、[tests](final-acceptance-tests.md)、[cleanup](final-cleanup-scan.md)。
