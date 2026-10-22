# 数据 / 并发最终验收（只读）

> **快照声明**：本报告是 df73880 的验收快照；P1-1 backup 大小写/NFD 与 replay claim 已在后续 commit 修复，最终状态见 [architecture-remediation-status.md](architecture-remediation-status.md)。

> **基线**：`df73880`（`docs: finalize WP0-WP7b architecture remediation status`）。验收期间我方未改任何源码；20:47 后其他并行任务开始改 30+ 文件的注释/文件头（见下条快照说明）。
> **范围**：Delivery 状态机/Intent、XMPFileLock、Schema V2、文件/路径/安全、trace 日志与 GatherLogger。
> **方法**：只读源码 + 既有测试断言 + 按仓库命令实跑 core 测试与 `gather-schema verify`；未改任何源码/测试/脚本/CI。
> **产物**：仅本文件 `docs/reviews/final-acceptance-data.md`。
> **口径**：`已确认` = 代码/测试可直接证明；`疑似` = 需要并发时序或运行期注入才能触发，静态无法 100% 排除。P0 = 可复现的数据损坏/丢数据；P1 = 明确的完整性/门禁缺口或可导致持久化损坏的窄窗口；P2 = 加固、文档、性能与残余风险。
> **快照说明**：源码行号与结论取自 20:35–20:46 的 HEAD 只读快照；20:47 起并行任务开始修改 30+ 个文件的注释/文件头（`git diff` 仅注释级），本报告未纳入这些未提交改动，行号可能随其漂移。

---

## 0. 结论（先行）

- **P0 = 0**。未发现「正常路径必现」的数据损坏：7 态迁移表与 `DeliveryStatus.canTransition` 逐边一致（含自迁移），DB 守卫与 intent 单事务提交有回滚/幂等测试钉死；Schema V2 对未知库默认 fail-closed；XMP 文件锁未发现反向锁序死锁。
- **P1 = 4**：
  1. **finalize 先删备份、后做 DB CAS**：DB 守卫拒绝/并发新输入时，交付行保留但 `backup_path` 指向已删除文件；后续 cleanup 反复 `backupMissing`、原 XMP 备份不可恢复（仅 culling 可再走 finalize 删行，P1-1）。
  2. **`markWritten` 不校验 lease owner**：租约过期被接管后，旧写者仍可提交 `written` 并覆盖新基线（P1-2；仓库自己的 `docs/final-report.md:25` 已列为残余）。
  3. **confirm 门禁读与事务非原子，且事务内 `confirmed_at` 不校验交付状态**；另有 `WritebackService.confirmSync` 公共旁路绕过 reload-ack/完整性门禁（P1-3）。
  4. **370 列 V1 库不可迁移到 V2**：`user_version=1` 但列形 370 的旧 V1 被判 `corrupt`，默认 fail-closed、显式 reset 才改名重建；V1→V2 迁移只对「已经是 373 列」的 V1 可达（P1-4）。
- **P2 = 15**：finalize 缺跨模块 item 门禁（当前不可达但无断言）、`isTerminal` 语义不一致、LiveMetadataAPI 锁未显式注入、replay 并发、XMP→DB 锁内 DB 写/锁序耦合、finalize 不做盘上指纹、入队读不在 XMP 锁内、trace 泄漏绝对路径、GatherLogger 全局锁、非 SQLite 文件靠字符串识别、reset 先移 WAL、备份路径未校验、symlink 文件导入边界、session 删除注释/孤儿残留、临时文件残留。
- **一句话**：核心状态机与「删除 + intent finish 单事务」是可信的；当前最需要修的是 **finalize 的文件/DB 顺序** 与 **370 列 V1 的升级路径**，其次是 **租约完成的 owner 校验** 与 **confirm 的事务内门禁**。

---

## 1. 交付状态机与迁移表

### 1.1 7 态迁移表 vs Persistence `canTransition`：一致（已确认，PASS）

- Delivery 侧显式表：`DeliveryStateMachine.Transition` 7 条（enqueue/claimWriting/writeSucceeded/confirm/failWriting/markConflict/cleanup），target→sources 派生为 `deliveryTable`（`Sources/GatherDelivery/Coordinator/DeliveryStateMachine.swift:26-90`）。
- Persistence 唯一真相源：`DeliveryStatus.canTransition` 的 `switch (self, next)`（`Sources/GatherPersistence/Database/DeliveryState.swift:47-74`）。
- 逐边核对（target ← sources）：
  | target | Persistence 允许来源 | DeliveryStateMachine.sources | 一致 |
  |---|---|---|---|
  | pending | pending/writing/written/synced/failed/conflict | 同左 | ✅ |
  | writing | pending/writing/failed/conflict | 同左 | ✅ |
  | written | writing/written | 同左 | ✅ |
  | synced | written/synced | 同左 | ✅ |
  | failed | pending/writing/failed | 同左 | ✅ |
  | conflict | pending/writing/written/synced/failed/conflict | 同左 | ✅ |
  | cleaned | synced/cleaned | 同左 | ✅ |
- 双向穷举测试：`Tests/GatherCoreTests/Delivery/DeliveryStateMachineTests.swift:13-51`（7×7 全组合断言 + item 4×4 + 命名迁移来源集合 + 自迁移必须存在）。
- SQL 的来源集合由枚举派生，不手写第二份：`DeliveryRepo.allowedFromSQL(for:)` / `allowedItemFromSQL(for:)`（`Sources/GatherPersistence/Database/Repositories/DeliveryRepo.swift:487-493, 719-725`），`casTransition` 与 `markItem` 都带 `status IN (...)` CAS（`DeliveryRepo.swift:457-485, 691-717`），与 `canTransition` 同源。
- 结论：所谓「两套状态机」在 `df73880` 已收敛为「Persistence 定义边、Delivery 派生表 + 测试双向锁死」。**未发现漏边/多边。**

### 1.2 终态语义的一处不一致（P2-1，已确认，当前无生产影响）

- `DeliveryStatus.isTerminal` 返回 `synced || cleaned`（`DeliveryState.swift:77`），但 `synced → pending/conflict/cleaned` 都是合法边（`DeliveryState.swift:60`），且 `mergeInput` 确实会把 synced 重新打开（`DeliveryRepo.swift:539-550`）。
- `isTerminal` 在生产代码零引用（仅声明），属「命名与语义打架」：任何未来用 `isTerminal` 做门禁的代码都会错误拒绝新输入。建议删除该属性，或改名为 `isSettledForDisplay` 并明确「可被新输入重开」。

### 1.3 item 状态机

