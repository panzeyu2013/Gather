# main 分支（2026-09-28 冻结）设计文档存档

> 来源：`main` @ `8268094e`（"chore(electron): 彻底移除 Electron 时代残留"）。
> 存档时间：2026-10-26，三线合并（refactor + feature + main）时归档。

## 为什么只存档、不合并

`main` 与 `refactor` 在 `740afc1f`（2026-09-23，R0 基线）后走了**两条互斥的重构路线**：

| 维度 | main（278 commits） | refactor（94 commits） |
|---|---|---|
| 结构 | 单体 `GatherCore`（160 swift） | 5 个库 target 拆分（265 swift） |
| 命令面 | `CommandSurface` 19 域 | `GatherProtocol` 16 域 API + `GatherHost/Live*API` |
| 门禁 | `check-no-legacy` 1 个 | 12 个 strict 门禁 |
| 内容 | R4–R8 单体内部重构 + R5 命令层 | WP1–WP7 包拆分 + R1–R9 整改 |

机械合并 main 会产生"引用已删除 `GatherCore` target"的不可编译混合体（实测 124 处冲突、
329 个已删除路径被 rename 映射回填），且其 19 域已由 refactor 的 16 域按域覆盖
（filter→PhotoAPI、workspace.status→SessionAPI、index.scan→JobAPI、template 已删除）。
因此 `main` 仅以 `git merge -s ours` 记录为祖先，**代码不进入统一线**。

## 唯一移植的代码

`normalizeKeywordList` 的数字字符串化（main `2f81fcd8`）：JS `String(item)` 语义
（7 → "7"、-0 → "0"），已移植到 `GatherApplication/Services/MetadataService.swift`
（`keywordString`）并补回归测试。

## 文件说明

- `ARCHITECTURE-AUDIT.md`、`ARCHITECTURE-REWRITE-DESIGN.md`、`ARCHITECTURE-W2B/W2C/W2D/W4/W5-*`：
  main 线的重构方案与验收台账（已被 WP1–WP7 取代）。
- `ARCHITECTURE-REFACTOR-PLAN.md`：含 §29/§30 残余清单与逐轮验收记录。
- `R5-APP-TYPED-MIGRATION.md`：R5 类型化命令面迁移规范（refactor 以 Cut 1 / B 阶段重做）。
