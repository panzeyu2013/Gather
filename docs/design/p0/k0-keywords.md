# K0 通用关键词（批量加/删 + 预览 + 写回）详细设计

> 状态：draft（2026-10-26）｜负责人：K0｜依赖：[x0-contracts.md](x0-contracts.md)、[README.md](README.md)

## 结论先行

1. 主流程固定为：**选中 → delta 编辑 → 只读预览 → 一次确认 → delta 入队 → 执行器写盘 → 状态/重试**；单请求上限 500 张。
2. **不走 replace 全量覆盖**。新增 `keywords_mode=delta`：执行器在文件锁内读盘，按 `盘上 ∪ 新增 − 删除` 落盘；预览与写入共用同一 `KeywordPlanner`。
3. `metadata.preview` **只读、无副作用**；`metadata.applyKeywords` 返回 `WritebackResult + MetadataSyncSummary`；`retryKeywordWriteback` 重放 **module=metadata** 的 pending/failed（不限关键词）。
4. 自动补全扩展 `PhotoAPI.suggestions`（keyword + camera_make），会话级缓存；不新增查询协议。
5. 手动词**不写** `metadata_keyword_origins`（CHECK 无 manual，D2 不改表）；生成词只读保护，审计依赖 delivery 备份。

## 0. 现状与约束（代码依据）

| 现状 | 位置 | 对 K0 的影响 |
|---|---|---|
| `applyMetadata` 以 `.replace` 入队关键词、source=`.manual`，只与 **cache** 合并 | `GatherApplication/Services/MetadataService.swift:547-589` | 直接复用 `set/batchSet` 会覆盖外部词；K0 需独立 delta 路径 |
| `batchSet` 按侧车分组、每会话只 flush 一次 | 同文件 `:614-703` | 500 张按 XMP 分组的批处理可复用 |
| `WritebackService.preview` 只支持 `keywordAdditions`，且会写 pending 交付行 | `GatherDelivery/Writeback/WritebackService.swift:131-239` | 不能直接用于“只读预览 + 删除” |
| 执行器已有 `merge`/`replace` 两种 `keywords_mode`，在文件锁内读盘合并 | `GatherDelivery/Writeback/WritebackService+Execute.swift:379-402` | 增加 `delta` 分支即可保证并发安全 |
| `suggest` 只查 `camera_make`、忽略 sessionId、≥2 字符、limit 5 | `GatherPersistence/Database/Queries/PhotoFilterQuery.swift:229-240` | 需扩展关键词建议并修正会话过滤 |
| `metadata_keyword_origins.source` 的 CHECK 只有 face-keyword/culling/similarity/template | `GatherPersistence/Database/Schema/SchemaV1+DDLDomain.swift` | 不能写 manual 来源；D2 不允许重建表 |
| 挑片检查器已有分区式面板；`CullingAsset.keywords` 来自 `photo_metadata_cache` | `GatherUI/Culling/CullingInspector.swift`、`CullingService+Queries.swift:359` | 新面板可复用现有分区与缓存投影 |

## 1. 目标 / 非目标

**目标（可验收）**：500 张批量加/删关键词；预览与实际写盘同源；face/similarity/culling 生成词不丢；外部修改可见、失败可重试、写入有备份可恢复。  
**非目标**：关键词库/层级树、同义词管理、IPTC、自动关键词、跨工作区关键词批量管理（均留 P1）。

**典型场景**：一场 600 张的婚礼选片，摄影师先挑出 120 张，需要给其中 40 张加“仪式/父母”，给 12 张加“新人特写”，同时删掉误加的“彩排”。这些词必须写进每张照片旁边的 XMP，回到 Capture One 执行“加载元数据”后仍能看到；任何一张写失败都要能定位、重试，且不能把人工加的词与其他人脸/相似组写入的词混在一起丢掉。

## 2. 主流程

| 步 | 触发 | 调用 | 失败路径 |
|---|---|---|---|
| 1 | 选中照片/输入词 | 本地草稿（`KeywordEditorModel`） | 无选中 → 禁用 |
| 2 | 点“预览写回” | `MetadataAPI.preview` | 读 XMP 失败 → 该项标 error，不阻塞其它项 |
| 3 | 预览 sheet | 展示新建/更新/冲突/无变化 + before→after | 无变化 → 确认按钮禁用 |
| 4 | 一次确认 | `Confirmed<MetadataKeywordApplyInput>` | 未确认 → 类型层不可达 |
| 5 | 写回 | `MetadataAPI.applyKeywords` | 部分失败 → 返回 failedItems + status |
| 6 | 结果条 | `WritebackReportCard` + 重试/冲突入口 | 重试 → `retryKeywordWriteback` |

