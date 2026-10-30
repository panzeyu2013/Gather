# C 组 · 浏览类页面交互审计：图库 Gallery / 灯箱 Lightbox / 全局图库 Library / 工作台 Dashboard

- 审计日期：2026-10-30
- 范围：`GatherUI/Gallery/`（16 文件 2797 行）、`GatherUI/Library/`（14 文件 2227 行）、`GatherUI/Dashboard/`（12 文件 2182 行），共约 7200 行；只读静态审计，未构建、未运行。
- 方法：逐文件通读 + 与挑片页（CullingGrid）、会话页骨架（GatherSessionPage / SessionPageHost）对照 + 按 860×560 最小窗口做宽度预算。
- 本文只记录**可复现的、用户可见的**缺陷，凡"已修复项"在 `## 亮点` 里给正评；凡无法静态证实的一律进 `## 未验证与风险`。

---

## 结论

1. **最严重的一类问题是"浏览态被刷新毁掉"**：图库的工具栏刷新（也是 ⌘R）走 `viewModel.load()` → `phase = .loading` + `reload()` → `clearSelectionForNewQuery()`，一次刷新同时造成「网格整个换成转圈 → 滚动位置回顶 → 已选的 N 张照片静默清空」，且没有任何提示。这与该页"事件刷新就地更新、不动选择"的设计意图（`refreshOnEvent` 只用 `formIntersection`）自相矛盾，属于两条刷新路径语义不一致。
2. **图库的搜索会先给一个假的"没有符合条件的照片"**：搜索只对**已加载页**做客户端过滤，命中项不在已加载页时不会重查首页，而是靠链式拉页补齐；在补齐之前 `filteredPhotos.isEmpty` 为真 → 直接渲染空态。此时网格（含分页哨兵）根本不渲染，若链式拉页中途失败，**这个假空态就成了没有出口的死态**（只能清筛选或改关键词）。
3. **图库的键盘模型是"只改状态、不改视野"**：四个方向键都映射到 `moveGalleryCursor(by:±1)`，只改 `keyboardCursorId` 与选择集，**既不滚动到游标、也不维护行/列**；同时每次按键先 `clearSelection()`，⌘ 点多选 30 张后按一下 → 就只剩 1 张。挑片页（CullingGrid）有 `ScrollViewReader + proxy.scrollTo`，图库没有——同一产品两套键盘体验。
4. **窄窗口（860×560）下三个页面的横向预算都不够**：图库选择栏需要约 680pt（检查器打开后内容列只剩约 460pt）且没有横向滚动；全局图库的筛选头行（搜索框 + 工作区菜单 + 清除/刷新）同样没有 `ViewThatFits`；筛选规则编辑器的"字段/操作符/值"是三个固定宽 Picker，缩窗后只能互相挤压。作者此前为"索引头行"专门加了横向 ScrollView（D-1），说明这类问题是已知的，只是其余横排没跟上。
5. **灯箱是"半截的路"**：它以模态 sheet 呈现、只接收打开时那一个快照数组，"N / M" 里的 M 是**已加载**张数；翻到第 200 张后 → 灰掉，没有"继续加载"，也没有任何提示说后面还有照片。关闭后不回写网格的游标/选择，用户翻了 20 张再关闭，网格仍停在打开前那一张的位置。按钮叫"在灯箱中比较"，实际行为是"打开第一个选中项并单张翻页"——文案承诺了产品没做的事。

---

## 发现

### P0

无。上一轮 P0（假空态、世代竞态、shutdown 后复活、约束循环崩溃）在当前代码里都能看到对应防线（`fetchGeneration`/`fetchingGeneration`/`isShutdown`/`.inspector` 不用 Form），本次未发现新的数据损坏或不可恢复路径。

---

### P1

#### P1-1 · 图库刷新（⌘R）会清空选择、把网格换成转圈、滚动回顶

**位置**
- `desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryToolbar.swift:15-16`
- `.../Gallery/GalleryViewModel+Load.swift:28-29, 90-93`
- `.../Gallery/GalleryViewModel+Core.swift:63-68`
- `.../Gallery/GalleryView+Content.swift:426-436`

```swift
// GalleryToolbar.swift:15-16
refreshKeyboardShortcut: true,
onRefresh: { Task { await viewModel.load() } },

// GalleryViewModel+Load.swift:28-29 / 90-93
private func performLoad() async {
    phase = .loading                       // ← 网格被 ProgressView 取代
    ...
    clearSelectionForNewQuery()            // ← 选择集整份清空（无提示）

// GalleryViewModel+Core.swift:63-68
func clearSelectionForNewQuery() {
    isScopeSelection = false
    batchCullingStates = [:]
    guard !selectedIds.isEmpty else { return }
    selectedIds = []
}
```

**现象**：已加载的页被 `pages = []` 清空；`phase = .loading` 让内容区整块变成 `ProgressView("加载照片中…")`（`GalleryView+Content.swift:428-430`）。ScrollView 连同其偏移一起被销毁，重排后停在顶部；`selectedIds` 归零，选择栏瞬间变成"选中 0 张照片"，批量操作/导出/在 Finder 中显示全部变灰。

**用户影响（可复现）**：
1. 图库滚到第 800 张附近，⌘ 点选 40 张（选择栏显示"选中 40 张照片"）；
2. 按 ⌘R（或点工具栏刷新图标）；
3. 网格闪成转圈 → 回到第 1 张 → 选择变成 0。
没有任何提示解释选择为什么没了；用户要重新滚、重新选。同一页的"事件驱动刷新"（`refreshOnEvent`）却只做 `selectedIds.formIntersection`（`+Events.swift:79-81`），两条刷新路径行为相反。

