# UI／交互审查（2026-09-29）修复台账

> 后续：[第二轮验收修复台账](ui-review-2026-09-29-round2-fixes.md)（N01–N10：挑片崩溃量化、人脸裁剪回归、导出草稿等）
> 来源：外部审查报告《Gather UI、交互与分块设计审查报告》（2026-09-29，13 项发现：P1 ×5、P2 ×7、P3 ×1）
> 关联：[原生化改造报告](native-refactor-report.md) · [布局重构](layout-restructure.md) · [窗口布局研究](window-layout-research.md)
> 本文档只记录**核验结论 + 修复 + 验收方式**，不重复报告原文。

---

## 0. 核验方法

1. **不采信摘要，逐条回到源码**：每个发现都定位到具体文件行，并区分「属实 / 部分属实 / 不成立」。
2. **崩溃回到系统日志**：读取 `~/Library/Logs/DiagnosticReports/Gather-2026-09-29-15*.ips` 四份崩溃报告的完整栈，
   而不是从截图与描述推断根因。
3. **构建与测试**：`swift build` + `swift test`（core 952 项、app 224+ 项）作为回归门槛。

崩溃报告的栈（四份一致，仅触发路径不同）给出了**决定性证据**：

```
 9  AppKit  __NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke
10  AppKit  NSDisplayCycleObserverInvoke
...
30  AppKit  -[NSSegmentedCell _performClick:onSegment:ignoreMenus:]
31  AppKit  -[NSAccessibilityElement accessibilityPerformPress]
```

即：**在显示周期刷新约束时抛出 `NSGenericException`**，其中两份由「点击工具栏分段控件（页签）」
触发，另两份是空闲态显示周期自然触发。根因是布局反馈环，触发点集中在
**工具栏分段控件的固有宽度** × **`.inspector` 列宽协商** × **grouped Form** 三者叠加。

---

## 1. 逐条核验与修复

| # | 发现 | 核验 | 修复 |
| --- | --- | --- | --- |
| F01 | 进入挑片／全局图库崩溃 | 属实（4 份崩溃日志 + 栈） | 见 §2 |
| F02 | 工具栏「导入文件夹」点击无响应 | 属实 | 见 §3 |
| F03 | 全局人脸库无可发现入口 | 属实 | 见 §4 |
| F04 | 导出范围与引导不一致 | 属实 | 见 §5 |
| F05 | 人脸审核缺少可辨认脸部图像 | 属实 | 见 §6 |
| F06 | 七项子导航挤掉导出主动作 | 属实 | §2 同批（页签移出工具栏） |
| F07 | 控制中心重复卡片、任务沉底 | 属实 | 见 §7 |
| F08 | 「已写入待读取」与「全部同步」矛盾 | 属实 | 见 §8 |
| F09 | 子页失去工作区上下文 | 属实 | 见 §9 |
| F10 | 已完成人脸页仍默认落在分析 | 属实 | 见 §10 |
| F11 | 设置分组顺序与保存机制 | 部分属实（保存提示已存在，文本只在回车保存属实） | 见 §11 |
| F12 | 人脸成员动作依赖悬停 | 部分属实（键盘可聚焦属实、`children: .combine` 使动作不可达属实） | 见 §12 |
| F13 | 预设／高级参数规则不统一 | 属实 | 见 §13 |

---

## 2. F01：布局约束循环崩溃

**证据**：`crash-summary.log` 与 `.ips` 完整栈（`__NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke`
→ `NSDisplayCycleObserverInvoke` → `objc_exception_rethrow`），窗口 `1180×780`。

**修复**（四处独立病灶，均已消除）：

1. **grouped Form 进 `.inspector`**：`CullingView.inspectorContent` 由 `Form(.grouped)` 改为
   `ScrollView + GroupBox`；`GalleryView.inspector` 同样改为 `ScrollView + 卡片`。
   `LibraryView.libraryInspector` 早已记录**同一崩溃栈**并改为此形态，这两处属于漏改。