**一次确认**：预览 sheet 是唯一的确认入口，`Confirmed<MetadataKeywordApplyInput>` 只能从“确认写入”分支构造；取消不建任何交付项，也不改 cache。  
**500 张**：API 上限 500；`CullingViewModel` 单页 `limit=500`，且 `loadedPhotoIds` 跨页 `formUnion`、选择集 `formIntersection(loadedPhotoIds)`，因此**连续加载多页后选 500 张是可行路径**；P0 验收直接按 500（加载 1 页即可选满，跨页加载验证累积）。超过 500 时 UI 直接拒绝并提示分批（P1 再自动分块）。  
**失败路径**：无选中/无变更 → 按钮禁用；离线照片 → 跳过并在结果条列出；单侧车读失败 → 该项 `errorMessage`，其它项继续；写盘失败 → `failedItems` 可见、可重试；预览后外部改词 → `externalChanged` 提示，写入仍按最新盘上内容执行；连点“确认” → `isApplying` 门控，避免重复 revision。

### 2.1 状态机

```text
idle → editing(dirty) → previewing → previewed → applying → applied | partial | failed
  ↑                         │                                   │
  └──── 改选择（dirty 时确认放弃） └──────── retry ───────────────┘
```

边界：空选择/无变更禁用；离线照片跳过并计入 failed；预览后外部改词 → `externalChanged` 提示但仍可写（delta 安全）；写盘期间切换页面 → 后台继续，返回后刷新结果。

## 3. 合并语义（纯函数）

| 规则 | 行为 | 示例 |
|---|---|---|
| 归一化 | NFC + trim + 内部空白折叠为单空格；长度 ≤256；拒绝 NUL/控制字符 | `"  Bride  Smith "` → `Bride Smith` |
| 去重 | 大小写不敏感（`fold` = case+width insensitive），保留**首次出现的拼写与顺序** | `Bride, bride, BRIDE` → `Bride` |
| 新增 | `盘上 ∪ 新增`，盘上顺序在前 | 已有 `A`，加 `B` → `A,B` |
| 删除 | 大小写不敏感删除；只删指定词 | 删 `bride` 会删 `Bride` |
| 生成词 | face/similarity/culling/template 拥有的词：**阻止删除**，新增时视为已存在 | 试图删人脸词 → 提示先解绑 |
| 层级词 | 以竖线分隔的层级词（如 婚礼→仪式）作为**一个**关键词字符串存储；不自动展开父级；仅 dc:subject 平铺写入 | 婚礼→仪式 原样写盘 |
| 同义词 | P0 不合并、不展开；`新娘` 与 `Bride` 是两个词 | P1 再评估 |
| replace | UI 不使用；`metadata.set/batchSet` 保留给“覆盖全部”场景（P1，需 fingerprint 守卫） | — |
| 空结果 | 归一化后无变化 → no-op，不建交付项 | 只加已存在的词 |

**为什么按“大小写不敏感”而不是转小写**：XMP 是给别人看的交付物，`Bride` 比 `bride` 更常见；只用于比较的 `fold` 不改变落盘拼写。中文/日文没有大小写，fold 只影响空白与宽度。  
**为什么层级词不展开**：现有 `SidecarXMPProvider` 只写 `dc:subject`（`SidecarXMPProvider+Patching.swift:68-70`），不写 `lr:hierarchicalSubject`；自动补父级会造成“看起来有层级、换软件就丢”的错觉。P0 把 `A|B` 当一个词原样写，P1 再评估是否补 `lr:hierarchicalSubject`。  
**为什么同义词不合并**：XMP 没有可移植的同义字段；本地同义词表要么进 schema（违反 D2），要么进设置（无结构）。P0 明确“不猜同义词”，避免把“新娘”和“Bride”误当同一个交付标签。  
**为什么阻止删除生成词**：face/similarity 的写回是“只增”语义；用户在这里删掉，下一次写回会再补回来，形成“删了又回来”的信任问题。正确路径是去人物页解绑/清理，而不是在关键词面板硬删。  
**并发不丢词的关键**：写入不是“把预览快照覆盖回去”，而是 delta。执行器在 `XMPFileLock` 内重新读盘：`(disk ∪ added) − removed`。因此外部新增词不会被覆盖；外部删除我们新增的词会被补回（可解释）。预览只负责展示与提示 `externalChanged`。

