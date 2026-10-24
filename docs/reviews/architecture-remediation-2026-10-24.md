# 架构整改方案（2026-10-24）

> 对应评审：[architecture-review-2026-10-24.md](architecture-review-2026-10-24.md)。
> 本文件是**执行方案**，不是任务书；每刀（R*）落地时再按仓内格式拆成带白名单的任务书。
> 原则：一刀一合并、每刀可回滚、每刀带测试与门禁、**不改 canonical DDL**、不新增 target（R7 除外且需先报批）。

## 0. 总策略

1. **先契约、后并发**：错误码类型化（R1）是一切后续改造的地基——它会顺带暴露哪些调用点依赖字符串。
2. **先测量、后优化**：R6 的读池不是第一步；先用 3 个真实场景拿到“锁等待/事务时长”分布，再决定池大小与分块粒度。
3. **优先删面**：R3（Template）与 R2（backlog）是“负成本”改动——删掉的面不需要再维护。
4. **测试并行是收益放大器**：R5 完成后，R1/R4/R6 的每刀验证时间下降，后续迭代才可持续。

## 1. 波次与依赖

| 波次 | 刀 | 目标 | 依赖 | 估时 |
| --- | --- | --- | --- | ---: |
| W0 | R1 错误契约 | P1-2 | 无 | 2d |
| W0 | R2 backlog 治理 | P2-5 | 无 | 0.5d |
| W0 | R3 Template 裁决 | P2-6 | 产品结论 | 1d |
| W1 | R4 事件 revision | P2-1 | R1（错误类型） | 1.5d |
| W1 | R5 单例与测试并行 | P2-4 | 无 | 2d |
| W2 | R6 数据面：量化→分块→只读池 | P1-1 | R5（并行跑测） | 5d |
| W3 | R7 UI 规则下沉 | P2-2 | R3（同改 AppServices） | 1.5d |
| W3 | R8 Delivery 端口 | P2-3 | 无 | 1.5d |
| W4 | R9 收口复测 | 全部 | R1–R8 | 1d |

**并行纪律**：R1 与 R3 都改 `AppServices`，串行；R6 与 R7/R8 文件不重叠，可并行；
`swift build/test` 永远串行（同一 `.build/scratch`）。

## 2. R1 错误契约类型化（P1-2）

**目标**：跨层错误“码即类型”，删除 Host 侧字符串反解；不改任何用户可见文案。

**设计**
- Protocol 新增：`public protocol CodedError: Error { var code: GatherErrorCode { get } }`；
  `GatherError` 直接 conform；`SessionServiceError` 已有的 `gatherCode` 改为 `code`（保留一版 forwarding 减少改动）。
- Persistence 新增：`public struct PersistenceError: Error, Equatable, Sendable { public let code: GatherErrorCode; public let detail: String? }`。
  `DatabaseError` 保持不动（open/closed/sql 三类语义）。
- Host：`LiveAPIErrorMapping` 增加 `catch let coded as CodedError` 分支，优先级最高；
  删除 8 处 `GatherErrorCode(rawValue:)` 反解；`DBError` 分支保留一版过渡并标 `TODO(R1-4)`。

**步骤**
1. R1-1 Protocol + `GatherError` + `SessionServiceError` 改造（纯编译期，无行为变化）。
2. R1-2 Persistence 13 个代码点改为 `PersistenceError`（共 14 个码值）：
   `AssetRepo+Relink` 8、`CullingHistoryRepo` 3（含 1 处三元 `CULLING_UNDO_NOT_LATEST`/`CULLING_REDO_OUT_OF_ORDER`）、
   `DeliveryRepo+Relocation` 2；`AnalysisJobRepo:150` 是对 DBError 的透传，保持原样。
3. R1-3 Host 漏斗改造；`CullingServiceError` 增加 `CodedError` conformance
   （其 `description` 字符串保留给日志，不再作为码的来源）。
4. R1-4 删除过渡分支 + 新增门禁。

**测试**
- 新增 `Tests/GatherCoreTests/Database/PersistenceErrorTests.swift`：每个 Repo 触发一次域错误，断言 `code`（真实 SQLite，不用 fake）。
- 改 2 处现有断言：`CullingServiceTests.swift:978/984` 由 `DBError.message("CULLING_...")` 改为 `CullingServiceError`。
- 回归：`LiveAPI` 的码映射保持等价（现有 Host 测试应零改动通过）。

