# 数据/安全 P1/P2 复核（final sweep）

> 只读静态审计。基准：**committed HEAD `ab7752e`**；本文件所有 `file:line` 均按该提交（`git show HEAD:<path>`）编号。
> 任务开始时工作区干净；审计过程中工作区出现 4 个未提交文件（见 §0.1，非本次审计写入），本报告不把它们当作 HEAD 事实，只在 §0.1 单独评估。
> **未执行** build / test / 门禁 / sqlite3 探针（按任务书禁令）；所有"测试证据"均为对测试源码的静态核对，不代表本地通过。
> 不信任 `docs/reviews/architecture-remediation-status.md` 的台账口径；凡必要处用代码反证台账。
> 唯一写入：本文件。

## 0. 结论（先行）

| # | 复核项 | 判定 | 一句话依据 |
| --- | --- | --- | --- |
| 1 | finalize 备份顺序（文件阶段不删 → DB 提交后删 → replay fileDone 后置 → 失败保留行+备份） | **已闭合** | `DeliveryFilePhase.run` 的 finalize 分支只 verify 不碰盘；唯一删除点 `removeFinalizeBackup` 只在 `applyFinalize` 返回 `.deleted/.alreadyGone` 后调用；CAS 拒绝分支保留备份；replay 两条路径共用同一后置删除点 |
| 2 | lease owner CAS 覆盖 markWritten/markFailed/markConflict；renew 失败不收敛；confirm 单事务门禁/status；confirmSync 是否仍可绕过 | **已闭合（confirmSync 无旁路）** | 三个 mark 入口共用 `leaseAwareTransition`（CAS 带 `lease_owner=?`）；execute 收敛/崩溃归位都在 renew 失败后 `continue`；`DeliveryRepo.confirm` 用 `transaction(.immediate)` 把门禁读+写确认+翻 synced 放同一事务；`WritebackService.confirmSync` 与三域 `confirmSync` 全部委托 `DeliveryCoordinator.confirm`（生产默认 `requireReloadAck=true`） |
| 3 | 370 列迁移：shape 识别、ALTER、备份、回滚、指纹；未知 371 仍 corrupt | **已闭合** | `HistoricalV1Shape`（43/370/69/62 + 8 关键列 + 固定指纹）在 `OpenState` 仅对 `from==.v1` 放行；`MigrationV1ToV2` 逐列 ALTER（定义与 DDL 逐字一致）；备份先于迁移、失败在事务内回滚、提交前校验目标 373 指纹；370+1 未知列（=371）走 shapeMismatch→corrupt，测试显式断言 `columnCount == 371` |
| 4 | backup_path 校验；历史备份 fail-closed 的发布影响 | **部分闭合（1 个 P1）** | 同目录/前缀/`..`/NUL/symlink/常规文件都覆盖；但"同目录/前缀"是**大小写与 Unicode 规范化敏感的字符串比较**，而 backup_path 由宿主按盘上真实大小写生成、xmp_path 由 `TSPath` 生成小写 `.xmp` → 大写 `.XMP` sidecar 会被 fail-closed 永久拒绝；宿主孤儿 restore/remove 入口完全没接校验 |
| 5 | replay claim 进程内 vs 跨进程；trace 脱敏是否覆盖 reason；临时文件 sweep 安全性 | **未闭合（claim 实际 per-call，弱于台账）** | `claims` 是 `DeliveryReplayFlow` 的实例字段，而 `DeliveryCoordinator.makeReplayFlow()` 每次 `replay()` 都新建 flow ⇒ 两次并发 `replay()` 各持独立 claim 集合，互不排斥；进程内跨调用都不生效，"仅进程内"的台账口径不成立。trace 的 reason 已脱敏（含二级兜底），但仍有 4 处非 trace 日志打印绝对路径；sweep 另有文档-实现漂移与锁外删除 |
| 6 | 遗漏/竞态/错误码回归 | **无错误码回归，遗漏/竞态见 §2** | 对 `GatherDelivery` 全树做 `4bbfa8d^` vs HEAD 的 `XMP_[A-Z_]*` 集合比较：**0 个旧码消失**、新增 11 个；`GatherPersistence` 的 `DELIVERY_*` 码同样 0 增 0 删 |

**P0：0 项。P1：1 项（大小写/规范化 fail-closed）。P2：11 项。**

### 0.1 审计期间的工作区漂移（非本次审计写入）

审计开始时 `git status --short` 为空；结束时出现 5 个未提交修改（并行会话的在途修改，未 commit；非本次审计写入）：

