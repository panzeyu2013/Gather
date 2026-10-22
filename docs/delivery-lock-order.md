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
