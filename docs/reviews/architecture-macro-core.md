# Gather core 四层宏观架构评审（HEAD 30f51f0）

> **性质**：只读宏观评审。本文件是唯一产出；未改源码 / 测试 / Package.swift / 脚本，未提交。
> **快照**：2026-10-22，HEAD 30f51f0，git status 干净。
> **口径**：**【已确认】** = 有 文件:行 或实测计数；**【疑似】** = 需运行/大库验证，本次未复现。
> **与旧评审的关系**：R1/R2/R4/R7 已记录 bug 级清单，本文件不重复；这里只回答「结构为什么会长出那些 bug」。未执行构建与测试（见 §8）。

---

## 0. 结论先行

1. **四层模块边界成立，且是这次重构最扎实的成果**：依赖图无环——GatherProtocol 的 66 个 import 全是 Foundation，GatherAnalysis 对 Persistence/Domain 的 import 为 0，GatherPersistence 对 Domain/Analysis 为 0，GatherDomain 对 CSQLite 为 0；explicit-target-dependency-import-check 把它变成编译期事实，不是文档约定。
2. **问题不在模块之间，在模块之内**：GatherDomain 占 4 层 45.0%（28 文件 / 19,224 行），最大 5 个文件 = 10,111 行（core 的 23.6%、Domain 的 52.6%），它们同时承担读模型、命令、事务、文件编排、跨服务编排五种角色。
3. **没有应用层**：一个用例被切成三段——Protocol/API/Inputs 校验、Domain/Services 编排、Host/APIs 做错误映射并**直接持有 8 个 Repo、19 处直调**。Database 门面的 read/write/async 生产调用点为 **0**（只有测试用），Cut 2 声称的「Service 不再自己管连接与事务边界」（Database.swift:9）没有落地：**16 个 Domain 文件持裸 DBConnection、40 处 connection.transaction、58 条内联 SQL**。
4. **交付（delivery）聚合没有单一 owner**：状态机在 Persistence，编排在 DeliveryCoordinator，写盘在 WritebackService，入队在 MetadataMutationService，**冲突裁决/孤儿处理在 Host 的 LiveMetadataAPI**。35 处状态写入分散在 4 个类型 / 2 个模块。R2 的 P1-10 就是「谁都能翻状态」的结构产物。
5. **Protocol 不是「过度暴露」，是「历史沉积 + 双词汇」**：347 个公开类型 / 1,752 行公开声明 / 16 协议 110 方法 / 179 错误码；其中 **89 个类型完全无引用（942 行）**、**6 个 Router 时代 JSON 信封类型（Core.swift:160-320，约 270 行）**、1,028 个公开字段、342 个公开 init（约 1 类型 1 个，等于没有构造不变量）。
6. **不建议大架构换血**。按收益/成本排序：先删契约死面、再做交付切片、再把用例上收，最后才考虑拆 Culling/FaceKw。

---

## 1. 方法

静态计数（find/grep，命令见附录 A）+ 逐文件读关键路径（Database 打开/重置、DeliveryRepo.confirm、DeliveryCoordinator 的 cleanup/replay/finish、LiveMetadataAPI 的冲突裁决）。未做：swift build / swift test、大库压测、GUI 验收。

### 1.1 规模（实测）

| 模块 | 文件 | 行 | 占 4 层 | 公开类型 | 公开声明行 |
| --- | ---: | ---: | ---: | ---: | ---: |
| GatherProtocol | 68 | 7,598 | 17.8% | 347 | 1,752 |
| GatherPersistence | 30 | 10,865 | 25.4% | 121 | 989 |
| GatherAnalysis | 16 | 5,078 | 11.9% | 70 | 361 |
| **GatherDomain** | **28** | **19,224** | **45.0%** | 94 | 602 |
| 合计 | 142 | 42,765 | 100% | 632 | 3,704 |

> 另有 3 个可执行（GatherSchema + 2 benchmarks）697 行，故 Sources/ 全量为 145 文件 / 43,462 行。

---

## 2. 四层体检：依赖方向、边界、内聚

### 2.1 依赖方向：成立（0 环）【已确认】

