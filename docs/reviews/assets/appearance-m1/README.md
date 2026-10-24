# 外观第一里程碑截图（2026-10-24）

- 来源：`appearance` 工作树，debug 构建（GatherUI 资源 bundle 从 SwiftPM Debug 产物替换进 release 壳）
- 运行：隔离数据目录 `/tmp/gather-m1-data`，窗口 1180×780，macOS 27，Retina 2×
- 截图工具：`screencapture -l <windowID>`
- 页面入口：仅 DEBUG 的 `--ui-page library|persons|settings` / `--ui-appearance dark|light`
- 数据：空库（无工作区/无人物/无照片），因此看到的是各页空态，不是有数据布局

| 文件 | 页面 | 外观 |
| --- | --- | --- |
| `dashboard-light.png` | 工作台（首运行） | 浅色 |
| `dashboard-dark.png` | 工作台（首运行） | 深色 |
| `library-light.png` | 全局图库（空库 + 检查器） | 浅色 |
| `library-dark.png` | 全局图库（空库 + 检查器） | 深色 |
| `persons-light.png` | 人脸库（空库） | 浅色 |
| `settings-light.png` | 设置 | 浅色 |
| `settings-dark.png` | 设置 | 深色 |
| `contact.png` | 上述截图拼接 | — |

## 本轮已核验

- 四个全局页的标题/副标题/背景由 `gatherPage` 统一提供，页面不再各自重复。
- 空态由 `GatherEmptyState` 渲染，浅/深色下文字与图标可读。
- 设置窗口的 inactive 玻璃鬼影修复仍在（`SettingsWindowSurface` 保持最外层）。
- 深色下 canvas/surface 分层可见；侧栏、工具栏、检查器没有断缝。

## 未覆盖（不要当成已验收）

- 860×560 最小窗口截图（由 `LayoutBudgetTests` 覆盖最小宽度，但未做本矩阵截图）。
- 英文界面截图（由 `LocalizationParityTests`/语言测试覆盖文案，未做本矩阵截图）。
- 高对比度截图。
- 有数据状态（有工作区/照片/人物）的布局——本矩阵只验证空态与页面骨架。
