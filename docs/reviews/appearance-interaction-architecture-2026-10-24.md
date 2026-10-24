# Gather 外观与交互的宏观架构评审（2026-10-24）

> 评审对象：`desktop/native/gather-app/Sources/GatherUI`（HEAD `71a3159e`，分支 `appearance`）
> 评审口径：只回答“结构是否撑得住”，不复述逐页视觉问题；逐页像素问题见
> [visual-style-review-2026-10-23.md](visual-style-review-2026-10-23.md)。
> 行号按当前 HEAD；数字由 `rg` / 脚本在该 HEAD 上实测，引用前请重新核对。
>
> **实施注记（2026-10-24）**：本报告评审时主题/共享组件位于 `Support/`；本轮执行已把
> `GatherTheme/GatherStyle/GatherGlass/GatherBadge/NativeBanner/GatherToast/GatherCommonViews`
> 迁到 `DesignSystem/`，并新增 `GatherPage/GatherSection/GatherEmptyState/GatherChromeMetrics`。
> 下文文件路径按评审时快照保留；当前代码以 `DesignSystem/` 为准。
>
> **Phase 2-4 实施注记（2026-10-24）**：7 个会话页已迁到 `GatherSessionPage`；
> `AppRoute`/`SessionPage` 成为唯一路由状态，页面从 `\.navigator` 取导航；
> `AppCommandCenter` 接管菜单命令；`domainChanged`/`jobTerminal` 已声明式化。
> **§6.3.1 的浏览器式 RouteHistory 没有采用**：现有测试明确锁定“会话内部切页签
> 不改变返回目标、图库/相似度返回=进入前页面”的产品语义；实现改为显式的
> `sessionOrigin` + `previousRoute` 双槽，见 [Phase 2-4 执行记录](appearance-m2-m4-execution.md)。

---

## 0. 结论

**骨架是原生的，状态所有权是清楚的；但外观与交互都还停留在“每页自己拼装”的阶段。**

过去几轮把两件很难的事做对了：

1. **外观有了语义层**：`GatherTheme` 的三层表面、状态文字色、`GatherStyle` 的字号/间距/动效，
   以及 `GatherBadge`、`PhotoOverlayChip`、`gatherCard` 等共享叶子。
2. **交互有了状态层**：`SessionStore → SessionWorkspace → 7 个 VM → 页面 @State`，
   两级可见性、LRU、入口意图、条件构建，方向都对。

但下一层没有建立起来：

- **外观**：token 是“常量”，不是“组合规则”。每个页面仍然自己决定背景、标题、工具栏、
  检查器、空态和生命周期；共享组件只覆盖原子，没有覆盖“页面”这个最常复用的单位。
- **交互**：导航是“一个 destination 枚举 + 一个 previous 槽 + 一串闭包”，命令是
  “SwiftUI Commands + AppKit 菜单 + NotificationCenter”三套并存；没有单一的路由模型，
  也没有单一的命令模型。

所以本报告的重点不是再补几个 token，而是补两个契约：

> **页面配方（Page Recipe）**：页面只声明“我是谁、我有哪些槽位”，由外壳渲染 chrome。
> **路由/命令契约（Interaction Contract）**：页面只调用 navigator / command，
> 由外壳拥有历史、可用性、焦点与生命周期。

### 结构评分（主观，仅用于定位优先级）

| 维度 | 判断 | 分数 |
| --- | --- | --- |
| 原生容器与系统边界 | `NavigationSplitView` / `List` / `.inspector` / `Form(.grouped)` / Glass 功能层边界都用对了 | 8 / 10 |
| 状态所有权 | Store / Workspace / VM / 页面 state 层级清楚，LRU 与意图有归属 | 7 / 10 |
| Token 完整性 | 颜色/字号/间距已有角色，但 adoption 只有一半，遗留别名仍在扩散 | 6 / 10 |
| 组件层 | 有 card / badge / chip / banner，但没有 section / inspector / page / chrome 原语 | 5 / 10 |
| 页面组合 | 11 个页面各自组装页面结构；新增页面要重新决定一遍窗口结构 | 3 / 10 |
| 路由模型 | destination 枚举 + 单槽 previous + 粗粒度 origin，不能表达路径 | 4 / 10 |
| 命令/键盘 | 三套菜单/通知路径；没有可用性、焦点域和统一 keymap | 3 / 10 |
| 事件/生命周期 | 载荷是类型化的，但 27 个 `onReceive` 与 7 份可见性钩子由页面各自维护 | 4 / 10 |
| 可执行治理 | 有布局预算与 preview 门禁；没有 token/对比度/截图的 CI 契约 | 4 / 10 |

**一句话**：不是“没有设计”，而是**设计规则没有落到组合层**。当前代码把“页面长什么样”
和“动作怎么到达”留给了每个页面，导致规则只能靠注释、review 和记忆维持。

### 设计语言判断

- 这是**照片工具**，不是后台仪表盘：内容层应中性、低饱和，chrome 让位于照片；
  当前“暖中性 canvas + 单一品牌橙 + 三层表面”的方向是对的，应继续压缩卡片化表单和多彩状态。
- 交互模型应是**全局资料库 + 工作区页签 + 检查器**的专业三栏；键盘、可预测返回、
  状态恢复与视觉同等重要，而不是“页面能点就行”。
- 设计系统的目标不是“所有页面长得一样”，而是**同一类页面用同一套配方**：
  全局页、会话页、检查器、浮层各有自己的 chrome 规则。

---

## 1. 评审范围与基线

### 1.1 范围

| 组 | 文件 |
| --- | --- |
| 主题/样式 | `Support/GatherTheme.swift`、`GatherStyle.swift`、`GatherGlass.swift` |
| 共享组件 | `GatherCommonViews.swift`、`GatherBadge.swift`、`PhotoOverlayChip.swift`、`NativeBanner.swift`、`GatherToast.swift`、`C1StatusCapsule.swift` |
| 窗口外壳 | `Shell/RootView.swift`、`RootShellNavigation/Sidebar/Detail/Toolbar/Workspace/Overlay.swift`、`Support/SessionTabBar.swift` |
| 会话状态 | `SessionStore.swift`、`SessionWorkspace.swift`、`WorkspaceIntent.swift`、`PageVisibility.swift` |
| 页面 | Dashboard / Library / Persons / Gallery / Culling / Duplicates / FaceKeywording / Similarity / Export / Settings / SessionControl |
| 命令/事件 | `GatherAppCommands.swift`、`GatherAppDelegate.swift`、`GatherAppNotification.swift`、`GatherEventCenter.swift`、`MenuCopy.swift` |