- `GatherDelivery/File/DeliveryBackupPath.swift`（+9/-2）：目录与前缀改为 `caseInsensitiveCompare` + `range(of:options:[.caseInsensitive, .anchored])`；
- `GatherDelivery/Coordinator/DeliveryCoordinator.swift`（+5/-1）：新增 `private let replayClaims = DeliveryReplayClaims()`，传给每次 `makeReplayFlow()`；
- `GatherDelivery/Coordinator/DeliveryReplayFlow.swift`（+7/-3）：`DeliveryReplayClaims` 改 internal，`init` 接收外部 claims；
- `Tests/.../DeliveryBackupPathTests.swift`（+11）：新增大写 `.XMP` 用例；
- `desktop/native/build.sh`（+23/-1）：release 模式强制 universal/Developer ID/公证/插件（release 方向，非本报告数据面）。

对这两处 in-flight 修复的静态评估（**未经编译器/测试验证**）：

1. 大小写修复能覆盖 P1-1 的主触发面（`IMG_1.XMP` vs `IMG_1.xmp`）；**仍不覆盖 Unicode NFC/NFD**（`caseInsensitiveCompare` 不是规范化等价），也**没有覆盖宿主孤儿入口**（P2-2）与无备份分支（P2-3）。建议再补 NFD 用例并把校验入口收进 `LiveMetadataAPI`。
2. replay claims 提到 Coordinator 后，生产唯一 coordinator 下的跨调用并发已被覆盖（P2-1 的主触发面）；仍缺测试（没有两路 `replay()` 并发用例），跨进程/多 coordinator 仍不互斥（台账口径应改成"同 coordinator 进程内"）。
3. 这两处修改会使 §1.4/§1.5 的部分行号在**工作区**偏移 +2~+5；本报告行号按 HEAD 不变。

## 1. 逐条复核

### 1.1 finalize 备份顺序（任务 1）——闭合

代码事实：

- 文件阶段不删：`DeliveryFilePhase.swift:94-102` 的 `.finalize` 分支只 `break`（注释明确"备份删除在 DB 删除事务成功之后"）。
- 唯一删除点：`DeliveryFilePhase.removeFinalizeBackup(xmpPath:backupPath:)`（`DeliveryFilePhase.swift:244-278`）在 `fileLock` 内做"行是否重新出现 → 路径校验 → 存在性 → remove"；`.retained/.failed` 都只上报、不回滚。
- DB 提交后才调用：`DeliveryCleanupFlow.swift:697-704`（`.deleted`）与 `:705-719`（`.alreadyGone`）在 `applyFinalize` 返回后调用；`:733-743` 的 `.idChanged/.revisionChanged/.stateChanged` 分支**不调用**，备份原样保留。
- DB 段单事务：`DeliveryDBPhase.swift:221-281`（item 门禁 → 删除 → `intent.finish` 同事务；`.incompleteItems` 时 finish(terminal error) 后返回，行/备份保留）。
- replay 后置：`DeliveryReplayFlow.swift:284-309` 的 fileDone 循环显式不跑文件阶段；`:462-476` 在 `.deleted/.alreadyGone` 之后才 `removeFinalizeBackup`；prepared 与 fileDone 共用 `applyFinalizeDBAndFinish`。
- 失败保留行+备份：`DeliveryDBPhase` 抛 `database/finish` 时整个事务回滚（intent 仍 fileDone）；`DeliveryCleanupFlow.swift:670-688` 只记错并 `continue`。

测试静态核对（未运行）：`DeliveryCoordinatorTests.swift:770-803`（删除时行已删、intent 已闭环、未 restore）、`:807-843`（DB 删除失败→行/备份/意图保留，修复后 replay 删行删备份）、`:847-877`（finish 失败同事务回滚）、`:881-914`（CAS 拒绝保留备份，intent 闭环）、`:1011-1090`（replay prepared/fileDone 的 finalize 后置与缺备份幂等）。

残余（非阻断）：DB 提交成功、备份删除前进程崩溃 → 无 DB 引用的孤儿备份（注释已承认，`DeliveryCleanupFlow.swift:757-760`）；无对账清理入口。另：finalize 的文件阶段实际只做 verify（`.fileFailed/.invalidated` 分支不可达），对应日志分支是死代码，但不影响顺序正确性。

### 1.2 lease owner CAS / renew / confirm / confirmSync（任务 2）——闭合

