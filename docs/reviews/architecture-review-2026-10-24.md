# Gather 总体架构评审（2026-10-24）

> 性质：**只读静态评审**。未执行编译、测试、门禁、benchmark 与 GUI 验收；
> 结论来自代码阅读 + grep/wc 统计，行号为当前工作区（HEAD ffd70276 + 49 项未提交改动）实测值。
> 引用前请重新 grep——工作区正在并行演进。

## 0. 规模口径（整改前快照，2026-10-24）

| 层 | 文件 | 行数 | 允许依赖（实测） |
| --- | ---: | ---: | --- |
| GatherProtocol | 71 | 6,535 | 无 |
| GatherPersistence | 106 | 16,877 | Protocol、CSQLite |
| GatherDelivery | 22 | 6,151 | Protocol、Persistence |
| GatherAnalysis | 19 | 4,993 | Protocol |
| GatherApplication | 44 | 14,135 | Protocol、Persistence、Delivery、Analysis |
| GatherUI | 214 | 31,332 | Protocol（仅） |
| GatherHost | 43 | 7,702 | 上述全部 + UI |
| GatherApp | 2 | 269 | Host、UI |

生产 524 文件 / 89,215 行（含 schema 工具与两个 benchmark target），测试 188 文件 / 61,841 行（约 0.69:1）。

> 整改后（R1–R9）：GatherProtocol 69 文件 / 6,395 行、GatherPersistence 107 / 17,131、GatherApplication 42 / 13,840、GatherUI 214 / 31,364；变更明细见 remediation 文档。
Import 矩阵与 `check-layering.sh` 的 6 条禁止边**全部成立**：UI 不碰持久化/应用层，Host 不回指 GatherApp，
Analysis 不碰 Persistence，Application 不碰 SwiftUI。

## 1. 一句话结论

分层、端口化、组合根、生命周期与门禁已经达到“可交付基础设施”的水平，**没有发现 P0**；
剩下的问题集中在三处：**数据面只有一条串行通道**、**错误契约仍以字符串为码**、
**UI 层吸收了本应下沉的规则与基础设施**。这三条都不是“写错了”，而是上一轮重构留下的
边界没有继续推完。

## 2. P1（影响正确性/可扩展性，建议下一轮处理）

### P1-1 单连接串行是整个应用的数据面硬上限

- **证据**：`Database.swift:31-34` 自述 `read` 与 `write` **共用同一个连接**，
  “长 read 会阻塞写”、“write 事务内的 read 不是快照隔离，调用方不得把 read 当作隔离边界”；
  `DB.swift` 是「单连接 + 递归锁」；全部 Live API 最终同步落到 Repo（`LiveAssetAPI.swift:38-42` 为范本）。
- **影响**：① 导出/写回/索引等长事务期间，UI 的所有读在同一条锁上排队；`await` 只让出线程，
  不绕过锁，表现为“页面在转圈但没有进展”。② 图库/工作台这类高频读没有只读通道可扩。
  ③ 一旦有人在 `write` 作用域里 `read`，拿到的是**未提交快照**——这是文档警告，不是编译期约束。
- **修复**：WAL 下引入只读连接池（`query_only=1`）+ `Database.read` 路由到池；长任务按批提交
  （每批不超过 N 行、独立事务）；在 `read` 上加“事务内只读断言”的调试检查。
- **状态**：已确认（代码与文档一致）；性能退化幅度未实测。

### P1-2 跨层错误契约仍是字符串码，类型安全只在 Host 侧“补救”

- **证据**：`DBError` 只有一个 `.message(String)`（`DB.swift:36-38`）；Persistence 有 **13 处**
  把错误码直接当字符串抛（如 `AssetRepo+Relink.swift:28` 的 `ASSET_RELINK_SAME_ROOT`），
  其余 44 处 `DBError.message` 承载 SQL/类型错误；Host 侧 8 处用 `GatherErrorCode(rawValue:)` 反解
  （`AppServices.swift:132/137/153/159`、`LiveCullingAPI.swift:220/236`、
  `LiveExportAPI.swift:182`、`LiveSimilarityAPI.swift:270`）。
- **影响**：错误码是否正确取决于抛错处字符串**逐字**等于枚举 rawValue；拼错、带参数前缀、
  大小写变化都会静默降级为 D-030 的通用文案，用户看到“操作失败”而失去可重试语义。
  `GatherErrorCode` 已 179 个码（`Core.swift:162`），但编译器对“谁抛了什么码”零校验。
- **修复**：Persistence 改抛 `PersistenceError(code: GatherErrorCode, underlying: String)`，
  `DBError` 只留给 SQL 层；`LiveAPIErrorMapping` 删除 rawValue 反解，改为直接透传；
  门禁加“禁止在 Persistence 抛裸字符串码”的 ratchet。