**门禁** `scripts/check-coded-errors.sh`（新）：
- Persistence 源码中 `DBError.message("[` + 大写码 的计数必须为 0；
- Host 源码中 `GatherErrorCode(rawValue:` 计数必须为 0（R1-4 后）。
CI `gates` job 增加一步。

**验收**：core/app 全绿；门禁 exit 0；`en` 本地化键数不变（错误码集合不变，只是携带方式变化）。

**风险**：`Equatable` 语义变化（`PersistenceError` 的 detail 参与相等）；错误日志文本变化。
回滚点：R1 每步独立可 revert，R1-2 之后 `DBError` 仍可兜底。

## 3. R2 backlog 治理（P2-5）

**步骤**
1. 修 `cleanup-backlog.md` 的 CL-07/CL-08/CL-10：Cut 4 已落地，改 `done` 并写证据
   （CL-08 证据：`SettingsViewModel.swift:36` 的 `CommandError`；CL-10 证据：`l(` / `.id(languageVersion)` 全仓 0 命中）。
2. 新增 `scripts/check-backlog-evidence.sh`：每个 `### CL-xx` 段若 `status: pending|deferred`，
   段内必须有 `证据:` 行；`done` 段必须有 `验收:` 或测试名。CI `gates` 接入。
3. `DEVELOPMENT.md` 增加“backlog 状态规则”三行；`docs/README.md` 基线数字标注采样日期与命令。

**验收**：脚本对当前树 exit 0；人工把一条 pending 的证据行删掉后 exit 1（自测一次）。

## 4. R3 Template 裁决（P2-6）

**决策点**：ADR-028 已裁决“未接线资产删除”。Template 的现状是 **16 个 API 域中唯一零 UI 消费者**。

- **A（建议）删除**，清单：
  `TemplateAPI.swift`、`API/Inputs/TemplateInputs.swift`、`API/Outputs/TemplateOutputs.swift`、
  `LiveTemplateAPI.swift`(159)、`TemplateService.swift`(247)、
  `AppServices.template` 字段/init 参数、`Composition/FeatureAPIs.makeTemplate`、`Composition/Root` 转发、
  `ServiceConstructionTestSupport` 2 处、`TemplateServiceTests.swift`(195)、
  `APIPersonTemplateTests.swift`(492，拆出 Person 部分保留)。
  同步：`docs/protocol-surface-baseline.json` 数字、ADR-030、`docs/README` 的“16 域 110 方法”。
  净删约 1,100 行 + 1 个 API 域。
- **B 保留**：ROADMAP 写明确日期；在 `TemplateAPI` 头注释写“零消费者 + 删除条件”；
  增加一条测试：`TemplateAPI` 的 6 个方法在 UI 侧引用数必须为 0（防误接）。

**建议 A**：理由是可维护面收益确定、删除路径清晰（构造点已集中在 composition 与 TestSupport）。
若产品 Q1 有“模板导出”计划则选 B，且必须在 ROADMAP 落日期。

## 5. R4 事件 revision 与去重（P2-1）

**设计**
- `GatherApplicationChange` 增加 `revision: UInt64`（默认 0，兼容现有构造点）。
- `GatherEventCenter` 增加静态 `ChangeSequencer`（`NSLock` + `[GatherChangeDomain: UInt64]`）：
  `postDomainChange` 递增并写入 payload，返回 revision（`@discardableResult`）；`currentRevision(_:)` 供 VM 查询。
- UI 增加 `DomainChangeGate`（约 20 行）：`shouldApply(_ change) -> Bool` —— 跳过 origin 自己、跳过
  `revision <= lastApplied`，更新 `lastApplied`。
- 分两步落地：
  1. **先去重**（低风险）：6 个 `refreshOnDomainEvents` 消费点接入 gate；
  2. **后合并**（可选）：同 `(domain, sessionId)` 在 50ms 窗口内合并，只发最后一次。
     合并会改变“即时刷新”体感，建议独立一刀并可单独回滚。

**测试**
- `GatherEventCenterTests`：跨域 revision 独立单调；同域严格递增；origin 自跳过；旧 revision 不触发。
- VM 测试：同一事件对象重复投递只应用一次；连发会产生新 revision（设计行为，不做合并）。

