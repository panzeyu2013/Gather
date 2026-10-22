# 最终收尾与死代码清理报告（2026-10-22）

- 输入：8 路评审修复后的工作树
- 方式：3 个只读/受限 subagent 分域自审 + 清理（core / app / docs-scripts-artifacts），父 agent 最终全量验证。
- 分报告：[final-cleanup-core.md](final-cleanup-core.md)、[final-cleanup-app.md](final-cleanup-app.md)、[final-cleanup-docs.md](final-cleanup-docs.md)。

## 1. 清理结果

### Core（净 −301 行；3 文件 161 行 + 14 符号 138 行）
- 删除整文件：MetadataConflictFields、BoundedString、NonEmpty。
- 删除零引用符号：ScanResult/ProgressData/EngineStatusData/GroupData、FkwCancel/FkwClusters Params、SessionDelete/DeleteMany/Get Params、ExportService.destinationSidecarExists、WritebackService.mutationSource、PersonRepo.getPersonName、GatherError.pendingInvalidParamCode。
- 保留：JobScopeCheckpoint（app 引用）、CaptureOneSyncState（app 端口引用）、ImageDimensions（仅对账测试）、112 个旧 Protocol DTO（契约测试钉住，建议单独 D-001/D-007 收刀）。

### App（净 −239 行；0 删除文件、1 新文件）
- 删除：deleteSessionSilently、SessionStore.pin/pinned 分支、.page(.settings) 死路由、未用 Preview fixture、L10nStringCache.resetStats、DisplayDateFormatters.timeWithSeconds、SimilarityViewModel.noteResultParams、SettingsView.downloadButtonTitle、GalleryView.pendingPhotoIds、GatherGlass 3 个 helper、JSONValue.decoded(as:)、GatherTheme/GatherBadge 零引用别名、4 个死 en 键。
- 收敛：6 份逐字 requireSessionId → GatherHost/APIs/LiveAPIInput.swift（净 −78，错误码/reason 不变）。
- 保留：RouterCommandError/BridgeError/APIError.emptyResponse（错误漏斗+测试）、map/mapAsync（域错误差异）、isClosed/*ForTesting（测试契约）。

### 文档/脚本/产物
- 删除构建产物 **≈2.21 GiB**：release/Gather.app 22MB、.build/scratch-app/scratch-core-p14/scratch-p14/perf-probe、desktop/native/.build/scratch-ci；保留活动 .build 缓存。
- check-duplicate-symbols.sh 删 RequestGate 规则/旧文案；check-docs.sh 新增当前文档 md 链接存在性检查。
- 修复当前文档 13 条旧 GatherCore 死链（face-clustering-benchmark），archive 历史链接按快照保留。
- 更新 CL-04/18/20、final-report、review-remediation、progress/decisions（D-166）。

## 2. 最终验证（本机实测）

| 项 | 结果 |
| --- | --- |
| core | **1,128 tests / 159 suites**，exit 0（3 skip，有效 1,125） |
| app | **616 tests / 68 suites**，串行 exit 0；并行 3/3 exit 0 |
| Schema | 43 表 / 373 列 / 69 索引 / 62 FK / user_version=1；verify exit 0 |
| 门禁 | 8 道 strict 全绿；ratchet **53/235/127/0/0**；catalog self-test 绿 |
| 当前文档链接 | 137 条 / 0 缺失（check-docs --strict） |
| 规模 | 535 Swift 文件 / 138,829 行（含修复轮新增测试；core 145 文件/43,462 行） |

## 3. 残余（不冒充完成）

1. **GUI smoke 未做**；build.sh 本机完整执行受 DSH sandbox 限制，交 CI。
2. **10k 人脸**：release 19.25s，未达 5s；接受 ≤20s 基线。
3. **l10n 剩余 76 个复数模板**（已列 CL）。
4. **112 个旧 Protocol DTO** 生产零外部引用但被契约测试钉住；删除需同批重写约 197 例契约测试。
5. **ImageDimensions + 对账测试** 生产 0 引用，候选删除（约 243 行）。
6. **重复 map/mapAsync、RouterCommandError 漏斗、BridgeError** 保留，合并风险大于收益。
7. **XMPFileLock 仅进程内**；外部编辑器/C1 写盘不互斥；markWritten 未校验 owner。
8. **CL-04 deferred**（4 套私有代次），**CL-18 pending**（try? 235/53 unchecked）。
9. **git 未 commit**：工作区 715+ 项，需统一 staging/快照后由 owner 提交。
10. **archive 33 条历史源码链接**为快照，未逐条修复。

## 4. 结论

死代码与无用逻辑的本轮清理已收口：core/app 共净减约 540 行，删除 3 个孤儿文件、1 个死路由、2 个 379MB/22MB 级构建产物与 2.21GB 旧 scratch；所有删除均有全仓零引用证据。机器验收保持全绿；剩余为人工 GUI/CI、性能、旧 DTO/契约测试与少量 P2/CL。
