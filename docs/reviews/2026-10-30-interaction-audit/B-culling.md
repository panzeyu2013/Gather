# B · 挑片（Culling）交互与前端显示审计

> 范围：`desktop/native/gather-app/Sources/GatherUI/Culling/` 全部 30 个文件 / 7,672 行，加必要的 `GatherSessionPage` / `GatherSessionToolbar` / `C1StatusCapsule` / `GatherChromeMetrics` / `LiveCullingAPI` / `CullingService+Delivery` 交叉证据。
> 方法：**只读静态审计**（read / grep / wc），未运行 `swift build`／`swift test`，未实机点 GUI。凡依赖运行时焦点/布局求解的结论在文中标「待实机」。
> 已读过的历史评审（不重复其已修项）：`functional-usability-remediation-2026-10-30.md`、`functional-usability-review-2026-10-29.md`。

---

## 结论

1. **真实视图层级是「一路竖排 + 一个系统侧栏检查器」，四块（工具栏/查看器/信息条/胶片条）都在同一条 flex 链上；窗口变小时唯一会被压缩的是查看器。** 860×560 下查看器只剩约 259pt 高（两条横幅同时出现时约 179pt），四宫格每格约 187×125pt；胶片条 140pt、信息条 32pt 是固定高度、永不让位，也没有"专注查看"模式自动折叠。

2. **键盘是这一页最大的系统性风险：所有裸键（P/X/U/0–5/←→/空格）只挂在一个 `.focusable()` 的查看器上，既没有初始聚焦，也被 `.focusEffectDisabled()` 抹掉了"现在按键有效吗"的唯一线索；而网格布局又自己 `onAppear { isFocused = true }` 抢焦点。** 两套布局的键盘行为从代码上就不可能一致：网格有 ⌘A/Esc/Return/⌥1–7，单图全都没有；单图有空格，网格把空格映射成"保留"但要求网格持有焦点。

3. **检查器里那三枚决策按钮上印着 "P" / "X" / "U"，但按钮从来没有绑定过快捷键**（`DecisionButtonView` 收了 `key: KeyEquivalent` 却完全没用）。这是全页最贵的一处"提示即谎言"：用户看着 P 的角标按下 P，只有在恰好看图器有焦点时才会有反应。

4. **同步/写回这一组的"同一事实、两个名字"问题比"三处显示不一致"更严重**：菜单里的「恢复原 XMP」在确认框里叫「清理写回备份 / 删除 N 项已确认同步的备份」，而实现是**把已同步照片的 XMP 回滚到写入前**；「立即写入 XMP」实际只是 replay 未完成的 delivery intent，从不写盘。两个入口的动作名都在误导用户对破坏性的判断。

5. **"没有可见结果"的路径确实存在且不止一条**：`commit` 在 `isLoading` 时 `return`（无提示、页面无任何 loading 视觉），写回失败只给计数不给照片，取消确认弹窗却弹出**绿色成功横幅**。相对地，跨页批量/相似组/重置/冲突裁决的确认链（`Confirmed` 类型门控 + 影响面快照 + 服务端 hash 校验）是本仓做得最扎实的部分。

---

## 0. 主布局：真实层级与 860×560 的分配

### 0.1 层级（按代码，不是按注释）

```text
CullingView.body                                    CullingView.swift:89
└ GatherSessionPage(.culling)                       Interaction/GatherSessionPage.swift:28
  └ VStack(spacing:0)
    ├ GatherSessionTabStrip                         40pt（宽 <620 退化为 compactMenu）
    ├ Divider
    └ shellContent                                 CullingView+Content.swift:11
      ├ NativeBanner(error)                        ← 有 errorMessage 时（无关闭按钮）
      ├ NativeBanner(notice, .success)             ← 有 notice 时（同样无关闭）
      └ CullingWorkbench                           CullingWorkbench.swift:22
        ├ CullingToolbar                           ViewThatFits{full | compact} ≈36pt
        ├ VStack
        │  ├ [grid]  CullingGridView（header 36 + 竖向 ScrollView）      CullingGrid.swift:183
        │  ├ [other] CullingWorkbenchViewer（flex，唯一弹性）            CullingWorkbenchViewer.swift:81
        │  │         CullingInfoBar（minHeight 32，横向 ScrollView）      CullingInfoBar.swift:99
        │  └ .overlay(bottomTrailing) CullingConflictPanel（≤540，bottom 52）CullingWorkbench.swift:55-77
        └ CullingFilmstrip（header 32 + 横向 ScrollView 108 = 140；折叠 32）CullingFilmstrip.swift:28
  .inspector(CullingInspector: 竖向 ScrollView, 220–360)   CullingView.swift:140-153
  .toolbar(C1 状态胶囊 + 刷新)                              GatherSessionToolbar.swift:76-103
```

### 0.2 860×560 的算术（`GatherChromeMetrics.windowMinWidth/MinHeight`）

高度（窗口 560，macOS 标题栏/工具栏约 52）：

| 行 | 高度 | 是否可让 |
| --- | --- | --- |
| 页签行 + Divider | 41 | 否 |
| 页面工具栏 | ~36 | 否（`ViewThatFits` 只换形态不改高） |
| infoBar | 32 | 否（单图/对比布局） |
| 胶片条 | 140 | 只能手动折叠到 32 |
| **查看器（残余）** | **≈259** | **是，全部挤压由它承担** |
| 两条横幅同时出现 | −80 | 否（无关闭按钮） |

宽度（窗口 860 − 侧栏最小 180 = 680）：