- 三入口共用 owner CAS：`DeliveryRepo.swift:497-545`（`leaseAwareTransition`：非空 owner 先快速失败，CAS 加 `lease_owner = ?`，CAS 失配后只在 owner/状态确实漂移时抛 `leaseLost`）；`markWritten` 在 `:468-495`，`markFailed` 在 `:1062-1077`，`markConflict` 在 `:1084-1099`，三者同一条路径。空 owner 仍带 `lease_owner=''` CAS（cleanup/replay 的 conflict 标记不会覆盖正在写盘的交付）。
- renew 失败不收敛：`WritebackService.swift:949-975`（`renewWriting` 抛错或返回 false → 记 `DELIVERY_LEASE_LOST` 后 `continue`，不写 written/failed）；崩溃归位 `:469-481`、`:509-527` 同样先 renew 再 mark，失败即放弃；`renewWriting` 本身是 `WHERE ... status='writing' AND lease_owner=?`（`DeliveryRepo.swift:437-456`）。
- confirm 单事务：`DeliveryRepo.swift:1407-1512`，关键为 `:1443` 的 `transaction(.immediate)`、`:1446-1458` 事务内 summary 门禁 + reload-ack、`:1464-1472` confirmed_at 只写 `delivery.status IN ('written','synced')`、`:1474-1494` synced/item 翻转同事务。Coordinator 只做错误码映射（`DeliveryCoordinator.swift:416-467`）。
- confirmSync 无旁路：`WritebackService.swift:1280-1296` 委托 `delivery.confirm(sessionId:module:)`；`SimilarityService.swift:406-409`→`424-445`、`CullingService+Delivery.swift:283-305`、`FaceKwService+Writeback.swift:62-86` 全部经 `delivery.confirm`（`CoordinatorDeliveryAdapter.confirm` → `engine.confirm`，`DeliveryModulePorts.swift:113-116`）；生产组合根 `Composition/Core.swift:90-91` 未传 `requireReloadAck`（默认 true）。`requireReloadAck: false` 只出现在 4 处测试（`APIExportMetadataTests.swift:925,1043`、`TraceLoggingTests.swift:206`、`WritebackServiceTests.swift:538`）。
- Host 无写旁路：`LiveMetadataAPI` 只注入 `StateWriter` 语义入口，grep `deliveryRepo.(mark|merge|claim|delete|upsert|confirm|linkSession|updateItem|resetConfirm)` 在 `gather-app/Sources` 为 0 命中。

残余：
1. reload-ack 失效与写入不同事务（P2-4）。
2. `DeliveryStateWriter.markFailed/markConflict` 的 `leaseOwner` 默认 `""`（P2-8）。
3. `acceptExternalState` 的 claim/reset/markWritten 仍是三个独立事务（`DeliveryStateWriter.swift:318-343`，reset 失败停 writing，注释已承认），非本轮范围。

### 1.3 370 列迁移（任务 3）——闭合

- shape 识别：`HistoricalV1Shape.swift:20-47`（43 表/370 列/69 显式索引/62 FK；`requiredColumns` 由 `SchemaV1.requiredTableColumns` 去掉 3 列派生，不另写全量；指纹硬编码 `7fb8…`）。`OpenState.swift:115-141`：仅当 `from == .v1` 且 historical issues 为空才 `.older(.v1)`，否则 shapeMismatch→`.corrupt`；371 列（370+1 未知列）列数/关键列/指纹全不匹配，仍然 corrupt。
- ALTER：`MigrationV1ToV2.swift:34-47` 按 `PRAGMA table_info` 逐列判断后 `ALTER TABLE similarity_cluster_meta ADD COLUMN`，定义与 `SchemaV1.swift:497-499` 逐字一致（顺序 algorithm_version→input_signature→state_digest，与 DDL 列序一致，保证 cid 对齐）。
- 备份：`Database.swift:226-234` 先 `SchemaBackup.create`（`SchemaBackup.swift:21-48`，VACUUM INTO + 只读 quick_check + user_version 校验），备份失败直接抛 `.io`、不迁移；成功后 `SchemaMigrator` 才执行。
- 回滚：`SchemaMigrator.swift:38-94`：`BEGIN IMMEDIATE` 内跑 steps + 写 user_version + `foreign_key_check` + 目标 373 指纹校验；任一步抛错整体回滚，连接级 FK 在事务外恢复。
- 指纹：提交前用 `SchemaV2.shape`（=V1 373 形态）校验（`SchemaMigrator.swift:55-64`），失败与 DDL 一起回滚。
- 测试静态核对：`SchemaMigrationTests.swift:259-322`（370→migrated、8→11 列、默认值/CHECK/数据保留/备份 1 套）、`:324-367`（注入半途 ALTER 失败→回滚为 8 列+user_version=1、备份保留、可重试）、`:726-784`（370+1 未知列=371→默认 corrupt、不改文件、不产生备份、显式 reset 才改名）。

