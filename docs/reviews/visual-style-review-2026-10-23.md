# Gather 样式设计评审与优化方案（2026-10-23）

- 评审角色：独立样式 / 视觉设计评审（只读代码与现有截图；唯一写入本文件）
- 仓库：Gather（工作区未提交）
- 时间：2026-10-23
- 范围：`GatherUI` 主题层、共享组件、窗口 chrome、11 个页面与 3 个检查器
- 口径：只写静态可复核证据；本机无 GUI 自动化，不声称完成逐页视觉 / 交互验收
- 约定：`UI/` = `desktop/native/gather-app/Sources/GatherUI`，`HOST/` = `desktop/native/gather-app/Sources/GatherHost`；行号按当前工作区 HEAD

> **落地状态（2026-10-23）**：本文的 P0 与大部分 P1 已完成第一轮实现：三层表面（canvas / surface / surfaceMuted / hairline）、状态文字安全变体、`GatherCard` 表面与阴影、`GatherBadge` 实心胶囊、`PhotoOverlayChip`、`GatherFont` / `GatherMetrics`、Dashboard 首屏、Library / Persons 空态、Culling 胶片条折叠与筛选入检查器、会话页返回按钮移入内容页签行（去掉 macOS 26/27 的 titlebar + 工具栏双行）、检查器标题/间距/表面统一（Culling 保留系统 GroupBox）、Similarity 居中、状态色正文替换。`swift build` 通过；`swift test --no-parallel` 626/626 通过；Dashboard / Gallery / 侧栏三态已截图核验，其余页面以构建 + 代码审查为准，需真机逐页复核。
>
> **实施取舍**：品牌 tint 从根视图移到内容区（侧栏跟随系统强调色）；自定义选中仍用品牌色；状态徽标改为实心 surface + 语义圆点（压在照片上也保持可读）。这与下文 §6.5 的“选择交给系统”不完全相同，是有意的品牌优先选择。
>
> **第二轮（工作台重做）**：工作台空库改为顶部对齐的 hero（产品预览 + 单一主 CTA）+ 三张快捷卡；侧栏先做了“工作区 / 图库”分组并收窄到 220pt；全局卡片圆角统一为 6 / 8 / 12 / 16 / 24 五级。
>
> **第三轮（侧栏重做，2026-10-23）**：否决“当前会话”单条，侧栏改为“工作台置顶 + 最近 5 个工作区 + 资料库”。数据由 `DashboardViewModel.refreshSidebarSessions()` 提供：工作台自身 `loadAll`，从深链/图库/会话页启动时外壳补一次轻量 `listSessions`，导入完成再刷新；失败保留旧列表。当前会话提前到首位；选中当前会话不重新导航；深链时用 `SessionStore` 名称做回退行；长名称单行截断 + 照片数 + help。已截图验收：0 会话、6 会话（最近 5 + 长名称截断）、选中会话（深链加载 + 选中态）。
>
> **第四轮（全量视觉 QA 修复）**：挑片工具栏改为 `ViewThatFits` 完整/紧凑两档，默认窗口不再裁切「分析技术质量」；侧栏重名会话补短 id 次行；图库单张照片限制在 480×360 内，不再被 justified 拉成巨幅卡；设置窗口加 `containerBackground` 消除 inactive 玻璃后的鬼影，数字字段加可见边框、队列计数收紧；相似度/人脸/重复控制卡限宽 760；导出页补「导出设置」页头；全局图库筛选条收进 surface 卡；人脸库空态改为 24pt 圆角卡；人脸步骤左对齐；图库 caption 渐变减淡。`swift test --no-parallel` 626/626 通过；最终 12 页批量截图已复核，挑片工具栏裁切、侧栏重名、单张图库巨幅卡、设置窗口鬼影、分析卡过宽、筛选条松散与空态过小均已消失。
>
> **关键运行发现**：此前开发构建的 Mach-O LC_BUILD_VERSION.sdk 是 **14.0**，AppKit 会强制旧外观（不透明侧栏、矩形工具栏、无 Liquid Glass）。用 GATHER_SDK_VERSION=27.0 重新链接后，系统侧栏 / 工具栏 / 按钮才进入 macOS 26/27 的 Liquid Glass 外观。发布脚本会自动探测 SDK；现在 Package.swift 也按 SDKROOT → xcrun → 14.0 的顺序自动探测，已用不设环境变量的 swift build 验证 Mach-O 记录为 sdk 27.0。GATHER_SDK_VERSION 仍可显式覆盖。
>
> **设计依据**：[HIG Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)（两级分组、图标跟随 accent、避免底部关键动作）、[HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)（标准组件、减少自定义底色、标题 < 15 字符）、[HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)（Liquid Glass 只用于功能层，内容层用标准材质）、[HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout)（按重要性排列、用容器/留白表达层级）、[HIG Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)（短、聚焦、可跳过）、[HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)（每屏 1–2 个 prominent、样式而非尺寸区分层级）。

---

## 0. 结论摘要

**工程骨架已经达到原生 macOS 应用的水准，但“皮肤”仍处在两套设计语言的过渡态。**

一方面，`NavigationSplitView`、`List(selection:)`、`.inspector`、`Form(.grouped)`、`ContentUnavailableView`、系统分段控件、系统材质与 Liquid Glass 的功能层边界都已经用对；另一方面，页面仍在大量使用“白色卡片 + 1px 描边 + 12pt 正文 + 状态色文字”的 Web Dashboard 语言，导致：

1. **卡片和页面同色**（实测 fill 1.00:1），卡片只剩一圈 1.25:1 的描边；
2. **状态色被当正文**（20+ 处），实测 1.97–3.57:1，浅色模式下不满足 WCAG AA；
3. **强调色语义分裂**：侧栏所有图标是品牌橙，系统选中色却是 `#0064E1`，自定义选中又有 4 种画法；
4. **排版和间距没有“角色”**：153/227 处字体调用是 `.callout`（12pt），19 种间距、4 种圆角、3 种检查器标题、卡片内边距 16/34/36 并存；
5. **页面容器不统一**：页面左右留白 16/20/24，卡片、GroupBox、Form 三种容器语言混用，挑片页 chrome 吃掉约一半可用高度。

### 评分（视觉完成度，非工程质量）

| 维度 | 判断 | 分数 |
| --- | --- | --- |
| 窗口 / 导航 / 工具栏 | 原生容器已就位，标题语义与工具项还不统一 | 7.5 / 10 |
| 表面 / 卡片 / 层级 | 卡片与页面同色，只有细描边；深色同样成立 | 3.5 / 10 |
| 品牌与强调色 | 暖橙有识别度，但与系统选中色冲突、在侧栏过度使用 | 5 / 10 |
| 状态语义 | 组件多、颜色当正文、对比度失败 | 3.5 / 10 |
| 排版 | 系统文本样式用对了，但 2/3 是 12pt，层级扁平 | 5 / 10 |
| 间距 / 圆角 / 节奏 | 19 种间距、4 种圆角、双内边距 | 3.5 / 10 |
| 组件一致性 | 有共享组件，但 5 种徽标、3 种检查器、4 种卡片 | 5 / 10 |
| 深色 / 高对比 | 语义色和查看器暗色好，卡片层次与徽标对比弱 | 6 / 10 |
| 可访问性 | 标签 / 提示较全，但对比度、焦点、颜色单通道不足 | 4.5 / 10 |
| 页面密度 | 图库 / 挑片密度高，工作台 / 空态过空 | 5 / 10 |

> **一句话**：不是“不好看”，而是**没有一套被执行的规则**。本报告的重点不是重画界面，而是把已经正确的原生骨架收拢成一套可检查的样式系统。

### 五个系统性根因

| # | 根因 | 一句话证据 |
| --- | --- | --- |
| R1 | 表面 token 没有层次 | `windowBackgroundColor` 与 `controlBackgroundColor` 在浅 / 深色下都完全相同（`#FFFFFF` / `#1E1E1E`） |
| R2 | 排版 / 间距没有角色 | 153/227 个字体调用是 `.callout`；19 种间距值；卡片内边距 16/34/36 |
| R3 | 强调色语义漂移 | 根视图 `.tint(accent)`；侧栏图标全橙；系统选中色 `#0064E1` |
| R4 | 状态色当正文 | 系统绿 / 橙 / 红在白底上只有 2.22 / 2.31 / 3.57:1 |
| R5 | 页面容器 / 密度不统一 | 页面留白 16/20/24；挑片页固定 chrome 约 326pt |

### 最小行动集（如果只做 5 件事）

1. **拆 token**：`accentText` / `accentFill` / `selection` / `canvas` / `surface` / `statusText` 六个角色，先不改页面。
2. **给卡片一个真实表面**：surface + 14% hairline + 浅色轻阴影；或者把页面分区改成扁平 `GatherSection`。
3. **状态徽标改中性文字**：主文字 + 语义圆点 / 图标 + 12% 底，彻底停止用状态色做正文。
4. **选中交给系统**：移除根 `.tint`；侧栏闲置图标降为 secondary；自定义选中用 `controlAccentColor`。
5. **挑片页减 chrome**：筛选行进检查器，胶片条 120pt + 可折叠，查看器拿回 ≥60% 高度。

---

## 1. 评审范围与方法

### 1.1 范围

| 组 | 文件 |
| --- | --- |
| 主题与基础 | `UI/Support/GatherTheme.swift`、`GatherCommonViews.swift`、`GatherBadge.swift`、`NativeBanner.swift`、`GatherGlass.swift`、`GatherToast.swift` |
| 窗口 chrome | `UI/Shell/RootView.swift`、`RootShellSidebar.swift`、`RootShellToolbar.swift`、`RootShellDetail.swift`、`RootShellWorkspace.swift`、`Support/SessionTabBar.swift` |
| 11 个页面 | Dashboard / Library / Gallery / Culling / Duplicates / FaceKeywording / Similarity / Export / Settings / Persons / SessionControl |
| 共享叶子 | `PhotoThumbnailView`、`C1StatusCapsule`、`SliderInputView`、`FaceClusterMontage`、`WritebackReportCard` |

### 1.2 方法