2. **负宽度约束**：`CullingView` 冲突面板原为 `frame(width: min(540, geometry.size.width - 32))`，
   首帧 `width == 0` 时得到 **-32**，AppKit 必须再跑一轮约束；改为 `max(0, …)` 且只在
   `conflicts` 非空时安装定宽。
3. **几何写回放大**：查看器原把 `GeometryReader.geometry.frame(in: .global)` 每次变化写回 `@State imageFrame`。
   改为让滚轮命中去问 AppKit 代理视图（`WindowBridge` 透出宿主 `NSView`）的 `bounds`——
   坐标由 AppKit 维护，不再产生布局反馈。
4. **工具栏宽度竞争**（同时修 F06）：七段 `Picker(.segmented)` 从 `.toolbar(.principal)` 移到内容区顶部的
   紧凑页签行（`sessionPageChrome`）。工具栏不再在目的地切换的同一轮约束更新里改变固有宽度。

**附带加固**：`LibraryView` 筛选行的固定宽度（`150/220`）改为自适应（`minWidth: 96/120`）——
固定宽度 × 3 在最小窗口 + 检查器打开时会索要超出可用宽度的最小尺寸，属同一类约束冲突。

**验收**：见 §14「仍需人工验收」。

---

## 3. F02：导入入口失效

**证据**：发送方 `RootView.swift:292` 以 `object: nil` 发送 `menuImportFolder`；接收方
`DashboardView.swift:73` 要求 `notification.object as? URL`，否则 `return`——
点击后没有任何反馈（旧版 Electron 同入口正常）。`GalleryView` 空态按钮同样传 `nil`。

**修复**：

- 新增 `GatherAppNotification.importFolderRequest`：语义是「用户请求导入，尚未选目录」，
  由 `GatherAppDelegate` 统一接收并打开目录选择器（与「文件 ▸ 导入文件夹…」⌘O **同一函数**）。
- `menuImportFolder` 保持原语义（**已选好目录但没有可导入 RAW**，载荷必须是非空 URL），
  并在收到 `nil` 时回退到统一入口，不再静默丢弃。
- **竞态修复**：工作台是条件构建页面，跨页触发的请求会随页面销毁而丢失。改由外壳持有
  `NewWorkspaceRequest`（`RootView`），工作台在 `onAppear`/`onChange` 消费；
  ⌘N 与导入共用同一表单，一次点击只出现一个 sheet。

**测试**：`RootViewTests`（路由）保持通过；新增导出范围与任务分层测试见 §15。

---

## 4. F03：全局人脸库入口

**证据**：`RootNavigation.WebPage.persons` 与 `RootView` 的 `.page(.persons)` 分支都存在，
但侧栏只有工作台／当前会话／全局图库三项，没有任何 `.tag(SidebarItem.web(.persons))`——
页面存在而用户不可达。

**修复**：侧栏新增「人脸库」（`person.2`），与「全局图库」并列作为全局一级目的地。
工作区人脸页仍保留工作区内的审核对象范围，两者不互相替代。

---

## 5. F04：导出范围

**证据**：`ExportView.parameters()` 固定 `scope: .session`；`ExportService.filteredPhotos`
对非 `.session` 直接抛 `scopeUnsupported`，且只排除 `status == "removed"`，不读挑片决策。
控制中心却引导「挑片已完成，导出最终成品」。

**修复**：

- **core**：`filteredPhotos` 支持 `.filtered` = **保留片**（读 `culling_decisions` 的 `decision == keep`，
  唯一真相源，不读镜像列）；`.selected` 显式拒绝（不静默降级成整个工作区）。
- **UI**：新增「导出范围」分区（保留片 / 工作区全部照片）+ **张数摘要**，摘要与预览、确认弹窗、
  实际写出来自**同一次** `export.preview` 计划。
- 确认弹窗文案带上范围：「范围「保留片」：将向「…」写入 N 个文件…」。
- 目录或范围一变就重算计划（旧计划立即作废），算不出计划时**不弹确认**。