**风险**：revision 是进程内计数，重启归零——VM 的 `lastApplied` 同为进程内，语义一致；
跨进程（Capture One 插件写入）仍靠轮询兜底，不在本刀范围。

## 6. R5 单例与测试并行（P2-4）

**分类处置**

| 单例 | 性质 | 处置 |
| --- | --- | --- |
| `GatherEventCenter.shared` | 有状态（wired 身份） | 保留 static post；`wire` 已幂等；补 `resetForTesting` |
| `XMPFileLock.shared` | 有状态（按路径串行） | 组合根已注入同一实例 → 删 `shared`，只在组合根创建 |
| `C1StatusService.shared` | 有状态 | 已支持注入（默认参数）→ 生产改为组合根传 |
| `PhotoDecodeGate.shared` | 纯并发闸（limit 4 + region 2） | **保留**：无跨用例可变状态，测试已自建实例，不构成并行阻塞 |
| `DisplayDateFormatters.shared` | 纯缓存 | 保留 |
| `L10nStringCache.shared` | 纯缓存 | 保留（已支持注入） |
| `RepositoryDateFormatters.shared` | 纯缓存 | 保留 |
| `CaptureOneBridge.shared` | 宿主桥 | 检查后定；优先注入 |

**并行收口步骤**
0. 先确认真正的串行成因：`GatherEventCenter.shared`（wired 身份）+ 语言/通知槽 + AppKit 两个 suite，
   而不是全部 8 个单例——批量删单例不是目标。
1. 逐 suite 用 `swift test --parallel` 跑 3 次，产出 flake 名单。
2. 剩余 flake 用 `@Suite(.serialized)` 精确标注（已知 `WorkspaceVisibilityTests`、`ThemeContrastTests` 触 AppKit）。
3. CI `gather-app` job 改为“并行主 job + 串行 smoke job”；保留 `--no-parallel` 作为可选复现入口。
4. 验收：并行连跑 5 次全绿；串行仍绿。

## 7. R6 数据面（P1-1）——分三步，不要一次上池

**R6-a 量化（不改行为，1d）**
- `DBConnection.transaction` 记录时长（进入/退出 + depth），超过 `slowTransactionMs`（默认关闭，dev 100）写 `GatherLogger.warn`
  并把 `duration_ms` 挂到现有 trace。
- 采样 3 个场景：导入 2k、导出 1k、人脸分析 2k；记录事务时长分布与 UI 读等待（可用 `os_signpost`）。
- 产出：一张“长事务清单”（文件:方法:时长），作为 R6-b 的输入。

**R6-b 缩短持锁（2d）**
- 对清单中 >100ms 的事务做**分块提交**（每块 ≤500 行），不改 SQL、不改结果：
  候选点：`IndexerService+Scan`（扫描批次）、`DeliveryReplayFlow`（replay 分片）、`ExportService+Plan`（计划分页）、
  `CullingService+Commands`（批量决策）、`FaceKwService+Analyze`（观测写入）。
- 每块之间不持锁（事务已提交），并显式让出执行器（`await Task.yield()`）。
- 测试：断言块大小上界（现有测试用 spy 记录事务次数）。

**R6-c 只读池（2–2.5d）**
- `ReadConnectionPool`：N=2（可配），`SQLITE_OPEN_READONLY` + `PRAGMA query_only=1` + `busy_timeout=5000`。
- 路由点：`DBConnection.prepare` —— 仅当 `transactionDepth == 0`、SQL 前缀为 `SELECT`（trim + 大写）、
  开关开启时，从池借句柄；`DBStatement` 记录来源并在 `deinit` 归还。
- 不改：`exec`、`BEGIN/COMMIT`、`PRAGMA`、`WITH`（当前 0 处）、`RETURNING`（当前 0 处）、未在事务中的写语句。
- **已核实的先决条件**：0 张 TEMP 表（跨连接不可见问题不存在）；39 处 `prepare("SELECT` 之外无 RETURNING。
- 开关：`settings.db_read_pool`（默认 on），关闭即回到单连接旧行为（回滚点）。
- 生命周期：`Database.close()/DBConnection.close()` 同步关池；`reopen` 重建池。
- 测试：
  1. 无事务并发读：写线程持事务 500ms，读线程 P99 必须 < 50ms（旧实现约 500ms）；
  2. 写后读可见（autocommit 写 → 池读）；
  3. `write { read { } }` 仍读到未提交数据（语义不变）；
  4. 关闭后读抛 `.closed`，池句柄全部释放。