残余：P2-10（提交后 assertReady 不可回滚）、P2-11（指纹对索引 SQL 文本敏感）。

### 1.4 backup_path 校验（任务 4）——部分闭合

已覆盖（`DeliveryBackupPath.swift:69-123`）：empty xmp、NUL、原始串 `..` 组件（归一化前检查，避免 `standardizingPath` 折叠后漏判）、归一化后同目录、`<xmp basename>.gather-backup-<non-empty>` 前缀、symlink（含断链）、非常规文件；不存在（ENOENT）不判死以保留 `backupMissing` 语义。GatherDelivery 内五处调用：file phase verify（`DeliveryFilePhase.swift:144-153`）、restore 前二次校验（`:217-225`）、finalize 后置删除（`:257-266`）、两个文件端口（`DeliveryTypes.swift:33-40, 285-292`）。

未覆盖的入口（P2-2 / P2-3）：
- `LiveMetadataAPI.resolveOrphan` 直接调 `xmp.restore/removeFile`，绕开 `XMPDeliveryFilePort`（`LiveMetadataAPI.swift:240-249, 258-270`），而 `DeliveryTypes.swift:34-35` 的注释声称"LiveMetadataAPI.resolveOrphan 直接走这里"——与实现不符；`gather-app/Sources` 全树 0 处 `DeliveryBackupPath` 引用。
- `DeliveryFilePhase.performCleanup` 的"无备份删除 sidecar"分支直接 `removeFile(xmpPath)`（`:210-213`），不经任何校验；有备份分支的 restore 目标由 `payload.photoPath` 推导（`:222-225`），只校验了 backup 与 `xmpPath` 同目录，没有断言 `xmpPath == TSPath.xmpSidecarPath(photoPath)`。

历史备份的发布影响：历史行只要 `backup_path` 不是"与当时 xmp_path 同串大小写 + 精确前缀"，就从"能清理/能恢复"退化为"永久拒绝"：cleanup 以 `XMP_CLEANUP_BACKUP_PATH_INVALID` 收尾 intent（`DeliveryCleanupFlow.swift:285-305`），finalize 以 `XMP_FINALIZE_BACKUP_PATH_INVALID` 收尾（`:606-626`），replay 同样 fail-closed（`DeliveryReplayFlow.swift:232-251`）。行与备份都保留（不误删、不误恢复，安全性方向正确），但用户侧表现为"清理永远失败 + 备份文件永久残留"，且错误码是新增的、UI 未见过。台账只写"历史非受控 backup_path 会 fail-closed"，未写大小写这一最常见触发面（P1-1）。

### 1.5 replay claim / trace / sweep（任务 5）——claim 未闭合

- **claim 实际 per-call（P2-1）**：`DeliveryReplayFlow.swift:22-37,47,59` 的 `claims` 是 flow 实例字段；`DeliveryCoordinator.swift:344-351` 的 `makeReplayFlow()` 每次新建 flow，`:531-533` 每次 `replay()` 都 `makeReplayFlow().replay()`。因此 `claims.claim(intent.id)`（`DeliveryReplayFlow.swift:120-125`、`:300-305`）在单次 replay 内必然成功（backlog 内 id 唯一），跨 replay 调用完全不互斥。生产有并发触发面：启动回放（`AppRuntime.swift:151`）与 similarity/face/culling 的 cleanup 内 replay（`SimilarityService.swift:416,467`、`FaceKwService+Writeback.swift:75,130`、`CullingService+Delivery.swift:53,61`）。后果是重复处理：`advance` 命中已被对方闭环的 intent 会 `rowNotFound` → `XMP_CLEANUP_ADVANCE_FAILED` 记 failed；DB 段靠 `.alreadyGone` 幂等。**无数据破坏**（fileLock 串行文件阶段、DB 事务+CAS 串行删除），但 summary 计数/错误会假阳性；该 claim 无任何并发测试（delivery 测试无两路 replay 用例）。
- 跨进程：无 claim、无 DB 抢占；`XMPFileLock` 是进程内 actor（`XMPFileLock.swift:34-104`）。跨进程仍只有 SQLite 写锁兜底（台账已如实记录"仅进程内"，但未记录"实际连进程内跨调用都不成立"）。
- trace 脱敏覆盖 reason：是。`DeliveryTrace.reason(_:_:)` 对 `DeliveryCoordinatorError/DeliveryRepoError` 做结构化映射（`DeliveryCoordinator.swift:75-123`），文本 reason 走 `sanitize`（替换上下文路径、home、扫描 `/...` 绝对路径）；`DeliveryTrace.log` 再对整行 fields 做一次 `redactAbsolutePaths`（`:194-196`），所以新增日志点即使漏调 `reason()` 也不会输出绝对路径。测试 `TraceLoggingTests.swift:744-767` 用"错误描述含绝对路径"的注入验证 warn 不泄漏、summary 仍保留完整路径。
- 脱敏残余：P2-5（4 处非 trace 日志；`~`/相对路径不覆盖；pathToken 保留 basename）。
- 临时文件 sweep 安全性：`DeliveryTemporaryFiles.swift:29-65` 只删同目录、`<basename>.tmp-`/`.restore-` 前缀、非 symlink、常规文件、mtime ≥24h；不碰 `.gather-backup-*`（正确）。残余 P2-6。

