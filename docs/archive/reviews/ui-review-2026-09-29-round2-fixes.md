# UI 验收（第二轮）修复台账：N01–N10

> 上一轮：[UI／交互审查修复台账](ui-review-2026-09-29-fixes.md)
> 来源：验收报告《Gather UI 修复验收与下一轮问题报告》（2026-09-29，10 项：P1×2、P2×7、P3×1）
> 本文件记录**核验 → 修复 → 可测量证据**，不重复报告原文。

---

## 0. 本轮最重要的发现：崩溃被量化了

第二轮验收的崩溃日志里出现了**决定性帧链**：

```
UpdateGroup.enqueueAction(reason:_:)
AppKitPlatformViewHost.enqueueLayoutInvalidation()
SplitViewChildController.hostingView<A>(_:didUpdateMinSize:maxSize:)
NSHostingView.SizeConstraints.update(from:)
NSHostingView._willUpdateConstraintsFor...
→ __NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke
→ NSGenericException → SIGABRT
```

它把「约束循环」翻译成了一条可测量的性质：**页面内容向 NavigationSplitView 报告的
最小宽度**（SplitViewChildController 询问的就是它）。于是本轮先把这条性质变成测试，
再照着数字修：

| 对象 | 修复前最小宽度 | 修复后 |
| --- | --- | --- |
| 挑片页（1 张照片，workbench） | **876pt** | **440pt** |
| 挑片页（空范围） | 876pt | 365pt |
| 会话页签行本身 | 532–576pt | 576pt（宽窗口）/ ≈100pt（窄窗口自动退化为菜单） |
| 控制中心 / 人脸 / 重复 / 导出 | — | 576pt（全部 ≤ 680pt 预算） |

可用的内容区宽度：最小窗口 860pt − 侧栏 180pt = **680pt**；默认窗口 1180pt − 侧栏
200pt = 980pt。876pt 在最小窗口下**无解**，AppKit 只能反复重算约束。

**两处根因**：

1. `CullingView.toolbarRow` 第一行是没有滚动容器的 HStack：最小宽度 = 所有控件最小
   宽度之和（undo/redo + 范围分段 240 + 自动前进 + 对比分段 150 + 质量分析块 + 边距）。
   现在与第二行一样放进横向 ScrollView，该行的最小宽度不再等于内容总宽。
2. `.inspector` 的**理想列宽**会计入承载视图的最小宽度（实测 min 260 / ideal 300 时
   贡献 300pt）。它叠加在页签行 532pt 上正好 = 876pt。页签行改为
   `ViewThatFits`（宽窗口分段控件 / 窄窗口菜单），检查器列宽收窄到 ideal 260。

**回归守卫**：[LayoutBudgetTests.swift](desktop/native/gather-app/Tests/GatherAppTests/LayoutBudgetTests.swift)
用 `NSHostingView.fittingSize`（与 SplitViewChildController 同一份数据）断言
「挑片页 workbench / 空态 / 其余四个会话页 / 页签行」都不超过 700pt 预算。

---

## 1. 逐条核验与修复

| # | 发现 | 核验 | 修复位置 |
| --- | --- | --- | --- |
| N01 | 挑片仍崩溃 | 属实（新日志 + 帧链 + 实测 876pt） | §0 |
| N02 | 人脸裁剪错位／代表图塌成色条 | 属实（两处独立缺陷） | §2 |
| N03 | 改变体后计划不更新 | 属实 | §3 |
| N04 | 切页签清空导出草稿 | 属实 | §4 |
| N05 | 「去导出」默认全部照片 | 属实 | §5 |
| N06 | 模型路径只回车保存 | 属实 | §6 |
| N07 | 全局图库点照片丢目标 | 属实 | §7 |
| N08 | 运行态无文件/编辑菜单 | 属实（SwiftUI 覆盖 NSApp.mainMenu） | §8 |
| N09 | 图库筛选标签重复、值被截断 | 属实 | §9 |
| N10 | 空态重复入口、新建弹窗留白 | 属实 | §10 |

---

## 2. N02：人脸裁剪（两个独立缺陷）