- 检查器默认可见（`@SceneStorage("culling.inspectorVisible") = true`，`CullingView.swift:66`）→ 内容区 **460**；
- `ViewThatFits` 在这里必然落到 compact（`fullToolbar` 固定宽 240+210+…≈900 > 460）；
- 侧栏被拖到 max 260 时 → 内容区 **380**，而 `GatherChromeMetrics` 自述"Culling 内容最小 382"（`GatherChromeMetrics.swift:29-31`）→ 差 2pt；检查器拖到 max 360 时只剩 **240**。

页签行：`GeometryReader { if proxy.size.width >= 620 { tabBar } else { compactMenu } }`（`GatherSessionPage.swift:115-124`）。可用宽 = 详情列 − 66，所以需要窗口 ≥ ~1126（检查器开）/ ~906（检查器关）。**在 860×560 最小窗口下，7 段页签无论检查器开不开都退化为"当前页名 + chevron"的下拉**（460−66=394；640−66=574）。

**双重滚动条**：网格布局同时存在网格竖向 ScrollView 与胶片条横向 ScrollView —— 不同轴，不是同轴嵌套，符合文件头声明的"这一层只允许一个横向 ScrollView"。单图/对比布局内容列无任何竖向滚动，检查器自带竖向滚动，**没有同轴嵌套滚动**。✅

> 位置：`CullingWorkbench.swift:22-81`、`CullingWorkbenchViewer.swift:81-99`、`CullingFilmstrip.swift:20-35`、`GatherSessionPage.swift:28-48`、`GatherChromeMetrics.swift:8-32`
> 现象：窗口缩小时查看器被压到 259pt（含两条横幅 179pt），胶片条与信息条不让位。
> 用户影响：最小窗口 + 四宫格对比时每格 ≈187×125pt，判不了合焦/微表情——而"对比"正是为了判这件事；此时唯一的出路是手动点胶片条头部的折叠箭头（140→32），没有"专注查看/隐藏面板"的快捷键或菜单。
> 修复建议：① 给查看器一个 `minHeight`（例如 320）并在低于该值时自动折叠胶片条（或让 infoBar 下沉到工具栏同排）；② 布局模式切到 compare4/grid 时默认收起胶片条；③ 在「显示」菜单加"隐藏胶片条/信息条"并给 ⌘⌥F 之类的可发现入口。

---

## 发现

### P0

**未发现 P0。** 没有"静默数据破坏/必崩"的直接证据：所有写路径都经 `Confirmed` 类型门控（`CullingView+DestructiveActions.swift:130-151` 是唯一 `confirmed: true` 来源），批量写有历史栈，移动文件是"移动不删除"。以下 P1 里 No.4、No.6 离 P0 只有一步。

---

### P1

#### P1-1 · 裸键快捷键只挂在一个不保证有焦点的查看器上，且被抹掉了焦点提示

位置：`CullingWorkbenchViewer.swift:147-155`、`CullingGrid.swift:229-232`

```swift
// CullingWorkbenchViewer.swift:147
// 空格 = 保留当前照片（裸键不该占用系统快捷键，交给聚焦查看器的 onKeyPress）。
.focusable()
.focusEffectDisabled()
.onKeyPress(phases: .down) { press in
```

```swift
// CullingGrid.swift:229
.focusable()
.focused($isFocused)
.onKeyPress(phases: .down) { press in handle(press) }
.onAppear { isFocused = true }
```

现象：全页只有这两处 `onKeyPress`（`grep` 确认 7 处命中里 2 处是实现）。查看器没有 `.focused()` 绑定、没有 `@FocusState`、没有任何地方在 appear/切换布局/关闭弹窗后请求焦点；网格相反，`onAppear` 主动抢焦点。同时 `focusEffectDisabled()` 删掉了系统焦点环——用户没有任何线索判断"现在按 P 会不会生效"。

同一事实的另一半：`CullingInfoBar.swift:23-24` 注释写"可见按钮承载 ←/→ 裸键快捷键（取代窗口级 NSEvent 监听）"，但那两个 chevron 按钮**只有 `.help` 和 `.accessibilityLabel`，没有 `.keyboardShortcut`**（全模块 `keyboardShortcut` 命中 13 处含 3 处注释，没有一处落在 InfoBar；真实绑定只有 ⌘−/⌘0/⌘=、⌘K、sheet 的回车/Esc）。注释与实现不符。

用户影响：① 进入挑片页后直接按 P/数字，若查看器未获焦点则**整页无反应、无提示**；② 在检查器里点过星标/颜色/筛选之后，焦点离开查看器，之后 P/X/←→ 全部失效，用户会认为"软件卡了"；③ 从网格切回单图，网格被销毁、查看器新建但没有焦点，键盘再次失效——这条路径每次切布局都会走一遍。
修复建议：给查看器 `@FocusState` + `.onAppear/.onChange(of: layoutMode)` 主动 `focus = true`，并把 `focusEffectDisabled()` 换成"仅在看图器聚焦时显示一圈极淡的内描边"；或者更稳的做法：把裸键收回到页面级 `.focusable()` 容器（一个 `CullingKeyRouter`），由它统一处理并在文本框获得焦点时让位（判断 `NSApp.keyWindow?.firstResponder is NSTextView`，仓库里 `CullingView.routeHistory` 已有同一模式可复用）。**待实机验证初始焦点。**

#### P1-2 · 检查器决策按钮印着 P/X/U 角标，但按钮没有绑定快捷键

位置：`CullingInspector.swift:458-475`（调用）、`CullingInspector.swift:550-585`（实现）