**修复建议**：`load()` 拆成两种语义——"首次加载/失败重试"允许 `phase = .loading` + 清选择；"用户主动刷新"走 `refreshOnEvent()`（就地替换页、保留 `page`/选择/滚动位置），或至少保留 `phase` 与 `selectedIds`，并用 `ScrollPosition` 记住第一可见照片 id 后恢复。

---

#### P1-2 · 搜索命中在未加载页时，先渲染"没有符合条件的照片"，且失败后无出口

**位置**
- `.../Gallery/GalleryViewModel+Filter.swift:67-104`（`commitSearch` 不重查首页）
- `.../Gallery/GalleryViewModel+Derived.swift:26-55`（`filteredPhotos` 只过滤 `loadedPhotos`）
- `.../Gallery/GalleryView+Content.swift:456-468, 497-510`
- `.../Gallery/GalleryViewModel+Scroll.swift:23-43`（链式拉页失败即终止）

```swift
// GalleryView+Content.swift:456-468
private var loadedContent: some View {
    let filtered = viewModel.filteredPhotos
    if filtered.isEmpty {
        if viewModel.loadedPhotos.isEmpty { emptyLibraryView }
        else { noMatchView }          // ← 只要"已加载的前 200 张"里没命中，就是无结果
    } else { gridView(filtered) }     // ← 空态下 gridView（含分页哨兵）不渲染
}

// GalleryViewModel+Filter.swift:100-103
if nextActive {
    Task { await chainFetchIfActive() }   // 只从现有游标往后追加，不重查首页
}
```

**现象**：搜索是纯客户端过滤，命中的照片不在已加载页时不会重查，而是靠 `chainFetchIfActive` 拉 1000/页往后补。补齐完成前，页面显示的是 `ContentUnavailableView("没有符合条件的照片")`。若链式拉页中途失败，`+Scroll.swift:37` 的 `guard hadMore, self.pages.count > before else { return }` 直接终止循环；而空态里没有网格 → 没有哨兵 → `loadMoreIfNeeded()` 再也无人调用 → **用户永久停在假空态**，只能点"清除筛选"或再改关键词。

**用户影响（可复现）**：
1. 打开一个有 5,000 张的工作区图库（默认只加载 200 张）；
2. 搜索一个排在第 600 位的文件名；
3. 先看到"没有符合条件的照片 / 调整或清除筛选条件以查看全部照片"，几百毫秒后结果才跳出来；
4. 若此时网络/数据库偶发失败 → 停在空态，且页顶的红色 banner 只说"操作失败"，没有重试。

**修复建议**：(a) `searchActive` 首次提交时**重查首页**（`limit = chainFetchLimit`），拿到确定性结果再决定空态；(b) 空态判定加 `!isFetchingNextPage`/`hasNextPage` 门控，加载中显示"正在搜索…"骨架而不是"没有结果"；(c) 空态里补一个"继续搜索全库/重试"按钮，别让用户无路可走。

---

#### P1-3 · 图库方向键：游标不滚动进视野，且会摧毁多选

**位置**
- `.../Gallery/GalleryGrid.swift:50-59`
- `.../Gallery/GalleryView+Content.swift:325-337`

```swift
// GalleryGrid.swift:53-56
.onKeyPress(.leftArrow) { moveGalleryCursor(by: -1); return .handled }
.onKeyPress(.rightArrow) { moveGalleryCursor(by: 1); return .handled }
.onKeyPress(.upArrow) { moveGalleryCursor(by: -1); return .handled }
.onKeyPress(.downArrow) { moveGalleryCursor(by: 1); return .handled }

// GalleryView+Content.swift:332-337
let next = min(max(0, start + delta), photos.count - 1)
let id = photos[next].id
keyboardCursorId = id
viewModel.clearSelection()      // ← 多选被整份丢弃
viewModel.toggleSelection(id)
```

**现象**：(1) 上/下与左/右完全等价（线性 ±1，没有网格行列语义）；(2) 移动游标后**没有任何滚动**——整个 Gallery 目录内不存在 `ScrollViewReader`/`scrollTo`/`scrollPosition`（只 `CullingGrid.swift:188,219-224` 有）；(3) 每次移动先清空选择集。

**用户影响（可复现）**：
1. 图库按住 ↓ 连按 12 次——从第 8 次起游标已在视口外，屏幕**完全不动**，但选择栏的"选中 1 张照片"对应的已是看不见的照片；
2. ⌘ 点选 10 张后按一下 →，10 张全变 1 张（无撤销）。

**修复建议**：参照 `CullingGrid`，给每个 cell 加 `.id(photo.id)` + `ScrollViewReader`，游标变化时 `proxy.scrollTo(id, anchor: .center)`；左右按 ±1、上下按 ±(每行张数)；移动游标时用 `moveCursor` 语义（不改选择集），选中另用空格切换，与 Finder/照片 App 一致。

---

#### P1-4 · 最小窗口 + 检查器打开时，图库选择栏被挤压/截断

**位置**：`.../Gallery/GalleryView+Content.swift:245-322`

```swift
private var selectionBar: some View {
    HStack(spacing: 12) {
        Label { Text(l10n.format("选中 %lld 张照片", viewModel.selectedIds.count)) } ...
        Spacer(minLength: 0)
        Button(l10n("全选筛选结果")) ...
        Menu(l10n("批量操作")) ...
        Button(l10n("导出所选")) ...
        Button(l10n("在灯箱中比较")) ...
        Button(l10n("在 Finder 中显示")) ...
        Button(l10n("取消选择")) ... .keyboardShortcut(.escape, modifiers: [])
    }
    .frame(height: 32)      // 固定高、无横向滚动、无 ViewThatFits
```

**现象**：该行 6 个 borderless 按钮 + 计数标签的固有宽度约 680pt（中文标签合计约 446pt + 5×12 间距 + 标签约 114pt + `pageGutter` 48pt）。最小窗口 860pt、侧栏 180pt、检查器最小 220pt 时内容列只有 **约 460pt**；`HStack` 里只有 `Spacer(minLength: 0)`，没有任何换行/滚动兜底，超出部分只会把按钮文字压成"取消选…""在 Finder…"，或直接顶出可视区。

