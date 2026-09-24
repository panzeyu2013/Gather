// desktop/native/gather-core/Sources/GatherCore/Runtime/Culling/CullingAssembler.swift
// W2b 步骤 2：CullingRuntime 纯函数层（Services/CullingService.swift 的纯逻辑下沉）。
//
// 来源与边界：
// - 逐字移植 CullingService.swift 中的纯逻辑：行 → DTO（photoData/state）、RAW 变体
//   折叠（groupKey/isPreferredVariant/assembleAssets）、人脸归一化、质量相对排名、
//   过滤安全网（matches/filterVisible）、groups/summary 装配、决策/补丁辅助
//   （pickState/legacyDecision/fields/patch/matchesSnapshot）。
// - 本文件无 IO、无 SQL、无 Store 依赖：输入为行/富查询/过滤规格，输出为 Protocol
//   层 DTO；仅依赖 TSPath（纯路径）与 JSONValue（纯解析）。设计文档 §6 门禁：
//   Runtime/Culling/** 不得出现 SQL 文本或数据库连接类型（本文件不 import C SQLite
//   Store 层，也不做任何查询）。
//
// 类型归属：
// - 富查询值袋由本文件声明。命名注记：设计文档写的是 CullingRichLookup，但
//   Services/CullingService.swift 已有一个同名 file-private struct，同模块顶层
//   重名会硬报 invalid redeclaration（服务删除前两者无法并存），故暂名
//   CullingAssetLookup；W2b 步骤 7 删除 CullingService.swift 后整体改回
//   CullingRichLookup（纯机械重命名）。字段/语义与设计逐字一致，LookupLoader 复用。
// - CullingFilterSpec / CullingQualityPredicate 由 Store/CullingQueryStore.swift
//   声明（SQL 下推与 JS 匹配的同一谓词来源），本文件只引用不声明；
//   CullingFilters → [CullingFilterSpec] 的编译入口是本文件的
//   CullingAssembler.specs(from:)。
//
// 语义注记（设计文档 §3.6）：asset_id = '' 与 NULL 同义，统一由 groupKey 归一化，
// 避免空串把互不相关的照片折进同一个"资产"。

import Foundation

/// TS: CullingAssetLookup —— assembleAssets 所需的全部每照片富化查询结果。
/// 由 LookupLoader 经 Store 协议批量装载后传入（值类型 + Sendable：可安全跨 actor）。
public struct CullingAssetLookup: Equatable, Sendable {
    /// photoId → 当前决策行。
    public var decisions: [String: CullingDecisionRecord]
    /// photoId → 元数据缓存行（rating/label/keywords 兜底）。
    public var cacheRows: [String: MetadataCacheRecord]
    /// xmpPath → outbox 行（写回状态与 metadataSource）。
    public var outboxByPath: [String: OutboxRecord]
    /// photoId → 相似度组 id（"<resultId>:<index>"）。
    public var similarityMap: [String: String]
    /// photoId → 质量分析（relativeRank 由 applyRelativeRank 预填）。
    public var qualityByPhoto: [String: CullingQuality]
    /// photoId → 原始 bbox 列表（归一化前的数据库原始值）。
    public var facesByPhoto: [String: [[Double]]]
    /// photoId → 分析签名里的 previewMaxDimension（缺省时用 getNumber 兜底）。
    public var analysisMaxByPhoto: [String: Double]
    /// photoId → 人物名（按名排序、去重）。
    public var peopleByPhoto: [String: [String]]
    /// xmpPath → 共享该侧车的照片数（linkedVariantCount）。
    public var linkedCounts: [String: Int]

    public init(
        decisions: [String: CullingDecisionRecord] = [:],
        cacheRows: [String: MetadataCacheRecord] = [:],
        outboxByPath: [String: OutboxRecord] = [:],
        similarityMap: [String: String] = [:],
        qualityByPhoto: [String: CullingQuality] = [:],
        facesByPhoto: [String: [[Double]]] = [:],
        analysisMaxByPhoto: [String: Double] = [:],
        peopleByPhoto: [String: [String]] = [:],
        linkedCounts: [String: Int] = [:]
    ) {
        self.decisions = decisions
        self.cacheRows = cacheRows
        self.outboxByPath = outboxByPath
        self.similarityMap = similarityMap
        self.qualityByPhoto = qualityByPhoto
        self.facesByPhoto = facesByPhoto
        self.analysisMaxByPhoto = analysisMaxByPhoto
        self.peopleByPhoto = peopleByPhoto
        self.linkedCounts = linkedCounts
    }
}

