# G0 网格挑片（Grid Cull）设计

> 状态：designing（2026-10-26）｜范围：G0｜基线：`docs/design/p0/README.md` D1–D10、`docs/design/p0/x0-contracts.md` §1.1
>
> **结论先行**：网格是挑片页的第 4 种布局（单图 / 2 图 / 4 图 / 网格），不新增页签；后端只增加 `sort` / `cursor` / `nextCursor`，不新增表；信息层级固定“四角 + 底部条 + 最多 2 枚 chip”；选择与键盘按 Lightroom / Capture One 习惯；20k 首屏 p95 < 800ms、单次键动作 p95 < 50ms（乐观更新）、200 张/页。

## 0. 目标与非目标

**目标**：让 3000–20000 张的工作区可以在一个全宽网格里完成首轮保留/淘汰、星级与色标，不需要在胶片条和查看器之间来回切换；网格与 1/2/4 图共用同一份 `CullingPage`、同一套决策 API、同一套撤销历史。

**非目标**：不改 7 页签；不做方格裁切模式（P1）；不做服务端“全选整个范围”；不在网格内做写回/同步；不自动运行 Triage；不做自绘沉浸式全屏。

## 1. 用户场景与主流程

1. 进入挑片 → 工具栏切“网格”（或按 `G`）→ 方向键移动、`0–5` 评级、`P/X/U` 决策、`⌥1–8` 色标 → 自动前进；接近底部自动加载下一页。
2. 想按拍摄时间重看 → 检查器“排序与网格”改排序 → 分页重置、保留选择与当前照片、滚回当前。
3. 选择一批（`⇧` 范围 / `⌘` 切换）→ `P` 批量保留 → 网格立即显示新状态，后台确认；失败回滚并显示错误。
4. 相似组挑片：切到“相似度分组”范围 → 组内强制导入序（契约限制）→ 组内用 `keepInGroupRejectRest` 或逐张决策。
5. T0 建议就绪后：卡片出现“建议保留/建议淘汰/待复核”角标；筛选“待复核”进入低置信度复核队列；应用建议走 T0 的 `applyTriage`，网格只消费 `CullingAsset.triage`。

失败路径：分页失败保留旧页 + 横幅重试；决策失败回滚乐观状态；排序切换作废在途请求并丢弃旧代数响应；离线照片可决策但写回会失败，网格只显示“离线”并在底部计数；未分析照片不显示质量角标。

## 2. 布局模式与全屏

| 模式 | 触发 | 显示区域 | 持久化 | 备注 |
|---|---|---|---|---|
| 单图 / 2 图 / 4 图 | 工具栏分段、紧凑菜单 | 查看器 + InfoBar + 胶片条 | `@SceneStorage("culling.layout")` | 保持现状 |
| 网格 | 同上、`G` 切换、`⌥⌘G`（可选菜单） | 只保留工具栏 + 网格 + 32pt 状态条 | 同上 | 隐藏胶片条/InfoBar；冲突改顶部横幅 |

`CullingLayout` 放在 `GatherUI/Culling/CullingLayout.swift`（UI 层类型，不进 Protocol）：

```swift
enum CullingLayout: String, CaseIterable, Identifiable {
    case single, compare2, compare4, grid
    var id: String { rawValue }
    var compareCount: Int? {
        switch self {
        case .single: return 1
        case .compare2: return 2
        case .compare4: return 4
        case .grid: return nil
        }
    }
}
```

- `CullingView` 用 `@SceneStorage("culling.layout") private var layoutRaw = CullingLayout.single.rawValue`；计算 `Binding<CullingLayout>` 传给 `CullingToolbar` / `CullingWorkbench`。
- `CullingToolbar` 现有“对比”Picker 改为“布局”Picker（4 段，宽约 200pt）；`ViewThatFits` 紧凑分支把布局放进“显示”菜单。按钮文案：单图 / 2 图 / 4 图 / 网格。
- 全屏：使用系统窗口全屏（绿色按钮 / 系统 `⌃⌘F`），G0 不自绘全屏窗口；网格在任意尺寸下重算行高，全屏只是可用宽高变大。`Esc` 优先清空多选，没有多选时不拦截，交给系统退出全屏。
- 布局切换不重新请求数据：`CullingWorkbench` 按 `layout` 分支渲染；`.grid` 渲染 `CullGridView`，其余渲染现有 `CullingWorkbenchViewer + CullingInfoBar + CullingFilmstrip`。网格使用当前 `page.assets`；切换后按 `currentPhotoId` 滚回当前。
- 网格下 `CullingConflictPanel` 不浮在右下（会压住卡片），改为顶部 `NativeBanner`：“N 个 XMP 冲突 · 切到单图处理”，点击切回单图并打开冲突面板。

