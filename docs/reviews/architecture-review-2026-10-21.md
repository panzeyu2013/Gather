# Gather 架构与设计深度评审（2026-10-21）

> 评审对象：Gather 原生 macOS 应用（Swift 6 / macOS 14+ / SwiftPM，两包 257 个 Swift 文件、约 7.4 万行生产代码）。
> 方法：全仓静态阅读 + 只读门禁脚本 + 5 路并行专项审计（服务层 / 数据库 / 宿主 / 表现层 / 算法），并对高优先项逐条回到代码核对。
> 本报告只讨论**架构与设计**（边界、依赖方向、职责、并发、错误语义、可演进性），不重复既有 review 台账中的 UI 视觉细节与已修复缺陷。

---

## 0. 结论摘要

**一句话判断：这是一个把"迁移期约束"固化成了长期架构的成熟单体。可靠性工程与测试纪律明显高于同类项目，但四根承重墙——字符串命令面、上帝 Router、单连接数据库、单 target 包结构——来自 Electron/IPC 时代，正在成为演进瓶颈。**

| 维度 | 判断 | 依据 |
| --- | --- | --- |
| 可靠性 / 数据安全 | **强** | 迁移备份与回滚、WAL、busy_timeout、连接代数、savepoint、任务租约与恢复、路径授权 |
| 测试纪律 | **强** | 1292 个测试、契约/对账/变异测试、错误码与本地化交叉契约 |
| 模块化 / 边界 | **中偏弱** | 服务层 128 处内联 SQL、Image→Database 反向依赖、命令面 stringly-typed |
| 并发模型 | **中偏弱** | 单连接全局锁 + 52 处 @unchecked Sendable + 主线程同步命令 |
| 表现层可维护性 | **弱** | 3525 行 View、VM 写进 View 文件、6 个 VM 零单测、外壳上帝对象 |
| 可演进性 | **中** | 命令面被"冻结 118 条"卡住；包结构无法用编译器强制分层 |

**最高杠杆的三件事**（按投入产出排序）：

1. **把命令面从"字符串 + 字典"改成类型化契约**，并顺势拆掉 3258 行的 SessionCommandRouter。这是所有其他改造的前置。
2. **把持久化边界收回到 Repository，并把单连接全局锁的临界区缩短**（长事务移出、读路径并行化）。
3. **收敛表现层状态所有权**（SessionWorkspace 取代 RootView 手工生命周期，语言用 Environment 注入）。

不建议大爆炸重写。上面三项都可以用"绞杀者模式"分阶段完成，每阶段有可执行验收。

---

## 1. 架构全景

### 1.1 物理结构

```
desktop/native/
├── gather-core/                     SwiftPM 包，1 个库 target + 3 个可执行 target
│   └── Sources/GatherCore/
│       ├── Protocol/     4,566 行   纯值类型 DTO + 错误码（零 IO）
│       ├── Database/     9,633 行   DBConnection、Schema、Migrations、18 个 Repository
│       ├── Services/    16,738 行   28 个领域服务
│       ├── Face/         3,671 行   检测→对齐→质量→嵌入→聚类→匹配（无 DB 依赖）
│       ├── Similarity/   1,563 行   dHash 聚类与增量状态机（无 DB 依赖）
│       ├── Image/          470 行   RAW/尺寸/9×8 像素采集
│       ├── Concurrent/     139 行   BatchRunner/BatchCursor（全仓唯一有界并发）
│       ├── IPC/            259 行   helper 行协议
│       └── Logging/         72 行
└── gather-app/                      SwiftPM 包，1 个可执行 target + 1 个测试 target
    ├── Sources/GatherApp/           RootView、Dashboard/Library/Gallery/Similarity/Persons、Host、Support
    ├── Culling/ Settings/ Export/ Duplicates/ FaceKeywording/ ControlCenter/
    └── Resources/                   en.lproj（1478 行）/ zh-Hans.lproj（12 行占位）
```

### 1.2 运行时数据流

```
SwiftUI View / ViewModel
   │  ① 字符串命令 + [String: JSONValue]（118 条：82 同步 + 36 异步）
   ▼
SessionCommandRouter（3258 行 / 24 个注入依赖）
   │  ② 参数解包、路径授权、confirmed 门控、错误字符串化
   ▼
GatherCore Services（28 个）──────► 18 个 Repository ──► 单条 SQLite 连接（WAL + 递归锁）
   │
   ├── JobService（唯一后台执行器：租约 / 心跳 / 取消宽限 / 恢复 / checkpoint）
   ├── MetadataSyncCoordinator ──► metadata_outbox ──► XMP 侧车
   └── Face / Similarity / Image（纯算法 + CoreML/Vision）
```

### 1.3 量化基线（本次实测）

