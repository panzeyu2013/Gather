# gather-core-benchmarks（Similarity 基准）

计划 2.3 验收「Similarity 基准 2 万/5 万」的 Swift 原生基准。
本基准覆盖算法层四类负载，
产出 NDJSON 指标行（对齐基准脚本的 stdout JSON 行风格）。

## 用法

```sh
cd desktop/native/gather-core
swift build -c release            # 必须 release（debug 慢 ~10 倍）
.build/release/gather-core-benchmarks            # 2 万/5 万两档全量
.build/release/gather-core-benchmarks --smoke    # 2 千档快速验证
```

## 覆盖项与口径

| phase | 负载 | 口径 |
|---|---|---|
| `dhash-cluster` | ClusterEngine.clusterByHash（threshold=8, minGroupSize=3, global） | 确定性 50 簇数据（seed 0xD4A5），期望 50 簇、0 噪声 |
| `embedding-cluster` | FaceClusterer.clusterEmbeddings（eps=0.9, minPts=5, LSH 路径 minPoints=1000） | 确定性 50 正交簇 × 128 维（seed 0xB1E2，扰动按维度缩放 0.005），期望 50 簇 |
| `hnsw` | CosineHnswIndex 建索引（dim=128, M=16, efConstruction=32）+ 100 查询 topK=10 | recall@1 对照暴力扫描（≥0.99 门） |
| `lsh` | CosineLshIndex（bits=16/tables=6/probeRadius=2, unitVectors=true）+ 100 查询（索引内行） | 自召回（threshold=0.85 下查到自身） |

数据全部固定种子确定性生成（不落盘、不入库），与对账 fixture 同一 mulberry32。

## 2026-08-09 基线（x86_64 Linux，Swift 6.1.2 release）

| phase | 2 万 | 5 万 |
|---|---|---|
| dhash-cluster | 1.1 s（50 簇） | 18.5 s（50 簇） |
| embedding-cluster | 1.5 s（50 簇） | 8.8 s（50 簇） |
| hnsw build + 100 queries | 28.8 s（recall@1=1.0） | 87.4 s（recall@1=0.99） |
| lsh build + 100 queries | 0.17 s（selfRecall=1.0） | 0.41 s（selfRecall=1.0） |

已知事项：HNSW 插入为逐层 searchLayerFrom + 多样剪枝，5 万行 build ~87 s；
相对 TS 侧（V8 JIT）偏慢，但结果对账（VectorIndex topK 逐位一致）不受影响，
可作后续性能优化点。