## 3. 网格信息层级

### 3.1 固定槽位（不随密度漂移）

| 槽位 | 内容 | 显示条件 | 样式 |
|---|---|---|---|
| 左上 | 星级 `3★`（或 5 颗小星） | rating > 0 | 深色胶囊 + 白字（复用胶片条样式） |
| 右上 | 保留 ✓ / 淘汰 × 圆点 | pickState ≠ unreviewed | 9pt 圆点，`success` / `error` |
| 左边缘 | 色标 3pt 竖条 | colorLabel ≠ none | `CullingDisplayFormat.dot` 固定色值（C1 数据色） |
| 底部条 | 文件名 | 始终 | 一行截断 + 自下而上渐变遮罩 |
| 底部条右 | 最多 2 枚 chip | 见 3.2 | `PhotoOverlayChip` / 自定义胶囊 |

### 3.2 chip 优先级与去重

优先级从高到低：`冲突` > `Triage 建议` > `质量` > `相似组` > `人脸` > `RAW+JPEG`。只显示前 2 枚；其余信息进检查器与 `.help`。冲突 chip 为红色 `冲突`，替代质量 chip（同一张卡不同时出现两个警告色）。

- Triage：`建议保留`（success）/ `建议淘汰`（error）/ `待复核`（warning），带小图标；置信度与理由只在 `.help` 和检查器出现，卡面不放百分比，避免“假精确”。
- 质量：`Q82` 或 `⚠`（warnings 非空）；`failed` 显示 `!`，未分析不显示。
- 相似组：`组 3`（成员数）；无组不显示。
- 人脸：`2 人`；`faceBboxes.count == 0` 不显示。
- 变体：`RAW+JPEG`；`linkedVariantCount > 1` 才显示。

### 3.3 信息层级与密度

- `GridInfoLevel`：`minimal`（星级/色标/取舍/文件名）、`standard`（+ Triage/质量/组/人脸，默认）、`detailed`（+ 变体/同步状态/来源）。`@SceneStorage("culling.gridInfoLevel")`，暂不新增设置键（P1 再进设置）。
- `GridDensity`：S / M / L 对应目标行高 140 / 200 / 280pt；默认读设置 `grid_density`（`s/m/l`），`@SceneStorage("culling.gridDensity")` 覆盖。
- **不做裁切**：复用 `layoutJustifiedRows`（`Gallery/JustifiedLayout.swift`），单元格宽度 = 宽高比 × 行高，因此 `PhotoThumbnailView(contentMode: .fill)` 实际是等比展示，不裁构图。单张成行时限制 480×360（L 为 640×480），避免一张图铺满整行。缩略图请求尺寸：S=256，M/L=512；圆角 `GatherTheme.Radius.thumbnail`，间距 8pt。
- 选择态：2.5pt `GatherTheme.accent` 描边 + 右下角勾；当前照片额外 1pt 内描边，聚焦环用 `accent.opacity(0.65)`，与现有胶片条一致。所有颜色/字号只用 `GatherTheme` / `GatherFont` / `GatherMetrics`，不手写字面量。

## 4. 选择模型与键盘

### 4.1 选择语义（VM 统一）

| 手势 | 结果 |
|---|---|
| 单击卡片 | `current = id`；`selection = {id}`；`anchor = id` |
| `⌘` / `Ctrl` 单击 | 切换 `id` 的选择；`current = id`；`anchor = id` |
| `⇧` 单击 | `selection = [anchor…id]`（按 `page.assets` 顺序）；`current = id` |
| `⇧⌘` 单击 | 在现有选择上并入 `[anchor…id]` |
| `⌘A` | 全选**已加载**照片 |
| `⇧⌘A` | 清空选择；保留当前 |
| `⌥⌘A` | 反选已加载照片 |
| `Esc` | 清空多选；无多选时不拦截 |

