# Gather 布局重构：对齐 Bridge / Capture One 的工作区组织

> 关联：[原生化改造报告](native-refactor-report.md) · [macOS 26/27 Liquid Glass 规范](liquid-glass-macos-26-27-adoption.md)
> 触发问题：「整体 UI 选项比较散」

---

## 1. 问题诊断：什么叫「散」

把改造前的界面按*信息归属*拆开看，问题是**同一类东西散落在三个不同的地方**：

| 内容 | 改造前放在哪 | 应该属于 |
| --- | --- | --- |
| 相册 / 资产关联 / 孤立 XMP / 离线卷 | 全局图库页**网格上方**的四张横向卡片 | 目录级管理 → 侧面板 |
| 筛选 / 网格尺寸 / 变体展开 | 窗口**工具栏**，和返回、状态、设置混在一起 | 浏览选项 → 侧面板 |
| 挑片决策 / 星级 / 色标 | 挑片页**左侧**一整列，把查看器挤在中间 | 工具选项 → 侧面板 |
| 后台任务状态 | **只在工作台**，挑片/导出时看不见 | 全局状态 → 常驻状态位 |

三条具体病灶：

1. **管理功能压在内容上方。** 全局图库一屏高约 780pt，四张卡片吃掉顶部约 200pt，
   而它们和「浏览照片」没有关系——用户每次看图都要先跨过一排管理卡片。
2. **窗口没有右侧检查器。** Bridge 的 Collections / Metadata、Capture One 的
   Library / Adjustments 工具页都在右侧。Gather 把「选项」塞进工具栏和内容区，
   工具栏因此又长又杂，内容区也不得不承载非内容。
3. **全局状态只在某一个页面可见。** 后台任务在挑片/导出时是真实存在的，
   但进度条只在工作台能看——这是最典型的「散」。

---

## 2. 参考的成熟做法（已核对的出处）

Bridge / Lightroom 的 Adobe 文档正文是客户端渲染的（脚本抓不到句子），
Capture One 的 HTML 站点被 Cloudflare 挡（走 Zendesk 公开 API 拿到全文），
Apple Photos 指南同样是 JS 正文。**下面凡带原句的都是直接抓到的**，其余标注为「常见排布」。

| 区域 | 依据 | 规律 |
| --- | --- | --- |
| 左 vs 右 | darktable 4.6 原文：「left panel = *modules primarily used to **provide information***」「right panel = *primarily used for **image processing***」；Lightroom Classic：「*The panel group on the left always holds the Navigator or Preview panel and other sources of information—folders, collections, templates, presets…*」 | **左 = 内容从哪来；右 = 对内容做什么** |
| 中 | darktable：「*The layout … consists of a **center area with panels at the edges***」 | 内容永远占中央 |
| 底 | darktable：**filmstrip 原文就是「at the bottom」**；digiKam 状态栏 = 文件名 · 选区 · 快速筛选 · **批量进度条** · 缩略图尺寸滑块 | 批量上下文 + 全局状态 |
| 模式切换 | Capture One 的模式叫 **Tool Tabs**，位置在**左上角的图标竖排栏**，默认就有 10 个（Library / Capture / Lens / Color / Exposure / Details / Adjustments / Metadata / Output / Batch）；Lightroom 7 个走 Module Picker；darktable 6 个走**文字列表** | **同级模式 ≤5 用横向切换器，超过就升级成竖向栏/列表** |
| 目录管理 | Capture One 原文：Library Tool Tab 是「*where all file navigation and organization takes place*」；Bridge 的整个「Organize and find files」章节组；Lightroom 的左侧面板组 | **管理功能永远是面板，绝不在网格上方** |
| 面板记忆 | darktable 原文：「***The size and visibility of the panels are stored independently for each view.***」 | 每个页面独立记忆显隐与宽度 |

由此得出本轮采用的 10 条规则（每条都至少有两个参考软件支持）：