```swift
private struct DecisionButtonView: View {
    let shortcut: String
    let key: KeyEquivalent          // ← 收了，但 body 里从未使用
    ...
        Text(shortcut)              // 角标只画字
            .font(.callout)
        ...
        // 裸键由查看器的 onKeyPress 统一注册（见 CullingWorkbenchViewer），
        .disabled(isBusy)
        .help(l10n.format("%@（快捷键 %@）", title, shortcut))
```

现象：`key` 参数是死参数（编译器 unused 警告级），按钮自身没有 `.keyboardShortcut(key, modifiers: [])`；角标与 `.help` 都在断言一个不存在的绑定。
用户影响：全页最显眼的三枚按钮告诉用户"按 P 就行"，而 P 只在另一个视图持有焦点时才有效。这既是可达性问题也是文案欺骗。
修复建议：真的把 `key` 用起来（`.keyboardShortcut(key, modifiers: [])` 对裸键是窗口级生效的，与查看器的 `onKeyPress` 会双触发 → 二选一，建议**保留按钮绑定、删掉查看器里重复的 p/x/u/0-5**，查看器只留空格与 ←→）；若坚持集中式，则把角标改成不带字母的图标或删掉。

#### P1-3 · 「全选」只存在于网格布局；单图/对比布局没有 ⌘A、也没有按钮

位置：`CullingGrid.swift:97`、`CullingGrid.swift:376-378`、`CullingInspector.swift:417-439`

```swift
// CullingGrid.swift:97  ⌘A 只在这个纯函数里被映射
if command { return lower == "a" ? .selectAll : nil }
...
case .selectAll: Task { await viewModel.selectAllInScope() }   // :377
```

现象：`selectAllInScope()` 全仓只有 3 个调用点，全部在 `CullingGrid`（grep 确认；Gallery 是另一套）。检查器的「选择管理」只有「取消选择」，没有「全选本范围」；「相似组」区只能选"当前 1 张/已选 N 张"。单图布局下要构造一个批量目标，只能靠胶片条 ⌘ 点 N 次。
用户影响：`scopeMode=.filtered` + "只看未处理" + 全选 + 按 X 是挑片的核心工作流（一次过 500 张里的一批）；在默认布局（`@SceneStorage("culling.layout") = .single`）里这条路根本走不到，用户得先发现"网格"这个布局页签。
修复建议：在「选择管理」加一枚「全选当前范围（N 张）」（调 `selectAllInScope()`，N 用 `page.total` 或 selection 查询返回的 count），并给它 ⌘A（`.keyboardShortcut("a", modifiers: .command)` 挂在页级容器上，与 P1-1 的集中式路由一并解决）。

#### P1-4 · ⌘ 加选之后按 ⇧ 会**覆盖**掉之前的 ⌘ 选择（与 Finder/macOS 语义相反）

位置：`CullingViewModel+Grid.swift:123-131`、`CullingViewModel+Grid.swift:144-147`

```swift
// selectRange(...)  :129 —— 直接整体替换，不是并集
selectedPhotoIds = Set(range.map { assets[$0].photo.id })
...
// gridClick(...)  :144
if modifiers.contains(.command) {
    toggleSelection(photoId)      // toggleSelection 里 selectionAnchorId = photoId（:200）
    currentPhotoId = photoId
```

现象：`⌘A`（选中"选中 A"）→ `⌘C`（`sel={A,C}`、anchor 变成 C）→ `⇧D` → `selectRange(from: C, to: D)` 把 `selectedPhotoIds` **整体替换成 C…D**，A 与 C 之前的任何加选全部消失，且没有任何提示。Finder 的行为是"⇧ 从锚点扩展到目标并**并入**已有选择"。
用户影响：这是"选错照片 → 批量写错照片"的直接来源。用户以为选了 {A,C,D,E}，实际只有 {D,E}，按 X 之后 A 被保留、D/E 被淘汰，两者都错；靠撤销才发现。
修复建议：① `selectRange` 改并集（`selectedPhotoIds.formUnion(range)`），或在 ⇧ 分支里以"锚点区间 ∪ 已有选择"计算；② ⌘ 点击**不移动** `selectionAnchorId`（只 `toggleSelection`，锚点保持），锚点只在普通点击时更新——这正是 macOS 标准语义，文件头 `:106` 的注释（"锚点是 selectionAnchorId（普通/⌘ 点击更新）"）说明这是有意为之，需要产品确认后改。

#### P1-5 · 「淘汰移出到 _rejects」的确认框不写影响面（会动多少张），且对"没有淘汰件"的选择也可点

位置：`CullingInspector.swift:144-155`（对话框）、`CullingInspector.swift:429-437`（按钮）、`CullingViewModel+Actions.swift:146-160`

```swift
.confirmationDialog(
    l10n("把选中的淘汰照片移出到 _rejects？"),
    isPresented: $confirmMoveRejected, titleVisibility: .visible
) {
    Button(l10n("移出"), role: .destructive) { Task { await viewModel.moveRejectedOut() } }
    ...
} message: {
    Text(l10n("只移动、不删除；文件可在会话目录的 _rejects 中找回。"))
}
```