### 1.2 基线数字（当前 HEAD 实测）

| 指标 | 数值 |
| --- | --- |
| GatherUI Swift 文件 / 行数 | 199 / 30,732 |
| `Support/` | 39 文件 / 5,713 行（约 18.6% 的 UI 代码） |
| `GatherTheme.` 调用 | 313 |
| `GatherFont.` 调用 | 151 |
| `.font(` 调用 / 其中 `.font(.callout` | 278 / 92 |
| `.system(size:` | 6 |
| 字面量间距值 | 16 种；8 出现 54 次、10 出现 34 次、6 出现 30 次、12 出现 28 次 |
| `GatherMetrics.Space` 使用 | 34（`spacing:` 只有 19 次走 token） |
| `gatherCard` / `GroupBox` | 29 / 5（5 个 GroupBox 全在 Culling 检查器） |
| `ContentUnavailableView` / `GatherEmptyState` | 31 / 0 个调用点（类型定义在 `GatherCommonViews.swift:149`） |
| `sessionPageChrome` / `.toolbar` / `.inspector` | 7 个页面 / 17 / 3 |
| `onReceive(NotificationCenter…)` | 27 处，分布在 12 个文件 |
| `.task` / `.onAppear` / `.onDisappear` | 62 / 33 / 13 |
| `.keyboardShortcut` / `.onKeyPress` / `.focusable` | 22 / 7 / 3 |
| `.accessibilityLabel` / `.accessibilityValue` / `.accessibilityHint` | 69 / 19 / 1 |
| `languageStore?.l10n ?? L10n(zhCN)` | 54 |
| `SessionTab` / `SessionTabSelection` / `Destination` / `SessionWorkspace.Page` | 5 / 3（7 个可选值）/ 6 / 7 个 case |

> 这些数字不是“越多越坏”。它们用来说明：**同一件事有多少个入口、多少个真相源**。

---

## 2. 现状架构

### 2.1 外观栈

```
GatherApp (WindowGroup / Settings)
└─ RootView (NavigationSplitView, .tint(accent), window title)
   ├─ Sidebar (List, native)
   ├─ Detail (switch destination)
   │  ├─ 全局页: Dashboard / Library / Persons
   │  └─ 会话页: sessionPageChrome + toolbar + inspector + banners
   └─ Overlay (Toast)

GatherTheme (color / radius / shadow)      GatherStyle (font / metrics / motion)
        ↓                                          ↓
gatherCard / GatherBadge / PhotoOverlayChip / NativeBanner / GatherEmptyState
        ↓
每页自己的 modifier 链：.background / .navigationTitle / .toolbar /
.inspector / .searchable / .onAppear / .onReceive
```

**特征**：底层 token 是共享的，**页面组合不是共享的**。页面是“token 的自由组合”，
而不是“设计系统的实例”。

### 2.2 交互栈

```
菜单: SwiftUI Commands ──┐
      AppKit 菜单兜底 ───┼── NotificationCenter ──> RootView / AppDelegate
      UI 直接 post ──────┘

RootView @State: RootNavigation + newWorkspaceRequest + columnVisibility
  ↓
RootShellDetail: switch destination，逐页注入 4–9 个闭包
  ↓
SessionTabHost: SessionTabRouter（9 个闭包）→ 7 个会话页
  ↓
SessionWorkspace（7 个 VM / 意图 / 两级可见性）← SessionStore（LRU）
  ↑
GatherEventCenter（job / domain / c1）── 27 个 onReceive
```

**特征**：状态归属是清楚的，但**导航/命令/事件没有单一 owner**。每个页面既接收闭包，
又订阅通知，又自己调 `workspace.setPageVisible`。

### 2.3 信息架构：两级导航已经成立，但命名和页签语义还不稳

当前是清晰的两级模型：

| 层级 | 当前条目 | 判断 |
| --- | --- | --- |
| 全局 | 工作台 / 全局图库 / 人脸库 / 设置（独立窗口） | 结构清楚；设置不占侧栏符合 macOS 惯例 |
| 工作区 | 浏览 / 相似度 / 控制中心 / 人脸 / 重复 / 挑片 / 导出 | 能覆盖工作流，但“模式”和“任务”混在同一排 |
| 页面内 | 检查器（Library / Gallery / Culling） | 专业工具的正确方向；但只有 3 页有，其余页面把选项放在内容里 |

三个具体的 IA 问题：

1. **默认落点与页签顺序不一致**：进入工作区默认落 `.control`（`RootNavigation.openSession` 169-172），
   但页签顺序是“浏览 → 相似度 → 控制中心 → …”，用户先看到第三个页签被选中。
   建议把页签分成“查看（浏览/相似度）”与“处理（控制中心/人脸/重复/挑片/导出）”两组，
   或把控制中心提升为工作区首页，页签只放任务。
2. **命名只差一个字**：工作台（Dashboard）vs 工作区（Session）vs 工作区控制中心；
   图库（会话内）vs 全局图库；人脸（会话内）vs 人脸库（全局）。
   建议固定命名契约：工作台 / 工作区 / 工作区图库 / 全局图库 / 人脸审核 / 人脸库，
   并在侧栏、窗口标题、页签、空态里使用同一组词。
3. **“控制中心”是工作区首页，不是任务**：它承载索引、阶段、任务、待办、推荐、同步，
   信息密度与“导出/挑片”不是一个层级。把它建模成 `SessionPage.control` 会继续和任务页签平级；
   更合理的模型是 `WorkspaceHome`（工作区首页）+ `WorkspaceTask`（任务页签）。

> 这一节不是要求立刻改 IA；它说明为什么“页面配方”必须能表达不同的页面角色，
> 而不是把一个 `sessionPageChrome` 套到所有页面上。

---

## 3. 外观架构：token 已就位，组合层缺失

### 3.1 已经做对的（不要一起改掉）

1. **原生容器优先**：`NavigationSplitView`、`List(selection:)`、`.inspector`、
   `Form(.grouped)`、`ContentUnavailableView`、segmented `Picker`。
2. **三层表面**：canvas / surface / surfaceMuted，hairline + 轻阴影；卡片不再与页面同色。
3. **状态与文字分离**：语义色只做圆点/图标/fill，正文用 primary；`*Text` 变体按 4.5:1 校核。
4. **Liquid Glass 边界**：`GatherGlass` 明确“内容层不用玻璃”，只给 toast/浮层/功能按钮。
5. **可访问性基础**：Dynamic Type 文本样式、semantic colors、reduce motion 分支。

这些是资产。下面的问题不是“推翻”，而是“把资产变成默认路径”。

### 3.2 结构性问题

