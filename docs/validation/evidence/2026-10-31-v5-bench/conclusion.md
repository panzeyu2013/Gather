# V5 算法层基准（2026-10-31）

- 机器：arm64、48 GB、macOS 27.0.1；Xcode 27.2 / Swift 6.4.2。
- 二进制：release，universal（arm64 slice 运行）。
- 命令：`gather-core-benchmarks --smoke` 与默认 20k/50k；`/usr/bin/time -l` 取峰值 RSS。
- 2k 冒烟：0.60 s，19.4 MB，PASS。
- 20k/50k 全量：12.79 s，164 MB，PASS。

| phase | 20k | 50k |
|---|---|---|
| dhash-cluster（50 簇） | 179 ms | 5,738 ms |
| embedding-cluster（50 簇） | 992 ms | 5,443 ms |
| lsh build + 100 queries | 42 ms | 107 ms |

LSH：selfRecall@0.85 = 1.0000（两档）；exactRecall@0.85 = 0.699（20k）/ 0.589（50k，抽样 5 对）。

## 口径与限制

- 这是**算法层**（相似度/聚类/LSH）基准，不是 App 端 10k/100k 的 facet、语义索引、watcher、
  缩略图、2k 输出、内嵌写回与峰值内存；后者仍需合成库与 App 级 harness。
- exactRecall 是抽样估计，不是全量 ground truth；selfRecall=1.0 只证明索引能找回自身。
- README 的 2026-08-09 基线是 x86_64 Linux，本机是 arm64 macOS，不可直接相减；本文件作为本机基线。