| 指标 | 数值 |
| --- | --- |
| 生产代码 | 74,419 行（core 37,603 / app 36,816），257 个 Swift 文件 |
| 测试代码 | 36,172 行，117 个测试文件，994（core）+ 298（app）个 @Test |
| 命令面 | 118 条（82 同步 / 36 异步），Router 24 个依赖 |
| 数据库 | schema v35、44 张表、64 个索引、63 个外键（46 个 ON DELETE CASCADE） |
| 错误体系 | GatherErrorCode 177 个 + 43 个服务错误枚举 |
| 并发逃生舱 | 生产代码 52 处 @unchecked Sendable / 23 个生产文件（门禁按含测试口径统计为 47 个文件） |
| 持久化越界 | Services 层 128 处 prepare()，分布在 15 个服务文件 |
| 迁移体量 | Migrations.swift 1,628 行（runMigrationsUnsafe 约 880 行） |
| ADR / review 文档 | ADR 30 条 / 682 行；docs/reviews 20+ 篇 |

---

## 2. 逐层设计评估

### 2.1 契约层（Protocol）：全仓最干净的一层

**做对了**：纯值类型、Codable、无 IO；TS 联合类型 → Swift 枚举逐字对应；错误码集中枚举并配 4 组交叉契约测试（码↔文案、英文覆盖、占位符序列、枚举外裸码）。

**问题**：契约只覆盖"**响应**"，不覆盖"**请求**"。请求是 `[String: JSONValue]` 手工解包（`requiredString / optionalNumber / clampedLimit` 等 20 多个 helper），参数名、可选性、取值范围都靠调用方与实现方口头约定。于是出现两类固定成本：

- 每个命令要写一遍解包 + 校验 + 错误字符串（Router 里 `MISSING_PARAM:x`、`Invalid target: must be ...` 等英文散文散落）；
- 参数越界可触发崩溃：`Int(floor(raw))` 未限幅，`1e300` 会 trap（SessionCommandRouter.swift:2654-2664、796-798；同文件 2861 已有安全版 `clampedInt` 未复用）。

### 2.2 持久化层：可靠性很强，一致性边界很弱

**做对了**（应保留）：

- 迁移前磁盘空间检查 → WAL checkpoint → SQLite backup API → 备份 integrity_check → 失败恢复（ADR-005）；有注入失败的回归测试。
- 连接代数（generation）让 close/reopen 后的旧语句稳定失效；savepoint 支持嵌套事务；busy_timeout=5000 把并发写退化为排队。
- SQL 全 `?` 绑定，动态片段（IN 占位符、列名）来自内部常量；本次未发现注入面。

**结构性问题**：

1. **单连接 + 一把递归锁 = 全局串行点**（DB.swift:116、203-236）。事务全程持锁，读也被串行化，WAL 的读并发被完全放弃；因此任何长事务都会阻塞 UI 与其他后台任务。
2. **事务里做重活和 I/O**：`CullingService.batchUpdate` 在事务内循环最多 1 万次（CullingService.swift:678-705）；`FaceKwService` 把观测替换 + DBSCAN 聚类 + 签名写入放进同一个事务，并在事务内逐张 `stat`（FaceKwService.swift:969-1000）；`SimilarityService` 同构。聚类期间全应用 DB 读写排队。
3. **事务内副作用**：`CullingService.updateState` 在事务内排队写回，事务外才 `schedule`；而 `schedule` 又会同步清 reload-ack 并起 Task（MetadataSyncCoordinator.swift:257-265）。savepoint 回滚后，"已排程写盘 / 已清 ack"不会回滚。
4. **Schema 双真相源**：`SchemaSQL`（新库）与逐版本 `ALTER`（旧库升级）共同定义最终形态。例：`face_clusters.match_confidence` 只在 Migrations.swift:162 添加，Schema.swift 无此列。二者靠"新库也跑一遍迁移"收敛。所谓"列级同形"测试（MigrationTests.swift:503 起）的"升级库"同样由当前 `SchemaSQL` 构造，并非真实 vN-1 旧库，因此**测不出历史漂移**；快照文件只记录表名+版本（docs/fixtures/schema.snapshot.json），列/索引/外键不在契约内。
5. **Repository 边界被穿透**：18 个 Repo 之外，Services 仍有 128 处 `prepare()`。典型如 `SessionService.deleteSessionDependencies`（SessionService.swift:154-168）按依赖顺序手写 8 条 DELETE——"删除顺序"这种 schema 知识落在服务层；而 `SessionRepo.delete` 是公开方法，可绕过该顺序。
6. **反向依赖**：`Image/RAWDecoder.swift:194` 使用 `Database/Repositories/PhotoRepo.rawExtensions`，图像层编译依赖数据库层；`IPC/HelperProtocol` 为 mock 引入业务模型 `SessionData`。
7. **跨聚合一致性没有事务边界**：`writeback_items` 与 `metadata_outbox` 是两套状态机，`WritebackService.confirmSync`（:602-611）先确认 outbox、再标 writeback、再更新 session 状态，三步各自提交；`cleanup`（:642-661）与 `CullingService.cleanup`（:1273-1290）同样是"两次独立调用后把计数相加"。中途失败没有补偿或回放日志。
8. **错误语义被压扁**：整个 DB 层只有 `DBError.message(String)`（DB.swift:35），因此上层只能用字符串判断语义：AnalysisJobRepo.swift:144 匹配 `"UNIQUE"`、Migrations.swift:74 匹配 `"no such table"`、JobService.swift:413 用 `try?` 吞掉恢复错误。BUSY / 约束冲突 / 库损坏无法区分，恢复失败不可观测。
9. **状态机常量分叉**：`analysis_jobs.status` 无 CHECK 约束（Schema.swift:168）；"活跃任务"在 Schema.swift:568 定义为 `queued/running/cancelling`，而 SessionRepo.swift:59 把 `interrupted` 也算 running，AnalysisJobRepo.swift:120 则视其为非活跃。同 dedupe_key 的新旧活跃行可能并存。
10. **多语句读没有快照**：`SimilarityClusterStateRepo` 先读 meta 再读 rows（:99-112 与 :132），中间可能被并发替换；`PersonRepo` 的 count 与分页也是两次独立读（:790/:812）。读到的"总数与内容"可能不一致。
11. **全列覆盖式 upsert 会清空字段**：`MetadataCacheRepo.upsert`（:132-179）对所有列执行 `excluded` 覆盖；当 `MetadataService` 走"仅尺寸"降级路径时（MetadataService.swift:467-472），date_taken/camera/gps 等会被写成 NULL/0。
12. **唯一约束下的合并风险**：`PersonRepo.merge`（:513）直接 `UPDATE person_photos SET person_id`，而表上有 `UNIQUE(person_id, photo_id)`（Schema.swift:623）。当两人同时出现在同一张合影时，整笔合并事务回滚。