**测试**：`ExportServiceTests.filteredScopeExportsOnlyKeepDecisions`——
keep 进计划，reject／未决策／已移除都不进；`.selected` 抛 `scopeUnsupported`。

---

## 6. F05：人脸审核的视觉证据

**证据**：簇代表图与成员行都用 `PhotoThumbnailView(path: member.photoPath)`（整图）；
成员行只有序号、文件名、置信度、悬停才出现的移除按钮。

**修复**：

- 新增 `FaceCropThumbnailView`：按检测阶段写入的**左上原点归一化 bbox** 裁出脸部，
  cover 语义（取较大缩放，不变形），非法 bbox 回退整图，解码结果进 `PhotoThumbnailCache`。
- 簇卡片 2×2 蒙太奇改为**人脸裁切**；成员行新增 40pt 人脸裁切缩略图。
- 裁切换算抽成纯函数 `FaceCropThumbnailView.layout(imageSize:bbox:frame:margin:)`，可单测。

**测试**：`ReviewFixTests`——bbox 中心落在裁切框中心、裁切区域覆盖 frame、非法 bbox 回退整图、零尺寸 frame 不产生 NaN。

---

## 7. F07：控制中心的优先级

**证据**：卡片顺序 `阶段 → 待办 → 推荐 → 分析 → 同步 → 当前任务`；`jobs` 只按
`scopeId` 过滤、无状态过滤，22 条已完成任务全部铺开；「待处理事项 · 已挑片但尚未导出」
与「推荐下一步 · 导出成品」指向同一动作。

**修复**：

- 卡片顺序改为 `索引状态 → 阶段 → **当前任务** → 待办 → 推荐 → 分析 → 同步`。
- `SessionControlViewModel` 拆分 `activeJobs / attentionJobs / historyJobs`；
  「当前任务」只列活跃与失败（失败最多 3 行），**已完成历史默认折叠**；
  没有活跃任务时只给一行说明。
- 推荐卡只在**不与待办重复**时渲染（同一动作只保留优先级列表里的那一行）。

**测试**：`ReviewFixTests.jobSplitKeepsHistoryOutOfCurrentTasks` / `onlyHistoryMeansNoCurrentTasks`。

---

## 8. F08：同步状态语言

**证据**：胶囊在 `written > 0` 时显示「已写入待读取」，而控制中心 `syncStatusText` 只判
`failed/conflict/pending/writing`，`written > 0` 时输出「元数据已全部同步」。

**修复**：控制中心与胶囊统一阶梯：
`冲突/失败 → Gather 正在写入 → 待写入 N 项 → 已写入待读取（等待 C1 读取） → 已同步（C1 已读取） → 没有待同步的元数据`；
同步图标同步调整（待写入/写入中/待读取为进行中黄色，只有全部确认才是绿色勾）。

**测试**：`ReviewFixTests` 五条状态矩阵（含「written > 0 不得出现『已同步』」的变异守卫）。

---

## 9. F09：工作区上下文

**证据**：`currentSidebarItem` 对非控制中心的 `sessionTab` 返回 `nil`（侧栏无高亮）；
`SimilarityView` 用 `.navigationTitle("相似度分析")` 覆盖窗口标题（工作区名消失）。

**修复**：

- 所有 `sessionTab` 子页都保持侧栏「当前会话」选中态。
- 相似度页不再覆盖窗口标题：工作区名留在标题，功能名进副标题（`sessionPageChrome(subtitle:)`）。
- 页签行常驻内容区顶部，任一子页都能看到自己在哪个工作区、哪个功能。

---

## 10. F10：人脸页默认落点

**证据**：`FaceKeywordingViewModel.step` 初值恒为 `.analyze`；`recoverAnalysis()` 只恢复
`analysisPhase`，已有结果时仍停在分析页，主按钮是「仅重新聚类」（会还原人工绑定）。