#### A1. Token 是常量，不是角色；页面仍在两套语言之间选择

`GatherStyle.swift:7-75` 定义了 16 个字体常量、8 个间距、6 个布局值、动效；
`GatherTheme.swift:15-172` 定义了颜色/圆角/阴影。但页面仍在大量使用系统文本样式：

- `.font(.callout` 92 次，而 `GatherFont` 151 次；`GatherFont.secondary` 本身就是 `.callout`。
- 字面量间距 16 种；`GatherMetrics.Space` 只有 34 次，`spacing:` 仅 19 次走 token。
- `GroupBox` 5 次（全在 Culling 检查器），`gatherCard` 29 次；两种容器语言并存。
- `GatherMetrics.Opacity` 1 次，`GatherTheme.infoText` 0 次，`gatherCanvas()` 1 次；
  `GatherTheme.windowBackground` 12 次 vs `canvas` 6 次。

**问题不在“还有 92 个 callout”，而在“选 token 和选系统样式一样方便”。** 设计系统没有提供
比系统样式更贴近语义的入口，所以旧代码没有迁移动力，新代码也会继续分叉。

#### A2. 页面 chrome 由每个页面自己拼

7 个会话页都重复同一组结构：

```
.background(GatherTheme.windowBackground)
.sessionPageChrome(subtitle:onBack:selection:onBrowse:onSimilarity:onSelectTab:)
.toolbar { C1StatusCapsuleHost + 刷新 + … }
.inspector(isPresented:) { … .inspectorColumnWidth(min: 220, ideal: 260, max: 360) }
```

例子：`CullingView.swift:68-115`、`ExportView.swift:56-202`、`GalleryView.swift:92-197`。
全局页也各自决定 `.navigationTitle` / `.background` / `.searchable`：
`DashboardView.swift:77-167`、`LibraryView.swift:107-170`、`PersonsView.swift:45-105`。

**后果**：

- “页面是什么”没有单一定义；新页面要重新决定一遍窗口结构。
- 改一次窗口 chrome 要改 7–11 个文件；漏一个就出现“这页有返回、那页没有”的漂移。
- `SessionTabBar.swift:82-102` 把导航页签和窗口 chrome 放在同一个 modifier 里，
  而文件住在 `Support/`，与主题 token 同级。**导航模式被放进了样式目录**。

#### A3. `Support/` 是 5.7k 行的共享层，但没有设计边界

`Support/` 同时包含：

| 关注点 | 文件/行数 |
| --- | --- |
| 主题/样式 | `GatherTheme` 262、`GatherStyle` 87、`GatherGlass` 89 |
| 共享组件 | `GatherCommonViews` 293、`GatherBadge` 131、`NativeBanner` 129、`GatherToast` 175 |
| 本地化 | `L10n` 613、`GatherLocalization` 346、`LanguageStore` 143 |
| 图像 | `PhotoThumbnailView` 782（视图 + 解码档位 + 缓存 + 闸门） |
| 会话/事件 | `SessionWorkspace` 189、`SessionStore` 118、`GatherEventCenter` 146 |
| C1 状态 | `C1StatusCapsule` 340 |
| 错误/端口/缓存 | 其余约 1.9k 行 |

主题/组件相关代码约 1.5k 行，其余是基础设施。**没有一个目录能回答“视觉契约在哪里”**；
新代码默认往 `Support/` 加文件，边界只会继续模糊。

#### A4. 组件层只有叶子，没有“页面级原语”

现有共享组件覆盖的是原子：

- `gatherCard` 是 modifier（固定 maxWidth + padding），不是可组合的容器；
  `GatherStatCard` 又自己画了一遍 surface + border（`GatherCommonViews.swift:74-95`）。
- `GatherEmptyState` 是自定义空态，但 **0 个调用点**；页面直接用 31 个
  `ContentUnavailableView`。这不是“组件不好”，而是“组件没有成为默认路径”。
- Culling 检查器用 `GroupBox`，Library/Gallery 用 `gatherCard` + 手写分区；
  三个检查器三种标题/间距/表面。
- 状态表面有三套：`NativeBanner`（26 次）、`GatherToastCenter`（14 处引用 / 11 次 show）、页面内联错误文字。

缺的不是更多原子，而是这些**页面级原语**：

```
GatherPage / GatherSessionPage    页面骨架（标题、背景、槽位、生命周期）
GatherChrome                      window toolbar / tab strip / overflow 的布局策略
GatherSection / GatherInspectorSection
GatherToolbar / GatherStatusBar
GatherContentState                loading / failed / empty / loaded 的统一分支
GatherDecisionMark                保留 / 淘汰 / 未处理 / 推荐（Culling & Duplicates）
```

#### A5. 没有可执行的治理

- 有 `LayoutBudgetTests`（394 行，覆盖最小宽度/约束循环），有 `check-preview-surface.sh`；
- **没有** `ThemeContrastTests`，没有 token 使用 ratchet，没有样式指南；
- `docs/design/` 不存在；`scripts/` 的 9 道门禁里没有设计门禁。

结果：`GatherTheme.swift:174-189` 的 13 个兼容别名（`windowBackground`、`primary`、
`background`、`border`、`Radius.group/panel/sm/md`…）没有退出机制。迁移可以无限期停在
“新旧并存”，而 review 只能靠人眼记住哪些是新名。

---

## 4. 交互架构：状态所有权清楚，路由/命令层缺失

### 4.1 已经做对的（不要一起改掉）

1. **每会话工作区**：`SessionStore` 管 LRU，`SessionWorkspace` 管 7 个 VM、标题缓存、
   入口意图、关闭终态；`SessionStore` 不持有 destination。
2. **两级可见性**：`SessionWorkspace.setVisible` 管会话进出，`setPageVisible` 只启停当前页；
   默认不可见、幂等、shutdown 终态（`PageVisibility.swift:22-35`）。
3. **条件构建**：页面按目的地构建，不再用 `.opacity(0)` 常驻；跨页快捷键/轮询污染被消除。
4. **入口意图**：`WorkspaceIntent` 六种 Kind，take 即清；跨页动作有明确归属。
5. **类型化 API**：页面 VM 只依赖 `GatherProtocol`；没有字符串命令/Router。

这些是这次重构最扎实的部分。问题不在状态层，而在**状态层之上的路由/命令层没有成形**。

### 4.2 结构性问题

#### I1. 导航是 destination 枚举，不是路由模型

`RootShellNavigation.swift`：

