# 门禁基线目录（docs/baselines/）

本目录是 **ratchet 门禁的机器输入**，不是人类可读文档。每个 JSON 是某一类不变量的冻结快照：门禁比较「当前实测值」与「基线值」，**只允许收紧（--write-baseline），扩张必须 --allow-growth 并记账**。

| 文件 | 读取者 | 内容 |
| --- | --- | --- |
| `structure-baseline.json` | G0–G5（`scripts/check-structural-gates.py` 共享实现） | `gates.lock-order`（XMP→DB 锁序）/ `gates.import-graph`（依赖边/import SCC）/ `gates.module-size`（每 target 文件/LOC/max-file）/ `gates.concurrency-whitelist`（@unchecked Sendable 白名单）/ `gates.layer-symbols`（Application 越界符号例外）/ `gates.public-surface-app`（app public 面 + API requirement 行） |
| `surface-baseline.json` | `scripts/check-protocol-surface.sh` | `gates.protocol-surface`（GatherProtocol 公开面总量）+ `gates.protocol-surface-modules`（5 模块公开面） |
| `cleanup-baseline.json` | `scripts/check-cleanup-ratchet.sh` | 9 个清理指标（try?/try!/as!/fatalError/unchecked Sendable/nonisolated unsafe/services_prepare/todo_fixme/withKnownIssue） |
| `perf-baseline.json` | `scripts/check-perf-ratchet.sh` | 9 个性能反模式构造点（DateFormatter/JSON coder/正则/字节格式化/阻塞睡眠） |
| `design-system-baseline.json` | `scripts/check-design-system.sh` | 8 个 design token 指标（字号/间距/空态/容器/主题别名） |
| `port-row-surface-baseline.json` | `scripts/check-port-row-surface.sh` | G6 指标 + 44 条端口准入台账（file/name/methods/has_fake/has_effective_fake） |
| `test-catalog-baseline.json` | `scripts/check-test-catalog.sh` | 测试目录 ratchet：@Test / @Suite / 断言声明数 + skip 站点数（删测试必须 `--write-baseline` 显式下调） |

## 约定

- 统一 `schema = 2`（design-system 是扁平 token 表，无 schema 字段）；不写 `generated_at`（减少重钉 diff 噪声）。
- 合并文件内每个 gate 一个 section；`--write-baseline` 只原子更新自己 section，其他 gate 数据保持不变。
- 不要手工编辑 JSON：用对应门禁的 `--write-baseline`（默认拒涨）→ 如需扩张加 `--allow-growth`，并在 `docs/cleanup-backlog.md` 记账。
- 删除/合并基线时同步更新 `docs/DEVELOPMENT.md` 的「门禁基线布局」表与 `scripts/report-baseline.sh`。