新增 `selectionAnchorId: String?`；`selectSole` / `extendSelection(to:additive:)` / `selectAllLoaded` / `invertSelection` 均为纯 VM 方法（可单测）。批量操作始终作用于 `selectedPhotoIds`，为空时作用于当前照片（沿用 `commit` 现有语义）。**注意**：现有胶片条单击只改当前、不清选择；网格上线时统一改成“单击清空多选”，否则用户按 `P` 会误伤上一批——这是有意的行为修正，需在验收里覆盖胶片条。

### 4.2 键盘映射

| 键 | 动作 | 作用域 | 备注 |
|---|---|---|---|
| `0`–`5` | 评级 0–5 | 网格/查看器 | 多选时批量 |
| `P` / `Space` | 保留 | 网格/查看器 | 保持现有 Space 语义 |
| `X` | 淘汰 | 同上 | |
| `U` | 未处理 | 同上 | 不自动前进 |
| `⌥1`–`⌥8` | 红/橙/黄/绿/蓝/粉/紫/None | 同上 | 8 = 清除色标；与 `CaptureOneColorLabel` 的 8 个值一一对应 |
| `←` / `→` | 上一张 / 下一张 | 网格/查看器 | 到头触发 `loadMore` |
| `↑` / `↓` | 上一行 / 下一行 | 网格 | 按布局行首计算 |
| `⇧` + 方向键 | 扩展选择 | 网格 | 从 anchor 起 |
| `Enter` | 打开单图（loupe） | 网格 | `layout = .single` |
| `G` | 网格 ↔ 上次布局 | 挑片页 | LR 习惯 |
| `⌘A` / `⇧⌘A` / `⌥⌘A` | 全选已加载 / 清空 / 反选 | 网格 | |
| `⌘F` | 展开检查器并聚焦筛选 | 挑片页 | P0 无自由文本搜索 |
| `?` | 键盘帮助浮层 | 挑片页 | |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做 | 挑片页 | 现有 focused-scope 命令 |

实现：新增 `CullingKeyInput { characters: String; modifiers: EventModifiers }` 与 `CullingKeyMap.command(for:) -> CullingKeyCommand?` 纯函数（单测）；网格容器 `.focusable()` + `.onKeyPress` 调用；卡片为 `.buttonStyle(.plain)` + `.focusable(false)`，避免 Space 同时触发按钮和查看器两套逻辑。注意：`⌥1–8` 用 `press.key` 匹配（Option 会改变 `characters`）；`⌘A/⇧⌘A/⌥⌘A` 走 `GatherAppCommands` 的 focused-scope 命令，`onKeyPress` 仅兜底，避免被系统 Edit 菜单截获。方向键移动只改当前与选择，不滚动整页；当前变化后 `ScrollViewReader.scrollTo(id, anchor: .center)`（Reduce Motion 时无动画）。

### 4.3 自动前进、焦点与 VoiceOver

- 自动前进：仅单张决策触发，目标 = 当前可见序的下一个；到已加载末尾且 `hasMore` 时先 `loadMore` 再前进；批量决策不前进（沿用现有 `batchUpdate`）；`U` 不前进。
- 焦点：`@FocusState<String?>` 只用于“键盘焦点在网格容器”这一层；卡片本身不抢焦点。Tab 走工具栏/检查器；网格内用方向键。
- VoiceOver：卡片 `.accessibilityElement(children: .ignore)`，label 拼接“文件名、3 星、保留、建议保留、质量 82、相似组 3 张、2 张人脸、RAW+JPEG、离线”；value 为“已选中/当前”；选中加 `.isSelected`；容器 label“网格，已加载 N 张，共 M 张，已选 K 张”；提供 `.accessibilityAction`“保留/淘汰/未处理/清除选择”。

## 5. 筛选、排序与分页游标

### 5.1 控件位置

- **检查器是唯一真相源**：`CullingInspector` 增加“排序与网格”分区——排序 Picker、密度 Segmented、信息层级 Picker。筛选区沿用 `CullingFilterControls`，T0 增加“Triage 建议”筛选。
- **工具栏不复制排序 Picker**：网格底部 32pt 状态条右侧显示“排序：拍摄时间 ↓ · 筛选 2 项”，点击展开检查器并聚焦对应分区；避免两处状态。
- 排序在“相似度分组”范围禁用（灰 + help“相似组内按导入顺序”）；VM 的 `effectiveSort(for:)` 在该 scope 强制 `.importOrder`，不把非法组合发给服务端（服务端仍兜底报 `CULLING_CURSOR_INVALID`）。