### 1.6 遗漏 / 竞态 / 错误码回归（任务 6）

- 错误码：`GatherDelivery` 0 个旧码消失、新增 11 个（`XMP_BACKUP_PATH_*` ×6、`XMP_BACKUP_PATH_INVALID` 兜底、`XMP_CLEANUP_BACKUP_PATH_INVALID`、`XMP_FINALIZE_BACKUP_PATH_INVALID`、`XMP_FINALIZE_INCOMPLETE_ITEMS`、`XMP_CLEANUP_REPLAY_CLAIMED`）；`GatherPersistence` 的 `DELIVERY_*` 码 0 增 0 删。旧码语义保持（如 `XMP_CLEANUP_ABORTED_EXTERNAL_EDIT`/`XMP_CLEANUP_GUARD_CONFLICT_CAS_FAILED` 仍在）。**无错误码回归**；但新增码的 UI 映射缺失（P2-9）。
- 竞态/遗漏集中在 §2。补充两条静态确认的"保护顺序"事实：cleanup 的 item 门禁在 prepare/文件阶段之前（`DeliveryCleanupFlow.swift:64-102`）且在 DB 事务内复核（`DeliveryDBPhase.swift:125-157`），跨模块未 synced item 不会随文件删除丢失；DB 阶段的 `.foreignItemsPending` 会显式上报"文件可能已恢复"（`DeliveryCleanupFlow.swift:388-399`），不静默当成功。

## 2. 缺陷清单

### P0

无。

### P1

#### P1-1（已确认，代码路径；触发面待实机）backup_path 校验对大小写/Unicode 规范化敏感，大写 `.XMP` sidecar 会让 cleanup/finalize 永久 fail-closed

- 位置：`DeliveryBackupPath.swift:85-96`（`backupDirectory == xmpDirectory`、`backupName.hasPrefix(expectedPrefix)` 均为逐字节字符串比较）；产生端 `SidecarXMPProvider.swift:177-186`（`backupPath = resolveSidecarPath(photoPath) + ".gather-backup-UUID"`），`:216-231` 的 `resolveSidecarPath` 明确"返回磁盘上真实存在的条目"（保留大小写）；DB 端 xmp_path 在默认 `asset_read_mode=dual` 下取 legacy 分支（`PhotoAssetResolver.swift:61,73,139-147`），即 `TSPath.xmpSidecarPath`（`RepositorySupport.swift:180-183`，扩展名固定小写 `.xmp`），且 `preview` 用该值 `createOrGet`（`WritebackService.swift:684,697,727`）。
- 证据链：xmp_path `/shoot/IMG_1.xmp`；盘上 sidecar `/shoot/IMG_1.XMP`；写入/备份走 `resolveSidecarPath` → backup_path `/shoot/IMG_1.XMP.gather-backup-<uuid>`；`validate` 的 expectedPrefix 是 `IMG_1.xmp.gather-backup-` → 不匹配 → `.unexpectedName`。
- 支持"大写 sidecar 是受支持布局"的证据：`SidecarXMPProviderTests.swift:216-233` 专门测试"大写 .XMP sidecar：读写落在实际存在的文件上，不另建小写 sidecar"。
- 影响：cleanup 在 `DeliveryFilePhase.verify` 返回 `.invalidBackup`（`DeliveryFilePhase.swift:144-153`），intent 被标终态（`DeliveryCleanupFlow.swift:285-305`），交付行永久停在 synced、sidecar 不被恢复、备份文件永久残留；finalize 同样保留行+备份并报 `XMP_FINALIZE_BACKUP_PATH_INVALID`（`:606-626`）；replay 同样拒绝（`DeliveryReplayFlow.swift:232-251`）。数据方向安全（不会误删/误覆盖），但这是主清理路径的功能性回归，且用户无法自愈（每次 finalize 还会新建并终结一个 intent）。
- 触发面：macOS 默认大小写不敏感卷上，任何历史大写 `.XMP`（Capture One 常见）或 sidecar stem 大小写与照片 stem 不一致的目录；同类风险还包括 Unicode NFC/NFD 不一致。Linux 大小写敏感卷上，provider 只按"实际存在"匹配，xmp_path 仍是小写串，校验同样失败。
- 未验证：没有真实大写 `.XMP` 目录的 end-to-end 用例；`DeliveryBackupPathTests.swift` 只测全小写 `IMG_1.xmp`。标注"代码已确认 / 触发面需实机目录确认"。
- 建议：比较改为文件系统等价判定（大小写+规范化不敏感），或在写入时把 provider 的真实 sidecar 路径作为 xmp_path 落库；补"大写扩展名/NFD"回归；对历史行提供一次性 `backup_path` 归一化或"同 inode"校验的迁移路径。