### 2.3 服务层：领域划分合理，单体热点集中

**做对了**：服务按领域切分；JobService 是唯一执行器，具备租约、心跳、取消宽限、恢复、去重键与 checkpoint；写回走 outbox 可重试；路径从数据库资产解析而非 UI 传入；大量不变量写进了注释与测试。

**问题**：

- **单类职责膨胀**：CullingService 2,572 行（分页 SQL、资产折叠、状态机、撤销历史、写回编排）；FaceKwService 2,042 行（`analyze` 单函数约 430 行）；MetadataSyncCoordinator 1,230 行（调度/租约/写盘/冲突/清理）；ExportService 1,119 行（规划/复制/转码/水印/报告/续作）。
- **双状态机无共同提交**（见 2.2-7）。
- **DI 形态碎片化**：端口协议、裸闭包、具体类混用；`MetadataMutationService` 反向依赖具体 `MetadataSyncCoordinator`；端口一致性写在消费方文件里（CullingService.swift:114/134）。
- **可测试性受全局时钟/文件系统拖累**：`nowISOString()`、`FileManager.default`、`UUID()` 直接调用，时间与落盘路径无法确定化；仅 WorkspaceStatusService 注入了 clock。

### 2.4 命令 / 宿主层：全仓最大的结构债

`SessionCommandRouter` 同时承担 5 件事：**组合根（makeDefault 装配 24 个服务）、命令分发（两个 switch）、执行器注册（registerExecutors）、参数校验、错误映射**。它 3,258 行、24 个依赖、118 条命令，是典型的上帝对象。

**代价已经显性化**：

- **契约靠文本门禁维持**：`scripts/check-command-surface.sh` 用 grep/正则检查命令是否注册、是否被 UI 调用、同步/异步是否错配；`CommandSurfaceRuntimeTests` 维护一份 118 条手抄黄金清单。没有编译期穷尽性——新增命令要同时改 Router、测试清单，可能还要改门禁注释。
- **命令面被冻结，反向阻塞功能**：ADR 明确"当前 118 条为冻结基线"，人脸簇拆分/试算接 UI 因"需要扩命令面"而迟迟不能做。这是架构限制产品，而不是产品限制架构。
- **两个 switch 语义不对称**：82 条同步命令只在 `execute` 注册，36 条异步只在 `executeAsync` 注册；同步命令误走异步会落到 `DispatchQueue.global` 回退（:2552），异步命令误走同步直接 `NOT_IMPLEMENTED`（:1636）。
- **执行上下文不一致**：多数异步分支包 `Task{}`，但 `navigation.analyze`（:1641-1668）与 `session.create_from_directory`（:2119-2143）在调用线程内联执行。UI 的 `NativeCommandClient.executeAsync` 用 continuation 包装，所以"异步"调用仍可能在主线程跑完整套 DB 分组。
- **错误映射是 OCP 反例**：`errorMessage`（:3167-3231）用约 20 个 `if let ... as?` 分支逐个匹配 43 个错误枚举；新增错误类型若忘记登记，就静默退化成"发生未知错误"。
- **边界被绕过**：Router 公开 4 个服务访问器（:71-97），Gallery/Library/Similarity/App bootstrap 直接调用 `router.sessionService`、`router.jobService`；`GatherApp.importFiles` 又是第三套导入语义（与 `session.create`、`create_from_directory` 并列）。