## 4. 交互与视觉

### 4.1 位置与布局

放在**挑片页右侧检查器**，位于“当前照片”之后、“筛选”之前；Grid Cull 复用同一面板。画廊（Gallery）不改：`GalleryPhotoData` 无 keywords 字段，`GalleryViewModel` 明确不新增评分/色标 API（见 `GalleryInspector.swift` 注释），P0 不扩。

```text
┌ 关键词 ──────────────────────────────┐
│ [🔍 添加关键词…                 ⌘K]  │
│ (新娘 ×) (仪式 ×) (culling:keep 🔒)   │
│ 已选 12 张 · 新增 2 · 移除 1         │
│ [预览写回]  [确认写入]                │
│ 已写入 12 · 失败 0 · 跳过 0 [重试元数据] │
└──────────────────────────────────────┘
```

多选时 chips 显示并集；只部分照片拥有的词加“—”前缀，点 × 表示从所有选中照片移除。生成词带锁图标，点 × 弹说明，不进入 delta。

### 4.2 预览 sheet

| 区块 | 内容 |
|---|---|
| 摘要 | `12 张 / 8 个 XMP · 新建 2 · 更新 6 · 外部修改 1` |
| 差异 | 每个 XMP 一行：`before` chips → `after` chips；新增绿、删除红 |
| 冲突 | `externalChanged` 行标“外部已修改，写入将基于最新盘上内容” |
| 动作 | 取消 / 确认写入（破坏性，仅一次确认） |

### 4.3 键盘、焦点、a11y

| 键 | 行为 |
|---|---|
| ⌘K | 聚焦关键词输入框 |
| ↑/↓ | 选择补全项 |
| Enter | 加入当前补全/输入词 |
| ⌫（空输入） | 移除最后一个 chip |
| ⌘⏎ | 打开预览（有变更时） |
| Esc | 关闭补全/预览 |

焦点顺序：照片 → 关键词输入 → chips → 预览 → 确认。a11y：chip 为按钮，label “移除关键词 %@”；输入框有 label；结果条为 live region；锁图标有 “由%@写入，需先解绑” 的 accessibilityValue。

### 4.4 文案（中/英同 PR）

| 中文（源 key） | English |
|---|---|
| 关键词 | Keywords |
| 添加关键词… | Add keywords… |
| 已选 %lld 张 | %lld selected |
| 新增 %lld · 移除 %lld | %lld added · %lld removed |
| 预览写回 | Preview writeback |
| 确认写入 | Write to XMP |
| 由人脸写入 | Added by face keywords |
| 由相似组写入 | Added by similar groups |
| 由挑片写入 | Added by culling |
| 先在人物页解绑 | Unbind it on the People page first |
| 外部修改 | Changed outside Gather |
| 新建 XMP | Create XMP |
| 写入完成 | Write complete |
| 部分失败，可重试 | Partly failed; retry available |
| 重试元数据写回 | Retry metadata writeback |

## 5. 数据 / API / SQL

### 5.1 新类型（可直接落地）

```swift
// GatherProtocol/Protocol/KeywordEdit.swift（新文件；纯值 + 纯函数，Application/Delivery 共用）
public enum KeywordNormalizer {
    public static func normalize(_ raw: String) -> String?   // NFC/trim/折叠/长度/NUL
    public static func fold(_ value: String) -> String       // 大小写+宽度不敏感
    public static func unique(_ values: [String]) -> [String]
}

public struct KeywordRemovalBlock: Equatable, Sendable {
    public var keyword: String
    public var sources: [MetadataMutationSource]
}

public struct KeywordPlan: Equatable, Sendable {
    public var before: [String]
    public var after: [String]
    public var added: [String]
    public var removed: [String]
    public var blocked: [KeywordRemovalBlock]
    public var changed: Bool { before != after }
}

public enum KeywordPlanner {
    public static func plan(
        existing: [String], added: [String], removed: [String],
        owned: [String: Set<MetadataMutationSource>] // key = fold(keyword)
    ) -> KeywordPlan
    public static func apply(existing: [String], added: [String], removed: [String]) -> [String]
}
```

