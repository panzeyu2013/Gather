# 会话页 Phase 2-4 截图（2026-10-24）

- 来源：`appearance` 工作树，debug 构建；GatherUI 资源 bundle 替换进 release 壳
- 运行：隔离 DB `/tmp/gather-m1-data`；主矩阵 1180×780，另有一张 860×560；macOS 27，Retina 2×
- 数据：直接向隔离 DB 插入一个空工作区 `qa1`（name=QA Session，photo_count=0），
  用于打开会话页；**不是**真实照片/分组/任务数据
- 页面入口：DEBUG-only `--ui-session qa1 --ui-page control|gallery|culling|similarity|export|duplicates|face-kw`
- 截图：`screencapture -l <windowID>`

> 2026-10-24 P2 复核：7 页工具栏已统一到 `GatherSessionToolbar`；Culling 空态已改为
> 撑满居中，下面的 light/dark 图均为修复后重拍。

| 文件 | 页面 | 外观 |
| --- | --- | --- |
| `control-light.png` | 控制中心 | 浅色 |
| `gallery-light.png` | 浏览/图库 + 检查器 | 浅色 |
| `culling-light.png` | 挑片（空范围） | 浅色 |
| `culling-dark.png` | 挑片（空范围） | 深色 |
| `similarity-light.png` | 相似度 | 浅色 |
| `export-light.png` | 导出 | 浅色 |
| `duplicates-light.png` | 重复 | 浅色 |
| `face-light.png` | 人脸 | 浅色 |
| `culling-860.png` | 挑片（空范围，最小窗口） | 浅色 860×560 |
| `culling-high-contrast.png` | 挑片（高对比外观） | 高对比 |
| `contact.png` | 上述 7 页浅色 + 深色拼接 | — |
| `english-library.png` | 全局图库（英文，检查器 4 张共享卡） | 浅色 |
| `data-gallery.png` | 图库（隔离库导入 4 张样例照片） | 浅色 |

## 已核验

- 7 段页签行固定在内容区顶部；返回按钮在页签行内。
- 7 页都使用同一个 `GatherSessionToolbar`（C1 + 刷新 + 可选设置/页内动作）；
  Control/Face 改为 `@Bindable` VM 后不再触发 toolbar 的 closure-copy 崩溃。
- Culling 空态在 light/dark 下都居中，页签行仍贴顶。
- 深色挑片页表面/文字/页签可读。
- 860×560 最小窗口展开检查器不再触发 N01 约束循环：页签行在窄窗退化为
  `Menu`（GeometryReader 门控），检查器 ideal 220 计入 680 内容预算。

## Phase 4 补充（2026-10-24）

- 英文截图：`--ui-language` 改为 **scene 发布后**由 RootView 调
  `languageStore.set(rawLanguage:)`，不再卡 loading；`english-library.png`
  为英文图库实拍。
- 有数据截图：`data-gallery.png` 来自隔离库导入 4 张样例 JPEG（页签/工具栏/
  网格/文件名均为真实数据）。
- 仍只截了 Culling 一页高对比；未做 7 页高对比矩阵。

## 未覆盖

- 有分组、有任务（索引/导出/人脸分析运行中）的真实布局。
- 交互级 QA（点击页签/返回/工具栏）——鼠标/辅助功能自动化在本机不可用；
  路由语义由单测覆盖，未做人工点击全流程。
