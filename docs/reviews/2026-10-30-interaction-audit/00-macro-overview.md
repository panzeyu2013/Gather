# Gather 交互与前端显示：宏观分析（2026-10-30）

> 范围：`desktop/native/gather-app/Sources/GatherUI`（242 个 .swift / 约 39,540 行）+ `Sources/GatherApp` 场景装配。
> 方法：静态审计（read/grep）+ 现有验收截图 + 仓库门禁脚本；**未实机运行 GUI**，涉及运行时表现的条目已在文中标注「待实机」。
> 分模块深查见同目录 `A-`…`F-` 六份报告。

---

## 1. 产品与界面形态

单窗口 macOS 原生应用，三段式信息架构：

```text
Window(1180×780，最小 860×560)
└─ NavigationSplitView
   ├─ 侧栏 List(selection:)      工作台 / 最近 5 个工作区 / 资料库（全局图库·人脸库）
   └─ 详情（由 AppRoute 条件构建）
      ├─ 全局页：工作台 · 全局图库 · 人脸库      → gatherPage 骨架
      ├─ 会话层：7 段页签 + 会话页内容           → GatherSessionPage 骨架
      │   浏览 / 相似度 ┊ 控制中心 / 人脸 / 重复 / 挑片 / 导出
      └─ 模态层：11 个 sheet · 13 个 confirmationDialog · 4 个 alert · 3 处 .inspector
   Settings 独立窗口（⌘,）
```

**交互骨架（做得好的部分）**：单一目的地 `AppRoute` + 单一页面身份 `SessionPage`；页面按目的地条件构建；每会话 7 个 VM 由 `SessionStore/Workspace` 持有并按页可见性启停；入口意图 `WorkspaceIntent`（take 即清、离开目标页即失效）；领域事件刷新收口为 `refreshOnDomainEvents / handleDomainEvents / refreshOnJobTerminal`；菜单命令单轨走 `AppCommandCenter`。这套骨架把「路由/生命周期/事件」三件事各收在一处，代码里没有第二套页面枚举或第二条命令通道。

**真正的复杂度不在这层**，而在下面三件尚未收口的事：chrome 分层、反馈通道、状态真相。

---

## 2. 宏观结论（5 条）

### M1 · 工具栏退化为「状态条」，页面主行动全在正文
7 个会话页的窗口工具栏几乎逐字相同：C1 状态胶囊 + 刷新（Gallery 多一个设置）。只有导出页追加了页内动作（`ExportView.swift:171`）。`GalleryToolbar.swift:9`、`SimilarityView+Toolbar.swift:9`、`SessionControlView+Toolbar.swift:9`、`FaceKeywordingToolbar.swift:9` 是同一段代码换了个 help 文案。

后果：**页面级「开始分析 / 开始写回 / 开始导出」这类主行动没有统一的可达位置**——它们分散在正文的不同分区里，位置随页面而变；用户切页签后要重新找。工具栏只剩下「同步状态 + 刷新」，而刷新在 6 个页面里都叫「刷新」，语义却不同（重载工作台 / 重载相似度 / 重载状态）。

### M2 · 反馈通道四分五裂
同一件事（操作失败/成功）在不同页面走不同通道：

| 通道 | 实现 | 用量 | 典型调用点 |
| --- | --- | --- | --- |
| 页内横幅 | `NativeBanner` | 28 | `DashboardView.swift:80`、`CullingView+Content.swift:14` |
| 全局浮层 | `GatherToastCenter` | 21 | `RootShellOverlay.swift:43/59/77/89`、`PersonsView.swift:376` |
| 页内 notice | `CullingNotice` / `SessionControl` notice | — | `CullingView+Content.swift:20` |
| 系统弹窗 | `alert` 4 / `confirmationDialog` 13 | 17 | 各破坏性动作 |

Person 库「创建/删除成功」走 toast（`PersonsView.swift:663/547`），工作台「操作失败」走 banner（`DashboardView.swift:80`），导入失败走 toast 但带「重试」按钮（`RootShellOverlay.swift:77`）。用户无法形成「结果会出现在哪」的稳定预期。