### 2.5 表现层：两套范式并存，外壳过度集中

- **两套写法**：Sources/GatherApp 下是"独立 VM + DataProvider 协议 + LoadPhase"；根目录 6 个功能页是"VM 与 View 同文件 + 字符串命令"。VM 代码约 4.6k 行写在 View 文件里（CullingView 1-1388、SettingsView、ExportView、DuplicatesView、SessionControlView、FaceKeywordingView）。
- **巨型 View**：CullingView 3,525 行，其中主 View 是单个 struct（约 1,342 行、35 个私有成员）；SettingsView 1,756 行只有一个 body；FaceKeywordingView 2,098 行。
- **RootView 是第二上帝对象**：17 个 `@State`、9 个 onReceive/onChange、手工启停轮询、手工构造/淘汰 4 类 VM（:349-379、:902-929）。
- **生命周期保障有两条死路**：
  - `isActive` 在 4 个页面一律传 `true`（RootView.swift:617/639/665/684），GalleryView 的 `onChange(of: isActive)` 与 `guard isActive` 永远不会生效；
  - `SessionDraftCache.activeSessionId` 只有声明（:295）与读取（:304），全仓无赋值——"不淘汰当前工作区"的承诺实际不成立。
- **语言切换摧毁页面状态**：`.id(languageVersion)` 挂在整个 detail 上（RootView.swift:423），与注释"只重建外壳层文案"及 ADR-025"只挂侧栏"矛盾；切换语言会重置导出配置、挑片选择、人脸步骤。
- **错误退化为文案**：6 个 VM 各自持有 `errorMessage: String?`，错误码在 NativeCommandClient.swift:60-65 就被翻译掉，UI 无法按码决定重试/跳设置。
- **刷新与 stale 守卫四套写法**：Gallery 用 fetchGeneration、Similarity 用 tierRequestID、Library 用 latestRequestID、Culling 用 pageVersion；FaceKw/Duplicates/Export/Settings/ControlCenter 没有守卫。

### 2.6 算法层：纯度好，但"生产接线"与"规模"有落差

- **优点**：Face/Similarity 不依赖 DB；聚类、对齐、匹配都有独立测试；ARI 用两种等价实现互证；对账测试（DHash/Cluster/VectorIndex）有门禁；ADR 对已知偏差写得很诚实。
- **问题**：
  - **ANN 空转**：`CosineHnswIndex`（VectorIndex.swift:104）只有 benchmark 引用；`Matcher` 的 LSH 分支无调用点，生产走全库线性扫描并嵌在簇循环里（FaceKwService.swift:1682）。
  - **"增量"被持久化吃掉**：每次增量保存都 DELETE 全表 + 逐行 INSERT（SimilarityClusterStateRepo.swift:132-161）；meta 只比三个参数，没有算法版本，语义变更后旧状态仍会被复用。
  - **一次全量跑两套实现**：`SimilarityService` 先跑 ClusterEngine，再跑 buildState→ComponentGraph（:763/:772），双份 O(n²)；度门控 BFS 在 6 处重复实现。
  - **DBSCAN 的分配与内存**：每簇循环内重新分配 `queued`，n×dim 缓冲多次复制（10 万×512 ≈ 200MB/份），万级簇时抖动明显。
  - **模型加载在锁内**：EmbeddingModel 在 NSLock 内编译 CoreML 模型并算全量内容指纹（:621-635），首次分析会阻塞所有会话；推理逐张串行，未使用已有的 BatchRunner。

### 2.7 工程化：门禁与文档是亮点，但存在"自己检查自己"的盲区

- 两条门禁（legacy boundary、command surface）+ CI 双工具链构建 + 结构快照测试，整体是同类项目里少见的自律。
- 但命令面门禁是**文本匹配**：它证明了"字符串出现过"，证明不了"参数形状正确、错误码存在、执行器一致"。`check-command-surface.sh` 对 confirmed 的检查只判断"文件里是否有确认弹窗"，不判断调用点归属。
- 文档与实现已出现漂移：ADR-029 写 schema 34/43 表，实际快照是 v35/44 表；ADR-025 写 `.id` 只挂侧栏，代码挂在 detail。文档质量高，但**没有机制保证文档随代码更新**。