/// TS: culling.service.ts 的纯函数面（QueryBuilder/LookupLoader/Store 均不在此文件）。
public enum CullingAssembler {
    // MARK: - 常量（TS 文件头部）

    /// TS: COLOR_LABELS —— 合法的 Capture One 颜色标签全集。
    private static let colorLabels: Set<CaptureOneColorLabel> = [
        .none, .red, .orange, .yellow, .green, .blue, .pink, .purple,
    ]

    /// TS: PREFERRED_RAW_EXTENSIONS（预编译小写 RAW 扩展名集合，O(1) 探测）。
    private static let preferredRawExtensions: Set<String> = Set(PhotoFormats.rawExtensions)

    /// TS: metadataSource 的合法来源集合（assembleAssets 从 outbox patch 解析）。
    private static let metadataPatchSources: Set<String> = [
        "culling", "face-keyword", "similarity", "template", "manual",
    ]

    // MARK: - 资产分组键 / 变体偏好

    /// 逻辑资产键：真实 asset_id 优先，空串与 NULL 同义 → "photo:<id>"。
    /// SQL 侧的等价归一化是 `COALESCE(NULLIF(asset_id, ''), id)`（设计的 §3.6；
    /// JS 侧前缀 "photo:" 只用于区分"无真实资产"的行，分组划分与 SQL 逐条一致）。
    public static func groupKey(assetId: String?, photoId: String) -> String {
        if let assetId, !assetId.isEmpty { return assetId }
        return "photo:\(photoId)"
    }

    /// 便捷重载：直接按行取键。
    public static func groupKey(_ photo: CullingPhotoRow) -> String {
        groupKey(assetId: photo.assetId, photoId: photo.id)
    }

    /// TS: isPreferredRawVariant —— 首选 RAW 变体探测（小写扩展名集合 O(1) 探测）。
    public static func isPreferredVariant(filename: String) -> Bool {
        let lower = filename.lowercased()
        guard let dot = lower.lastIndex(of: ".") else { return false }
        return preferredRawExtensions.contains(String(lower[dot...]))
    }

    // MARK: - 每会话索引

    /// TS: buildPhotosByAssetIndex —— asset_id → 照片索引，updateState 的按资产变体
    /// 扫描变成 map 查找。空串 asset_id 与 NULL 一样跳过：扫描只匹配共享真实
    /// asset_id 的照片（空串不是真实资产，绝不能让互不相关的行互相改状态）。
    public static func photosByAssetIndex(
        _ photos: [CullingPhotoRow]
    ) -> [String: [CullingPhotoRow]] {
        var photosByAssetId: [String: [CullingPhotoRow]] = [:]
        for photo in photos {
            guard let assetId = photo.assetId, !assetId.isEmpty else { continue }
            photosByAssetId[assetId, default: []].append(photo)
        }
        return photosByAssetId
    }

    /// TS: ensureUpdateExtras 的 xmp 联动映射 —— 共享同一 XMP 侧车的照片
    /// （RAW/JPEG 变体、同 stem 多文件）；失去该映射时共享元数据不会被联动。
    public static func linkedByXmpIndex(
        _ photos: [CullingPhotoRow]
    ) -> [String: [CullingPhotoRow]] {
        var linkedByXmp: [String: [CullingPhotoRow]] = [:]
        for photo in photos {
            linkedByXmp[TSPath.xmpSidecarPath(photo.filepath), default: []].append(photo)
        }
        return linkedByXmp
    }

    // MARK: - 人脸归一化

