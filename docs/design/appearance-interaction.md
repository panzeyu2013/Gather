# Gather 设计系统与页面配方（2026-10-24）

> 目标：页面**声明角色**，不自己拼 font / color / background / chrome。
> 背景与完整论证见 [外观与交互宏观架构评审](../reviews/appearance-interaction-architecture-2026-10-24.md)。
> 本文只写**怎么用**，不重复评审。

---

## 1. 分层

```
Sources/GatherUI/
  DesignSystem/
    Tokens/       颜色、字体、间距、圆角、阴影、chrome 尺寸
    Components/   Card / Section / Badge / Banner / EmptyState / Toast
    Patterns/     GatherPage（全局页骨架）
    Modifiers/    gatherSurface / gatherText
  Interaction/    （规划中）路由、命令、事件、生命周期
  Features/       Dashboard / Library / …
  Shell/          RootView / Scene 装配 / Overlay
  Support/        基础设施：L10n、错误、端口、缓存、事件中心
```

**规则**：

- `DesignSystem` 不 import 任何 Feature 类型；`Features` 可以 import `DesignSystem`。
- `Support/` 不再放主题/组件；新增共享视觉代码放 `DesignSystem/`。
- 不新建 SwiftPM target；目录 + `package` 可见性 + ratchet 足够。

---

## 2. Token 角色

### 表面

| Token | 用途 |
| --- | --- |
| `GatherTheme.canvas` | 窗口/页面底色 |
| `GatherTheme.surface` | 卡片、工具条、检查器分区 |
| `GatherTheme.surfaceMuted` | 嵌套面板、同色分区 |
| `GatherTheme.viewerBackground` | 照片查看器（固定暗色，不跟随浅色） |
| `GatherTheme.hairline` | 卡片/面板边界（不用 `separator` 代替） |

页面背景用 `.gatherSurface(.canvas)`（或 `.gatherPage` 自带），不要在页面里手写
`.background(GatherTheme.canvas)` 与 `.background(GatherTheme.windowBackground)` 两套名字。

### 文字

| 角色 | 用途 |
| --- | --- |
| `.hero` | 首屏 hero 标题 |
| `.pageTitle` | 详情/弹层主标题 |
| `.sectionTitle` | 页面分区/卡片分区标题 |
| `.body` / `.bodyStrong` | 正文 |
| `.secondary` / `.secondaryStrong` | 元数据、次级正文 |
| `.label` | 徽标、密集标签 |
| `.mono` | 行内数字（自动等宽） |
| `.stat` | 统计数字（自动等宽） |

用法：

```swift
Text(l10n("最近工作区"))
    .gatherText(.sectionTitle)

Text("12847")
    .gatherText(.stat)
```

`.gatherText` 只用于 `Text` / `Label`，不要套在含按钮/图片的整块容器上。
需要自定义颜色时传 `color:`；默认 `.secondary` 角色已经带次级文字色。

### 间距 / 圆角 / 阴影

- 间距优先 `GatherMetrics.Space`：4/8/12/16/24/32/48；2/6 仅用于紧凑 inline。
- 圆角优先 `GatherTheme.Radius`：6（缩略图）/ 8（小面板）/ 12（卡片）/ 16（tile）/ 24（hero）。
- 阴影用 `gatherCard(elevated:)` 或 `GatherElevation`（规划中）统一，不要手写
  `.shadow(color: .black.opacity(...), radius: ..., y: ...)`。
- 尺寸预算用 `GatherChromeMetrics`：窗口 860×560、侧栏 180/220/260、检查器 220/220/360/400
  （ideal 220 是为了 860 最小窗口下页签行 + 内容 + 检查器不触发约束循环）。

---

## 3. 页面配方

### 全局页

```swift
VStack(spacing: 0) {
    banners
    content
}
.gatherPage(
    title: l10n("全局图库"),
    subtitle: browseSubtitle,
    surface: .canvas
)
.toolbar { toolbarItems }
.searchable(...)
.inspector(...)
```

`.gatherPage` 统一：frame、语义背景、`.navigationTitle`、非空 `.navigationSubtitle`。
页面不再自己写 `.frame(maxWidth:.infinity,maxHeight:.infinity)` / `.background(...)` /
`.navigationTitle(...)`。

### 分区

```swift
GatherSection(l10n("任务中心")) {
    jobsContent
}
```

`GatherSection` = 标题 + `gatherCard` 表面。适合 Dashboard / Library / Persons 的
内容分区；检查器请用后续的 `GatherInspectorSection`（不要用 `Form` 进 `.inspector`，
会触发 AppKit 约束循环）。

### 空态

```swift
GatherEmptyState(
    icon: "photo.on.rectangle.angled",
    title: l10n("图库还没有照片"),
    message: l10n("导入一个文件夹后，这里会汇总所有工作区的照片。")
) {
    Button(l10n("导入文件夹")) { ... }
        .gatherPrimaryActionButton()
}
```

`GatherEmptyState` 是系统 `ContentUnavailableView` 的薄包装：
- 页面级空态用它；
- List Section 行内（会被行高约束）继续用 `ContentUnavailableView`，不要强行塞入；
- 错误态必须保留重试/清除筛选等出口。

### 按钮