| 边 | 实测 | 判定 |
| --- | --- | --- |
| Protocol → 任何下层/系统 ML | import Foundation ×66，其它 0 | 纯 Foundation，UI 可单独依赖 |
| Persistence → Domain/Analysis | 0 | 无反向依赖 |
| Analysis → Persistence/Domain | 0 | 算法层可独立跑基准 |
| Analysis → CSQLite | 0 | 算法层不碰 SQL |
| Domain → CSQLite | 0 | 只有 Persistence 碰 C API |
| Domain → Persistence / Analysis / Protocol | 22 / 9 / 22 个文件 import | 合法宽边 |

### 2.2 边界：模块级干净，模块内漏【已确认】

- Database 门面声称三个作用域，实际生产 0 调用：read/write/async（Database.swift:208/213/221）只有 DatabaseFacadeTests 引用；组合根把 database.connection（AppComposition.swift:110）直接发给所有 Repo/Service。
- 结果：**16/28 个 Domain 文件持 private let connection: DBConnection**（CullingService.swift:289、DeliveryCoordinator.swift:475、WritebackService.swift:180、SimilarityService.swift:151…）。
- 上层同样绕过：GatherHost/APIs 有 8 个 Repo 字段、19 处直调（LiveMetadataAPI.swift:54 持 DeliveryRepo，:362-395 直接 markWriting/markWritten）。
- 即：**「谁能碰数据」没有边界，只有「谁能 import 哪个模块」有边界**。

### 2.3 内聚：越往下越混

| 指标 | Protocol | Persistence | Analysis | Domain |
| --- | ---: | ---: | ---: | ---: |
| 最大文件 | Core.swift 707 | DeliveryRepo 1,325 | ClusterGraph 1,119 | CullingService 2,800 |
| 前 5 文件占本层 | 32% | 49% | 64%（ClusterGraph 单文件 1,119） | **53%** |
| 直接 SQL | 0 | 190 处字面量 | 0 | **58 条 / 13 文件** |
| 事务 | 0 | repo 内 | 0 | **40 处** |
| 每服务依赖 | — | — | — | 9–11 |

GatherAnalysis 是唯一「纯」层：16 文件 / 5,078 行 / 70 公开类型 / 只依赖 Protocol + 系统框架，没有 SQL、没有文件 IO、没有服务间调用。它证明这套分层**可以**做干净；Domain 没做到不是分层的问题，是 Domain 被当成了「什么都能放」的层。

---

## 3. Domain 作为应用服务层：职责与三个张力

### 3.1 五个大文件的实测画像

| 文件 | 行 | public 方法 | 构造依赖 | 内联 SQL | 事务 | 混装的职责 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| CullingService.swift | 2,800 | 23 | 9 | 2 条 + 谓词拼接 | 4 | 读模型（分页/摘要/分组）、命令（CAS/批处理/历史）、会话上下文缓存、写回/清理编排 |
| FaceKwService.swift | 2,544 | 14 | 10 | 4 条 | 8 | 推理作业、簇编辑、预览、写回、确认/清理 |
| DeliveryCoordinator.swift | 1,964 | 25 | 10 | 1 条 | 2 | 文件端口 + 结果 DTO + saga 编排 + 3 个模块适配器 |
| SimilarityService.swift | 1,511 | 12 | 9 | 4 条 | 4 | 聚类作业、结果查询、写回/清理 |
| WritebackService.swift | 1,292 | 11 | 11 | 0 | 0（走 Repo） | XMP 文件写、租约、失败重试、交付状态推进（18 处） |

补充：
- CullingService 同时持 4 个 Repo + 裸连接 + 3 个端口 + 设置读取闭包（CullingService.swift:285-296），典型 God service 形状。
- **DeliveryCoordinator 的 25 个 public 方法里 15 个是三个模块适配器**（:1806-1960），每个方法体就是「把 module 写死再转发一行」——同一组 5 个操作 × culling / face-keyword / similarity。60% 的公开面是复制。
- @unchecked Sendable 共 35 处（Domain 19 + Persistence 4 等），线程安全仍以「约定 + DBConnection 递归锁」为主。

### 3.2 三个最重要的架构张力