- `DeliveryItemStatus.canTransition`（`DeliveryState.swift:91-107`）与 `ItemTransition.sources`（`DeliveryStateMachine.swift:94-125`）逐边一致（同上测试 `DeliveryStateMachineTests.swift:24-50`）。
- item 的 CAS **只带 status，不带 revision**（`DeliveryRepo.markItem` `DeliveryRepo.swift:692-717`）。这是设计选择：item 是「文件 × 模块」的最终事实，delivery 级 revision 门禁已经挡住旧写者的 `markWritten`。残余：Phase 2 的 item 收敛可能与新 revision 交错（旧 execute 仍可把 item 标 written/failed）；影响有限（下一次 writeback 的 `upsertItem(pending)→目标态` 会重排），但会让短暂的 summary/UI 与交付行不一致，建议未来给 item 加 `revision` 或把 item 收敛也纳入 delivery 的 revision CAS。

---

## 2. Intent（prepare → fileDone → applied）

### 2.1 相位状态机与幂等（PASS）

- 唯一转移表 `prepared → fileDone → applied`，无自迁移、无跳相位（`Sources/GatherPersistence/Database/Repositories/DeliveryIntentRepo.swift:43-50`）；`advance` 在事务内先读相位再 CAS（`DeliveryIntentRepo.swift:235-268`）。
- `finish(error: nil)` 删除 intent；`finish(error: non-empty)` 标 `applied` + error，留给 `replayAll` 清理（`DeliveryIntentRepo.swift:278-312`）；`finishIfPresent` 把「已不存在」视为闭环（`Sources/GatherDelivery/Coordinator/DeliveryIntentStore.swift:139-145`）。
- 回放按相位分派：`prepared` 重做文件+DB，`fileDone` 只补 DB，`applied` 启动时删除（`DeliveryReplayFlow.swift:53-217, 227-372`；文档见 `DeliveryIntentRepo.swift:30-39`）。
- 单条失败不拖垮整批、intent 保留待重试；`fileDone` 绝不重放文件（`DeliveryReplayFlow.swift:199-217`）。**与设计一致。**

### 2.2 “单事务 finish”与失败回滚（PASS，有测试）

- `DeliveryDBPhase.applyCleanup/applyFinalize` 只开一个 `connection.transaction`：item 门禁（仅 cleanup）→ 删 items/links/delivery → `intent.finishIfPresent`（`Sources/GatherDelivery/Coordinator/DeliveryDBPhase.swift:88-156, 181-215`）。
- 删除顺序显式 `delivery_items → delivery_sessions → deliveries`，并校验 `removed == 1`，失败抛错回滚（`DeliveryRepo.swift:1232-1247`）。
- 测试：finish 失败（SQLite trigger 注入）→ 交付与 intent 都回滚保留；去掉 trigger 后重试成功（`Tests/GatherCoreTests/Delivery/DeliveryDBPhaseTests.swift:64-101`）；重复调用幂等返回 `.alreadyGone`（同文件 103-121）；finalize 同一事务纪律（同文件 146-174）。
- **一处精度问题（P2-9 的一部分）**：`applyFinalize` 不跑 item 门禁（见 §3.4 / P2-2），且 `finish(error:)` 与文件阶段删除备份不具可逆性（P1-1）。

### 2.3 Intent 的并发重放（P2-4，疑似但静态可证）

- `replayAll()` 只读待办，没有「claim/租约」：两个并发 `replay()`（启动回放 + `flush()/retrySync()`）可以同时拿到同一条 prepared intent（`DeliveryIntentRepo.swift:337-343`；调用点 `CullingService+Delivery.swift:52-63`）。双方都在 `XMPFileLock` 内重做文件（restore 幂等）后依次 `advance`，后者会因相位已前进/已删除得到 `rowNotFound` 或 `writeNotPersisted`，计入 failed；用户可见一条虚假失败（不损坏数据，但会让 `flush` 报错）。
- 建议：`replayAll` 在事务内按 intent id 抢占（例如新增 phase=`replaying` 或带 owner 的 `claimed_at`），或对 `advance/finish` 的 `rowNotFound` 在 replay 路径按「已被他人闭环」处理。

---

## 3. confirm / cleanup / finalize / replay 的 revision、CAS 与门禁

### 3.1 总表

| 操作 | revision 守卫 | 状态守卫 | 跨会话守卫 | 跨模块守卫 | 单事务收尾 |
|---|---|---|---|---|---|
| `markWriting/claimWriting/markWritten/markFailed/markConflict` | ✅ `revision=?` | ✅ `canTransition` + SQL IN | — | — | 单条 UPDATE（整写） |
| `confirm` | ❌ 无 revision | 仅 delivery 翻转带 `status='written'`；**links 的 confirmed_at 无状态过滤** | ✅ `NOT EXISTS confirmed_at=''` | ⚠️ 按 module 收窄 scope，但 items 会跨模块翻 synced | ✅ 单事务（门禁读在事务外） |
| `cleanup` | ✅ payload.revision + id | ✅ `synced`（候选+DB 段+DELETE WHERE） | ✅ 所有 link 已确认 | ✅ `cleanupItemGate`（所有 item 必须 synced，foreign 则只清本模块） | ✅ 文件在锁内；DB+finish 单事务 |
| `finalize` | ✅ payload.revision + id | ✅ `synced` | ✅ 所有 link 已确认 | ❌ 无 item 门禁（P2-2） | ✅ DB+finish 单事务；**备份删除在事务外且在前**（P1-1） |
| `replay(prepared)` | ✅ verify 比对 payload 快照 | ✅ payload.status | ✅（delete helper 内） | ✅（cleanup DB 段） | ✅ DB+finish 单事务 |
| `replay(fileDone)` | ✅ DB 段 delete helper | ✅ | ✅ | ✅ | ✅ |

### 3.2 confirm（P1-3，已确认代码事实；端到端触发需窄并发窗口）

- 门禁顺序：`summary.isConfirmable` → `requireReloadAck` → `stateWriter.confirm`（`Sources/GatherDelivery/Coordinator/DeliveryCoordinator.swift:257-293`）。**门禁读与 confirm 事务之间没有锁、没有 revision/状态复核**。
- `DeliveryRepo.confirm` 是一个事务（`DeliveryRepo.swift:1308-1353`），但：
  - 第一步 `UPDATE delivery_sessions SET confirmed_at=?` 的 `targetSQL` **没有 `d.status='written'` 过滤**（`DeliveryRepo.swift:1309-1313`）；因此事务执行时即使交付已变回 `pending/writing/failed/conflict`，链接也会被写成已确认。
  - delivery 翻转才有 `status='written'` 且所有链接 `confirmed_at<>''`（`DeliveryRepo.swift:1315-1326`）；items 翻转只对 `d.status='synced'` 的交付（`DeliveryRepo.swift:1328-1335`）。
  - 后果（窄窗口）：`confirm` 读门禁后、事务前，另一写者 `mergeInput` 把交付 reopening 为 pending；confirm 仍写入 `confirmed_at`。随后 writeback 把新内容写成 `written`，此时「所有链接已确认」仍成立（因为刚才被写入），下一次 confirm 会直接翻 `synced`——用户从未确认过新内容。这与 `DeliveryCoordinator` 注释「先查完整性，再查 reload-ack，最后才写状态」的设计意图不符（`DeliveryCoordinator.swift:255-256`）。