1. 读主题层、共享组件、窗口外壳与 11 个页面的视图代码，抽取所有颜色 / 字体 / 间距 / 圆角 / 阴影 / 动效调用。
2. 用 grep 做全量普查：字体调用、间距值、圆角、`.gatherCard`、`GroupBox`、`Form(.grouped)`、`ContentUnavailableView`、固定宽度、状态色前景、透明度、动画。
3. 用 AppKit 探针在当前 macOS 27 SDK 上取系统语义色与文本样式实际值（见 1.3 节）。
4. 用 WCAG 相对亮度公式计算主题色与状态的对比度（见 1.4 节）。
5. 目视检查 2026-10-23 验收截图，并与历史截图交叉验证布局模式。

### 1.3 AppKit 系统值（macOS 27，实测）

| Token | 浅色 | 深色 |
| --- | --- | --- |
| `windowBackgroundColor` | `#FFFFFF` | `#1E1E1E` |
| `controlBackgroundColor` | `#FFFFFF` | `#1E1E1E` |
| `underPageBackgroundColor` | `#F6F6F6` | `#282828` |
| `separatorColor` | 黑 10% | 白 10% |
| `secondaryLabelColor` | 黑 50% | 白 55% |
| `selectedContentBackgroundColor` | `#0064E1` | `#0059D1` |
| `systemGreen` | `#34C759` | `#30D158` |
| `systemRed` | `#FF383C` | `#FF4245` |
| `systemOrange` | `#FF8D28` | `#FF9230` |

文本样式实测：

| 样式 | 字号 |
| --- | --- |
| `.title3` | 15 |
| `.headline` | 13 |
| `.body` | 13 |
| `.callout` | 12 |
| `.subheadline` | 11 |
| `.footnote` | 10 |
| `.caption` | 10 |

> 这条表解释了两个“设计意图与实际不符”的点：`GatherBadge` 注释写“字号从 footnote(10pt) 提到 caption(11pt)”，但 macOS 的 `.caption` 是 **10pt**；`.callout` 也不是正文，而是比 `.body` 小一号的次级样式。

### 1.4 对比度实测（WCAG，normal text 需 4.5:1）

| 前景 / 背景 | 对比度 | 结论 |
| --- | --- | --- |
| `systemGreen` 文本 / 白底 | **2.22** | 不通过 |
| `systemOrange` 文本 / 白底 | **2.31** | 不通过 |
| `systemRed` 文本 / 白底 | **3.57** | 不通过 |
| `systemBlue` 文本 / 白底 | **4.02** | 不通过 |
| success 徽标文字 / 15% 绿色底 | **1.97** | 不通过 |
| warning 徽标文字 / 15% 橙色底 | **2.04** | 不通过 |
| error 徽标文字 / 15% 红色底 | **2.91** | 不通过 |
| info 徽标文字 / 15% 蓝色底 | **3.30** | 不通过 |
| 品牌橙 `#A54D2A` / 白底 | **5.68** | 通过 |
| 白字 / 品牌橙 `#A54D2A` | **5.68** | 通过 |
| 白字 / 深色品牌橙 `#D98964` | **2.72** | 不通过（深色模式主按钮风险） |
| 白字 / 主 CTA 深棕 `#7E3517` | **8.72** | 通过 |

### 1.5 截图证据与限制

最新截图：[2026-10-23 验收截图](2026-10-23-acceptance-workbench.png)（macOS 27，窗口 1180×780）。

可复核的目视结论：

- 工作台窗口标题是 “Gather”，侧栏选中的却是「工作台」；副标题是固定的营销句，不是状态信息。
- 五个统计值全部为 0，仍占据一条完整卡片；下方「暂无工作区」和「暂无后台任务」两个大空态各占一段首屏。
- 顶部统计卡与页面同为白色，只靠一圈极浅描边分界；卡片没有阴影或材质。
- 四个侧栏图标（工作台 / 全局图库 / 人脸库）都是品牌橙；选中行是中性灰，强调关系倒置。
- 标题栏与侧栏之间有一条硬水平接缝（标题栏 `#F0F0F0` 左右，侧栏 `#DEDEDE` 左右，内容 `#FFF`）。

**限制**：

- 本机没有可用的 GUI 自动化 / 辅助功能权限，本轮未重新构建运行 app；视觉判断来自上述截图与代码常量，**不声称逐页目视验收**。
- 历史截图（`docs/archive/reviews/assets/native*`）来自旧构建，只用于识别布局模式，不作为当前视觉证据。
- 标题栏接缝、窗口非活跃态的系统选中灰、以及 `.inspector` 内的 `.navigationTitle` 行为，需要在 macOS 14 / 15 / 26 上复测后再定性。

---

## 2. 做得对的地方（不要一起改掉）

1. **原生容器优先**：`NavigationSplitView` + `List(selection:).listStyle(.sidebar)`、`.inspector`、`Form(.grouped)`、系统分段 `Picker`、`ContentUnavailableView` 都是正确选择。
2. **语义色基线正确**：表面 / 分隔线 / 文字已经改用 AppKit 语义色，不再整页硬编码暖色；品牌色保留了高对比度四态变体。
3. **查看器暗色语言独立且合理**：`viewerBackground #0D0D0D`、`viewerSurface #1A1A1A`、`viewerTextPrimary 93%` 与照片内容分离，不再受浅 / 深色外观影响。
4. **Liquid Glass 边界判断正确**：只在 toast / 查看器缩放 / 浮动控件等功能层使用玻璃，卡片等内容层保持标准材质。
5. **错误漏斗一致**：`CommandErrorText` 把 API 散文挡在界面外，错误码在渲染期本地化，避免把英文诊断直接铺上屏。
6. **共享组件已有沉淀**：`GatherCard`、`GatherBadge`、`NativeBanner`、`GatherStatCard`、`WritebackReportCard`、`GatherProgressBar` 都有明确复用点。
7. **无障碍标签覆盖较广**：图库单元、胶片条、C1 胶囊、统计卡、空态、确认框大多有 label / value / hint；7 个文件使用 `accessibilityReduceMotion`。
8. **布局预算有单点常量**：`RootShellMetrics` 统一了窗口 / 侧栏 / 内容宽度的最小预算，避免测试与实现漂移。

---

## 3. P0：进入视觉验收前应修

### P0-1 卡片与页面同色：fill 1.00:1，只剩 1.25:1 描边

**位置**

- `UI/Support/GatherTheme.swift:30-36`：`windowBackground = .windowBackgroundColor`，`contentBackground = .controlBackgroundColor`。
- `UI/Support/GatherTheme.swift:134-149`：`gatherCard` 填充 `contentBackground` + 1px `separator`。
- 所有 `.gatherCard()` 调用点（ControlCenter 6、Similarity 6、Face 8、Duplicates 2、Dashboard / Library 各 1，外加两个检查器）。
- 截图：统计卡和页面都是白色，只有一圈浅灰边。

**证据**

AppKit 实测（1.3 节）：浅色 `windowBackground` 与 `controlBackground` 都是 `#FFFFFF`；深色都是 `#1E1E1E`。因此：

- 卡片与页面的 fill 对比度 **1.00:1**；
- 唯一分离是 `separatorColor` 10% 黑 / 白，对白底 **1.25:1**，对深底约 **1.20:1**；
- 卡片没有阴影，也没有材质。

历史视觉评审（2026-09-29）已经记录过同型问题：卡片 / 页面 1.06:1、描边 1.32:1，并建议改用语义表面或容器材质。当前改用语义色后，**fill 仍然相等**，说明 token 选择没有解决“卡片需要可辨识表面”的问题。

**影响**

- 卡片不“浮起”，页面读起来是一整块白；分组边界依赖极细描边，在低质量显示器 / 强环境光下会消失。
- 深色模式同样成立：卡片与页面都是 `#1E1E1E`，只剩 10% 白描边。
- 首屏统计卡、控制中心的 6 张卡、相似度的 6 张卡都失去层级，信息噪声增加而结构没有增加。

**方案（二选一，推荐 B 混合）**

**A. 保留卡片，但给它真实表面**

1. 增加表面 token（建议由 `GatherTheme` 暴露）：
   - `canvas`：页面底色，浅 `#F6F5F2` / 深 `#1B1B1D`；
   - `surface`：卡片，浅 `#FFFFFF` / 深 `#2A2A2C`；
   - `surfaceMuted`：嵌套面板，浅 `#EFEDE8` / 深 `#202022`；
   - `hairline`：描边，浅 14% 黑 / 深 12% 白。
2. 卡片 = `surface` + `hairline` + 仅浅色模式一层轻阴影（`0 1 3 / 8%`）。
3. 验收目标：卡片 / 画布 ≥ 1.15:1；描边 ≥ 1.4:1；浅色截图里能一眼看出卡片边界。

**B. 减少卡片，改成原生分区（推荐）**

不是所有内容都值得一张卡片。把「页面分区」和「可选对象」分开：

| 用途 | 推荐容器 | 说明 |
| --- | --- | --- |
| 页面分区（控制中心 / 相似度 / 重复页的配置块） | 扁平 `GatherSection` | 标题 + 分隔线 + 内容，不要边框；像 macOS 设置 / 检查器 |
| 可选对象（重复组、相似组、人脸簇） | `GatherCard` | 对象需要被整体选中 / 悬停，卡片有语义 |
| 检查器分区 | 系统 `GroupBox` | 系统列内不要再套自定义卡片 |
| 浮层（toast / 冲突面板） | 功能层玻璃 + 阴影 | 已经是正确用法 |

这样能同时解决“白卡片无边”和“卡片过多”的问题，也更接近 Capture One / Lightroom 的面板语言。

**代码草案**

```swift
// GatherTheme.swift
private static func dynamic(light: String, dark: String,
                            hcLight: String? = nil, hcDark: String? = nil) -> Color { ... }

public enum Surface {
    public static let canvas = GatherTheme.dynamic(light: "#F6F5F2", dark: "#1B1B1D",
                                                   hcLight: "#FFFFFF", hcDark: "#000000")
    public static let card = GatherTheme.dynamic(light: "#FFFFFF", dark: "#2A2A2C",
                                                 hcLight: "#FFFFFF", hcDark: "#1C1C1E")
    public static let hairline = GatherTheme.dynamic(light: "#00000024", dark: "#FFFFFF1F")
}
```