#### T1｜Domain 同时是领域层与数据访问层

服务既表达业务规则（revision CAS、历史栈、门控），又直接写 SQL、开事务、读会话行。

- 证据：58 条内联 SQL 落在 13 个服务文件，覆盖约 28 张业务表（photos 46 次、duplicate_group_members 16、photo_metadata_cache 13、person_photos 10、delivery* 10）；DuplicateService.swift:455-465 直接 DELETE/INSERT duplicate_groups；DeliveryCoordinator.swift:616 直接读 sessions.reload_acked_at（绕过 SessionRepo）；FilterEngine.swift:91-95 拼 SELECT；CullingService.swift:1655 拼谓词。
- 代价一：**写路径的锁粒度由业务代码决定**。单连接 + NSRecursiveLock 下，任何 connection.transaction 期间全库写被阻塞；CullingService.updateState 的事务里做两次批量读 + 逐张状态写入 + 历史插入（:524-620），事务长度与业务分支同阶。
- 代价二：**无法脱离 SQLite 做单测**。Domain 的 30 个测试文件里 26 个直接构造 DBConnection/makeTestDatabase；Persistence 里没有任何 Repository 协议（只有 DBValueDecodable、MetadataCodedError 两个非仓储协议），「给 CullingService 一个假 Repo」今天做不到。
- 【疑似】Database.open 每次启动执行 PRAGMA foreign_key_check（Database.swift:566），成本随库线性增长；10 万照片级启动耗时会进 UI 热路径，本次未压测。

#### T2｜没有应用层：用例被切成三段，且 Host 是「第二领域层」

| 段 | 位置 | 职责 |
| --- | --- | --- |
| 输入校验 | Protocol/API/Inputs（1,793 行 / 15 文件） | 非空、范围、枚举、`Confirmed<T>` |
| 编排 | Domain/Services（19,224 行） | 业务规则 + SQL + 事务 + 文件 |
| 适配 | Host/APIs（4,059 行 / 18 文件） | 二次校验 + GatherError 映射 + **直调 Repo** |

- 改一个用例要动 2–4 个文件、跨 3 个模块；CullingAPI 的 17 个方法在 Protocol/CullingInputs、Domain/CullingService、Host/LiveCullingAPI 三处各有逻辑，且三处都写校验（Host 里 `invalidParameter` 43 次，Protocol Inputs 里 `GatherError` 15 次、其中 `invalidParameter` 6 次）。
- LiveMetadataAPI（484 行）不是适配器而是**用例实现**：resolveConflict（:132）、resolveOrphan（:186）、acceptExternalState（:373）自己驱动 markWriting → resetConfirmations → markWritten，即 delivery 状态机的一段在这里走。冲突裁决属领域规则，却住在 app 包，core 测试覆盖不到。
- 这解释了 R1「15 个方法无 Live 行为测试」：Live 层在 core 之外，core 测试天然够不着。

#### T3｜交付聚合被 5 个类型 / 2 个模块共管，saga 边界不闭合

- **状态写入点 35 处**：WritebackService 18、DeliveryCoordinator 9、LiveMetadataAPI 7、MetadataMutationService 1。DeliveryStatus.canTransition 有 8 个校验点（DeliveryRepo.swift:348/472/625/704 等），但 confirm 用 SQL 条件 status='written' 直接翻 synced（DeliveryRepo.swift:1194-1260），「唯一真相源」只管了一半。
- **DB 删除与 intent 收尾仍是两个事务**：applyCleanupDB 自己开事务（DeliveryCoordinator.swift:1615），返回后 :1712 再 intentRepo.finish(id:)（内部又开一个事务，DeliveryIntentRepo.swift:281）。设计 §4.3 要求同一事务；当前靠 alreadyGone 幂等兜底能自愈，但崩溃窗口里「文件已恢复、DB 已删、intent 还在」三种事实并存。
- **文件阶段与 DB 阶段之间没有共同的版本守卫**：cleanup 的 CAS 在 DB 段，文件段只持 XMPFileLock。R2 的 P0-1 已修（intent payload 增 baseFingerprint，DeliveryCoordinator.swift:336），但结构上「文件正确性」仍由编排代码逐分支手工保证，不是聚合不变量。

