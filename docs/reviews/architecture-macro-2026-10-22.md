# Gather 宏观架构分析（2026-10-22，HEAD 30f51f0）

> 范围：两个 SwiftPM 包、7 个产品 target、核心四层与 app 三层；只读分析，不改代码。
> 方法：读两个 Package.swift、各层目录与关键实现；统计文件/行数/import/公开声明/直接 SQL；对照 docs/archive/cuts/module-split-map-v2.md 与 ADR 的既定意图。
> 分报告：[core 四层](architecture-macro-core.md) / [app 三层](architecture-macro-app.md)。

## 1. 结论先行

当前架构是**清晰的模块化单体（modular monolith）+ 端口/适配器**，适合单机 macOS 照片应用：

- 依赖方向严格单向，无 target 环；GatherUI 只依赖 GatherProtocol；Host 是唯一组合根。
- 契约层 16 协议 / 110 方法，命令面为 0；SchemaV1 单真相源；算法层单实现。
- 主要架构债务不在“拆得不够”，而在“拆完之后层内的**巨型应用服务**与 **Delivery 子系统**”：
  GatherDomain 28 文件 19,224 行，其中 CullingService 2,800、FaceKwService 2,544、DeliveryCoordinator 1,964、SimilarityService 1,511、WritebackService 1,292；Domain 内 125 处直接 prepare、40 处 transaction，22/28 文件 import Persistence。
- 第二层债务：导航/会话状态双真相源（RootNavigation 与 SessionStore）、SchemaV1 仅重置无迁移、测试支持跨包复制、构建 manifest 非 hermetic。
- 不建议现在把 core 拆成 Culling/Face/Similarity 等 feature target；那会制造跨 feature 依赖环与基础设施重复。建议保持分层，**层内按 feature 重组，并把 Delivery 提取为独立模块/子系统**。

## 2. 目标图与依赖

~~~text
GatherApp (1 file, 111 lines)
  ├─ GatherHost (43 files, 8,804)
  │    ├─ GatherUI (178 files, 28,726) ── GatherProtocol
  │    ├─ GatherDomain (28 files, 19,224)
  │    │    ├─ GatherPersistence (30 files, 10,865) ── GatherProtocol + CSQLite
  │    │    └─ GatherAnalysis (16 files, 5,078) ── GatherProtocol
  │    └─ GatherProtocol (68 files, 7,598)
  └─ GatherUI
GatherSchema ── GatherPersistence
Benchmarks ── GatherProtocol + GatherAnalysis
GatherTestSupport ── GatherProtocol + GatherPersistence
~~~

Import 实测（生产 Sources）：

| target | 依赖 import |
| --- | --- |
| GatherProtocol | 无 |
| GatherPersistence | GatherProtocol 16、CSQLite 2 |
| GatherAnalysis | GatherProtocol 4 |
| GatherDomain | GatherProtocol 22、GatherPersistence 22、GatherAnalysis 9 |
| GatherUI | GatherProtocol 144 |
| GatherHost | Protocol 34、Persistence 28、Analysis 29、Domain 31、UI 21 |
| GatherApp | Host 1、UI 1 |

判断：**依赖图干净**，严格 import 检查有意义；没有 UI→Persistence/Analysis/Domain 的越界。

## 3. 分层评价

### 3.1 做得好的部分

1. **契约层稳定**：Protocol 零依赖，承载 DTO/API/错误码；UI 与 Host 都面向协议，Live API 是适配器。符合端口/适配器。
2. **Persistence 收口**：唯一 CSQLite import；SchemaV1、Database 门面、Repository、Delivery 表集中；WAL/foreign_keys/busy_timeout/列形指纹在门面内强制。
3. **Analysis 独立**：只依赖 Protocol；Face/Similarity/Image 算法不反向依赖 UI 或 DB；ClusterGraph 单实现。
4. **组合根明确**：GatherHost 的 AppComposition/AppServices 是唯一装配点；App 可执行只剩 @main/Scene。
5. **数据完整性意识**：Delivery intent/CAS/revision/文件锁/XMPFileLock 的设计比一般桌面应用更严谨。

### 3.2 主要张力

#### 张力 1：GatherDomain 实际是 Application 层，不是 Domain 层