```swift
// GatherProtocol/API/Inputs/MetadataInputs.swift
public struct MetadataPreviewInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]        // 1...500，去重
    public let addedKeywords: [String]   // 0...100
    public let removedKeywords: [String]
    public init(photoIds: [String], addedKeywords: [String] = [], removedKeywords: [String] = []) throws
}

public struct MetadataKeywordApplyInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]
    public let addedKeywords: [String]
    public let removedKeywords: [String]
    public init(photoIds: [String], addedKeywords: [String] = [], removedKeywords: [String] = []) throws
}

// GatherProtocol/Protocol/Metadata.swift
public struct MetadataKeywordApplyResult: Codable, Equatable, Sendable {
    public let result: WritebackResult
    public let status: MetadataSyncSummary
}
```

两个 Input 均需手写 `init(from:)`（解码后走同一 `photoIds/edit` 校验，不能只靠合成 Decodable）。校验：photoIds 非空/去重/≤500；added+removed ≤100；逐词 ≤256、无 NUL；added 与 removed 大小写折叠后不得重叠；归一化后全空 → `invalidParameter`。  
**新增稳定错误码 `KEYWORD_OWNED_BY_SOURCE`**（进 `GatherErrorCode` 与 L10n 错误表，params: `keyword`/`source`）：API 删除生成词时返回它，UI 用同一码区分“被来源锁定”，而不是笼统的 `INVALID_PARAMETER`。

### 5.2 API 变更（MetadataAPI 7→10）

```swift
func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview
func applyKeywords(_ input: Confirmed<MetadataKeywordApplyInput>) async throws -> MetadataKeywordApplyResult
func retryKeywordWriteback(_ input: Confirmed<SessionReference>) async throws -> MetadataKeywordApplyResult
```

- **不复用 `batchSet`**：`batchSet` 对关键词是 `.replace`（`MetadataService.swift:572-574`），会把预览后外部新增的词覆盖掉；K0 只用它做“覆盖全部”的 P1 备选。  
- `preview` **不写 delivery 行**（与 `WritebackService.preview` 的“预览即入队”不同，原因：取消预览不能让 pending 项被后续 metadata flush 意外执行）。  
- `applyKeywords` 内部：解析 → 按 XMP 分组 → 每侧车 `queueKeywordDelta` → 一次 `flushKeywordQueue(sessionId)`（module=metadata，含该模块其它 pending）→ 读回写入结果 → 回填 cache。  
- `retryKeywordWriteback` 只调 `flushPending`（executePending 会消费 pending+failed），不重新计算 delta。  
- **flush 语义**：现有 `flushMetadataQueue` 在 `failed > 0` 时抛 `writebackFailed`；K0 新增 `flushKeywordQueue`，直接返回 `WritebackResult`（逐项失败进 failedItems），避免“部分失败”被当成整体异常。  
- 返回的 `status` 由 `LiveMetadataAPI` 用 `deliveryRepo.metadataSummary(sessionId:module:.metadata)` 投影，UI 用它显示 pending/failed/conflict。

### 5.3 预览实现（只读）

`MetadataService` 新增（签名）：

```swift
func previewKeywords(
    photoIds: [String], added: [String], removed: [String],
    conflictedXmpPaths: Set<String> = []
) async throws -> WritebackPreview

func applyKeywordDelta(
    photoIds: [String], added: [String], removed: [String]
) async throws -> WritebackResult

func retryKeywordWriteback(sessionId: String) async throws -> WritebackResult
```

`previewKeywords`：

1. `getPhotosByIds` + `assetResolver.resolveMany` 得到 photo→(filepath,xmpPath)；无 resolver 回退 `TSPath.xmpSidecarPath`。  
2. 按 xmpPath 去重，统计 `sharedPhotoCount`；`willCreate = !xmp.fileExists(xmpPath)`。  
3. 并行 8 读 `xmp.readKeywords(photoPath:)`；`metadataCacheRepo.getBatch` 读 cache。  
4. `externalChanged = normalize(cache.keywords) != normalize(disk) || conflictedXmpPaths.contains(xmp)`；无 cache 行时不标 externalChanged（未知≠外部修改）；`conflictedXmpPaths` 由 `LiveMetadataAPI` 从 `deliveryRepo.conflictDeliveries(sessionId:)` 传入。  
5. 对每个 xmp 产出 `WritebackItem`：`id=nil`、`photoId/photoPath` 取首张、`module="metadata"`、`keywords=plan.after`、`preview.before/after/dirtyFields=[.keywords]/source="metadata"/sharedPhotoCount/externalChanged/willCreate`。**不落库**，仅展示。  
6. 被生成词阻止的删除：`plan.after` 不含该删除，item 写 `errorMessage="KEYWORD_OWNED_BY_SOURCE:<keyword>:<source>"`、`xmpStatus="blocked"`、`preview.dirtyFields=[]`；UI 行标红且确认按钮整体禁用（不静默跳过）。  
7. 读 XMP 失败：item 写 `errorMessage` 与 `xmpStatus="failed"`，其它项继续；`WritebackPreview(items:, totalCount: xmp 数, affectedPhotos: 照片数)`。