> `dynamic(light:dark:)` 当前是 `private`；要么把它提升为 `internal`，要么在 `GatherTheme` 内部定义表面。不要把 hex 直接写进页面。

**验收**

- 浅 / 深色截图里卡片边界可辨；不用放大也能看出分组。
- 卡片内文字对比度不下降；描边不抢正文。
- 若选 B：控制中心 / 相似度 / 重复页不再出现“6 张白卡叠白底”。

---

### P0-2 状态色当正文：对比度 1.97–3.57:1

**位置（文字，不是图标）**

- `UI/Support/GatherBadge.swift:42-49`：`.font(.caption.weight(.medium))` + `.foregroundStyle(tone.color)` + 15% 同色底。
- `UI/Culling/CullingInfoBar.swift:52-71`：保留 / 淘汰计数用 `success` / `error` 做正文；`linkedNotice` 用 `error` 做提示句。
- `UI/Culling/CullingConflictPanel.swift:38-51, 121-136`：冲突标题、原因、失败清单整段红色。
- `UI/Export/ExportView+Result.swift:15-22`：导出完成 / 错误明细。
- `UI/Export/ExportView+Range.swift:50-52`、`ExportView+Preview.swift:43-48, 60-63`。
- `UI/Settings/SettingsView+Model.swift:149-154`、`SettingsView+C1HealthSection.swift:61-65`。
- `UI/Dashboard/JobRowView.swift:70-77`、`UI/Persons/PersonsView.swift:410-415`、`UI/Duplicates/DuplicatesView.swift:88-93`。

全量普查：27 处 `foregroundStyle(statusColor)`，其中约 20 处是文字；其余是图标。

**证据**

| 用法 | 实测 |
| --- | --- |
| `GatherBadge(.success)` 文字 / 15% 绿底 | 1.97:1 |
| `GatherBadge(.warning)` 文字 / 15% 橙底 | 2.04:1 |
| `GatherBadge(.error)` 文字 / 15% 红底 | 2.91:1 |
| `GatherBadge(.info)` 文字 / 15% 蓝底 | 3.30:1 |
| `CullingInfoBar` 的 “保留 N” / systemGreen | 2.22:1 |
| `CullingInfoBar` 的 “淘汰 N” / systemRed | 3.57:1 |
| 导出结果 / systemGreen | 2.22:1 |

这和主题层自己的原则冲突：`GatherTheme.swift:4-8` 明确写“品牌色只做 accent”，而 `GatherCommonViews.swift:37-39` 也写了“状态色只出现在圆点上，数字始终用系统前景色”。`GatherBadge` 与多个页面没有遵守这条已经写下的规则。

**影响**

- 浅色模式下，成功 / 警告 / 信息类文字不满足 WCAG AA；系统绿和橙只有 2.2:1，远低于 4.5:1。
- 颜色还是唯一的状态通道：徽标没有图标 / 文字以外的形状区分，色弱用户会丢失语义。
- 同一类信息在不同页面有“彩色文字”“彩色图标 + 主文字”“彩色圆点 + 主文字”三种画法，视觉上不统一。

**方案**

1. **徽标默认改为中性文字 + 语义圆点 / 图标**：

```swift
struct GatherStatusBadge: View {
    let text: String
    let tone: GatherTone

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))   // 11pt，不再是 10pt
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.20)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
```

2. **行内计数**用 `GatherCount`：彩色圆点 / SF Symbol + `Color.primary` 数字，不要给数字上色。
3. **确实需要彩色文字**的地方（例如表单行内错误）使用“文字安全变体”，不要复用填充色：

| Token | 浅色 | 深色 | 对比度 |
| --- | --- | --- | --- |
| `successText` | `#1E7B36` | `#6EE7A0` | 5.33 / 10.80 |
| `warningText` | `#8A5A1F` | `#E5B27B` | 5.89 / 8.72 |
| `errorText` | `#B3261E` | `#FF9C96` | 6.54 / 8.29 |
| `infoText` | `#0060C9` | `#6FB3FF` | 5.97 / 7.60 |

4. 破坏性按钮用 `role: .destructive` 让系统着色；不要额外 `.foregroundStyle(error)`（Persons 的删除按钮是重复着色）。
5. `CullingInfoBar` 的“同名 RAW/JPEG 共用 XMP”是**提示**不是错误：改成 `NativeBanner` 或 `warningText`，不要用 `error`。

**验收**

- 新增 `ThemeContrastTests`（或 Node 脚本）对每个“文字 token × 表面 token”断言 ≥ 4.5:1；状态徽标按实际 12% 底计算。
- 浅 / 深 / 高对比三态截图；所有状态文字可读。
- 代码普查中不再出现 `Text(...).foregroundStyle(GatherTheme.success/error/warning/info)`；图标用法保留并加注释。

---

### P0-3 挑片页 chrome 挤压查看器：核心工作区只剩约一半高度

**位置**

- `UI/Culling/CullingWorkbench.swift:20-69`：工具栏 → 查看器 + infoBar → 胶片条的纵向堆叠。
- `UI/Culling/CullingToolbar.swift:23-176`：两行固定工具栏，每行 `.padding(.vertical, 6)`。
- `UI/Culling/CullingFilmstrip.swift:76-81`：固定 `height: 176`。
- `UI/Culling/CullingInfoBar.swift:141-145`：`.frame(minHeight: 36)`。
- `UI/Support/SessionTabBar.swift:139-141`：页签行 `.padding(.vertical, 8)`。
- `UI/Culling/CullingWorkbenchViewer.swift:102-111`：查看器顶部还常驻一条操作提示胶囊。

**估算（按代码常量，标题栏按 52pt 估）**

| 项 | 高度 |
| --- | --- |
| 页签行 | 40 |
| 工具栏两行 | 72 |
| infoBar | 36 |
| 胶片条 | 176 |
| 分隔线 | ~4 |
| 合计 chrome | **~328** |

默认窗口 1180×780，内容区约 728：查看器只剩约 **400pt**（55%）。最小窗口内容高 560 时，查看器只剩约 **232pt**（41%）。这还没有算查看器顶部提示胶囊和内边距。

**影响**

- 挑片是这个 app 的核心工作流，但在默认窗口里照片只能占一半高度；最小窗口下几乎不可用。
- 胶片条 176pt 是固定值，不随窗口高度收缩；缩略图 180×122，比常见的 96–120pt 胶片条大一圈。
- 两行工具栏 + 可横向滚动的筛选行 + 可横向滚动的 infoBar，让顶部像 Web 工具条，而不是原生挑片器的紧凑 chrome。
- 查看器顶部常驻“100% 滚轮缩放 · 拖动平移 · 双击复位 · ⌘−/⌘= 缩放”提示，长期压在照片上，抢注意力。

**方案**

1. **把筛选行移进右侧检查器**：`CullingInspector` 已经存在，增加「筛选」`GroupBox`；工具栏只保留撤销/重做、范围、自动前进、对比、质量分析。页面工具栏高度从 72 降到 36。
2. **胶片条自适应**：
   - 默认高度 120–132pt（缩略图 96–104pt 高）；
   - 增加折叠按钮 / 快捷键，`.frame(height: expanded ? 132 : 0)`；
   - 根据可用高度自动折叠：`GeometryReader` 或 `.onGeometryChange` 在 `height < 640` 时收起；不要用固定 176。
3. **合并 infoBar 与 C1 胶囊的同步状态**：工具栏胶囊已经显示写回队列；infoBar 不要重复整句“已写入待确认”。infoBar 只保留位置计数 + 保留/淘汰/未处理 + 同步菜单入口。
4. **提示胶囊改为瞬时 / 按需**：只显示缩放百分比；操作说明放进 infoBar 的提示或首次进入的 onboarding，不要在照片上常驻一整句。
5. **保留现有的横向滚动兜底**：代码里多处注释说明 `ScrollView(.horizontal)` 是为了避免 860pt 窗口下的约束循环；重构时不要把这些兜底删掉，改用 `ViewThatFits` / 折叠菜单也要保持最小宽度可控。

**验收**

- 1180×780：查看器 ≥ 60% 内容高；860×560：≥ 50%（胶片条自动折叠时）。
- 860×560 下不出现 “more Update Constraints in Window passes…” 崩溃。
- 挑片页顶部不再有横向滚动条；筛选入口在检查器里可达。
- 截图：单图 / 2 图 / 4 图三种对比模式，胶片条展开 / 折叠。

---

## 4. P1：明显不一致，影响专业观感

### P1-1 强调色与选中色分裂：品牌橙 vs 系统蓝

**位置**

- `UI/Shell/RootView.swift:113`：根视图 `.tint(GatherTheme.accent)`。
- `UI/Shell/RootShellSidebar.swift:22-45`：`Label` 没有显式颜色，继承 tint；截图四个图标全橙。
- `UI/Support/GatherTheme.swift:25`：`selectionFill = accent.opacity(0.16)`（品牌橙）。
- `UI/Gallery/GalleryCellView.swift:76-81`：选中描边用 `selectedContentBackgroundColor`（系统蓝）。
- `UI/Gallery/GalleryView+Content.swift:224-227`：整条选中栏用系统蓝 + 白字。
- `UI/Culling/CullingFilmstrip.swift:103-107`：当前 / 多选用品牌橙描边。
- `UI/FaceKeywording/FaceClusterCard.swift:32-41`：选中用品牌橙 16% 填充 + 2px 描边。
- `UI/Similarity/SimilarityGroupCardView.swift:122-126`：选中用品牌橙描边。

AppKit 实测：`selectedContentBackgroundColor` 是 `#0064E1`（浅）/ `#0059D1`（深），不是品牌橙 `#A54D2A` / `#D98964`。

**影响**

- 同一个“选中”语义出现 5 种画法：系统列表蓝底、系统蓝描边 + 勾、品牌橙描边、品牌橙淡底 + 描边、灰色多选。
- 侧栏所有图标都是强调橙，真正的强调（选中）却是中性灰 / 系统蓝——强调关系倒置。
- 用户改系统强调色（石墨 / 紫 / 黄）后，列表选中与图库选中会一起变化，但品牌橙不会；同一个页面可能出现两种“主色”。
- 深色模式下，品牌橙 `#D98964` 作为主按钮填充 + 白字只有 **2.72:1**，是一个潜在的可读性风险（取决于 `.glassProminent` 实际选的前景色）。