    /// TS: assembleAssets 的人脸分支 —— 当前检测器观测已归一化；老数据库存的是
    /// 预览像素坐标，为范围外的值保留有界的兼容换算，随后 clamp 到 [0, 1]，
    /// 最后按面积（w*h）降序（大脸在前）。
    ///
    /// - Parameters:
    ///   - faces: 原始 bbox（数据库列序 x/y/w/h）。
    ///   - analysisMax: 该照片分析签名里的 previewMaxDimension；缺省时为
    ///     max(detect_input_size, face_preview_max_dimension)。
    ///   - width/height: 照片原始像素尺寸（<=0 时按 1 守卫）。
    public static func normalizedFaceBoxes(
        _ faces: [[Double]],
        analysisMax: Double,
        width: Int,
        height: Int
    ) -> [[Double]] {
        let sourceWidth = max(1, width)
        let sourceHeight = max(1, height)
        let analysisScale = min(1, analysisMax / Double(max(sourceWidth, sourceHeight)))
        let analysisWidth = Double(sourceWidth) * analysisScale
        let analysisHeight = Double(sourceHeight) * analysisScale
        return faces.compactMap { face -> [Double]? in
            // 数据库 bbox 恒为 4 列；损坏行退化丢弃而不是越界崩溃。
            guard face.count >= 4 else { return nil }
            let alreadyNormalized = face[0] >= 0 && face[1] >= 0 && face[2] >= 0 && face[3] >= 0
                && face[0] <= 1 && face[1] <= 1 && face[2] <= 1 && face[3] <= 1
            let values = alreadyNormalized
                ? face
                : [face[0] / analysisWidth, face[1] / analysisHeight,
                   face[2] / analysisWidth, face[3] / analysisHeight]
            return values.map { min(1, max(0, $0)) }
        }.sorted { ($0[2] * $0[3]) > ($1[2] * $1[3]) }
    }

    // MARK: - 质量相对排名

    /// TS: buildRichLookup 的组内相对排名 —— 同一相似度组内成功质量按分数降序
    /// 1 起排名；失败/无组的结果保持原 relativeRank。返回新字典（值语义，纯函数）。
    public static func applyRelativeRank(
        _ qualityByPhoto: [String: CullingQuality],
        similarityMap: [String: String]
    ) -> [String: CullingQuality] {
        var ranked = qualityByPhoto
        var qualityGroups: [String: [(photoId: String, quality: CullingQuality)]] = [:]
        for (photoId, quality) in qualityByPhoto {
            guard let groupId = similarityMap[photoId],
                  quality.status == .succeeded else { continue }
            qualityGroups[groupId, default: []].append((photoId, quality))
        }
        for (_, members) in qualityGroups {
            let sorted = members.sorted { $0.quality.score > $1.quality.score }
            for (index, member) in sorted.enumerated() {
                guard var updated = ranked[member.photoId] else { continue }
                updated.relativeRank = Double(index + 1)
                ranked[member.photoId] = updated
            }
        }
        return ranked
    }

    // MARK: - 状态（决策行 + 缓存兜底）

    /// TS: rowToState —— 决策行优先；行缺失时 rating/label 取 cache 兜底。
    /// 决策行存在时其 rating 原样透出（历史行可能越界，沿用 TS 语义），
    /// colorLabel/source 非法值归一化为 .none / .manual。
    public static func state(
        photoId: String,
        decision: CullingDecisionRecord?,
        cache: MetadataCacheRecord?
    ) -> AssetCullingState {
        let fallbackLabel = colorLabel(raw: cache?.label ?? "None")
        let cacheRating = cache?.rating ?? 0
        let fallbackRating = (0...5).contains(cacheRating) ? cacheRating : 0
        let rowColorLabel = colorLabel(raw: decision?.colorLabel ?? "")
        return AssetCullingState(
            photoId: photoId,
            pickState: pickState(decision?.decision),
            rating: Double(decision?.rating ?? fallbackRating),
            colorLabel: decision != nil ? rowColorLabel : fallbackLabel,
            source: sourceFromDecisionRow(decision),
            revision: Int(decision?.revision ?? 0),
            updatedAt: decision?.updatedAt ?? ""
        )
    }

    /// TS: rowToState 的 source 分支（决策行存在时取合法 decision_source，缺省
    /// manual；行缺失时为 imported）。
    private static func sourceFromDecisionRow(_ row: CullingDecisionRecord?) -> CullingDecisionSource {
        guard let row else { return .imported }
        return CullingDecisionSource(rawValue: row.decisionSource) ?? .manual
    }