**缺陷 A：平移公式漏了「居中项」。** 图像在 ZStack 里是居中布局，左上角不在 frame
原点；原公式 `frame.width/2 − box.midX·displayed` 只在左上角重合时成立。
正确平移量 = `(0.5 − box.midX)·displayed.width`（y 同理）。
上一轮的测试把同一个错误假设带进了断言，所以「测试通过但仍然错裁」。

**缺陷 B：蒙太奇单元没有固有高度。** `FaceCropThumbnailView` 由 GeometryReader
驱动，没有固有高度；放进 `LazyVGrid + .aspectRatio(1, .fit)` 后，行的理想高度退化成
GeometryReader 的默认值（约 10pt），代表图塌成一条色带。现在由
[FaceClusterMontage](desktop/native/gather-app/Sources/GatherApp/Support/FaceClusterMontage.swift)
在外层算好正方形边长再下发给单元（`(边长 − 间距) / 2`）。

**测试（不再复述公式）**：`ReviewFixTests` 用 `ImageRenderer` 把视图渲染成位图，
按**像素**断言：

- 400×200 蓝底 + 目标人脸红块 → 裁切后**中心像素必须是红**、上下边缘仍是图像背景蓝
  （证明人脸被搬到中心，且裁切落在图像内部，没有露出占位底色）；
- `margin = 0` 的紧框同样对齐；
- 蒙太奇按 200pt 宽度渲染后高度 ≥ 180pt（塌陷时只有十几点）。

这两条测试对旧实现是**必失败**的（旧公式下中心像素会落在画面外）。

---

## 3. N03：导出计划指纹

`ExportViewModel` 新增 `planSignature`（范围 / 变体 / 格式 / 目录 / 命名 / XMP / 水印）
与 `plannedSignature`、`isPlanStale`：

- 任何影响计划的参数变化 → 立即作废旧计划（`preview = nil`）→ 重算；
- 用**请求代数**丢弃过期响应：先发的慢请求不会覆盖后发的新选择；
- 张数摘要只在 `!isPlanStale` 时显示，绝不用旧参数的数字冒充当前选择。

测试：`ReviewFixTests.planSignatureCoversPlanAffectingOptions`。

---

## 4. N04：会话级草稿

页面是按目的地条件构建的，切页签会销毁页面的 `@State` 视图模型。现在由外壳持有
`SessionDraftCache`（按工作区 id 键控，普通引用类型，body 期间写入不触发更新循环）：

- `ExportViewModel`：目录 / 格式 / 命名 / 范围 / 水印 / 上次计划全部保留；
- `FaceKeywordingViewModel`：步骤、选中簇、编辑中的角色名与关键字保留；
- 深链（人物库「前往人脸审核」）在复用缓存 VM 时补一次角色过滤，不会被缓存吞掉；
- 两个工作区互不串状态（按 sessionId 隔离）。

**未覆盖**：滚动位置（视图局部状态）仍需重进后重新滚动，已在 §11 标注。

---

## 5. N05：导出入口意图

新增 `ExportRangeIntent`：

- 控制中心的「去导出」（待办 export_pending 与推荐下一步 export）传 `.picks` →
  导出页首次打开默认**保留片**；
- 工具栏页签直接进入传 `.allPhotos`（或 nil）→ 默认工作区全部照片；
- `applyRangeIntentIfNeeded` **只播种一次**：用户手动改过范围后，再次进入不会被覆盖；
- 保留片为 0 时仍然只显示「当前没有保留的照片…」的说明，不静默回退全部。

---

## 6. N06：模型路径与普通字段同一套保存语义

`modelPathRow` 补上 `focused($focusedFieldKey, equals: key)` + 失焦提交，与首屏
「文本与数字在离开输入框或按回车时保存」的承诺一致；回车走 `commitModelPath`
（先结束焦点再显式保存一次）。

---

## 7. N07：跨工作区照片目标与工作区记忆

- 图库卡片点击改为 `onOpenPhoto(sessionId, photoId)`：`RootNavigation` 记录待打开
  照片，图库页加载完成后**一次性打开该照片的查看器**（并先把本地搜索/筛选清回默认，
  避免目标被隐藏）；离开图库页清空，不会重复弹出；