`MetadataService` 需注入 `MetadataKeywordOriginRepo`（组合根 `Composition/Core.swift` 传入）；`removed` 非空时按目标 xmpPath **一次**批量查 origins，`owned` 由服务预载后传给 planner。

### 5.4 写入实现（delta）

`MetadataMutationService.queueKeywordDelta`：

```swift
// MetadataMutationService.swift：专用入口，绕开 enqueue 的 writableNames 过滤
func queueKeywordDelta(
    sessionId: String, photoId: String, added: [String], removed: [String],
    owned: [String: Set<MetadataMutationSource>]   // 由 apply 批量预载
) async throws -> MetadataMutationResult? {
    let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
    let xmpPath = TSPath.normalize(resolved.xmpPath)
    return try await chain.run(path: xmpPath) {
        let current = try await self.xmp.readAttributes(photoPath: resolved.filepath)
        let pending = try? self.deliveryRepo.item(
            xmpPath: xmpPath, photoId: photoId, module: .metadata)?.keywordList
        let existing = try normalizeKeywords(
            (pending?.isEmpty == false ? pending! : current.keywords ?? []))
        let plan = KeywordPlanner.plan(
            existing: existing, added: added, removed: removed, owned: owned)
        guard plan.blocked.isEmpty else {
            throw GatherError(code: .KEYWORD_OWNED_BY_SOURCE,
                params: ["keyword": plan.blocked[0].keyword,
                         "source": plan.blocked[0].sources[0].rawValue])
        }
        guard plan.changed else { return nil }
        return try self.enqueueKeywordDelta(
            sessionId: sessionId, photoId: photoId, plan: plan)
    }
}

// 专用入队：显式允许 keywords_added / keywords_remove 进 attributes_json；
// 不能走普通 enqueue(values:)：后者按 MetadataField.writableNames 过滤，
// 两个内部键会被静默丢弃。
private func enqueueKeywordDelta(
    sessionId: String, photoId: String, plan: KeywordPlan
) throws -> MetadataMutationResult {
    try enqueue(
        sessionId: sessionId, photoId: photoId,
        values: ["keywords": .array(plan.after.map(JSONValue.string))],
        keywordsMode: .delta,
        extraAttributes: [
            "keywords_added": .array(plan.added.map(JSONValue.string)),
            "keywords_remove": .array(plan.removed.map(JSONValue.string))
        ])
}
```

执行器 `WritebackService+Execute.writeGroupItems` 增加分支：

```swift
// attrs = entry.item.attributes（raw JSON；内部键不会被 WritebackAttributes 投影丢掉）
case "delta":
    let added = attrs["keywords_added"]?.arrayElements?.compactMap(\.stringValue) ?? []
    let removed = attrs["keywords_remove"]?.arrayElements?.compactMap(\.stringValue) ?? []
    attributesToWrite.keywords = KeywordPlanner.apply(
        existing: attributesToWrite.keywords ?? [], added: added, removed: removed)
```