    private static func colorLabel(raw: String) -> CaptureOneColorLabel {
        guard let parsed = CaptureOneColorLabel(rawValue: raw),
              colorLabels.contains(parsed) else { return .none }
        return parsed
    }

    // MARK: - 资产装配（富化 + 变体折叠）

    /// TS: assembleAssets —— 富化 + 按逻辑资产分组 + RAW 优先折叠变体。
    ///
    /// - Parameter getNumber: TS SettingsService.getNumber 兜底读（通常注入
    ///   settings 表读；缺省返回默认值，与 CullingService 的测试注入一致）。
    public static func assembleAssets(
        photos: [CullingPhotoRow],
        lookup: CullingAssetLookup,
        getNumber: (String, Double) -> Double = { _, defaultValue in defaultValue }
    ) -> [CullingAsset] {
        let assets: [CullingAsset] = photos.map { photo in
            let decision = lookup.decisions[photo.id]
            let cache = lookup.cacheRows[photo.id]
            let xmpPath = TSPath.xmpSidecarPath(photo.filepath)
            let outbox = lookup.outboxByPath[xmpPath]
            let analysisMax = lookup.analysisMaxByPhoto[photo.id]
                ?? max(
                    getNumber("detect_input_size", 640),
                    getNumber("face_preview_max_dimension", 2048)
                )
            return CullingAsset(
                photo: photoData(
                    photo,
                    faceCount: lookup.facesByPhoto[photo.id]?.count ?? 0
                ),
                state: state(photoId: photo.id, decision: decision, cache: cache),
                xmpPath: xmpPath,
                syncStatus: MetadataSyncStatus(rawValue: outbox?.status ?? "") ?? .clean,
                people: lookup.peopleByPhoto[photo.id] ?? [],
                keywords: cache?.keywords ?? [],
                similarityGroupId: lookup.similarityMap[photo.id],
                linkedVariantCount: lookup.linkedCounts[xmpPath] ?? 1,
                faceBboxes: normalizedFaceBoxes(
                    lookup.facesByPhoto[photo.id] ?? [],
                    analysisMax: analysisMax,
                    width: photo.width,
                    height: photo.height
                ),
                quality: lookup.qualityByPhoto[photo.id],
                metadataSource: metadataSource(fromPatchJSON: outbox?.patchJSON ?? "{}")
            )
        }

        // 按逻辑资产 id 单遍分组（替代整数组每组的过滤，大会话下 O(n²)）。
        // TS 的 Map 保插入序；Swift Dictionary.values 顺序不定，故显式维护
        // 首见顺序，资产顺序与 TS `[...assetsByAssetId.values()]` 一致。
        var assetsByAssetId: [String: [CullingAsset]] = [:]
        var assetIdOrder: [String] = []
        for asset in assets {
            let assetId = groupKey(assetId: asset.photo.assetId, photoId: asset.photo.id)
            if assetsByAssetId[assetId] == nil { assetIdOrder.append(assetId) }
            assetsByAssetId[assetId, default: []].append(asset)
        }
        return assetIdOrder.compactMap { assetsByAssetId[$0] }.map { variants in
            let preferred = variants.first(where: {
                isPreferredVariant(filename: $0.photo.filename)
            }) ?? variants[0]
            var photo = preferred.photo
            photo.variantCount = variants.count
            photo.variants = variants.map { variant in
                PhotoVariant(
                    photoId: variant.photo.id,
                    filepath: variant.photo.filepath,
                    filename: variant.photo.filename,
                    role: variant.photo.id == preferred.photo.id ? "primary" : "variant"
                )
            }
            var asset = preferred
            asset.photo = photo
            return asset
        }
    }

    /// TS: assembleAssets 的 metadataSource 分支 —— 损坏的历史补丁由 sync status
    /// 呈现（TS try/catch）；只认合法 source 字符串。
    private static func metadataSource(fromPatchJSON patchJSON: String) -> MetadataMutationSource? {
        guard let parsed = try? JSONValue.parse(patchJSON),
              case .object(let dict) = parsed,
              let source = dict["source"]?.stringValue,
              metadataPatchSources.contains(source) else { return nil }
        return MetadataMutationSource(rawValue: source)
    }

    // MARK: - 过滤（SQL 下推 + JS 安全网，同一谓词来源）