1. **内容不动，选项进侧面板。**（darktable / digiKam / Capture One / Bridge / Lightroom）
2. **左 = 内容从哪来，右 = 对内容做什么。**（darktable / digiKam / Lightroom 均有明文）
3. **目录级管理不进内容区。**
4. **网格上方的「筛选条」不算管理。**（Lightroom 的 Library Filter bar 是合法的）
5. **工具栏只放模式与瞬时动作。**
6. **同级模式 ≤5 用横向切换器，超过就升级成竖向栏。**
7. **选项属于当前项，状态属于整个 app。**（digiKam 的全局批量进度条）
8. **终态/一次性流程不是浏览模式的对等项。**（导出 = Bridge 面板 / Capture One Output 工具页 / Lightroom 对话框）
9. **面板显隐与宽度由用户控制并按页记忆。**
10. **状态栏承载：选区计数、生效筛选数 + 清除、批量进度、缩放。**（digiKam 明文清单）

---

## 3. 已落地的改动

统一采用系统 `.inspector(isPresented:)` + `.inspectorColumnWidth(min:ideal:max:)`——
**macOS 14.0+，部署目标即可用，无需版本门控**（已核对 SwiftUI swiftinterface：
`@available(iOS 17.0, macOS 14.0, *)`）。工具栏的显示/隐藏按钮由系统提供，
可见性与宽度由系统记忆，**不自己存偏好**。检查器内容一律 `Form(.grouped)` + `Section`，
标题、分组圆角、内边距、行高全部交给系统。

### 3.1 全局图库：四张管理卡片 → 右侧「资料库」检查器

```
改造前                              改造后
┌────────┬──────────────┐        ┌────────┬──────────────┬────────┐
│ 侧栏    │ 筛选行        │        │ 侧栏    │ 筛选行        │ 资料库  │
│        │ ┌──┐┌──┐┌──┐┌──┐│        │        │ ──────────── │ 检查器  │
│        │ │相册││关联││XMP││离线││        │        │ 状态行        │ 智能相册 │
│        │ └──┘└──┘└──┘└──┘│        │        │ ──────────── │ 资产关联 │
│        │ ──────────── │        │        │              │ 孤立 XMP │
│        │ 照片网格      │        │        │ 照片网格      │ 离线卷   │
│        │ 分页          │        │        │ 分页          │        │
└────────┴──────────────┘        └────────┴──────────────┴────────┘
```

内容区回到两件事：**筛选 + 网格**。四个 `Section`：智能相册 / RAW·JPEG 资产关联 /
孤立 XMP / 离线存储卷。同时消掉了旧版「四张卡横排、隐藏滚动条、窄窗口下最后一张在屏幕外」
的不可达缺陷。

### 3.2 图库页：浏览选项 → 右侧检查器

工具栏从「返回 + 筛选 + 网格尺寸 + 变体 + 状态胶囊 + 刷新 + 设置」八项，
收敛成「返回 | 状态胶囊 + 刷新 | 设置」三组。

- 检查器 `Section`：**筛选**（全部 / 有人脸 / 无人脸）、**显示**（网格尺寸 + 展开所有变体）。
- 所有 `.help()` / `.accessibilityLabel` / `.accessibilityValue` / `.onChange` 原样保留；
  两个 `Picker` 去掉 `.labelsHidden()`、变体按钮去掉 `.iconOnly`，因为 Form 行需要可见标签。
- **未做**「评分与色标」筛选：`GalleryViewModel` 没有对应状态，
  `GalleryPhotoData` 也不带评分/色标字段（源码 :146–148 已有说明）。加它需要新增 ViewModel API，
  超出视图层范围。

---

## 3.3 挑片页：工具列 → 右侧检查器（Capture One 解剖）

```
改造前                                  改造后
┌────┬─────────────┬──────┐            ┌────┬───────────────────┬──────┬────────┐
│挑片 │  查看器      │ 胶片 │            │    │    查看器          │ 胶片 │ 挑片   │
│工具 │             │      │            │    │                   │      │ 检查器 │
│列   │             │      │            │    │                   │      │ 保留 P │
│214pt│  被两列夹住   │196pt │            │    │  独占全部剩余宽度   │180pt │ 淘汰 X │
│    │             │      │            │    │                   │      │ 星级   │
│    │  信息条      │      │            │    │    信息条          │      │ 颜色   │
└────┴─────────────┴──────┘            └────┴───────────────────┴──────┴────────┘
```