### 5.2 排序切换与状态保持

`setSort(_:)` 的固定流程：`loadGeneration &+= 1` → 记录 `anchor/current/selection` → 以 `sort` + `cursor nil` 请求首页（保留旧页直到新页返回，避免白屏）→ 替换 `page` → `selection.formIntersection(newIds)` → `currentPhotoId` 仍在则 `scrollTo`，否则第一条并滚顶 → `summary` 异步刷新。**筛选变化同样重置分页**：`setFilterState` / `resetFilters` / `setScope` / `selectSimilarityGroup` 均以 `cursor nil` 重新取首页，旧代数响应丢弃；不把筛选指纹塞进游标（契约 §1.1）。

所有重置式取页（排序、筛选/范围、质量分析完成、`refreshSilently`、领域刷新）都必须携带当前有效 `sort`；`refreshSilently` 的 `limit` 改用 `pageLimit` 而不是硬编码 500。否则任一后台刷新都会把网格打回导入序。

排序值持久化：`SettingsAPI.get(SettingsKey("grid_default_sort"))` 作为首次默认（`CullingViewModel` 注入 `SettingsAPI`，在 `load()` 首次执行前读取，非法值回落 `.importOrder`；`SettingsKey` 初始化会抛错，读取处 `try?` 兜底）；`@SceneStorage("culling.sort")` 做窗口级覆盖，用户改排序时写回 SceneStorage。密度同理读 `SettingsKey("grid_density")`。

### 5.3 协议类型（可直接落地）

```swift
public enum CullingSort: String, Codable, CaseIterable, Equatable, Sendable {
    case importOrder = "import"
    case captureDesc = "capture_desc"
    case captureAsc = "capture_asc"
    case ratingDesc = "rating_desc"
    case triageConfidenceAsc = "triage_confidence_asc"
}

public struct CullingPageCursor: Codable, Equatable, Sendable {
    public var sort: CullingSort
    public var dateKey: String?
    public var numberKey: Double?
    public var rowId: Int64
}

public struct CullingPageQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let scope: CullingScope
    public let filters: CullingFilters?
    public let groupId: String?
    public let sort: CullingSort?
    public let afterRowId: Int64?
    public let cursor: CullingPageCursor?
    public let limit: Int
}

public struct CullingPage: Codable, Equatable, Sendable {
    public var assets: [CullingAsset]
    public var nextRowId: Int?
    public var nextCursor: CullingPageCursor?
    public var total: Int
    public var hasMore: Bool { nextCursor != nil || nextRowId != nil }
}
```

校验（`CullingPageQuery.init`）：`sort == nil` 视为 `.importOrder`；**import 序只接受 `afterRowId`（>=1），非 import 序只接受 `cursor`**；两者同时非空或与排序错配 → `CULLING_CURSOR_INVALID`。`cursor.sort` 必须等于有效排序、`rowId >= 1`；capture 仅 `dateKey` 非空（空串合法 = 无拍摄时间），rating 与 triage 仅 `numberKey` 非空；`sort != .importOrder && scope == .similarityGroup` → 同码。两者的自定义 `init(from:)` / `encode(to:)` 的 `CodingKeys` 同步增加 `sort` / `cursor` / `nextCursor`；`nextCursor` 为 nil 时编码 null（与 `nextRowId` 同规）。`CullingPage` 保留 `nextRowId` 一版，读方优先 `nextCursor`（胶片条、`advanceCurrent`、`loadMore` 全部改 `hasMore`）。**本地重建页面的所有路径**（`applyDecisionStates`、`loadPage` 续页、`refreshSilently`）必须透传 `nextCursor`；`CullingPage(assets:nextRowId:total:)` 便捷初始化器不得静默置 nil，否则一次决策就会丢掉“还有下一页”。

### 5.4 SQL（Persistence：`CullingAssetPageQuery.pageSorted`）

