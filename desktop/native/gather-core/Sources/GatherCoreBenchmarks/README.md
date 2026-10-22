# gather-core-benchmarks（Similarity 基准）

计划 2.3 验收「Similarity 基准 2 万/5 万」的 Swift 原生基准。
本基准覆盖算法层三类负载（HNSW 项已于 Cut 5 / 5b-2a 随 CosineHnswIndex 删除），
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
| `dhash-cluster` | ClusterGraphPipeline.run（threshold=8, minGroupSize=3, global；原 ClusterEngine 已随 5b-2a 删除） | 确定性 50 簇数据（seed 0xD4A5），期望 50 簇、0 噪声 |
| `embedding-cluster` | FaceClusterer.clusterEmbeddings（eps=0.9, minPts=5, LSH 路径 minPoints=1000） | 确定性 50 正交簇 × 128 维（seed 0xB1E2，扰动按维度缩放 0.005），期望 50 簇 |
| `lsh` | CosineLshIndex（bits=16/tables=6/probeRadius=2, unitVectors=true）+ 100 查询（索引内行） | 自召回（threshold=0.85 下查到自身） |

数据全部固定种子确定性生成（不落盘、不入库），与对账 fixture 同一 mulberry32。

## 2026-08-09 基线（x86_64 Linux，Swift 6.1.2 release）

| phase | 2 万 | 5 万 |
|---|---|---|
| dhash-cluster | 1.1 s（50 簇） | 18.5 s（50 簇） |
| embedding-cluster | 1.5 s（50 簇） | 8.8 s（50 簇） |
| lsh build + 100 queries | 0.17 s（selfRecall=1.0） | 0.41 s（selfRecall=1.0） |

已知事项：聚类两档（dhash/embedding）相对 TS 侧（V8 JIT）偏慢，但结果对账
（cluster-fixtures / pipeline golden 逐例一致）不受影响，可作后续性能优化点。
HNSW 基准（原 2 万 28.8 s / 5 万 87.4 s）已随实现删除，不再维护对照基线。