**用户影响**：把窗口缩到最小并打开检查器（这是 13"/14" 笔记本的常见状态）后，"导出所选/在 Finder 中显示/取消选择"三个动作可能看不见或被截断，而这三个正是批量操作后的收尾动作。同一文件里"索引头行"因为同样原因已经改成 `ScrollView(.horizontal)`（`GalleryView+Content.swift:179-198`），选择栏漏改。

**修复建议**：与索引头同一处理——`ViewThatFits` 两档（宽：一行；窄：两行或"批量操作"收进一个 Menu）；或把 6 个动作合并成一个"批量"菜单 + 一个主按钮（导出），把宽度压到 300pt 以内。

---

#### P1-5 · 切页签再回到图库，滚动位置与键盘游标全部丢失

**位置**
- `.../Shell/SessionPageHost.swift:44-54`（`.id("session-page-\(sessionId)-\(page.rawValue)")`）
- `.../Gallery/GalleryView.swift:74-78`（`density/lightboxIndex/keyboardCursorId` 都是页内 `@State`）

```swift
// SessionPageHost.swift:46-48
pageView(workspace)
    .environment(\.languageStore, languageStore)
    .id("session-page-\(sessionId)-\(page.rawValue)")   // ← 换页签即换身份 = 整棵子树销毁
```

**现象**：页签切换会改变 `.id`，GalleryView 的 `ScrollView`、`keyboardCursorId`、`layoutCache` 全部重建。VM 里 `pages` 还在（`loadIfNeeded` 有 `pages.isEmpty` 守卫，不会重取），所以数据不丢、只丢位置。

**用户影响（可复现）**：图库滚到第 300 张 → 点"挑片"改一个决策 → 点"浏览"回来 → 停在第一张，游标也没有。大工作区里"回来看一眼刚才那张"要重新滚 300 张。灯箱打开时的 `lightboxIndex` 同样丢失（切换页签会直接关掉灯箱，这倒可接受）。

**修复建议**：把"第一可见照片 id + 游标 id"提到 VM（或 `@SceneStorage`），列表重挂载时 `scrollTo`；这与 P1-3 需要的滚动锚点是同一套基础设施，一次做完两处受益。

---

#### P1-6 · 全局图库：筛选头行在窄窗口无适配，翻页不回到顶部

**位置**
- `.../Library/LibraryView+Filters.swift:41-104`（`browseHeaderRow`）
- `.../Library/LibraryView+Content.swift:99-135`（`photoGrid` / `pagination`）
- `.../Library/LibraryViewModel+Paging.swift:11-27`

```swift
// LibraryView+Filters.swift:42-48 & 52-68 —— 平铺的 HStack，无 ViewThatFits
HStack(spacing: 5) {
    GatherSearchField(...).frame(minWidth: 110, maxWidth: 320)
    Spacer(minLength: 5)
    HStack(spacing: 5) {
        Text(l10n("工作区")).font(.callout).fixedSize()
        GatherMenuField(..., minWidth: 88, fixedWidth: 112)
    }
    ...两个 22pt 图标按钮...
}
```

**现象**：这一行含 `.fixedSize()` 的"工作区"标签与 `fixedWidth: 112` 的菜单，最小固有宽度约 380–420pt；同文件下方的主筛选三列**已经**用 `ViewThatFits` 做了两档（`LibraryView+Filters.swift:115-123`），这一行漏了。检查器（`inspectorMinWidth 220`）打开时内容列约 460pt，搜索框被压到 110pt 下限，工作区菜单与两个图标按钮挤在一起。
另外：`nextPage()` 只换数据，滚动偏移沿用旧值——**在第 2 页底部点"下一页"，会落在第 3 页的中后段**（内容高度相近时偏移几乎不变）。

**用户影响**：窄窗口下搜索框只剩"搜索文件..."几个字，工作区名被截成两个汉字，清除/刷新两个图标挤在右边缘；翻页后看到的不是新一页的开头，容易被误认为"没翻成功"。

**修复建议**：`browseHeaderRow` 套 `ViewThatFits`（窄档：搜索独占一行，工作区 + 图标按钮第二行）；`goToPage` 成功后用 `ScrollViewReader.scrollTo(topAnchor)` 回到顶部。

---

#### P1-7 · 灯箱只能翻到"已加载"的最后一页，且关闭后不回写浏览位置

**位置**
- `.../Gallery/GalleryView+Content.swift:82-91, 144-150`
- `.../Gallery/LightboxView.swift:12-13, 114, 251-259, 285-295`

```swift
// GalleryView+Content.swift:84-89 —— 传的是一次性快照
if let index = lightboxIndex {
    LightboxView(photos: viewModel.filteredPhotos, initialIndex: index, onClose: closeLightbox)
}

// LightboxView.swift:114 / 251 / 259
Text("\(currentIndex + 1) / \(photos.count)")       // photos = 打开时的已加载数组
.disabled(currentIndex == 0)
.disabled(currentIndex == photos.count - 1)          // 到最后一张就到此为止
```

**现象**：(1) 灯箱内没有"接近末尾再取一页"的逻辑，`photos` 是打开时捕获的数组；(2) 页签显示"M"是**已加载**张数，与页面顶部的"已索引 5,230 张照片"不一致，用户无法判断后面还有；(3) `closeLightbox()` 只把 `lightboxIndex = nil`，不回写 `keyboardCursorId`、不滚动、不改变选择。

**用户影响（可复现）**：
1. 图库刚打开（200 张已加载），点第 10 张进灯箱；
2. 按住 → 连翻，翻到第 200 张时"下一张"变灰，标题显示"200 / 200"；
3. 用户以为工作区只有 200 张（顶部却写着 5,230）；
4. 翻到第 40 张后关灯箱——网格还停在原来第 10 张的位置，键盘游标也没动，无法"接着刚才继续看"。