**并且存在一个 P1 级实现缺陷**：`ToastView` 的容器写了 `.allowsHitTesting(false)`（`GatherToast.swift:126`），子按钮再写 `.allowsHitTesting(true)`（:156/:164）。SwiftUI 的 hit-testing 是自上而下收敛的，祖先关闭后子节点无法重新开启——**右上角 toast 的「重试」和「×」按钮点了不会有反应**，只能等 5s 自动消失（`GatherToast.swift:86-91`）。这直接影响导入失败后唯一的恢复入口。待实机点一下确认。

### M3 · 「为什么不能点」只在挑片页被解释
统计每模块 `.disabled(` 与 `.help(` 的配对：

| 模块 | disabled | help | 比例 |
| --- | --- | --- | --- |
| Culling | 47 | 47 | 1:1（每个禁用控件都有理由提示）✅ |
| Metadata | 11 | 0 | 0:11 ❌ |
| Settings | 12 | 3 | 1:4 ⚠️ |
| Export | 7 | 3 | 1:2 ⚠️ |
| Library | 13 | 11 | 接近 |
| Persons | 5 | 6 | 接近 |

挑片页的做法是对的（禁用 + tooltip 说明原因），但**没有成为全应用约定**。元数据编辑器 11 处禁用、0 处提示，用户只能靠猜。

### M4 · 三种「页面范式」并存，公式化程度不均
- `gatherPage`（工作台/全局图库/人脸库/设置）+ `GatherSessionPage`（7 页）= **10 个页面已有统一骨架**；
- 但只有 **3 个页面**用右侧 `.inspector`（挑片/浏览/全局图库），其余 4 个会话页把控制项平铺在正文；
- 空态组件两套并行：`GatherEmptyState` 3 处 vs 裸 `ContentUnavailableView` 30 处（正是门禁基线里 `empty.contentUnavailable: 30` 那条，说明「统一空态」只完成了示范，没有完成收口）；
- 设计系统门禁仍在带债运行：`font.callout 89` / `literalPadding 175` / `literalSpacing 257` / `legacyAlias 15+15`（`scripts/design-system-baseline.json`）。

### M5 · 键盘可达性薄，且集中在两页
全 UI 仅 **30 处 `keyboardShortcut`**，其中 `.defaultAction/.cancelAction` 占 11 处（对话框按钮）。真正的命令键 ≈ 9 个：`⌘[`（返回）、`⌘R`（3 页）、`⌘K`（关键词）、`⌘- ⌘0 ⌘=`（查看器缩放）、`⌘⇧N`（新建人物）、`Esc`（灯箱/关键词面板）、`⌘Z/⇧⌘Z`（仅挑片页接管）。

裸键（↑↓←→、Space、P/X、1-5）依赖 `.onKeyPress + .focusable` 挂在网格/查看器上（`CullingGrid.swift:229-231`、`GalleryGrid.swift:50-60`、`CullingWorkbenchViewer.swift:148-155`）。这类实现的固有问题是**焦点一走键就失效**：点过右侧检查器的输入框后，↑↓ 与 P/X 是否还生效，需要实机验证；若失效，这是挑片效率的硬伤（挑片是键盘密集型工作流）。

**全局缺口**：无 `⌘F` 搜索（只有人脸库用了 `.searchable`，`PersonsView.swift:76`）、无 `⌘1…7` 切页签、无 `⌘,` 之外的偏好入口（系统设置窗口已具备）、无「下一个/上一个工作区」导航键。

---

## 3. 前端显示的宏观观察

### 3.1 窗口 chrome 预算已经很紧
`GatherChromeMetrics`：窗口 860 + 侧栏 180 + 内容最小 680。会话页在内容区还要减去页签行最小 61 与检查器 220（`CullingView.swift:152` 用 `ideal: 220` 正是为了避免约束循环）。**860 − 180 = 680；680 − 220（检查器）= 460**，页签条阈值 620（`GatherSessionPage.swift:116`）在检查器打开时必然退化成下拉菜单。

