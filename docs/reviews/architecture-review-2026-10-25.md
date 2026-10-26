# 全量架构复核（2026-10-25，第二轮）

> 基线：HEAD `c89d999`（refactor 分支，工作区干净）。四路只读子代理分别覆盖
> Persistence/Delivery、Application/Jobs/Analysis、Host/UI、Tests/Gates/CI/Docs；
> 主线程逐条复核并落修复。结论：**无 P0**，6 条 P1、18 条 P2、1 条驳回。

## 1. 结论

数据面与 UI 状态机的关键不变量（事务/CAS/租约、迁移 fail-closed、latest-wins、
可见性扇出、XMP 锁）经得起读；风险集中在**任务终态与看门狗的失败路径**、
**宿主导入旁路**、**门禁失效模式（扫描根消失即 PASS）**，以及交付 cleanup 的
一个"已恢复却被判 conflict"的崩溃窗口。

## 2. 发现与处置

| ID | 严重度 | 位置 | 问题 | 状态 |
| --- | --- | --- | --- | --- |
| A1 | P1 | DeliveryFilePhase.swift:161-172 / DeliveryReplayFlow.swift:233-257 | cleanup restore 后崩溃，replay 以写盘后指纹判定，把已恢复的交付误标 conflict 且永久无法收口 | **已修**（盘上==备份内容时继续；+回归测试） |
| B1 | P1 | JobService+Settle.swift:116/135/146/165 | `try? repo.finish` 把 SQL 错误与 0 行合并成 leaseLost，行停 running 且可能被重跑 | **已修**（writeTerminal 三态 + 错误上报） |
| B2 | P1 | JobService+Recover.swift / AnalysisJobRepo.recoverStale | 看门狗不排除本进程活跃 job，长事务饿死心跳时自己回收自己 | **已修**（excludingJobIds + 回归测试） |
| C1 | P1 | AppImport.swift:45-96 | 导入建库/ImageIO/写库全在主线程，Finder/C1 多选冻结 UI | **已修**（改走 async SessionAPI） |
| C2 | P1 | AppImport.swift:79-117 | 入队失败只写日志，不回滚会话/照片，留下永不索引的半成品 | **已修**（复用 LiveSessionAPI 的补偿删除） |
| D1 | P1 | 5 个 gate 脚本 | 扫描根消失/改名 → 0 命中仍 PASS（layering 显式 skip） | **已修**（根存在 + 文件数下界） |
| A2 | P2 | DeliveryFilePhase.performCleanup | xmp_path 零校验，DB 篡改后可 remove/restore 目录外文件 | **已修**（DeliveryXMPPath + 2 测试） |
| A3 | P2 | DeliveryCleanupFlow+Finalize.swift:275-296 | finalize 提交后删备份，崩溃窗口留下永不回收的 .gather-backup | **已修**（intent 保留 applied + replay 补删；+崩溃窗口测试） |
| A4 | P2 | AnalysisRunRepo.start | INSERT 与 lastInsertRowid 不在同一事务，并发可拿错 rowid | **已修** |
| A5 | P2 | DB.swift:400-414 | 读池在 prepare 时判定事务深度，跨作用域语句会静默走错连接 | **已修**（DBStatement 执行期校验 + 回归测试） |
| A6 | P2 | DeliverySummaryQuery.hasWrittenBackItem | 用 delivery_sessions 判归属，与其余查询的 photos.session_id 口径不一致 | **已修** |
| B3 | P2 | CullingService+Commands.swift:256-278 | 批量更新在单事务内逐条 3 读 + 2 写（1 万条≈3 万查询），饿死心跳 | **已修**（批外层预读决策/缓存/sync；相交集合自动退回逐条） |
| B4 | P2 | JobService.swift:480 | cancelScope 用 repo.list() 全表加载（含 1MB checkpoint） | **已修**（activeJobIDs 窄 SQL） |
| B5 | P2 | CullingService+Caches.swift:111-114 | 双重 try? 把 DB 故障降级为空照片集，伪装成 PHOTO_NOT_IN_SESSION | **已修**（throws 上抛） |
| B6 | P2 | IdentityPolicy.swift:16-18 | 建议亚军也过阈值 | **驳回**：文件头与 FaceIdentityArchitectureTests 明确钉住"被拒绝的亚军仍参与歧义" |
| B7 | P2 | FaceInputs.swift:122 / FaceKwService+Types.swift:360 | minSamples=1 放行到 DBSCAN，孤立脸各自成簇 | **已修**（下界 2 + 测试更新） |
| C3 | P2 | AppBootstrap.swift:163-166 | [weak settingsRepo] 局部实例立即释放，PRAGMA 设置需重启 | **已修**（按需构造，避免持有环） |
| C4 | P2 | DuplicatesViewModel.swift:302-435 / DuplicateService.swift:522-540 | UI 与服务端各自重算"保留谁"，非法 mtime 口径不同 | **已修**（UI 对齐 Double/NaN 与首成员兜底；+2 测试） |
| C5 | P2 | AppBootstrap.makeScene | DB open/组合根/ runtime.start 全在主线程同步执行 | **已修**（Database.open+schema 校验、runtime.start 均移入 detached；组合根只剩对象装配在主线程） |
| C6 | P2 | SessionStore.swift:60-77 | capacity==1 时先淘汰后认领 active，新 workspace 被 close | **已修**（先认领再淘汰） |
| D2 | P2 | check-test-catalog.sh | skip 到期日从不校验，过期静默通过 | **已修**（日期比较 + strict FAIL） |
| D3 | P2 | ci.yml:114-121 | 文档称 app 始终串行，CI 却整包并行 smoke（已知 flake） | **已修**（删除并行 smoke，串行口径统一） |
| D4 | P2 | ReadPoolTests.swift | 替换进程级 logger/阈值但套件未 serialized | **已修**（.serialized） |
| D5 | P2 | README/DEVELOPMENT/test-audit | 16 域/110 方法 vs 15/104；8 target vs 15；17 vs 19 依赖；5 vs 12 Preview；en 键 1313/1332/1336 vs 1337 | **已修**（全部改为 15/104、15 target、19 方向、18 块/13 文件、1,337 键） |
| D6 | P2 | check-layering.sh:55 | import 正则不匹配 @_exported / import struct Mod.Type | **已修** |
| D7 | P2 | build.sh:622-630 | RELEASE_MODE 下 SDK<26 只 warning | **已修**（exit 1） |
| E1 | P2 | DB.swift | 842 行，超过单文件 ≤800 的书面指标 | **已修**（值类型拆到 DBValues.swift，DB.swift 695 行） |

## 3. 复核过且成立的关键点

- 迁移 fail-closed：SchemaMigrationTests 覆盖 v3/v0/未知列形/回滚/备份，并钉死 43/373/69/62。
- 交付 CAS/租约与 replay 互斥：真实 SQLite + 跨实例 .lock 断言，不是类型测试。
- UI latest-wins 与两级可见性：7 个 VM 的 setVisible 全部经 transitionVisibility；页面唯一入口 onAppear/onDisappear。
- 主线程无同步图片解码：缩略图统一 decodeAsync。

## 4. 验证

- core **1166 tests / 173 suites**；app **650 tests / 74 suites**；12/12 gates；schema 43/373/69/62 v2。
- 本轮新增测试：recoverStale 排除活跃 id、DeliveryXMPPath（7 tests in suite）、minSamples 下界。

## 5. 未覆盖

无 GUI/真机验收；未跑 nightly benchmark；未构造真实崩溃注入复现 A1/A3；x86_64 只编译不运行。
