# 重构后全量 Review 汇总（8 路独立评审）

- 日期：2026-10-22
- 对象：工作区未提交的 Cut 0–6 重构（HEAD `82603e0`）
- 评审方式：8 个只读 subagent 并行；源码/测试/Package/脚本未改，仅各自写一份报告。
- 修复状态：P0/P1 已按本报告执行修复，见 [review-remediation-report.md](../review-remediation-report.md)；本文件保留当时发现，不随修复改写。
- 分报告：
  - [R1 API 语义](post-refactor-r1-api.md)
  - [R2 持久化/Delivery](post-refactor-r2-persistence.md)
  - [R3 模块/构建/打包](post-refactor-r3-build.md)
  - [R4 UI 状态/生命周期](post-refactor-r4-ui.md)
  - [R5 本地化](post-refactor-r5-l10n.md)
  - [R6 算法/性能](post-refactor-r6-algorithms.md)
  - [R7 测试/门禁](post-refactor-r7-tests.md)
  - [R8 清理/文档/交付](post-refactor-r8-cleanup.md)

## 0. 总体结论

架构目标基本达成：7 target、0 字符串命令、SchemaV1（43 表/373 列/69 索引/62 FK）、179 错误码、页面/VM `l()`=0、14 Preview、core 1092/157、app 581/66（串行）、8 门禁全绿（ratchet 53/236/126/0/0）。

但“可交付/可发布”结论**不成立**，原因不是架构方向，而是 2 个 P0 + 一组 P1：

1. **数据完整性 P0**：Delivery cleanup/replay 的文件阶段在 DB revision/CAS 之前执行，旧备份可覆盖新写入的 XMP，且无备份时会直接删除新 sidecar。
2. **交付门禁 P0**：CI 的 app 测试未加 `--no-parallel`，本机默认并行 6/6 次失败；串行也观察到 Gallery shutdown 断言间歇失败。CI 的 bundle 步骤根本不会执行。
3. P1 集中在：跨会话确认绕过、writing 租约不恢复、手动队列非原子、旧 V1 库缺列不重置、Indexer 删除撞 RESTRICT；`session.create` 目录分支缺 job/回滚、15 个 API 方法无 Live 行为测试、`index.scan` 语义被复制到 UI；Workspace 全量扇出导致隐藏页轮询、`endSession` 零调用导致幽灵会话、Gallery 构造即取页；3 条真实照片测试永久 skip 却被计入 1092；英文复数/设置页动态中文/Notice parity 漏扫；无 entitlements 的 C1 签名、mlpackage 名未断言；git 155 staged/392 unstaged/386 untracked 的混合态。

## 1. P0（必须先修）

### P0-1 Delivery 文件阶段无 revision/指纹守卫，旧备份可覆盖新内容

- 证据：`DeliveryCoordinator.swift:566-658`（cleanup 先 await 文件阶段 636，653 才 DB CAS）；`1012-1051`（replay prepared 直接重做文件）；`1106-1123`（restore 覆盖、无备份删除 sidecar）；`309-348`（intent payload 无 base_fingerprint）；`DeliveryRepo.swift:925-965`（revision 守卫只在 DB 段）。
- 触发：cleanup/replay 文件阶段期间新输入 `mergeInput` revision+1/status=pending；restore 仍用旧备份覆盖；DB 随后 revisionChanged 只标错误，文件已旧；intent 可能 applied 后被清。**第二入口**：`LiveMetadataAPI` orphan restore（209-228）也是先 restore 后 revision 守卫（R2 补充）。
- 影响：用户新写入的 XMP 被旧备份回滚或删除，且无提示；属于数据丢失。
- 修复：intent 增加 base_fingerprint/base_values；文件阶段前重读 delivery 并复核 revision/status/fingerprint；不一致则 conflict/skip，不碰文件；无备份删除同样复核；补“文件阶段注入新输入”的确定性测试。

### P0-2 CI app 测试不可执行（并行必红；串行仍有时序 flake）