- `Destination` 6 个 case（`34-41`）；
- `previousDestination` 只有一个槽（`115`）；
- `sessionOrigin` 5 个粗粒度来源（`101-107`）；
- `goBack` 优先 previous，否则按 origin 兜底（`137-153`）；
- 四个返回入口 `backFromSession/backFromSimilarity/backFromGallery/goBack` 都指向它。

注释记录了多轮修补：E-P0（返回写死去图库）、B1（单步返回）、A6（gallery/similarity 被 default 吞掉）、
问题 8（gallery 返回落点）。这些都是真实 bug，但根因是**模型只能表达“一个 previous”**，
不能表达“路径 + 转移策略”。

具体后果：`openSessionTab` 在同一会话内切换页签时**不记录** previous（`186-191`），
而 `openGallery/openSimilarity` 会记录。于是“控制中心 → 浏览 → 相似度 → 返回”能回到浏览，
但“控制中心 → 浏览 → 挑片 → 返回”可能回到进入会话前的页面。行为是路径依赖的，
测试只能逐条枚举，新增入口很容易再破一次。

`NavigationStack` 在 production 中 0 次，13 次全在 Preview。**既然不用系统栈，就必须
自己把路由模型写清楚**；现在它是一个隐式单槽。

#### I2. 同一组 7 个页面被建模了 4 次

| 类型 | 形状 | 用途 |
| --- | --- | --- |
| `SessionTab`（`Shell/SessionTab.swift:7-14`） | 5 case | 会话页签身份 |
| `SessionTabSelection`（`Support/SessionTabBar.swift:9-13`） | browse / similarity / tab(5)，共 7 个可选值 | 页签栏高亮 |
| `RootNavigation.Destination` | gallery / similarity / sessionTab(5) | 路由目的地 |
| `SessionWorkspace.Page`（`SessionWorkspace.swift:36-44`） | 7 case | 页面可见性路由 |

再加 `SessionTabBar.tabTitle` 的 5 分支、`SessionTabHost` 的 5 分支、`SessionWorkspace`
的 7 分支。**新增一个页面/页签要改 5 个 switch**。Exhaustive switch 是安全网，
但这里的安全网重复了 4 次，任何一次漏改都是编译错误或静默错页。

#### I3. 9 个闭包的 router + 每页 5–9 个闭包 = 交互版 prop drilling

`SessionTabHost.swift:31-63` 的 `SessionTabRouter` 有 9 个闭包：
`onBack`、`onOpenSimilarity`、`onOpenTab`、`onOpenGallery`、`onOpenSettings`、
`onOpenExportTab`、`onReviewXmpConflicts`、`onReviewOfflinePhotos`、`onReviewStaleAnalysis`。

`RootShellDetail.swift:82-112` 为 sessionTab 构造这 9 个闭包；每个页面 init 再接收 5–9 个。
`GalleryView`、`ExportView`、`CullingView` 等都有一串 `onBack/onOpenSimilarity/onOpenTab/
onOpenGallery/onOpenSettings`。`onBack` 在代码库中出现 57 次（含注释/测试）。

这不是“闭包不好”，而是**页面知道了太多它不需要知道的导航形状**。加一个目的地、
改一个回调签名，要同步改 RootView、RootShellDetail、SessionTabHost、7 个页面、预览、
布局测试。导航应该是一个环境能力，不是构造参数。

#### I4. 命令是“SwiftUI + AppKit + 通知”三套并存

- `GatherAppCommands.swift:42-60` 用 SwiftUI `Commands` 构建 5 个菜单项；
- 每个菜单项 `post` 一个 `Notification.Name`（`77-82`）；
- `GatherAppDelegate.swift:203-253` 又因为 SwiftUI 会替换 `NSApp.mainMenu`，补一份
  File/Edit 菜单，并按 `⌘N`/`⌘O` 去重；
- `RootView.swift:117-139` 订阅这些通知；
- 页面还直接 `post` `importFolderRequest`（Dashboard/Library/Gallery 等）。

没有 `AppCommand` 枚举、没有 `canPerform`、没有 `@FocusedValue` 命令域。结果是：

- 菜单项的禁用态无法跟页面状态同步；
- Culling 的撤销/重做**不在菜单里**：`CullingToolbar.swift:133-156` 把 `⌘Z/⇧⌘Z` 挂在
  可见按钮上，因为菜单的 undo 走 `NSUndoManager`，而 `gatherMenuUndo/Redo` 通知
  “全仓没有发布者”（`CullingView.swift:124-127`）；
- `ensureStandardMenus` 是一个运行时补丁，不是命令架构。

#### I5. 事件与生命周期由页面复制

- 27 个 `onReceive(NotificationCenter…)`，12 个文件；每页自己 guard 类型/scope/domain，
  自己 debounce。例：`LibraryView.swift:148-169`、`GalleryView.swift:173-193`、
  `SessionControlView.swift:176-193`、`SettingsView.swift:152-156`。
- 7 个会话页每页都有：`.task` 加载 + `.onAppear` `setPageVisible(true)` +
  `.onDisappear` `setPageVisible(false)`；`SessionWorkspace` 另有一层会话级全停，
  `RootShellWorkspace` 还有 route 级兜底。
- 两级可见性是**好设计**，但“谁在什么时候调用”仍是 7 份复制。漏一个 `onDisappear`
  就是后台轮询不停；重复 `onAppear` 靠契约幂等兜底。

`PageVisibility` 是状态契约，不是生命周期 API。页面应该只声明“我是哪一页”，
由 scaffold 负责挂载/卸载时调用。

#### I6. 场景/窗口边界没有定义

- `RootNavigation` 是 `RootView` 的 `@State`；`newWorkspaceRequest` 也是 shell `@State`；
- `SessionStore`/`LanguageStore`/`RootShellDependencies` 在 `AppBootstrap.SceneState`；
- `Settings` 是独立 scene；
- `@SceneStorage` 只用于 3 个检查器布尔值，没有 destination/tab/lightbox 恢复；
- 深链走 AppDelegate → import → notification → RootView，路由不是可直接寻址的。

当前实现**隐含单窗口**。如果以后要做多窗口/窗口恢复，`SessionStore`（共享 workspace）
和 `RootView @State`（每窗路由）会立刻冲突。这个边界需要在架构上明确，而不是等需求来了再拆。

#### I7. 本地化在页面边界是可选的

54 处 `languageStore?.l10n ?? L10n(language: .zhCN)`。生产漏注入不会报错，会静默中文；
预览很方便。这是“交互一致性”问题：语言是场景级能力，页面不应该有可选的第二真相源。
建议 scaffold 提供非可选 `L10n`（预览注入固定值），而不是每页写 fallback。

---

## 5. 根因：workaround 就是需求