含义：最小窗口 + 检查器打开时，用户失去「一眼看到 7 个页签」的能力。这不是 bug，是预算的必然结果；但**它决定了任何新增一条横向 chrome 都会触发布局事故**（代码注释里 N01 的约束循环教训即此类）。

### 3.2 会话页内仍有 2–4 条横向 chrome
以挑片页为例（`CullingView.swift:90-153` + `CullingToolbar.swift:22-32` + `CullingFilterControls`）：

```text
窗口 toolbar（C1 胶囊 + 刷新）
页签条 40pt
动作条（撤销/范围/自动前进/布局/同步/筛选/质量分析）
筛选条（仅未处理·状态·星级·颜色·质量·XMP 冲突）
查看器（信息条 + 导航条）
胶片条（标题 + 卡片 + 加载更多）
```

943pt 高的窗口里，正文被压到 ~430pt。挑片页的信息密度是对的（专业工具就该密），但**「三条横条 + 一条胶片标题栏」在视觉上同权**：页签条、动作条、筛选条都用了接近同一种底与分隔线，缺少层级差（页签条 canvas、动作条 contentBackground、筛选条无底）。建议按「导航 / 模式 / 过滤」三层用底色或间距差区分。

### 3.3 现有截图已过期，不能作为现状依据
`docs/reviews/2026-10-23-acceptance-*.png` 是 10-23 的验收图。图中「分析技…」按钮被检查器边缘裁切的问题，当前代码已经用 `ViewThatFits` 修掉（`CullingToolbar.swift:25`）。**这些图不再代表 HEAD**；其中 `2026-10-23-acceptance-import.png` 甚至不是应用截图，而是一张包含个人聊天记录的桌面截图，**应在发布前删除**（隐私与仓库卫生）。

### 3.4 本地化体系是健康的，但有两处结构性风险
- en 表 1862 条、0 缺键、0 条残留中文（已扫）；zh 表留空 = 中文原文即 key，设计如此。
- 风险一：**42 处动态 key**（`l10n.errorText(code)` / `jobStatusText` / `jobTypeText` / `progressPhaseText` / `jobErrorMessage`）。这类映射不经过静态扫描，缺一条键就静默回退中文——而当前门禁 `check-docs.sh` 覆盖不到。
- 风险二：`NativeBanner` 用 `.accessibilityElement(children: .combine)`（`NativeBanner.swift:127`）把「关闭」按钮合成进文本元素，VoiceOver 读不到也点不到关闭。

### 3.5 无障碍是「有标注、缺语义」
106 处 `accessibilityLabel/Hint/Value`（其中 `accessibilityValue` 23、`accessibilityAddTraits` 8），对 242 个文件来说覆盖偏薄。挑片页签做了 `.isSelected` trait（`GatherSessionPage.swift:261`），是正确做法；但评分星标、照片张数、选中数量等**状态型信息**普遍没有 `accessibilityValue`，VoiceOver 用户读不出「这张照片 3 星、已保留」。

---

## 4. 跨模块的根因判断

1. **没有「页面动作槽」的概念**：`GatherSessionToolbar` 只收 C1/刷新/设置，页面动作靠各自往正文里塞 → 主行动位置不可预测（M1）。
2. **没有「操作结果」的统一模型**：成功/失败/部分失败/可重试，各页各写一套 → 反馈通道分裂（M2）。
3. **设计系统只到「叶子」没到「配方」**：卡片/文字/空态有了，但「页面级横向 chrome 的层级」「禁用态的理由」「状态型语义」还没成为配方 → 于是 89 处 font.callout 与 30 处裸空态成为基线债务（M3/M4）。
4. **生命周期收口了，焦点与键盘没有**：可见性做到了页面级，但键盘焦点仍按视图挂 `.onKeyPress`，两套模型各自演化（M5）。

---

---

## 6. 跨页一致性抽查（人工核对，均为当前 HEAD 代码）