### P2

#### P2-1（已确认）replay claim 是 per-call，不是"进程内"——台账口径不成立

- `DeliveryReplayFlow.swift:22-37,47,59`；`DeliveryCoordinator.swift:344-351,531-533`。每次 `replay()` 新建 flow → 新 `DeliveryReplayClaims()`；单次 replay 内 intent.id 唯一，claim 恒真；`XMP_CLEANUP_REPLAY_CLAIMED` 实际不可达。
- 影响：并发 replay 重复处理同一 intent，产生 `XMP_CLEANUP_ADVANCE_FAILED` 等假失败、计数漂移；无数据破坏（fileLock + DB CAS 兜底）。
- 建议：claim 提到 Coordinator/AppRuntime 单例（或按 connection 注入），或 intent 表加跨进程租约；补并发用例。

#### P2-2（已确认，威胁模型内）宿主的孤儿 restore/remove 入口完全没接 backup_path 校验，且注释与实现不符

- `LiveMetadataAPI.swift:247`（keep/删行后 `xmp.removeFile(row.backupPath)`）、`:264`（restore 时 `xmp.restore(photoPath: row.photoPath, backupPath: row.backupPath)`）、`:268`（无备份时 `xmp.removeFile(row.xmpPath)`）都直接走 `XMPProvider`；`gather-app/Sources` 全树 0 处 `DeliveryBackupPath` 引用；`DeliveryTypes.swift:34-35` 注释声称该入口"直接走这里"（指 `XMPDeliveryFilePort`），与实现矛盾。
- 影响：P2-12 威胁模型（DB 被手工篡改/迁移残留一条恶意路径）在 `metadata.resolve_orphan` 上仍然成立：伪造一条无 `delivery_sessions` 关联的 deliveries 行（`orphanDeliveries` 不筛状态，`DeliveryRepo.swift:1126-1135`），用户在确认弹窗后选 keep 即删任意可写文件、选 restore 即把任意可读文件拷进 `row.photoPath` 推导的 sidecar。孤儿行不需要 item/link 图，构造成本比 cleanup 更低。
- 建议：该入口改用 `XMPDeliveryFilePort`（或显式调用 `DeliveryBackupPath.validate`），并修正注释；`row.xmpPath` 的裸 `removeFile` 也要有受控目录/扩展名断言。

#### P2-3（已确认，威胁模型内）Delivery 文件阶段的两个未锚定路径：无备份删 `xmp_path`、restore 目标来自 `photo_path`

- `DeliveryFilePhase.swift:210-213`：`backupPath == ""` 时直接 `removeFile(xmpPath)`，不经校验；同威胁模型下 `xmp_path` 可指向任意文件（需伪造 synced + 全 confirmed 的 link/item 图，成本高于孤儿）。
- `DeliveryFilePhase.swift:220-225`：backup 以 `xmpPath` 校验，但 `XMPDeliveryFilePort.restore` 的目标由 `photoPath` 推导（`DeliveryTypes.swift:36-39`），只校验了 backup 与 xmpPath 同目录，没有断言 `xmpPath == TSPath.xmpSidecarPath(photoPath)`；恶意 `photo_path` 可把"合法备份"恢复到另一个 `*.xmp`。
- 建议：文件阶段统一断言 `xmpPath == TSPath.xmpSidecarPath(photoPath)`，且无备份分支的删除目标必须匹配 `.xmp` 扩展名/受控目录。