- **公共旁路**：`WritebackService.confirmSync` 只统计 failed item，然后直接 `stateWriter.confirm(scope:.module)`（`Sources/GatherDelivery/Writeback/WritebackService.swift:1090-1106`）。它没有 reload-ack、没有 `summary.isConfirmable`（pending/writing/conflict 不拦）、没有跨会话阻断报告。当前生产调用点未找到（`confirmSync` 的域入口都改走 Coordinator），但它是 public API，且 `stateWriter.confirm` 在 GatherDelivery 内部也是可调用的。**门禁不是一个入口。**
- 修复建议：
  1. 把门禁读并入 confirm 事务（或在事务内重读 `summary`/状态）；`confirmed_at` 的 UPDATE 增加 `AND d.status='written'`（与 delivery 翻转同一条件）；
  2. 删除 `WritebackService.confirmSync` 或让它委托 `DeliveryCoordinator.confirm`（保留旧错误码映射）；
  3. 在 `DeliveryRepo.confirm` 内用 `canTransition` 或显式状态断言替代「尽量更新」，失败显式返回 `.stateChanged` 而不是写半套确认。

### 3.3 cleanup：门禁与 TOCTOU（基本 PASS）

- 候选只选 `synced` 且所有 link 已确认、本模块 item 全 synced（`DeliverySummaryQuery.syncedCandidates` `Sources/GatherPersistence/Database/Repositories/DeliverySummaryQuery.swift:132-182`）。
- `cleanupItemGate` 在文件阶段之前 + DB 事务内各查一次（`DeliveryCleanupFlow.swift:65-100`；`DeliveryDBPhase.swift:94-125`），foreign 模块只清本模块 item、保留交付且不碰文件（P1-8）。
- 外部修改：预检指纹（锁外）标 conflict；锁内 `verify` 再比对 revision/status/base_fingerprint + 盘上指纹；`restore/remove` 后再查一次行快照，发现新输入返回 `.invalidated` 并显式上报（`DeliveryFilePhase.swift:67-145, 164-173`；`DeliveryCleanupFlow.swift:178-292`）。
- 残余：锁外预检只是“早退优化”，真正安全边界在锁内 `verify`；这部分已确认。
- **但**：外部编辑器（Capture One）不参与进程内锁，`verify` 的指纹读与 `restore` 之间仍有外部写窗口（P2-6，理论不可消除，需在文档/验收中明示）。

### 3.4 finalize：两处缺口

**P1-1（已确认）：备份删除先于 DB CAS，失败/竞态会留下悬空 `backup_path`。**

> 定级说明：不升 P0 的理由是「当前 XMP 内容仍在」——丢失的是备份文件与 cleanup 的闭环能力，且触发需要并发/DB 失败窗口；但一旦触发，该交付的 cleanup 不可恢复，因此必须按 P1 在发布前修。

- 文件阶段先删备份：`performFinalize` 在 `XMPFileLock` 内 `guard fileExists(backupPath)` → `removeFile(backupPath)` → 才 `verifyAfterMutation`（`Sources/GatherDelivery/Coordinator/DeliveryFilePhase.swift:199-207`）。
- 随后 `DeliveryDBPhase.applyFinalize` 才做 `deleteSyncedDeliveryInTransaction` 的 id/revision/status/links CAS（`DeliveryDBPhase.swift:181-204`）；被拒时仅 `finish(intentId, error:)`，**不回补备份**（`DeliveryDBPhase.swift:197-202`）。
- `mergeInput` 不清理 `backup_path`（`DeliveryRepo.swift:539-550`）；WritebackService 对已有 `backup_path` 的行**不再取新备份**（`WritebackService.swift:919-922`；收敛时 `existingBackupByPath` 兜底 `WritebackService.swift:830-832`）。因此交付行会长期带着一个已删除的 `backup_path`。
- 触发路径（已确认的代码路径，不一定必现）：
  - 候选查询 → 文件阶段期间，另一会话对同一 `xmp_path` 执行 `linkSession`（会重置 `confirmed_at`）或 `mergeInput`（revision+1）→ DB 段返回 `.stateChanged/.revisionChanged`；此时备份已被删。
  - 或 DB 段本身 SQL/trigger 失败（异常路径）。
- 后果：该交付之后 `cleanup` 走 `performCleanup`，`backupPath` 非空但文件缺失 → `backupMissing` → `fileFailed` → intent 停在 prepared，replay 反复重试，cleanup 无法闭环；原始 XMP 备份不可恢复。唯一的兜底是等 delivery 再次进入 `synced` 后走 **finalize**（只删行、不读备份；但 finalize 只有 culling 暴露）。`LiveMetadataAPI.resolveOrphan` 的顺序反而正确：先删行、成功后再删备份（`gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:231-239`）。
- 修复建议（按可靠性排序）：
  1. finalize 改为「DB CAS 删行（intent 保留 fileDone 语义）→ 删备份」，把「删备份」做成可重试的尾段；或
  2. 文件阶段只做 `verify` + 把备份**改名到回收区**（同目录 `.garbage-`），DB 删行成功后再真删；DB 拒绝时改回原名；
  3. 至少在 DB 段拒绝时把 `deliveries.backup_path` 置空（明确“无备份可恢复”），并把 intent 的 error 作为显式冲突，而不是让后续 cleanup 永久 backupMissing；
  4. 增加「finalize 被 CAS 拒绝后交付行 backup_path 不存在」的回归测试。

**P2-2（已确认缺失，但当前不可达）：finalize 没有跨模块 item 门禁。**

- cleanup 有 `cleanupItemGate`（所有 item 必须 synced；foreign 模块只清本模块），finalize 直接走 `applyFinalize`，没有任何 item 检查（`grep cleanupItemGate` 只命中 cleanup：`DeliveryCleanupFlow.swift:67`、`DeliveryDBPhase.swift:96,165`）。
- 当前不可达的原因：任何新输入都会经 `openDeliveryForInput/mergeInput` 把 delivery 置回 `pending`（`DeliveryRepo.swift:871-900`；preview 也显式 reopen `WritebackService.swift:308-323, 614-627`），而 finalize 候选要求 delivery=`synced`；因此「delivery synced + 其它模块 pending/failed item」在现有 public 流程中没有构造点。
- 但它是**无断言的不变量**：一旦未来有「item 级入队不重开 delivery」或「finalize 暴露给更多模块」，finalize 会静默删掉其它模块未落盘的输入（cleanup 不会）。建议 finalize 复用 `cleanupItemGate`：非本模块非 synced item → skip/报 `XMP_FINALIZE_INCOMPLETE_ITEMS`；只清本模块 item 的 retainForeign 语义同样适用。

**P2-6（已确认）：finalize 完全不做盘上指纹校验。**
- `verify` 对 finalize 在 snapshot 一致后直接 `.proceed`，不读指纹（`DeliveryFilePhase.swift:125-126`）。外部改盘后 finalize 会删掉旧备份、保留外部内容并静默丢恢复点。若这是刻意的「结束会话保留 XMP」语义，应在报告/UI 明示；否则至少补「外部修改 → 不删备份、标 conflict」的一致行为。