**修复建议**：灯箱接收一个 `onReachEnd` 闭包（或直接持有 VM），接近末尾调用 `loadMoreIfNeeded()`；标题用"已加载/总数"两段或加"加载更多"；关闭时把当前照片 id 回写 `keyboardCursorId` 并 `scrollTo`。

---

### P2

#### P2-1 · 图库分页失败没有"就地重试"，错误条在视线外

**位置**：`.../Gallery/GalleryGrid.swift:40-46`、`.../Gallery/GalleryView+Content.swift:14-22`；对照 `.../Culling/CullingGrid.swift:207-214`。

```swift
// GalleryGrid.swift:40-46 —— 哨兵只会"再试一次"，没有失败态 UI
Color.clear.frame(height: 1).onAppear { Task { await viewModel.loadMoreIfNeeded() } }

// GalleryView+Content.swift:14-22 —— 错误条挂在滚动区之外（页面顶部）
if let error = viewModel.actionError {
    NativeBanner(text: l10n.format("操作失败：%@", ...), color: GatherTheme.error)
}
```

**现象**：翻页失败时 `+Scroll.swift:168-175` 只设 `actionError`，而 banner 渲染在页面**顶部、网格滚动区之外**；用户停在列表底部看不到任何变化（只有滚回顶部才看到红条）。挑片页在列表末尾就有"加载失败，重试"按钮（`CullingGrid.swift:207-214`），图库没有。

**用户影响**：滚到底白屏一片（哨兵行只有 1pt），以为"这个工作区就这么多照片"。
**修复建议**：给 VM 暴露 `loadMoreFailed`，在 `LazyVStack` 末尾渲染"加载失败，重试"按钮（照抄 CullingGrid）。

#### P2-2 · 错误条无法关闭，且会跟随 VM 跨越页面存活

**位置**：`.../Gallery/GalleryView+Content.swift:16-19`、`.../Library/LibraryView.swift:109-113`、`.../Dashboard/DashboardView.swift:79-83`。
三处都构造 `NativeBanner(text:)` 而**没有传 `onDismiss`**（`NativeBanner.swift:105-114` 已支持关闭按钮）。`actionError` 只在"下一次成功取页/成功动作"时被清（`+Scroll.swift:166`），而 VM 由 `SessionWorkspace` 按会话缓存——离开图库再回来，红条还在。
**修复建议**：三处都传 `onDismiss: { viewModel.clearActionError() }`；或给 banner 加"12 秒自动消退"（与 Toast 一致）。

#### P2-3 · 图库右键菜单里有两个同名的"取消选择"

**位置**：`.../Gallery/GalleryGrid.swift:157-165`

```swift
Divider()
Button(viewModel.selectedIds.contains(photo.id) ? l10n("取消选择") : l10n("选择")) { ... }
if !viewModel.selectedIds.isEmpty {
    Button(l10n("取消选择")) { viewModel.clearSelection() }   // ← 同名，语义是整个选择集
}
```

**现象**：右键一张已选照片 → 菜单出现两行"取消选择"，一行只取消这一张、一行清空全部；没有副标题区分。
**用户影响**：误点第二行会丢掉几十张的选择。
**修复建议**：第二条改成"取消全部选择（N）"。

#### P2-4 · "在灯箱中比较"名不副实；"在 Finder 中显示"在全范围选择下静默无反应

**位置**：`.../Gallery/GalleryView+Content.swift:299-303, 369-376, 415-421`

```swift
func revealSelectedInFinder() {
    let urls = viewModel.filteredPhotos.filter { viewModel.selectedIds.contains($0.id) }
        .compactMap { finderURLForPath($0.filepath) }
    guard !urls.isEmpty else { return }   // ← 没有任何反馈
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}
```

**现象**：⌘A 走服务端全选（`+Filter.swift:9-46`，最多 20,000 个 id），但"在 Finder 中显示"只处理**已加载**的那些；如果选中项全都不在已加载页（例如全选后从第 1 页翻走），点击完全没反应。"在灯箱中比较"实际只打开"第一个选中项"并单张翻页，不是并排比较。
**用户影响**：点按钮毫无反馈，用户会怀疑按钮坏了。
**修复建议**：按钮改名为"在灯箱中查看"；Finder 路径无结果时 `GatherToastCenter` 提示"选中的照片尚未加载，请先滚动加载"。

#### P2-5 · 事件刷新与哨兵分页是两套并发守卫，可能互相覆盖

**位置**：`.../Gallery/GalleryViewModel+Events.swift:45-76` 与 `.../Gallery/GalleryViewModel+Scroll.swift:136-147`

```swift
// +Events.swift:46-76 —— 重新从首页拉到 targetCount，最后整份替换
fetchTask?.cancel()
var nextPages: [[GalleryPhotoData]] = []
... while cursor != nil && nextPages.reduce(0, { $0 + $1.count }) < targetCount
pages = nextPages ; pageCursors = nextCursors      // ← 覆盖式写

// +Scroll.swift:142 —— 哨兵取页只看 fetchingGeneration，不知道 refreshOnEvent 在跑
guard fetchingGeneration != generation else { return hasNextPage }
```

**现象**：`refreshOnEvent` 期间滚到底，哨兵触发的 `fetchNextPage` 会真的发请求并 `pages.append`，随后被 `pages = nextPages` 整份丢弃——重复请求 + 已加载页回退。
**用户影响**：边滚边有写路径事件（挑片页每改一次决策都会广播）时，列表可能突然少一页。
**修复建议**：给 `refreshOnEvent` 与 `fetchNextPage` 共用同一个"取页中"闸门（`fetchingGeneration` 或者新增 `isRefreshing`），刷新期间 `loadMoreIfNeeded` 直接早退。

