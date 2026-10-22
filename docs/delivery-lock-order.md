# Delivery 锁序契约（XMP → DB 单向）

> 适用：`GatherDelivery`（cleanup / finalize / replay / writeback）与 `XMPFileLock`。
> 结论：**XMP → DB 允许；DB → XMP 禁止。** 当前无反向后路径，无死锁。

## 1. 允许的锁序

```text
XMPFileLock.run(path:) {
    DeliveryRepo.get(...)          // 锁内读交付快照（verify / verifyAfterMutation）
    DeliveryStateWriter.markItem() // writeback 失败落库（WritebackService）
}
```

理由：文件阶段的 verify 必须与文件读写处于同一次取锁内，否则「验证通过 → 另一写者
落盘 → 旧备份覆盖」的 TOCTOU 窗口重新打开（P0-1）。

## 2. 禁止的锁序

```text
DBConnection.transaction {
    await XMPFileLock.shared.run(path:) { ... }   // 编译不过：transaction body 是同步闭包
}
```

也不允许用 `Task` / `Task.detached` 在事务闭包内绕到 XMP 锁：那会让「持 DB 连接锁
的线程」等待「持 XMP 锁的线程」，而后者又可能读 DB，形成环。

静态审计：

```bash
# transaction 闭包内不应出现 fileLock.run / 文件端口
rg -n 'transaction.*\{|fileLock\.run' desktop/native/gather-core/Sources/GatherDelivery
```

## 3. 当前实现位置

- `DeliveryFilePhase.verify / verifyAfterMutation`：锁内只 `DeliveryRepo.get`（读）。
- `DeliveryDBPhase.applyCleanup / applyFinalize`：`connection.transaction` 内只做 DB
  （item 门禁、删除、intent.finish），不碰文件端口 / XMPFileLock。
- `WritebackService.writeGroupItems`：锁内 backup/read/writeAttributes；失败落库
  `markItem` 也发生在锁内（允许方向）。
- `DeliveryFilePhase.removeFinalizeBackup`：锁内先读行归属、校验备份路径、再 remove。

## 4. 残余风险

- XMPFileLock 是**进程内**锁；外部编辑器（Capture One）与第二个 Gather 进程不受约束。
- 锁内 DB 读会等待单连接全局锁：长 DB 事务会放大文件锁持有时间（P2-5 残余），
  但不会反向取 XMP 锁，因此不构成死锁。
- 若未来把某个 `DeliveryRepo` 方法改成 async 并在内部取 XMP 锁，本契约失效；
  该改动必须先拆掉本文件第 1 节的锁内读，改由调用方在锁外预读。

## 5. replay claim 与临时文件 sweep（与文件阶段共享窗口，但不是锁序）

### 5.1 replay claim

- claim 是 **coordinator 级进程内内存状态**（`DeliveryReplayClaims`，NSLock），由
  `DeliveryCoordinator` 持有并注入每次 `makeReplayFlow()`；不是 per-call，也不是
  跨进程租约。claim 窗口覆盖同一条 intent 的文件阶段 + DB 阶段（`defer release`）。
- 并发 replay 同一 intent 时，失败方 `claims.claim(id)` 返回 false，记
  `skippedCount += 1` 并报 `XMP_CLEANUP_REPLAY_CLAIMED: #<intentId>`；它不进入
  file/db，因此不会产生 `XMP_CLEANUP_ADVANCE_FAILED` / rowNotFound 假失败。
- 测试：`DeliveryCoordinatorTests.concurrentReplaySameIntentClaimsOnceAndSkipsWithoutAdvanceFailure`
  （本任务只静态写入，未运行；第一路在文件阶段用 ReplayRaceGate 挂起，第二路在
  claim 处跳过，释放后第一路正常闭环）。
- 跨进程：仍无 DB 租约。第二个 Gather 进程可与本进程并发回放同一 intent；当前只靠
  `XMPFileLock`（进程内）与 SQLite 写锁/CAS 兜底，不承诺跨进程互斥。

### 5.2 临时文件 sweep

- 唯一调用点是 `DeliveryReplayFlow.replay()` 开头，按 backlog 的 xmpPath 逐路径扫；
  **不在** `XMPFileLock` 内，也不读 DB（`DeliveryTemporaryFiles.sweep` 只做
  FileManager 同目录枚举 + 删除），因此不构成「DB → XMP」反向锁序。
- 只删同目录、`<basename>.tmp-` / `.restore-` 前缀、非 symlink、常规文件且
  mtime ≥24h 的条目；不碰 `.gather-backup-*`。24h 阈值是它与同路径进行中写盘
  之间的唯一保护，测试注入 0 阈值不得用于生产。
- 文档-实现漂移：`DeliveryTemporaryFiles` 文件头曾承诺 cleanup/finalize 成功后
  再清一次，当前实现只有 replay 一个调用点；本文件以实现为准。