### 3.3 反证：同一个 Domain 里也有做对的

FaceKwService.analyze（:524-970）已是「短事务读快照 → 锁外推理 → 分片短事务提交」（:571 快照、:655 起分片写），模型迁移在 DB 外准备。说明团队已掌握正确形态；缺的是**统一**，不是认知。

---

## 4. Persistence：Repository、单连接、Schema 重置、Delivery

### 4.1 Repository vs 内联 SQL：两条路都在走

| 项 | 实测 |
| --- | --- |
| Repo 规模 | 17 个 Repo 类 + 1 查询对象（DeliverySummaryQuery）+ 支持文件 = 7,929 行，占 Persistence 73% |
| Repo 公开成员 | FaceRepo 40、DeliveryRepo 34、PersonRepo 25、AnalysisJobRepo 17（含每个类 1 个 public init） |
| Repo 协议 | **0**（只有具体类） |
| Domain 内联 SQL | 58 条 / 13 文件 / 125 处 connection.prepare / 约 28 张表 |

同一张表两层同时写 SQL：duplicate_groups（只在 DuplicateService）、photos（PhotoRepo + 46 处服务内查询）、deliveries（DeliveryRepo + Coordinator + LiveMetadataAPI）、sessions（SessionRepo + DeliveryCoordinator:616 + SessionService:147-157）。

- 后果 1：Schema 变更要 grep 全仓；check-select-star 只防 SELECT *，防不了列名写错。
- 后果 2：仓储的「唯一入口」承诺失效——DeliveryRepo 的 CAS 语义可被任何持连接的服务绕过。

### 4.2 单连接 + WAL + NSRecursiveLock：能用，但把并发策略写死在最底层

- 事实：SQLITE_OPEN_FULLMUTEX（DB.swift:208）、journal_mode=WAL（:215）、busy_timeout=5000（:220）、每条 SQL 在 connectionLock（NSRecursiveLock，:250）下执行；门面另有 stateLock（Database.swift:101）保证 close 与 body 互斥。
- 读池明确延后（Database.swift:27-29，D-035 #2）：读写共用一条连接，长读阻塞写，事务内读不是快照隔离。
- 在 SQLite 单写者模型下这是合理起点，但把「事务预算」变成全局约束：40 处服务事务里任何一处变长，全 app 写延迟都变长；而事务长度由业务分支决定，没有度量（设计 §4.4 提过「2,000 行 / 250ms warn」，当前全仓无慢事务日志）。
- 优点也要说清：单连接 + 递归锁让 transaction 可嵌套（SAVEPOINT），Repo 与服务自由组合，这是 Cut 2 能快速收敛的前提。

### 4.3 SchemaV1 重置：策略正确，但「版本」其实是构建指纹

- 事实：43 表 / 373 列 / 69 索引 / 62 FK / user_version=1（SchemaV1.swift:46-58）；同版本靠 expectedShapeFingerprint（:80，SHA-256）+ 计数 + 关键列三重比对（Database.swift:466-515）；不匹配则把 -shm → -wal → 主库整体改名 .incompatible-<ts> 并重建，保留 3 份（:583-640）。
- 这是开发期最诚实的选择：不做迁移链、不静默改库、顺序正确（先 sidecar 防「新库 + 旧 WAL」）。**保留**。
- 代价：**5 个手写常量 + 1 个指纹是 DDL 之外的第二真相源**。开发期「改 V1 不 bump 版本」意味着每次 DDL 变更都要同步 5 个数 + 重算指纹；漏改的失败模式是「启动即报 schema 不符」（响亮，可接受），但也会把用户库整体改名（开发期可接受）。
- 【疑似】foreign_key_check 全库扫描在每次 open（Database.swift:566），大库冷启动成本未测。

### 4.4 Delivery：状态机与 Intent 设计对，归属错