#### P2-4（已确认，窄窗口）reload-ack 失效与 markWritten 不同事务，confirm 可在 ack 被清前确认新内容

- `WritebackService.swift:981-999`（markWritten 事务提交后）才调用 `clearReloadAck`（`:576-597`，逐 session UPDATE 各自事务）；`DeliveryRepo.confirm` 的 reload-ack 读在同一事务内（`:1451-1458`），但读的是"尚未被清"的旧 ack。
- 顺序：markWritten 提交 → （窗口）confirm 读 ack=非空、看到 written → 写 confirmed_at / 翻 synced → clearReloadAck 才把 ack 置 NULL。结果：Capture One 未重载也被确认。单连接 `DBConnection` 的语句锁让窗口只有几条语句宽，但真实存在（UI 确认与写回可并发）。
- 建议：把 `clearReloadAck` 放进 markWritten 的同一事务（Repo 层），或 confirm 额外校验 `updated_at` 之后的 ack 时间戳。

#### P2-5（已确认）trace 之外的 4 处日志仍打印绝对路径；`~`/相对路径不在脱敏范围

- `WritebackService.swift:594-595`（clear reload-ack 失败打印 `xmpPath`）、`:720-723`（preview 读关键词失败打印 `sidecarPath`）、`:1376-1378`（投影失败打印 `xmpPath`）、`DeliveryTypes.swift:265-271`（baseline 读取失败打印 `xmpPath`）。这些不是 `DeliveryTrace`，不经过 `redactAbsolutePaths`。
- `DeliveryTrace.redactAbsolutePaths` 只识别以 `/` 起始且前导字符为空白/引号/括号/等号/冒号/逗号的片段（`DeliveryCoordinator.swift:176-189`）；`~/Pictures/x.xmp` 与相对路径不会被替换；`pathToken` 保留 basename（文件名仍进日志，设计如此）。
- 建议：上述 4 处改走 `DeliveryTrace.log` 或 `pathToken`；脱敏补 `~` 前缀。

#### P2-6（已确认）临时文件 sweep：文档-实现漂移 + 锁外删除 + 窄 TOCTOU

- 文件头声明 cleanup/finalize 成功后也清一次（`DeliveryTemporaryFiles.swift:8-9`），实际唯一调用点在 replay（`DeliveryReplayFlow.swift:78-82`）。
- sweep 不在 `XMPFileLock` 内，与同一路径的写盘/恢复并发；24h 阈值让"正在进行的写盘"基本安全，但阈值可注入（传 0 时会误删同目录正在写的临时文件）。
- `attributesOfItem` 与 `removeItem` 之间若路径被换成目录，`removeItem` 会递归删除（极窄，需本机攻击者）。
- 建议：补 cleanup/finalize 成功路径调用（如注释承诺）；sweep 放进 `fileLock.run` 或显式要求调用方持锁；删除前再 `lstat` 一次类型。

#### P2-7（已确认，竞态）item 级写入没有租约/修订守卫，mirror 可能在租约被接管后改写新基线的 item

- `DeliveryMirrorWriter.swift:76-84` claim 后 `:90-107` 逐项 `upsertItem(pending→目标态)`、`:146` `linkSession` 都无租约/修订条件；只有 `markWritten/markFailed` 有 owner CAS（`:116-145`）。租约在 item 写期间被抢占/新输入 `mergeInput`（revision+1、清 lease）后，mirror 仍会把旧一轮结果写进新 revision 的 item，随后 mark 失败只留下错误。
- `DeliveryStateWriter.upsertItem/markItem`（`:230-258`）是模块内公开写路径，无 revision 参数；Host 已不直调（见 1.2），但模块内任何调用方都可能违反。
- 影响：新输入与镜像并发时 item 状态可能短暂超前（display/confirm 门禁受影响），文件内容不受影响；概率低（需跨进程抢占或同进程新输入恰好插入）。
- 建议：upsertItem 加 `expectedRevision/leaseOwner`，或 mirror 在每批 item 写前 renew 并在 CAS 失配时回滚本轮 item 写。

#### P2-8（已确认，API 陷阱）markFailed/markConflict 的 leaseOwner 默认空串