| # | 不一致点 | 证据 | 影响 |
| --- | --- | --- | --- |
| C1 | 搜索入口三种形态 | Gallery `GatherSearchField`（`GalleryView+Content.swift:57`）、Library `GatherSearchField`（`LibraryView+Filters.swift:43`）、Persons `.searchable`（`PersonsView.swift:76`） | 同样是"搜索"，一个在内容区、一个在工具栏；而设计文档明文规定"不要用 `.searchable(placement: .toolbar)`"（`docs/design/appearance-interaction.md` §3.5）——Persons 的例外没有记账，文档与代码已脱节 |
| C2 | 删除/危险动作的确认形态 | 13 个 `confirmationDialog` + 4 个 `alert`；人脸页把 **9 个** `.gatherDestructiveConfirm` 串在同一条 modifier 链上（`FaceKeywordingView+Confirmations.swift:159-240`），相似度页 4 个（`SimilarityView.swift:116-140`） | SwiftUI 对"同一视图上挂多个 `confirmationDialog`"的行为不可靠（后者抢占前者）。9 连挂时，只要有一个不弹，用户会认为按钮坏了。**已知 P2，但风险等级被低估** |
| C3 | 检查器首屏重复标签 | `GatherInspectorSection(l10n("当前照片"))` 内又渲染一次 `Text(l10n("当前照片"))`（`CullingInspector.swift:40` 与 `:42`，仅未多选时） | 首屏第一眼就是"当前照片 / 当前照片"两行，纯噪声 |
| C4 | 重启不恢复现场 | 全 UI 仅 5 个 `@SceneStorage`（挑片布局/密度/排序 + 3 处检查器可见性），路由 `AppRoute` 存内存 | 关掉再开永远回到工作台；对"连续几天挑同一批片"的用法是每天重新导航一次 |
| C5 | 工作台没有会话搜索 | `DashboardView` 列表无搜索；侧栏只显示最近 5 个 | 工作区 >10 个时只能靠滚动找 |
| C6 | 单文件体量差异 | Persons 680 行 UI 单文件（列表+详情+表单），其余模块都已拆分（挑片 30 文件） | 该模块后续改动成本与冲突概率显著高于其他页 |
| C7 | 动效克制但有一处漏 reduceMotion | 全 UI 仅 5 处 `withAnimation` + 7 处 `.animation`；`CullingGrid.swift:221` 未判断 `reduceMotion` | 整体没问题，单点补齐即可 |

### 补充观察：会话页"三条横条"的层级问题（视觉）

页签条（`GatherSessionPage.swift:127-129`，canvas 底）、挑片动作条（`CullingToolbar.swift:30`，contentBackground 底 + 底部 Divider）、筛选条（无底）三者视觉权重接近，但语义层级是「导航 → 模式 → 过滤」。建议给动作条与筛选条之间加 8–12pt 留白或让筛选条退成 `surfaceMuted`，用"底色梯度"而不是"再加一条分割线"来表达层级。

## 5. 建议的优先级（宏观层）

| 级别 | 事项 | 成本 |
| --- | --- | --- |
| P0 | 修 toast hit-testing（去掉容器 `.allowsHitTesting(false)`，改由容器自身尺寸不拦截）→ 恢复导入失败重试入口 | 0.5h |
| P1 | 建立「页面动作槽」：`GatherSessionPage` 增加 actions 参数，7 页主行动上到页签行右侧或工具栏第二组 | 1–2d |
| P1 | 统一反馈：定义 `OperationOutcome`（成功/失败/可重试/部分失败）+ 一个渲染出口（页内 banner 优先，toast 仅作跨页/后台事件） | 1–2d |
| P1 | 禁用态理由：给 `.disabled` 加统一修饰符 `.disabled(reason:)`（内部落 `.help` + a11y hint），先清 Metadata/Settings/Export 的 0 提示 | 1d |
| P2 | 键盘：补 `⌘F`（全局/页内搜索）、`⌘1…7`、`⌥↑↓` 工作区切换；把裸键从 `.onKeyPress` 提升到 focused-scope 命令 | 2–3d |
| P2 | 空态收口：把 30 处裸 `ContentUnavailableView` 逐页替换为 `GatherEmptyState`（同步下调基线） | 2d |
| P2 | 重启恢复：`AppRoute` 落 `@SceneStorage`，恢复上次会话与页签 | 0.5d |