**方案：选择交给系统，行动留给品牌**

1. **根视图去掉 `.tint(GatherTheme.accent)`**；只在主动作按钮上局部 tint。
2. 增加两个角色，不要复用同一个 `accent`：
   - `accentFill`：填充按钮 / 品牌块，配 `onAccent = .white`；浅色用 `#A54D2A`（5.68:1），深色仍用 `#A54D2A` 或一个白字 ≥4.5:1 的深橙；
   - `accentText`：品牌色文字 / 星标，浅 `#A54D2A`、深 `#D98964`。
3. **选中色统一为系统强调色**：
   ```swift
   public static let selection = Color(nsColor: .controlAccentColor)
   public static let selectionFill = selection.opacity(0.14)
   ```
   替换 `selectionFill` 的品牌橙；Gallery 选中栏 / 描边、胶片条当前 / 多选、簇卡片、相似组卡片全部改用 `selection` / `selectionFill`。系统列表选中保持不动，三种自定义选中与系统列表一致。
4. **侧栏闲置图标显式降为次级色**：
   ```swift
   Label(copy.workbench, systemImage: "house")
       .foregroundStyle(.secondary)
   ```
   选中态由系统负责；品牌橙只出现在主 CTA、星标、品牌标识。
5. **主按钮**：`gatherPrimaryActionButton()` 内部加 `.tint(GatherTheme.accentFill)`，不再依赖根 tint。
6. 如果产品坚持“品牌橙就是选中色”，那就必须把所有自定义选中改成品牌橙，并接受系统列表仍是用户强调色；这会制造更大的分裂，**不推荐**。

**验收**

- 系统强调色设为蓝 / 石墨 / 紫三种，侧栏、图库、胶片条、簇卡片、相似组的选中色一致。
- 侧栏闲置图标不再是品牌橙；选中行才有强调。
- 浅 / 深色主按钮文字对比度 ≥ 4.5:1。
- 全仓只有一处 `.tint(GatherTheme.accentFill)`（或明确的品牌作用域），没有根 tint。

---

### P1-2 排版层级扁平，且 2/3 的文字是 12pt

**位置 / 计数**

- 全 UI 字体调用 227 处；`.callout` **153 处（约 68%）**，`.headline` 19，`.title3.weight(.semibold)` 10，`.footnote` 10，`.caption` 5。
- `.callout` 是 12pt，而 macOS 正文是 `.body` 13pt；大量主内容（文件名、计数、说明、错误）落在 12pt。
- 10pt `.caption` / `.footnote` 仍用于：`GatherBadge`（10pt）、任务类型、日期、部分说明。
- 卡片标题两套：ControlCenter / Face 用 `.title3.weight(.semibold)`（15），Similarity / Duplicates / Dashboard 用 `.headline`（13）。
- 数字字号三套：`.title3`（15）、`.title2`（17）、`.title`（22，仅 Face 蒙太奇空态）。
- `GatherBadge` 注释声称 `.caption` 是 11pt，实际是 10pt（1.3 节）。

**影响**

- 正文和次级信息只差 1pt，扫读时层级主要靠颜色和字重；一屏里“标题 / 正文 / 说明”几乎同号。
- 中文在 10–12pt 下的字形复杂度高于拉丁文；10pt 徽标、10pt 日期、10pt 任务类型在 Retina 上勉强可读，在低分屏 / 大字号设置下明显吃力。
- 同一种“卡片标题”在不同页面差 2pt，页面之间像不同产品。

**方案**

建立“文字角色”表，页面只允许使用角色，不允许随手选样式：

| 角色 | 样式 | 用途 |
| --- | --- | --- |
| 弹层标题 | `.title2.weight(.semibold)`（17） | sheet / dialog 标题；页面标题交给窗口 chrome |
| 详情标题 | `.title2.weight(.semibold)` | 人物名、详情页主标题 |
| 页面分区标题 | `.title3.weight(.semibold)`（15） | 控制中心卡片、相似度 / 重复页分区、设置分区 |
| 子分区标题 | `.headline`（13 semibold） | 检查器分区、卡片内二级标题 |
| 正文 | `.body`（13） | 文件名、描述、说明、错误正文 |
| 次级正文 | `.callout`（12） | 元数据、时间、辅助说明；不承载主信息 |
| 徽标 / 密集标签 | `.subheadline.weight(.medium)`（11） | 徽标、状态、紧凑行；中文不再低于 11 |
| 数字 | `.title2.monospacedDigit()` / `.callout.monospacedDigit()` | 统计 / 行内计数；全部等宽 |

配套规则：

1. `.caption`（10pt）只用于图标旁的单位、极短英文 token；中文句子禁止 10pt。
2. 徽标从 `.caption` 提到 `.subheadline`；同屏徽标不再低于 11pt。
3. 页面级分区标题统一 `.title3`；检查器 / 卡片内二级统一 `.headline`。Dashboard 的 List Section header 可以继续用 `.headline`（系统 List 语义），但同一页不要同时出现 13 / 15 两种“同级标题”。
4. 主内容从 `.callout` 升到 `.body`：文件名、说明、错误正文；只有元数据 / 时间 / 提示保留 `.callout`。
5. 长中文段落加 `.lineSpacing(2)`；不要靠缩小字号来塞内容。

**验收**

- `.callout` 占字体调用比例从 68% 降到 < 45%；主内容使用 `.body`。
- 10pt 中文句子为 0；徽标 ≥11pt。
- 页面分区标题只有 `.title3`，子分区只有 `.headline`。
- 截图：中文 / 英文、100% / 最大文字大小下，标题与正文层级仍清楚。

---

### P1-3 间距、圆角、卡片内边距没有阶梯

**计数**

- `.padding` / `spacing` 的数字有 **19 种**：1, 2, 3, 4, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 24, 40, 48, 52, 60。
- 圆角 4 种：4, 6, 8, 10；主题还有 `Radius.group 10 / panel 8 / sm 6 / md 8`，其中 `md` 0 使用、`sm` 1 使用。
- 页面左右留白：**16**（Dashboard / Library / Export / Persons 的横幅）、**20**（Gallery 索引头 / 选择栏 / 灯箱）、**24**（ControlCenter / Culling / Library 网格 / Duplicates）。
- 页面纵向堆叠：**14**（Duplicate / Face）、**16**（Similarity）、**18**（ControlCenter）。
- 卡片内边距：`gatherCard` 自带 16；Face 分析卡再 `.padding(18)` → **34**；Face 写回卡 `.padding(18)` / 空预览 `.padding(.vertical, 20)` → **34 / 36**；其他卡片 16。
- 检查器内边距统一 14，但卡片 `gatherCard` 再 16 → 30。

**影响**

- 页面边缘不齐：图表 / 网格从 24 开始，错误横幅从 16 开始，Gallery 索引头从 20 开始；同一列内容有 4–8pt 的视觉错位。
- 卡片内文字离边框忽远忽近；Face 页的卡片明显比 ControlCenter 松。
- 19 种间距让“紧凑 / 宽松”变成局部手感，无法通过一个 token 调整整体密度。

**方案**

采用 4pt 基准 + 少量光学值，并明确“只允许在哪个层级用”：

```swift
enum Space {
    static let xxs: CGFloat = 2    // 图标与文字、徽标内
    static let xs:  CGFloat = 4    // 行内元素
    static let s:   CGFloat = 8    // 行间距、控件组
    static let m:   CGFloat = 12   // 卡片内小节
    static let l:   CGFloat = 16   // 卡片内边距、卡片间距
    static let xl:  CGFloat = 24   // 页面留白、分区间距
    static let xxl: CGFloat = 32   // 大分区
    static let xxxl:CGFloat = 48   // 首屏 hero / 空态
}
```

映射规则：

| 现状 | 新值 |
| --- | --- |
| 14（检查器 / 堆叠） | 12 或 16 |
| 18（卡片外再 padding） | 删除；用 `GatherCard(padding: 16)` |
| 20（页面 / 卡片） | 16 或 24 |
| 40 / 52 / 60（查看器 / 空态） | 32 / 48 |
| 页面左右 16/20/24 | 统一 24 |
| 卡片内 16/34/36 | 统一 16（需要更大时显式 `padding: 20`，只允许一个来源） |

圆角：

| 角色 | 值 |
| --- | --- |
| 缩略图 / 照片 / 小控件 | 6 |
| 卡片 / 分组容器 | 10 |
| 浮层 / sheet / toast | 12 |
| Capsule | 系统形状 |

删除 `Radius.sm` / `md` 的兼容映射；把 4 → 6、8（成员卡）→ 10、10（Gallery 单元）保留为 card 10。

**实现要点**

```swift
struct GatherCard<Content: View>: View {
    var padding: CGFloat = Space.l
    var radius: CGFloat = Radius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.background, in: .rect(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Surface.hairline) }
    }
}
```

> 现有 `gatherCard()` 是 `View` 扩展并固定 16；短期可以先加 `padding:` 参数，再逐步把调用点的 `.padding(18)` 删掉。

**验收**

- 页面 / 卡片层只允许 `Space` 常量；grep 不再出现 14 / 18 / 20 / 40 / 52 / 60（允许在 `GatherTheme` / `GatherMetrics` 内定义）。
- 卡片内边距只有 16（或显式 20），Face 页不再 34 / 36。
- 圆角只有 6 / 10 / 12。
- 截图：同一列的元素左边缘对齐。

---

### P1-4 容器语言分裂：卡片 / GroupBox / Form，检查器三套

**位置**

- `gatherCard`：ControlCenter 6、Similarity 6、Face 8、Duplicates 2、Dashboard / Library 各 1，外加两个检查器。
- `GroupBox`：只在 `CullingInspector`（4 组）。
- `Form(.grouped)`：Export、Settings、Persons 详情、NewSession、CreatePerson。
- 检查器标题：Gallery `.headline`；Library `Label + .headline`；Culling `.callout.weight(.semibold)` + secondary。
- 检查器 padding：Gallery 14 + 16、Library 14 + 16、Culling 14 + GroupBox 默认。

**影响**