现象：这是全页唯一会**动磁盘文件**的动作，而它的 message 是一句常量、没有任何 `l10n.format` 计数（对比同一文件的 reset/writeback/groupDecision/crossPageBatch 全部带 `%lld`）。而 `moveRejectedOut()` 的 targets 是"全部选择集"（`:150-151`），服务端再按 `not_rejected` 逐张跳过——所以对话框既不知道会移动几张，也不知道会跳过几张。按钮的启用条件只有 `!isBusy`，选 5 张全"保留"的照片也能点。
用户影响：破坏性操作的最后一道关卡不提供决策依据；用户点完只会在事后收到"已移出 0 张；跳过 5 张（非淘汰 5…）"的长句 notice（`:173-178`）。对"移动文件"这类动作，影响面必须先于确认给出。
修复建议：按钮文案带计数（"淘汰移出到 _rejects（3 张）"，计数取 `selectedPhotoIds ∩ page.assets where pickState == .rejected`，跨页时显示"≥N"或先拉一次 selection 查询）；全部非淘汰时禁用并给 `.help` 理由；对话框 message 用 `l10n.format` 写"将移动 N 张、跳过 M 张（非淘汰），只移动不删除"。

#### P1-6 · 「恢复原 XMP」在确认框里被描述成「删除备份」，而实现是把 XMP 回滚

位置：`CullingSyncControls.swift:45-51`（菜单）、`CullingView+DestructiveActions.swift:75-76`（确认文案）、`CullingService+Delivery.swift:295-299` + `DeliveryCoordinator.swift:490-503`（实现）

```swift
// CullingSyncControls.swift:48
Button(l10n("恢复原 XMP"), role: .destructive) { pendingAction = .cleanup }
// CullingView+DestructiveActions.swift:75
case .cleanup:
    return l10n.format("将删除 %lld 项已确认同步的备份；未确认的项会恢复原 XMP 并标记冲突，原因会显示在面板里。",
                       viewModel.syncStatus?.synced ?? 0)
```

```swift
// DeliveryCoordinator.swift:490-495 —— 真实语义
/// 每个交付独立走三段：prepare → 文件恢复 → advance(fileDone) → DB 删除 → finish。
public func cleanup(sessionId: String, module: DeliveryModule) async throws -> DeliveryCleanupSummary {
```

现象：三处对同一动作有三种说法——菜单"恢复原 XMP"、对话框标题"`清理写回备份`"（`PendingCullingAction.actionText`，`:47`）、正文"删除 N 项备份 / 未确认项会恢复并标冲突"。实现是"**已同步**的交付：先恢复备份到 XMP，再删备份；未确认的交付**根本不是候选**（不会被恢复，也不会被标冲突）"。
用户影响：① 以为只是清磁盘（想省事点确认）的用户，实际上把已交付给 Capture One 的 XMP 回滚了；② 以为"未确认项会被恢复"的用户什么也不会发生。这是破坏性确认链里最实质的一处描述错误。
修复建议：统一命名为「把已同步的 XMP 恢复为写入前版本并删除备份」，正文用 `l10n.format` 写"将回滚 N 张照片的 XMP、删除对应备份；未确认同步的项不会被处理"；`actionText` 与菜单名必须同源（同一个 `LocalizedText`）。

#### P1-7 · 「立即写入 XMP」从不写盘，却和"写回"并列在同一个菜单里，且不需要确认

位置：`CullingSyncControls.swift:22`、`CullingViewModel+Writeback.swift:102-117`、`CullingService+Delivery.swift:47-55`

```swift
Button(l10n("立即写入 XMP")) { Task { await viewModel.flush() } }   // 无确认
...
// CullingService+Delivery.swift:47
/// S5c-2b-1 起 flush 的动作是「回放未完成的 delivery intent」（cleanup/finalize 的崩溃恢复），
/// **不再触发旧 outbox 队列**；写盘仍由 writeback/retryFailedWriteback 内的 WritebackService.execute 同步完成。
public func flush(sessionId: String) async throws -> MetadataSyncSummary {
    _ = try await delivery.engine.replay()
```

现象：菜单第一项承诺"立即写入 XMP"，实现只 replay 崩溃恢复 intent；成功后的 notice 是"已刷新同步队列"（`CullingViewModel+Writeback.swift:111`）——用户点"写入"得到"刷新"。同时它紧挨着「写回 XMP…」（需要确认弹窗），两者的破坏性等级在 UI 上被画成相反。
用户影响：这是最典型的"动作发出后没有可见结果"：没有任何文件被写，同步计数不变，用户会反复点、然后怀疑挑片决策没保存。
修复建议：菜单项改名为「重放未完成的同步任务」并移出"写回"分组（或直接删掉——崩溃恢复应该是自动的、不该由用户触发）；若确实想保留"立刻写"的语义，就让它走 `writeback` 的确认链。

#### P1-8 · 加载期间按 P/X/数字被静默丢弃，而页面在有数据时**没有任何 loading 视觉**

位置：`CullingViewModel+Actions.swift:342-343`、`CullingView.swift:134`、`CullingView+Content.swift:67-75`

```swift
public func commit(patch: CullingUpdatePatch, shouldAdvance: Bool = true) async {
    guard !isLoading else { return }          // ← 无 notice、无 error、无任何反馈
```

```swift
// CullingView+Content.swift:67 —— 只有 page == nil 才有进度条
} else {
    HStack { Spacer(); ProgressView(l10n("正在载入挑片工作台…")); Spacer() }
}
```

现象：`isLoading` 覆盖整页加载、筛选/范围/排序切换、写回后刷新、翻页续加载；只要有数据（`page != nil`）就只剩工具栏刷新按钮变灰（`refreshDisabled: viewModel.isLoading`）这一处痕迹。此时 `commit` 直接 return，`advanceCurrent`/`retreatCurrent` 仍生效（可以翻页），但翻到末张触发的 `loadMore` 期间同样吞掉决策。
用户影响：在 20k 会话里每按一次 X 都伴随一次静默刷新，快速连按时有一部分 X 被吞掉——用户看到的是"我按了 5 次 X，只有 3 张变红"。
修复建议：① `commit` 的 `guard` 改为排队（一次 pending commit，加载完执行）或至少 `notice = "正在载入，请稍候"`；② 工作台右上角加一个 `.overlay` 的细进度条/转圈（`isBusy` 已经有值，只是没人画）。