---

## 3. 值得保留的设计（不要在重构中丢掉）

1. **ADR + 不变量注释的文化**：每条关键决策记录了"为什么"和"何时允许改"，这比多数团队的架构文档更有价值。
2. **数据库迁移的失败路径**：备份、校验、恢复、幂等、generation、savepoint，是一套完整可验证的可靠性设计。
3. **JobService 单执行器模型**：租约 + 心跳 + 取消宽限 + 恢复 + 去重键 + checkpoint，覆盖了后台任务的主要失败模式。
4. **错误码 → 本地化的交叉契约测试**（4 个方向），以及"文案表不得含枚举外裸码"的守卫。
5. **安全边界**：路径来自数据库资产、删除/写回需要 confirmed、目录 700 / DB 600。
6. **算法层的纯度与对账测试**：合成数据自检、ARI 双实现、生产路径 margin 曲线，边界标注诚实。
7. **无外部依赖、Swift 6 语言模式统一、@Observable 现代化**：构建与运行时的确定性高。
8. **路径规范化 / 逻辑资产折叠 / outbox 重试**等业务不变量，已经沉淀为可测试的代码而非口头约定。

---

## 4. 问题清单（按严重度）

### P0 —— 正确性 / 可用性阻断，建议一个迭代内处理

**A1. 退出可能永久挂起**
- 证据：`prepareForTermination` 顺序 await `jobService.stop()` → `metadataSyncCoordinator.shutdown()` → `db.close()`（SessionCommandRouter.swift:165-169）；`shutdown` 是 `while true` 无 deadline（MetadataSyncCoordinator.swift:665-676）；`applicationShouldTerminate` 只返回 `.terminateLater`，无超时、无幂等闩（GatherAppDelegate.swift:545-552）。
- 影响：任一卡死的 XMP 写入会让应用永远停在"退出中"；重复触发退出可能二次 reply。
- 建议：`shutdown(deadline:)` + 到点强制 `db.close()` + 幂等状态机；`applicationShouldTerminate` 加 watchdog。

**A2. 单连接全局锁 + 主线程同步命令 + 长事务**
- 证据：`DBConnection` 一把递归锁（DB.swift:116），事务全程持锁（:203-236）；`CullingService.batchUpdate` 事务内最多 1 万次（:678-705）；`CullingViewModel` 是 `@MainActor`（CullingView.swift:6），批量更新同步 `client.execute`（:970）；`navigation.analyze` 在 `executeAsync` 里内联（:1641-1668），由 @MainActor VM await 调用（CullingView.swift:380）。
- 影响：大库批量挑片、导航分析、设置写入都可能冻结主线程；后台任务与 UI 互相排队。
- 建议：UI 只允许 async 命令；重命令进后台执行器；事务只包 DB 写，计算移出；DB 引入读连接池或 actor 化。

**A3. 双状态机半提交（无补偿）**
- 证据：WritebackService.confirmSync（:602-611）/ cleanup（:642-661）；CullingService.confirmSync / cleanup（:1273-1290）。
- 影响：outbox 已 synced 而 writeback 仍 written（或反向），UI 计数与真实交付不一致，重试可能重复写或永久阻塞清理。
- 建议：合并为单一交付状态机，或引入 intent + 两阶段提交 + 可回放补偿；用故障注入测试（两步之间抛错）验收。

**A4. 共享可变缓存缺少同步（疑似，需并发压测确认）**
- 证据：CullingService 无锁缓存 `sessionLookupCache` / `sessionUpdateCache`（:347-349），在 `getSessionUpdateContext` 写（:2081-2097）；类未标 Sendable，却经 `@unchecked Sendable` 的 Router 从主线程、`DispatchQueue.global` 回退（:2552）与 Task 分支同时可达。
- 影响：字典并发读写可撕裂，表现为随机崩溃或读到半更新上下文。
- 建议：改用 actor 或加锁；给"命令在哪个执行器上跑"建立类型约束；补并发压力测试。

**A5. 身份合并可能整笔回滚**
- 证据：PersonRepo.merge（:513）直接 `UPDATE person_photos SET person_id`；Schema.swift:623 有 `UNIQUE(person_id, photo_id)`。同一张合影的两个人合并时必然冲突。
- 影响：普通用户操作触发事务回滚，表现为"合并失败"，且错误只会是通用文案。
- 建议：先按 (person_id, photo_id) 去重再更新，或改为 `INSERT OR IGNORE + DELETE`；补合影场景回归测试。

### P1 —— 结构性债务，影响演进、可维护性与规模

