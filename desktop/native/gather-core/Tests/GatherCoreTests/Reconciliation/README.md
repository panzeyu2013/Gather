# 对账测试框架（Phase 1 任务 1.5）

## 对账模式

同一 fixture 输入双跑（TS vitest ↔ Swift 测试）：

1. **fixture 由 TS 侧产出并入库**：`scripts/reconciliation/` 下的生成器（纯 Node，无第三方依赖）
   用固定种子（确定性伪随机）生成输入与 TS 参照实现的期望输出，写入本目录 `Fixtures/` 并提交进仓库。
2. **TS 生成器 `--check`**：重算并与入库 fixture 比对，漂移即退出 1（CI 门禁）。
3. **Swift 测试**：加载同一 JSON，逐 case 以 Swift 移植实现重算并与期望值比对。

两条路径（生成器重算 ↔ Swift 测试）验证的是同一份入库 fixture，任何一侧语义漂移都会在 CI 双跑中暴露。

## 当前覆盖

### dHash（`DHashReconciliationTests.swift`）

- fixture：`Fixtures/dhash-fixtures.json`（seed=42，50 cases）
- 输入：9x8 灰度像素网格（72 个 0-255 值）；输出：16 位小写 hex
- 边界覆盖：全零网格、全一网格、重复行、首/中/末边界值、相邻等值（严格 `left < right` 不置位）、随机网格
- 移植对照：TS `desktop/src/main/services/similarity/hash-computer.ts` 第 14-27 行核心循环
  ↔ Swift `Sources/GatherCore/Similarity/Hash.swift`
- 范围说明：sharp resize/grayscale 属解码层，Phase 2.1 在 Swift 侧以 CoreImage 实现，不在本对账范围

### 向量索引（`VectorIndexReconciliationTests.swift`）—— 单独运行

- fixture：`Fixtures/vector-fixtures.json`（seed 固定，1000 行 × 100 查询）
- 覆盖：HNSW topK 索引/得分逐位一致、各节点层级（PRNG 流）、阈值检索 vs 暴力点积；
  LSH 邻域召回 ≥ TS 参照；空索引/维度/配置校验；`LSH_MIN_POINTS` 常量
- 移植对照：TS `face-kw/hnsw-index.ts`、`lsh-index.ts` ↔ Swift
  `Sources/GatherCore/Face/VectorIndex.swift`
- **默认不随 `swift test` 运行**（全套 ~6s，开发迭代高频跑全量时拖慢节奏），
  用环境变量门控（`@Suite(.enabled(if:))`）：

  ```bash
  # 单独运行（默认 swift test 会跳过本套件）
  GATHER_RECONCILIATION_VECTOR=1 swift test --filter VectorIndexReconciliationTests
  ```

- **门禁**：凡改动 VectorIndex/Clusterer 移植代码或 fixture 生成器
  （`scripts/reconciliation/generate-vector-fixtures.mjs`）必须显式运行本套件；
  与 dHash/聚类/matcher 等毫秒级对账套件随全量跑的策略不同属有意为之。

## 如何扩展新函数

1. 在 `scripts/reconciliation/` 新增生成器（仿照 `generate-hash-fixtures.mjs`：固定种子、
   TS 参照循环逐字等价并注释来源行号、确定性输出）。
2. 生成并提交 fixture 到 `Fixtures/<name>-fixtures.json`。
3. Swift 侧移植实现（`Sources/GatherCore/...`），文件头注释 TS 源。
4. 在 `Harness.swift` 增加对应 fixture 结构（`Decodable`），新增 `<Name>ReconciliationTests.swift`：
   加载 fixture 逐 case 比对 + 手工边界 case。
5. 在 `docs/NATIVE-DEVELOPMENT-ANALYSIS.md` 的 1.5 行登记覆盖函数。
