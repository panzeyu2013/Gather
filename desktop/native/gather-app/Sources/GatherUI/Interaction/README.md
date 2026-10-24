# Interaction

这一层负责“动作怎么到达”，与 `DesignSystem`（页面长什么样）分开。

## 已落地（Phase 2-3；Phase 4 部分）

- `AppRoute` / `SessionPage`：唯一目的地 + 页面身份；`SessionTab` / `Destination`
  兼容层已删除，测试与控制中心模型也改用 `AppRoute` / `SessionPage`。
- `RootNavigation`：内部以 `route: AppRoute` 为状态；保留现有产品返回语义：
  - 会话页返回 = 先回真实页级来源（图库/相似度/上一个会话），无则离开会话；
  - 图库/相似度返回 = 回进入前页面；
  - 会话内部切页签不改变返回目标；
  - 跨会话跳转记录上一个会话页。
- `\.navigator` environment：页面从 RootView 注入的 `RootNavigation` 取路由，
  不再接收 5–9 个导航闭包。
- `GatherSessionPage`：7 段页签 + 返回 + 背景 + 副标题 + 页面级 setPageVisible。
- `AppCommandCenter`：菜单命令经 handler 执行；RootView 安装 handler，
  `GatherAppCommands` 只调 `perform`。
- `refreshOnDomainEvents` / `handleDomainEvents` / `refreshOnJobTerminal`：
  页面不再手写 domainChanged / jobTerminal 的 guard + debounce。

## 约束

- 不要在 Feature 页面里新增“导航回调参数”；先加到 Navigator 契约。
- 不要在 View 里直接 post 菜单通知；命令必须经 AppCommandCenter。
- 任何返回语义改动先写行为矩阵（工作台→控制→浏览→相似度→返回 等），再改实现。
- 会话页可见性只由 `GatherSessionPage` 调；页面不要重复 onAppear/onDisappear 钩子。
- 新增页面直接进 `SessionPage` / `AppRoute`；不要再引入第二套页面枚举。

## 下一阶段

1. `GatherInspectorSection`（Culling/Gallery 检查器共享；工具栏已收口到 `GatherSessionToolbar`）；
2. AppDelegate 兜底已接 `AppCommandCenter`；下一步把 handler 安装提前，删除命令通知回退；
3. 页内命令的完整 focused scope（Culling undo/redo 已进菜单，但还没有 per-window 上下文）。
