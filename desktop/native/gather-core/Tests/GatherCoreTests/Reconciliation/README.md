# 对账测试框架（Phase 1 任务 1.5；Cut 5 后现状）

## 对账模式

同一 fixture 输入双跑（历史 TS 参照 ↔ Swift 测试）：

1. **fixture 由参照实现产出并入库**：`scripts/reconciliation/` 下的生成器（纯 Node，
   无第三方依赖）用固定种子（确定性伪随机）生成输入与参照实现的期望输出，写入本目录
   `Fixtures/` 并提交进仓库。Electron/TS 源码删除后，仅
   `generate-vector-fixtures.mjs` 保留（Cut 5 / 5d-1 重建为只产 LSH）；dHash / 聚类 /
   matcher 的 fixture 作为**冻结的 TS 参照**保留，生成器已随旧栈删除。
2. **生成器 `--check`**（仍存在的 vector 生成器）：重算并与入库 fixture 逐字节比对，
   漂移即退出 1。
3. **Swift 测试**：加载同一 JSON，逐 case 以 Swift 移植实现重算并与期望值比对。

两条路径（生成器重算 ↔ Swift 测试）验证的是同一份入库 fixture；没有生成器的 fixture
只由 Swift 侧复算，漂移由测试断言暴露。

## 当前覆盖

### dHash（`DHashReconciliationTests.swift`）

- fixture：`Fixtures/dhash-fixtures.json`（seed=42，50 cases）
- 输入：9x8 灰度像素网格（72 个 0-255 值）；输出：16 位小写 hex
- 边界覆盖：全零网格、全一网格、重复行、首/中/末边界值、相邻等值（严格 `left < right` 不置位）、随机网格
- 移植对照（历史）：TS `desktop/src/main/services/similarity/hash-computer.ts` 第 14-27 行
  ↔ Swift `desktop/native/gather-core/Sources/GatherAnalysis/Similarity/Hash.swift`
- 范围说明：sharp resize/grayscale 属解码层，Phase 2.1 在 Swift 侧以 CoreImage 实现，不在本对账范围

### 向量索引 LSH（`VectorIndexReconciliationTests.swift`）—— 随全量运行

- fixture：`Fixtures/vector-fixtures.json`（seed 固定，1000 行 × 100 查询；只含 `lsh` 段）
- 覆盖：LSH 邻域召回 ≥ TS 参照（弱桶另设 > 0.4 门限）、空索引、配置校验、
  `LSH_MIN_POINTS` 常量
- 移植对照：TS `face-kw/lsh-index.ts` ↔ Swift
  `desktop/native/gather-core/Sources/GatherAnalysis/Face/VectorIndex.swift`
- **HNSW 为历史实现，已删除**（CL-06；Cut 5 / 5b-2a 删 `CosineHnswIndex`/`HnswConfig`/
  `HnswHits`，5d-1 删 fixture 的 `hnsw` 段与生成器里的 HNSW 参照）。本套件不再覆盖
  HNSW，也不声称仓库当前使用 HNSW；历史决策见 `docs/ADR.md` 的 ADR-011（superseded，
  不再约束实现）。
- **默认运行**：LSH 对账是毫秒级，`GATHER_RECONCILIATION_VECTOR` 门控已随 5b-2a 取消；
  matcher 的实例级 LSH 路径另由 `MatcherReconciliationTests` 覆盖。

## 如何扩展新函数

1. 在 `scripts/reconciliation/` 新增生成器（仿照 `generate-vector-fixtures.mjs`：固定种子、
   参照循环逐字等价并注释来源行号、确定性输出）；纯 Swift 算法也可先在测试里直接构造
   golden 期望，不强制引入生成器。
2. 生成并提交 fixture 到 `Fixtures/<name>-fixtures.json`。
3. Swift 侧移植实现（`desktop/native/gather-core/Sources/GatherAnalysis/...`），文件头注释
   写明参照来源。
4. 在 `Harness.swift` 增加对应 fixture 结构（`Decodable`），新增
   `<Name>ReconciliationTests.swift`：加载 fixture 逐 case 比对 + 手工边界 case。
5. 在 `docs/test-audit.md` 的测试目录/套件清单登记新套件。
