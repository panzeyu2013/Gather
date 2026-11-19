# Gather 设计系统与页面配方（2026-10-24）

> 目标：页面**声明角色**，不自己拼 font / color / background / chrome。
> 背景与完整论证见 git 历史（原宏观架构评审已清理）。
> 本文只写**怎么用**，不重复评审。

---

## 1. 分层

```
Sources/GatherUI/
  DesignSystem/
    Tokens/       颜色、字体、间距、圆角、阴影、chrome 尺寸
    Components/   Badge / Banner / Button / EmptyState / MenuField / SearchField / Toast
    Patterns/     GatherPage（全局页骨架）/ GatherInspectorSection / GatherCollapsibleSection
    Modifiers/    gatherSurface / gatherText / gatherPresence
  Interaction/    路由、命令、事件、生命周期（GatherSessionPage / SessionPage）
  Dashboard/ Library/ Culling/ …  按功能分目录（不再有 Features/ 层）
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
`.background(GatherTheme.canvas)`。旧别名 `windowBackground` 已删除；`contentBackground` /
`secondaryContentBackground` 只是 `surface` / `surfaceMuted` 的兼容别名，新代码不要再用
（门禁 metric `theme.legacyAlias` 只降不升）。

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
- 圆角优先 `GatherTheme.Radius`：6（小控件）/ 8（照片媒体面 `media`、小面板）/ 12（卡片）/ 16（tile）/ 24（hero）。
  照片缩略图统一用 `Radius.media`：浏览 / 挑片网格 / 全局图库三处必须同一个圆角，
  否则同一张照片在三个页面里像三个产品。
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
Section {
    jobsContent
} header: {
    Text(l10n("任务中心"))
        .font(GatherFont.label)
        .foregroundStyle(.secondary)
}
```

页面内容分区用系统 `Section`（放在 `List` / `Form` 里，标题走 `header:`）；需要卡片
表面时内容自己套 `gatherCard()`。**没有**通用 `GatherSection` 组件（早期规划名，未
落地，勿引用）。检查器分区用 `GatherInspectorSection` / `GatherCollapsibleSection`
（`DesignSystem/Patterns/`）；不要用 `Form` 进 `.inspector`，会触发 AppKit 约束循环。

### 空态

```swift
GatherEmptyState(
    icon: "photo.on.rectangle.angled",
    title: l10n("图库还没有照片"),
    message: l10n("导入一个文件夹后，这里会汇总所有工作区的照片。")
) {
    Button(l10n("导入文件夹")) { ... }
        .gatherButton(.primary)
}
```

`GatherEmptyState` 是品牌色空态（2026-10-30 起自绘，不再是 `ContentUnavailableView` 包装）：
- 页面级空态用它；页面级加载失败/错误态同样用它（必须保留重试/清除筛选等出口）；
- List Section 行内（会被行高约束）继续用 `ContentUnavailableView`，不要强行塞入；
- 采纳进度由门禁 metric `empty.contentUnavailable` 度量（`./scripts/check-design-system.sh`，
  统计 GatherUI 内 `ContentUnavailableView` 出现次数、含注释；只降不升）。

### 按钮

内容层按钮只声明角色，不直接写 `.bordered` / `.borderedProminent` / `.glass`：

- 主 CTA：`.gatherButton(.primary)`；每个 section / view 最多 1–2 个（优先 1），需要尺寸时传 `size: .small/.large`。
- 次 CTA：`.gatherButton(.secondary)`；用于成对的取消、返回、替代路径，以及「路径字段旁的『选择…』」。不着品牌色（macOS 的 tint 只染标签，bezel 仍是系统灰；给取消按钮上品牌橙会与主 CTA 抢注意力）。
- 行内/低优先级：`.gatherButton(.tertiary, size: .small)`。
- 错误上下文里的行内动作（错误行「重试」）：`.gatherButton(.tertiaryDanger, size: .small)`。
- 页面级危险动作：`.gatherButton(.destructive)`（系统描边 + 红色标签，**不是**红色描边）；自定义确认 sheet 的不可逆主按钮才用 `.destructiveProminent`（errorFill 填充 + 白字；alert/confirmationDialog 内仍交系统 role）。
- 图标按钮：`.gatherIconButton()`（默认 `.regular`，命中区 24pt 保底）或系统 `.borderless`；照片卡 / tab 命中区仍用 `.plain`。
- 标签色：`prominent` 系列由 `.tint()` + `.foregroundStyle(onAccent)` 双写；`tertiary` / `tertiaryDanger` / `destructive` 由 `.tint()` + `.foregroundStyle(对应 *Text 色)` 双写。**不要只写 tint**——不同 buttonStyle 对 tint 的处理不一致，只写 tint 会出现"文字没变色"的静默失败。
- 自绘 chip / 状态胶囊（FacetBar、C1StatusCapsule、筛选胶囊）是命中区，不套 `gatherButton`；不要用它们承载普通 CTA。
- 恒暗媒体查看器（Lightbox）的 chrome：`.gatherViewerButton()`（默认 `.regular`，plain + viewer 文字色 + 显式禁用态）；不要用 primary/secondary。
- 窗口 toolbar / 浮层等功能层：`.gatherFunctionalPrimaryButton()` / `.gatherFunctionalSecondaryButton()`（保留系统玻璃）。
- toast 的容器是功能层玻璃，但 toast 内的文字动作仍用内容层 `gatherButton(.secondary, size: .small)`（玻璃上再叠玻璃按钮会丢失边界）；关闭 icon 用 `gatherIconButton(size: .small)`。这是「内容层不用玻璃」的唯一书写例外。
- alert / confirmationDialog 里的按钮交给系统 role，不要套内容层样式。
- 内容层禁用 Liquid Glass；玻璃只用于 toast / 查看器控制条 / 浮动选择栏等浮层表面，不用于**内容层**按钮填充。功能层按钮保留系统玻璃（`.glass` / `.glassProminent`）——这条只作用于 `gatherFunctional*`，页面不要直接写。

