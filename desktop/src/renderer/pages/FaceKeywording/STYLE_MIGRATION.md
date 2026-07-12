# FaceKeywording 内联样式迁移计划

当前问题：StepAnalyze.tsx, StepReview.tsx, StepWriteback.tsx 含 ~89 处内联 style={}。

迁移步骤：
1. 为每个 Step 文件创建对应的 .module.css
2. 颜色值替换为 CSS 变量：var(--color-primary), var(--color-surface) 等
3. 像素值提取为 CSS class
4. 删除组件中的 style={} 属性

CSS 变量参考（见 global.css）：
--color-primary, --color-bg, --color-surface, --color-text, 
--color-text-secondary, --color-border, --color-success, --color-danger
