# DesignSystem

GatherUI 的视觉契约层。目标是让页面**声明角色**，而不是每页自己拼 font / color / background / chrome。

## 分层

```
Tokens/       颜色、字体、间距、圆角、阴影、chrome 尺寸
Components/   Card / Section / Badge / Banner / EmptyState / Toast…
Patterns/     GatherPage（全局页骨架）等页面级配方
Modifiers/    gatherSurface / gatherText 等语义修饰符
```

## 规则

- Tokens 不 import 任何 Feature 类型；Components 不放业务逻辑；Patterns 不依赖 SessionStore / VM。
- 页面不再直接写 `.font(.callout)`、`Color(hex:)`、手写 `.shadow`、`.background(.regularMaterial)`。
- 内容层不使用 Liquid Glass；Liquid Glass 只用于 toast / 浮层 / 功能按钮（见 `GatherGlass`）。
- 卡片用 `gatherCard`；页面背景用 `gatherSurface`；空态用 `GatherEmptyState`。
- `GatherMetrics` / `GatherTheme` 的旧别名仍可用，但新代码使用语义名（canvas / surface / accent / selection）。
- 新增共享视觉代码放这里，不要继续往 `Support/` 加主题/组件。

## 迁移状态

- 第一里程碑：主题/共享叶子已迁入本目录；Dashboard / Library / Persons / Settings 使用 `gatherPage`。
- 后续：会话页 scaffold（chrome 槽位）与路由/命令层在 `Interaction/`，不在本目录。