- 同样是“检查器里的一组选项”，Culling 用系统 GroupBox，Gallery / Library 用自定义卡片；视觉上像两个 app。
- 同样是“页面分区”，ControlCenter 用 6 张卡片，Settings 用系统 Form 分组，Duplicates 用卡片 + 裸文本；用户无法从外观判断“这是可点对象还是一段配置”。
- Gallery / Library 检查器里的卡片在系统 inspector 的材质底上又加一层白卡，层次过度。

**方案**

固定四种容器语义（见 P0-1 的表）：

1. **`GatherSection`**：页面级分区。标题（15 semibold）+ 可选副标题 + 可选尾部动作 + 内容 + `Divider`。用于 ControlCenter、Similarity、Duplicates、Face 的配置块。没有边框 / 白底。
2. **`GatherCard`**：可整体选中的对象（重复组、相似组、人脸簇、Dashboard 统计、浮层）。有表面 + 描边 + 10 圆角。
3. **`GatherInspectorSection`**：检查器分区。基于系统 `GroupBox` 的标题 + 内容，padding 统一 14；不再套自定义卡片。三个检查器全部改用它。
4. **`gatherFunctionalSurface`**：浮层（toast、查看器控制、冲突面板），已有实现保留。

同时统一检查器：

- 标题：`Label(title, systemImage: icon)` + `.font(.headline)`；不再三种字号。
- 内容间距：`Space.m`（12）。
- 空文本：用 `.foregroundStyle(.secondary)` + `.font(.callout)`；不要一会儿 `.callout`、一会儿默认 `.body`。
- 检查器里禁止 `Form(.grouped)`（已有崩溃记录）。

**验收**

- 三个检查器截图并排，标题字号、间距、容器一致。
- ControlCenter / Similarity / Duplicates 的页面分区不再全部是“白卡”。
- `GroupBox` 只出现在检查器；`gatherCard` 只用于对象 / 统计 / 浮层。

---

### P1-5 工作台首屏：五个 0 + 两个大空态

**位置**

- `UI/Dashboard/DashboardView.swift:243-275`：统计卡始终渲染。
- `:313-322`：「暂无工作区」`ContentUnavailableView`，放在 List 的 Section 内。
- `:335-351`：任务中心 Section header 内嵌副标题 + “清理已完成”按钮。
- `:353-383`：任务为空时再渲染一个「暂无后台任务」`ContentUnavailableView`。
- 截图：首屏几乎被“0 统计 + 两个空态”占满。

**影响**

- 首次启动没有任何照片，却先给用户一条“0 工作区 / 0 照片 / 0 待同步 / 0 冲突 / 0 离线”的仪表盘，信息量为零，视觉重量很大。
- 两个 44pt 图标的空态上下叠放，主次不分；用户不知道先点哪个。
- “清理已完成”按钮在 Section header 的 HStack 里，和两行标题做 firstTextBaseline 对齐，截图里按钮基线低于标题，像一个错位的浮动按钮。
- `ContentUnavailableView` 是为整页空态设计的；塞进 List 行后，它自带的 padding 与 List 的 section inset 叠加，形成不自然的垂直空白。

**方案**

1. **空库时隐藏统计条**（或改成一行次要文字：“还没有工作区 · 0 张照片”）。有数据时，统计条从 5 个 0 简化为 3 个关键值：照片 / 待同步 / 冲突；离线作为次级。
2. **空库时用一整页 onboarding，而不是两个空态**：
   ```text
   导入你的第一个工作区
   从文件夹或 Capture One 导入；照片不会被移动。
   [导入文件夹]  [从 Capture One 导入]
   选择来源 → 索引 → 挑片 / 写回
   ```
   主 CTA 只有一个（导入文件夹），Capture One 作为次按钮；底部用 3 步说明代替第二个空态。
3. **任务中心在空库时收起**：只留一行 “任务中心 · 暂无任务”，或直接隐藏，直到有任务 / 历史；不要把空态放在首屏。
4. 有数据时，任务中心在没有活跃任务时用一行 `NativeBanner`（已有“当前没有运行中或失败的任务”）代替大空态；历史用 `DisclosureGroup` 折叠。
5. “清理已完成”移出 Section header：放在任务列表底部，或作为 Section 内的行内 trailing 动作；Section header 只放标题 + 副标题。
6. 空态组件：整页用 `ContentUnavailableView`；List 内用自定义紧凑行（28–32pt 图标、13pt 标题、24pt 垂直 padding），不要嵌套整页组件。

**验收**

- 0 工作区截图：只有一个 onboarding 主 CTA；统计条不出现（或只一行）；任务中心不出现大空态。
- 有 1–3 个工作区截图：统计条 3 个关键值；任务中心无任务时一行提示。
- “清理已完成”与标题基线对齐，或不在 header 里。

---

### P1-6 深色查看器里的白色缩略图占位

**位置**

- `UI/Support/PhotoThumbnailView.swift:186-208`：加载中 / 失败占位使用 `GatherTheme.backgroundSecondary`（= `contentBackground`）。
- `UI/Gallery/LightboxView.swift:56-65`：整个灯箱恒用 `viewerBackground #0D0D0D`。
- `UI/Culling/CullingWorkbenchViewer.swift:100, 247-253, 339`：查看器恒用 `viewerChrome / viewerBackground`。
- `UI/Support/GatherTheme.swift:52-56`：查看器有独立的 `viewerSurface / viewerChrome / viewerTextPrimary`，但缩略图组件不知道自己在深色查看器里。

**影响**

- 浅色外观下打开灯箱 / 挑片查看器，加载中的缩略图是 **白色矩形**，在 `#0D0D0D` 背景上非常刺眼；文件丢失时的失败态会一直保持白色块。
- 查看器已经有一套暗色 token，但组件没有接收“我在暗色表面”的上下文，说明 viewer 语义没有下沉到叶子组件。

**方案**

1. 给 `PhotoThumbnailView` 增加 `surface: Color? = nil`（或 `placeholderStyle: .content / .viewer`）：
   ```swift
   PhotoThumbnailView(path: ..., size: ..., surface: GatherTheme.viewerSurface)
   ```
   占位 / 失败态使用该 surface；失败文字在暗色表面用 `viewerTextPrimary.opacity(0.75)`。
2. 在 Lightbox / CullingWorkbenchViewer 所有 `PhotoThumbnailView` 调用点传 `viewerSurface`；Gallery 网格 / Library 卡片保持语义 surface。
3. 加一个预览 / 截图用例：浅色外观 + 缺失文件，确认没有白块。

**验收**

- 浅色外观下灯箱 / 挑片查看器加载与失败态是深灰底，不是白色。
- 深色外观下占位与背景仍有层次（`#1A1A1A` vs `#0D0D0D`）。

---

### P1-7 状态 / 徽标有 5 种视觉语言

| 语义 | 现有实现 | 问题 |
| --- | --- | --- |
| 工作区 / 任务状态 | `GatherBadge`：胶囊 + 语义色文字 + 15% 底 | 对比度失败；10pt |
| 行内状态 | `SessionRowView.statusPill`：图标 + 主文字 + 15% 底（`SessionRowView.swift:96-110`） | 这个模式是对的，但没有被复用 |
| 照片角标（离线 / RAW+JPEG） | `GalleryCellView.chip`：黑 66% + 白字 | 正确，但 Library 的“离线”用 material + 主文字（`LibraryCardView.swift:89-96`） |
| 胶片条决策 | 9pt 红 / 绿圆点 | 颜色单通道，色弱不可辨 |
| C1 同步状态 | 圆点 + 正文 + 计数（`C1StatusCapsule.swift:216-245`） | 模式正确，保留 |

**方案**

定义三个叶子组件，语义各归其位：

1. `GatherStatusBadge`（P0-2 草案）：非照片表面；主文字 + 语义圆点 / 图标 + 低透明度底。
2. `PhotoOverlayChip`：照片上的角标；统一黑 66% + 白字 11pt；离线、RAW+JPEG、评分都用它。Library 的 material 版本删除。
3. `DecisionMark`：保留 / 淘汰；`checkmark` / `xmark` 图标 + 语义色，不再只画一个 9pt 圆点。胶片条、信息栏、查看器徽标共用。

**验收**

- “离线”在 Gallery / Library / 查看器里同形。
- 胶片条的保留 / 淘汰有图标，不只颜色。
- `GatherBadge`、`statusPill`、两个 chip、圆点实现合并为 3 个组件。

---

### P1-8 可访问性：对比度之外的四类缺口

1. **相似度成员卡不是按钮**：`SimilarityMemberCellView.swift:41-51` 用 `.onTapGesture`，没有 `.isButton` trait、没有 `.accessibilityAction`，键盘也不可达。改成 `Button` + `.buttonStyle(.plain)`，或补 traits / action / focusable。
2. **悬停才出现的删除按钮仍可点击**：`FaceMemberRow.swift:50-59` `.opacity(isHovered || isFocused ? 1 : 0)`，但 `.opacity(0)` 不关闭 hit testing，行尾的空白区域仍可误触删除（虽然有确认框）。改成隐藏时 `.allowsHitTesting(false)`，或常驻 0.35 透明度、hover / focus 提到 1。
3. **颜色单通道**：胶片条的保留 / 淘汰圆点、Duplicates 的保留 / 丢弃底色与描边。文字徽标已经存在（Duplicates），胶片条没有；补 `DecisionMark`。
4. **固定宽度在英文 / 大字号下会截断**：
   - `CullingConflictPanel.swift:63-65` 字段标签固定 `width: 44`；“Keywords” 在 12pt 下约 50pt，会截断。改 `minWidth: 64` 或 `Grid`。
   - `JobRowView` 状态 90 / 操作 80、`Settings` 下拉 200、`Export` 字号 70 等，需要在英文 + 最大文字大小下逐项复测。
   - `NewSessionSheet.swift:51-54` 固定 `width: 520 / height: 330|430`；英文脚注换行 + 大字号会顶到 footer。改为 `.fixedSize(horizontal: false, vertical: true)` + `minHeight`，不要固定高度。
5. **焦点**：自定义 `.buttonStyle(.plain)` 卡片（Gallery / Library / Similarity / Face）没有统一的 focus ring；键盘 Tab 遍历时用户很难看到当前项。加 `.focusable()` + 2px `selection` 描边，或使用统一 `GatherCardButtonStyle`。