做对的部分（应保留）：
- DeliveryStatus 7 态 + canTransition 单表（DeliveryState.swift:36-96），非法转移抛错不静默；DB CHECK 只兜字符串（SchemaV1.swift:669/701）。
- Intent 三相位 prepared → fileDone → applied（DeliveryIntentRepo.swift:41-52），回放按相位分支：prepared 重做文件、fileDone **只补 DB 段**（:158-163），正确的「文件不可重放」设计。
- cleanup 的候选/门禁/DB 段都在 revision + status 双守卫下（DeliveryCoordinator.swift:1604-1650）；deleteSyncedDelivery 单事务（DeliveryRepo.swift:1136）。

结构性缺口：① 状态机有 4 个推进者（T3），confirm 绕过 canTransition 用 SQL 条件判定；② DB 删除与 intent.finish 两事务；③ 读写模型混在同一 Repo（DeliveryRepo 1,325 行 + 单独的 DeliverySummaryQuery 382 行方向对，但没形成「读走 Query、写走 Repo」的规则）。

### 4.5 可扩展性 / 可测试性

| 维度 | 现状 |
| --- | --- |
| 加一个新域 | 动 Protocol（输入/输出/协议）+ Domain（服务）+ Host（Live 实现）+ Persistence（SQL/Repo）4 处 |
| 改一条查询 | 可能落在 Repo 或服务内联 SQL，需 grep 全仓 |
| Domain 单测 | 26/30 测试文件要真库，无法注入假 Repo |
| 换存储 | 不可行（16 文件持 DBConnection 与 SQLite 方言） |
| 事务可观测性 | 无预算、无慢事务日志 |

---

## 5. Protocol 契约面：16 协议 / 110 方法 / 1,752 行公开声明

### 5.1 数字

| 项 | 实测 |
| --- | --- |
| 文件 / 行 | 68 / 7,598（API 452 + Core 220 + Inputs 1,793 + Outputs 283 + Errors 54 + 传统 Protocol 4,724 + Logging 72） |
| 公开类型 | 347（270 struct / 59 enum / 18 protocol） |
| 公开声明行 | 1,752（字段 1,028 + init 342 + func 29 + 类型 347） |
| 域协议 / 方法 | 16 / 110（Culling 17、Face 13、Similarity 10、Person 8…） |
| 错误码 | 179（Protocol/Core.swift:321-535） |

### 5.2 两套 DTO 词汇，边界不清

Protocol/（传统 249 类型 / 4,724 行）是 Router 时代响应 DTO；API/Inputs（95 类型 / 1,793 行）是新输入；API/Outputs 只有 283 行。于是 **API 返回类型大多仍是传统 DTO**——93 个有返回值的方法里，21 个返回类型的声明在传统 Protocol/（WritebackResult、CleanupResult、MetadataSyncSummary、SimilarityResult、TemplateData、SessionData…），13 个在 API/Outputs，其余是基本类型/容器。新契约寄居在旧形状上（CullingUpdateResult 同时是 UI 渲染模型和命令返回）。

### 5.3 死面：89 个类型完全无引用（942 行）+ 6 个信封

- 方法：347 个公开类型名在 Persistence/Analysis/Domain/gather-app/Sources 中查引用 → 105 个模块外无引用；再在 Protocol 内查非注释引用 → **89 个只有声明本身**。
- 典型：CullingUpdateParams、SimWritebackParams、SessionCreateParams、FkwAnalyzeParams… 共 60 余个 *Params；另有 FaceCluster、FaceObservation、BindingData、DupScanOptions。
- 6 个 Router 信封：ResponseID（Core.swift:160）、ErrorDetail（:184）、ResponseErrorBody（:197）、ResponseOk（:220）、ResponseErr（:256）、Response<T>（:292），约 270 行，生产 0 引用。
- 合计 **约 1,200 行 / 95 个公开类型可删**，占 Protocol 公开类型 27%。

### 5.4 形状不一致：Confirmed 与 sessionId 两套门禁

- 29 个方法收 `Confirmed<T>`，但 **18 个方法只收裸 `sessionId: String`**，其中 8 个会改状态：flush、retrySync、confirmSync（Culling/Face/Similarity 各一）、cancel、cancelAnalysis（两处）。「没有确认弹窗就写不出调用点」只覆盖一半。
- 13 个方法返回 Bool（reset、confirmSync、cancel、unbind…），丢掉「为什么失败/是否部分成功」；同一 API 其它方法返回结构化结果，语义不一致。
- 参数风格三分：`page(_ query:)`、`groups(_ sessionId:)`、`reset(_ input: Confirmed<...>)` 并存。