- 证据：`.github/workflows/ci.yml:87` 无 `--no-parallel`；本机默认并行 **R7 6/6 失败、R8 2/2 失败，但 R2 本轮 581/66 通过**，即非确定 flake 而非稳定必红。失败点 `DuplicatesControlCenterAPITests.swift:384`、`CullingViewModelAPITests.swift:573`、`SettingsSaveSemanticsTests.swift:96-100`、`FaceReclusterConfirmTests.swift:46-59`；R8 另见固定 `CullingViewModelAPITests.swift:421-423`（applyHistory 后 `Task.detached` refresh 用 stub 旧 history 覆盖本地 undone 标记）。**串行也不稳定**：R7 3/3 绿，但 R4 串行 1 次在 `GalleryViewModelTests.swift:896` 失败，R1 5 次 4 绿 1 红（`DuplicatesControlCenterAPITests.swift:384`）。**581/66 不能作为稳定基线**；`AsyncWait.swift:28` 2s 墙钟 + 多处 `_ = await waitUntilAsync` 丢弃结果。R7 补充：4 个失败用例用 `--filter` 一起并行跑 4/4 通过（0.413s），只有整包 581 条默认并行才失败——根因是主线程/调度饥饿耗尽 2s，不是用例间共享状态。
- 影响：CI app job 在 bundle 前失败，`build.sh` 不执行；“581/66 全绿”只在串行且非确定条件下成立。
- 修复：CI/README/DEVELOPMENT 统一加 `--no-parallel`（止血）；同时修测试确定性：等待返回 Bool 必须断言、轮询用可控时钟/tick、shutdown/在途请求取消、跨套件全局语言/通知隔离；再补 app 序列至少 10 次稳定。

## 2. P1（按领域，去重后）

### 2.1 持久化/Delivery
- **P1-9（功能阻断）metadata 手动队列在产线没有执行器**：`MetadataService.setMetadata` 只 enqueue `delivery_items(module=.metadata, pending)`（`MetadataService.swift:539-545`、`MetadataMutationService.swift:149-167`），但 `execute` 调用点只有 culling/face/similarity；**keywords 无旁路，rating/label 可能被 culling 顺带写**；delivery 停 pending 还会阻断其它模块 confirm；测试是手工 execute 才写盘。
- **P1-10 冲突“全部接受远程”绕过跨会话确认**：`LiveMetadataAPI.acceptExternalState:338-362` conflict→writing→written→markSynced，不看 `delivery_sessions.confirmed_at`；随后 `DeliveryRepo.confirm` 的 itemsSynced 子查询（1044-1051）把其他会话已 synced 的 written items 一起翻 synced，cleanup 可删未确认内容。
- **P1-8 模块级 cleanup 删文件级交付**：其他模块 pending/failed item 被静默删；cleanup 不删备份、relink 不迁 delivery_intents（P2-9/10）。
- mergeInput 只重置当前会话 confirmed_at，跨会话门禁可绕过（`DeliveryRepo.swift:433-444`、`850-854`）。
- writing 租约 owner 恒空、无租约恢复；崩溃在 markItem/markWritten 之间永久 writing（`DeliveryRepo.swift:292-310`、`WritebackService.swift:318-341`、`AppComposition.swift:162-165`）。
- MetadataMutationService.enqueue 跨 3 事务；mergeItem 失败后 revision/ pending 已推进但无 item（`MetadataMutationService.swift:134-175`）。
- `user_version=1` 不校验列形：Cut 5 加 3 列未 bump；旧 370 列 V1 库运行期 no such column（`SchemaV1.swift:6-7`、`Database.swift:313-324`）。
- `IndexerService.swift:282-287` 直接 DELETE photos，撞 `person_photos` RESTRICT。
- mirror/execute 多步 DB 部分失败只记 errors 不回滚（`DeliveryCoordinator.swift:861-930`）。

### 2.2 API 完整性
- `session.create` 目录分支只建会话，无 metadata.scan job/回滚；仅 Dashboard 在 UI 层补（`LiveSessionAPI.swift:102-127`）。
- “110 行为覆盖”不成立：15 个方法无 Live 行为测试（Culling 10、Face 3、Session.addPhotos、Similarity.cancelAnalysis）。
- `JobAPI.start` 不封装 index.scan 的 dedupeKey/checkpoint，规则复制在 3 处 UI（`JobInputs.swift:14-15` 等）。