**R6-d 复测（0.5d）**：同 R6-a 场景复测，出前后对比表；benchmark 不回归（±10%）。

**不推荐**：一次性把 42 处 `Repo(connection:)` 改成 Provider——改动面大、收益与 R6-c 相同且更容易引入语义回归。
若 R6-c 无法做到“事务内读仍在写连接”，再退回 Provider 方案。

## 8. R7 UI 规则下沉（P2-2）

**迁移 1：路径规则**
- 把 `TSPath` 的三个纯函数（canonical / xmpSidecarPath / basename）与
  `normalizeImportFilepaths` / `commonParentDirectory` 移到 `GatherProtocol/Protocol/PhotoPathRules.swift`（Foundation only）；
  Persistence 侧保留 `typealias` 一版兼容调用点。
- 删除 `GatherUI/Support/ImportPathRules.swift` 的端口 + registry（约 50 行）与 Host 的 `ImportPathRulesAdapter`。

**迁移 2：C1 同步状态**
- 把 `CaptureOneSessionState` 与 `aggregateSessionState` 移到 `GatherProtocol/Protocol/C1SyncState.swift`；
  删除 `CaptureOneSyncStatePort.swift` 的重复枚举/端口/registry 与 Host 的 `CaptureOneSyncStateAdapter`。
- 注意：`GatherProtocol` 已是 UI 唯一依赖，移入后无需新增依赖边。

**验收**：GatherUI 行数下降 ≥150；layering 仍 0 违规；core 新增纯函数测试（从 app 测试迁 2 组）。

## 9. R8 Delivery 端口（P2-3）

- 新增 `GatherPersistence/Ports/DeliveryStore.swift`：`DeliveryWriting` 的读侧补全
  （`fetch`、`items`、`counts` 等 Coordinator/Writeback 实际用到的方法）；
  新增 `PhotoReadStore`、`MetadataCacheStore` 两个窄协议。
- `DeliveryRepo`/`PhotoRepo`/`MetadataCacheRepo` 增加 conformance（extension，不改类）。
- `DeliveryCoordinator.init(store: DeliveryStore, ...)`、`WritebackService.init(store: ...)`；
  保留 `init(connection:)` 便捷构造（内部建具体 Repo），现有测试零改动。
- 组合根改用 store 注入。
- 新增 1 个轻替身测试验证端口可替换（不替代现有真实 SQLite 测试）。
- ADR-031 记录“Delivery 与 Persistence 的依赖风格”：同层允许具体类型，跨层必须端口。

## 10. R9 收口

- 全量：core `swift test --no-parallel`、app 两种模式、`gather-schema verify`、10 道 strict 门禁。
- 更新两份评审文档的“状态”列（P1/P2 → done 或 新编号）。
- 出对比表：行数、测试数、事务时长 P50/P99、并行耗时。

## 11. 工时与关键取舍

- 合计约 **16 人日**（不含 review 与回归等待）；R6 占 5 天，是唯一需要“测量—改—复测”的闭环。
- 三个决策点需要你拍板：
  1. R3 Template：删（建议）还是排期；
  2. R6 只读池：先在 `prepare` 路由（建议）还是先改 Provider；
  3. R4 是否做“50ms 合并”（建议先只做去重）。

## 12. 不建议做的事

- 为并行测试一次性删除全部单例（收益低、回归面大）。
- 在 R6-a 没有数据前就调池大小/事务块大小。
- 给 GatherUI 新增 target（R7 用 Protocol 下沉即可，避免又一次依赖矩阵调整）。
- 删除 Template 前不做产品复核（ADR-028 是删除先例，不是强制）。

## 13. 执行进度（2026-10-24，随做随更）

