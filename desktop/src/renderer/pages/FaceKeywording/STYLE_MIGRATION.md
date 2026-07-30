# FaceKeywording 样式约定

人脸分析、聚类审核和关键词写回均已迁移到独立的 CSS Module，并使用全局设计令牌。

后续修改应遵循：

- 结构、颜色、间距和控件状态放在对应的 `.module.css` 中。
- 使用 `global.css` 中的 `--color-*`、`--radius-*` 和 `--shadow-*` 令牌。
- 仅允许进度、位置和尺寸等运行时计算值保留为内联样式。
- 新增按钮和表单控件时保留清晰的 hover、disabled 与 focus-visible 状态。