### 3.5 replay（PASS + P2-4）

- `prepared` 的 `verify → 文件 → verifyAfter` 整体在锁内（`DeliveryReplayFlow.swift:69-96`），新输入推进 revision 时返回 `.changed` 并 `finish(error:)`，不碰文件（`DeliveryReplayFlow.swift:127-167`）。
- `fileDone` 只补 DB，绝不重放文件（`DeliveryReplayFlow.swift:199-217`）。
- 幂等：`alreadyGone` → 仍走 DB 段 → `.alreadyGone` → finish（`DeliveryReplayFlow.swift:168-176`；`DeliveryDBPhaseTests.swift:103-121`）。
- 并发重放问题见 P2-4。

### 3.6 跨会话 / 跨模块门禁小结

- **跨会话**：confirm 的 `NOT EXISTS unconfirmed`、cleanup/finalize 的候选与 `deleteSyncedDeliveryBody` 的 `unconfirmedLinks==0` 形成双层；`mergeInput` 与 `resetConfirmations` 在所有确认失效时清空全部 link（`DeliveryRepo.swift:565-568, 585-596`）。**一致。**
- **跨模块**：cleanup 有 item gate；confirm 有意让「一个侧车文件是一次原子写」把同交付的所有 written item 一起翻 synced（`DeliveryRepo.swift:1328-1335` 注释 1255-1261）；finalize 缺门禁（P2-2）；`resolveConflict` 的 `acceptExternalState` 只到 `written` 并清确认（`LiveMetadataAPI.swift:374-405`）。**唯一实质缺口是 finalize。**

---

## 4. XMPFileLock

### 4.1 设计核对（PASS）

- 进程内 actor，按 `TSPath.normalize` 的路径串行；FIFO 等待队列，release 时直接移交所有权；取消在取得所有权后 `Task.isCancelled` 检查并释放（`Sources/GatherDelivery/File/XMPFileLock.swift:34-104`）。
- 同一路径的 `./a.xmp` 与 `a.xmp` 视为同一把锁（`XMPFileLock.swift:54`），测试覆盖（`Tests/GatherCoreTests/Services/WritebackServiceTests.swift:780-861`）。
- 三个入口确实共用（生产）：`CompositionCore` 用同一个 `XMPFileLock.shared` 构造 `DeliveryCoordinator` 与 `WritebackService`（`gather-app/Sources/GatherHost/Composition/Core.swift:87-99`）；`LiveMetadataAPI` 的孤儿 restore/remove 也在 `fileLock.run` 内（`LiveMetadataAPI.swift:227-229`）。
- 唯一文件阶段入口：cleanup/finalize/replay 都经 `DeliveryFilePhase.run`（`DeliveryFilePhase.swift:67-101`），writeback 的 backup→read→writeAttributes 在 `WritebackService.fileLock.run` 内（`WritebackService.swift:743-753, 881-978`），orphan restore/remove 在 `LiveMetadataAPI.fileLock.run` 内（`LiveMetadataAPI.swift:227-262`）。

### 4.2 锁顺序（DB vs XMP）：无反向路径，但耦合是真实的（P2-5）

- 实测锁内做 DB 的路径：
  - `DeliveryFilePhase.verify` / `verifyAfterMutation` 在锁内 `deliveryRepo.get`（`DeliveryFilePhase.swift:121, 134, 168`）；
  - `WritebackService.writeGroupItems` 在锁内 `persistItemFailure` → `DeliveryRepo.markItem`（DB 事务）（`WritebackService.swift:902, 973`）。
- 反向路径（持 DB 事务/连接锁再取 XMP 锁）静态未找到：DB 事务的 body 是同步闭包，无法调用 async `fileLock.run`；`Database` 的 `stateLock`/`connectionLock` 也不会在持有时进入 XMP 锁。因此当前是单向 `XMP → DB`，**未发现死锁**。
- 风险：XMP 锁内等待单连接 DB 的全局锁；一个长 DB 事务（或另一路径的慢写）会让该侧车的文件锁持有时间变长，阻塞同路径的 cleanup/finalize/replay。建议把 `deliveryRepo.get` 的快照读移到取锁前（锁内只做一次最终复核）或明确接受；至少在文件锁内不做写 DB（`persistItemFailure` 改为出锁后批量落库）。

### 4.3 TOCTOU 残余与外部编辑器边界（P2-6 / P2-7）

- **C1/外部编辑器**：`verify` 先读指纹、后 `restore`；两者之间 C1 可写盘，restore 会用旧备份覆盖它，且 `verifyAfterMutation` 只比较 DB 行快照，不重读指纹（`DeliveryFilePhase.swift:127-144, 164-173`）。这不是 XMPFileLock 能解决的（锁只在进程内），但意味着「外部修改 → conflict」的承诺在 restore 路径上有一个不可消除的窗口。注意不能拿 `expected`（写后指纹）做 restore 后的比对（restore 后盘上本来就是旧内容，必然不等）；若要检测「restore 期间/之后被外部改」，应在锁内先读 `backupPath` 的指纹，restore 后再读目标盘指纹，二者不等则上报 `.invalidated`。
- **入队读不在锁内**：`MetadataMutationService.queueMutation` 只用 `PathSerialChain` 串行「读当前文件→合并→入队」，没有取 `XMPFileLock`（`Sources/GatherDelivery/Writeback/MetadataMutationService.swift:195-239`）。它与 cleanup 的 restore 可交错，关键词合并可能基于 restore 前的内容。文件写盘本身仍在 writeback 的锁内，所以不是覆盖写竞争，而是「合并输入基于过期快照」。建议入队读也走 `fileLock.run(path:)`（只读），或明确接受并在测试中钉死。
- **取消/超时**：排队中的任务取消后仍留在队列，直到当前持有者 release 才被 resume；若文件操作卡死（网络卷），取消的等待者也无法退出（`XMPFileLock.swift:81-104`）。没有超时参数。P2。

### 4.4 锁实例注入（P2-3）

- `FeatureAPIs.makeMetadata` 构造 `LiveMetadataAPI` 时没有传 `fileLock:`，依赖默认参数 `.shared`（`gather-app/Sources/GatherHost/Composition/FeatureAPIs.swift:143-147`；默认值在 `LiveMetadataAPI.swift:64-69`）。
- 生产 `CompositionCore` 也用 `.shared`，所以当前恰好同一实例；但这与文档「AppComposition 把 `XMPFileLock.shared` 同时注入三者」不符（`LiveMetadataAPI.swift:57-59`）。任何想注入自有锁的测试/嵌入组合都会让孤儿 restore 与 cleanup 退化为无锁。建议：`CompositionCore` 暴露 `xmpFileLock`，`FeatureAPIs.makeMetadata` 显式传入。

---

## 5. Schema V2