当前架构不是“设计错了”，而是**一串正确的局部修补，缺少一个全局契约**。这些修补
实际上已经把目标架构的需求写出来了：

| 现有 workaround | 位置 | 它真正需要的契约 |
| --- | --- | --- |
| 页签行放内容区 + `ViewThatFits` 降级菜单 | `SessionTabBar.swift:67-161` | Chrome 布局预算 + 统一 overflow renderer |
| `previousDestination` 单槽 + `sessionOrigin` | `RootShellNavigation.swift:101-153` | Route history + 显式 transition policy |
| 9 个闭包的 `SessionTabRouter` | `SessionTabHost.swift:31-63` | Navigator environment |
| RootView 代收 `newWorkspaceRequest` | `RootView.swift:52-55` | Scene-level intent/route state |
| AppDelegate 补 File/Edit 菜单 | `GatherAppDelegate.swift:203-253` | 单一 command/menu owner |
| 7 页各写 `onAppear/onDisappear` | 7 个会话页 | Page lifecycle modifier/scaffold |
| 12 文件 27 个 `onReceive` | 页面 | 声明式 event subscription |
| 13 个主题兼容别名 | `GatherTheme.swift:174-189` | Token deprecation + ratchet |

**结论**：下一阶段不需要发明新方向，只需要把这些 workaround 背后的契约显式化。
这也是为什么本报告建议“先补组合层，再继续逐页美化”——否则每加一个页面，workaround 就多一份。

---

## 6. 目标架构

### 6.1 两个契约，三层目录

```
GatherUI/
  DesignSystem/
    Tokens/         颜色、字体、间距、圆角、阴影、动效、图标、chrome 尺寸
    Components/     Card / Section / Badge / Banner / EmptyState / Stat / DecisionMark…
    Patterns/       GatherPage / GatherSessionPage / GatherChrome / GatherInspector
  Interaction/
    Routing/        AppRoute / SessionPage / RouteHistory / AppNavigator
    Commands/       AppCommand / CommandCenter / CommandScope
    Events/         DomainEvent / refreshOnDomainEvents
    Lifecycle/      gatherPageLifecycle
  Features/         Dashboard / Library / …（只依赖上面两层 + GatherProtocol）
  Shell/            RootView / Scene 装配 / Overlay（只做组合，不定义视觉常量）
```

**不要新建 SwiftPM target。** 目录 + `package` 可见性 + lint 足够；拆 target 会迫使
设计系统暴露 public API，并把 30k 行 UI 的编译/测试成本放大。只有在设计系统被第二个
app 复用时才值得拆。

**依赖方向**：

```
Features → DesignSystem + Interaction + GatherProtocol
DesignSystem → SwiftUI / AppKit（不依赖任何 Feature 类型）
Interaction → SwiftUI / Observation + 路由类型（不依赖 Feature VM）
Shell → 三者；Features 不得 import Shell
Support/ → 只保留基础设施（L10n、错误、端口、缓存、事件中心），不再放主题/组件
```

### 6.2 外观契约：页面配方

#### 6.2.1 Token 角色表

| 类别 | 现状 | 目标 | 迁移动作 |
| --- | --- | --- | --- |
| 表面 | canvas / surface / surfaceMuted + 3 个兼容别名 | `canvas / surface / surfaceRaised / surfaceMuted / viewer`；一个 `gatherSurface(_:)` | 删 `windowBackground/contentBackground/secondaryContentBackground` |
| 行动色 | accent / accentFill / selection / selectionFill | 保留；`selection` 只用于自定义选中，列表选中交给系统 | 清掉根 `.tint` 之外的滥用 |
| 文字 | primary/secondary + 4 个 `*Text` | 10 个文字角色（hero/page/section/body/secondary/label/mono + strong 变体） | 页面改用 `gatherText(_:)` |
| 间距 | 8 个 scale + 16 个字面量 | 4pt 严格 scale：4/8/12/16/24/32/48；2/6 仅 inline | 6→8、10→8/12、14→16、9→8（逐页截图） |
| 圆角 | 5 个角色 + 4 个别名 + 4 个字面量 | 6/8/12/16/24，一名一值 | 删 `group/panel/sm/md`；13/14/9 收敛 |
| 阴影 | 3 个 shadow + 手写 border | `GatherElevation.flat/card/floating/hero` | 不再手写 `.shadow + overlay` |
| Chrome | `RootShellMetrics` + 每页列宽 | `GatherChromeMetrics`：window/sidebar/inspector/tab/info | `RootShellMetrics` 指向它 |
| 图标 | 6 处 `.system(size:)` + 多处字号 | 5 个图标尺寸角色 | 页面不再写 size |
| 动效 | 2 个 duration + 7 个 `.animation` | `gatherAnimation(_:)` 统一 reduce motion | 页面不再直接 `.animation` |

**Typography 是重点**：`GatherFont` 现在是 16 个平铺常量，页面无法判断何时用
`secondary` vs `label`。目标是一个 `GatherTextRole` + modifier：

```swift
enum GatherTextRole {
    case hero, pageTitle, sectionTitle, body, bodyStrong,
         secondary, secondaryStrong, label, mono, stat
}

extension View {
    func gatherText(_ role: GatherTextRole, color: Color? = nil) -> some View
}
```

页面只写 `Text(...).gatherText(.secondary)`；内部决定字号、字重、monospacedDigit、
是否跟随 Dynamic Type。这样 92 个 `.callout` 才有地方可去。

#### 6.2.2 组件分层

| 层 | 组件 | 规则 |
| --- | --- | --- |
| Primitive | `GatherText`、`GatherSurface`、`GatherIcon`、`GatherDivider` | 页面不直接写 font/color/background/阴影 |
| Component | `GatherCard`、`GatherSection`、`GatherBadge`、`GatherBanner`、`GatherEmptyState`、`GatherStat`、`GatherProgress`、`GatherPhotoOverlay`、`GatherDecisionMark` | 变体用 enum，不用多个 Bool |
| Pattern | `GatherPage`、`GatherSessionPage`、`GatherChrome`、`GatherInspector`、`GatherToolbar`、`GatherStatusBar`、`GatherContentState` | 页面只提供槽位 |
| Feature leaf | `GalleryCell`、`CullingFilmstrip`、`FaceClusterCard`… | 只允许用上面三层 |

具体合并：

- `GatherEmptyState` 改成 `ContentUnavailableView` 的薄包装（图标/标题/说明/动作 + 统一
  padding），替换 31 处内联空态；保留系统外观，不另造一套。
- `GatherInspectorSection` 统一三个检查器；Culling 的 5 个 `GroupBox` 改为它
  （继续避开 `Form` 进 inspector 的约束崩溃）。