#### P2-6 · 缩窗时 justified 布局每一帧全量重排（无节流/无量化）

**位置**：`.../Gallery/GalleryGrid.swift:31-33, 71-103`

```swift
let rows = layoutRows(filtered: filtered, width: max(1, geometry.size.width - 48))
...
let key = "\(viewModel.layoutGeneration)|\(viewModel.filteredFingerprint)|\(filtered.count)|\(width)|\(density)"
if layoutCache.key == key { return layoutCache.rows }
```

**现象**：缓存键里含连续量 `width`，拖拽窗口的过程中每一帧宽度都不同 → 每帧都 miss → 对全部已加载照片（最多 2 万）重跑 `layoutJustifiedRows`（内含逐项 `reduce`，O(n·k)）并重建所有 `JustifiedLayoutItem`。行高变化后总内容高度也变，ScrollView 保持"点偏移"→ 可视照片跳走。
**用户影响**：5000 张的库里拖窗口边缘会掉帧；松手后停在完全不同的照片上。
**修复建议**：宽度量化到 8pt 再进 key；或对 resize 用 0.1–0.2s 去抖；并用"第一可见照片 id + 相对偏移"做缩放锚点。

#### P2-7 · 灯箱：放大后可以把照片整个拖出可视区；双击是"归位"不是"100%"

**位置**：`.../Gallery/LightboxView.swift:175-189`、`.../Culling/CullingViewerParts.swift:68-71`

```swift
// CullingViewerParts.swift:69-71 —— 无任何边界钳制
static func apply(start: CGSize, translation: CGSize) -> CGSize {
    CGSize(width: start.width + translation.width, height: start.height + translation.height)
}
```

**现象**：`scale > 1` 时拖拽位移完全不受限（没有 max offset = 图片尺寸×缩放 - 视口）；拖太远只剩黑底。双击执行 `resetTransform()`（回 100%），而 macOS 照片/预览的惯例是双击切换"适应窗口 ↔ 100%"。
**用户影响**：放大看细节时手一滑照片就"消失"了，需要找底部"重置"按钮（在 720pt 宽 sheet 的最右端）。
**修复建议**：给 `PanOffset.apply` 加基于视口/缩放比的钳制；双击改为"适应窗口 ↔ 100%"切换。

#### P2-8 · 灯箱 Esc 与网格"取消选择"共用 Esc，优先级未经隔离

**位置**：`.../Gallery/LightboxView.swift:117-119`、`.../Gallery/GalleryView+Content.swift:309-314`

```swift
// 灯箱：关闭按钮挂 cancelAction
Button(l10n("关闭"), action: onClose).keyboardShortcut(.cancelAction)
// 网格选择栏：取消选择挂裸 Esc
Button(l10n("取消选择")) { viewModel.clearSelection() }
    .keyboardShortcut(.escape, modifiers: [])
```

**现象**：两者在同一个 NSWindow 的视图树里（sheet 是附着的）。若 key-equivalent 扫描同时命中父视图，Esc 会"关灯箱 + 清空网格选择"。
**用户影响**：选 300 张后进灯箱看一眼、按 Esc 关掉，回来发现选择没了。
**修复建议**：把网格的 Esc 从 `keyboardShortcut` 改成 `.onKeyPress(.escape)`（已有，`GalleryGrid.swift:59`），删掉按钮上的快捷键，彻底避免跨层竞争。

#### P2-9 · 全局图库卡片：缩略图被固定 110pt 裁切、无悬停、无多选

**位置**：`.../Library/LibraryCardView.swift:24-48, 79-98`；`.../Support/PhotoThumbnailView.swift:180`（`contentMode: ContentMode = .fill`）

```swift
PhotoThumbnailView(path: photo.filepath, size: 512)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(height: 110)          // ← 高度写死，宽度 150–220 自适应
    .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, ...))
```

**现象**：`.fill` + 固定高 → 竖构图照片只保留中间一条横带（3:4 的图在 150×110 里只看到约 44% 高度）；图库（GalleryCellView）是按原始比例 justified 排布、永不裁切。卡片没有 `onHover`、没有选中态、没有多选——整页无法批量操作。
**用户影响**：人像/竖构图在全局图库里认不出来（脸常被裁掉），跨工作区找图时"看缩略图"这一行为失效。
**修复建议**：至少把高度改成 `aspectRatio(4/3, contentMode: .fit)` 或按卡片宽度×0.75；若要保留定高，则 `contentMode: .fit` + 背景兜底，别裁。

#### P2-10 · 筛选规则编辑器：三段不自解释、数字字段会吞输入、行宽不可压缩

**位置**：`.../Library/FilterRuleEditor.swift:112-139, 142-169, 206-237`

```swift
// 206-217：数字字段用 Double 解析失败就写 .null → getter 立刻返回 "" → 输入被吞
set: { text in
    var updated = rule
    switch kind {
    case .number: updated.value = Double(text).map(JSONValue.number) ?? .null
    default: updated.value = .string(text)
    }

// 112-127：三个固定宽控件，无换行/滚动
Picker(...).frame(width: 110)     // "标题（Headline）" 在这里必然截断
Picker(...).frame(width: 96)
valueEditor(...)                  // 再 110–140 + 删除按钮
```

**现象**：(1) 数字字段（星级/ISO）输入 `-` 或 `1e` 等中间态时值变成 `.null`，getter 返回空串，**字符被立即吞掉**，输入负数/科学计数法不可能；(2) `between` 的两个边界永远写 `.string`（`:231`），同一个数字字段 `eq` 写 number、`between` 写 string，比较语义不一致；(3) 三个固定宽 Picker 在"更多筛选"展开 + 检查器打开（内容列约 460pt）时挤到最小值，删除按钮 ✕ 被推到边上；(4) `TextField(l10n("值"), ...)` 全部 `.labelsHidden()`，三段里第三段是个没有任何提示的空框，`in` 操作符的"逗号分隔"约定也只在被隐藏的 label 里。
**修复建议**：数字用字符串缓冲 + 提交时解析（不即时写 null）；`between` 按 kind 写 number；行套 `ViewThatFits`（窄档改成两行：字段+操作符一行、值一行）；`in` 用 `placeholder` 显示"逗号分隔"。