- 28 文件 19,224 行；22 文件 import Persistence；125 处 connection.prepare、40 处 connection.transaction。
- 典型：DuplicateService 25 处 prepare、IndexerService 22、CullingService 15；CullingService 2,800 行 77 个方法，FaceKwService 2,544 行 43 个方法，DeliveryCoordinator 1,964 行 55 个方法。
- 它是“用例服务 + 事务脚本 + SQL + 文件 I/O”的混合层；Protocol 里是 anemic DTO，没有真正的 domain model。
- 后果：服务难以纯单元测试（必须带 DB）；文件级修改牵动多个用例；命名让新成员误以为这里是 domain 规则。
- 建议：把 GatherDomain 明确重命名为 Application（或至少文档定义），将 SQL 继续下沉到 Repository/Query；按用例拆分 Culling/Face/Similarity 服务（query / command / writeback 三面），而不是保持 TS IPC 的 1:1 方法面。

#### 张力 2：Delivery 是“应用内平台”，体量与耦合最高

- DeliveryRepo 1,325 + DeliveryCoordinator 1,964 + WritebackService 1,292 + MetadataMutationService 270 + intent/file lock，跨 culling/face/similarity/metadata 四个模块。
- 它同时管理：状态机（7 态）、revision CAS、intent 前滚、文件备份/恢复、跨会话确认、模块级 cleanup、replay、XMP 文件锁。
- 优点是数据完整性；缺点是认知负担与变更风险最高，且 DeliveryCoordinator 一个文件包含 confirm/cleanup/finalize/replay/file phase/DB phase 多个生命周期。
- 建议：提取 GatherDelivery 子系统（独立 target 或至少独立目录 + 明确 port），把：
  - 状态迁移表/合法性；
  - intent 状态机；
  - 文件阶段（restore/remove/backup）；
  - DB 删除阶段；
  分成可独立测试的组件；feature 服务只依赖 DeliveryPort，不直接拼 cleanup/replay 细节。

#### 张力 3：横向分层导致 feature 变更放大

- 一次 Culling 改动仍可能触及：Protocol/CullingAPI + Domain/CullingService + Persistence/CullingRepo + UI/Culling + Host/LiveCullingAPI，5 个 target。
- 这是分层的正常代价；但对 8 个 feature 的应用，层内没有 feature 边界，Domain/Persistence 是扁平 Services/Repositories。
- 建议：**不要拆 feature target**（Culling 依赖 Face/Similarity 查询，容易成环）；在层内建立 feature 子目录与 ownership：
  - GatherDomain/Services/Culling/、Face/、Similarity/、Delivery/、Indexing/、Export/、Metadata/；
  - GatherPersistence/Repositories 保持按聚合，但将跨 feature 查询收进 Query 对象。
- 这是低风险、高可读性的结构改进。

#### 张力 4：导航/会话状态双真相源

- RootNavigation.destination 拥有页面；SessionStore.activeSessionId/lastSessionId 拥有工作区；RootShellWorkspace 通过 workspaceSessionId 派生并同步；sidebar 用 lastSessionId 回退。
- 三个标识（destination、activeSessionId、lastSessionId）需要手动保持一致；删除会话、页签切换、返回栈都可能产生漂移。
- 建议：引入 AppRouter/SessionSelection 单一选择源（destination + activeSessionId 派生），SessionStore 只做 workspace 缓存；或让 activeSessionId 成为 destination 的计算属性。当前测试覆盖了主要路径，但认知成本高。

#### 张力 5：契约面与公开面偏大

- Protocol 1,717 个 public 声明，Persistence 914，Domain 523，UI 775，Host 236；总计约 4,259。
- 112 个旧 Protocol DTO 生产零外部引用但仍被契约测试钉住；公开面包含历史 IPC/response 形状。
- 跨包必须 public，但可以：删除旧 DTO/契约测试；把仅 Host 使用的类型收进 Host；为 Protocol 增加 API 文档与弃用标记；避免把实现细节（如 Delivery 内部 payload）放公共层。

#### 张力 6：单连接 + 多锁的并发模型

- Database 单连接 + NSRecursiveLock + WAL；所有 SQL 串行；分析已移出锁，但写回/交付/索引仍可能争用。
- 新增 XMPFileLock 与 DB 锁形成两个锁域；当前代码大多 XMP→DB，但没有正式锁顺序文档/断言；未来容易死锁。
- 建议：明确 lock ordering（例如禁止在 DB transaction 内取 XMPFileLock），增加压力测试；如 profiling 显示读争用，再考虑只读连接池，而不是现在改 actor。