---

### P2

#### P2-1 · 网格布局下 infoBar 整块消失：同步状态、RAW/JPEG 链接警告、上一张/下一张一起没了
位置：`CullingWorkbench.swift:37-52`、`CullingGrid.swift:235-255`
现象：`if layoutMode == .grid { CullingGridView } else { viewer + CullingInfoBar }`。网格头部只显示"N 张 / 已选 M 张 + 全屏"。
用户影响：网格是最常用的批量视图，而"有 N 个 XMP 冲突 / N 个等待写入 / 已同步"在这个视图里只存在于窗口右上角的 C1 胶囊（另一套措辞），页内的同步事实完全不可见；"同名 RAW/JPEG 共用 XMP"的警告也不会出现（批量评级会连带改掉兄弟文件，而用户无从得知）。
修复建议：把 infoBar 的同步段与 linkedNotice 提到 `CullingWorkbench` 层（所有布局共享），网格下保留一条 32pt 的状态行。

#### P2-2 · "已同步"在从未写过 XMP 的新会话里也是绿色成功
位置：`CullingInfoBar.swift:113-121`、`C1StatusCapsule.swift:295-298`
```swift
func syncStatusText(_ sync: MetadataSyncSummary) -> String {
    let hasCounts = sync.conflict + sync.failed + sync.pending + sync.writing + sync.written + sync.synced > 0
    if sync.items.isEmpty && !hasCounts { return l10n("XMP 已同步") }
```
现象：全零（空 outbox / 从未写回）被判为"已同步"，胶囊同样返回绿色「已同步」。而 `decidedPhotoCount` 可能已经是 500。
用户影响：用户挑完 500 张，看到两处绿色"已同步"，合理地认为 XMP 已经写好；实际上 Capture One 里什么都没有。这是本页最可能造成"工作丢失感"的误报。
修复建议：加"未写回"态——`sync` 全零且 `decidedPhotoCount > decisionCountAtLastWriteback`（或服务端给一个 `dirtyDecisions` 计数）时显示灰色「尚未写回（N 张已决策）」；胶囊同步该状态。

#### P2-3 · 胶片条色标线被文件名条压住
位置：`CullingFilmstrip.swift:145-185`
现象：`ZStack(alignment: .bottom)` 里先放 `Rectangle().fill(colorLabel).frame(height: 4)`（`:153-157`），最后放 `Text(filename).background(GatherTheme.viewerBackground.opacity(0.7))`（`:177-184`）——两者都底对齐，文件名条后绘制且只有 0.7 透明度。
用户影响：色标（挑片的核心筛选维度）在胶片条上几乎看不见，只剩 30% 饱和的一条；用户会转而依赖网格或检查器判断颜色。
修复建议：把色标线改成 `overlay(alignment: .bottom)` 画在文件名条之上，或把文件名条上移 4pt（`.padding(.bottom, 4)`）。

#### P2-4 · 网格单元只有 `onTapGesture`：不是按钮、VoiceOver 无法激活、双击无意义
位置：`CullingGrid.swift:265-288`
现象：`.contentShape(Rectangle()).onTapGesture { … }` + `.accessibilityElement(children: .ignore)`，没有 `.accessibilityAddTraits(.isButton)`、没有 `accessibilityAction`、没有 `onTapGesture(count: 2)`。
用户影响：① VoiceOver 能读出"文件名，保留，3 星"但**无法选中**；② 双击不会"在单图中打开"（只有 Enter 和右键菜单），鼠标用户的心智模型（Finder/Lightroom 双击进单图）失效；双击只是把 current 重设了两次。
修复建议：包成 `Button`（`.buttonStyle(.plain)`）或补 `.accessibilityAction { gridClick(...) }` + `.accessibilityAddTraits(.isButton)`；加 `.onTapGesture(count: 2) { onOpenSingle() }`（注意与单击的 `.simultaneousGesture` 顺序，避免单击延迟）。

#### P2-5 · 长关键词在 220pt 检查器里溢出，删除按钮会被裁到看不见
位置：`CullingKeywordPanel.swift:8-57`（`KeywordFlowLayout`）、`:254-291`（chip）
现象：`sizeThatFits` 对子视图用 `.unspecified` 提案（`:22`），chip 的 `Text` 只 `lineLimit(1)` 不设宽度上限；超过容器宽度的 chip 会在 `placeSubviews` 里从 `bounds.minX` 起排、右边溢出边界（`:48-53` 只判断换行，不裁剪）。
用户影响：一条 30+ 字的关键词（"2026 春季婚礼-新娘准备-化妆间"）会把 `xmark.circle.fill` 推到检查器可视区外，用户无法移除它，只能整批重置草稿。
修复建议：`sizeThatFits` 里给每个 subview 传 `ProposedViewSize(width: maxWidth, height: nil)`，并给 chip 的 `Text` 加 `.truncationMode(.middle)` + `.frame(maxWidth: containerWidth - 28)`；删除按钮固定在 chip 右侧不参与压缩。

