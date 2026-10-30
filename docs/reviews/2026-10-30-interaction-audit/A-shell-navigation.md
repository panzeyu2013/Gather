# A · 应用外壳、导航与交互骨架（只读审计）

审计范围：`GatherUI/Shell/*`、`GatherUI/Interaction/*`、`GatherApp/*`、`Support/SessionStore | SessionWorkspace | WorkspaceIntent | GatherEventCenter | PageVisibility | MenuCopy`。
方法：静态阅读 + 尺寸核算（未构建、未运行）。所有结论带 file:line；需实机确认的条目单列在最后一节。

---

## 结论

1. **层级设计是对的，层级之间的语义没有收口。** 侧栏=工作区、页签=页面、窗口标题=会话名，三级结构清晰；但同一页面在**页签条 / 窗口副标题 / 页内标题**上是三个不同名字（7/7 页不同名），返回键又同时承担页级返回、会话级退出、兜底回工作台三种语义，且没有可见目标。用户看到的是"三个标题 + 一个猜不出目的地的箭头"。
2. **返回语义有可复现的"跳级"与"横跳"。** `open(_:in:)` 只在离开图库/相似度时写 `previousRoute`（RootShellNavigation.swift:104-114），于是"图库→控制中心→人脸→返回"会**跳过控制中心直接落回图库**；而侧栏切换会话被 `enterSession` 当成页级跳转写入返回槽（:202-210），"在 A 会话图库里点侧栏 B 会话，再按返回"会**横跳回 A 会话的图库**。这是本轮最实的两个交互缺陷。
3. **最小窗口 860 下，7 段页签 100% 退化为下拉菜单。** 阈值写死 620pt（GatherSessionPage.swift:115-125），但中文页签条实际只需约 354pt、英文约 535pt；页签行可用宽 = 内容区宽 − 66，故需窗口 ≥ 906pt（侧栏 ideal 220）才出现标签条。也就是说"最小窗口"验收场景里，7 个页面变成一枚 26pt 下拉胶囊，用户学不到还有 7 个页面。
4. **布局预算 680pt 只在侧栏拖到最窄时成立。** `contentMinWidth` = 860 − 180 = 680（GatherChromeMetrics.swift:16），而侧栏默认 ideal 220 → 内容 640，拖到 max 260 → 600；LayoutBudgetTests 用 680 断言"展开检查器不超预算"（LayoutBudgetTests.swift:369-377），默认侧栏下就已透支 40pt。第 3、4 条同一根因：**预算只按最小值算，没按默认/最大值算**。
5. **命令体系"能用但不可学"。** 菜单只有 4 项 + 挑片撤销/重做；全仓 30 处 `.keyboardShortcut` 里约 19 处是弹层的 Esc/Return 默认动作，剩下的命令键只有 5 个进菜单（⌘N/⌘O/⌘⇧I/⌘⌥S/⌘Z），⌘[、⌘R、⌘K、⌘⇧N、⌘−/0/= 都不在菜单里。缺 ⌘F 搜索、⌘1–7 切页签、⌘] 前进、Esc 退出层、空格预览；而 7 个页签既无快捷键、又是 `.buttonStyle(.plain)`（默认"键盘导航"设置下 Tab 不可达）——**页签切换没有键盘路径**。同时 `CommandGroup(replacing: .undoRedo)` 在挑片页无条件替换系统撤销（GatherAppCommands.swift:39-47），导致挑片关键词输入框里的 ⌘Z 撤销的是照片裁决。

---

## 发现

### P0

无。外壳不存在阻断主流程、或不可恢复数据损失的路径；下述 P1 均为"能完成但会困惑/绕路"级别。

---

### P1

#### P1-1 返回键"跳级"：经过的普通页签不进入返回历史

**位置** `GatherUI/Shell/RootShellNavigation.swift:104-114`