**修复**：新增一次性 `seedInitialStep()`——首次 `load()` 后若 `analysisDone || !clusters.isEmpty`
且用户未显式指定步骤，则落到 `.review`；后续 `load()`（分析完成、动作刷新、事件回流）
不再改步骤，不会把用户从写回步骤拉走。

---

## 11. F11：设置分组与保存机制

**核验更正**：「没有保存反馈」不成立——`save()` 会写「已保存 X」提示（`:327`）。
成立的是：文本/数字只在 `onSubmit` 保存（无失焦提交），与下拉「选择即保存」不一致；
首屏被模型路径／输入尺寸／特征维度占据。

**修复**：

- 首屏顺序：**保存规则说明 → 语言 → Capture One 状态 → 图片处理 / 写回 / 元数据 / 缓存 → 人脸分析**；
  模型与推理、数据库、人脸算法参数折叠进「**高级：模型、推理与性能参数**」（默认收起）。
- 文本/数字改为**失焦或回车**提交；`save()` 在值未变化时直接返回（不写库、不提示），
  避免 Tab 穿过字段刷出一堆「已保存」。

---

## 12. F12：人脸成员动作可达性

**核验更正**：`opacity(0)` 不改变命中区与可聚焦性，「键盘拿不到」不成立；
成立的是：动作只在悬停时可见（焦点态不可见）、`children: .combine` 使移除动作对 VoiceOver 不可达、
置信度被读两遍。

**修复**：成员行移除按钮在**悬停或键盘焦点**任一状态可见；置信度文字对无障碍隐藏、
只由带单位的 `accessibilityLabel` 读一次；整行改 `.accessibilityElement(children: .contain)`，
文件名／置信度／移除动作各自是可用元素。

---

## 13. F13：参数与术语规则

**证据**：相似度／人脸用 `DisclosureGroup` 折叠高级参数，重复页把预设、滑杆、数字框、范围说明
和两个「开始扫描」同时摆在首屏；`cluster.size`（人脸样本数）被标成「N 张」。

**修复**：

- 重复页阈值滑杆与范围说明折叠进「高级：相似阈值」，与本页主动作分层；
  空态不再放第二个同权「开始扫描」。
- 人脸计数统一为「**N 个人脸样本**」；仅当成员**未被截断**（`members.count == size`）时
  才补「· M 张照片」，截断时不猜数字。

**测试**：`ReviewFixTests.sampleCountDistinguishesPhotos` / `truncatedMembersDoNotGuessPhotoCount`。

---

## 14. 仍需人工验收（本轮未覆盖）

| 项 | 为什么不能只靠单测 |
| --- | --- |
| F01 崩溃 | 约束循环只在真实显示周期出现；单测可以防住明显布局冲突，但替代不了连续导航/缩放/检查器开关的实测 |
| F02 导入入口 | 「一次点击只出现一个选择器、取消不创建工作区」只能交互验证 |
| F04 实际导出 | 本轮只验证计划与范围语义；未写出文件 |
| F05 视觉可辨认性 | 裁切是否「足够辨认」是视觉判断，需要在真实人脸样本上确认 |
| F11 保存矩阵 | 编辑／Tab／回车／关闭重开／失败恢复需逐项实测 |
| 深色／英文／最小窗口／VoiceOver | 本轮未覆盖 |

---

## 15. 本轮验证记录

- `swift build`（gather-app，含 GatherCore）：通过。
- `swift test`（gather-core）：952 项，1 项失败为环境所致
  （`波浪号路径会被展开` 需要在 home 目录写探测文件，被本轮沙箱拒绝 `Operation not permitted`），与本次改动无关。
- `swift test`（gather-app）：见提交时输出；本轮新增 `ReviewFixTests`（F05／F07／F08／F13 共 11 条）。
- 沙箱内构建需 `--disable-sandbox --cache-path … --scratch-path …`（SwiftPM 的 manifest 沙箱在受限环境下无法嵌套）。