#### P2-6 · "混合值"表达弱：关键词只加一个"—"前缀，且与"部分照片包含"共用同一底色
位置：`CullingKeywordPanel.swift:257-262`、`CullingInspector.swift:64-68`（星级/颜色用"混合"文字 + 未选中态）
现象：星级/颜色在混合时显示一行小字"混合"，而 picker 自己的 `selection` 仍是 `summary?.colorLabel`（nil）→ 菜单按钮上显示空白；关键词混合是 `"— " + keyword` 的纯文本前缀。
用户影响：三处混合态的视觉语言不一致；颜色菜单显示空白而不是"混合"，用户会以为"没有颜色"而不是"多张不同"。
修复建议：颜色菜单的 `Picker` 在 `hasMixedColorLabel` 时把标签本身显示为"混合"（已有 `Text(l10n("混合")).tag(nil)`，需要让 `labelsHidden()` 的菜单标题读它——改用 `Menu` + 自绘 label 更稳）；关键词的 "—" 换成同色系的"部分"胶囊。

#### P2-7 · 检查器 14 段一路竖排，破坏性的"淘汰移出"埋在倒数第二段
位置：`CullingInspector.swift:35-447`（顺序：当前照片 → 只读元数据 → 元数据 → 模板 → 导入 → 技术建议写回 → 关键词 → 排序与网格 → 技术质量建议 → 筛选 → 相似组 → 选择管理 → 统计）
现象：在 220pt 宽、560pt 高的检查器里，这 14 段需要滚约 4 屏；「淘汰移出到 _rejects」在全页最底部，紧挨着「取消选择」（两个全宽按钮，一破坏一良性，无间距分隔）。
用户影响：破坏性入口既难找又容易误触；常用项（星级/色标）与被压缩的元数据面板抢同一列。
修复建议：把「元数据/模板/导入/技术建议写回」收进一个 `DisclosureGroup`（或挪到「控制中心」页），让检查器第一屏固定为"当前照片 + 关键词 + 选择管理"；破坏性按钮与其上方的良性按钮之间加 `Divider` 并保持 `.help`。

#### P2-8 · 取消动作走绿色成功横幅；错误横幅不可关闭且与整页错误态重复
位置：`CullingView.swift:116`、`CullingView+Content.swift:13-21`、`CullingView+Content.swift:58-66`
现象：`onCancel: { viewModel.noteCancelledAction($0.actionText) }` → `notice = CullingNotice(cancelled: …)` → 渲染成 `NativeBanner(color: GatherTheme.success)`（`:20`）+ 绿色 `checkmark.circle.fill`。"已取消：重置挑片状态"是一句绿色成功提示。另外加载失败时页面上方**同时**出现红横幅"操作失败：…"和整页 `ContentUnavailableView`"载入挑片工作台失败 / 同一句错误 / 重试"。
用户影响：① 取消（正确的谨慎行为）获得与成功相同的正反馈色，稀释语义色；② 失败时同一句话出现两遍，横幅还占 40pt 高且没有关闭按钮，用户无法清掉它（`errorMessage` 只能被下一次成功 `loadPage` 清空，`+Load.swift:298`）。
修复建议：取消用中性色（`GatherTheme.secondaryContentBackground` / info）；`NativeBanner` 传 `onDismiss`（组件已支持，`:105-114`）；`page == nil` 的失败分支不要再渲染顶部横幅（`if page != nil` 才画）。

#### P2-9 · 编辑菜单的「撤销」永远可点，工具栏的撤销按钮却是按栈禁用的
位置：`CullingView.swift:156-162`、`CullingToolbar.swift:174-193`
```swift
.focusedSceneValue(\.cullingHistory, CullingHistoryActions(
    // 焦点可能在关键词 TextField：canUndo 不能只看挑片栈，否则文本撤销被禁用。
    canUndo: !isBusy,
```
现象：`canUndo` 恒为 `!isBusy`；`undoOperation == nil` 时菜单仍可点，点了走 `undo()` → `notice = "没有可撤销的挑片操作"`（`+Actions.swift:561`）。而同一个动作的工具栏按钮 `.disabled(viewModel.undoOperation == nil || isBusy)`。
用户影响：同一动作两个入口两个状态；用户点了菜单里的"撤销"却没有变化（只有一条绿色 notice），会怀疑撤销坏了。
修复建议：`canUndo: !isBusy && viewModel.undoOperation != nil && 无文本焦点`（文本焦点可以用 `@FocusedValue`/环境变量近似，或保留现状但在 `undo()` 里直接 no-op 不弹 notice）。

#### P2-10 · 网格的滚动动画不遵守"减少动态"
位置：`CullingGrid.swift:219-224` vs `CullingFilmstrip.swift:17/51/100`
现象：全模块只有胶片条读了 `@Environment(\.accessibilityReduceMotion)`（1 处声明、2 处使用）；网格的 `withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }` 无条件动画——而它在每次 current 变化时都触发（含方向键连按）。
用户影响：对前庭敏感用户与"连按 → 翻 20 张"的大幅滚动，违反系统偏好。
修复建议：网格补 `reduceMotion` 判断（与胶片条同写法）。

#### P2-11 · 全页 9 处 `.font(.callout)` 直写，违反 `appearance-interaction.md` 的字体令牌规则
位置：`CullingConflictPanel.swift:60/74/84/88/113/166`、`CullingToolbar.swift:214`、`CullingViewerParts.swift:30`、`CullingInspector.swift:572`
现象：设计系统要求走 `GatherFont.*`（`GatherFont.body/secondary/label…`），这 9 处直接写死 `.callout`，其中 `CullingToolbar.swift:214` 是质量进度百分比、`CullingInspector.swift:572` 是快捷键角标——都是**内容语义**而非控件标签，且没有 `.monospacedDigit()` 之外的动态度量适配。
用户影响：动态字体/字号设置下这些文本不随 `GatherFont` 的比例缩放，检查器里的角标会与相邻 `GatherFont.secondary` 层级错位；也绕过了设计系统的可访问性审计点。
修复建议：替换为 `GatherFont.body` / `GatherFont.secondary`（冲突面板的三层差异文本建议 `GatherFont.secondary` + `secondaryStrong` 区分）。