**验收**

- VoiceOver 走通：工作台 → 导入 → 图库网格 → 灯箱 → 挑片 → 人脸绑定 → 导出。
- 纯键盘走通：Tab 到网格项、空格打开、←/→ 翻页、Esc 关闭。
- 英文 + 最大文字大小下，主要行 / 表单 / 弹层无截断。

---

### P1-9 窗口标题与副标题语义不统一

| 页面 | `.navigationTitle` | `.navigationSubtitle` |
| --- | --- | --- |
| Dashboard | “Gather” | “整理、挑选并同步你的摄影工作区” |
| Library | “全局图库” | “以同一逻辑照片为单位，跨工作区浏览、筛选和管理。” |
| Persons | “人脸库” | 无 |
| Gallery | 会话名 | “图库” |
| Culling | 会话名 | “挑片与写回” |
| ControlCenter | 会话名 | “工作区控制中心” |
| Settings | “设置” | 无 |

**问题**

- 侧栏选中的是「工作台」，窗口标题却写 “Gather”；用户无法从标题确认自己在哪。
- Library 的副标题是一整句产品说明（24 个汉字），在工作台 / 图库之间切换时长度跳变，且没有状态信息。
- Persons 没有副标题，与 Library / Dashboard 不一致。
- `LibraryView+Support.swift:35` 在 `.inspector` 内设置 `.navigationTitle("资料库")`；如果 SwiftUI 把 inspector 的 navigationTitle 传播到窗口，打开检查器会把窗口标题改成“资料库”（需实测；若生效，这是一个明显 bug）。

**方案**

1. **建立标题契约**：
   - 会话页：标题 = 会话名，副标题 = 页面功能（已有，保持）。
   - 全局页：标题 = 页面名（工作台 / 全局图库 / 人脸库），副标题 = 动态状态（N 个工作区 · N 张照片 / N 张逻辑照片 / N 个人物），不要营销句。
   - 设置：标题 = 设置，无副标题。
2. Dashboard 改为 `.navigationTitle("工作台")`；副标题用 `summary()` 的简短版本，或直接去掉（统计条已经承担）。
3. Library 副标题改为计数，或去掉（状态行已有“共 N 张逻辑照片”）。
4. Persons 加动态副标题，或与 Library 一样去掉。
5. 删除 inspector 内的 `.navigationTitle`；检查器需要标题时用 `GatherInspectorSection` 的分区标题，不要改窗口标题。
6. 工具栏契约：返回 + C1 + 刷新 + 当前页主操作；返回 `⌘[`、刷新 `⌘R` 在所有会话页统一（现在只有 Control / Face 有 `⌘[`，只有部分页有 `⌘R`）。

**验收**

- 每个页面的标题与侧栏选中项一致；副标题随数据变化，不是固定句。
- 打开 / 关闭 Library inspector，窗口标题不变。
- 所有会话页的返回 / 刷新快捷键一致。

---

### P1-10 相似度页在宽窗口左对齐、页面宽度策略不统一

**位置**

- `UI/Similarity/SimilarityView+Content.swift:60-61`：
  ```swift
  .padding(20)
  .frame(maxWidth: 1200, alignment: .leading)
  ```
  外层 `ScrollView` 没有把内容居中；窗口宽于 1240 时，内容贴左，右侧留下大块空白。
- Face 的分析 / 写回步骤用 `maxWidth: 900` + `.frame(maxWidth: .infinity, alignment: .top)`，是居中的；两页不一致。
- ControlCenter / Duplicates / Export 的卡片在宽窗口下铺满，长文本行宽过宽。

**方案**

- `GatherPage(maxContentWidth: 1100)`：内容区最大 1100，水平居中；图库网格 / 灯箱不设上限（全宽）。
- Similarity 改为 `GatherPage(maxContentWidth: 1100)`；Face 用 900；ControlCenter / Duplicates 用 1100；Export / Settings 交给 Form，不额外限宽。
- 对全宽卡片，内部正文加 `frame(maxWidth: 720, alignment: .leading)` 或分成两栏，避免一行 1600pt。

**验收**

- 1600pt 宽窗口截图：Similarity 内容居中；ControlCenter / Duplicates 不出现超长单行。
- 860pt 宽窗口：不出现横向溢出。

---

## 5. P2 / P3：一致性与打磨

| # | 问题 | 位置 / 证据 | 建议 |
| --- | --- | --- | --- |
| P2-1 | 悬停 / 按下 / 焦点反馈不一致 | Gallery cell 有阴影 + 亮度；Library card 无；Similarity member 有 6% 底；Face cluster 有 15% 动画；Duplicates 无 | 统一 `GatherCardButtonStyle`：hover 4% 底、pressed 8%、focus 2px `selection`、120ms |
| P2-2 | 动效未统一 / 未全部尊重 Reduce Motion | `CullingFilmstrip.swift:68-73` 自动滚动 `withAnimation(.easeInOut(0.2))` 未判 `reduceMotion`；其余 6 处已判 | 所有动画走 `GatherMotion`；滚动动画在 reduceMotion 时改为无动画 |
| P2-3 | 透明度 / 阴影值散落 | 21 种 opacity；`shadowMd` 三处组合 9/3、12/4、12/6 | `opacity.hover/pressed/disabled`、`shadow.card/floating` 两组 token |
| P2-4 | 死 token / 兼容别名 | `Radius.md` 0 使用、`Radius.sm` 1；`GatherTheme.primary/primarySoft/background/backgroundSecondary/surface/border` 仅 `backgroundSecondary` 3 处；`C1StatusCapsule.textColor` UI 未使用 | 删除别名与 `Radius.md`；把 `backgroundSecondary` 改名 `contentBackground`；`C1` 移除 `textColor` 或真正使用 |
| P2-5 | 工具栏分组在 macOS 26 不一致 | 只有 Gallery / Export 用 `ToolbarSpacer(.fixed)`；Culling / Control / Similarity / Duplicates / Face 没有 | 抽 `sessionToolbar`，统一 C1 + 刷新 + 页面动作分组；macOS 26 加 spacer |
| P2-6 | 侧栏与标题栏接缝 | 截图：标题栏 `#F0F0F0`，侧栏 `#DEDEDE`，内容 `#FFF`；侧栏从标题栏下缘才开始 | 验证 `.toolbarBackground` / 安全区 / `NavigationSplitView` 侧栏材质；不要用硬编码色块补齐 |
| P2-7 | 仪表盘任务 header 内嵌按钮基线不齐 | `DashboardView.swift:335-351`：`HStack(alignment: .firstTextBaseline)` 里放 VStack + Button；截图按钮偏下 | 用 `GatherSectionHeader` 的 center 对齐，或把动作移到行内 / footer |
| P2-8 | 检查器空文本两种风格 | Gallery / Library 用 `.callout + secondary`，Culling 的“未选择照片”用默认字号 | 检查器空文本统一 `.callout` + secondary；整页空态才用 `ContentUnavailableView` |
| P2-9 | C1 胶囊过长 | `C1StatusCapsule.swift:216-245`：状态词 + 计数 + 时间；工具栏预算紧张 | 保留状态词 + 计数；时间进 tooltip / 菜单；或折叠为 “C1” + 状态点 |
| P2-10 | 固定 sheet 高度 | `NewSessionSheet.swift:51-54` 520×330/430 | 改内容自适应 + `minHeight`；英文 / 大字号下不截断 |
| P2-11 | 图标尺寸不统一 | `frame(width: 16/28/40/44)`；`imageScale(.small/medium/large)` 混用 | 定义 12/16/20/28/44 五档，按行高 / 空态 / 工具栏分配 |
| P2-12 | 选择栏整条系统蓝 | `GalleryView+Content.swift:224-227` | 若坚持系统选中，保留但降低高度（28–32）；否则改 `surfaceMuted` + 主文字 + 选中图标 |
| P2-13 | 全宽卡片阅读行过长 | ControlCenter / Duplicates 在 1600pt 下铺满 | `GatherPage` 限宽或内部两栏 |
| P2-14 | 空态图标 / 标题 / 说明在 List 内过重 | Dashboard 两个 `ContentUnavailableView` | 见 P1-5；List 内用紧凑行 |
| P2-15 | 英文宽度未验证 | `CullingConflictPanel` 44；`NewSessionSheet` 固定高；JobRow 90/80 | 加 en + 最大文字大小截图矩阵 |
| P2-16 | 日期 / 数字 / 分隔符风格 | 多处 `·`、`/`；日期有 “2026年8月11日” 与 “08/11 22:04” 两种 | 统一日期格式（长日期 / 短时间两档）；数字全部 `.monospacedDigit()` |
| P3-1 | `GatherEmptyState` 与 `ContentUnavailableView` 两套空态 | `GatherCommonViews.swift:148-222` 只用于 bootstrap；页面用系统组件 | 保留 bootstrap 特例并注释；其余统一系统组件 |
| P3-2 | `GatherProgressBar` 包装层 | 只有 Dashboard JobRow 使用；其他页直接 `ProgressView` | 要么推广（带标签 / 百分比），要么删除包装 |
| P3-3 | 动画语义 | 出现 0.15 / 0.2 两档，easeOut / easeInOut 混用 | 统一 `reduceMotion ? nil : .easeOut(duration: 0.18)` |
| P3-4 | 中文标点 / 省略号 | 文案中 “…” 与 “...” 混用；全角 / 半角括号混用 | 文案规范：中文用全角标点，英文用半角；统一省略号 |

---

## 6. 优化方案

### 6.1 设计原则（建议写进 `docs/design/style-guide.md`）

1. **Native first**：能用系统容器就不自绘；颜色 / 文本 / 控件优先语义 API。
2. **选择交给系统，行动留给品牌**：列表 / 网格 / 胶片条的选中用用户强调色；品牌橙只用于主 CTA、星标、品牌标识。
3. **层级靠表面，不靠描边**：canvas → surface → surfaceMuted 三层；描边只做边界，不承担层级。
4. **角色化，不手选**：间距 / 字号 / 圆角 / 阴影 / 动效都有角色；页面不出现魔法数字。
5. **状态 = 图标 + 文字 + 颜色**：颜色是增强，不是唯一通道；状态色永远不做正文。
6. **密度服务于任务**：图库 / 挑片紧凑；Dashboard / 空态克制；一屏只保留一个主 CTA。
7. **为中文和英文同时设计**：11pt 下限、固定宽度可换行、避免 10pt 中文。