#### P2-11 · 全局图库：分面芯片显示英文原值，与上方筛选菜单不一致

**位置**：`.../Library/LibraryFacetBar.swift:63-85` vs `.../Library/LibraryView+Filters.swift:27-30`

```swift
// FacetBar:69 —— 直接拼原始 value
Text("\(bucket.value) · \(bucket.count)")
// Filters:29 —— 同一维度走本地化
options: LibraryColorOption.all.map { (l10n.resolve($0.label), $0.value) }
```

**现象**：色标维度芯片显示 `Red · 42` / `Blue · 7`，而紧邻上方"颜色"菜单显示"红/蓝"；相机/镜头维度显示原始型号（可接受），年份显示 `2024`。中文界面里混入一列英文。
**修复建议**：给 `label` 维度单独映射到 `CullingDisplayFormat.title`（挑片页已有该函数），其余维度保持原值。

#### P2-12 · 分面查询失败会显示成"操作失败"

**位置**：`.../Library/LibraryViewModel.swift:282-301`

```swift
} catch {
    guard facetsRequestID == requestID else { return }
    facets = []
    actionError = CommandError(error)     // ← 同一个 actionError 被三处语义共用
}
```

**现象**：`actionError` 同时承载"取照片失败/相册写失败/分面计数失败"，页面统一渲染成"操作失败：…"。分面是辅助信息，失败却弹出一个"操作失败"的红条，用户会以为刚才的删除/相册操作失败了。
**修复建议**：分面失败静默（只清空 facets），或走单独的 `facetsError` 渲染在分面区域内部。

#### P2-13 · 工作台会话行双击无反应、回车无反应

**位置**：`.../Dashboard/DashboardView.swift:259-274`、`.../Dashboard/SessionRowView.swift:26-38`

```swift
// SessionRowView.swift:26-38 —— 行本身不是按钮，只有右侧"进入"
HStack(spacing: 12) { identity; Spacer(minLength: 12); actions }
    .contextMenu { Button(l10n("打开"), action: onOpen) ... }

// DashboardView.swift:260-273 —— List(selection:) 绑了选择，但没有 onKeyPress/双击
List(selection: $selectedIds) { summaryRow; sessionsSection; jobsSection }
    .onDeleteCommand { ... }
```

**现象**：macOS 列表的通用心智是"双击打开行 / 回车打开选中行"，这里两者都没有：双击只会让行保持选中，回车什么也不发生；唯一入口是行尾那颗"进入"按钮（在 860pt 宽度里还排在名称+徽标+四个状态胶囊之后）。
**用户影响**：用户双击 -> 没反应 -> 以为卡片坏了；键盘用户完全无法打开工作区。
**修复建议**：行加 `.onTapGesture(count: 2) { onOpen() }`（或在 List 上加 `onKeyPress(.return)` 对 `selectedIds` 取唯一项打开）；保留"进入"按钮不冲突。

#### P2-14 · 批量删除的确认按钮叫"删除全部"

**位置**：`.../Dashboard/DashboardView.swift:148-164`

```swift
Button(l10n("删除全部"), role: .destructive) { ... }
...
Text(l10n.format("确定要删除选中的 %lld 个工作区吗？...", selectedIds.count))
```

**现象**：这是"删除选中的 N 个"，按钮写"删除全部"会被读成"删除所有工作区"。同屏还有"全选"按钮，语义更容易混淆。
**修复建议**：改成"删除选中的 N 个"。

#### P2-15 · 新建工作区：选第二个文件夹时名称不再更新（自触发 `nameEdited`）

**位置**：`.../Dashboard/NewSessionSheet.swift:81, 138-142, 158-165`

```swift
// :81 名称字段任何变化都记成"用户编辑过"
.onChange(of: name) { _, _ in nameEdited = true }

// :138-141 程序化填入也被上面这条监听捕获
folderPath = url.path
if !nameEdited { name = url.lastPathComponent }   // 第一次能填，之后永远跳过
```

**现象**：第一次"选择文件夹"把目录名填进名称 → 该赋值触发 `.onChange(of: name)` → `nameEdited = true` → 之后换目录、切来源都不再自动命名。
**用户影响（可复现）**：新建工作区 → 选择文件夹 A（名称自动 = A）→ 发现选错，再点"选择文件夹"选 B → **名称仍是 A** → 创建出来的工作区叫 A 但内容来自 B。
**修复建议**：程序化赋值时把 `nameEdited` 显式复位（用 `isProgrammaticName` 标志包裹），或改成"名称 == 上次自动生成值时才覆盖"。

#### P2-16 · 新建工作区："创建"禁用时不给理由

**位置**：`.../Dashboard/NewSessionSheet.swift:115-123, 203-218`

```swift
case .local:
    return !name.trimmingCharacters(in: .whitespaces).isEmpty && !folderPath.isEmpty
...
Button(l10n("创建"), action: create).disabled(!canCreate || viewModel.isCreating)
```

**现象**：名称或目录任一为空，"创建"就是灰的，但表单里没有任何一行说明缺什么（脚注只讲"名称会自动生成"）。名称 placeholder 写"自动生成"，与"必须非空才能创建"的规则互相矛盾。
**用户影响**：从工具栏"新建工作区"进来（无预填目录）的用户，填了名称后按钮仍是灰的（因为没选目录），不知道还差一步。
**修复建议**：`LabeledContent("文件夹位置")` 行尾加内联校验文案"请选择文件夹"（红/次要色），或按钮 hover 时 `help` 说明原因；把 placeholder 改成"留空则用文件夹名"。