#### P2-12 · 关键词"确认写入"有两条不等价的路径
位置：`CullingKeywordPanel.swift:307-323`（actionRow）vs `:349-375`（previewSheet）
现象：预览 sheet 里的"确认写入"（`:363-370`）**直接执行**；列表页的"确认写入"（`:317-321`）打开一张只报计数的 `applyConfirmationSheet`（`:467-493`），不含逐张 before/after。两条路都能到达 `applyKeywordWriteback`，但用户看到的影响面信息量不同；且 `keywordCanApply` 要求 `keywordPreview != nil`，所以"确认写入"按钮必须先点过"预览写回"才可用（一个隐藏的顺序约束）。
用户影响：用户取消预览后仍可点"确认写入"进入一个没有差异列表的确认框——本该是最需要看差异的地方反而最空。
修复建议：合并为一条路径（"确认写入"直接打开预览 sheet，sheet 内确认），删除 `applyConfirmationSheet`；按钮禁用时用 `.help` 说明"请先预览"。

#### P2-13 · 跨页选择在关键词面板被静默收窄到"已加载页"
位置：`CullingViewModel+Keywords.swift:15-21`、`:39` vs `CullingViewModel+Actions.swift:355-365`
现象：`keywordTargetAssets = page.assets.filter { selectedPhotoIds.contains(...) }` —— 目标只取已加载的；而同一个选择集按 P/X 时 `commit` 会先弹"19500 张不可见"的跨页确认（`:357-365`）。关键词面板则直接显示"将向 500 张照片写入关键词"，无任何"其余 19500 张不在范围内"的提示。
用户影响：⌘A 之后加关键词，只有首屏 500 张（网格 200 张）被打上，用户以为整批完成；XMP 里出现"只有一部分有 culling:keep"的不一致数据。
修复建议：`keywordTargetCount > page.assets.count` 时在面板顶部显示"仅前 N 张（共 M 张选中）可编辑关键词"，或直接走 `preview` 的服务端 selection 快照（与批量写同一套 hash 绑定）。

#### P2-14 · 「批量 1 张」：单选也算批量
位置：`CullingInspector.swift:42`、`CullingViewModel+Actions.swift:506-511`
```swift
Text(viewModel.selectedPhotoIds.isEmpty ? l10n("当前照片")
     : l10n.format("批量 %lld 张", viewModel.selectedPhotoIds.count))
```
现象：`selectCurrent` 把 `selectedPhotoIds` 设成 `[photoId]`（不是空），胶片条/网格任何一次点击后都非空 → 检查器标题永远是"批量 1 张"，「选择管理」的"未选择照片"分支实际只在首帧出现。
用户影响：用户看"批量 1 张"会以为自己进入了批量模式；决策按钮的作用面（1 张 vs N 张）失去可信指示。
修复建议：`count <= 1 ? "当前照片" : "批量 N 张"`。

#### P2-15 · 查看器常驻"100%"胶囊 + 缩放控件压住字幕条
位置：`CullingWorkbenchViewer.swift:102-112`、`:141-145`
现象：顶部居中永远显示 `(Int(effectiveScale*100))%`（1× 时也显示），底部左侧缩放三连用 `.padding(.bottom, 40)` 浮在单元格字幕条（文件名/来源/星级，`:313-328`）上方 40pt。
用户影响：在 259pt 高的查看器里，顶部胶囊 + 底部 40pt 让实际构图区再少约 60pt；"100%"是无信息量的常驻噪声。
修复建议：缩放值只在 `scale != 1` 或鼠标悬停时显示（`.opacity(scale == 1 && !hovering ? 0 : 1)`），或并入底部控件组。

#### P2-16 · 信息条的"重试"其实重载整页
位置：`CullingInfoBar.swift:82-94`
现象：`lastSyncError` 旁边是 `Button("重试") { Task { await viewModel.load() } }`——它重跑 `loadNavigation + loadPage`，不是重试同步队列（`retryFailedWriteback`/`retrySync`）。
用户影响：用户看到"同步状态加载失败 → 重试"，期望恢复同步，实际是整页重刷；若故障在同步 API，重试后错误依旧，按钮行为看起来"无效"。
修复建议：文案改为"重新载入"或改成 `refreshSyncStatus()`（真正的重试）。

#### P2-17 · ⌘R 在挑片页被刻意关闭
位置：`CullingView.swift:128-136`、`GatherSessionToolbar.swift:153-163`
现象：`GatherSessionToolbar(... refreshKeyboardShortcut:` 未传 → `enabled: false`，而 Control/Gallery/Similarity/Face 四页都开了 ⌘R。
用户影响：同一个"刷新"在 6 个会话页里 4 个有 ⌘R、挑片没有；挑片恰恰是最需要"重新载入工作台"的页面（外部改了 XMP 之后）。
修复建议：`refreshKeyboardShortcut: true`。

---

## 亮点