- **状态**：已确认。

## 3. P2（结构债/治理债，按收益排序）

### P2-1 跨页一致性是“通知 + 轮询”双轨，事件无序号、无重放

- **证据**：`GatherEventCenter.swift:80-84` 4 条 `Notification.Name`，`postDomainChange`（:128）无 seq/revision；
  5+ 处 VM 自建 `while !Task.isCancelled` 轮询（`SessionControlViewModel.swift:104`、
  `DashboardViewModel+Polling.swift:14`、`SettingsView.swift:152`）。
- **影响**：订阅建立晚于变更发布时只能等下一轮轮询或重新可见；多页同时可见时同一状态被重复查询，
  直接放大 P1-1；没有“我是否落后”的判据。
- **修复**：事件携带单调 revision（每域 `updated_at` 最大值或 DB change counter），VM 记 `lastSeen`，
  可见时对比补齐；轮询降级为长间隔兜底。
- **状态**：机制已确认；一致性缺口未复现。

### P2-2 UI 层职责外溢，成为“第二个应用层”

- **证据**：GatherUI 31,332 行（占 8 个功能 target 的 35.6%），其中 Support+DesignSystem+Preview 8,063 行；
  `Support/` 内含 `SessionStore`（LRU）、`ThumbnailDiskCache`、`PhotoDecodeGate`（:491，actor，limit 4）、
  `ImportPathRules`（:14）、`CaptureOneSyncStateRules`（:26）、782 行的 `PhotoThumbnailView`。
  前两者是**领域规则**，不是视图关注点。
- **影响**：规则只能 `@MainActor` 测试；Host 与未来 CLI 无法复用；“UI 只依赖 Protocol”靠端口适配维持，
  规则每多一条，适配样板就多一份。
- **修复**：把 `ImportPathRules`/`CaptureOneSyncStateRules` 这类纯规则上移到 Protocol 或 Application；
  缩略图缓存/解码闸若需跨层复用，再抽独立的 `GatherUISupport` target。
- **状态**：结构已确认；是否值得改属产品取舍。

### P2-3 依赖倒置在 Delivery 层只做了一半

- **证据**：`Ports/DeliveryWriting.swift:1-4` 注释称“具体 DeliveryRepo 只在组合根出现”，
  但 `DeliveryCoordinator.swift:214/239/281`、`WritebackService.swift:55-60/80-83` 仍直接持有并构造
  `DeliveryRepo`/`PhotoRepo`/`MetadataCacheRepo`。Application 层则已全面 `any XxxRepository`。
- **影响**：Persistence 的 Repo 签名变化直接穿透 Delivery；同一仓库两套依赖风格，
  评审时要分别记规则；Delivery 的单测难以用轻替身。
- **修复**：Delivery 内部定义所需最小协议（可复用 `DeliveryWriting`），组合根注入；
  或在 ADR 明确记录“Delivery 与 Persistence 同属基础设施，允许具体类型”，把例外变成决定。
- **状态**：已确认。

### P2-4 进程级单例决定了测试只能串行

- **证据**：Sources 9 处 `static let shared`（`GatherEventCenter.swift:78`、`XMPFileLock.swift:36`、
  `PhotoThumbnailView.swift:491` 等）；`ci.yml` 注释自述 app 用例共享 MainActor 状态层与进程级语言/通知槽，
  必须 `--no-parallel`；`cleanup-backlog.md` §11 记 `WorkspaceVisibilityTests` 依赖进程级
  `NSApplication`（疑似并行争用）。
- **影响**：反馈时间随用例线性增长；flake 面带“重跑才知道”的不确定性。
- **修复**：把 `shared` 收敛为组合根注入（`XMPFileLock` 已示范同一实例传递）；
  测试用 `@Suite(.serialized)` 精确标注而非全局串行。
- **状态**：机制已确认；并行 flake 概率未测。

### P2-5 文档治理滞后于代码演进

- **证据**：`docs/` 下 markdown 合计 2.7 MB（`reviews/` 单目录 1.2 MB / 39 篇正文，多为一次性审计）；
  `refactor-decisions.md` 单篇 133 KB；
  `check-docs.sh` 只校验 ADR 路径、md 链接与 schema 数字，**不校验 backlog 状态**；
  `cleanup-backlog.md` 的 CL-07/CL-08/CL-10 仍写 `pending, Cut 4`，而 Cut 4 已收口
  （现 VM 错误已是 `CommandError`，见 `SettingsViewModel.swift:36`）。
- **影响**：评审者无法从文档判断“当前真相”，只能读代码；每轮都要人工对账，正是本次评审的成本来源。
- **修复**：backlog 的每个 `pending` 必须带“未完成证据”（失败测试名/门禁规则），由脚本校验；
  或在 `docs/README` 建唯一“当前基线”数字源，其余文档只链接不复制。