- 主 CTA：`.gatherPrimaryActionButton()`（macOS 26+ glass，旧系统 borderedProminent）。
- 次 CTA：`.gatherSecondaryActionButton()`。
- 行内/工具按钮：`.buttonStyle(.borderless)` + `.controlSize(.small)`；不要自绘胶囊。

---

## 4. 禁止项

- ❌ 页面里直接 `.font(.callout)` / `.font(.system(size:))`：改用 `.gatherText(...)` 或 `GatherFont` 角色。
- ❌ 页面里直接 `Color(hex:)` / `.background(.regularMaterial)`：用 `GatherTheme` / `gatherSurface`。
- ❌ 内容层用 Liquid Glass：玻璃只用于 toast / 浮层 / 功能按钮。
- ❌ 在 `.inspector` 里用 `Form`：用 `ScrollView` + `gatherCard`（`GatherInspectorSection` 仍待落）。
- ❌ 在页面里手写检查器宽度/页签高度：用 `GatherChromeMetrics`。
- ❌ 为“统一”把 List 行内空态换成全屏 `GatherEmptyState`：会撑行高，属于布局改变。
- ❌ 批量 `sed` 替换间距/圆角：6/10/14 的收敛会动布局，必须逐页截图。

### 3.5 会话页

```swift
GatherSessionPage(page: .culling, workspace: workspace, subtitle: l10n("挑片与写回")) {
    content
}
.toolbar {
    GatherSessionToolbar(
        sessionId: viewModel.sessionId,
        culling: culling,
        onOpenSettings: { openSettings() },
        refreshTitle: l10n("刷新"),
        onRefresh: { Task { await viewModel.load() } }
    )
}
.inspector { ... }
```

`GatherSessionPage` 负责：7 段页签、返回、canvas 背景、`navigationSubtitle`、
页面级 `workspace.setPageVisible`（onAppear/onDisappear）。`GatherSessionToolbar`
负责每页都有的 C1/刷新/设置；页面只追加页内动作（如 Export 预览/开始导出）。
不要在新页面里再写 `sessionPageChrome`、setPageVisible 钩子或重复 C1 胶囊。

返回语义：图库/相似度页的返回回到进入前页面；从图库/相似度切到普通页签后再返回，
先回图库/相似度；普通页签之间切换不改变返回目标；没有页级来源时返回离开会话。

### 3.6 交互入口

- 路由：`@Environment(\.navigator)` 取 `RootNavigation`，调
  `open(_ page:in:)` / `openGallery(photoId:)` / `openCullingConflicts` 等；
  页面不再接收导航闭包。
- 命令：菜单/快捷键走 `AppCommandCenter`（RootView 安装 handler）。
- 事件：写路径广播用 `.refreshOnDomainEvents(...)`；需要 change 载荷用
  `.handleDomainEvents(...)`；任务终态用 `.refreshOnJobTerminal(...)`。
- 生命周期：会话页的可见性只由 `GatherSessionPage` 调，页面不要在 onAppear/
  onDisappear 里重复调用。

---

## 5. 门禁

```bash
# 只允许下降；增加会 exit 1
./scripts/check-design-system.sh

# 有意更新基线（review 后）
./scripts/check-design-system.sh --update

# 先观察、不阻断
./scripts/check-design-system.sh --warn-only

# 对比度回归（浅/深/高对比）
cd desktop/native/gather-app
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --filter ThemeContrastTests --no-parallel \
  --disable-sandbox --cache-path ../.build/shared-cache --scratch-path ../.build/scratch
```

基线文件：`scripts/design-system-baseline.json`。

---

## 6. 迁移状态

| 阶段 | 状态 |
| --- | --- |
| 主题/共享叶子迁入 `DesignSystem/` | ✅ 本轮 |
| `GatherPage` / `GatherSection` / `GatherEmptyState` / `GatherChromeMetrics` | ✅ 本轮 |
| Dashboard / Library / Persons / Settings 使用 `gatherPage` | ✅ 第一里程碑 |
| 7 个会话页使用 `GatherSessionPage` + 生命周期 | ✅ Phase 2 |
| `AppRoute` / `SessionPage` / `\.navigator` environment | ✅ Phase 3（旧 `Destination` / `SessionTab` 已删除） |
| `AppCommandCenter` 菜单命令 | ⚠️ Phase 4 部分：主路径已接；undo/redo 仍只在 Culling 页内，AppDelegate 兜底回退通知、菜单 canPerform/禁用态未完成 |
| `refreshOnDomainEvents` / `refreshOnJobTerminal` | ✅ Phase 4 |
| `GatherSessionToolbar` 共享工具栏 | ✅ P2（7 页迁移；Control/Face 改 @Bindable 修 SIGSEGV） |
| `GatherInspectorSection` 共享检查器 | 下一阶段 |
| 删除 `Destination` / `SessionTab` 兼容层 | ✅ P2 |

**迁移原则**：先组合层、后页面；先全局页、后会话页；先路由、后命令。
每阶段独立构建/测试/截图，不做大爆炸重写。

---

## 7. 一句话

> 页面只声明“我是谁、我有哪些槽位”；颜色、字体、表面、chrome、生命周期由设计系统与外壳负责。