    /// TS: matchesFilters 的谓词编译 —— CullingFilters → Store 的 SQL 规格列表
    /// （空规格退化为 []，多规格按 AND 叠加）。Store 侧把同一列表编译成 SQL WHERE
    /// （除 metadataConflictOnly：它依赖 JS 计算的 XMP 侧车路径，见 matches 的独立入参）。
    public static func specs(from filters: CullingFilters?) -> [CullingFilterSpec] {
        guard let filters else { return [] }
        // Store 的 CullingFilterSpec(filters:) 是 TS CullingFilters → SQL 规格的唯一
        // 映射（qualityStatus 三态 → succeeded/failed/absent），此处只做「空规格
        // 退化为不过滤」的归一化，避免第二份映射漂移。
        let spec = CullingFilterSpec(filters: filters)
        let isEmpty = !spec.unreviewed && spec.pickStates.isEmpty && spec.ratings.isEmpty
            && spec.colorLabels.isEmpty && spec.quality == nil
        return isEmpty ? [] : [spec]
    }

    /// TS: filters.metadataConflictOnly 的 JS 侧入口（SQL 不下推）。
    public static func metadataConflictOnly(from filters: CullingFilters?) -> Bool {
        filters?.metadataConflictOnly == true
    }

    /// TS: matchesFilters / buildFilteredWhere 的 JS 安全网 —— 同一谓词来源的
    /// JS 侧应用。空列表恒通过；metadataConflictOnly 只在 JS 层判定。
    public static func matches(
        _ asset: CullingAsset,
        specs: [CullingFilterSpec],
        metadataConflictOnly: Bool
    ) -> Bool {
        for spec in specs {
            if spec.unreviewed, asset.state.pickState != .unreviewed { return false }
            if !spec.pickStates.isEmpty, !spec.pickStates.contains(asset.state.pickState) { return false }
            if !spec.ratings.isEmpty, !spec.ratings.contains(asset.state.rating) { return false }
            if !spec.colorLabels.isEmpty, !spec.colorLabels.contains(asset.state.colorLabel) { return false }
            if let predicate = spec.quality {
                switch predicate {
                case .succeeded:
                    if asset.quality?.status != .succeeded { return false }
                case .failed:
                    if asset.quality?.status != .failed { return false }
                case .absent:
                    if asset.quality != nil { return false }
                }
            }
        }
        if metadataConflictOnly && asset.syncStatus != .conflict { return false }
        return true
    }

    /// 便捷重载：直接从 IPC 过滤条件判定（等价于 specs(from:) + matches）。
    public static func matches(_ asset: CullingAsset, filters: CullingFilters?) -> Bool {
        matches(
            asset,
            specs: specs(from: filters),
            metadataConflictOnly: metadataConflictOnly(from: filters)
        )
    }

    /// TS: filterVisible —— SQL 下推之上的最终安全网。已下推的过滤器
    /// （pick/rating/label/quality）SQL 谓词已作用在首选行，此遍历恒通过；
    /// 未下推的 metadataConflictOnly 在这里应用。
    public static func filterVisible(
        _ assets: [CullingAsset],
        scope: CullingScope,
        specs: [CullingFilterSpec],
        metadataConflictOnly: Bool,
        requestedGroupId: String?
    ) -> [CullingAsset] {
        assets.filter { asset in
            if scope == .similarityGroup {
                guard let similarityGroupId = asset.similarityGroupId else { return false }
                if let requestedGroupId, similarityGroupId != requestedGroupId { return false }
                return true
            }
            if scope == .filtered {
                return matches(asset, specs: specs, metadataConflictOnly: metadataConflictOnly)
            }
            return true
        }
    }

    /// 便捷重载：直接传 IPC 过滤条件。
    public static func filterVisible(
        _ assets: [CullingAsset],
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?
    ) -> [CullingAsset] {
        filterVisible(
            assets,
            scope: scope,
            specs: specs(from: filters),
            metadataConflictOnly: metadataConflictOnly(from: filters),
            requestedGroupId: requestedGroupId
        )
    }

    // MARK: - 相似度组（getGroups 的纯装配）