**B1. 字符串命令面 + 上帝 Router**（详见 2.4）
- 118 条命令、3,258 行、24 依赖、两个 switch、文本门禁、冻结基线、错误 if-let 映射、参数可 trap。
- 建议路径：`enum Command`（关联 Decodable 参数）+ 注册表（name → handler + executor 语义 + destructive 元数据），`allCases` 自动生成门禁/黄金清单；或退一步，用类型化 `SessionAPI` 门面直接调用服务，仅保留一层中间件做确认/路径授权。

**B2. Repository 边界泄漏 + 反向依赖**
- 证据：Services 128 处 `prepare()`；`SessionService.deleteSessionDependencies` 手写 8 条 DELETE；`RAWDecoder` → `PhotoRepo`；`HelperProtocol` → `SessionData`。
- 影响：schema 变更扩散、服务无法用假仓储单测、删除顺序知识散落。
- 建议：门禁脚本禁止 Services 内 `prepare(`；把 RAW 扩展名等常量下沉到无依赖模块；补 Duplicate/Indexer/Session 的仓储方法。

**B3. 错误模型碎片化**
- 证据：43 个错误枚举；Router 20 分支映射；`WebResponse.error: String`；`CODE::param` 字符串协议；只有部分服务提供 `gatherCode`；DB 层仅有 `DBError.message` 且用字符串匹配 `"UNIQUE"`/`"no such table"`；UI 在 NativeCommandClient 就把码翻译成文案。
- 影响：新错误静默降级；UI 无法按码分支；错误契约测试只覆盖 GatherErrorCode；DB 故障无法分类处理。
- 建议：统一 `GatherError { code, params }`，服务只抛它；DB 层补 typed error（busy/constraint/io/corrupt）；Router 不再逐类型 if-let；UI 接收 `(code, params)` 并在边界翻译。

**B4. 表现层双范式 + 巨型 View + 测试空窗**
- 证据：4.6k 行 VM 写在 View 文件；CullingView 3,525 行；Export/Duplicates/SessionControl 三个 VM 零单测；CullingViewModel 仅同步状态机被测。
- 建议：统一到 `Features/<Feature>/{View,ViewModel,State}`；抽 DataProvider 协议；拆子视图；每个 VM 至少覆盖"加载/空/错误/取消/重入"五态。

**B5. 语言切换摧毁状态，且与 ADR 不一致**
- 证据：RootView.swift:423；ADR-025 的现状描述。
- 建议：`@Observable LanguageStore` 经 Environment 注入，删除 `.id`；若短期保留，至少把 `.id` 移回侧栏并修文档。

**B6. 生命周期死通道**
- 证据：`isActive: true` 硬编码（RootView 617/639/665/684）；`activeSessionId` 无赋值（:295）。
- 影响：隐藏页轮询门控形同虚设；LRU 可能淘汰当前工作区草稿。
- 建议：可见性由单一来源提供（ScenePhase + destination），删除冗余参数；补赋值与单测。

**B7. 规模路径上的"名义增量"**
- 证据：簇状态全量 DELETE+INSERT（SimilarityClusterStateRepo:132-161）；HNSW 零生产引用；LSH 未接；一次全量双算（SimilarityService:763/772）；聚类在 DB 事务内（FaceKwService:969-1000）。
- 影响：10 万级库的增量收益被持久化与全量重算抵消，且锁内计算放大 UI 卡顿。
- 建议：行级 diff/upsert；meta 加 algorithm_version；删除或真正接入 HNSW；单一聚类实现 + 结果断言；先算后写。

**B8. 包/模块边界无法由编译器强制**
- 证据：core 只有 1 个库 target；app 的 `sources` 手工枚举 7 个目录（Package.swift），新增功能目录要改清单；app 可 import core 任意符号。
- 影响：依赖侵蚀已经发生（Image→Database）；无法按层独立构建/测试；无 SwiftUI Preview（全仓 0 个 `#Preview`）。
- 建议：core 拆 `GatherProtocol` / `GatherPersistence` / `GatherDomain` / `GatherAnalysis`；app 拆 `GatherUI`（可预览）与壳；用 target 依赖表达允许方向。

**B9. 测试盲区与非 hermetic 用例**
- 证据：命令运行时测试只验证"命令被识别"；UI 无自动化；`FaceEmbeddingFingerprintTests` 有 1 条写用户主目录的用例，在沙箱下必然失败（本次实测：994 tests / 1 failure，NSCocoaErrorDomain 513）。
- 建议：命令测试改为"类型化参数 golden + 响应形状"；所有测试用临时目录；把已知环境依赖标成 `withKnownIssue` 或注入可写根。

**B10. 数据库状态机与读一致性缺口**
- 证据：
  - `analysis_jobs` 无 CHECK；"活跃"常量与使用方判定不一致（Schema.swift:568 的活跃集合不含 `interrupted`，SessionRepo.swift:59 却把它算作 running）；
  - `SimilarityClusterStateRepo`、`PersonRepo` 的 count+分页是两次独立读；
  - `MetadataCacheRepo.upsert` 全列覆盖，降级提取会清空既有字段（MetadataService.swift:467-472）。
