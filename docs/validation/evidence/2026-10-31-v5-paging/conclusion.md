# V5 排序分页 20k/100k 预演（2026-10-31）

- 工具：`CullingPagingPerfTests`（20k，仓库内、默认 skip）与 `scripts/validation/CullingPaging100kPerfTests.swift`（100k，运行时临时复制）。
- 环境：arm64、48 GB、macOS 27.0.1；Debug 测试构建（比 release 更保守）。
- 20k（GATHER_CULLING_PERF=1）：capture 48.0 ms / rating 36.7 ms / triage 36.3 ms（p95），预算 300 ms，PASS。
- 100k：capture 252.2 ms / rating 195.3 ms / triage 192.3 ms（p95），预算 1,000 ms，PASS；插入+测量 8.34 s。
- 口径：SQL 读路径（`CullingAssetPageQuery.pageSorted`，200/页，10 页），不含 UI/缩略图/facet 聚合/写回。

## 限制

- 不是 App 端 facet p95，也不覆盖 100k 索引、watcher、语义检索、2k 输出、峰值内存。
- Debug 构建的绝对耗时不能与 release 承诺直接对比；结论是“100k 分页读路径在当前实现下未爆预算”。