#### P2-17 · 首屏 hero 不可点却跟随 hover 抬起；快捷卡动画不尊重"减少动态"

**位置**：`.../Dashboard/DashboardFirstRunView.swift:52-95, 350-356`

```swift
// :86-95 —— 纯容器（无 Button/无 action）却做 hover 阴影动画
.shadow(color: GatherTheme.shadowHero, radius: heroHovered ? 26 : 18, x: 0, y: heroHovered ? 12 : 8)
.animation(reduceMotion ? nil : .easeOut(duration: GatherMetrics.Motion.standard), value: heroHovered)
.onHover { heroHovered = $0 }

// :355 —— DashboardQuickCard 的 hover 动画没读 reduceMotion
.animation(.easeOut(duration: GatherMetrics.Motion.hover), value: isHovered)
```

**现象**：hero 是首屏最大的一块，鼠标移上去会"浮起来"，暗示可点击，但点击没有任何动作；同一文件里 hero 做了 reduceMotion 保护，快捷卡漏了。
**修复建议**：hero 的 hover 只保留极轻微的高亮（或干脆去掉），或让整块 hero 点击 = "导入文件夹"；快捷卡动画补 `reduceMotion` 分支。

#### P2-18 · 首屏同一句"照片不会被移动"出现两次

**位置**：`.../Dashboard/DashboardFirstRunView.swift:113`（hero 副标题）与 `:211-219`（privacyNote）。

**现象**：`"从文件夹或 Capture One 导入；照片不会被移动。"` 与 `"所有处理都在本地完成；照片不会被移动。"` 同屏重复；后者还是居中一条弱化的注脚，视觉上像免责声明。
**修复建议**：副标题保留产品承诺，注脚只留"所有处理都在本地完成"。

#### P2-19 · 终态事件逐个触发 `refreshAll()`，无合并、无 N+1 保护

**位置**：`.../Dashboard/DashboardViewModel+Polling.swift:61-74`、`.../Dashboard/DashboardViewModel+Load.swift:28-50`

```swift
if event.isTerminal {
    ...
    lastFullRefreshAt = Date()
    Task { await refreshAll() }     // ← 每帧一个 Task，无 "已有刷新在跑" 守卫
}
...
// refreshSessions：串行 N 次 workspace.status
for session in sessions { if let status = await workspaceStatus(sessionId: session.id) { ... } }
```

**现象**：一次索引结束若同时产生多个 job 的终态帧（metadata.scan + thumbnail.build + quality.score），会并发出 N 个 `refreshAll`，每个再串行打 `N 个工作区` 的 status。20 个工作区 × 3 帧 = 60 次 status 请求。
**用户影响**：任务结束时列表卡顿、进度条来回跳（每次 `jobs` 被整份替换）。
**修复建议**：`refreshAll` 加单飞（`isRefreshing` guard + 一个 pending 标志），终态帧走 300ms 合并。

#### P2-20 · 回到工作台后最多 30 秒不刷新

**位置**：`.../Dashboard/DashboardViewModel+Polling.swift:11-21, 40-44`、`.../Shell/RootShellWorkspace.swift:102-110`

```swift
if case .dashboard = destination { viewModel.isVisible = true; viewModel.startAutoRefresh() }
...
let due = Date().timeIntervalSince(lastFullRefreshAt) >= 30
guard due else { return }
```

**现象**：离开工作台再回来，`startAutoRefresh` 只是重启 2s 心跳；`lastFullRefreshAt` 若在 30 秒内，心跳会直接 return，页面显示的是离开前的快照（页面 `.task` 只在 `phase == .loading` 时才 `loadAll`）。
**用户影响**：在别处删了工作区/跑完索引后回工作台，计数与列表是旧的，最长 30 秒。
**修复建议**：进入工作台时把 `lastFullRefreshAt = .distantPast`（或直接 `refreshAll()` 一次）。

#### P2-21 · 空工作区态 `emptySessionsState` 不可达

**位置**：`.../Dashboard/DashboardView.swift:223-227` 与 `:309-311`

```swift
// :223-227  sessions 为空时整页就是 firstRunState
if viewModel.sessions.isEmpty { firstRunState } else { workspaceList }
// :309-311  再次判断 sessions.isEmpty —— 永远为假
if viewModel.sessions.isEmpty { emptySessionsState } else { ForEach(...) }
```

**现象**：`emptySessionsState`（`ContentUnavailableView("暂无工作区") + 新建工作区`）永远渲染不到；两套空态文案并存。
**修复建议**：删掉死分支，或把 `firstRunState` 只在"首次运行"用、有历史但删空时用 `emptySessionsState`。

#### P2-22 · 三个浏览页直接用系统字体样式（违反 design token 规则），跨页不一致

**位置**：`.../Gallery/GalleryView+Content.swift:206, 228, 238`；`.../Library/LibraryView+Content.swift:15, 19, 21, 125`、`.../Library/LibraryView+Filters.swift:54, 157, 231`；`.../Dashboard/SessionRowView.swift:45, 51, 62, 87, 104`、`.../Dashboard/JobRowView.swift:62, 67`、`.../Dashboard/NewSessionSheet.swift:180, 189, 194, 206`。

规则明确写在 `docs/design/appearance-interaction.md:147`："❌ 页面里直接 `.font(.callout)` / `.font(.system(size:))`：改用 `.gatherText(...)` 或 `GatherFont` 角色。" 这三个目录里仍有 20+ 处。
**用户影响**：同样是"次要说明行"，图库用 `GatherFont.secondary`（10–11pt），全局图库/工作台用系统 `.callout`（13pt）——三个浏览器页面并排看，行高与字号明显不同；深色模式下的层级也会因为 token 与系统样式混用而不一致。
**修复建议**：批量替换为 `GatherFont.labelRegular/secondary`（`.callout`→`GatherFont.body`，`.footnote`→`GatherFont.secondary`），补一条 lint。