    /// TS: getGroups 的纯装配 —— 成员轻投影 + 决策计数，按 groupIndex 升序
    /// （同索引按照片首见序，稳定排序；TS Array.sort 稳定）。
    /// 无相似度结果时调用方直接返回 []（本函数在空 membership 上同样返回 []）。
    ///
    /// - Parameters:
    ///   - photos: 会话照片的轻投影（行序即成员首见序）。
    ///   - membership: photoId → 组 id（"<resultId>:<index>"）。
    ///   - decisions: photoId → decision 字符串（缺省 pending）。
    public static func groups(
        photos: [CullingPhotoRow],
        membership: [String: String],
        decisions: [String: String]
    ) -> [CullingGroup] {
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var memberIdsByGroup: [String: [String]] = [:]
        var groupIdsInFirstSeenOrder: [String] = []
        for photo in photos {
            guard let groupId = membership[photo.id] else { continue }
            if memberIdsByGroup[groupId] == nil { groupIdsInFirstSeenOrder.append(groupId) }
            memberIdsByGroup[groupId, default: []].append(photo.id)
        }

        var groups: [(index: Int, insertion: Int, group: CullingGroup)] = []
        for (insertion, groupId) in groupIdsInFirstSeenOrder.enumerated() {
            // 损坏的遗留成员行不得产生打乱组排序的 NaN 键。
            let parsedIndex = Int(groupId.split(separator: ":").last ?? "") ?? 0
            var keepCount = 0
            var rejectCount = 0
            var pendingCount = 0
            var images: [CullingImage] = []
            for photoId in memberIdsByGroup[groupId] ?? [] {
                guard let photo = photoById[photoId] else { continue }
                let decision = decisions[photoId] ?? "pending"
                if decision == "keep" { keepCount += 1 }
                else if decision == "reject" { rejectCount += 1 }
                else { pendingCount += 1 }
                images.append(CullingImage(
                    photoId: photoId,
                    filepath: photo.filepath,
                    filename: photo.filename,
                    decision: LegacyCullingDecision(rawValue: decision) ?? .pending
                ))
            }
            groups.append((index: parsedIndex, insertion: insertion, group: CullingGroup(
                groupId: groupId,
                groupIndex: parsedIndex,
                images: images,
                keepCount: keepCount,
                rejectCount: rejectCount,
                pendingCount: pendingCount
            )))
        }
        // 稳定排序（TS Array.sort 稳定；Swift sort 不保证稳定，同索引时按首见序）。
        return groups
            .sorted { $0.index == $1.index ? $0.insertion < $1.insertion : $0.index < $1.index }
            .map(\.group)
    }

    // MARK: - 徽标计数（getSummary 的纯装配）

    /// TS: getSummary 的纯装配 —— 决策 + 缓存兜底的徽标计数 + 相似度组数
    /// （stats_json.totalGroups，缺失时回退 groups_json 长度）。
    ///
    /// - Parameters:
    ///   - photos: 会话照片轻投影（计数只需 id）。
    ///   - decisions: photoId → 当前决策行。
    ///   - cacheByPhoto: photoId → 轻投影 (rating, label)：只含计数所需两列。
    ///   - result: 最新相似度结果行；nil 时 totalGroups = 0。
    public static func summary(
        photos: [CullingPhotoRow],
        decisions: [String: CullingDecisionRecord],
        cacheByPhoto: [String: (rating: Int64, label: String?)],
        result: SimilarityResultRecord?
    ) -> CullingSummary {
        var kept = 0
        var rejected = 0
        var rated = 0
        var labeled = 0
        for photo in photos {
            let row = decisions[photo.id]
            let cache = cacheByPhoto[photo.id]
            if row?.decision == "keep" { kept += 1 }
            if row?.decision == "reject" { rejected += 1 }
            if (row?.rating ?? cache?.rating ?? 0) > 0 { rated += 1 }
            let label = row?.colorLabel ?? cache?.label ?? "None"
            if let parsed = CaptureOneColorLabel(rawValue: label),
               colorLabels.contains(parsed), parsed != .none {
                labeled += 1
            }
        }
        let totalGroups: Int
        if let result {
            totalGroups = parseTotalGroups(result)
        } else {
            totalGroups = 0
        }
        return CullingSummary(
            totalGroups: totalGroups,
            totalPhotos: photos.count,
            kept: kept,
            rejected: rejected,
            pending: max(0, photos.count - kept - rejected),
            rated: rated,
            labeled: labeled
        )
    }