### 5.1 版本/快照/迁移注册（PASS）

- `SchemaCatalog.production`：`current=.v2`，快照 `v1/v2`，迁移 `[MigrationV1ToV2]`（`Sources/GatherPersistence/Database/Migration/SchemaCatalog.swift:22-31`）；`validate()` 校验 from+1==to、from 不重复、两端有快照（同文件 48-78）。
- `SchemaV2.ddl == SchemaV1.ddl`、`SchemaV2.shape == SchemaV1.shape`（`Sources/GatherPersistence/Database/Migration/SchemaV2.swift:14-18`），测试显式断言（`Tests/GatherCoreTests/Database/SchemaMigrationTests.swift:188-206`，尤其 195 `SchemaV2.ddl == SchemaV1.ddl`）。**migration 文件与 DDL 一致（no-op 版本位）。**
- `MigrationV1ToV2.apply` 为空，版本号由 `SchemaMigrator` 在 `BEGIN IMMEDIATE` 事务内统一写（`Migration/MigrationV1ToV2.swift:11-18`；`Migration/SchemaMigrator.swift:38-68`），DDL 与 `PRAGMA user_version` 同生共死。
- 迁移前备份：`SchemaBackup.create` 用 `VACUUM INTO` + 只读连接 `quick_check` + `user_version` 校验，失败即 `.io`、不迁移（`Migration/SchemaBackup.swift:21-135`）。
- 迁移后：`foreign_key_check` + 目标形态校验都在事务内，失败回滚（`SchemaMigrator.swift:48-64`）；回滚测试证明 `user_version` 仍 1、注入列不存在、备份保留、下次可重试（`SchemaMigrationTests.swift:226-266`）。
- `user_version=2`：`SchemaSQL.currentSchemaVersion=2`（`Database/Schema.swift:14`），测试 `productionCatalogRegistersVersionOnlyV2` 断言 `Database.openInMemory` 的 user_version=2（`SchemaMigrationTests.swift:215-224`）；`SchemaV1.userVersion=1` 仅作为旧库夹具（`SchemaV1.swift:50`）。

### 5.2 fail-closed / 0 表 / 非 SQLite / 高版本（PASS，附 P2）

- 判定顺序：`current → empty → older → newer → corrupt → unreadableVersion`（`Migration/OpenState.swift:71-131`）。
- `0 表`：`user_version=0` 且 `sqlite_master` 无用户表 → `.empty` → 建当前 schema（`OpenState.swift:102-106`；`Database.swift:215-224`）。`user_version=2` 但 0 表 → 形态不符 → `.corrupt`。
- 非 SQLite：`makeConnection` 抛错后按 `indicatesNotDatabaseFile` 判定 → 默认抛 `.corrupt`、不改文件；只有 `resetPolicy=.renameToIncompatible` 才改名重建（`Database.swift:180-198, 266-283, 304-308`）。
- 高版本：`.newer` 默认 `.versionUnsupported` 且主库字节不变；显式 reset 才改名（`Database.swift:245-264`；测试 `SchemaMigrationTests.swift:268-317`）。
- **P2-10（已确认，低风险）**：`DBError` 只保留 message、丢掉 SQLite 结果码（`DatabaseError.swift:110-115`），因此非 SQLite 最终仍靠错误文本子串分类（"not a database" / "file is encrypted" / "不是数据库"，`DatabaseError.swift:129-184`）。虽然 `init(sqliteCode:)` 有 `SQLITE_CORRUPT/NOTADB` 分支（`:87-107`），但底层没有把码传上来。SQLite 返回本地化/包装错误或文案变化时会落到 `.sql/.io` 而不是 `.corrupt`；默认 fail-closed 下只是错误码不精确，但开发 reset 的归类会错。建议让 `DBError` 携带 `sqlite3_extended_errcode`，用码而不是 message 匹配。

### 5.3 370 列 / 真实 V1 → V2：**不可达**（P1-4，已确认）

- 当前 `SchemaV1.shape` 要求 **43 表 / 373 列 / 69 索引 / 62 FK + 指纹**（`SchemaV1.swift:59-62, 84-96`）。
- `0 < version < current` 的分支要求「列形与该版本快照一致」才 `.older`，否则 `.corrupt(.shapeMismatch)`（`OpenState.swift:112-121`）。
- 历史事实：Cut 5 给 `similarity_cluster_meta` 加 3 列但**没有 bump user_version**（370→373），注释自己写明（`SchemaV1.swift:54-58`）。因此 Cut 2–4 期间生成的合法 V1 库（`user_version=1`、370 列）在本构建会被判 `.corrupt`，默认 fail-closed，不会走 `SchemaBackup.create` + `MigrationV1ToV2`。
- 测试把这个行为钉死：`v1ShapeMismatchFailsClosedAndReportsIssue` 造 370 列库，断言默认 `.corrupt`、**没有迁移备份**、显式 reset 才改名重建（`SchemaMigrationTests.swift:360-415`，尤其 396「形态不符不得迁移/备份」）。
- 结论：**V1→V2 的备份/迁移/回滚链本身是正确的，但它只对「列形已经是 373」的 V1 可达**；真正的旧 V1 用户没有升级路径（只能开发 reset 丢库，或手工改库）。这与 `SchemaV1.swift:58` 的「不匹配按不兼容库整体重置（含 -wal/-shm）」注释也不一致（默认是抛错不改名）。
- 修复建议（二选一，按项目「破坏性重构」政策选）：
  1. **承认 V2 只支持 373 列 V1**：在 README/迁移文档明确写「Cut 2–4 的 370 列 V1 不迁移，需重建」；同时修正 `SchemaV1.swift:58` 注释；
  2. **补一个真正的 V2/V3 迁移**：注册「370 列已知 shape → 373」的迁移（`ALTER TABLE similarity_cluster_meta ADD COLUMN ...` + 默认值/回填），让 `OpenState` 对已知旧 shape 返回 `.older` 而不是 `.corrupt`；这也能给未来加列建立「必须 bump 版本」的机制（当前 Cut 5 已违反）。
- 验收上，任务书里的「370 列」当前结果是 **fail-closed 正确、迁移不可达**，应记为「未满足 V1→V2 升级语义」。按项目「开发期库可丢弃」政策可降级为 P2；但只要对外宣称「V1 可升级到 V2」，就必须按 P1 处理。

### 5.4 迁移备份与 reset 的删除/改名顺序（P2-11）

- `SchemaReset.reset` 先移 `-shm`、`-wal`，再移主库（`Migration/ResetSupport.swift:23-40`）。若主库 move 失败（权限/占用），WAL 已经离开原路径，主库可能在缺少已提交 WAL 页的状态下被人工打开，造成「已提交事务看不到」的假回滚。注释声称「中途失败时用户数据仍在原路径」并不成立。建议：先 rename 主库（同一文件系统原子），成功后再移 sidecar；或失败时把 sidecar 移回。
- `SchemaBackup.pruneBackups` / `pruneIncompatibleCopies` 按文件名前缀删除，最多保留 N 套；同前缀的用户文件会被误删（`SchemaBackup.swift:77-99`；`ResetSupport.swift:73-95`）。概率低，P2。