### 5.5 179 错误码

保留 179 项是 D-010 既定裁决，本文不主张砍；但有两个结构后果：① GatherError.retryable 只硬编码 5 个码（GatherError.swift:34-41），其余 174 个「可重试性未知」，重试策略没有单一来源；② 每个码都要在 en/zh-Hans 两套表出现，错误码成为 UI 本地化表最大单一来源（R5 已记 parity 缺口）。

### 5.6 结论

Protocol 的问题不是「协议太多」（16 个域协议合理），而是**契约里混着三代产物**——Router 的 *Params 与 Response*、Schema 时代的读模型、Cut 1 的新输入。公开面比实际需要大 27%，新旧形状并存，让「哪套是契约」需要读注释才能判断。

---

## 6. 目标架构选项（含取舍）

> 前提：四层 target 结构保留（它已成立）；以下都是**层内重构**，不是再拆模块。成本按 1 人估。

### O-1｜Delivery 垂直切片（推荐）

做法：把 delivery 收成一个内聚单元（GatherDelivery target 或 GatherDomain/Delivery/）：状态机 + 3 个持久化对象 + saga（原 Coordinator 去掉 DTO 与适配器）；对外只暴露一个 DeliveryAPI：enqueue / confirm / cleanup / finalize / replay / resolveConflict。关键结构修正：finish 接受调用方事务（finish(in: Transaction)），DB 删除 + intent 收尾同事务；3 个模块适配器收敛为 1 个带 module 参数的端口（15 个 public func → 5）；把 LiveMetadataAPI 的 resolveConflict/resolveOrphan 迁回切片。

收益：状态写入点 35 → ~8；Host 少约 300 行；崩溃恢复只有 1 个实现；P1-10 类「谁都能翻状态」从结构上消失。
成本：6–8 人日。风险：中（最敏感路径，但已有 121 个 Delivery 相关测试兜底）。

### O-2｜应用层显式化（用例上收，Host 只做装配）

做法：把 18 个 Live*API 从 GatherHost 移入 core（新 target GatherApplication 或 GatherDomain/API/），只依赖 Domain 门面类型，不 import Repo；Host 只保留 AppComposition/AppRuntime/AppBootstrap 与 DTO→UI 适配。
收益：用例逻辑可被 core 测试覆盖（直接解决 R1「15 个方法无 Live 行为测试」）；Host 4,059 → ~1,500 行；改用例只动 2 处。
成本：5–8 人日（机械搬家 + 抽 8 个 Repo 依赖）。风险：低–中（编译期就能发现越界）。
取舍：不做的话 Host 会持续长成「第二领域层」——LiveMetadataAPI 已经证明了这一点。

### O-3｜读模型先行 + DB 边界 ratchet（渐进）

做法（可分两次交付）：① 在 Persistence 内建 3 个读模型（CullingReadModel / PhotoReadModel / DeliveryReadModel），把 Domain 58 条 SQL 中约 40 条只读查询迁走，Domain 只保留命令路径的 connection.transaction；② 对测试最重的 3 个服务（Culling/FaceKw/Similarity）引入 3–4 个窄端口，其余不动。同步加门禁：Domain 内新增 connection.prepare 字面量 SQL = 0。

收益：Domain SQL 58 → ≤15；读路径可 fake（页面级测试不必建库）；单文件缩 20–30%。
成本：读模型 5 人日 + 端口 8 人日。风险：中（逐条搬 SQL，必须逐条对照现有测试）。
取舍：**不建议**全量端口化（17 个 Repo 全加协议 = 10–15 人日，多数 Repo 只有一个消费者）。

### O-4｜Culling/FaceKw 按角色拆分（最后做）

做法：每个大服务拆 3 个角色：Queries（读模型）、Commands（CAS + 事务）、DeliveryAdapter（端口），依赖 9 个降到 3–4 个。
收益：5 个 1,292–2,800 行文件 → 约 15 个 ≤700 行文件；每角色可独立单测。
成本：10–15 人日。风险：中高（revision CAS、历史栈顺序、会话上下文缓存 TTL 都是隐含语义）。
取舍：只有 O-3 完成后做才便宜；单独做只是「大类改小类」，依赖数不变。

