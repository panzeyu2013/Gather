# V1 崩溃/回滚预演（2026-10-31）

命令：`swift test --filter EmbeddedRewriteSessionTests`，12/12 通过。

覆盖：

- 校验阶段失败 → 原文件字节不变、临时文件删除；
- 替换前失败（`beforeInstall`）→ 原文件一字节不变、临时文件删除；
- 头部备份与 restore 可用；
- 多 APP13 资源合并不丢非 0x0404；
- 会话不可重入（commit 后再次 commit/备份显式失败）；
- 12MB 一次写回读放大 ≤2.1×、scan SHA 不变；
- 端到端 WritebackService 快路径。

## 限制

- 这是 **hook 注入**级失败，不是进程 `kill -9`；真正的进程级崩溃注入、磁盘满、只读卷仍未跑。
- 未经过 App 导入/DB/交付队列；真实 RAW+JPEG 与 Bridge/C1 复核仍属 V1/V2。

结论：V1 的“失败不动机器原片”在单元/会话层有行为证据；完整 V1 仍需真实素材与进程级注入。