---

## 6. 文件 / 路径 / 安全

### 6.1 path traversal（基本 PASS，P2-12 加固）

- 所有进入交付/文件阶段的业务路径来自 DB 行（`deliveries.xmp_path/photo_path/backup_path`），`metadata.resolve_orphan` 的输入 `xmpPath` 先 `TSPath.normalize` 再与 `orphanDeliveries()` 精确匹配（`LiveMetadataAPI.swift:187-196`），不会对任意用户路径执行 restore/remove。
- `DeliveryRepo.normalizedPath` 拒绝空串，`TSPath.normalize` 只做词法折叠（`DeliveryRepo.swift:221-225`；`RepositorySupport.swift:108-110`），**不解析 symlink**。
- 残余：`backup_path` 从 DB 直接用于 `removeFile`/`restore`，没有「必须位于照片目录 / 必须匹配 `.gather-backup-` 前缀 / 必须仍在允许根内」的校验（`DeliveryFilePhase.swift:186-193, 204-205`；`SidecarXMPProvider.swift:189-205`）。如果 DB 被手工篡改/迁移残留一条恶意 `backup_path`，finalize/replay 可以删除/覆盖任意可写文件。建议加前缀/父目录校验（至少 `backupPath.hasPrefix(xmpPath + ".gather-backup-")`），并拒绝 `..` 归一化后逃出照片目录的路径。
- `restore` 的目标由 `photoPath` 重新推导（`SidecarXMPProvider.resolveSidecarPath`），而锁键是 `xmpPath`（`DeliveryFilePhase.swift:72` vs `SidecarXMPProvider.swift:190`）。二者若因 rename/relink 漂移，锁与实际写入目标不是同一路径（见 6.3 的 relocation 逻辑）。建议在 `restore` 前断言 `TSPath.xmpSidecarPath(photoPath) == xmpPath`（或让 provider 接收显式 `xmpPath`）。

### 6.2 symlink（P2-13，已确认未处理）

- 扫描侧：`ScanPath.isDirectory` 用 `lstat`，符号链接目录不递归（`ScanPath.swift:94-98`）；但符号链接**文件**会按扩展名进入 `channel.push(.file)` 并在 `stat` 后导入（`IndexerService.swift:928-935, 604-610`），即可以导入指向根外的文件（读取其内容/EXIF/缩略图）。这是「扫描根边界」的旁路，不是写盘权限提升。
- 写盘侧：`writeAtomic` 用 temp + `replaceItemAt`（`SidecarXMPProvider.swift:758-780`），目标是 symlink 时**疑似**替换链接本身而非链接目标（macOS `replaceItemAt` 语义，未用测试钉死），因此**未发现** symlink 写穿；`removeFile` 也只删链接。`backup` 的 `copyItem` 对 symlink 的行为同样未在测试中钉死（`SidecarXMPProvider.swift:177-187`）。
- 建议：明确「扫描不跟随 symlink 文件」或记录为已知边界；补一条 symlink 侧车的写盘/恢复测试。

### 6.3 备份恢复 / 删除顺序 / FK（P2-14）

- 删除顺序：`delivery_items → delivery_sessions → deliveries`（`DeliveryRepo.swift:1232-1243`），`delivery_intents` 无 FK、按 id 单独收尾（`SchemaV1.swift:727-738`）。**顺序正确，无 FK 违规**（`deleteSyncedDeliveryBody` 内先删子行；`foreign_key_check` 在 open/迁移后为 0）。
- `delivery_sessions` FK 到 `sessions`/`deliveries` 都是 CASCADE（`SchemaV1.swift:701-707`），`delivery_items` 到 `deliveries/photos` 也是 CASCADE（`SchemaV1.swift:710-725`）。
- **注释错误**：`SessionService.deleteSessionDependencies` 声称「写回行由 deliveries 级联处理」（`Sources/GatherApplication/Services/SessionService.swift:149-156`），但 `deliveries` 没有 `session_id` 列/FK（`SchemaV1.swift:682-698`），删 session 只会级联 `delivery_sessions` 和 `delivery_items`（经 photos），`deliveries` 行与其 `backup_path` 文件会留下成为孤儿。若这是有意的「孤儿交付交由 metadata.orphans 处置」，注释应改成这一事实；否则应在删 session 时显式清理备份文件，避免磁盘泄漏。
- `AssetRepo.relocateMetadataState` 在照片移动时更新 `deliveries.xmp_path/photo_path`，但不清理该 `xmp_path` 上**已 prepared 的 intent**（`AssetRepo.swift:699-734`）。旧 path 的 intent 回放时 `verify` 找不到行 → `.alreadyGone` → 走 DB 段 `.alreadyGone` → finish；文件阶段不会执行（安全），但会留一条无意义回放。P2。
- `finalize` 与 `resolveOrphan` 的「行删除 vs 备份删除」顺序相反（P1-1）；`resolveOrphan` 是先删行再删备份（`LiveMetadataAPI.swift:231-239`），更安全。

### 6.4 临时文件（P2-15）

- `writeAtomic` 生成 `<xmp>.tmp-<pid>-<uuid>`（`SidecarXMPProvider.swift:758-768`），`restore` 生成 `<xmp>.restore-<pid>-<uuid>`（同文件 194-205），`FileSystemDeliveryFilePort.restore` 生成 `<xmp>.restore-<uuid>`（`DeliveryTypes.swift:288-302`）。
- 失败路径会 `removeItem`；但进程崩溃/断电后没有启动清理，照片目录会累积 `.tmp-`/`.restore-` 文件；`.gather-backup-<uuid>` 也可能因 DB 删除成功但 backup 删除失败而永久残留（finalize 是唯一主动删备份的路径）。建议启动/导入时做一次「同目录、匹配前缀、超过 N 天」的清理（谨慎：备份文件不能按时间盲删，应先与 DB `backup_path` 对账）。

---

## 7. Trace 日志 / GatherLogger

### 7.1 泄漏面（P2-8，已确认）

- 新增 trace 在 info 级输出**完整绝对路径**（字面量形如 `xmp=/Users/.../IMG_0001.xmp`）：cleanup/finalize 的 `xmp=...` 在 `DeliveryCleanupFlow.swift:175, 192, 201, 209, 229, 245, 279, 310, 324, 332, 342, 349, 359, 370, 380, 474, 482, 490, 499, 507, 525, 542, 558, 586, 600, 608, 617, 624, 632`；replay 在 `DeliveryReplayFlow.swift:79, 87, 95, 104, 113, 133, 149, 171, 250, 268, 276, 285, 292, 301, 309`。
- confirm 的 trace 含 `session:<sessionId>`（`DeliveryCoordinator.swift:261-290`）。这些是用户主目录/会话标识，默认 `GatherLogger.minimumLevel = .info`（`Sources/GatherProtocol/Logging/Logger.swift:23`），console 输出即可看到。
- 若日志被宿主重定向到文件/Console/诊断包（本仓库未内置文件 sink，但 stdout 可被外部收集），会暴露用户目录结构与工作流。**没有脱敏/哈希/截断**。
- 建议：日志只保留 `xmpPath` 的 basename 或 `deliveryId/revision`；路径级细节降为 `.debug`；sessionId 做短哈希；或在 sink 层统一 redaction。