- `DeliveryStateWriter.swift:134-163`、`DeliveryRepo.swift:1063-1099`。持租约的调用方漏传 owner 时不会编译失败，而是 CAS（`lease_owner=''`）失败返回 nil，且 `leaseAwareTransition` 对空 owner 不抛 `leaseLost`，错误被降级为普通 `CAS_FAILED`。
- 带租约的 7 处调用都传了 owner（mirror 2、writeback 收敛/归位 4、acceptExternalState 1）；cleanup/replay 的 3 处 markConflict 故意传空。建议把参数改为必填或提供 `markFailedWithoutLease` 的显式命名。

#### P2-9（已确认）新增错误码没有 UI/调用方映射；finalize 的 `.incompleteItems`/invalidBackup 是"永久卡死 + 每次重试新建 intent"

- 新码：`XMP_CLEANUP_BACKUP_PATH_INVALID`、`XMP_FINALIZE_BACKUP_PATH_INVALID`、`XMP_FINALIZE_INCOMPLETE_ITEMS`、`XMP_CLEANUP_REPLAY_CLAIMED`。grep `gather-app/Sources` 无这些字符串；UI 只会显示 summary.errors 原文或通用失败。
- `applyFinalize` 的 `.incompleteItems`（`DeliveryDBPhase.swift:243-251`）把 intent 标终态、行保留；下次 finalize 仍会把它当候选（synced + 全 confirmed），再 prepare 一个新 intent、再失败。同理 invalidBackup。功能上"安全但不可收敛"，建议在 candidate 查询里排除"已知不可收敛"的行，或给用户一个显式"放弃备份/强制删行"的出口。

#### P2-10（已确认，低）迁移提交后 `assertReady` 失败无法回滚

- `Database.swift:235-243`：`SchemaMigrator.migrate` 提交后才 `assertReady`；若断言失败（版本/FK 开关/shape 漂移），异常抛出但 user_version 已是 2，下次 open 会按 2 判 `.corrupt`（fail-closed），备份虽在但需要人工恢复。事务内已做同样的 shape/FK 校验（`SchemaMigrator.swift:48-64`），触发概率极低。
- 建议：把 `assertReady` 的检查并入迁移事务，或失败时显式回退 user_version。

#### P2-11（疑似，低）370 指纹对索引 DDL 文本敏感

- canonical 含 `sqlite_master.sql` 原文（`SchemaShape.swift:152-159`），`HistoricalV1Shape.fingerprint` 是对"由当前 SchemaV1 DDL 删三列"生成的形态钉死的（测试 `SchemaMigrationTests.swift:101-115,271-275` 也用同一构造）。真实历史库若索引 SQL 有等价但文本不同的写法（旧迁移重建索引、空白差异），会判 `.corrupt` 而不是补列。
- 静态无法证伪"历史 370 库的索引文本一定与当前 DDL 一致"；按"已知旧形"的保守设计可接受，但发布说明应给出"corrupt 后的恢复路径（备份/重置）"。

## 3. 与台账/验收报告的偏差

1. `architecture-remediation-status.md` §3.3 写"replay claim 仅进程内"——实际 per-call（P2-1），进程内跨调用也不成立。
2. 台账把"历史非受控 backup_path 会 fail-closed"列为已知残余，但没写**大小写/规范化**这一最常见的触发面；它会让默认 `dual` 模式下大写 `.XMP` 的交付全部无法 cleanup/finalize（P1-1），不只是"历史脏数据"。
3. `final-acceptance-data.md` §10.2 的 P2-12 威胁模型只覆盖 `backup_path`；本次复核补两条同类缺口：宿主孤儿入口未接校验（P2-2）、restore 目标来自 `photo_path` 与无备份分支裸删 `xmp_path`（P2-3）。
4. `DeliveryTemporaryFiles` 文件头承诺的"cleanup/finalize 后再清一次"未实现（P2-6），与 P2-15 的收口描述不完全一致。
5. `DeliveryTypes.swift:34-35` 的注释声称 LiveMetadataAPI 走文件端口校验——实现并非如此（P2-2），属于"注释即台账"的失真点。

## 4. 未执行 / 限制

- 未运行 build/test/门禁/sqlite3（任务书禁令）；测试结论均为源码静态核对，不声称通过。
- 未在真实大写 `.XMP` / 大小写敏感卷 / NFD 目录上实跑（P1-1 的触发面因此标"代码已确认、环境待实机"）。
- 未做并发/故障注入实跑（replay 并发、租约抢占、断电窗口均为静态推理）。
- 未验证 UI 对 4 个新错误码的展示；未做 GUI 验收。
- 旧提交对比仅用于确认错误码集合与 P1-1 顺序（`git show 4bbfa8d^:<path>`），未改动工作区。