排序键归一严格按契约：拍摄时间 `COALESCE(c.date_taken, '')`、评级 `COALESCE(c.rating, 0)`、Triage `COALESCE(t.confidence, 2.0)`（2.0 是无建议哨兵，ASC 排最后）；**并列一律 `first_rowid ASC` 决胜**。`date_taken` 的字符串序依赖索引器写入格式；若存在混合格式，需在数据契约统一，不能靠 SQL 猜测时间。base 查询（capture/rating）：

```sql
WITH preferred AS (
  SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
         p.rowid AS first_rowid,
         COALESCE(c.date_taken, '') AS sort_date,
         COALESCE(c.rating, 0) AS sort_rating
  FROM photos p
  LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
  LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
  WHERE p.session_id = ?
    AND <preferredRowPredicate>
    AND <filterPredicate>
)
SELECT gid, first_rowid, sort_date, sort_rating
FROM preferred
WHERE <cursorPredicate>
ORDER BY <sortExpr> <ASC|DESC>, first_rowid ASC
LIMIT ?;
```

- `sortExpr`：`.captureAsc/.captureDesc` 用 `sort_date`；`.ratingDesc` 用 `sort_rating`。
- `cursorPredicate`（`:k` 重复两次）：
  - asc：`(sort_date > :k OR (sort_date = :k AND first_rowid > :r))`
  - desc：`(sort_date < :k OR (sort_date = :k AND first_rowid > :r))`
  - rating desc 同形，替换列。
- triage 排序时增加 `LEFT JOIN triage_suggestions t ON t.photo_id = p.id` 与 `COALESCE(t.confidence, 2.0) AS sort_confidence`（无建议排最后），`ORDER BY sort_confidence ASC, first_rowid ASC`，游标同上（`>`）。Triage 未启用时不 JOIN、不暴露该排序。
- `filterPredicate` 从现有 `filteredWhere` 抽出（去掉 session/preferred），复用 `unreviewedOnly`、decisions、ratings、labels、conflict、quality 谓词；`.all` 传空谓词。`similarityGroup` 不走本查询。
- 下一页：query 返回的 `rows.count == limit` 时构造 `nextCursor`（按 sort 只填对应键：capture → `dateKey = last sort_date`；rating/triage → `numberKey = last sort_rating/confidence`；`rowId = last first_rowid`），不满一页返回 nil。`CullingPage.nextRowId` 在 import 序继续由旧查询返回。
- `loadAssetRows` 必须按排序后的 `gid` 顺序回填：先按 gid 分组取全部变体行（`ORDER BY p.rowid`），再 `groups.flatMap { rowsByGid[$0.gid] ?? [] }`，否则页面仍是 rowid 序。
- 计数复用 `countFiltered` / `countAssetsBySession`，与排序无关；`hasMore` 由游标判断。

### 5.5 DDL / 索引

G0 **不新增表、不改既有表**（遵守 D2）。排序使用既有 `idx_photos_asset_group`、`idx_metadata_cache_session_date/rating`；Triage 排序依赖 T0 的 `triage_suggestions(session_id, verdict, confidence)` 索引。若 `EXPLAIN QUERY PLAN` 显示临时 B-tree，先记录基线，不在 G0 擅自加索引；需要时由 X0/T0 评审统一进 V3 或后续迁移。

## 6. 分页、预取与性能

- 网格 `pageLimit = 200`；查看器/胶片条保持 500（避免现有行为回归）。`CullingViewModel.pageLimit` 由布局设置，`loadPage` / `refreshSilently` 读取；切换布局不改已加载页，只影响下一次取页。
- 哨兵：距末尾 20 项（约 1–2 行）触发 `loadMore`；`isLoading` + `loadGeneration` 双闸；失败保留已加载页，底部显示“加载失败 · 重试”，不自动重试。
- 缩略图预取：新增 `ThumbnailPreheat.warm(paths:size:limit:)`（`GatherUI/Support`），对当前行之后 2 行、≤24 张调用现有 `PhotoThumbnailDecoder.decodeAsync`（写磁盘/内存缓存，不新建解码器）；去抖 150ms，排序/筛选/布局变化取消。可见卡片仍由 `PhotoThumbnailView` 自取。
- 预算（20k 工作区）：首屏 p95 < 800ms（page + summary + 首行缩略图，warm disk cache）；键动作输入到视觉反馈 p95 < 50ms（乐观更新）；`loadMore` p95 < 250ms；排序切换 p95 < 400ms；滚动无可感知掉帧；网格增量内存 < 300MB。冷缓存首屏单独记录，不作为发布门。