- `enqueue` 当前只复制 rating/label/keywords 并写 `keywords_mode`；K0 增加 `extraAttributes: [String: JSONValue] = [:]` 参数（仅内部键，不进 `MetadataField.writableNames`），落进 `delivery_items.attributes_json`；普通调用不传，行为不变。  
- **入队过滤缺口（必须修）**：普通 `enqueue(values:)` 只按 `MetadataField.writableNames` 复制 rating/label/keywords，`keywords_added`/`keywords_remove` 会被静默丢弃。因此 K0 用**专用** `enqueueKeywordDelta`（或在 `enqueue` 显式放行这两个内部键），并在 `delivery_items.attributes_json` 断言两者存在（§8-16）。
- **端口**：`queueKeywordDelta` 需加入 `MetadataMutationPort`（`MetadataService` 只持有 `any MetadataMutationPort`），测试替身同步实现。  
- **flush**：`applyKeywordDelta` 使用新增的 `flushKeywordQueue`（返回 `WritebackResult`，逐项失败不抛整体错误），再读回结果。  
- **批量预载**：`applyKeywordDelta` 先按目标 xmpPath 一次性查 `metadata_keyword_origins`（`active=1`），得到 `[xmpPath: [fold(keyword): Set<source>]]`，再逐侧车调用 `queueKeywordDelta(..., owned:)`；预览同理，`removed` 为空时完全不查 origins。  
- **每侧车只入队一次**：按 xmpPath 分组后取首张照片作为 item 的 `photoId`（RAW+JPEG 共享侧车），避免同一侧车重复 item/revision；`queueKeywordDelta` 返回 nil 的侧车跳过。  
- 仍在 `XMPFileLock.run(path:)` 内读-改-写；`MetadataKeywordWriteMode` 增加 `.delta`。
- `delivery_items.keywords` 存 `plan.after`（冲突投影/展示用）；真正写盘用 attributes 里的 added/removed。**K0-4 必改**：`LiveMetadataAPI.dirtyFields` 目前只看 `keywordList` 非空——`keywords_mode=delta` 时即使 after 为空也要把 `.keywords` 计入冲突字段，否则“只删词”的冲突不会出现在裁决 UI。
- **预览必须完全绕开 `WritebackService.preview`**：后者会 `createOrGet`/`reopenDeliveryForInput`/`upsertItem`，留下 pending 行；`metadata.preview` 走 `MetadataService.previewKeywords` 纯读路径，预览前后 `delivery_items` 行数不变（§8-15）。
- **手动词不写 origins**：`metadata_keyword_origins` 的 CHECK 无 `manual`，D2 又禁止改表；因此只在“生成词”上查 `activeSources`，手动词没有来源行（§8-5）。
- **重试范围**：`retryKeywordWriteback` 调用 `flushPending(sessionId)`，会重放 **module=metadata 的全部 pending/failed**（不限于关键词；rating/label 的手动项也会一起执行）。这是安全且幂等的行为，但 UI 文案必须写“重试元数据写回”，不能写“只重试关键词”。
- 写后 `xmp.readKeywords` 回读，更新 `photo_metadata_cache.keywords`（仅目标侧车；以现有 cache 行为基底，只换 keywords；无行则下次 `getMetadata` 重新提取）；失败保留旧 cache 并记日志。
- 幂等：同一 delta 重复执行时，执行器第二次 `(disk ∪ added) − removed` 结果不变；失败重试不会产生重复词。

### 5.5 自动补全（不新增 API）

**推荐**：扩展 `PhotoAPI.suggestions` 的返回，而非新查询；底层用 Application 级 `KeywordCatalog` 缓存。

```sql
-- 冷加载：每个会话一次（TTL 60s，写回/索引后失效）
SELECT keywords FROM photo_metadata_cache
WHERE session_id = ? AND keywords <> '[]';
```

- Swift 解析 JSON、按 `fold` 去重计数，保留原拼写；内存字典，冷启动 20k 约 150–300ms，热查询 <5ms；建议条数 8，按频次+最近使用排序。
- **长度门槛**：关键词允许 ≥1 个字符（中文单字有意义）；camera_make 仍要求 ≥2；`suggest` 的空/1 字符行为按字段区分，不能一刀切。
- `PhotoFilterQuery.suggest` 把 camera_make 查询加上 `WHERE session_id = ?`（当前是全库，顺手修正）；返回顺序保持 **camera_make 在前、keyword 在后**，避免既有 `.first` 消费者语义变化；两条 `FilterSuggestion`。
- 缓存失效：`KeywordCatalog` TTL 60s，并在 metadata 写入/人脸/相似组写回/索引完成后失效；不依赖文件 mtime。
- 空态/无匹配：返回空，UI 显示“创建 ‘xxx’”行；不编造建议。

### 5.6 DDL

**P0 不新增表**（D2）。手动词不写来源表，原因是既有约束：

```sql
CREATE TABLE metadata_keyword_origins (
  xmp_path TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('face-keyword','culling','similarity','template')),
  keyword TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY (xmp_path, source, keyword)
);
```