#### 张力 7：Schema 只有重置，没有迁移

- Database.open 对 user_version/列形不符直接移走旧库（保留 .incompatible-*），重建 SchemaV1。
- 开发期合理且有安全网；但发布后无法保留用户数据。架构上必须在 1.0 前决定：版本化 migration，或显式导出/导入 + 首次启动提示。
- 这是产品级架构决策，不是 bug。

#### 张力 8：构建/测试基础设施的架构债

- app 的 Package.swift 在 manifest 求值期执行 /usr/bin/xcrun 获取 SDK 版本，并用 unsafeFlags 注入 platform_version；CLT 搜索路径带环境判断。构建可复现性依赖机器。
- GatherTestSupport 是 core 的 target 但不是 product；app 测试无法复用，复制了 TestDatabase/AsyncGate/LockedBox。测试基础设施没有跨包契约。
- 建议：SDK/工具链探测移到 build.sh/CI 环境变量；把 GatherTestSupport 暴露为 library product（或独立测试支持包），app 测试依赖它；CI 增加 schema verify 与 bundle 内容 smoke。

#### 张力 9：UI 状态与全局单例

- 28,726 行 UI、178 文件；SessionWorkspace 每会话构造 7 个 VM，capacity 6；Gallery 已懒加载，其他 VM 仍 eager 构造。
- GatherEventCenter、GatherLocalization 是进程级单例；页面/VM 通过通知和全局语言耦合，测试需要 AppLanguageLock/序列化。
- 这是单窗口桌面应用的务实选择；但若未来多窗口/多用户，需要把事件与语言放入 environment/actor。当前不必大改，记录边界即可。

#### 张力 10：可观测性

- 有 Logger、GatherEventCenter、CommandError，但缺少 job/delivery 的 correlation id、阶段耗时、失败原因聚合；长任务（索引/人脸/交付）排障依赖日志与 DB 状态。
- 建议：为 JobHandle/DeliveryIntent 引入 trace id，在阶段边界记录结构化事件；不是架构重构，是运行期可维护性。

## 3.3 独立评审补充（同日，core/app 分报告）

两份独立评审进一步量化了层内问题，结论与上文一致但更具体：

### Core
- **没有应用层**：Database 门面的 read/write/async 在**生产代码 0 调用**；16/28 个 Domain 文件直接持有裸 DBConnection；Domain 内 40 处 connection.transaction、58 条内联 SQL，跨约 28 张表。Host/APIs 还持有 8 个 Repo、19 处直调。
- **Protocol 历史沉积**：347 个类型 / 1,752 个公开声明；89 个类型完全无引用（约 942 行），6 个 Router 信封（Core.swift 约 270 行）仍保留。
- **交付聚合 5 个 owner / 35 处状态写入**：Writeback 18、Coordinator 9、LiveMetadataAPI 7、Mutation 1；DB 删除（Coordinator:1615）与 intent.finish（:1712）仍是两个事务；3 个模块适配器占 Coordinator 25 个 public 方法中的 15 个。
- **测试耦合**：26/30 个 Domain 测试必须使用真库；Persistence 没有 Repo 协议，锁粒度由业务代码决定。
- 建议顺序：R1 协议瘦身（约 2 人日）→ R2 交付切片（6–8 人日）→ R3 用例上收（5–8 人日）→ R4 读模型/DB 边界 ratchet（约 5 人日）→ R5 Culling/FaceKw 拆角色（10–15 人日，最后）。

### App
- **语义归属错位**：Host 仍含 882 行纯 SwiftUI 外壳（RootView/RootShell*），与 D-017“Host 只留装配与 Bridge”不一致；GatherUI 内藏着 3 个生产 Live provider（Dashboard/Gallery/Library）。
- **双 API 面**：27 个 Live 同步核 + 18 个 UI 同步端口方法 + SyncAPIPortBridge；同一能力有 async/sync/provider 三入口。
- **状态生命周期**：7 个 VM 的 setVisible/shutdown 语义不统一（Control 默认 false、Culling 用 isActive、其余默认 true）；全局单例迫使 app 测试串行。
- **组合根/发布**：AppComposition 390 行、269 行 make、33 个局部构造；Package.swift manifest 执行 xcrun；release 无 universal/notarization/版本注入。
- 建议：R1 完成 D-017（RootView/RootShell 迁 UI，优先）→ R2 provider 全面 async、删同步双面 → R3 组合根拆 private factory → R4 统一生命周期/LoadPhase → R5 固定 SDK + release job。