| 刀 | 状态 | 证据 |
| --- | --- | --- |
| R1 错误契约 | **done** | `CodedError` + `PersistenceError`（13 个代码点/14 个码）；Host 反解从 8 处降到 3 处 allowlist；新门禁 `check-coded-errors.sh` 绿 |
| R2 backlog | **done** | CL-07 保持 pending（实测 3 套 loader，证据已补）、CL-08/09/10 标 done 并补证据；`check-backlog-evidence.sh` 绿并接入 CI |
| R3 Template | **done** | 删除 8 个源文件 + 2 个测试；15 域 / 104 方法；ADR-031；protocol 面 255→245 类型、1340→1285 声明（含 R7 新增 C1SyncState 的 +1/+2） |
| R4 revision | **done（合并不做）** | 事件带 `revision`；`DomainChangeGate` 去重；3 个新测试；`refreshOnDomainEvents` 已有 500ms debounce，50ms 合并不再叠加 |
| R5 单例 | **部分 done** | 删除 `XMPFileLock.shared`（改为组合根唯一实例，4 个便利 init 不再有默认锁）；`@unchecked Sendable` 54→53（R6 新增 ReadConnectionPool 后回到 54，见偏差）；**并行测试实测 segfault（signal 11），保持 `--no-parallel`** |
| R6 数据面 | **done（batching defer）** | 事务时长埋点（阈值默认关）+ 事务深度改线程局部 + 只读池（仅无事务 SELECT 路由，默认 2 连接、`:memory:` 不建池、无空闲回退写连接）；新增 5 测试；core 1160/173、app 648/73 |
| R7 UI 规则 | **done** | C1 同步状态与导入路径规则全部下沉 Protocol（`CaptureOneSyncState`/`aggregateSessionState` + `TSPath`/`ScanPath`/`ImportPaths`）；删 UI 端口/registry/Host 适配器 4 个文件，Dashboard 直调 |
| R8 Delivery 端口 | **done** | `NarrowStores.swift`：`DeliveryReadStore`(1) / `PhotoReadStore`(1) / `MetadataCacheStore`(3)；镜像与写回改用端口；ADR-032 裁决"同层允许具体 Repo、禁止 god protocol" |
| R9 收口 | **done（门禁 12/12）** | protocol-surface 基线收紧到 245 类型 / 1285 声明；design-system 按方案 1 转绿（新组件 token 化 + WIP 指标接受）；core 1160/173、app 648/73、schema 43/373/69/62 |

### 偏差记录

- **R5 并行**：删单例后并行跑仍以 signal 11 崩溃（SwiftUI/AppKit 用例与 `NSApplication` 争用），不再尝试"为并行而并行"；CI 维持"串行主 job + 并行 smoke"现状，smoke 的 flake 风险记入残余。
- **R4 合并**：`refreshOnDomainEvents` 本身已 debounce 500ms，再加 50ms 合并只会增加延迟，故只做 revision 去重。
- **门禁修复**：`check-protocol-surface.sh` 的 warn 分支在 `set -u` 下解析 `$base（` 崩溃，已改 `${base}`（门禁自身 bug）。
- **设计系统门禁红**：`check-design-system.sh` 报 literalPadding +14 / literalSpacing +5，来自工作区未提交的外观改造（GatherTheme/ChromeMetrics 等），非本方案改动（已被 §14 取代）。
- **R6 分块提交 defer**：只加了事务时长埋点，没有实测到的长事务清单前不动事务边界；待真实库跑出 >100ms 的事务后再按清单分块（避免凭猜测改原子性）。
- **R6 读池边界**：只路由「无事务的 SELECT」；`WITH`/`RETURNING`/PRAGMA/写语句/事务内读全部保持原路径（事务线程用线程局部深度识别，读己写语义不变）。
- **R7 导入路径（批 2 已收口）**：`TSPath`/`ScanPath`/`ImportPaths` 迁入 Protocol，canonical 语义逐字保留（含 /private/var 折叠与 POSIX lstat）；UI 直调，registry 与 Host 适配器删除。
- **R8 范围裁决**：实测 Delivery 内用到 `DeliveryRepo` 约 30 个方法（读/写/事务/CAS 混合），整体端口化会得到 Repo 的影子接口；改为「按调用点收窄」——镜像只读一条、写回只读投影/回写三列，其余按 ADR-032 明确允许同层具体类型。
- **R5 解除条件**：并行 smoke 连续 5 次绿且已定位 NSApplication 争用（两个触 AppKit 的 suite 串行化后仍崩溃则关闭该路线）。
- **design-system 门禁**：原记录「仍红、未触碰基线」已被 §14 取代——按方案 1，新组件先 token 化，剩余外观 WIP 指标按脚本 --update 接受（当前 88/15/170/243）。