#### P2-23 · 三个浏览页"打开照片/工作区"的语义各不相同

**位置**：`.../Gallery/GalleryGrid.swift:133-139`（普通点击 = 原地开灯箱）、`.../Library/LibraryView+Content.swift:103-109`（点击 = 跨工作区跳转并在那边开灯箱）、`.../Dashboard/SessionRowView.swift:142-144`（点击行 = 只选中，必须点"进入"）。

**现象**：同一个"点一下卡片"的动作，在图库是"就地放大"，在全局图库是"离开当前页、跳到别的工作区"，在工作台是"什么都不发生"。全局图库的右键菜单里还并列着"打开照片 / 打开所在工作区"——说明作者知道这是两件事，但主点击行为没对齐。
**用户影响**：在全局图库里连点几张不同工作区的照片，会在导航栈里来回跳，回来时筛选与滚动状态都没了。
**修复建议**：全局图库主点击改为"就地预览（复用 LightboxView）"，"打开所在工作区"保留在右键/次要按钮；或至少让点击行为可预期地在卡片上标注入口图标。

---

## 亮点

1. **刷新/世代竞态防线做得扎实**：`fetchGeneration` + `fetchingGeneration` + `statusRequestID` + `facetsRequestID` + `latestRequestID` 五层守卫，"旧响应覆盖新筛选"这类曾经的 P0 已经很难复现（`+Load.swift:74-79`、`+Fetch.swift:13-25` 的注释把病因写得很清楚）。`refreshOnEvent` 用"重取到 targetCount 再整份替换"实现**就地更新、不闪 loading、不跳页**（`+Events.swift:29-32, 72-76`），方向是对的。
2. **分页去重是认真的**：哨兵 + 行内预取两个触发点共用 `loadMoreIfNeeded()` 的 `hasNextPage/fetchingGeneration` 早退（`+Scroll.swift:12-21`），链式拉页还有 D05 的"无进展即终止"，不会自旋 21 次。
3. **破坏性操作全部走确认 + `confirmed` 编译期门控**：图库批量（`GalleryView+Content.swift:30-50` 带影响条数）、工作区单删/批删（`DashboardView.swift:129-164`）、相册删除/合并/重新关联/恢复原片（`LibraryView+Load.swift:86-168` + `Confirmed<T>`）——确认文案里都写清了"影响多少、是否可恢复"，这是本轮最完整的一条线。
4. **灯箱滚轮捕获没有污染背景**：`ScrollWheelCatcher` 消费 wheel 事件且不转发（`LightboxView.swift:405-412`），加上 sheet 本身是模态的，背景网格不会被意外滚动——这条被点名的风险实际是安全的。
5. **挑片页那套"游标 + scrollTo + 列表末尾重试"是现成的正确范式**（`CullingGrid.swift:188-224`），图库只要照抄就能一次性解决 P1-3、P1-5、P2-1 三个问题。
6. **空态/失败态都有明确出口**：图库真空态给"导入文件夹/前往控制中心/刷新"三条，无结果给"清除筛选"，加载失败给"重试"；全局图库还区分了"库是空的"（导入）与"筛掉了"（清除筛选）两种语义（`LibraryView+Content.swift:70-97`）。
7. **窄窗页签条降级**：`< 620pt` 时 7 段页签变成 Menu，避开了 AppKit 约束循环（`GatherSessionPage.swift:112-123`）——这是"最小窗口"约束下做得最漂亮的一处。

---

## 未验证与风险

1. **方向键是否真的被 `onKeyPress` 收到**：`.onKeyPress` 挂在 `ScrollView` 上（`GalleryGrid.swift:50-59`），而 NSScrollView 通常先消费方向键做滚动。若 SwiftUI 的 key handler 在 AppKit 之后，则表现为"按方向键只滚动、游标不动"。需要实机验证（这也决定 P1-3 是"行为错误"还是"完全不生效"）。
2. **Esc 的跨层竞争（P2-8）**：sheet 与父视图同属一个 NSWindow，SwiftUI 的 key-equivalent 扫描范围没有文档保证。需要在灯箱打开且网格有选中时按 Esc，观察选择集是否被清。
3. **`ScrollWheelCatcher.hitTest` 恒返回 self**：这会让图像区域的 hover/光标形状失效（本页没有依赖，但 `mouseDown` 转发到 `nextResponder` 是否稳定触发 SwiftUI 的拖拽/双击手势，静态无法证明）。若转发失败，表现为"灯箱里拖不动、双击没反应"。
4. **宽度预算为估算**：P1-4/P1-6 的固有宽度是按中文字符数与常用间距手算的（标签字数 × 13pt + 间距），未在 860×560 实机测量；实际可能略宽/略窄 ±40pt，但"460pt 内容列放不下 680pt 内容"的量级结论不受影响。
5. **`List(selection:)` 里混入无 tag 行（summaryRow / jobsSection）**：未选中的无 tag 行在 macOS 上会吸收点击并清空选择集，可能造成"点了概览条，选中的工作区没了"。静态无法确认，建议实机点一下概览条看选择是否被清。
6. **`refreshOnEvent` 的整份替换对大库的开销**：已加载 4,000 张时，每个域事件都会重取 20 页；`.refreshOnDomainEvents(debounce: .zero)` 意味着写路径密集时可能背靠背触发。实际卡顿程度取决于本机 SQLite 与 IPC 往返（未测）。
7. **本次未覆盖**：`GatherMenuField`/`GatherStatCard`/`DashboardHeroCollage` 的内部实现细节；暗色/高对比度下的对比度实测（只看了 token 使用是否合规）；本地化 key 是否全部进 en.lproj（未做 parity 扫描）。