尺寸策略：行内动作 `small`，表单/footer 动作 `regular`，hero `large`；同一按钮组不要混用尺寸。
重试层级：整页失败态用 `primary`（整页唯一出口）；同一屏还有别的 primary（如重复页的「开始扫描」）时，失败态的重试降为 `secondary` + `small`；行内/局部恢复用 `secondary` + `small`；错误行辅助重试用 `tertiaryDanger` + `small`。
同一行里若已有 `secondary` 主入口（如会话行的「进入」），行内恢复动作（「重试」）用 `tertiary` 让位；该行只有重试一个出口时用 `secondary`。
`GatherButtonRole` 的映射见 `DesignSystem/Components/GatherButton.swift`：
primary = 品牌实心，secondary = 系统描边（无 tint），tertiary = 纯文字（品牌色），destructive = 系统描边 + 红色标签，destructiveProminent = errorFill 实心 + 白字。

迁移取舍（2026-10-31）：人脸复核页 primary 归“绑定/更新绑定”，拆分所选降为 secondary；
Export 页唯一 primary 是工具栏“开始导出”，整套交付为 secondary；C1“确认同步”统一为 secondary small；
“结束同步/清理备份”保留 destructive（确实删除备份与交付记录）。

---

## 4. 禁止项

- ❌ 页面里直接 `.font(.callout)` / `.font(.system(size:))`：改用 `.gatherText(...)` 或 `GatherFont` 角色。
- ❌ 页面里直接 `Color(hex:)` / `.background(.regularMaterial)`：用 `GatherTheme` / `gatherSurface`。
- ❌ 内容层用 Liquid Glass：玻璃只用于 toast / 浮层表面；按钮本身走 `gatherButton` 层级。
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

所有命令都在**仓库根目录**执行（`--package-path` 指定包，`--cache-path` / `--scratch-path`
用包内绝对/相对路径；不要先 `cd` 进包再调 `./scripts/...`）。

```bash
# 按钮三件套：语义角色门禁（含正则正/负样本自检）+ 渲染采样 + 对比度
#   ButtonStylePolicyTests  —— 页面不得直写系统样式
#   ButtonRenderTests        —— 离屏渲染采样：prominent 填充必须等于对应 token、
#                               secondary 不得带品牌色、标签对比度达标
#   ThemeContrastTests       —— 文字 4.5:1 与控件边界 3:1（1.4.11）
swift test --package-path desktop/native/gather-app --no-parallel \
  --filter 'ButtonStylePolicyTests|ButtonRenderTests|ThemeContrastTests' \
  --disable-sandbox \
  --cache-path desktop/native/gather-app/.build/shared-cache \
  --scratch-path desktop/native/gather-app/.build/scratch

# 只允许下降；增加会 exit 1。基线含空态采纳指标 empty.contentUnavailable
#（页面级空态改用 GatherEmptyState 会压低它；List Section 行内保留项见基线/审计文档）
./scripts/check-design-system.sh

# 有意更新基线（review 后）
./scripts/check-design-system.sh --update

# 先观察、不阻断
./scripts/check-design-system.sh --warn-only

# 对比度回归（浅/深/高对比）
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-app --no-parallel \
  --filter ThemeContrastTests \
  --disable-sandbox \
  --cache-path desktop/native/gather-app/.build/shared-cache \
  --scratch-path desktop/native/gather-app/.build/scratch
```

基线文件：`docs/baselines/design-system-baseline.json`。

---

## 6. 迁移状态

| 阶段 | 状态 |
| --- | --- |
| 主题/共享叶子迁入 `DesignSystem/` | ✅ 本轮 |
| `GatherPage` / `GatherEmptyState` / `GatherChromeMetrics` | ✅ 本轮 |
| Dashboard / Library / Persons / Settings 使用 `gatherPage` | ✅ 第一里程碑 |
| 7 个会话页使用 `GatherSessionPage` + 生命周期 | ✅ Phase 2 |
| `AppRoute` / `SessionPage` / `\.navigator` environment | ✅ Phase 3（旧 `Destination` / `SessionTab` 已删除） |
| `AppCommandCenter` 菜单命令 | ✅ Phase 4：菜单可执行性由 `AppCommandCenter.installed` 驱动并置灰；undo/redo 仅挑片页自建历史栈，其他页面保留系统撤销/重做 |
| `refreshOnDomainEvents` / `refreshOnJobTerminal` | ✅ Phase 4 |
| `GatherSessionToolbar` 共享工具栏 | ✅ P2（7 页迁移；Control/Face 改 @Bindable 修 SIGSEGV） |
| `GatherInspectorSection` / `GatherCollapsibleSection` 共享检查器 | ✅ Phase 5（Metadata / Gallery / Library / Culling 检查器已迁移） |
| 按钮语义层（`GatherButton` + 门禁） | ✅ 本轮：内容层角色化；toolbar/浮层用功能层 helper；Lightbox 用 viewer helper |
| 删除 `Destination` / `SessionTab` 兼容层 | ✅ P2 |

**迁移原则**：先组合层、后页面；先全局页、后会话页；先路由、后命令。
每阶段独立构建/测试/截图，不做大爆炸重写。

---

## 7. 一句话

> 页面只声明“我是谁、我有哪些槽位”；颜色、字体、表面、chrome、生命周期由设计系统与外壳负责。