### 2.3 UI 生命周期
- `SessionWorkspace.setVisible(true)` 对 7 VM 全量扇出：进入任意会话即启动 gallery/control/similarity 轮询，隐藏页持续跑（`SessionWorkspace.swift:78-89`、`RootShellWorkspace.swift:127`）。
- `SessionStore.endSession` 全仓 0 调用；Dashboard 删除只 refresh，workspace 不 close，sidebar 回退到已删会话（`SessionStore.swift:97`）。
- workspace 构造即触发 Gallery 首屏取页（`GalleryViewModel.swift:355-357`）。
- `ViewState`/`RequestGate` 零生产调用点；CL-04 未完成却被计为门禁通过（`RequestGate.swift:2`）。
- 多处 `.confirmationDialog` 堆同节点：Face 8、Similarity 4、Settings 2，与 `DuplicatesView.swift:122-124` 的项目自定约束冲突（R4 P1-5，疑似，无 GUI 未目视）。

### 2.4 测试/门禁
- 3 条真实照片人脸用例 `.enabled(if: GATHER_FACE_FIXTURE)` 永久 skip，但 1092 把 3 条算作通过；catalog 只识别 `.disabled`。
- 无测试数量/覆盖率 ratchet；CI test-catalog 仍 warning 模式（`ci.yml:46`）。
- 门禁名宽于规则：layering 只匹配行首 import、select-star 漏多星号、docs 不查 md 链接、duplicate 只查 3 符号。

### 2.5 本地化
- 设置页人脸模型路径校验生成中文动态句，英文界面回退中文（`SettingsViewModel+Fields.swift:74-82`）。
- 无 `.stringsdict`，76 个计数模板只有复数形式（`1 photos`）。
- parity 漏扫 CullingNotice/FaceNotice/SimilarityNotice 与三元分支（`LocalizationParityTests.swift:107/120-145`）。

### 2.6 打包/交付
- `build.sh:127` codesign runtime 但全仓无 `.entitlements`，C1 Apple Events 签名分发后会被 TCC 拒绝（-1743）。
- `build.sh:77-81` 只断言任意 `*.mlpackage`，运行期写死 `SFace`（`EmbeddingModel.swift:554`）。
- git 155 staged / 392 unstaged / 386 untracked；常规 `git commit` 会丢 GatherUI/GatherHost 主体与归档。
- `Sources/.build` 379MB 构建产物；final-report 只写“未提交”，未给提交口径。

### 2.7 算法
- 增量 `IncrementalClusterer.swift:245-246` 按 `minGroupSize` 二次过滤，丢掉全量会保留的合法小组，违反“增量划分与全量相同”的不变量（R6 P1-1；反例 0x31/0x07/0x2a/0x1c/0x12/0x2b、threshold=3、min=4）。**收口建议**：删过滤对齐全量（首选）；若产品要最小簇，必须两条路径同时过滤并更新 golden，二选一不能分叉。**更正**：此前“增量无视 rejected”不成立——任意 rejected 会让该会话退回全量（`FaceKwService.swift:1592-1605`），真实副作用是此后每次 analyze 都全量重建（R6 P2-13，pre-existing）。
- 10k release 精确 DBSCAN 19.25s，未达 ≤5s；根因是 LSH 门 20k + 标量点积（已接受 ≤20s 基线，但仍是性能项）。

## 2.8 补充 P2（R8 交付/清理）

- CL 状态漂移：CL-04/07/17 真未收（CL-07 两个 `load(for:)` 仍在 `PhotoThumbnailView.swift:222/415`），CL-08/09/10 已完成却仍 pending；final-report 残余只列 CL-18/19/20。
- 删键数口径冲突：R5 为 HEAD 1,406/1,395 unique → 当前 1,313，**删 94 / 增 12**；R8 按 git 差集为 **删 105 / 增 12 / 净 −93**；1,407 基线无法从 HEAD 复现，需逐键复核。
- `face-clustering-benchmark.md` 有 13 条旧 GatherCore 死链；归档另有 34 条代码路径死链。
- `RouterCommandError` 生产零构造，仍在 4 处错误漏斗 `as?` 分支；源码 2 处仍写“177 码”。
- `docs/README.md:64`、`ROADMAP.md:200` 仍称“无需模型资产”，实际 bundled SFace 38MB 且 build.sh 硬依赖；`release/` 有旧 22MB bundle。
- `refactor-decisions` 有重复 D-081/D-162/D-163；cleanup-baseline 的 services_prepare scope 仍写 GatherCore。
- 两份测试建库入口 `makeTestDB`/`makeGatherTestDB`（app 19 处），与“唯一入口”注释不符。
- CI 缺 `gather-schema verify`；仍保留已删除的 `GATHER_RECONCILIATION_VECTOR`；test-catalog 未加 `--strict`。
- 导出备份/回滚失败路径 `try?` 静默（`ExportService.swift:447-480`）；DB 重置多文件 move 非原子（`Database.swift:411-428`）、prune 会删同前缀手工备份（:459-480）；文件扫描跟随符号链接（`IndexerService.swift:623-637`）——均标疑似/低概率。

