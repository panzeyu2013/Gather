# Review 修复执行报告（P0/P1 全量）

- 日期：2026-10-22
- 输入：docs/reviews 下 8 路评审 + post-refactor-review-summary.md
- 范围：P0 全部、P1 全部可执行项、影响交付的 P2；不改产品功能范围。

## 1. 修复结果

| 项 | 状态 | 主要落点 |
| --- | --- | --- |
| P0-1 Delivery 文件阶段旧备份覆盖新 XMP | 已修 | DeliveryCoordinator 三入口 verify+base_fingerprint；LiveMetadataAPI orphan restore 同锁；XMPFileLock 串行 cleanup/finalize/replay/writeback |
| P0-2 CI/测试可执行与确定性 | 已修（Q 复跑中） | ci.yml/README/DEVELOPMENT 统一 --no-parallel；AsyncWait ContinuousClock+10s；4+2 flake 隔离；默认并行 10 次目标 |
| P1-9 metadata 手动队列无执行器 | 已修 | WritebackService.executePending；MetadataService flush；AppComposition 注入；setMetadata/batchSet 立即写盘 |
| P1-10 acceptExternalState 绕过跨会话确认 | 已修 | 只到 written；DeliveryRepo.resetConfirmations 全会话失效 |
| P1-8 模块 cleanup 删其他模块 item | 已修 | cleanupItemGate：非 synced skip；foreign synced 只删本模块 |
| P1-1 mergeInput 只清当前会话确认 | 已修 | 同一事务重置该 delivery 全部 delivery_sessions.confirmed_at |
| P1-2 writing 租约无恢复 | 已修 | claimWriting/renewWriting + 300s TTL + 稳定 owner + 崩溃归位 |
| P1-3 metadata enqueue 跨 3 事务 | 已修 | DeliveryRepo.applyMetadataMutation 单事务（open+item+link） |
| P1-5 user_version=1 不校验列形 | 已修 | SchemaV1 shape fingerprint/列数/索引/FK；不符走 incompatible 重置 |
| P1-7 Indexer DELETE photos 撞 FK | 已修 | 同事务先删 person_photos |
| session.create 目录分支无 job/回滚 | 已修 | LiveSessionAPI 对称入队+回滚；Dashboard 去重复 |
| JobAPI index.scan 规则复制 | 已修 | JobCreateParams.metadataScan 工厂，4+ 调用点统一 |
| 15 个 API 方法无 Live 行为测试 | 已修 | 新增 15 条（Culling 10/Face 3/Session 1/Similarity 1） |
| workspace 全量扇出/隐藏页轮询 | 已修 | 两级可见性：会话级 + setPageVisible；7 页钩子 |
| endSession 零调用/幽灵会话 | 已修 | Dashboard onSessionDeleted + RootView 注入 SessionStore.endSession |
| Gallery 构造即取页 | 已修 | activateIfNeeded；构造零副作用；首可见一次 |
| RequestGate/ViewState 死代码 | 已修 | 删除 4 文件/12 测试；CL-04 deferred 入账；2026-10-22 收尾移除 dup 脚本的 RequestGate 规则 |
| 设置页动态中文/Notice parity/复数 | 部分 | FaceModelPathIssue 固定 key；L10n.plural 7 模板；parity 增 Notice/plural/三元；剩余 76 模板列 CL |
| skip 假绿/test catalog | 已修 | 识别 .enabled(if:)/Suite(.disabled)；CI --strict；FaceRealPhoto 加 owner/到期 |
| entitlements/SFace 断言 | 已修 | Gather.entitlements + build.sh 精确断言/签名后校验/lproj 非空 |
| 子代理/文档交付口径 | 已修（收尾） | ratchet baseline 53/240/127；docs 最终指标已更新（en 1,322 / 测试文件 166 / 非 archive 死链 0）；git 混合态仍待 staging |

## 2. 当前验证（本轮实测）

- core：**1128 tests / 159 suites**，exit 0；3 条真实照片 skip（有效 1125）。
- app：**616 tests / 68 suites**（串行/并行以 Q 最终为准）。
- schema：43 表 / user_version=1 / FK 违规 0。
- ratchet：**53 / 240 / 127 / 0 / 0**（baseline 已更新，因 Indexer 必要新增 prepare +1）。
- 门禁：docs/test-catalog/no-legacy/layering/duplicate/select-star/preview 全 strict 通过；cleanup-ratchet 通过。
- 收尾复核（2026-10-22，docs/scripts/构建产物）：`check-docs --strict` OK（当前文档 md 链接 0 缺失；reviews 14 篇）；`check-test-catalog --strict` OK（**166** 文件、skip 3）；`check-cleanup-ratchet` **53/235/127/0/0**（baseline try? 240）；`check-duplicate-symbols --strict` OK（535 文件，RequestGate 规则已移除）；en 表 **1,322** / zh 9。**未复跑全量测试**（本轮无源码改动）；测试例数沿用 1,128/159 + 616/68 的最近记录。

## 3. 残余（明确不冒充完成）

1. **GUI smoke 未做**：逐页中英/写回/delivery replay 需人工；无 GUI 自动化。
2. **build.sh 本机未完整执行**：DSH sandbox 拒绝 SwiftPM manifest；release 构建、bundle 组装/资源解析、entitlements dry-run 已验证，CI 负责最终 bundle。
3. **10k 人脸精确聚类 19.25s**：未达 5s，接受 ≤20s 基线；vDSP/simd 或降 LSH 门为后续优化。
4. **l10n 剩余 76 个复数模板**：已列 CL，未全量迁移。
5. **外部编辑器/C1 并发**：XMPFileLock 仅进程内；外部写盘不与 Gather 串行，靠 revision/fingerprint 事后检测。
6. **markWritten/markFailed 不校验 owner**：被抢占的慢写者仍可能收敛；per-xmp DB 互斥未做。
7. **AppServices 未显式注入 fileLock**：LiveMetadataAPI 缺省 .shared，与组合根同实例；建议后续显式传。
8. **死代码/文档小项（2026-10-22 收尾后）**：仍余 Dashboard `deleteSessionSilently`、CL-04 私有代次、markWritten owner、pin 零调用。已关闭：`JobScopeCheckpoint` 是单一来源键枚举且被 LiveSessionAPI/Dashboard 与测试引用（不是死代码，从清单移除）；`Support/LoadPhase.swift:9/18` 注释经 16:48 复核已无 `ViewState`（并行工作区已修，非本轮）；当前文档死链已修（13→0；归档 33 条旧源码链接按快照保留）；dup 脚本 RequestGate 规则已移除。
9. **git**：未 commit；工作区 staged/unstaged/untracked 混合，需在最终验收时统一 staging/快照。

## 4. 结论

P0 与 P1 的产品/数据路径已闭环；剩余为人工 GUI、CI 打包、性能与少量 P2/CL。最终发布前仍需 Phase 0 的 GUI/CI 实测确认。