~~~swift
func open(_ page: SessionPage, in sessionId: String) {
    if case .session(let currentId, let currentPage) = route, currentId == sessionId {
        if currentPage != page,
           currentPage == .gallery || currentPage == .similarity {
            previousRoute = route
        }
        route = .session(sessionId: sessionId, page: page)
~~~

**现象** 只有"离开图库/相似度"才写返回槽；普通页签（控制中心/人脸/重复/挑片/导出）之间互切不写。
**用户影响** `图库 → 控制中心 → 人脸 → 返回` 落到 **图库**，跳过控制中心；`图库 → 控制中心 → 重复 → 挑片 → 返回` 同样一步退回图库。用户点一次返回跨越了 2–4 次自己刚做的页签切换，只能理解为"返回坏了"。返回键的语义既不是"上一页"，也不是"层级上移"，而是"上一次离开图库的位置"。
**修复建议** 二选一并写进契约：①维护 `[AppRoute]` 页级历史栈（页签切换 push，返回 pop）；②明确"返回=退出会话"，页签互切不入栈，并把箭头换成退出语义（`chevron.backward` → `xmark` / `rectangle.portrait.and.arrow.right`）。否则用户永远猜不到目的地。

#### P1-2 侧栏切换会话被记成页级跳转 → 返回横跳回上一个会话

**位置** `GatherUI/Shell/RootShellNavigation.swift:202-210`（写入）、`RootShellSidebar.swift:158-167`（触发）

~~~swift
private func enterSession(_ sessionId: String, page: SessionPage) {
    if route.isSession {
        previousRoute = route
    } else {
        sessionOrigin = route
        previousRoute = nil
    }
    route = .session(sessionId: sessionId, page: page)
}
~~~

**现象** 侧栏点击会话走 `navigation.openSession(id)` → `enterSession`；当路由已是会话页时，把"当前会话的页"写进 `previousRoute`。
**用户影响** 侧栏在用户心智里是**全局导航**（与工作台/资料库同级），却被实现成页级跳转：在 A 会话图库点侧栏 B 会话，新页面的返回箭头把用户送回 **A 会话的图库**，侧栏高亮同时从 B 跳回 A——用户会以为自己点错了。另外每次经侧栏切会话都被重置到控制中心（`openSession` 固定 `.control`），各会话里的页签位置全部丢失。
**修复建议** 侧栏会话项视为顶层导航：与 `selectDashboard()` 一样`clearReturnState()`（进会话即清页级返回槽，返回=回工作台）；若要保留"回到上次所在页"，按会话记忆 `lastPageBySession`，不要复用 `previousRoute`。

#### P1-3 最小窗口下 7 段页签必然退化（阈值 620 与真实宽度不匹配）

**位置** `GatherUI/Interaction/GatherSessionPage.swift:115-125`（阈值）、`:126-130`（行内边距）、`:132-161`（标签条）

~~~swift
GeometryReader { proxy in
    if proxy.size.width >= 620 {
        tabBar.fixedSize()
    } else {
        compactMenu.fixedSize()
    }
}
~~~

**核算（11pt = `GatherFont.labelRegular` = `.subheadline`，GatherStyle.swift:28）**
- 中文标签文字 22+33+44+22+22+22+22 = **187**；每片左右内边距 10×2×7 = 140；片间距 2×6 = 12；组分隔线 1+8 = 9；容器内边距 3×2 = 6 → 标签条 **≈354pt**。
- 英文（en.lproj:562-565、257-267）Browse/Similarity/Control Center/Faces/Duplicates/Culling/Export ≈ 368 + 140 + 12 + 9 + 6 → **≈535pt**。
- 页签行可用宽 = 内容区 − 32（左右 16，GatherChromeMetrics.swift:24）− 26（返回）− 8（间距）= **内容区 − 66**；满足 620 需内容区 ≥ **686**。
- 860 − 180（侧栏最窄）= 680 → 614 **< 620 → 菜单**；860 − 220（ideal）= 640 → 574 → 菜单。

**用户影响** 在 860 最小窗口（以及任何 860–905 的窗口）里，7 个页面永远只以"当前页名 + chevron"的 26pt 胶囊出现：新用户不知道有 7 个页面，老用户每次切页多两次点击；窄窗菜单里也没有当前项勾选（`:186-203` 用的是普通 Button），打开菜单后唯一能判断当前页的线索是胶囊上的文字。真实内容只需 354pt，阈值把 266pt 的可用空间当成了"窄"。
**修复建议** 阈值改为"标签条实测宽度 + 24pt 缓冲"（或用 `ViewThatFits` 的 `.frame(minWidth: 380)` 变体），中文界面在 860 下即恢复标签条；菜单态改用 `Picker` 并勾选当前页。

#### P1-4 布局预算按"最窄侧栏"计算，按默认侧栏就已透支

**位置** `GatherUI/DesignSystem/Tokens/GatherChromeMetrics.swift:8-16`、`Shell/RootShellToolbar.swift:21`、`Tests/GatherAppTests/LayoutBudgetTests.swift:369-377`

~~~swift
public static let windowMinWidth: CGFloat = 860
public static let sidebarMinWidth: CGFloat = 180
public static var contentMinWidth: CGFloat { windowMinWidth - sidebarMinWidth }   // 680
~~~

~~~swift
let total = stripWidth + contentWidth + GatherChromeMetrics.inspectorIdealWidth
#expect(total <= Self.contentMinWidthBudget, "860 最小窗口展开检查器会触发 N01 约束循环")
~~~

**现象** 预算 680 = 860 − 180（侧栏最小）。但侧栏 `ideal: 220 / max: 260`（GatherChromeMetrics.swift:11-13，RootView.swift:114）：默认 860 窗口真实内容区 **640**，侧栏拖到底 **600**。测试用 680 断言"页签行 + 挑片内容 + 检查器 220 放得下"，通过的其实是"侧栏拖到最窄"的假想窗口。
**用户影响** 默认窗口（860，侧栏 220）展开挑片检查器比测试保证少 40pt；侧栏拖宽后少 80pt。这正好是 N01 记录过的"检查器展开触发 AppKit 约束循环"的条件区，只是被预算常量掩盖——测试绿，真机仍可能挤压/裁切。
**修复建议** 预算改为 `windowMinWidth − sidebarMaxWidth`（600）并据此重排页面最小宽度；或把 `navigationSplitViewColumnWidth` 的 max 降到与预算自洽（如 200），二者必须有一处让位。测试至少应断言"默认 ideal 侧栏"下的宽度。

#### P1-5 7 个页签没有任何键盘路径

**位置** `GatherUI/Interaction/GatherSessionPage.swift:132-161`（无 shortcut）、`:218-220`（`.buttonStyle(.plain)`）

~~~swift
Button(action: action) { ... }
.buttonStyle(.plain)
.onHover { hovering in ... }
.accessibilityAddTraits(isSelected ? .isSelected : [])
~~~

**现象** 页签是 `.plain` Button，没有 `.focusable()`、没有 `.keyboardShortcut`、没有菜单入口。macOS 默认"键盘导航：仅文本框与列表"下，plain 按钮不进 Tab 环。
**用户影响** 键盘用户无法切页签：唯一路径是鼠标点标签，或窄窗下先点开 Menu。相比 ⌘1–7 的惯例、`⌘[` 已存在的"半套键盘支持"，这是明显的断层。
**修复建议** 给 7 个页签挂 `⌘1…⌘7`（"显示 > 工作区页面"菜单里同步列出、带勾选），至少覆盖浏览/挑片/导出三个高频页；同时补 `.focusable()` 与 `⌘]` 前进。


---

### P2

#### P2-1 同一页面三个名字：页签 / 窗口副标题 / 页内标题互不一致

**位置** `Interaction/GatherSessionPage.swift:30-41`（`.navigationSubtitle`）、`Interaction/SessionPage.swift:25-35`（页签名）、各页 subtitle：
- 浏览 vs `l10n("图库")`（GalleryView.swift:97）
- 相似度 vs `l10n("相似度分析")`（SimilarityView.swift:88）
- 控制中心 vs `l10n("工作区控制中心")`（SessionControlView.swift:106）
- 人脸 vs `l10n("人脸检测与聚类")`（FaceKeywordingView.swift:68）
- 重复 vs `l10n("重复照片检测")`（DuplicatesView.swift:57）
- 挑片 vs `l10n("挑片与写回")`（CullingView.swift:90）
- 导出 vs `l10n("按统一格式、命名规则导出照片及元数据")`（ExportView.swift:49；en.lproj:1252 = 68 字符）

**现象** 7 页的窗口副标题**全部**≠页签名：没有任何一页的标题栏文案与页签一致（"图库↔浏览""工作区控制中心↔控制中心""人脸检测与聚类↔人脸"…）；导出页副标题更是一整句操作说明。
**用户影响** 标题栏（会话名 + 副标题）与页签条各说一套名字，用户建立不起"图库=浏览"的映射。导出页的 18 字说明在 860 窗口的 `.navigationSubtitle` 单行里必然尾截断，半句话比没有更糟。这不是"重复标题"，是**同页多名**。
**修复建议** 副标题只装"页面身份之外的信息"（照片数、筛选状态、导出范围），页面身份只由页签表达；导出页说明句移进内容区（那里已有 `l10n("导出设置")` 的 h1，ExportView.swift:78）。

#### P2-2 侧栏"最近工作区"最多 5 条、当前会话强制置顶、无"查看全部"

**位置** `Shell/RootShellSidebar.swift:83-91`

~~~swift
var list = viewModel.sessions
if let currentId = currentSidebarSessionId,
   let index = list.firstIndex(where: { $0.id == currentId }) {
    let current = list.remove(at: index)
    list.insert(current, at: 0)
}
return Array(list.prefix(5))
~~~

**现象** 当前会话搬到首位后截断到 5 条。
**用户影响** ①第 6 个及以后的会话在侧栏**不可达**，只能回工作台找；②列表组成随导航变化——每切一次会话"最近工作区"就重排一次，刚点过的行跳到第一行、第 5 行消失，用户失去空间记忆（列表本应稳定）。
**修复建议** 不重排：当前会话不在前 5 时**追加**一条并加分隔；标题右侧加"全部工作区"入口（回工作台）；或把"最近 5 个"改成可展开分组。

#### P2-3 侧栏首载失败 = 假空态"暂无工作区"，无错误无重试

**位置** `Support/DashboardViewModel+Load.swift:20-26` + `RootShellSidebar.swift:43-48`

~~~swift
func refreshSidebarSessions() async {
    do { sessions = try await listSessions() }
    catch { /* 保留旧列表；不设置 phase / actionError */ }
}
~~~

~~~swift
if recentSidebarSessions.isEmpty, fallbackSessionId == nil {
    Text(l10n("暂无工作区"))
~~~

**现象** 首载（`sessions` 本来就空）失败时静默吞错，渲染走"暂无工作区"；`sessions.isEmpty` 也无法区分 loading / empty / failed。
**用户影响** 数据库锁、磁盘满、迁移失败等场景下，侧栏告诉用户"你没有工作区"——用户会去新建而不是排查；且没有重试入口（只能靠切页面触发 RootView.swift:208-211 那次 `refreshSidebarSessions`）。
**修复建议** 侧栏分三态：空（真空 + "去工作台新建"）/ 加载（占位行）/ 失败（一行"加载失败 · 重试"，只影响侧栏，不污染工作台错误）。

#### P2-4 会话工作区缺失时是无限转圈，无文案无出口

**位置** `Shell/RootShellDetail.swift:37-47, 51-55`、`Shell/SessionPageHost.swift:49-53`

~~~swift
case .session(let sessionId, let page):
    if let workspace = sessionStore.workspaces[sessionId] { ... }
    else { loadingPlaceholder }   // 裸 ProgressView(.large)，铺满
~~~

**现象** `workspaces[id] == nil` 时只画一个大 spinner：没有文案，也没有返回按钮（返回按钮在 `GatherSessionPage` 里，页面根本没建出来）。
**用户影响** 只要路由指向的会话被 `endSession`（删除会话的 `onSessionDeleted`，RootView.swift:94-96）或 LRU 竞态清掉，用户就停在**永久转圈页**，页面内没有任何出口，只能靠侧栏离开——界面看起来还在努力，这是最难受的一类"落空"。
**修复建议** 占位态补失败分支：`「无法打开此工作区」+「返回工作台」+「重试」`，主按钮直接调 navigator 返回。

#### P2-5 ⌘Z 在挑片页被全局替换，抢掉关键词输入框的文本撤销

**位置** `GatherApp/GatherAppCommands.swift:39-47`、`Culling/CullingKeywordPanel.swift:74, 82-88`、`Interaction/CullingHistoryActions.swift:4`

~~~swift
if let history = cullingHistory {
    CommandGroup(replacing: .undoRedo) {
        Button(l10n("撤销")) { history.undo() }.keyboardShortcut("z", modifiers: .command)
~~~

**现象** `CullingHistoryActions.swift:4` 的前提写着"挑片页没有文本输入框"，但 `CullingKeywordPanel` 有 `inputRow` 与建议列表，由 `@FocusState inputFocused` 驱动（:74、:104-110）。
**用户影响** 在挑片页输入关键词时按 ⌘Z，撤销的是**上一张照片的裁决**（可能已写入数据库），输入框里的文字不动；用户会以为"撤销没生效"再按一次，连续撤销多张照片的评级。这是本案最接近数据事故的一条交互缺陷。
**修复建议** 只在"焦点不在文本框"时替换 `.undoRedo`（把 `isTextEditing` 一并放进 focused-scope，或 TextField 聚焦时撤掉 `cullingHistory` 注入）；或改用 `CommandGroup(after: .undoRedo)` + 不同快捷键。

#### P2-6 错误 Toast 的恢复出口只有 5 秒，且被祖先 `allowsHitTesting(false)` 包住

**位置** `DesignSystem/Components/GatherToast.swift:86-90, 126, 149-165`、`Shell/RootShellOverlay.swift:74-82`

~~~swift
.padding(16)
.allowsHitTesting(false)        // :126 容器
...
Button(actionTitle) { action(); onDismiss() }
    .allowsHitTesting(true)     // :156 子按钮
~~~

**现象** 容器关闭命中测试以便点击穿透到页面，子按钮再声明 true。按 SwiftUI 语义，祖先 `false` 截断整棵子树的命中测试，后代的 `true` 无法恢复；叠加 `:86-90` 的 5s 自动消失。
**用户影响** "导入失败：… · 重试"（RootShellOverlay.swift:74-82）是本应用唯一的导入失败恢复入口：若按钮确实不可点，用户看到的是装饰性"重试"；即使可点，5 秒后连错误文案一起消失，来不及读完再决策。
**修复建议** 错误类 Toast 不自动消失（或 ≥15s）；"重试"移出可交互容器（例如改用错误横幅），Toast 只负责提示。

#### P2-7 导入完成无条件把用户拽到新会话图库

**位置** `Shell/RootShellOverlay.swift:65`

~~~swift
// 深链/导入完成语义对齐旧版 App.tsx:34-64：落点浏览页（图库）。
openGallery(sessionId)
~~~

**现象** 任何导入完成事件都执行 `openGallery`，不判断当前是否正在别的会话里编辑。
**用户影响** 后台导入（拖入 200 张 RAW）在用户已经开始在另一个会话挑片/填导出参数时完成，界面被整体切走：正在编辑的表单、选择、滚动位置全部丢失（页面按目的地条件构建，离开即销毁）。对目录作用域这种长任务，这是高频打断。
**修复建议** 只在当前是工作台/图库/无会话页时自动跳转；否则只出 Toast 并带"查看"动作，把导航权交还用户。

#### P2-8 关窗后应用近乎"变砖"：File 菜单全灰、无 ⌘N、唯一出口藏在 Window 菜单底部

**位置** `GatherApp/GatherApp.swift:42`（`Window` 单实例场景）、`RootView.swift:198-200`（`onDisappear { commandCenter.clearHandlers() }`）、`GatherAppCommands.swift:64-68`、`GatherAppDelegate.swift:119-129`

~~~swift
CommandGroup(after: .windowList) {
    Button(l10n("显示主窗口")) { openWindow(id: GatherWindowID.main) }
}
~~~

~~~swift
guard let main = sender.windows.first(where: {
    $0.identifier?.rawValue.hasPrefix(GatherWindowID.main) == true
}) else { return true }   // 找不到也返回 true（= 我已处理），AppKit 不再兜底
~~~

**现象** ⌘W 关窗 → `onDisappear` 清空 handler → `installed` 为空 → 新建/导入/C1 导入全部置灰（这条路径本身**正确**，不是"错误暗示"）。重开路径两条：①Window > 显示主窗口（无快捷键）；②Dock 点击，但 `Window` 场景关窗后通常已无该 NSWindow，`first(where:)` 返回 nil → 返回 `true` 却什么都没做。
**用户影响** 用户合上窗口后按 ⌘N（无反应、菜单灰）、点 Dock（可能无反应），只能在一堆菜单里找底部那一行。重开后 `@State navigation` 重新初始化（RootView.swift:49, 75），**回到工作台，会话/页签/滚动位置全丢**。
**修复建议** 无窗口时也让 ⌘N、显示主窗口可用并等价于 `openWindow(id:)`；`applicationShouldHandleReopen` 找不到窗口时返回 `false` 交给 AppKit，或直接 `openWindow`；用 `RootNavigation` 持久化 route 做恢复。

#### P2-9 菜单文案："显示/隐藏侧栏"斜杠标题、无勾选态

**位置** `Support/MenuCopy.swift:40, 51`（key `l10n("显示/隐藏侧栏")`）、`GatherAppCommands.swift:108-112`

**现象** focused-scope 取不到时回退成 `显示/隐藏侧栏`；取到时是"隐藏侧栏/显示侧栏"但没有 `Toggle` 勾选态。
**用户影响** macOS 惯例是"☑︎显示侧栏"。斜杠标题在菜单里读起来像两个动作挤在一起；且菜单不告诉用户当前状态，只有文案在切换，菜单项宽度会随状态跳。
**修复建议** 改用 `Toggle(l10n("侧栏"), isOn:)` 或在标题前加勾选标记，标题固定为"显示侧栏"。

#### P2-10 高对比度只依赖 0.5pt 描边与很窄的填充差

**位置** `Interaction/GatherSessionPage.swift:151-158, 234-252`（选中片）、`Tokens/GatherTheme.swift:48-86`（`controlSelection` / `hairline` 的 HC 值）

**现象** 选中页签 = `controlSelection` 填充（HC-light `#FFFFFF` vs 轨道 `#E8E8E8`）+ `hairline` 0.5pt 描边（HC-light `#00000059`）+ 2pt 阴影 + 文字 `.primary` / `.secondary`。
**用户影响** "提高对比度"下，填充差只有约 8% 亮度、描边仅 1 物理像素且 35% 透明；真正区分选中项的只有文字色差。低视力用户在 11pt 小字上很容易认错当前页，而这正是"当前页"唯一的状态指示。
**修复建议** HC 下把选中片换成 accent 的 12–15% 底 + 1.5pt 不透明描边（或直接用系统 Selection 色）；不要用阴影表达状态（HC / 减少透明度会吃掉它）。

#### P2-11 设计规则违例：工具栏里裸写 `.font(.callout)`

**位置** `Support/C1StatusCapsule.swift:225`

~~~swift
Text(visual.label)
    .font(.callout)
~~~

**现象** `docs/design/appearance-interaction.md` 禁止 `.font(.callout)` 直接写（应为 `GatherFont.secondary`）。
**用户影响** 无直接可见后果，但它是 7 个会话页工具栏里唯一常驻的文字：字号/行高一旦与 `GatherFont` 体系漂移，就会与右侧 12pt 刷新图标、`.caption` 队列徽标整体错位。
**修复建议** 换成 `GatherFont.secondary`。


---

## 导航 / 返回行为矩阵

约定：**返回** = 页签条左侧 chevron（也是唯一的 ⌘[ 绑定）。`sessionOrigin` 只在"非会话页进入会话"时写；`previousRoute` 只在"离开图库/相似度"或"会话内换会话"时写；两者都没写时兜底回工作台（RootShellNavigation.swift:182-198）。

| # | 起点 | 用户动作 | 落点 | 按「返回」落在 | 判定 |
|---|---|---|---|---|---|
| 1 | 工作台 | 点侧栏会话 / 卡片 | 控制中心 | 工作台 | ✅ 一步、可预期 |
| 2 | 工作台 | ⌘N 新建 | 工作台 + 新建表单 | （表单内取消） | ✅ |
| 3 | 控制中心 | 页签「浏览」 | 图库 | 控制中心 | ✅ |
| 4 | 图库 | 页签「控制中心」 | 控制中心 | 图库 | ✅（形成 1 步乒乓） |
| 5 | 图库 | 页签「控制中心」→「人脸」 | 人脸 | **图库**（跳过控制中心） | ❌ P1-1 跳级 |
| 6 | 图库 | 页签 控制→重复→挑片 | 挑片 | **图库**（跨 3 步） | ❌ P1-1 跳级 |
| 7 | 控制中心(A) | 点侧栏会话 B | 控制中心(B) | **控制中心(A) 的上一页** | ❌ P1-2 横跳 |
| 8 | 图库(A) | 点侧栏会话 B | 控制中心(B) | **图库(A)** | ❌ P1-2 横跳 |
| 9 | 控制中心（无页级来源） | 返回 | — | 进入会话前的全局页 | ✅ |
| 10 | 全局图库 | 点照片（进灯箱） | 图库(会话) + 灯箱 | 全局图库 | ✅ 意图消费正确 |
| 11 | 人脸库 | 点「审核」 | 人脸页(会话) | 人脸库 | ✅ |
| 12 | 人脸库 | 点照片 | 图库(会话) + 灯箱 | 人脸库 | ✅ |
| 13 | 任意页 | 后台导入完成 | 图库(新会话) | 原页面 | ⚠️ P2-7 被劫持（能回来，编辑态已丢） |
| 14 | 图库 | 灯箱内按 Esc | 关灯箱，停在图库 | 图库 | ✅ |
| 15 | 图库 | 灯箱内按 ⌘[ | **无反应** | — | ⚠️ sheet 是独立窗口，快捷键不达；语义上正确但无提示 |
| 16 | 图库 | 网格有选中时按 Esc | 清空选择 | — | ✅（与 14 同键不同语义，靠焦点区分） |
| 17 | 会话页 | 窄窗菜单态下点「返回」 | — | 同上返回逻辑 | ✅ 返回按钮在 620 阈值之外，不随退化消失（**做对了**） |
| 18 | 会话页（会话已被删） | — | **永久 spinner** | 无按钮可点 | ❌ P2-4 落空 |
| 19 | 任意 | ⌘W 再「显示主窗口」 | 工作台 | — | ⚠️ P2-8 位置全丢 |
| 20 | 控制中心 | 「只看冲突」→ 挑片 | 挑片 + 冲突面板 | 控制中心 | ✅ intent 消费 + prune 正确 |

**矩阵结论**：20 条里 6 条不合预期（#5 #6 #7 #8 #18 #19），根因集中在一处——**"返回"没有单一语义模型**：页级历史 / 会话退出 / 全局导航三者共用同一个槽和同一个箭头。

---

## 快捷键现状 vs 缺口

现状（全仓 30 处 `.keyboardShortcut`，约 19 处是弹层 Esc/Return 默认动作；下表只列窗口/页面级命令键与裸键）：

| 操作 | 键位 | 位置 | 菜单可见 | 备注 |
|---|---|---|---|---|
| 新建工作区 | ⌘N | GatherAppCommands.swift:52 / MenuCopy.swift:48 | ✔ 文件 | 关窗后置灰（P2-8） |
| 导入文件夹 | ⌘O | GatherAppCommands.swift:53 / MenuCopy.swift:49 | ✔ 文件 | |
| 从 Capture One 导入 | ⌘⇧I | GatherAppCommands.swift:54 / MenuCopy.swift:50 | ✔ 文件 | |
| 显示/隐藏侧栏 | ⌘⌥S | GatherAppCommands.swift:59 / MenuCopy.swift:51 | ✔ 显示 | 标题斜杠、无勾选（P2-9） |
| 设置 | ⌘, | Settings 场景（GatherApp.swift:117） | ✔ 系统 | |
| 撤销/重做 | ⌘Z / ⌘⇧Z | GatherAppCommands.swift:42, 45 | ✔ 编辑 | **仅挑片页替换**（P2-5 冲突） |
| 返回 | ⌘[ | GatherSessionPage.swift:110 | ✘ **无菜单项** | 仅会话页、仅页签条内；IME/非 US 布局可能不匹配 |
| 刷新 | ⌘R | GatherSessionToolbar.swift:159 | ✘ | 仅控制中心/图库/相似度/人脸 |
| 关键词面板 | ⌘K | CullingKeywordPanel.swift:85 | ✘ | 由 0×0 隐藏按钮承载 |
| 新建人物 | ⌘⇧N | PersonsView.swift:88 | ✘ | |
| 缩放 −/0/= | ⌘− ⌘0 ⌘= | CullingWorkbenchViewer.swift:119-133 | ✘ | 挑片查看器 |
| 清空选择 | Esc | GalleryGrid.swift:59 + GalleryView+Content.swift:314 | ✘ | 双绑定（同语义） |
| 切换选择 / 打开 | Space / Return | GalleryGrid.swift:57-58 | ✘ | 网格需先获得焦点 |
| 全选筛选结果 | ⌘A | GalleryGrid.swift:60-63 | ✘（系统"全选"走另一条链） | `onKeyPress` 内自判 ⌘ |
| 关闭/取消 | Esc | 灯箱与各 sheet（`.cancelAction`） | ✔ 系统 | |

缺口（用户会期待但没有）：

| 期待的操作 | 现状 | 影响 |
|---|---|---|
| ⌘F 搜索 | 无。图库搜索框在内容列（GalleryView+Content.swift:55-68），不是 toolbar search 字段，系统不会自动给 ⌘F | 全局图库/图库都不能用习惯键聚焦搜索 |
| ⌘1–⌘7 切页签 | 无（P1-5） | 7 个页面没有键盘路径 |
| ⌘] 前进 | 无 | 只有单向返回 |
| Esc 退出当前层（会话页 → 上一层） | 无。会话页 Esc 无绑定 | 灯箱/弹层有 Esc，页面级没有 |
| 空格预览 / Quick Look | 无。Space 在图库=切换选择、在挑片=保留 | 从"浏览照片"的工具定位看，最大的习惯落差 |
| ⌘⌥I 显示/隐藏检查器 | 无（靠工具栏系统按钮） | 图库/挑片的高频右栏 |
| ⌘. 取消进行中的任务 | 无 | 长任务只能去页面里找"取消" |
| 回工作台 | 无（⌘0 被挑片占用为缩放复位） | 深链/导入后只能靠侧栏 |

---

## 亮点

1. **单窗口 + 单一命令通道**：`Window("Gather", id: GatherWindowID.main)`（GatherApp.swift:42）从构造上排除"第二个窗口共享/覆盖 handler"的竞态；`AppCommandCenter.installed` 作为唯一可观察 readiness（AppCommandCenter.swift:44-66）+ `onDisappear` 里 `clearHandlers()`，关窗后菜单**真的**置灰，而不是静默 no-op。
2. **意图失效覆盖完整**：`pruneWorkspaceIntents`（RootShellWorkspace.swift:26-53）逐条覆盖 `WorkspaceIntent.Kind` 全部 6 种，且对"图库 s1→s2"额外补了 previous 分支；`take` 取出即清（SessionWorkspace.swift:160-162）。除"路由值不变时 onChange 不触发"这一理论缺口外，没有漏掉的 Kind。
3. **可见性两级模型克制且正确**：会话级 `setVisible(true)` 故意**不**启动任何 VM，页面级由挂载页 `onAppear` 经 `setPageVisible` 单启一个 VM（SessionWorkspace.swift:94-132）——避免"进会话就 7 个 VM 全转"；`setVisible(false)` 仍全量扇出停止（宁可多停不漏停），`close()` 后 `setPageVisible` no-op 防复活。
4. **返回按钮不随窄窗退化消失**：返回键在 `GeometryReader` 之外（GatherSessionPage.swift:94-110），620 阈值只作用于 7 段标签条。窄窗里用户不会"出不去"，这个细节比很多同类产品做得对。
5. **页签按钮的宽度锁**：隐藏 semibold 双胞胎锁定选中/未选中宽度（GatherSessionPage.swift:219-230），切页签时标签不横向抖动；hover 动效尊重 `accessibilityReduceMotion`（:257）。小的正确积累起来就是"稳"。
6. **文案在事件发生时按当前语言解析**，不缓存字符串（RootShellOverlay.swift:47-62 的注释与实现一致）；`L10n` 唯一源 `LanguageStore`，切语言只重渲染、不重建整树（RootView.swift:117-121），避免"切语言丢草稿"。
7. **空目录导入有可见反馈**（RootShellOverlay.swift:41-46）：成功但 0 张也给 info toast，而不是把用户送进一个空图库让他自己发现。

---

## 未验证与风险

1. **本环境不构建、不运行**，以下 4 条是代码推导，建议各做一次实机确认：
   - 侧栏 `.navigationTitle("Gather")`（RootShellSidebar.swift:76）与详情区 `.navigationTitle(windowTitle)`（RootView.swift:125）并存时，侧栏标题是否真的在侧栏头部渲染。若渲染，"Gather"会与会话名构成**两级标题**；若不渲染，这行就是死代码。
   - Toast 子按钮的 `.allowsHitTesting(true)` 能否覆盖祖先的 `false`（P2-6）。我按 SwiftUI 语义判断"不能"，需一次点击验证。
   - `⌘[` 在中文输入法激活时是否仍触发（KeyEquivalent 按字符匹配，IME 可能吞掉）。
   - `GeometryReader` 首帧宽度为 0 时是否会先渲染一帧 `compactMenu` 再切到 `tabBar`（切页签时整条 strip 随 `SessionPageHost` 的 `.id(...)` 重建，SessionPageHost.swift:48），宽窗下可能出现闪动。
2. **未覆盖**：`AppBootstrap`/`SceneState` 的装配顺序与失败重试（不在我的文件清单内）；`SessionDirectoryMonitor` 的关闭时机；设置窗口与主窗口的焦点竞争。若 `bootstrap.scene` 重建导致 `RootView` 重新 init，`installCommandHandlers` 与 `onDisappear` 的先后顺序值得单独看。
3. **LRU 与意图的竞态未验证**：`enqueueIntent` 内部 `sessionStore.workspace(for:)` 会**新建** workspace 并触发 `enforceCapacity()`（SessionStore.swift:44-55, 115-122）。容量 6 时若同时活跃 7 个会话，理论上存在"写入意图的 workspace 立刻被淘汰 → `enqueue` 因 closed 静默丢弃"的窗口。默认容量与真实使用（≤5 个最近会话）不重叠，故未升级为发现；容量调小就会变成真 bug。
4. **矩阵 #19 的前提**是"关窗后 `Window` 场景销毁、重开时 `@State` 重新初始化"。若 SwiftUI 保留了场景状态，实际表现可能更好，需一次 ⌘W → 显示主窗口 实机确认。
5. **A 范围外但会污染本报告判断的两处**（建议由图库/挑片线单独收口）：图库 `selectionBar` 在"0 张选中"时也常驻（GalleryView+Content.swift:25-27、:245-315，32pt 高；0 选中时「导出所选/灯箱比较/Finder 显示/取消选择」+ 两个星级/色标 Menu 全灰，只剩「全选筛选结果」可点），860×560 下净吃高度；`GalleryGrid` 的 `.onAppear { galleryGridFocused = true }`（GalleryGrid.swift:52）会抢焦点，可能盖掉搜索框输入。