- 卡片右键菜单同时提供「打开所在工作区」作为显式第二动作；
- 新增 `lastSessionId`：离开工作区页面后侧栏**仍保留「当前会话」入口**，
  一键回原工作区（`sidebarSessionId = currentSessionId ?? lastSessionId`）。

测试：`ReviewFixTests.sidebarKeepsLastSession` / `galleryCarriesPendingPhoto`。

---

## 8. N08：菜单在 SwiftUI 场景里声明

**根因**：SwiftUI 在场景装配时用自己构建的主菜单替换 `NSApp.mainMenu`，
`GatherAppDelegate.installMenu` 建的「文件/编辑」在运行态根本不生效。

**修复**：新增 [GatherAppCommands](desktop/native/gather-app/Sources/GatherApp/Host/GatherAppCommands.swift)
并用 `.commands { }` 挂到 WindowGroup：

- 文件：新建工作区 ⌘N、导入文件夹 ⌘O、从 Capture One 导入 ⌘⇧I（替换 SwiftUI 的 New Item 组）；
- 显示：显示/隐藏侧栏 ⌘⌥S；
- 帮助：Gather 帮助。

动作仍走通知，与工具栏按钮、深链共用同一条实现（新增
`captureOneImportRequest`，AppDelegate 收到后调用同一个 `importFromCaptureOne`）。

**菜单语言**：`Info.plist` 补 `CFBundleLocalizations = [en, zh-Hans]`，
build.sh 把 SPM 资源 bundle 里的 `.lproj` 同步复制进**主 bundle**——系统菜单
（关于/隐藏/服务/窗口/帮助）由 macOS 按主 bundle 的本地化集合渲染，此前主 bundle
是英文单语，于是中文界面配英文系统菜单。

---

## 9. N09：图库筛选标签

`filterSelect` 改为「左侧短字段名（Text）+ 右侧只显示当前值的 Picker（labelsHidden）」，
消除同一行出现两次「全部星级」；三个主筛选放进 `ViewThatFits`：宽窗口一行三列，
放不下时整组竖排，字段名与完整当前值在两种排布下都可读。

---

## 10. N10：空态与新建弹窗

- **人脸库空态**：右侧不再放第二个「新建人物」，也不再提示「从左侧列表选择一个人物」
  （那是一个空列表）；改为说明建库后的用途，主动作唯一留在左侧空态 + 工具栏。
- **新建工作区弹窗**：固定 520×440 → 520×(本地 330 / Capture One 430)，消除 3 行表单
  下方的 200pt 空白；名称的长提示从输入框 placeholder 移到分组脚注，不再被标签列
  挤成「选择文件…」。

---

## 11. 仍需人工验收

| 项 | 为什么单测不够 |
| --- | --- |
| N01 | 本轮把崩溃机制量化成「最小宽度预算」并用拟合尺寸守卫，但**真机连续导航/缩放/检查器拖动**仍必须实测（新增 crash log 为判定依据） |
| N02 | 像素测试能证明「脸在中心且未塌陷」，但「是否足够辨认」仍需人眼在真实人像上确认 |
| N04 | 草稿恢复已按工作区隔离；滚动位置未纳入（视图局部状态） |
| N05 | 需要混合 keep/reject/pending 的真实样本确认预选范围与张数 |
| N06 | 需要真实模型路径的持久化试验（写入后重开设置验证） |
| N07 | 需要跨多个工作区的搜索结果验证「点哪张开哪张」与返回上下文 |
| N08 | 需要冷启动 / 开关设置窗口 / 切工作区后的菜单完整性截图，以及中英语言一致 |
| N12 类深色/英文/窄窗口 | 本轮仍未覆盖 |

---

## 12. 本轮验证记录

- `swift build`（gather-app）：通过。
- `swift test`（gather-app）：**250 项全绿**（含新增 `LayoutBudgetTests` 6 条、
  `ReviewFixTests` 21 条）。
- `swift test`（gather-core）：见提交输出（本轮未改 core 逻辑）。
- 门禁：`check-command-surface.sh`、`check-no-legacy.sh` 均通过。
- 构建命令（沙箱内需要）：`swift build --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch`。