查询生成词归属（新增仓储方法，按 xmpPath 批量；关键词用 fold 在 Swift 侧匹配，避免大小写/拼写差异漏判）：

```swift
func activeSources(
    xmpPaths: [String]
) throws -> [String: [String: Set<MetadataMutationSource>]]
// 返回 [xmpPath: [fold(keyword): sources]]；空 removed 时不调用。
```

```sql
SELECT xmp_path, keyword, source FROM metadata_keyword_origins
WHERE xmp_path IN (?, ...) AND active = 1;
```

## 6. 来源与审计

| 项 | P0 结论 | 已知限制 |
|---|---|---|
| manual 来源 | **不写** origins；CHECK 无 manual，改表违反 D2 | 无法区分“手动加”与“外部软件加” |
| 生成词 | 保留；删除前查 origins，四个来源都阻止 | 生成词若被外部删除，下次人脸/相似写回会补回 |
| 审计 | 依赖 delivery `backup_path` + `cleanup` 恢复；失败项可见 | 无逐词历史；⌘Z 不支持关键词写回 |
| JPEG 内嵌 XMP | 预览/写入以 `XMPProvider` 侧车读写为准（与执行器同源） | 内嵌词与侧车不一致时，预览可能不显示内嵌词；P0 不改写回路径 |
| 后续 | 若评审要求逐词审计，V4 加 `manual_keyword_edits`（非 P0） | — |

## 7. 性能预算与测量

| 场景 | 预算 | 方法 |
|---|---|---|
| 预览 500 张/≤500 XMP（RAW+JPEG 典型 250） | p95 <1.5s（热），冷 <3s | 10 次取 p95，临时 XMP 夹具 |
| 应用 500 张 | p95 <8s，UI 不阻塞 | 后台 Task + 进度；Instruments |
| 自动补全 | 冷 <300ms，热 <50ms | 20k cache 夹具，prefix 输入 |
| 内存 | catalog <5MB，预览不复制全量 keywords | Instruments Allocations |
| 主线程 | 单次 >50ms 卡顿为 0 | Time Profiler |

## 8. 测试矩阵

| # | 用例 | 期望 |
|---|---|---|
| 1 | 500 张/250 侧车 批量加 | 一次确认，written=250，cache 更新 |
| 2 | 重复/大小写/空白输入 | 去重为首次拼写，无重复写盘 |
| 3 | NFC/NFD（é） | 视为同一词 |
| 4 | 空会话/无关键词 | 预览空，按钮禁用，无交付行 |
| 5 | face 生成词 + 手动加/删 | 加不重复；删被阻止并提示解绑 |
| 6 | RAW+JPEG 共享侧车 | sharedPhotoCount=2，只写一次 |
| 7 | 预览后外部新增词 | apply 保留外部词（delta） |
| 8 | 预览后外部改词 | externalChanged=true；apply 仍安全 |
| 9 | XMP 只读/磁盘满 | failedItems 可见；修复后 retry 成功 |
| 10 | 冲突裁决后重试 | 走既有 conflict + delivery 备份 |
| 11 | 层级词（竖线分隔） | 原样写盘，不展开父级 |
| 12 | 离线照片/无效 id | 跳过/报错，不影响其它项 |
| 13 | 20k 自动补全 | 冷/热预算内；空输入返回空 |
| 14 | 写回后 cleanup | 备份可恢复原 XMP |
| 15 | **预览前后 `delivery_items` 行数** | 完全不变（证明绕开 `WritebackService.preview`） |
| 16 | **入队后 `attributes_json`** | 含 `keywords_added`/`keywords_remove`；普通 `enqueue` 不吃这两个键 |
| 17 | 500 张跨页选择 | 加载 2 页后选 500，预览/应用通过 |
| 18 | `suggest` 会话隔离 | A 会话 camera_make 不串到 B；关键词只来自本会话；空 → 空；1 个汉字 → 有建议；1 个拉丁字母 → 空（camera 仍 ≥2） |
| 19 | retry 重放范围 | module=metadata 的 rating/label pending 一并执行，不重复写关键词 |
| 20 | 生成词错误码 | `KEYWORD_OWNED_BY_SOURCE` 有 L10n 文案，UI 能区分“锁定”与参数错误 |

## 9. 风险与未决