### 6.2 Token 层草案

```swift
public enum GatherTheme {
    // 品牌：行动
    public static let accentText = dynamic(light: "#A54D2A", dark: "#D98964",
                                           hcLight: "#7E3517", hcDark: "#F2B08C")
    public static let accentFill = dynamic(light: "#A54D2A", dark: "#A54D2A",
                                           hcLight: "#7E3517", hcDark: "#8A3E1F")
    public static let onAccent = Color.white

    // 选中：跟随用户系统强调色
    public static let selection = Color(nsColor: .controlAccentColor)
    public static let selectionFill = selection.opacity(0.14)

    // 表面
    public static let canvas = dynamic(light: "#F6F5F2", dark: "#1B1B1D",
                                       hcLight: "#FFFFFF", hcDark: "#000000")
    public static let surface = dynamic(light: "#FFFFFF", dark: "#2A2A2C",
                                        hcLight: "#FFFFFF", hcDark: "#1C1C1E")
    public static let surfaceMuted = dynamic(light: "#EFEDE8", dark: "#202022",
                                             hcLight: "#F2F2F2", hcDark: "#141416")
    public static let hairline = dynamic(light: "#00000024", dark: "#FFFFFF1F",
                                         hcLight: "#00000059", hcDark: "#FFFFFF4D")

    // 文字
    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    public static let textTertiary = Color.secondary.opacity(0.7)

    // 状态填充（只做图标 / 点 / 底，不做正文）
    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let error = Color(nsColor: .systemRed)
    public static let info = Color(nsColor: .systemBlue)

    // 状态文字（需要彩色正文时使用）
    public static let successText = dynamic(light: "#1E7B36", dark: "#6EE7A0")
    public static let warningText = dynamic(light: "#8A5A1F", dark: "#E5B27B")
    public static let errorText = dynamic(light: "#B3261E", dark: "#FF9C96")
    public static let infoText = dynamic(light: "#0060C9", dark: "#6FB3FF")
}
```

> `dynamic` 目前是 private；建议提升为 internal，并保留高对比度四态。上表的 hex 是建议值，需要在浅 / 深 / 高对比三态下用截图确认后再定稿。

```swift
public enum GatherMetrics {
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }
    public enum Radius {
        public static let thumbnail: CGFloat = 6
        public static let card: CGFloat = 10
        public static let floating: CGFloat = 12
    }
    public enum Layout {
        public static let pageGutter: CGFloat = 24
        public static let cardPadding: CGFloat = 16
        public static let rowGap: CGFloat = 8
        public static let sectionGap: CGFloat = 24
    }
    public enum Chrome {
        public static let tabStrip: CGFloat = 36
        public static let infoBar: CGFloat = 32
        public static let filmstrip: CGFloat = 120
    }
}
```

### 6.3 组件层草案

| 组件 | 职责 | 关键约束 |
| --- | --- | --- |
| `GatherPage(maxContentWidth:gutter:)` | 页面滚动 + 画布 + 留白 + 可选最大宽度居中 | 图库 / 灯箱不设上限；表单页不包 |
| `GatherSection(title:subtitle:action:)` | 页面级分区 | 15pt 标题 + 可选尾部动作 + Divider；无边框 |
| `GatherCard(padding:radius:)` | 可选对象 / 统计 / 浮层 | surface + hairline + 10 圆角；默认 16 内边距 |
| `GatherInspectorSection(title:)` | 检查器分区 | 系统 GroupBox；14 padding；13pt 标题 |
| `GatherStatusBadge` | 非照片状态 | 主文字 + 语义点 + 12% 底；11pt |
| `PhotoOverlayChip` | 照片角标 | 黑 66% + 白字 11pt；离线 / RAW+JPEG / 评分同形 |
| `DecisionMark(picked:)` | 保留 / 淘汰 | checkmark / xmark + 语义色；不只颜色 |
| `GatherCardButtonStyle` | 可点卡片 / 网格项 | hover / pressed / focus 三态；reduceMotion |
| `GatherPrimaryButton` | 页面唯一主 CTA | 局部 tint accentFill；不依赖根 tint |
| `GatherStatusText` | 需要彩色正文的少数场景 | 只允许 `*Text` token；禁止 fill token |

### 6.4 页面级配方

**Dashboard**

- 空库：顶部对齐的 hero 卡（app icon + GATHER eyebrow + 26pt 标题 + 3 个能力 chip + 主/次 CTA + 照片堆叠预览），下方 3 张快捷卡（Capture One / 三步工作流 / 最近使用）与本地隐私说明；隐藏 0 统计与任务空态。
- 有数据：5 个统计的概览卡 + 工作区 List + 任务中心（无任务时一行提示）；分区标题降为 11pt 次级标签，减少黑色粗体的视觉噪声。
- 标题“工作台”；副标题用计数或省略。
- 任务 header 只用标题 + 副标题；动作移到行 / footer。

**Shell / Sidebar**

- 工作台置顶；最近工作区最多 5 个，当前会话提前并高亮；无会话只显示一行“暂无工作区”。
- 资料库只放全局图库 / 人脸库；设置不占侧栏条目。
- 会话行：原生 Label + 照片数；长名称截断，`.help` 给完整名称/计数。
- 选中当前会话是 no-op；切换其他会话进入控制中心。

**Library**

- 空库且无筛选：整页 `ContentUnavailableView`，隐藏筛选条 / 状态条 / 分页，只留“导入文件夹”。
- 有数据：筛选条（3 个下拉 + 更多筛选）保持紧凑；网格 24 gutter；检查器统一 GroupBox。
- 搜索在 toolbar；筛选面板在 inspector 或可折叠条。
- 移除 `.searchable` 与筛选条的重复输入。

**Gallery**

- 选中栏改 32pt 高，中性底 + 主文字 + 选中图标；或保留系统蓝但降低高度。
- 单元圆角统一 6（照片）或 10（内容卡）；与 Library / Similarity 一致。
- 离线 chip 改为 `PhotoOverlayChip`。
- 检查器统一 GroupBox 标题；移除卡片内边距叠加。

**Culling**

- 一行工具栏（撤销/重做、范围、自动前进、对比、质量）。
- 筛选进检查器；infoBar 只留计数 + 同步菜单；胶片条 120 + 可折叠。
- 查看器顶部只留缩放百分比；操作说明进 infoBar / 首次提示。
- 决策圆点改 `DecisionMark`；保留 / 淘汰 / 未处理计数用圆点 + 主文字。
- 冲突面板沿用 `gatherCard + shadow`，但错误正文改 `errorText` 或主文字 + 图标。

**ControlCenter**

- 6 张卡 → `GatherSection` 扁平分区：索引状态、阶段、当前任务、待处理、推荐、同步。
- 分区标题统一 15pt；卡片内文字从 12pt 升 13pt。
- 同步卡去掉与 C1 胶囊重复的整句状态；只保留计数 + 一行状态。
- 阶段连接线保持现有修正（等宽列 + 列内线段）。

**Similarity / Duplicates**

- 页面用 `GatherPage(maxContentWidth: 1100)` 居中。
- 分析 / 扫描配置放 `GatherSection`；结果组用 `GatherCard`。
- 统计条改为一行 13pt 文本 + 分隔线，不再套整张卡（Similarity 的 `statsBar`）。
- 分组卡标题统一 13/15；成员缩略图圆角 6；选中描边用 `selection`。
- Duplicates 的保留 / 丢弃用 `DecisionMark` + 文字徽标，边框只做辅助。

**Persons**

- 空库：左侧列表只保留一个“新建人物”入口；右侧用说明性空态（无第二个 CTA），或直接隐藏右栏。
- 有数据：HSplitView 保持；列表行 28pt 头像；详情头 17pt；Form 分组；删除按钮只用 role，不重复上色。
- 检查器 / 详情标题统一。

**Export / Settings**

- 保持 `Form(.grouped)`；这是最原生的部分。
- 长提示改脚注（`.font(.callout).foregroundStyle(.secondary)`）；减少每行下方的重复说明。
- Settings 的 queueGrid 数字用 15pt + 主文字；失败 / 冲突的强调色只做数字颜色（用 `errorText`）或图标。
- 设置窗口默认 640×620，限制最大宽度（如 760），避免宽屏下表单行拉太长。

### 6.5 强调色策略（建议直接采纳）

- 根视图移除 `.tint(accent)`。
- 所有系统控件 / 列表选择 / 自定义选中走 `controlAccentColor`。
- 品牌橙只用于：
  1. 每页唯一主 CTA（`GatherPrimaryButton` / `gatherPrimaryActionButton` 局部 tint）；
  2. 评分星标、品牌标识、空态主图标（可选）；
  3. 不放侧栏闲置图标、不做正文色、不做状态色。
- 深色模式使用 `accentFill #A54D2A + onAccent white`（5.68:1），不要用 `#D98964` 做填充 + 白字（2.72:1）。

### 6.6 排版 / 间距执行顺序

1. 先改 token 与共享组件（`GatherBadge`、`GatherCard`、`GatherStatCard`、`NativeBanner`）。
2. 再改页面级“标题 / Body / 说明”三类字号；优先 Dashboard、ControlCenter、Similarity、Duplicates。
3. 最后改单页特例（Culling inspector、Face 卡片、Persons 详情）。
4. 每一轮只动一类，避免截图对比时无法归因。

### 6.7 可访问性 / 国际化执行清单

- [ ] 所有文字 token 对比度 ≥ 4.5:1（大字号 ≥3:1），用脚本 / 单测锁定。
- [ ] 状态不只颜色：图标 / 文字至少一个冗余通道。
- [ ] 自定义卡片 / 网格项有 focus ring 和键盘动作。
- [ ] hover-only 控件在隐藏时 `.allowsHitTesting(false)`，或常驻可见。
- [ ] 英文 + 最大文字大小下，固定宽度列 / sheet 不截断。
- [ ] VoiceOver 走通 5 条主流程。
- [ ] Reduce Motion 覆盖所有动画；Reduce Transparency 下玻璃 / 材质仍可读。
- [ ] 高对比度外观下，surface / hairline / 状态徽标仍可辨。