### 6.1 选项对照

| 选项 | 主要收益 | 成本（人日） | 风险 | 前置 | 顺序 |
| --- | --- | ---: | --- | --- | ---: |
| O-1 Delivery 切片 | 状态 owner 唯一、同事务、去重 15 个转发方法 | 6–8 | 中 | 无 | 2 |
| O-2 用例上收 | 用例可测、Host 瘦身 60% | 5–8 | 低–中 | 与 O-1 的 metadata 部分重叠 | 3 |
| O-3 读模型 + 端口 | Domain SQL −74%、可 fake | 5 + 8 | 中 | 无 | 4 |
| O-4 大服务拆角色 | 单文件 ≤700、依赖 ≤4 | 10–15 | 中高 | O-3 | 5 |
| （附）协议瘦身 | 公开面 −27% | 2 | 低 | 无 | 1 |

**明确不建议**：① 事件溯源/CQRS 全套（没有多读端压力，代价远超收益）；② 再拆 target（7 个已够，拆细只是把 import 负担转给调用方）；③ 为「可测试性」给全部 Repo 加协议。

---

## 7. 建议（按收益/成本排序）

| # | 建议 | 收益 | 成本 | 验收（可复跑） |
| ---: | --- | --- | ---: | --- |
| **R1** | **协议瘦身**：删 89 个死类型 + 6 个信封；*Params 只留 12 个被 API 直接复用的；Bool 返回改结构化结果 | 公开面 −27%、契约可读、grep 可判定「哪套是契约」 | 2 人日，低风险（纯删除 + 测试改 import） | 死类型 = 0（附录 A-5）；Protocol 公开行 ≤1,500；core/app 测试绿 |
| **R2** | **交付切片**（O-1）：单一 owner + finish(in:) 同事务 + 单适配器 | 状态写入点 35→8；消除两事务窗口；3 组适配器 → 1 | 6–8 人日，中风险 | 状态写入 grep 只命中 1 个切片文件；intentRepo.finish 在事务外 = 0；Delivery 测试全绿 |
| **R3** | **用例上收**（O-2）：Live API 进 core，Host 禁持 Repo | 用例可测；Host −2,500 行；改用例只动 2 处 | 5–8 人日，低–中（与 R2 的 metadata 部分合并） | Host/APIs 中 Repo 调用 = 0；Host/APIs ≤1,800 行；core 新增 ≥15 个用例行为测试 |
| **R4** | **读模型 + DB 边界 ratchet**（O-3 第一步） | Domain SQL 58→≤15；读路径可 fake | 5 人日，中风险 | connection.prepare 计数 ≤40 且新增 = 0（门禁 domain_sql_literals） |
| **R5** | **Culling/FaceKw 拆角色**（O-4） | 5 个巨文件 → 15 个 ≤700 行；依赖 9→3 | 10–15 人日，中高（最后） | 单文件 ≤700；每服务构造依赖 ≤4；Culling/Face 测试绿 |

排序理由：R1 是唯一「零行为风险、立刻缩小认知面」的动作；R2/R3 治同一个病（没有 owner 的用例），合并做可少改一次 metadata 路径；R4 是「先让脏东西不再增长」的止血；R5 收益最大但必须等前三项把边界稳定后再动。

---

## 8. 未执行 / 限制

- **未执行 swift build / swift test**：本任务为只读宏观评审；文中所有「测试覆盖」陈述来自测试文件结构与旧评审记录，不是本轮实测。
- **未做**：真实大库（≥10 万照片）Database.open 冷启动压测 → foreign_key_check 成本为【疑似】；崩溃注入验证 intent 两事务窗口；GUI 验收。
- **未复核**：docs/refactor-progress.md 的 Cut 状态与本文结论的一致性（不在任务范围）。
- 未更新 docs/reviews/README.md（索引维护不在授权范围）。

---

