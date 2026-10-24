# 对账测试框架（Phase 1 任务 1.5；Cut 5 后现状）

## 对账模式

同一 fixture 输入双跑（历史 TS 参照 ↔ Swift 测试）：

1. **fixture 是冻结的 TS 参照**：dHash / 聚类 / matcher 的 JSON 输入与期望输出入库；
   Electron/TS 源码和生成器已随旧栈删除。
2. **Swift 测试**：加载同一 JSON，逐 case 以 Swift 移植实现重算并与期望值比对；
   漂移由测试断言暴露。
3. **质量/召回不再由默认套件承担**：近似算法召回、聚类 F1/ARI 由
   `gather-core-benchmarks --quality/--smoke` 在夜间输出；默认套件只保留配置校验、
   空索引、自召回与 exact golden。

## 当前覆盖

### dHash（`DHashReconciliationTests.swift`）

- fixture：`Fixtures/dhash-fixtures.json`（seed=42，50 cases）
- 输入：9x8 灰度像素网格（72 个 0-255 值）；输出：16 位小写 hex
- 边界覆盖：全零网格、全一网格、重复行、首/中/末边界值、相邻等值（严格 `left < right` 不置位）、随机网格
- 移植对照（历史）：TS `desktop/src/main/services/similarity/hash-computer.ts` 第 14-27 行
  ↔ Swift `desktop/native/gather-core/Sources/GatherAnalysis/Similarity/Hash.swift`
- 范围说明：sharp resize/grayscale 属解码层，Phase 2.1 在 Swift 侧以 CoreImage 实现，不在本对账范围

### 向量索引 LSH（`VectorIndexReconciliationTests.swift`）—— 随全量运行

- 覆盖：空索引、配置校验、`LSH_MIN_POINTS` 常量、小索引自召回（索引接线）。
- 质量基线：1000×100 的召回统计已从默认套件删除；`gather-core-benchmarks --smoke`
  输出 `exactRecallAt085`，夜间对比基线。
- **HNSW 为历史实现，已删除**（CL-06）；历史决策见 `docs/ADR.md` 的 ADR-011
  （superseded，不再约束实现）。
- matcher 的实例级 LSH 路径另由 `MatcherReconciliationTests` 的 exact fixture 覆盖。

## 如何扩展新函数

1. 优先在测试里直接构造 **golden 期望**（固定种子、确定性输出、逐 case 比对）；
   若需要冻结外部参照，再把 fixture 提交到 `Fixtures/<name>-fixtures.json`。
2. Swift 侧实现（`desktop/native/gather-core/Sources/GatherAnalysis/...`），文件头注释
   写明参照来源。
3. 在 `Harness.swift` 增加对应 fixture 结构（`Decodable`），新增
   `<Name>ReconciliationTests.swift`：加载 fixture 逐 case 比对 + 手工边界 case。
4. 在 `docs/test-audit.md` 的测试目录/套件清单登记新套件。