### 6.8 治理：让规则可执行

1. **`docs/design/style-guide.md`**：token 表、组件契约、页面配方、禁止项（本报告可拆成该文档）。
2. **`scripts/check-style-tokens.sh`（ratchet）**：
   - 统计 `cornerRadius:` 字面量、非 token 的 `.padding(` 数字、`foregroundStyle(GatherTheme.(success|error|warning|info))`、`Color(hex:`、`.font(.system(size:`；
   - 与基线 JSON 比较，只允许下降 / 不增加；新文件按 0 处理；
   - 在 CI 中以 warning 起步，稳定后 `--strict`。
3. **`ThemeContrastTests`**：把 `*Text` / `surface` token 解析成 sRGB，断言对比度；状态徽标按实际 tint 计算。
4. **截图矩阵**：9 个页面 ×（1180 浅 / 1180 深 / 860 浅 / 高对比）×（zh / en），至少覆盖关键 5 页；存 `docs/reviews/assets/` 或 CI artifact。

---

## 7. 路线图

| 阶段 | 范围 | 主要文件 | 工作量 | 退出条件 |
| --- | --- | --- | --- | --- |
| 0 基线 | 截图矩阵、对比度测试、ratchet 基线 | `docs/reviews`、`scripts`、`Tests` | 0.5–1 天 | 有 20+ 张基线截图；脚本能跑 |
| 1 Token + P0 颜色 | `GatherTheme` 角色拆分（accentText/Fill、selection、surface、statusText）、`GatherStatusBadge`、`GatherCard` 表面、根 tint、侧栏图标 | `Support/GatherTheme.swift`、`GatherBadge.swift`、`RootView.swift`、`RootShellSidebar.swift` | 2–3 天 | 对比度测试全绿；卡片可辨；侧栏不再全橙 |
| 2 布局 / 密度 | `GatherPage` / `GatherSection`、Dashboard 首屏、Culling chrome、三个检查器、Similarity 居中、Library 空态 | Dashboard / Culling / ControlCenter / Similarity / Library / Support | 3–4 天 | 挑片查看器 ≥60% / ≥50%；Dashboard 单 CTA；检查器一致 |
| 3 排版 / 间距普查 | `.callout` → `.body`、徽标 11pt、分区标题统一、卡片 padding、圆角 6/10/12、英文宽度 | 全 UI | 2–3 天 | 字体 / 间距 / 圆角 ratchet 达标 |
| 4 可访问性 / 打磨 | 焦点 / hover / pressed、viewer 占位、动效、深色 / 高对比 / VoiceOver | 全 UI | 1–2 天 | 验收矩阵通过；无 P0/P1 残留 |

总工作量约 **9–13 个工程日**（不含产品决策与设计返工）。Phase 1 与 Phase 2 可以由两人并行，但 `GatherTheme` / `GatherCard` 是共享文件，需要先合并 Phase 1 的 token，再动页面。

### 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| 改根 `.tint` 影响所有系统控件 | 先在分支里用 3 种系统强调色截图；只把主 CTA 局部 tint，不保留根 tint |
| `GatherCard` 全局改表面，波及 20+ 页面 | 先加 token / 参数，保持默认行为；逐页截图切换；不要一次性删 `gatherCard` |
| 挑片页改布局触发 AppKit 约束循环 | 保留 `ScrollView(.horizontal)` / `ViewThatFits` 兜底；860×560 必测；不要引入负宽度 / GeometryReader 写状态 |
| `.inspector` 里用 Form 崩溃（已有记录） | 检查器只用 GroupBox / ScrollView；不要“顺手”改成 Form |
| 修改 `navigationTitle` 影响窗口标题 | 先在 Library inspector 上实测；不确定就删除 inspector 内的 navigationTitle |
| 视觉改动与现有测试冲突 | 先跑 app/core 测试；布局常量变更同步 `RootShellMetrics` 与测试断言 |

---

## 8. 验收清单

### 8.1 视觉验收矩阵

| 页面 | 1180 浅 | 1180 深 | 860 浅 | 高对比 | zh / en |
| --- | --- | --- | --- | --- | --- |
| Dashboard | ☐ | ☐ | ☐ | ☐ | ☐ |
| Library | ☐ | ☐ | ☐ | ☐ | ☐ |
| Gallery + Lightbox | ☐ | ☐ | ☐ | ☐ | ☐ |
| Culling 1/2/4 图 | ☐ | ☐ | ☐ | ☐ | ☐ |
| Duplicates | ☐ | ☐ | ☐ | ☐ | ☐ |
| Face 分析 / 审核 / 写回 | ☐ | ☐ | ☐ | ☐ | ☐ |
| Similarity | ☐ | ☐ | ☐ | ☐ | ☐ |
| Export | ☐ | ☐ | ☐ | ☐ | ☐ |
| Settings | ☐ | ☐ | ☐ | ☐ | ☐ |
| Persons | ☐ | ☐ | ☐ | ☐ | ☐ |
| SessionControl | ☐ | ☐ | ☐ | ☐ | ☐ |

### 8.2 可访问性

- [ ] 对比度脚本：所有文字 token ≥ 4.5:1；大字号 / 粗体 ≥ 3:1。
- [ ] VoiceOver：工作台、图库、灯箱、挑片、人脸绑定、导出。
- [ ] 键盘：Tab / Shift-Tab / 空格 / Enter / Esc / 方向键。
- [ ] Reduce Motion / Reduce Transparency / Increase Contrast。
- [ ] 英文 + 最大文字大小：无截断、无重叠。

### 8.3 工程

- [ ] `swift test --no-parallel`（app + core）通过。
- [ ] `./desktop/native/build.sh` 通过（bundle / 本地化 / 图标断言）。
- [ ] 860×560 无约束循环崩溃。
- [ ] `scripts/check-docs.sh --strict` 通过（本文件链接有效）。
- [ ] 样式 ratchet 不增加（或按计划下降）。

---

## 9. 附录

### 9.1 普查数字（本轮）

| 指标 | 数值 |
| --- | --- |
| GatherUI Swift 文件 | 195 |
| Swift 行数 | 29,466 |
| 字体调用 | 227 |
| `.callout` | 153（约 68%） |
| `.headline` | 19 |
| `.title3.weight(.semibold)` | 10 |
| `.footnote` / `.caption` | 10 / 5 |
| 间距数值种类 | 19 |
| 圆角字面量 / token | 4 / 4（group, panel, sm, md） |
| `gatherCard` 调用点 | 20+ |
| `GroupBox` | Culling 检查器 |
| `Form(.grouped)` | 6 处 |
| `.inspector` | 3 处（Library / Gallery / Culling） |
| `ContentUnavailableView` | 33 |
| 固定宽度 `frame(width:)` | 39 |
| 状态色 `foregroundStyle` | 27（约 20 文字 / 7 图标） |
| opacity 值 | 21 种 |
| 阴影组合 | 3 种 |
| 动画调用 | 7（1 处未判 Reduce Motion） |

### 9.2 历史评审对照

- [历史视觉评审（2026-09-29，归档）](../archive/reviews/visual-design-review.md) 已记录：
  - 卡片 / 页面 1.06:1、描边 1.32:1；
  - warning 色作正文 2.41:1；
  - 根 tint 覆盖系统强调色。
- 当前进展：warning 色部分改为系统色、Liquid Glass 边界与系统容器已落地；但“卡片 fill = 页面 fill”和“状态色作正文”仍未根治，属于**同一根因的残留**，不是新问题。
- 本篇不重复历史报告中的旧行号；所有位置按当前 HEAD 重新核对。

### 9.3 关键命令（可复核）

```bash
# 字体
grep -rhoE '\.font\(\.[a-zA-Z0-9]+(\([^)]*\))?(\.weight\([^)]*\))?\)' \
  desktop/native/gather-app/Sources/GatherUI | sort | uniq -c | sort -rn

# 间距 / 圆角 / 固定宽度
grep -rhoE '\.(padding|spacing)\(([^)]*)\)' ... | grep -oE '[0-9]+' | sort -n | uniq -c
grep -rn --include=*.swift -E 'cornerRadius: [0-9]' ...
grep -rn --include=*.swift -E '\.frame\(width: [0-9]' ...

# 状态色前景
grep -rn --include=*.swift -E 'foregroundStyle\(GatherTheme\.(success|error|warning|info)\)' ...

# 主题 / 组件
grep -rn --include=*.swift -E 'gatherCard\(|GroupBox|formStyle\(\.grouped\)|\.inspector\(' ...
```

### 9.4 建议新增的文件

- `docs/design/style-guide.md`：本报告第 6 节的可执行版（token 表 + 组件 API + 页面配方 + 禁止项）。
- `scripts/check-style-tokens.sh`：样式 ratchet。
- `Tests/GatherAppTests/ThemeContrastTests.swift`：token 对比度断言。
- `docs/reviews/assets/style/`：验收矩阵截图（浅 / 深 / 高对比 / 中英文）。

### 9.5 需要产品 / 设计确认的 5 个决策

1. **表面策略**：A 保留卡片但给真实表面；B 页面分区扁平 + 只有对象用卡片。**建议 B 混合**。
2. **强调色**：A 选中跟随系统、品牌只做行动；B 品牌橙做所有选中。**建议 A**。
3. **密度**：A 专业紧凑（当前挑片 / 图库方向）；B 舒适宽松（当前 Dashboard 方向）。**建议 A，局部 B**。
4. **表面色温**：A 轻微暖中性（贴合品牌）；B 纯系统中性（最 HIG）。**建议 A，幅度控制在 1.15:1 左右**。
5. **工作台首屏**：导入文件夹为主 + Capture One 为次；还是 Capture One 为主。**建议前者**（本地优先）。

---

**评审结论**：这套 UI 已经“原生”了，但还没有“统一”。下一步不是继续加页面，而是把主题层从“若干颜色常量”升级为“表面 / 文字 / 间距 / 状态 / 行动”五类角色，并用一个共享组件 + 一个 ratchet 脚本把规则固定下来。完成 Phase 1–2 后，视觉一致性会有质的变化；Phase 3–4 是把专业观感和可访问性补齐。