- 影响：任务去重/恢复可能误判；分页 total 与页内容不一致；一次降级扫描丢相机/GPS/日期。
- 建议：状态列加 CHECK；活跃集合收敛到单一常量并配契约测试；Repo 提供"单语句/单事务读"API；缓存 upsert 改"仅更新非 nil 列"或按来源分列。

**B11. 迁移与快照的"假同形"**
- 证据：新库 = SchemaSQL + 迁移；升级库测试也用当前 SchemaSQL 构造（MigrationTests.swift:503 起）；快照仅表名；无 down migration，降级只抛错（Migrations.swift:995）；v32 的 DDL 在事务外（:896-903）。
- 影响：历史 schema 漂移测不出；版本回退无路径；迁移中途失败只能靠整库备份。
- 建议：用真实 vN-1 fixture 做升级同形测试；快照导出列/索引/外键；明确"只前进不回退"的产品决策并写入 ADR。

### P2 —— 工程卫生与长期维护

**C1. 迁移文件与 schema 快照**：Migrations 单文件 1,628 行、`runMigrationsUnsafe` 约 880 行；快照只记录表名+版本；ADR 数字（34/43）与实际（35/44）漂移。建议按版本拆文件、快照扩展为 PRAGMA 导出、文档随迁移自动生成。

**C2. 构建与打包**：build.sh 手工拼 bundle（复制 SPM 资源包、再把 .lproj 复制到主 bundle、可选插件、可选签名），`swift build` 被调用 3 次；无 universal binary；`desktop/native/swbuild.tmp.*` 三个空目录未被 .gitignore 覆盖。建议把 bundle 组装拆成可测试的函数，或迁移到归档脚本；补 .gitignore。

**C3. 文档/注释债**：ADR 682 行、reviews 20+ 篇；代码注释内嵌审计编号（P0-1、F-5、N08、D6…），对新人不可导航且容易过期（ADR-025 已发生）。建议代码注释只留不变量与"为什么"，审计编号迁到文档；建立"文档变更随代码 PR"的检查项。

**C4. 外部进程与文件系统**：CaptureOneBridge 超时只 `terminate()`，不升级 SIGKILL、不可取消、completion 可能被 timeout 与 exit 各触发一次；Sidecar 每次解析都枚举目录做大小写回退，读写为同步 IO。建议抽可注入 `ProcessRunner`（取消/升级杀进程/单次完成），Sidecar 缓存目录索引并下放专用 actor。

**C5. 参数健壮性**：除 A 类主线程问题外，`clampedLimit/clampedOffset/Int64(raw)` 对超范围数值会 trap；建议统一 `Double.safeInt` 并补模糊测试。

**C6. 无障碍与主题**：GatherTheme 引用 248 处，但页面内仍有大量字面尺寸（如 CullingView.swift:1783/1800/2381 附近）；accessibility 相关修饰 159 处，分布不均。建议把间距/尺寸令牌化，补 VoiceOver 标签审计清单。

**C7. 事件/轮询双通道复杂度**：`GatherEventCenter` 单例 + NotificationCenter + 各页 2-30s 轮询 + 4 套 stale 守卫。建议抽出 `RefreshCoordinator`/`PollingPolicy`，把"事件触发 + 轮询兜底 + 可见性门控"收敛为一个可测试组件。

**C8. Repo 行解码脆弱**：行按列位解码（`row[18]`），部分 Repo 无列数 guard（CullingDecisionRepo.swift:34-46、FaceRepo.swift:40-61）；加列/改序会在运行期错位。建议统一 `row.decoded(by:)` 或按列名映射，并补"改 schema 必失败"的测试。

---

## 5. 改进路线（建议分四阶段，绞杀者模式）

### Phase 0：止血（约 1 周）

| 项 | 动作 | 验收 |
| --- | --- | --- |
| A1 | 停机上 deadline + 幂等闩 + 强制 close | 注入卡死 writer，退出 ≤5s；重复退出只回一次 |
| A2 | `navigation.analyze`、`culling.batch_update` 等移出主线程；批量事务分片 | Instruments 主线程单次阻塞 <100ms；1 万张批量不冻 UI |
| A4 | CullingService 缓存加锁或 actor 化；命令执行器约束成类型 | 并发压测 0 崩溃；TSAN 无报告 |
| A5 | 合并前按 (person_id, photo_id) 去重 | 合影合并用例通过 |
| C5 | 统一安全数值转换 | 1e300/-1e300 参数模糊测试不崩溃 |

### Phase 1：契约与边界（约 3-4 周）