## 附录 A：复现命令

    cd /Users/panzeyu2013/Desktop/code/develop/Gather/desktop/native

    # A-1 四层规模
    for d in GatherProtocol GatherPersistence GatherAnalysis GatherDomain; do
      n=$(find gather-core/Sources/$d -name '*.swift' | wc -l)
      l=$(find gather-core/Sources/$d -name '*.swift' -print0 | xargs -0 cat | wc -l)
      echo "$d files=$n lines=$l"
    done

    # A-2 依赖边（应为 0）
    grep -rhE '^import (GatherPersistence|GatherDomain)' gather-core/Sources/GatherAnalysis | wc -l
    grep -rhE '^import (GatherDomain|GatherAnalysis)' gather-core/Sources/GatherPersistence | wc -l
    grep -rhE '^import CSQLite' gather-core/Sources/GatherDomain | wc -l

    # A-3 Domain 的 SQL / 事务 / 连接
    grep -rnE '"(SELECT|INSERT INTO|UPDATE |DELETE FROM|WITH )' gather-core/Sources/GatherDomain | wc -l
    grep -rho 'connection.transaction' gather-core/Sources/GatherDomain | wc -l
    grep -rl 'private let connection: DBConnection' gather-core/Sources/GatherDomain | wc -l

    # A-4 门面作用域的生产调用点（应为 0）
    grep -rnE '[.]read|[.]write' gather-core/Sources gather-app/Sources | grep -v Database.swift

    # A-5 Protocol 死类型
    grep -rhoE '^public (struct|enum|final class|class|protocol|actor) [A-Za-z0-9_]+'       gather-core/Sources/GatherProtocol --include='*.swift' | awk '{print $3}' | sort -u > /tmp/prot_types.txt
    # 逐个在 gather-core/Sources/{GatherPersistence,GatherAnalysis,GatherDomain} 与 gather-app/Sources grep；
    # 再在 GatherProtocol 内按「非注释引用数 <= 1」过滤 = 89。

    # A-6 交付状态写入点
    grep -rn 'markWriting|markWritten|mergeInput|resetConfirmations|deleteSyncedDelivery'       gather-core/Sources gather-app/Sources | sed 's/:.*//' | sort | uniq -c

    # A-7 契约规模
    grep -rhE '^    func ' gather-core/Sources/GatherProtocol/API/*.swift | wc -l    # 110
    grep -rhE '^[[:space:]]*public[[:space:]]' gather-core/Sources/GatherProtocol | wc -l  # 1752

## 附录 B：证据索引

| 结论 | 位置 |
| --- | --- |
| 门面作用域 0 生产调用 | Database.swift:208/213/221；AppComposition.swift:110 |
| 16 个 Domain 文件持裸连接 | CullingService.swift:289、DeliveryCoordinator.swift:475、WritebackService.swift:180、SimilarityService.swift:151 等 |
| Domain 内联 SQL | DuplicateService.swift:455-465、DeliveryCoordinator.swift:616、FilterEngine.swift:91-95、CullingService.swift:1655、SessionService.swift:147-157 |
| 单连接 / 递归锁 / 无读池 | DB.swift:208/215/220/250；Database.swift:27-29/101 |
| 启动即 foreign_key_check | Database.swift:566 |
| Schema 常量与指纹 | SchemaV1.swift:46-58/80；重置 Database.swift:583-640 |
| 交付状态机 | DeliveryState.swift:36-96；写入点 DeliveryRepo.swift:348/472/625/704/1194 |
| DB 删除与 intent 收尾两事务 | DeliveryCoordinator.swift:1615（事务）→ :1712（finish，另开事务）；DeliveryIntentRepo.swift:281 |
| 3 个模块适配器 | DeliveryCoordinator.swift:1806-1960（25 个 public 方法中 15 个） |
| Host 直驱交付状态机 | LiveMetadataAPI.swift:54/362-395/373 |
| Protocol 信封残留 | Protocol/Core.swift:160/184/197/220/256/292 |
| 179 错误码 | Protocol/Core.swift:321-535；GatherError.swift:34-41 |
| 16 协议 / 110 方法 | API/*.swift；CullingAPI.swift:20-46 为 17 方法 |