## 14. 阻塞解除（2026-10-24，按推荐方案 1）

用户确认按方案 1 执行，design-system ratchet 已转绿（12/12 门禁）：

1. **新组件字面量 token 化**（纯命名，值不变）：
   - `GatherMenuField` / `GatherSearchField` 的字段横向内边距 → `GatherChromeMetrics.fieldToolbarHorizontalPadding`(5) / `fieldHorizontalPadding`(9)；
   - 字段图标与文本间距 6 → `GatherMetrics.Space.controlGap`。
2. **剩余外观 WIP 指标按脚本接受**：`check-design-system.sh --update` 记录当前树
   （`font.callout` 88、`font.systemSize` 15、`literalPadding` 170、`literalSpacing` 243）。

**增量归属（实测 vs HEAD）**：`font.systemSize` +9、`literalPadding` +14、`literalSpacing` +5（238→243）全部来自工作区未提交的
外观文件（`GatherMenuField`/`GatherSearchField` 两个新组件 + `GalleryView+Content`、`GatherSessionPage`、
`GatherSessionToolbar`、`LibraryView+Filters`、`C1StatusCapsule` 五个改版视图）；本次整改没有新增这些字面量。
另有下降项 `font.callout` 92→88、`container.groupBox` 5→0（外观改版减少；脚本只对上升失败）。

**遗留提醒**：这三个指标记录的是外观 WIP 的当前状态；WIP 收尾后应把新组件/改版视图的字面量继续 token 化，
再运行 `--update` 收紧基线（ratchet 只增不减的例外仅此一次）。

## 15. 复审修复（2026-10-24，4 路子代理复核后）

已修（批 1 + 批 2）：

- **门禁**：`check-coded-errors.sh` 扫描范围扩到 core+app 全 Sources（跨行码匹配、注释豁免）；
  `check-backlog-evidence.sh` 支持大小写/全角冒号、空证据 FAIL、无 status 段 FAIL。
- **数据面**：事务深度键按连接实例；池读连接继承 `Database.Options` 的 busy/cache/temp_store；
  慢事务区分 queue/exec、带 file:line:function，支持设置项 `db_slow_transaction_ms` 与环境变量
  `GATHER_SLOW_TX_MS`；Database 头注释同步读池与锁序；`ReadConnectionPool.close` 只关空闲连接。
- **错误面**：JobService 优先 `CodedError.code`（兼容 `CODE: detail` 文本）；`APIErrorPresentation` 增加
  `CodedError` 分支（PersistenceError 不再落系统英文）；`CullingHistoryRepo.get` 带 detail；
  `CullingHistoryRepoTests` 断言收紧到 `.CULLING_UNDO_NOT_LATEST`。
- **R4/R8**：删除 `DomainChangeGate` 未用的 isBehind/markCaughtUp；测试套件加 `.serialized`；
  NarrowStores 与宽端口的取舍写入 ADR-032 与文件头。
- **R5**：XMPFileLock 注释改为真实风险；测试便利 init 支持注入同一把锁；AppCompositionTests 新增
  “coordinator/writeback/metadata API/composition 四处同一实例”契约测试。
- **R7 补完**：TSPath/ScanPath/ImportPaths 迁入 Protocol（canonical 语义逐字保留），删 UI 端口/registry/
  Host 适配器共 4 个文件；Dashboard 直调。
- **文档**：README 基线（1160/173、648/73、12 门禁）、R3/R9 数字（245/1285）、§13 标 superseded、
  §14 修正 +5 与下降项、CL-17/18 证据按符号与当前 ratchet、review §0 标“整改前快照”、
  AppComposition 15 域、R5 解除条件。

仍 defer（环境/数据依赖，非代码缺陷）：

- **R5 并行**：复审后再次实测无 `--no-parallel` 的 `swift test` 仍 signal 11；根因是 AppKit/SwiftUI
  用例与测试进程并发，需单独定位并设计执行策略（在“不新增 target”的约束下暂无安全解）。
  CI 维持串行主 job + 并行 smoke。
- **R6-b 分块**：需真实库跑出 >100ms 事务清单（用 `GATHER_SLOW_TX_MS=100` 采样）后再改事务边界。