- `workbench` 从三列变两列，`toolsWidth` 删除；查看器现在独占除胶片条外的全部宽度。
- 检查器 `Form(.grouped)`，四个 `Section`：**当前照片**（保留/淘汰/未处理 + 星级 + 颜色）、
  **相似组 · N 张**、**选择管理**、**统计**（评分 / 标记）。
- 全部 action / binding / `.help()` / `accessibilityLabel` 原样保留。

### 3.3.1 附带修掉的两个真实缺陷

1. **裸键失效（回归，已修）。** 把按钮搬进检查器后，P / X / U 与 0–5 的
   `.keyboardShortcut` 只在**面板展开时**才注册——收起检查器这三个主力键就全没了。
   现在改为挂在**查看器**的 `.onKeyPress(phases: .down)` 上（查看器是本页唯一始终存在的控件，
   且原本就用它处理空格），同时删掉检查器按钮上的重复注册（`keyboardShortcut` 与
   `onKeyPress` 并存会**双触发** `viewModel.commit`）。
2. **英文缺失。** 新增的 `选择管理` / `未选择照片` / `已选 %lld 张` / `统计` 四条中文
   key 已补进 `en.lproj`。

---

## 3.4 一个必须记录的坑：不要把 `Form(.grouped)` 放进 `.inspector`

全局图库的检查器最初写成 `Form { ... }.formStyle(.grouped)`，**打开该页必崩**：

```
EXC_CRASH (SIGABRT)  abort() called
  libc++abi  __cxa_rethrow
  AppKit     __NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke
  AppKit     NSDisplayCycleObserverInvoke → NSDisplayCycleFlush
  QuartzCore CA::Transaction::commit
```

即 **AppKit 在约束更新阶段抛出 Objective-C 异常**。注意**同样写法的挑片页检查器不崩**——
说明这不是 `Form` 本身的问题，而是 `Form` 与图库里某些定宽控件（`Picker` 的
`.frame(width: 150)`、相册列表等）组合后在 `.inspector` 的滚动容器里产生了约束冲突。

处理：全局图库的检查器改回 `ScrollView` + `.gatherCard()` 卡片分组
（四组内容本来就是「管理面板」而不是表单行，卡片分组更贴切），
挑片页与图库页继续用 `Form(.grouped)`（实测稳定）。

**结论：把 `Form(.grouped)` 放进 `.inspector` 前必须实机跑一遍该页面。**

---

## 4. 尚未落地（建议的下一步）

### 4.0 会话模式：目标是把七段收敛成三段

研究给出的映射（**仅呈现层，枚举与顺序不动**）：

| 页面 | 结论 | 应该在哪 | 依据 |
| --- | --- | --- | --- |
| 浏览 | **保留**为模式 | detail + 右检查器 | 就是 Lightroom 的 Library / Bridge 的 Essentials |
| 挑片 | **保留**为模式 | detail + **底部**胶片条 + 右检查器 | 浏览+决策视图，和「浏览」同类，不该和「相似度」并列 |
| 相似度 | **保留**为模式 | detail + 右检查器 | 有自己的画布（分组），阈值该进面板而不是工具栏 |
| 人脸 | **保留**但归组 | detail + 右检查器 | 分析类 |
| 重复 | **合并** | 收进「分析 ▸ 重复」 | 与「人脸」同类同形（待复核的列表 + 逐项动作） |
| 控制中心 | **降级** | 侧栏「当前会话」的落地页（现在已经是） | 它是会话**状态**，不是照片视图（规则 4/7） |
| 导出 | **降级** | 工具栏按钮 → **sheet** | 规则 8：Bridge 是 Export 面板、Capture One 是 Output 工具页、Lightroom 是对话框，都不是「库」的同级 tab |

净效果：