| 项 | 动作 | 验收 |
| --- | --- | --- |
| B1 | `enum Command` + 注册表 + 元数据（async/destructive/params）；Router 拆成 `AppEnvironment` + `CommandRegistry` + `JobExecutors` | 新增命令只改 1 个文件；门禁由 `allCases` 生成；118 条一一映射 |
| B3 | 统一 `GatherError`；DB typed error；UI 接收 code+params | 43 个错误枚举全部映射；无"未知错误"兜底路径 |
| B2 | Services 禁止 `prepare(`；补仓储；RAW 常量下沉 | 门禁 0 命中；Image 层不再 import Database |

> 迁移策略：保留 JSON envelope 适配器一个版本，先把"调用方 → 类型化 API"切换完，再删旧 switch；避免一次性重写 3258 行。

### Phase 2：结构与状态（约 6-8 周）

| 项 | 动作 | 验收 |
| --- | --- | --- |
| B4/B6 | `SessionWorkspace` 持有 4 类 VM + 意图队列；RootView 只留导航；删除 isActive 死通道 | RootView < 400 行；新增页面不改外壳；VM 单测覆盖五态 |
| B5 | LanguageStore + Environment，删除 `.id` | 切语言后页面选择/草稿保留；ADR 与实现一致 |
| B8 | 拆 target：Protocol / Persistence / Domain / Analysis / UI | 依赖方向由 Package.swift 强制；UI target 可 Preview |
| A2 | DB 读连接池或 actor；长事务移出 | 聚类/索引期间 UI 查询 P95 < 50ms |

### Phase 3：规模与工程化（持续）

- B7：簇状态行级 diff/upsert；算法版本进 meta；HNSW 要么接线要么删除；单一聚类实现 + 结果一致性断言。
- B10/B11：状态 CHECK 与单一活跃常量；真实旧库升级测试；快照导出列/索引/外键。
- C1/C2/C4：迁移按版本拆文件；打包脚本函数化 + .gitignore；ProcessRunner 可取消、可升级杀进程。
- B9：命令参数 golden 测试、VM 单测、测试 hermetic 化（临时目录注入）。

---

## 6. 结论

Gather 的**可靠性底座**（迁移、备份、任务、写回、错误码、测试）是同类项目中的上乘水平，绝大多数"数据会不会丢、任务能不能恢复"的问题已经被认真回答过。真正的问题不在"有没有想到"，而在**移植期的抽象没有随原生形态一起演化**：

- 进程内调用却保留了 IPC 的字符串信封；
- 单一组合根演化成了上帝 Router；
- 单连接简化演化成了全局串行点；
- 单 target 的便利演化成了无法强制的分层；
- 页面常驻的取舍演化成了手工生命周期与死门控。

这些都属于"**结构债**"而非"**缺陷债**"：它们不会每天报错，但会持续抬高每次改动的成本，并在规模（10 万张、多窗口、长任务）与演进（新命令、新页面、新模型）时集中兑现。建议按 Phase 0 → 3 推进，先解决会冻结/挂起/半提交的五项，再用类型化命令面换掉最大的结构债；其余改造都应在类型化边界建立之后进行，否则会在旧抽象上叠加新抽象。

---

## 附录 A：本报告关键指标的复现命令

```bash
# 规模
find desktop/native -name '*.swift' -not -path '*/.build/*' | xargs wc -l | tail -1
# 命令面 / 依赖数
grep -cE '^[[:space:]]+case "[a-z_]+\.[a-z_]+"' desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
# 服务层内联 SQL
grep -rn 'prepare(' desktop/native/gather-core/Sources/GatherCore/Services --include='*.swift' | wc -l
# 并发逃生舱
grep -rn '@unchecked Sendable' desktop/native/gather-core/Sources desktop/native/gather-app/Sources --include='*.swift' | wc -l
# 门禁
./scripts/check-command-surface.sh
./scripts/check-no-legacy.sh
# 测试
cd desktop/native/gather-core && swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
cd desktop/native/gather-app  && CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch
```

## 附录 B：本次评审的验证边界

- **已实测**：gather-core 994 tests / 141 suites，1 条失败为沙箱禁止写用户主目录的环境性用例（非产品缺陷）；gather-app 298 tests / 32 suites 全绿（2026-10-21 本机）。
- **已实测**：两条门禁脚本通过（命令面 118/118；legacy 4 条 enforced 规则通过）。
- **未做**：GUI/交互/视觉人工验收、真实 Capture One 端到端、10 万级真实库压测、TSAN/Instruments 运行、签名/公证。
- **静态推断**：A4 的并发风险、B7 的内存峰值、C4 的进程泄漏为代码阅读结论，需压测/注入验证后才可定性为缺陷。
- 报告中所有行号以当前工作区为准（HEAD 82603e0）；若后续重构，请以符号名为准。

---

*评审人：AI 架构审计（只读）· 2026-10-21*