### 7.2 性能（P2-9，已确认结构，量级待基准）

- 每个交付在成功路径上约 4 条 info（file start/done、db start/done；finalize/replay 同量级）；失败分支再加 1–2 条 warn。10k 交付的 cleanup 会产生约 4–8 万条日志。
- `GatherLogger.log` 对每条日志持**全局 `NSRecursiveLock`**，并在锁内做 `ISO8601DateFormatter.string(from:)` 与 `state.output(...)`（`Logger.swift:64-71`）。因此：
  1. 所有域（Job/Delivery/UI/导入）的日志在一条全局锁上串行；
  2. sink 慢（stdout 管道满）会阻塞所有调用方，包括在 XMP 文件锁/DB 事务附近打日志的线程；
  3. 字符串插值在调用点完成，即使 `minimumLevel` 过滤掉也付出了路径拼接成本。
- 建议：trace 采样/降级（成功路径 debug、仅失败 info/warn）；sink 移出锁（复制 output 后在锁外调用）；时间戳惰性格式化；或引入 `os_signpost`（结构化、无字符串）。

### 7.3 行为不变性

- trace 调用不改变控制流（`GatherLogger.log` 不抛错），confirm 的 `do/catch` 只多了一条 warn 后 `throw error`（`DeliveryCoordinator.swift:284-292`），与迁移前返回值一致；cleanup/replay 的日志都在分支前后，未改变 CAS/事务边界。**未发现日志导致的业务时序变化。**

---

## 8. 验证记录（实测）

> 在 `desktop/native` 下执行；日志重定向后单独记录 `EXIT:$?`，避免 `| tail` 掩盖真实退出码。

| 检查 | 命令 | 结果 | exit |
|---|---|---|---|
| core 全量测试（第 1 次） | `swift test --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --explicit-target-dependency-import-check error` | `1100 tests / 165 suites`，**1 issue**；当次用了 `2>&1 \| tail -30`，失败用例名被截断、不可恢复（不记为通过） | 被 pipeline 掩盖（tail 的 0） |
| core 全量测试（第 2 次） | 同上，输出重定向到 `/tmp/gather-core-test-2.log` | **`Test run with 1100 tests in 165 suites passed`**；`SchemaMigrationTests`、`DeliveryStateMachineTests`、`DeliveryDBPhaseTests` 全绿 | **0** |
| core 全量测试（第 3 次） | 同上，输出重定向到 `/tmp/gather-core-test-3.log` | **`Test run with 1100 tests in 165 suites passed`**；日志中 `✘` 计数 0 | **0** |
| schema verify | `swift run --package-path gather-core --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch gather-schema verify` | **`schema ok: tables=43 columns=373 indexes=69 fks=62 user_version=2 foreign_key_violations=0`** | **0** |
| 状态机测试（日志抽查） | 第 2 次日志 | `deliveryTableMatchesPersistenceTransitionTable()` passed | 0 |
| DB 单事务测试（日志抽查） | 第 2 次日志 | `itemGateSkipFinishesIntentWithErrorAndKeepsDelivery()`、`finalizeSharesTheSameAtomicDeleteAndFinish()` passed | 0 |
| 370 列测试（日志抽查） | 第 2 次日志 | `v1 缺 3 列（370）：默认 .corrupt 且不迁移；显式 reset 保留旧副本` passed；日志打印 `列数 370，期望 373` 与三条缺列 | 0 |
| 迁移回滚测试（日志抽查） | 第 2 次日志 | `迁移失败回滚：抛 .migration、user_version 仍 1、新列不存在、备份保留` passed | 0 |
| XMPFileLock 串行测试（日志抽查） | 第 2 次日志 | 同一归一化路径串行 / 不同路径并行 2 例 passed | 0 |

**测试口径备注**：

1. 第 1 次的 1 issue 无法归因（输出被截断），按既有 flake 处理但**不冒充为绿**；第 2/3 次为完整日志、真实 exit 0。若 CI 复现，应以第 1 次失败为准重跑并保留完整日志。
2. 仓库文档给出的基线是 core `1,100/165`（`docs/reviews/architecture-remediation-status.md`），与本次第 2/3 次一致；没有测试数量漂移。
3. 本报告**没有**跑 app 包测试；本任务范围是 core 的数据/并发层。
4. 测试日志里可见 trace 的实际形态（例如 `trace=delivery:1/rev:0/file ... xmp=/var/folders/.../photo0.xmp ...`），可佐证 §7.1 的绝对路径泄漏面。
5. 三次 core 测试都跑在 20:42–20:46 的 HEAD 工作区（当时 `git status` 仍只有未跟踪报告）；20:47 起并行任务开始改注释，因此以上数字对应 HEAD `df73880`，不是当前 dirty 工作区。

---

## 9. 未执行 / 限制

1. 未做真实 GUI/Capture One 并发人工验收（本环境无 GUI 自动化）；C1 的外部写窗口只能从代码边界判断，不能实测。
2. 未做故障注入（断电/磁盘满/权限拒绝）实跑；P1-1 的「DB 段失败后备份悬空」由代码路径与已有 trigger 注入测试的同类语义推出，未新增测试。
3. 未做多进程并发（两个 Gather 实例打开同一库/同一 XMP）；XMPFileLock 明确是进程内锁。
4. 未跑 app 包测试（本报告范围是 core 数据/并发；app 的 UI 门禁由其他评审负责）。
5. 未改任何源码/测试/Package/脚本/CI；本轮唯一写入是本文件（`docs/reviews/` 下其他未跟踪文件由并行评审新增）。

---

## 10. 缺陷索引（P0/P1/P2）

> 每一行的「证据」都能在正文对应小节展开；`已确认` 表示代码或测试直接证明，`疑似` 表示需要并发/外部条件。

### 10.1 P0

无。未发现正常路径必现的数据损坏；本结论不覆盖「外部编辑器并发」与「370 列 V1 升级」这两个已知边界（分别见 P2-6、P1-4）。

### 10.2 P1