## 7. 状态矩阵

| 状态 | 触发 | UI | 恢复 |
|---|---|---|---|
| 空会话 | 未打开工作区 | 现有 `emptyGuide` | 去工作台 |
| 空范围 | 筛选/组无结果 | 工具栏 + `ContentUnavailableView`“当前范围没有照片” + “显示全部照片” | 重置筛选 |
| 首次加载 | `page == nil && !error` | 8 张 `surfaceMuted` 骨架卡 + 进度 | 自动 |
| 加载更多 | `isLoading && page != nil` | 底部行内 `ProgressView`，不清空网格 | 自动 |
| 分页失败 | 错误 | 保留旧页 + 顶部 `NativeBanner` + 底部“重试” | 手动 |
| 未索引/刚导入 | `page.total == 0`、无筛选、无错误 | 空态文案“没有照片。若刚导入，索引可能仍在进行。”+“打开控制中心”（`@Environment(\.navigator)`） | 去控制中心 |
| 离线 | `photo.status == "missing"` | 卡片“离线”chip；状态条显示离线数；允许决策 | 重连卷 |
| 未分析 | `quality == nil` | 无质量 chip；Triage 筛选“未分析”可见 | 运行质量分析 |
| 质量失败 | `quality.status == .failed` | `!` chip，`.help` 显示错误码漏斗文案 | 重试分析 |
| 冲突 | `viewModel.conflicts` 非空 | 顶部横幅 + 计数；网格不浮冲突面板 | 切单图裁决 |
| RAW/JPEG | 逻辑资产多行 | 一张卡；`RAW+JPEG` chip；**P0 不展开变体** | P1 |

## 8. 视图层级、状态归属与调用时序

### 8.1 关键 UI / VM 签名

```swift
enum GridDensity: String, CaseIterable { case s, m, l }   // 行高 140 / 200 / 280
enum GridInfoLevel: String, CaseIterable { case minimal, standard, detailed }

struct CullingKeyInput: Equatable {
    var characters: String
    var modifiers: EventModifiers
}

enum CullingKeyCommand: Equatable {
    case rating(Int), pick(PickState), label(CaptureOneColorLabel?)
    case move(Int), moveRow(Int), openLoupe, toggleGrid
    case selectAll, clearSelection, invertSelection, focusFilters, help
}

enum CullingKeyMap {
    static func command(for input: CullingKeyInput) -> CullingKeyCommand?
}

struct CullGridView: View {
    let viewModel: CullingViewModel
    @Binding var density: GridDensity
    @Binding var infoLevel: GridInfoLevel
}

struct CullGridCell: View {
    let asset: CullingAsset
    let isSelected: Bool
    let isCurrent: Bool
    let density: GridDensity
    let infoLevel: GridInfoLevel
}

extension CullingViewModel {
    var hasMore: Bool { page?.hasMore ?? false }
    func setSort(_ sort: CullingSort) async
    func setPageLimit(_ limit: Int)
    func selectSole(_ photoId: String)
    func extendSelection(to photoId: String, additive: Bool)
    func selectAllLoaded()
    func invertSelection()
    func moveCurrent(by delta: Int, extendSelection: Bool)
    func advanceAfterDecision(from photoId: String) async
    func applyOptimistic(_ patch: CullingUpdatePatch, to ids: Set<String>) -> [String: CullingStateSnapshot]
    func restore(_ snapshots: [String: CullingStateSnapshot])
}
```

```text
CullingView (@SceneStorage layout/density/infoLevel, showHelp)
├─ GatherSessionPage
│  └─ VStack
│     ├─ NativeBanner(error / notice / 冲突)
│     ├─ CullingToolbar(layout, scope, autoAdvance, quality)
│     └─ layout == .grid ? CullGridView : (Viewer + InfoBar + Filmstrip)
└─ .inspector CullingInspector(当前照片 / 筛选 / 排序与网格 / 相似组 / 选择)
```

| 状态 | 归属 | 持久化 |
|---|---|---|
| layout / density / infoLevel / showInspector | View | `@SceneStorage` |
| sort / pageLimit / filterState / scope | `CullingViewModel` | sort 存 `@SceneStorage("culling.sort")`；默认读 settings |
| page / nextCursor / selection / anchor / current | `CullingViewModel` | 会话内（workspace 复用） |
| 布局行缓存 / 焦点 / hover | `CullGridView`（引用盒子 + `@FocusState`） | 无 |
| 键盘帮助 / 冲突选择 / 破坏性确认 | View | 无 |