| # | 问题 | 选项 | 推荐 |
|---|---|---|---|
| 1 | apply 用新方法还是 `batchSet` | 新 `applyKeywords` vs 复用 replace | **新方法**：replace 会覆盖外部词 |
| 2 | 写入用 delta 还是 replace | delta（改执行器）vs replace（简单但丢词） | **delta** |
| 3 | 是否加 status/retry API | 3 个新方法 vs 复用 culling.syncStatus + 重放 | **3 个**（状态准确） |
| 4 | 手动词是否记来源 | 不记 vs V4 新表 | **不记**（D2） |
| 5 | 层级/同义词 | 平铺 vs P1 关键词库 | **平铺**，P1 再做树/同义词 |
| 6 | 生成词删除 | 阻止 vs 警告后删 | **阻止**（防止下次写回打架） |
| 7 | 自动补全 | 扩展 suggestions vs 新查询 | **扩展 + 会话缓存** |
| 8 | 画廊是否可编辑 | 仅挑片 vs 扩展 Gallery payload | **仅挑片**（P0 不做 payload/VM 扩） |
| 9 | ⌘K 冲突 | ⌘K vs ⌥K | **⌘K**（本页无其它占用） |
| 10 | retry 范围 | 只重试关键词 vs module=metadata 全部 pending | **全部**（幂等）；文案写“重试元数据写回” |
| 11 | suggest 加 sessionId | 保持全库 vs 会话过滤 | **会话过滤**（更相关）；补跨会话隔离测试 |

## 10. 实施拆解（合计 15 PD）

| ID | 任务 | 主要文件 | PD | 验收 |
|---|---|---|---:|---|
| K0-1 | 规格定稿与评审 | 本文档 | 1 | 评审通过，x0 同步 |
| K0-2 | 纯函数 + delta 服务/执行器（含 `Composition/Core.swift` 注入 origin repo、`MetadataKeywordOriginRepo` 批量查询） | `KeywordEdit.swift`、`MetadataService.swift`、`MetadataMutationService.swift`、`WritebackService+Execute.swift`、`MetadataKeywordOriginRepo.swift` | 3 | 幂等/并发单测 |
| K0-3 | 只读预览 + 外部修改判定 | `MetadataService.swift`、`LiveMetadataAPI.swift` | 2.5 | 500 张 p95 <1.5s |
| K0-4 | API/契约/基线 | `MetadataAPI.swift`、`MetadataInputs.swift`、`LiveMetadataAPI.swift`、`PreviewAPIs.swift`、`protocol-surface-baseline.json` | 1 | 契约测试 + strict 门禁 |
| K0-5 | 自动补全 | `PhotoFilterQuery.swift`、`KeywordCatalog.swift`、`LivePhotoAPI.swift` | 1.5 | 冷/热预算 |
| K0-6 | 检查器 UI（chips/预览/结果/a11y） | `CullingKeywordPanel.swift`、`CullingInspector.swift`、`en.lproj` | 4 | 键盘全流程 + 文案 |
| K0-7 | 测试矩阵与性能 | core/app tests | 2 | 20 项全绿（含 15–20 缺口测试） |
| | **合计** | | **15** | |

## 11. 与 x0-contracts 的冲突/缺口

| # | x0 现状 | K0 需要 | 处理 |
|---|---|---|---|
| 1 | 只列 `metadata.preview` | 还需 `applyKeywords`、`retryKeywordWriteback` | **冲突**：批准后补进 x0 与 P0 计划 |
| 2 | 方法数“约 118” | K0 在 x0 的 preview 之外再 +2（apply/retry）→ 约 120；MetadataAPI 7→10 | 更新 baseline/README，禁止静默改 |
| 3 | `MetadataPreviewInput` 未定义 | 字段与校验见 §5.1 | 补进 x0 |
| 4 | 未提自动补全 | 扩展 `PhotoAPI.suggestions` | §7.5 未决项落定；补一行 |
| 5 | D6“预览与写回同源” | 只读预览 + delta 写回 | 不冲突，但需在 x0 记录“preview 不建 pending” |
| 6 | V3 仅两表 | K0 不加表 | 一致 |
| 7 | 错误码清单无关键词项 | 新增 `KEYWORD_OWNED_BY_SOURCE`（params keyword/source） | **冲突**：批准后补进 x0 错误码表与 L10n；其余复用 `invalidParameter`/`XMP_*` |