| ID | 位置 | 证据 | 影响 | 修复 |
|---|---|---|---|---|
| P1-1 | `DeliveryFilePhase.swift:199-207`；`DeliveryDBPhase.swift:181-204`；`DeliveryRepo.swift:539-550`；`WritebackService.swift:919-922` | finalize 先 `removeFile(backup)` 再 DB CAS；拒绝时只 `finish(error:)`；`mergeInput` 不清 `backup_path`，后续写入复用旧路径、不再备份 | 交付行保留但备份已删；后续 cleanup `backupMissing` 反复重试（仅 culling 可再走 finalize 删行）；原 XMP 备份不可恢复 | 改「删行成功→删备份」或可逆改名；拒绝时清 `backup_path`；补 CAS 拒绝回归测试 |
| P1-2 | `DeliveryRepo.swift:416-441`；`321-386`；`WritebackService.swift:825-840` | `markWritten` 只 CAS revision/status，无 `lease_owner`；`renewWriting` 失败只记 error 后继续 | 租约过期被接管后，旧写者提交 `written` 覆盖新 `base_fingerprint/backup_path` | `markWritten` 加 `lease_owner=?` CAS；renew 失败即中止本组收敛 |
| P1-3 | `DeliveryCoordinator.swift:263-274`；`DeliveryRepo.swift:1309-1313`；`WritebackService.swift:1090-1106` | 门禁读在事务外；`confirmed_at` UPDATE 无 status 过滤；存在公共 `confirmSync` 旁路 | 窄窗口内确认新内容未确认的交付；旁路可跳过 reload-ack/完整性 | 门禁并入事务；`confirmed_at` 加 `status='written'`；只保留 Coordinator 一个确认入口 |
| P1-4 | `OpenState.swift:112-121`；`SchemaV1.swift:54-62`；`SchemaMigrationTests.swift:360-415` | 370 列 V1 因 shape 不匹配被判 `.corrupt`，默认 fail-closed、无迁移备份（按「开发期库可丢弃」可降 P2；对外宣称可升级时按 P1） | Cut 2–4 的合法 V1 库无法升级到 V2（只能 dev reset） | 明确文档「不支持 370 列 V1」或补 370→373 的真实迁移并 bump 版本 |

### 10.3 P2

| ID | 位置 | 证据 / 影响 | 修复 |
|---|---|---|---|
| P2-1 | `DeliveryState.swift:77` vs `:60` | `isTerminal` 含 synced，但 synced 可回 pending；属性零生产引用 | 删除或改名，避免未来门禁误用 |
| P2-2 | `DeliveryCleanupFlow.swift:403-647`；`DeliveryDBPhase.swift:181-205` | finalize 无 `cleanupItemGate`；当前因「新输入必重开 delivery」不可达，但无断言 | finalize 复用 item gate，增加 skip/错误码 |
| P2-3 | `FeatureAPIs.swift:143-147`；`LiveMetadataAPI.swift:64-69` | LiveMetadataAPI 依赖默认 `.shared`，未显式注入 | 组合根显式传 `xmpFileLock` |
| P2-4 | `DeliveryIntentRepo.swift:337-343`；`DeliveryReplayFlow.swift:27-197` | replay 无 claim，两并发 replay 会争同一 intent，后者报 rowNotFound | intent 抢占/幂等忽略已闭环 |
| P2-5 | `DeliveryFilePhase.swift:121,134,168`；`WritebackService.swift:902` | XMP 锁内做 DB 读写；单向 XMP→DB，无死锁但长 DB 事务放大锁持有 | 快照读移出锁；失败落库出锁批量 |
| P2-6 | `DeliveryFilePhase.swift:125-126,127-144,164-173` | finalize 不做盘上指纹；cleanup 的 verify 与 restore 之间可被 C1 写 | 明确边界；restore 前后比对备份指纹并上报 invalidated |
| P2-7 | `MetadataMutationService.swift:195-239` | 入队读只走 PathSerialChain，不在 XMP 锁内，合并可能基于 restore 前内容 | 只读也走 `fileLock.run` 或记录接受 |
| P2-8 | `DeliveryCleanupFlow.swift:175...632`；`DeliveryReplayFlow.swift:79...309`；`DeliveryCoordinator.swift:261` | info 级完整绝对路径 + sessionId，无脱敏；10k 交付约 4–8 万条 | basename/短哈希；成功路径降 debug；sink redaction |
| P2-9 | `Logger.swift:64-71` | 每条日志持全局锁并在锁内做格式化 + sink 回调 | sink 移出锁、惰性时间戳、采样 |
| P2-10 | `DatabaseError.swift:110-115, 129-184` | `DBError` 只保留 message、丢 SQLite 结果码，`init(dbError:)` 走 `classify` 子串；`indicatesNotDatabaseFile` 再加一层子串 | 保留 sqlite3 extended errcode 到 `DBError`，用码分类 |
| P2-11 | `ResetSupport.swift:23-40` | 先移 -wal/-shm 再移主库；主库 move 失败会留下无 WAL 的库 | 先主库后 sidecar，失败回移 |
| P2-12 | `DeliveryFilePhase.swift:186-205`；`SidecarXMPProvider.swift:189-205` | `backup_path` 未校验前缀/父目录即 remove/restore | 加 `.gather-backup-` 前缀与目录校验 |
| P2-13 | `IndexerService.swift:928-935`；`SidecarXMPProvider.swift:758-780` | symlink 文件可被导入（读根外内容）；写盘疑似替换链接本身（未测） | 明确 symlink 策略并补测试 |
| P2-14 | `SessionService.swift:149-156`；`SchemaV1.swift:682-698`；`AssetRepo.swift:699-734` | 删 session 不删 deliveries/备份（注释说级联，错误）；relocate 不清旧 intent | 修注释或显式清理；relocate 时收尾 intent |
| P2-15 | `SidecarXMPProvider.swift:758-768,194-205`；`DeliveryTypes.swift:288-302` | 崩溃后 `.tmp-`/`.restore-`/备份文件无启动清理 | 启动对账清理（备份按 DB 引用判定） |

## 11. 结论

- **可信的部分**：7 态迁移表与 Persistence 逐边一致且有双向测试；cleanup/finalize 的 DB 删除 + intent.finish 单事务、失败回滚、幂等重放有确定性测试；Schema V2 的版本位/备份/回滚/fail-closed 结构正确；XMP 文件锁在进程内把 cleanup/finalize/replay、writeback、orphan restore 串到同一路径上，未发现反向锁序。
- **必须在发布前处理**：
  1. P1-1 finalize 的「先删备份、后 CAS」——改为删行成功后再删备份，或可逆改名；
  2. P1-4 370 列 V1 无升级路径——明确不支持并改文档，或补真正的 370→373 迁移；
  3. P1-2 `markWritten` 的 owner 校验——至少把 `lease_owner` 带进 CAS，租约丢失时拒绝 `written`；
  4. P1-3 confirm 的事务内状态门禁 + 删除/收口 `WritebackService.confirmSync` 旁路。
- **可排期**：P2 的 trace 脱敏/日志锁、XMP→DB 锁内 DB 写、LiveMetadataAPI 显式注入锁、外部编辑器窗口文档化、临时文件清理、备份路径校验。
- **验收口径**：当前 HEAD 可以判「机器可验收（数据/并发核心路径）」，但 **不能判「V1 用户可平滑升级」**，也不能判「外部编辑器并发安全」；这两点必须在发布说明中显式写明。