## 4. 架构选项与取舍

### 选项 A（推荐）：保持分层，层内按 feature 重组 + 提取 Delivery

- 保留 7 target 依赖图；不新增 feature target。
- GatherDomain/Services 按 feature 分目录；Culling/Face/Similarity 大服务拆 query/command/writeback。
- 提取 GatherDelivery（Coordinator/Writeback/Intent/FileLock）为独立 target 或至少独立目录，feature 服务只依赖 DeliveryPort。
- 收益：低风险、可增量、直接降低最大文件与认知负担；不改变公开 API 形状。
- 成本：中等（文件移动 + access 调整 + 测试迁移）；Delivery 提取需要 XMP/DB 端口。

### 选项 B（不推荐现在做）：feature vertical targets

- 按 Culling/Face/Similarity/Indexing/Export 拆 target。
- 问题：Culling 查询依赖 Face/Similarity/Photo 数据；feature 间会产生环或共享 kernel；SQLite/事务/交付基础设施重复；SwiftPM target 数量与编译时间上升。
- 适合团队规模更大、发布节奏独立时；当前单人/小团队不划算。

### 选项 C（中期）：CQRS/read model

- Culling/Gallery 的富查询与写回分离；读模型（SQL view/query object）与命令服务分离。
- 收益：读路径可独立优化；减少 CullingService 的 77 方法混合。
- 成本：高；需要 query contract/缓存一致性设计；当前 2k/10k 规模未必需要。

### 选项 D（发布前必须）：Schema 迁移策略

- 版本化 migration 或 export/import；移除“重置即完成”的发布假设。
- 成本：中高；但这是 1.0 的硬前提。

## 5. 评分（主观，供讨论）

| 维度 | 分数 | 理由 |
| --- | ---: | --- |
| 依赖/边界 | 9/10 | 7 target 单向、UI 隔离、strict import |
| 内聚 | 6/10 | Domain god services；Delivery 跨 feature |
| 耦合 | 7/10 | Protocol 共享内核合理；SQL 泄漏到 Domain |
| 可测试性 | 7/10 | 集成测试强；纯单元测试受 DB 依赖限制；测试支持未共享 |
| 可演进性 | 6/10 | Schema 无迁移；Delivery 复杂；导航双源 |
| 构建/发布 | 7/10 | 构建干净；manifest 非 hermetic；bundle 验证在 CI |
| 总体 | **7/10** | 方向正确，主要债务在层内与交付子系统 |

## 6. 建议的下一步（按收益/成本排序）

1. **Delivery 提取/分阶段拆分**（最高收益）：先拆文件为 Confirm/Cleanup/Finalize/Replay/FilePhase，再评估独立 target；补状态迁移表与锁顺序测试。
2. **Domain 按 feature 重组 + 大服务拆分**：先目录/文件级，后用例级；Culling/Face/Similarity 的 query/command/writeback 分开；把直接 SQL 收进 Query/Repository。
3. **导航/会话单源**：AppRouter 统一 destination + activeSessionId；SessionStore 只缓存 workspace。
4. **Schema 迁移策略**：发布前必须；先设计版本表/迁移器，保留 reset 作为开发分支。
5. **测试支持 product 化**：GatherTestSupport 作为 library product 供 app 测试使用；消除 TestDatabase 复制。
6. **构建 hermetic 化**：SDK 探测移到 build.sh/CI；固定 toolchain；bundle smoke。
7. **契约面清理**：删除 112 个旧 DTO/对应契约测试，减少 public 面。
8. **可观测性**：Job/Delivery trace id + 阶段耗时。

## 7. 一句话总结

这是一套**边界清晰、工程纪律强的模块化单体**；它已经解决了“单体里没有模块”的旧问题，现在的主要矛盾是“模块内部的应用服务与交付子系统过大”，而不是 target 数量不够。下一轮架构工作应做**层内模块化 + Delivery 提取 + 状态单源 + Schema 迁移**，而不是继续拆 target。