- **状态**：状态漂移已确认。

### P2-6 预留但零消费的 API 面

- **证据**：`TemplateAPI`（`TemplateAPI.swift:13`，6 方法）+ `LiveTemplateAPI`（159 行）+
  `TemplateService`（247 行）；GatherUI **0 调用**（`CullingWorkbenchViewer.swift:409` 的 `.template`
  只是元数据域文案）。ADR-028 已裁决“未接线资产删除”，Template 走 D-008“保留”。
- **影响**：16 个 API 域里唯一无消费者，却要在每轮 API/测试/文档中维护。
- **修复**：按 ADR-028 同口径删除；或在 ROADMAP 给出明确排期，避免下一轮评审重复提问。
- **状态**：已确认（依赖 D-008 的产品结论）。

## 4. 已经做得好的（不计入问题，供后续维持）

1. **依赖方向是编译期硬约束**：`--explicit-target-dependency-import-check error` + `check-layering.sh` 双保险，
   6 条禁止边 0 命中。
2. **组合根收敛**：`Composition/Core.swift` 是唯一服务图构造点（单 DB、单 JobService、单 DeliveryCoordinator、
   单 XMPFileLock），没有第二套运行时。
3. **UI 生命周期两级可见性**：`SessionWorkspace` 的会话级/页面级分离 + LRU 淘汰 close + 终态保护，
   避免了“未见页面后台空转”。
4. **危险模式极少**：Sources 中 `try!` 2、`as!` 1（`fatalError` 仅出现在注释里），
   无 `Task.detached`、无裸 SQL 在 Application 层。
5. **可观测性**：job/delivery trace 带 `duration_ms`，错误展示有唯一漏斗。

## 5. 未执行 / 限制

- 未编译、未跑 core/app 测试、未跑其余 8 道门禁、未跑 benchmark、无 GUI 验收；
  仅执行 `check-layering.sh`（19 项检查 0 违规，exit 0）与 `check-docs.sh --strict`
  （ADR 路径 20 / md 链接 226 均 0 缺失，exit 0），用于校验依赖边与本文链接。
  全部结论仍是静态推断，**不构成发布验收**。
- 单连接的实际延迟、事件丢失概率、并行 flake 概率均未测量。
- 行数/文件数含工作区未提交改动；半成品文件的最终形态可能变化。
- 功能缺口（人脸质量筛选、隐藏状态、增量人脸聚类、模型版本迁移）见
  `docs/reviews/face-clustering-benchmark.md`，属产品排期，不在本次架构结论内。

## 6. 建议顺序

1. P1-2（错误契约）——改动面可控、收益确定，先把码变成类型。
2. P1-1（读连接池）——收益最大但风险最高，先做只读池 + 长任务分批，保留单写连接。
3. P2-4 → P2-1（测试隔离 → 事件 revision），两者都降低后续每轮的验证成本。
4. P2-2/P2-3/P2-6 按产品排期决定；P2-5 随每次收尾顺手修。

---

## 整改状态（2026-10-24 执行，详见 [architecture-remediation-2026-10-24.md](architecture-remediation-2026-10-24.md)）

| 编号 | 状态 | 落点 |
| --- | --- | --- |
| P1-1 单连接串行 | **部分完成** | R6：慢事务埋点 + 线程局部事务深度 + 只读池（无事务 SELECT 路由）；分块提交因无实测长事务清单而 defer |
| P1-2 字符串错误码 | **已修复** | R1：`CodedError` + `PersistenceError`，13 代码点迁移；Host 反解 8→3（均标注例外）；新门禁 |
| P2-1 事件/轮询双轨 | **已修复** | R4：事件 `revision` + `DomainChangeGate` 去重；50ms 合并因已有 500ms debounce 不做 |
| P2-2 UI 职责外溢 | **已修复** | R7：C1 同步状态 + 导入路径规则均下沉 Protocol（删 4 个端口/适配器文件），UI 直调无 registry |
| P2-3 Delivery 倒置 | **已裁决** | R8：窄端口（读一条/投影/三列）+ ADR-032；整体 Store 化会成 god protocol，明确不采纳 |
| P2-4 进程级单例 | **部分完成** | R5：删 `XMPFileLock.shared`；并行测试实测 signal 11，保持 `--no-parallel` |
| P2-5 文档治理 | **已修复** | R2：CL-07/08/09/10 状态与证据；`check-backlog-evidence.sh` 入 CI |
| P2-6 预留 API | **已删除** | R3：Template 域 8 源文件 + 3 测试删除；ADR-031；15 域/104 方法 |

*本报告只读产出；整改由 remediation 文档逐刀记录，源码改动未在本报告内展开。*