1. **破坏性动作的类型级门控是全仓最干净的一处**：`Confirmed<T>` 只能由 `CullingView.perform(_:)` 在确认分支构造（`CullingView+DestructiveActions.swift:130-151`），`gatherDestructiveConfirm` 统一处理"取消也要有可见文案"（`GatherCommonViews.swift:159-223`），并且没有"无弹窗硬编码 true"的旁路（`grep confirmed: true` 只命中这些分支）。
2. **影响面先于确认**：相似组走"先拉完整组 → 生成 plan（totalCount/visibleCount/样本文件名）→ 确认弹窗"（`CullingViewModel+Navigation.swift:96-137`、`+DestructiveActions.swift:96-106`）；跨页批量带服务端 hash + count 快照，不符则零写入并清空失效选择（`+Actions.swift:437-440`）；`crossPageBatch` 还提供"仅当前可见"的第二动作（`CullingView.swift:105-113`）。这是本页最专业的设计。
3. **写状态与视图状态分离**：VM 只存 `CommandError`（码/参数/诊断），文案在渲染期经 `L10n` 解析（`NativeBanner.swift:8-49` 的政策注释），切语言不残留旧语言字符串；`CullingNotice` 存结构化 payload 而不是格式化好的句子（`CullingNotice.swift:7-59`）。`CommandErrorText` 还拒绝了"把 API 中文散文铺到界面"。
4. **焦点与撤销的文本让位处理**：`routeHistory` 在 `firstResponder is NSTextView` 时把 ⌘Z/⇧⌘Z 交还 field editor（`CullingView.swift:165-173`），避免了"在关键词框里按 ⌘Z 把 20 张照片的决策撤了"。
5. **约束循环的历史修复有据可查且克制**：多处注释记录了 ideal 宽度导致 AppKit 约束 pass 耗尽的具体数值（`CullingView.swift:149-152`、`CullingWorkbench.swift:60-65`、`CullingInfoBar.swift:16-20`），并用 `ViewThatFits`/`GeometryReader`（最小宽 0）替代 `fixedSize` 分段控件——这类"用布局契约换稳定性"的处理值得保留。
6. **性能上刻意避免了 O(n)/O(n²)**：网格行布局按 `(pageVersion, count, width, rowHeight)` 缓存（`CullingGrid.swift:132-167`）、关键词索引按 `selection+pageVersion` 缓存（`+Keywords.swift:41-59`）、`refreshSilently` 只在"排序依赖决策"时才重取页（`+Load.swift:50-59`）、18 处 `requestID/generation` 守卫防旧响应覆盖。
7. **确认弹窗按钮显式 `.disabled(false)`**（`GatherCommonViews.swift:210-219`）——修掉了"宿主页 `.disabled(!isActive)` 继承到弹窗导致确认按钮全部变灰"的经典陷阱，这个细节很多项目会踩。

---

## 未验证与风险

1. **初始焦点（待实机，影响 P1-1 的严重度）**：SwiftUI 的 `.onKeyPress` 只在视图（或其子视图）持有焦点时触发。代码里查看器没有任何焦点请求，但 macOS 可能把首个 `focusable` 视图设为窗口的初始 first responder。若实机确认"进页面即可用 P/X"，P1-1 降级为 P2（仅"点过检查器后失效"）；若确认"必须点一下图片"，P1-1 就是本模块第一优先。
2. **AppKit 约束循环是否在最小窗口复现（待实机）**：`860 − 260(侧栏max) − 220(检查器min) = 380 < 382`（`GatherChromeMetrics.swift:29-31` 自述的内容最小宽）。历史上同类越界曾导致约束 pass 耗尽/日志刷屏。需要在 860×560 下把侧栏拖到最宽 + 打开检查器观察 Console。
3. **多个 `.sheet`/`confirmationDialog` 挂在同一 body 链上的抢占**：检查器里有 `.sheet(item:)`（`:156`）+ 2 个 `.confirmationDialog`（`:144`、`:249`、`:277`），关键词面板还有自己的 `.sheet`（`:140`），TriageCard 又有 `.sheet(isPresented:)`（`CullingTriageCard.swift:83`）。代码注释已承认"同视图叠多个 sheet 行为不稳定"，但跨层（祖先/后代各一个）的行为无法静态判定。需要依次点：预览写回 → 取消 → 确认写入 → 建议写回撤销 → 摄取，确认每个都能弹出。
4. **`CullingGridLayoutCache` 的缓存键不含每张照片的宽高**（`CullingGrid.swift:148`）：`version|count|width|rowHeight`。若 `pageVersion` 因选择/决策而 +1 但 `count` 与资产集合不变，键不变 → 命中旧行宽（正确）；但若服务端在**同一 pageVersion 内**替换了资产集合（例如 `applyDecisionStates` 不 +1？它确实 +1），才会错。风险低，但如果未来有"不递增 pageVersion 的页替换"，行宽会贴错。
5. **`moveRejectedOut` 后的路径失效窗口**：`loadPage(reset: true)` 在移动之后才执行（`+Actions.swift:184-185`），在此期间网格/胶片条仍用旧 `filepath` 取缩略图，可能出现一小段缩略图空白闪烁。未实机确认。
6. **未覆盖的文件**：`IngestSheet.swift`(309) 只做了一次通读（发现"开始摄取"在来源为空时禁用但无 `.help` 说明原因、`rootMissing` 有内联修复入口——不构成新 P 级）；`CullingView+Content` 的意图消费（`workspace.take(.cullingConflicts)`）与新 `setFilterState` 的相互作用只做了代码级核对，未追踪端到端。
7. **本报告不含**：性能（缩略图解码预算/滚动帧率）、XMP 写入正确性、l10n 键覆盖率（en 表 1862 条是否覆盖本模块新增 key）——按任务边界只做交互与显示。