**CullingAPI 时序**：进入 → `page(sort, cursor nil, limit)` → 渲染首屏 → `summary` → 后台并行 `groups/syncStatus/history/conflicts`（不阻塞首屏）；排序/筛选 → 仅 `page` + `summary`；加载更多 → 仅 `page(nextCursor, limit)`；单张/批量决策 → 本地乐观 `applyDecisionStates` → `update` / `batchUpdate` → 应用服务端 states → 异步 `summary`（**不整页刷新**，避免滚动跳动）→ 失败回滚 + 横幅；外部域变更 → 网格显示“内容已更新 · 刷新”横幅（手动刷新），查看器保持现有静默刷新；实现为 `CullingViewModel.refreshPolicy: .auto/.manual`（布局写入）与 `pendingExternalRefresh`，网格下 `handleDomainChange` 只置位、不自动 reload；布局切换 → 不请求。

## 9. 测试计划

| 层 | 文件 | 用例 |
|---|---|---|
| Protocol | `GatherCoreTests/Protocol/CullingContractTests.swift` | sort/cursor 编解码、非法组合、`hasMore`、旧 `nextRowId` 兼容 |
| Persistence | `GatherCoreTests/Queries/CullingAssetPageQueryTests.swift` + 新增 `...SortTests.swift` | 20 页无重漏；capture asc/desc、rating desc、triage asc；空日期/并列/RAW+JPEG 组完整；`EXPLAIN` 基线 |
| Application | `GatherCoreTests/Services/CullingServiceTests.swift` | sort 透传、similarity 非 import 拒绝、`nextCursor` 回填、重排后资产顺序 |
| App VM | `GatherAppTests/CullingViewModelAPITests.swift` + 新增 `CullingGridSelectionTests.swift` | 单选/⌘/⇧/全选/反选/范围/自动前进/加载到边界 |
| App View | 新增 `CullingGridLayoutTests.swift`、`CullingKeyboardMapTests.swift`、`CullingGridStateTests.swift` | 行高缓存、键盘纯函数、空/错/离线/冲突态；NSHostingView 860×560 不触发约束循环 |
| 性能 | 新增 `CullingGridPerformanceTests.swift` | 20k 首屏/键动作/排序/滚动预算；signpost |
| 文案 | `en.lproj` / `zh-Hans` | 新增约 40 键；L10n 覆盖测试 |

## 10. 任务拆解（对齐 G0-1…G0-9，合计 17 PD）

| ID | 任务 | 文件 | PD | 验收 |
|---|---|---|---:|---|
| G0-1 | 交互规格、键盘表、文案清单、评审 | `docs/design/p0/g0-grid-cull.md` | 1 | 设计评审通过；与 D1–D10 一致 |
| G0-2 | 契约：`CullingSort`/`CullingPageCursor`/query 校验/`nextCursor` | `Protocol/Culling.swift`、`API/Inputs/CullingInputs.swift`、`CullingContractTests.swift` | 2 | 非法组合报 `CULLING_CURSOR_INVALID`；旧调用不破坏 |
| G0-3 | 查询：`pageSorted`、排序键归一、游标谓词、按组重排、计数 | `CullingAssetPageQuery.swift`、`Ports/CullingRepository.swift`、`CullingAssetPageQueryTests.swift` | 4 | 20 页随机无重漏；并列稳定；资产组完整 |
| G0-4 | 服务/VM：sort 透传、`nextCursor`/`hasMore`、`pageLimit`、SettingsAPI 读默认、筛选重置分页 | `CullingService+Paging.swift`、`CullingViewModel.swift`、`+Load.swift`、`CullingFilmstrip.swift`、`SessionWorkspaceFactory.swift` | 1.5 | 排序/筛选/分页行为与契约一致；默认值生效；无 `nextRowId` 直读残留 |
| G0-5 | 网格视图：行布局、卡片、chip 优先级、密度/信息层级 | 新增 `CullingGrid.swift`、`CullingGridCell.swift`、`CullingGridBadges.swift`、`CullingLayout.swift`、`ThumbnailPreheat.swift`；改 `CullingWorkbench.swift` | 3.5 | 20k 首屏预算；信息不糊；无裁切 |
| G0-6 | 键盘/选择/自动前进/乐观更新 | 新增 `CullingGridKeyboard.swift`；改 `CullingViewModel+Actions.swift`、`CullingFilmstrip.swift`、`CullingGridSelectionTests.swift` | 2 | 全流程纯键盘；批量/范围/回滚正确；胶片条单击语义同步；50ms 反馈 |
| G0-7 | 布局持久化、全屏适配、检查器排序/密度分区、状态条 | `CullingView.swift`、`CullingToolbar.swift`、`CullingInspector.swift`、`CullingFilterControls.swift` | 1 | 切页/重启保持；860 宽不溢出 |
| G0-8 | 测试/性能：20k 夹具、分页、布局、预算记录 | 新增 `CullingGridPerformanceTests.swift`、`CullingGridStateTests.swift`；`docs` 基线 | 1.5 | 预算全部达标并记录 |
| G0-9 | 帮助浮层、菜单/命令接入、中英文案 | 新增 `CullingGridHelp.swift`；改 `GatherAppCommands.swift`；`en.lproj`/`zh-Hans` | 0.5 | `?` 可发现；L10n 测试绿 |