    // MARK: - 行 → DTO

    /// TS: photoRowToData —— 照片行 → PhotoData（重 JSON 列解析，损坏退化空字典）。
    public static func photoData(_ row: CullingPhotoRow, faceCount: Int) -> PhotoData {
        PhotoData(
            id: row.id,
            sessionId: row.sessionId,
            filepath: row.filepath,
            filename: row.filename,
            checksum: row.checksum,
            hasExistingXmp: false,
            faceCount: faceCount,
            width: row.width,
            height: row.height,
            metadata: parseJSONRecord(row.metadata ?? "{}"),
            result: parseJSONRecord(row.result ?? "{}"),
            status: row.status,
            assetId: row.assetId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// TS: parseJsonRecord —— 解析 JSON 对象（损坏/非对象退化为空字典）。
    public static func parseJSONRecord(_ value: String) -> [String: JSONValue] {
        guard let parsed = try? JSONValue.parse(value),
              case .object(let dict) = parsed else { return [:] }
        return dict
    }

    // MARK: - 决策 / 补丁辅助

    /// TS: decisionToPickState（字符串决策行版）。
    public static func pickState(_ decision: String?) -> PickState {
        switch decision {
        case "keep": .picked
        case "reject": .rejected
        default: .unreviewed
        }
    }

    /// TS: decisionToPickState（LegacyCullingDecision 入参版）。
    public static func pickState(_ decision: LegacyCullingDecision) -> PickState {
        switch decision {
        case .keep: .picked
        case .reject: .rejected
        case .pending: .unreviewed
        }
    }

    /// TS: pickStateToDecision。
    public static func legacyDecision(_ pickState: PickState) -> LegacyCullingDecision {
        switch pickState {
        case .picked: .keep
        case .rejected: .reject
        case .unreviewed: .pending
        }
    }

    /// TS: `Object.keys(patch)` —— 补丁非空字段（CullingUpdatePatch 声明序）。
    public static func fields(_ patch: CullingUpdatePatch) -> [CullingUpdatePatchField] {
        var fields: [CullingUpdatePatchField] = []
        if patch.rating != nil { fields.append(.rating) }
        if patch.pickState != nil { fields.append(.pickState) }
        if patch.colorLabel != nil { fields.append(.colorLabel) }
        return fields
    }

    /// TS: `Object.fromEntries(fields.map(field => [field, snapshot[field]]))`。
    public static func patch(
        fields: [CullingUpdatePatchField],
        snapshot: CullingStateSnapshot
    ) -> CullingUpdatePatch {
        var patch = CullingUpdatePatch()
        for field in fields {
            switch field {
            case .rating: patch.rating = snapshot.rating
            case .pickState: patch.pickState = snapshot.pickState
            case .colorLabel: patch.colorLabel = snapshot.colorLabel
            }
        }
        return patch
    }

    /// TS: applyHistory 的 `current[field] !== expected[field]` 分歧比较。
    public static func matchesSnapshot(
        state: AssetCullingState,
        snapshot: CullingStateSnapshot,
        field: CullingUpdatePatchField
    ) -> Bool {
        switch field {
        case .rating: state.rating == snapshot.rating
        case .pickState: state.pickState == snapshot.pickState
        case .colorLabel: state.colorLabel == snapshot.colorLabel
        }
    }

    // MARK: - 相似度结果计数

    /// TS: parseTotalGroups —— 相似度结果行的组计数。当前管线把 totalGroups 写进
    /// 小的 stats_json 对象，多 MB 的 groups_json 只为旧行解析。损坏行退化为 0
    /// （与旧 groups_json 解析相同）。
    public static func parseTotalGroups(_ resultRow: SimilarityResultRecord) -> Int {
        if let parsed = try? JSONValue.parse(resultRow.statsJson),
           case .object(let dict) = parsed,
           case .number(let value) = dict["totalGroups"],
           value.rounded() == value, value >= 0 {
            return Int(value)
        }
        if let parsed = try? JSONValue.parse(resultRow.groupsJson),
           case .object(let dict) = parsed,
           case .array(let groups) = dict["groups"] {
            return groups.count
        }
        return 0
    }
}
