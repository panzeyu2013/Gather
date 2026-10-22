# 深审（D1–D8）修复与验收台账 · 2026-09-30

> 来源：第三轮深审报告（基准 df86849d）。**审查员的 7 个 Core 探针 + 1 个 App 探针
> 已原样收入仓库作为验收测试**，修复前失败、现在全部通过。

| # | 级别 | 问题 | 修复 | 验收（探针实际输出） |
| --- | --- | --- | --- | --- |
| **D1** | P1 | 边车写入失败后删除了原本已有的导出照片 | 引入 `FileInstallToken`：覆盖前留底（照片 + 边车），提交才丢弃备份；失败**回滚**（本次新建则删除半成品）。完成检查点只在整套提交后写入 | `failedSidecar: failed=1,priorPhotoExists=true` ✅（修复前 `priorPhotoExists=false`） |
| **D2** | P1 | 孤儿恢复使用等待前的旧快照，可能删掉原有 XMP | `waitForIdle` 后**重取孤儿行**并校验仍是孤儿；恢复用最新 `backupPath`；删除带 revision CAS | `orphanRestore: originalSidecarExists=true,backupLeft=false` ✅（修复前 `false/true`） |
| **D3** | P1 | 清理跨 await 后无条件删行，吞掉新修改 | 整个清理阶段以**起始 revision** 为 CAS 条件（读指纹前、删行前各校验一次），仓库新增 `deleteIfRevision` | `cleanup: deleted=0,newRevision=Optional(2),backupExists=true` ✅（修复前 `deleted=1,newRevision=nil`） |
| **D4** | P2 | 取消防抖任务反而立即启动写回 | 睡眠取消即 `return`（不再用 `try?` 吞错继续）；新增**计时器代数**守卫，只有当前计时器能消费排程；预排程任务加停止/取消检查 | `debounce: writesBeforeDeadline=0,status=pending` ✅（修复前 `writesBeforeDeadline=1,status=written`） |
| **D5** | P2 | `waitForIdle` 的 timeout 不约束活跃任务等待 | 改为轮询「是否仍在写」+ deadline 独立结束等待（**不再 await writer**） | `waitForIdle: timeoutMs=20,elapsedMs=200,returnedTimeout=true` ✅（修复前 `returnedTimeout=false`） |
| **D6** | P2 | 重开后旧语句重新通过检查、绑定旧连接 | 连接**代数**：open/close 自增，`DBStatement` 记录创建代数，`requireOpenConnection` 校验代数一致 | `reopen: newConnectionRowCount=0` + 旧语句抛 `DBError` ✅ |
| **D7** | P2 | 模型安装逐个替换，第二个失败留下混合版本 | 先把旧文件移出到同目录备份 → 依次放入新文件 → 任一步失败**整体回滚**（全旧或全新） | `modelInstall: failed=true,first=old-model,second=old-model` ✅（修复前 `first=new-model`） |
| **D8** | P2 | 非有限值已过滤，超大有限值仍通过校验 | ① `validateFaceClusteringParameters` 增加业务上界（`minClusterSize ≤ 1_000_000`）；② 防抖毫秒先夹到 `maxWriteDebounceMs`（1h）再做纳秒乘法 | `finiteParameter: minPts=1e30,isFinite=true` + 校验抛错 ✅ |

## 验证

- gather-core：**986 tests / 140 suites**（+7 深审探针；唯一失败为沙箱禁止写 home 的环境性用例）。
- gather-app：**298 tests / 32 suites 全绿**（+1 模型安装探针）。
- 门禁：`check-command-surface`（C 与 C.UTF-8）/ `check-no-legacy` 通过。

## 未完成 / 未验证（诚实边界）

- **D3 的数据-文件一致性**：CAS 保证新 revision 不被删除；但「恢复已把文件写回旧内容、随后新 revision 才落库」这一瞬间（探针钩子制造的顺序）仍由协调器下一轮 drain 纠正（新 revision 是 pending 会被重新写入）。真正需要的是「恢复与合并同一路径排他」的租约——报告也指出 `deleteByRevision` 不足以覆盖；本轮实现了 CAS + 重排程，**未实现跨阶段排他租约**。
- **D5 超时后的并发保护**：超时只结束等待者；调用方（恢复/清理）在超时后不得与仍在写的 writer 并发做破坏性操作——本轮靠 CAS 兜住删除侧，但「超时期间禁止恢复」的显式门未加。
- **D2 的「等待期间重新关联会话」分支**：用「重取孤儿列表」判定，未单独构造重新关联的验收用例（探针只覆盖备份路径刷新）。
- **D7 的崩溃恢复**：回滚覆盖了「第二个提交失败」；「提交中途断电」需要版本化目录 + 活动指针，未实现（报告建议的方案 2）。
- **D6 的文件库替换/迁移恢复场景**：代数校验对所有连接通用，但未用文件库替换路径单独验收。
- **D8 的其它入口**：只处理了人脸参数与防抖延迟；分页游标/counterStart 等其它极大有限值未逐一审计。
- 真实 Capture One、GUI/无障碍矩阵、真实 RAW/万级库、断电注入、签名公证、Intel/macOS 14/26：本轮仍未覆盖。
