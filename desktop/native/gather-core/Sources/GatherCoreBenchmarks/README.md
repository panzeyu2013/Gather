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
.build/release/gather-core-benchmarks --quality  # 合成聚类质量（P/R/F1/ARI/noise）
.build/release/gather-core-benchmarks --margin   # margin 扫描（生产判定）
.build/release/gather-core-benchmarks --face-10k # 10k 合成人脸（显式档）
```

默认单测只保留 correctness；`--quality`/`--margin`/`--smoke` 的质量指标改为手动
执行并自行保存 NDJSON（原夜间 workflow 已于 2026-10-29 移除）。

## 覆盖项与口径

| phase | 负载 | 口径 |
|---|---|---|
| `dhash-cluster` | ClusterGraphPipeline.run（threshold=8, minGroupSize=3, global；原 ClusterEngine 已随 5b-2a 删除） | 确定性 50 簇数据（seed 0xD4A5），期望 50 簇、0 噪声 |
| `embedding-cluster` | FaceClusterer.clusterEmbeddings（eps=0.9, minPts=5, LSH 路径 minPoints=1000） | 确定性 50 正交簇 × 128 维（seed 0xB1E2，扰动按维度缩放 0.005），期望 50 簇 |
| `lsh` | CosineLshIndex（bits=16/tables=2/probeRadius=1, unitVectors=true）+ 100 查询（索引内行） | selfRecall + 抽样 exactRecall（threshold=0.85；200 个小簇 + 0.45 噪声，保证有真实近邻且召回有区分度） |
| `face-quality` | FaceClusterer.clusterEmbeddings（eps=0.8, minPts=2, floor=0/0.5） | 6 身份 × 60 样本、24 维；输出 pairwise P/R/F1、ARI、TP/FP/FN、noise 率、簇数 |
| `margin-sweep` | FaceIdentityPolicy.decide（生产判定） | 固定 near-tie 分数，跑 0 / gap 边界 / 0.01 / 更大 margin 的 accepted/ambiguous 曲线 |

数据全部固定种子确定性生成（不落盘、不入库）；质量基线不再依赖已删除的
`vector-fixtures.json`。

## 2026-08-09 基线（x86_64 Linux，Swift 6.1.2 release）

| phase | 2 万 | 5 万 |
|---|---|---|
| dhash-cluster | 1.1 s（50 簇） | 18.5 s（50 簇） |
| embedding-cluster | 1.5 s（50 簇） | 8.8 s（50 簇） |
| lsh build + 100 queries | 0.17 s（selfRecall=1.0） | 0.41 s（selfRecall=1.0） |

已知事项：聚类两档（dhash/embedding）相对 TS 侧（V8 JIT）偏慢，但结果对账
（cluster-fixtures / pipeline golden 逐例一致）不受影响，可作后续性能优化点。
HNSW 基准（原 2 万 28.8 s / 5 万 87.4 s）已随实现删除，不再维护对照基线。