```
浏览 | 相似度 | 挑片        [分析 ▾]        [导出…]   [任务 ●3]
                        人脸 / 重复
```

⚠️ 再次强调：`SessionTab.allCases` 的顺序是测试契约
（`GatherAppTests/RootViewTests.swift:69`），所以只能改**渲染与路由**，
枚举本身一行都不能动。这是本轮唯一没有落地的结构性改动，因为它是**交互语义变更**。

### 4.4 关于「图标竖排栏」（Capture One 的 Tool Tab bar）

Capture One 有 10–13 个模式，它用**左上角的图标竖排栏**承载；Lightroom 7 个模块用
Module Picker；darktable 6 个视图用**右上角的文字列表**。

**macOS 14 上没有原生的「图标竖排栏」控件。** 原生替代
（`TabViewStyle.sidebarAdaptable` + `Tab`）是 **macOS 15.0+**。
所以在本项目的部署目标下，正确的做法就是现在的方案：**≤5 个同级模式用横向
`Picker(.segmented)`，侧栏目的地才用 `List(.sidebar)`**。
不要手工造竖排栏，也不要拿 `Picker` 塞进 `List` 假装。

### 4.5 面板显隐的记忆

darktable 的原话是「*The size and visibility of the panels are stored independently for
each view*」，Microsoft 的 `NavigationView` 也把 `IsPaneOpen` / `OpenPaneLength` 归给
**应用自己管**。所以 `@State private var showInspector` 是错的——它在每次导航重建、
每个新窗口都会重置。改为**每页一个 `@SceneStorage` 键**。

**宽度不要自己存**：声明 `.inspectorColumnWidth(min:ideal:max:)` 让系统持有拖拽宽度；
如果把自己的宽度回灌成固定值 `.inspectorColumnWidth(_:)`，就丢掉了弹性列
（Apple 明确说环境「may use a different width」）。

### 4.6 不要在 `.inspector` 上叠加 Liquid Glass

macOS 26 上侧栏、工具栏、检查器**已经**拿到系统玻璃；再手工 `glassEffect`
会变成双层材质，并破坏工具栏/检查器自动合并的效果（就是那个让切换按钮看起来
原生的一步）。玻璃只留给**浮在媒体之上的自定义控件**——本 app 里只有
挑片的冲突面板和 toast 两个合法位置。


### 4.1 后台任务状态应常驻

后台任务由 `GatherEventCenter` 全局广播，只有 `DashboardViewModel` 消费并渲染，
所以**只有工作台能看到进度**。挑片、导出、图库页都有真实的后台任务，却看不到。

建议：外壳工具栏加一个任务状态指示器（运行中数量 + 环形进度），点击弹 popover 列出任务。
这是 Capture One 的进程指示器、Bridge 的缩略图生成进度所采用的做法。
属**新增功能**，需要新的 ViewModel 状态与命令订阅，本轮未做。

### 4.2 工作台的纵向堆叠

工作台目前是「统计条 → 工作区列表 → 任务中心 → 已完成历史」四段纵向堆叠。
按 §2 的规则，任务中心属于全局状态（见 4.1），已完成历史属于可折叠的次级信息；
把两者移出后，工作台只剩「统计 + 工作区」两件事，会清爽很多。

### 4.3 七段式模式选择器

会话页工具栏是一个七段 `Picker`：浏览 / 相似度 / 控制中心 / 人脸 / 重复 / 挑片 / 导出。

按参考软件的惯例，模式切换通常 ≤5 项且语义同层。这里混了三种东西：
**浏览视图**（浏览、挑片）、**分析视图**（相似度、重复、人脸）、**状态与产出**（控制中心、导出）。

⚠️ 注意：`SessionTab` 的枚举与 `allCases` 顺序是**测试契约**
（`RootViewTests` 断言 `["control","face-kw","duplicates","culling","export"]`），
所以任何调整只能是**呈现层**的（例如拆成一个视图模式分段控件 + 一个「分析」菜单 +
工具栏里的导出按钮），不能动枚举本身。属交互语义变更，需要单独一轮设计与回归。