## 3. 正面确认（可复算）

- 535 文件 / 133,740 行；7 target 无环；UI 只 import Protocol；clean scratch debug/release 均 exit 0；strict import flag 负向对照有效。
- 按 build.sh 步骤在 /tmp 组装 Gather.app 成功：双 bundle、FaceModels/SFace.mlpackage、en/zh-Hans.lproj、Info.plist 齐全；plutil OK；otool 仅系统框架；运行期 Bundle 解析 SFace 与 zh-Hans 命中（R3）。
- Schema 43/373/69/62、user_version=1、FK 52 CASCADE+7 SET NULL+3 RESTRICT；无 SQL 注入/列名漂移。
- core 1092/157、app 581/66（仅串行且非稳定，见 P0-2）；8 门禁 strict 口径基本通过；ratchet 53/236/126/0/0。
- l10n：en 1313/zh 9；179 错误码全覆；格式占位符逐条匹配。**删键数口径不一致**：R5 实测删 94 / 增 12（1,395−94+12=1,313），R8 按 git 差集得删 105 / 增 12 / 净 −93；需逐键 diff 复核后再写死。
- 算法：ClusterGraph golden/200 随机/32769 streaming 全过；FaceMatcher 批量与逐条逐位一致；A/B/C 锁外聚类并发读 0.019ms。

## 4. 建议修复顺序

| 阶段 | 内容 | 预估 |
| --- | --- | --- |
| 0 立即 | P0-1 文件阶段 revision/fingerprint 守卫 + 回归；P0-2 CI `--no-parallel` + 4 个 flake 用例确定性化 | 1.5–2 天 |
| 1 数据完整性 | mergeInput 全会话重置、writing 租约、enqueue 单事务、user_version 列形校验、Indexer 删除顺序、mirror 失败面 | 2–3 天 |
| 2 API 完整性 | session.create 目录分支 job/回滚；JobAPI.startIndexScan；补 15 个 Live 测试 | 2 天 |
| 3 UI 生命周期 | 按当前页 setVisible、endSession 接线、Gallery 懒加载、删除/接线 ViewState/RequestGate | 2 天 |
| 4 测试/本地化 | skip 真计数、测试 ratchet、catalog strict；设置页动态 key、stringsdict 复数、Notice parity | 2–3 天 |
| 5 交付 | entitlements、SFace 断言、git add -A/快照、删除 Sources/.build、CI schema verify | 1 天 |

总计约 **10–13 人日**；阶段 0 完成前不建议宣布可发布。

## 5. 建议的验收命令

```bash
# core / app
swift test --package-path desktop/native/gather-core --disable-sandbox \
  --cache-path .build/shared-cache --scratch-path .build/scratch \
  --explicit-target-dependency-import-check error
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
swift test --package-path desktop/native/gather-app --no-parallel --disable-sandbox \
  --cache-path .build/shared-cache --scratch-path .build/scratch \
  --explicit-target-dependency-import-check error
# 稳定性：app 串行连跑 10 次、并行/串行均 0 issue
# 门禁
for s in check-cleanup-ratchet check-docs:--strict check-test-catalog:--strict \
         check-no-legacy check-layering check-duplicate-symbols:--strict \
         check-select-star:--strict check-preview-surface:--strict; do ...; done
# schema / bundle
swift run --package-path desktop/native/gather-core gather-schema verify
./desktop/native/build.sh   # CI macOS runner
```

## 6. 结论

- 方向正确、主体扎实：模块/类型/持久化/算法的主干值得保留。
- **当前不是“可发布完成”状态**：P0-1 是数据丢失风险，P0-2 使 CI/打包门禁失效；P1 中有 API 副作用缺口、跨会话确认绕过、隐藏页轮询、skip 真计数、entitlements 等。
- 建议按上表 Phase 0→5 修复后，再重跑全量/稳定性/CI，并把 final-report 的“完成”改为“机器验收通过、待 P0/P1 修复”。