> 估算含测试、±30%；不含 T0 的 `triage` 字段与 V3 迁移（T0-2/3/4 负责）。

## 11. 未决问题（推荐选项）

| # | 问题 | 推荐 | 理由 |
|---|---|---|---|
| 1 | 相似组内用户改排序怎么办？ | UI 禁用非 import 排序 + help；VM 强制 import | 契约只允许 `.all/.filtered`；避免报错打断 |
| 2 | `⌘A` 全选“已加载”还是“整个范围”？ | 已加载；状态条明确“已加载 X/共 Y” | 批量 API 上限 10000；全范围需新选择模型（P1） |
| 3 | 单击是否清空多选？ | 是；胶片条同步改 | 否则 `P` 会误伤上一批（现有隐患） |
| 4 | 网格分页 200 还是沿用 500？ | 布局作用域：网格 200，查看器/胶片条 500 | 首屏预算 vs 现有行为回归最小 |
| 5 | 是否做自绘沉浸全屏？ | P0 不做，使用系统全屏 | 减少焦点/快捷键冲突；网格自适应已够 |
| 6 | `grid_default_sort` 如何读？ | VM 注入 `SettingsAPI`，首次 load 前读；SceneStorage 覆盖 | 保持设置单一来源；非法值回落 |
| 7 | Triage 排序是否依赖 V3 表？ | 仅启用 Triage 时 JOIN；未启用不 JOIN、不暴露选项 | G0 可独立落地；避免旧库查询失败 |
| 8 | 游标 rawValue 序列化 | 固定 snake_case（与 settings 一致），写进契约 | 跨语言/日志可读；避免默认枚举名漂移 |
| 9 | `date_taken` 混合格式时字典序 ≠ 时间序 | 数据契约统一为可排序格式；G0 不做解析 | 避免 SQL 猜时间格式 |

## 12. 与 x0-contracts 的冲突 / 口径差异

§1.1 已采纳 typed cursor、`nextCursor`、`CULLING_CURSOR_INVALID`、`triageConfidenceAsc`，与本文一致，**无未解契约冲突**。仍需在评审时回写的 3 处口径：

| # | x0-contracts | 本文 | 建议 |
|---|---|---|---|
| 1 | 只写 `CullingSort` 枚举名，未写 rawValue | 固定 `import` / `capture_desc` / `capture_asc` / `rating_desc` / `triage_confidence_asc` | 补进 §1.1，避免 Swift/JSON 默认命名漂移 |
| 2 | P0 计划写“200/页” | 网格 200，查看器/胶片条保留 500 | 在计划中改为“网格 200；其余布局沿用 500” |
| 3 | 未写 `nextRowId` 的读方迁移范围 | 胶片条、`advanceCurrent`、`loadMore` 全部改用 `hasMore`，优先 `nextCursor` | 在 G0 验收里加“无 `nextRowId` 直读残留”检查 |

> 另：本文遵循“筛选变化由 UI 重置分页”，不把筛选指纹塞进游标，与 §1.1 一致。