- `GatherDecisionMark` 统一保留/淘汰/未处理/推荐；Culling 与 Duplicates 不再各画圆点。
- `NativeBanner` 改名为 `GatherBanner`，tone enum（info/success/warning/error）；
  toast 仍是功能层，不合并进 banner。

#### 6.2.3 Chrome 槽位

把页面 chrome 变成声明式槽位，而不是一长串 modifier：

| 槽位 | 内容 | Owner |
| --- | --- | --- |
| `title` / `subtitle` | 页面名 / 会话名 / 状态摘要 | scaffold（title 可由 router 提供） |
| `back` | 返回按钮 + ⌘[ | scaffold |
| `tabs` | 7 段页签 + 窄窗菜单 | scaffold |
| `primaryActions` | C1 胶囊 / 刷新 / 页面主 CTA | scaffold 默认 + 页面扩展 |
| `secondaryBar` | 页面级工具（范围/对比/质量） | 页面 |
| `statusBar` | 计数 / 同步 / 索引状态 | 页面 |
| `inspector` | 选项 / 管理 | 页面 |
| `banners` | 错误 / 通知 | 页面或 scaffold |

渲染器负责：

- 背景、标题、副标题、工具栏位置、检查器宽度/可见性；
- 窄窗 `ViewThatFits` 降级与工具栏 overflow；
- `@SceneStorage` 检查器记忆（key 由 route 派生，不再每页手写）；
- 最小宽度预算（与 `LayoutBudgetTests` 共用常量）。

**规则**：窗口工具栏只放全局动作；页面内会改变固有宽度的控件（筛选、范围、对比）
放 `secondaryBar` 或 overflow，不放 window toolbar。这条规则直接对应 F01/N01 的崩溃教训。

#### 6.2.4 前后对比（Gallery）

Before（现在，`GalleryView.swift:92-197`）：

```swift
page
  .frame(maxWidth: .infinity, maxHeight: .infinity)
  .background(GatherTheme.windowBackground)
  .sessionPageChrome(subtitle: l10n("图库"), onBack: onBack,
                     selection: .browse, onBrowse: {}, onSimilarity: …,
                     onSelectTab: …)
  .toolbar { toolbarItems }
  .inspector(isPresented: $showInspector) { inspector }
  .searchable(...)
  .task(id:) { … workspace.setPageVisible(.gallery, true) }
  .onAppear { … }
  .onDisappear { … }
  .onReceive(jobTerminal) { … }
  .onReceive(domainChanged) { … }
  .onReceive(jobProgress) { … }
```

After（目标）：

```swift
GatherSessionPage(.browse, workspace: workspace) {
    GalleryGrid(...)
}
.subtitle(l10n("图库"))
.primaryActions {
    C1StatusCapsuleHost(...)
    RefreshButton()
}
.inspector { GalleryInspector(...) }
.searchable(...)
.refreshOnDomainEvents([.culling, .library, .metadata, .faceKeywording],
                       sessionId: sessionId) { … }
```

页面不再知道返回按钮、页签、背景、检查器宽度和可见性钩子；只声明内容与槽位。

### 6.3 交互契约：路由 → 命令 → 事件/生命周期

#### 6.3.1 路由模型：一个 `SessionPage`，一个 `AppRoute`

```swift
enum AppRoute: Hashable, Codable {
    case dashboard
    case library
    case persons
    case workspace(sessionId: String, page: SessionPage)
}

enum SessionPage: String, CaseIterable, Hashable, Codable {
    case browse, similarity, control, face, duplicates, culling, export

    var titleKey: String { … }
    var systemImage: String { … }
    var appearsInTabStrip: Bool { … }   // browse/similarity/5 tabs = true
}
```

用 `SessionPage` 取代 `SessionTab` + `SessionTabSelection` + `SessionWorkspace.Page`；
`Destination` 只保留 `AppRoute` 一层。页签栏是 `SessionPage` 的投影，不是第二套枚举。

`RouteHistory` 把“返回”从单槽变成显式策略：

```swift
enum RouteTransition { case push, replace, reset }

@MainActor @Observable
final class AppNavigator {
    private(set) var route: AppRoute = .dashboard
    private(set) var history: [AppRoute] = []

    func go(_ route: AppRoute, transition: RouteTransition = .push)
    func openWorkspace(_ id: String, page: SessionPage = .control)
    func open(_ page: SessionPage, in id: String)
    func openGallery(_ id: String, photo: PhotoTarget? = nil)
    func back()
}
```

**转移策略必须写表**（先按现有验收路径锁定行为，再实现）：

| From | To | Transition | Back 落点 |
| --- | --- | --- | --- |
| dashboard / library / persons | workspace | push | 来源全局页 |
| workspace tab | workspace tab | replace（保留 tab trail） | 上一个不同 tab；无则来源 |
| workspace | gallery / similarity | push | 来源 tab |
| gallery / similarity | workspace | replace | tab trail |
| deep link | workspace page | reset | 全局默认（或历史空） |

这样“工作台 → 控制 → 浏览 → 相似度 → 返回”和“控制 → 浏览 → 挑片 → 返回”都有明确答案，
而不是由 `previousDestination` 是否被某条路径写入决定。

**placement**：`AppNavigator` 移到 `SceneState`，由 `GatherApp` 注入 `RootView` 与
`Commands`。深链直接调用 `navigator.go(...)`，不再经过“import 完成 → 通知 → RootView”。
如果坚持单窗口，这是低风险；如果要多窗口，先决定 per-window store，再搬。

#### 6.3.2 Navigator environment

```swift
extension EnvironmentValues {
    var navigator: AppNavigator { get set }
}

// 页面
Button("相似度") { navigator.open(.similarity, in: workspace.sessionId) }
```

删除：

- `SessionTabRouter` 的 9 个闭包；
- 每个页面的 `onBack/onOpenTab/onOpenGallery/onOpenSimilarity/onOpenSettings` 参数；
- `RootShellDetail` 里逐页构造闭包的 4–9 行。

保留 `onOpenPhoto` 这种**数据动作**，但它也走 navigator 的 `openGallery(photo:)`，
不再由每个页面单独传。

#### 6.3.3 Command：一个 `AppCommand`，一个 `CommandCenter`

```swift
enum AppCommand: String, CaseIterable {
    case newWorkspace, importFolder, captureOneImport, openSettings, toggleSidebar
    case refresh, undo, redo, selectAll, deselectAll, delete, toggleInspector
}

@MainActor @Observable
final class CommandCenter {
    var context: CommandContext
    func canPerform(_ command: AppCommand) -> Bool
    func perform(_ command: AppCommand)
}

struct SessionCommandScope {
    let undo: (() -> Void)?
    let redo: (() -> Void)?
    let refresh: (() -> Void)?
}
```

- `GatherAppCommands` 从 `AppCommand.allCases` 生成菜单项，`.disabled(!center.canPerform(...))`；
- 页面用 `.focusedSceneValue(\.sessionCommands, scope)` 暴露页内命令（Culling undo/redo、
  导出 preview 等）；
- AppDelegate 只负责 `NSApplication` 生命周期、文件打开、C1 导入；**不再建第二套菜单**。
  如果 macOS 14/26 的 SwiftUI 菜单替换仍需要兜底，兜底也从同一张 `AppCommand` 表生成，
  而不是手写 `NSMenuItem`。
- 菜单/按钮/快捷键共用同一个 enum，Culling 的 `⌘Z` 不再靠“可见按钮上的 shortcut”生效。

#### 6.3.4 Event：声明式订阅

保留现有 `GatherEventCenter` 载荷，不重写总线；在 UI 层加一个 modifier：

```swift
.refreshOnDomainEvents(
    [.culling, .library, .metadata, .faceKeywording],
    sessionId: sessionId,
    debounce: .milliseconds(500)
) {
    await viewModel.refresh()
}
```

内部仍可订阅 `NotificationCenter`，但页面不再写 `guard let change = …`、不再各自 debounce。
目标：27 个 `onReceive` 收敛到 5 个以内的声明式订阅 + 少数特例（jobProgress 帧）。

#### 6.3.5 Lifecycle：一个 modifier

```swift
.gatherPageLifecycle(.culling, in: workspace)
```

它负责 `.task(id: sessionId)` 里的 `setPageVisible(true)`、`.onAppear`、`.onDisappear`，
并在 scene phase 变化时 suspend/resume。页面只声明“我是哪一页”。

#### 6.3.6 本地化：页面边界不要 Optional

`GatherSessionPage` / `GatherPage` 提供非可选 `L10n`（从 `LanguageStore` 派生）；
预览注入固定 `LanguageStore(language: .zhCN)`。删除 54 处 `?? L10n(zhCN)` 兜底。
生产漏注入应当编译期/启动期失败，而不是静默中文。

### 6.4 治理：让契约可执行

| 门禁 | 内容 | 起步方式 |
| --- | --- | --- |
| `check-design-system.sh` | 统计 Feature 层裸 `.font(` / 字面量 `.padding(` / `Color(hex` / `.system(size:` / 直接 `.shadow`；与 baseline JSON 比较 | warning 起步，稳定后 `--strict` |
| `ThemeContrastTests` | 解析 `GatherTheme` 的 `*Text` / surface / status 组合，断言 4.5:1（大字号 3:1） | 先锁 `*Text` 与 accentFill |
| `PageChromeBudgetTests` | 扩展现有 `LayoutBudgetTests`：每个 `GatherSessionPage` 在 860×560、检查器开/关下不超预算 | 与 scaffold 同步 |
| `check-preview-surface.sh --strict` | 保留；新增组件 preview 必须覆盖 light/dark | 已有 |
| 截图矩阵 | 11 页 × 浅/深 × 1180/860 × 中/英；关键页加高对比 | 本地脚本/CI artifact |
| 文档 | `docs/design/appearance-interaction.md` = 本报告 §6 的可执行版 | 与 Phase 0 一起落 |

**Ratchet 的基线**（建议从当前数字开始，只允许下降）：

```
font.callout            92
font.raw_system_size     6
spacing.literal_values  16
content_unavailable     31
groupbox                 5
theme.legacy_alias      13
menu.notification       5
page.visibility_hooks    7
```

---

## 7. 迁移路线

> 原则：**先组合层，后页面；先全局页，后会话页；先路由，后命令。**
> 每一阶段都能独立截图/测试，不搞“大爆炸重写”。

### Phase 0 — 基线与护栏（1–2 天）

- 把本报告 §6 落成 `docs/design/appearance-interaction.md`；
- 加 `scripts/check-design-system.sh` + baseline JSON；
- 加 `ThemeContrastTests`；
- 把 `LayoutBudgetTests` 的常量指向新的 `GatherChromeMetrics`。

**退出**：基线数字可复现；新增违规会让门禁变红；现有测试全绿。

### Phase 1 — DesignSystem 提取 + 全局页（3–5 天）

- 建 `DesignSystem/` 目录，搬 `GatherTheme/GatherStyle/GatherGlass` 与共享组件；
- 加 `GatherText/GatherSurface/GatherSection/GatherInspectorSection/GatherEmptyState`；
- 迁移 Dashboard / Library / Persons / Settings 四个全局页（无会话 chrome，风险最低）；
- 主题兼容别名标 deprecated，页面改用新名。

**退出**：4 个全局页只使用 DesignSystem 原语；`ContentUnavailableView` 内联降到 <10；
对比度测试通过；浅/深截图复核。

### Phase 2 — Page scaffold + 会话页 chrome（5–7 天）

- 加 `GatherPage` / `GatherSessionPage` / `GatherChrome` 槽位；
- 先迁 Export（表单简单）或 Duplicates（无轮询），再 Control / Face / Similarity / Gallery / Culling；
- 把返回、页签、C1、刷新、检查器宽度、`@SceneStorage` 收进 scaffold；
- Culling 保留 `secondaryBar`（范围/对比/质量），不硬塞进 window toolbar。

**退出**：7 个会话页不再出现 `.sessionPageChrome`；只有一份 tab strip 实现；
860×560 + 检查器开/关无约束循环；逐页截图。

### Phase 3 — Route + Navigator（4–6 天）

- 引入 `AppRoute/SessionPage/RouteHistory/AppNavigator`；`SessionTab` 收敛为 `SessionPage`；
- `RootNavigation` 的测试改为路由矩阵测试（6 条返回路径 + 3 条深链）；
- Navigator 注入 environment；删 `SessionTabRouter` 与页面导航闭包；
- 把 router 移到 `SceneState`，深链直接寻址。

**退出**：页面 init 不再有导航闭包；返回矩阵全绿；深链不经过通知；多标签切换不丢页。

### Phase 4 — Command + Event + Lifecycle（3–5 天）

- `AppCommand/CommandCenter`；SwiftUI Commands 从表生成；删命令通知；
- AppDelegate 不再手写 File/Edit 菜单；如必须兜底，复用同一张表；
- `refreshOnDomainEvents` 替换 27 个 `onReceive`；
- `gatherPageLifecycle` 替换 7 份可见性钩子；
- Culling undo/redo 进菜单 + focused scope。

**退出**：无命令通知；菜单禁用态正确；订阅数 <5；焦点/快捷键矩阵通过。

### Phase 5 — 场景/恢复 + 验收（2–3 天）

- 单窗口：`@SceneStorage` 恢复 route/tab/inspector；
- 多窗口：先做决策，再引入 per-window `SessionStore`/router（不在本次默认范围）；
- 截图矩阵 + VoiceOver/键盘/语言切换/LRU 验收。

**总工作量**：顺序做约 18–28 个工程日；Phase 1 是 1–2 周内可独立交付的价值点，
Phase 2 是视觉/布局收益最大的一步。

### 不做什么

- ❌ 不引入全局 reducer / 单一 store（会重写 7 个 VM 与全部状态/布局测试，且与 Observation 不匹配）。
- ❌ 不拆 11 个 feature SwiftPM target（manifest/可见性/测试成本爆炸）。
- ❌ 不用自绘 chrome 替换 `NavigationSplitView`/`.inspector`/`Form`。
- ❌ 不把 Liquid Glass 用到内容层。
- ❌ 不做全仓 `sed` 式 token 替换；必须逐页截图，因为 6/10/14 的间距和 8/12 的圆角改变会动布局。
- ❌ 不在没有返回矩阵的情况下改 `goBack` 语义；这是多轮 bug 修出来的行为。

---

## 8. 验收

### 8.1 视觉矩阵

| 页面 | 浅 1180 | 深 1180 | 浅 860 | 高对比 | 中/英 | 空/载入/错误 |
| --- | --- | --- | --- | --- | --- | --- |
| Dashboard | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Library | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Persons | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Gallery + Lightbox | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Culling 1/2/4 图 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Duplicates | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Face 分析/审核/写回 | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Similarity | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Export | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Settings | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| SessionControl | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

### 8.2 交互矩阵

- **返回**：工作台→控制→浏览→相似度→返回；控制→浏览→挑片→返回；图库→会话→返回；
  深链→会话→返回；删除会话后的侧栏回退；同会话页签往返。
- **命令**：⌘N / ⌘O / ⇧⌘I / ⌘, / ⌘⌥S / ⌘Z / ⇧⌘Z；菜单禁用态与页面状态一致。
- **焦点/键盘**：Tab 遍历、Esc 关闭、←/→ 翻页、空格决策、⌘[ 返回；灯箱焦点不泄漏。
- **事件**：jobProgress 节流、jobTerminal 刷新、domainChanged 按域刷新、C1 同步。
- **生命周期**：切页签只启停当前 VM；离开会话全停；LRU 淘汰关闭；语言切换不重建页面。
- **恢复**：冷启动回到上次 route/tab/inspector（若 Phase 5 做）。

### 8.3 工程

- [ ] `swift build` / `swift test --no-parallel` 通过；
- [ ] `LayoutBudgetTests` 通过（860×560，检查器开/关）；
- [ ] `check-design-system.sh` 不高于 baseline；
- [ ] `ThemeContrastTests` 通过；
- [ ] `check-preview-surface.sh --strict` 通过；
- [ ] `check-layering.sh` 通过（GatherUI 仍只依赖 GatherProtocol）。

---

## 9. 需要产品/设计确认的 5 个决策

1. **单窗口还是多窗口？**
   建议：本阶段明确单窗口，但把 route 放到 `SceneState` 并做 `@SceneStorage` 恢复；
   多窗口作为独立项目（需要 per-window `SessionStore`）。
2. **返回语义：真栈，还是“tab trail + 来源”？**
   建议：后者。它符合当前产品“页签不是浏览器历史”的心智，也能覆盖已修的 4 条路径；
   但必须把策略写成表并做矩阵测试。
3. **7 段页签是否保留？**
   建议：保留，但把 browse/similarity 也建模为 `SessionPage`；若 860pt 下仍拥挤，
   把 browse/similarity 移到“显示”菜单或侧栏的“当前工作区”分组，而不是继续压缩。
4. **间距是否严格 4pt？**
   建议：是。6/10/14 收敛到 4/8/12/16；这会改变少量布局，必须逐页截图，不要全仓替换。
5. **设计系统是否独立 target？**
   建议：不。目录 + `package` + ratchet；等第二个 app 复用再拆。

---

## 10. 附录

### 10.1 关键文件索引

| 关注点 | 文件 |
| --- | --- |
| 主题/样式 | `Support/GatherTheme.swift`、`GatherStyle.swift`、`GatherGlass.swift` |
| 共享组件 | `Support/GatherCommonViews.swift`、`GatherBadge.swift`、`PhotoOverlayChip.swift`、`NativeBanner.swift` |
| 窗口外壳 | `Shell/RootView.swift`、`RootShellNavigation.swift`、`RootShellDetail.swift`、`RootShellSidebar.swift`、`RootShellToolbar.swift`、`RootShellWorkspace.swift` |
| 页签/chrome | `Support/SessionTabBar.swift`、`Shell/SessionTab.swift`、`Shell/SessionTabHost.swift` |
| 会话状态 | `Support/SessionStore.swift`、`SessionWorkspace.swift`、`WorkspaceIntent.swift`、`PageVisibility.swift` |
| 命令/菜单 | `GatherApp/GatherAppCommands.swift`、`GatherHost/GatherAppDelegate.swift`、`Support/MenuCopy.swift`、`Support/GatherAppNotification.swift` |
| 事件 | `Support/GatherEventCenter.swift` |
| 布局预算 | `Tests/GatherAppTests/LayoutBudgetTests.swift` |

### 10.2 复核命令

```bash
cd desktop/native/gather-app/Sources/GatherUI

# 字体 / 间距 / 圆角
rg -c '\.font\(\.callout' --glob '*.swift' | awk -F: '{s+=$2} END {print s}'
rg -o '\.padding\([0-9.]+' --glob '*.swift' | sort | uniq -c | sort -rn

# 页面 chrome
rg -l 'sessionPageChrome' --glob '*.swift'
rg -n '\.inspectorColumnWidth' --glob '*.swift'

# 命令 / 事件 / 生命周期
rg -n 'onReceive\(NotificationCenter' --glob '*.swift' | wc -l
rg -n 'setPageVisible' --glob '*.swift' | wc -l
rg -n 'keyboardShortcut|onKeyPress' --glob '*.swift' | wc -l
```

### 10.3 一句话给实现者

> 先把“页面怎么拼”和“动作怎么走”各收成一个 API；每收一个，就删掉一类 workaround。
> 不要一边加页面，一边让每个页面继续拥有自己的窗口 chrome、返回逻辑和菜单通知。
