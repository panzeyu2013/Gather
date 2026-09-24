// desktop/native/gather-core/Sources/GatherCore/Runtime/Culling/CullingLookupLoader.swift
// W2b（设计 §1/§2.2）：CullingLookupLoader —— 无状态 struct，只经 Store 协议批量装载
// 富查询所需的每照片数据（旧 Services/CullingService.swift:1622-1901 的逐段移植）。
//
// 边界与门禁：
// - 本文件不含任何 SQL 文本，也不出现 SQLiteDatabase（Runtime/Culling 门禁）；
//   全部分块、排序、JSON 守卫语义由 Store 方法承担（见各 Store 的 W2b 方法注释）。
// - try? 审计：旧实现的「静默降级」只保留两处显式数据退化（损坏 JSON 解析，
//   与 TS try/catch 同语义，均带注释）；数据库读错误一律上抛（旧 loadSessionPhotos
//   的 try? → [] 已按设计 §3.1 消除，由 Runtime 的 loadSessionPhotos 上抛）。
// - 类型归属：CullingPhotoRow 目前仍声明在 Services/CullingService.swift（W2b 步骤 7
//   删除旧服务时必须原样迁入本文件或 Assembler，见迁移报告）；本文件只引用。
//
// 方法 ↔ 旧实现映射（报告用）：
//   loadDecisions       ← buildRichLookup 的 decisions 段（decisionsFull / decisions）
//   loadMetadata        ← buildRichLookup 的 cacheRows 段（metadataBatch）
//   loadOutbox          ← buildRichLookup 的 outbox 段（outboxEntries 会话 / xmpPaths）
//   loadLatestSimilarity← getLatestSimilarityMap
//   loadSessionLookup   ← getSessionLookup（去掉 TTL/可变条目，返回 CullingSessionCache.Lookup 值）
//   loadAnalyses        ← loadQualityByPhoto + loadFaces + loadPeople
//   loadSummaryCache    ← loadSummaryCacheByPhoto
//   loadPageLookup      ← buildRichLookup（mode == .page）
//   CullingGroupIndex.build ← buildPhotoGroupIndex（纯函数部分）

import Foundation

/// 富查询的分析派生映射（旧 SessionLookupEntry 的四个分析字段）。
public struct CullingLookupAnalyses: Equatable, Sendable {
    /// photoId → 质量分析（relativeRank 由 Assembler.applyRelativeRank 预填）。
    public var qualityByPhoto: [String: CullingQuality]
    /// photoId → 原始 bbox 列表（归一化前的数据库原始值）。
    public var facesByPhoto: [String: [[Double]]]
    /// photoId → 分析签名里的 previewMaxDimension。
    public var analysisMaxByPhoto: [String: Double]
    /// photoId → 人物名（按名排序、去重）。
    public var peopleByPhoto: [String: [String]]

    public init(
        qualityByPhoto: [String: CullingQuality] = [:],
        facesByPhoto: [String: [[Double]]] = [:],
        analysisMaxByPhoto: [String: Double] = [:],
        peopleByPhoto: [String: [String]] = [:]
    ) {
        self.qualityByPhoto = qualityByPhoto
        self.facesByPhoto = facesByPhoto
        self.analysisMaxByPhoto = analysisMaxByPhoto
        self.peopleByPhoto = peopleByPhoto
    }
}

/// TS: buildPhotoGroupIndex 的纯函数部分 —— groups_json → photoId → "resultId:index"。
/// 无相似度结果时返回空索引（groupIndexResolved 语义由调用方管理）。
public enum CullingGroupIndex {
    /// groups_json 是数据库内容：损坏或结构意外的行退化为空索引而不是崩溃（TS 语义）。
    public static func build(
        photos: [CullingPhotoRow],
        resultRow: SimilarityResultRecord?
    ) -> [String: String] {
        guard let resultRow else { return [:] }
        var groups: [[String: JSONValue]] = []
        // 显式退化：groups_json 损坏/结构不符 → 空索引（原实现的 try? 语义，非数据库错误）。
        if let parsed = try? JSONValue.parse(resultRow.groupsJson),
           case .object(let dict) = parsed,
           case .array(let items) = dict["groups"] {
            groups = items.compactMap {
                if case .object(let obj) = $0 { return obj }
                return nil
            }
        }
        // 同一会话内 filepath 有唯一索引；重复时保首见（不因损坏数据崩溃）。
        var photoIdByPath: [String: String] = [:]
        for photo in photos where photoIdByPath[photo.filepath] == nil {
            photoIdByPath[photo.filepath] = photo.id
        }
        var groupByPhotoId: [String: String] = [:]
        for (index, group) in groups.enumerated() {
            guard case .array(let images)? = group["images"] else { continue }
            for image in images {
                guard case .object(let imageObj) = image,
                      let path = imageObj["path"]?.stringValue,
                      let photoId = photoIdByPath[path] else { continue }
                groupByPhotoId[photoId] = "\(resultRow.id):\(index)"
            }
        }
        return groupByPhotoId
    }
}

/// 每照片富化数据的批量装载器（无状态、Sendable；唯一依赖是 Store 协议）。
/// cullingStore 与旧服务一致为可选（老装配缺省时决策/历史栈禁用）。
public struct CullingLookupLoader: Sendable {
    /// 装载模式：.session 是整会话读（旧 mode == .session），.page 是按给定照片集读
    /// （旧 mode == .page）。Store 方法内部分块，模式只决定查询范围。
    public enum Mode: Equatable, Sendable {
        case session
        case page
    }

    private let cullingStore: (any CullingStore)?
    private let metadataStore: any MetadataStore
    private let writebackStore: any WritebackStore
    private let similarityStore: any SimilarityStore
    private let jobStore: any JobStore
    private let faceStore: any FaceStore
    private let personStore: any PersonStore

    public init(
        cullingStore: (any CullingStore)?,
        metadataStore: any MetadataStore,
        writebackStore: any WritebackStore,
        similarityStore: any SimilarityStore,
        jobStore: any JobStore,
        faceStore: any FaceStore,
        personStore: any PersonStore
    ) {
        self.cullingStore = cullingStore
        self.metadataStore = metadataStore
        self.writebackStore = writebackStore
        self.similarityStore = similarityStore
        self.jobStore = jobStore
        self.faceStore = faceStore
        self.personStore = personStore
    }

    // MARK: - 决策行

    /// TS: buildRichLookup 的 decisions 段 —— 会话全量（decisionsFull）或按照片
    /// （decisions，内部分块）读决策行，photoId 键控。
    public func loadDecisions(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: Mode
    ) async throws -> [String: CullingDecisionRecord] {
        let rows: [CullingDecisionRecord]
        switch mode {
        case .session:
            rows = try await cullingStore?.decisionsFull(sessionId: sessionId) ?? []
        case .page:
            rows = try await cullingStore?.decisions(sessionId: sessionId, photoIds: photos.map(\.id)) ?? []
        }
        // (session_id, photo_id) 是主键，photoId 唯一；重复即数据损坏。
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.photoId, $0) })
    }

    // MARK: - 元数据缓存

    /// TS: buildRichLookup 的 cacheRows 段 —— metadataBatch（内部分块）。
    public func loadMetadata(photoIds: [String]) async throws -> [String: MetadataCacheRecord] {
        guard !photoIds.isEmpty else { return [:] }
        let rows = try await metadataStore.metadataBatch(photoIds: photoIds)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.photoId, $0) })
    }

    // MARK: - outbox

    /// TS: buildRichLookup 的 outbox 段 —— 会话全量或按页照片的 xmp 路径（Store 分块，
    /// 500/块）。xmpPath 键控。
    public func loadOutbox(
        sessionId: String,
        photos: [CullingPhotoRow],
        mode: Mode
    ) async throws -> [String: OutboxRecord] {
        switch mode {
        case .session:
            let rows = try await writebackStore.outboxEntries(sessionId: sessionId)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.xmpPath, $0) })
        case .page:
            return try await loadOutbox(
                sessionId: sessionId,
                xmpPaths: photos.map { TSPath.xmpSidecarPath($0.filepath) }
            )
        }
    }

    /// TS: loadOutboxByPaths —— 按 xmp 路径批量读 outbox 行（Store 内去重分块）。
    public func loadOutbox(sessionId: String, xmpPaths: [String]) async throws -> [String: OutboxRecord] {
        guard !xmpPaths.isEmpty else { return [:] }
        let rows = try await writebackStore.outboxEntries(sessionId: sessionId, xmpPaths: xmpPaths)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.xmpPath, $0) })
    }

    // MARK: - 相似度

    /// TS: getLatestSimilarityMap —— 最新非预计算相似度结果的 photoId → "resultId:index"。
    public func loadLatestSimilarity(sessionId: String) async throws -> [String: String] {
        try await loadSessionLookup(sessionId: sessionId).similarityMap
    }

    /// TS: getSessionLookup —— 最新相似度结果行 + 由其派生的版本键控查询。
    /// 返回纯值条目（无 TTL / 无可变共享）：调用方（CullingRuntime）负责写入
    /// CullingSessionCache 并在 index_seq / resultId 变化时重建。
    /// groupIndex 初值与旧实现一致：成员映射非空时它本身就是组索引（已解析）；
    /// 空映射时 groupIndexResolved = false，由调用方回退 groups_json 解析。
    public func loadSessionLookup(sessionId: String) async throws -> CullingSessionCache.Lookup {
        let resultRow = try await similarityStore.latestResult(sessionId: sessionId)
        let similarityMap: [String: String]
        if let resultRow {
            similarityMap = try await similarityStore.photoGroupMap(
                sessionId: sessionId, resultId: resultRow.id
            )
        } else {
            similarityMap = [:]
        }
        return CullingSessionCache.Lookup(
            resultRow: resultRow,
            similarityMap: similarityMap,
            groupIndex: similarityMap.isEmpty ? [:] : similarityMap,
            groupIndexResolved: !similarityMap.isEmpty,
            analysesLoaded: false,
            qualityByPhoto: [:],
            facesByPhoto: [:],
            analysisMaxByPhoto: [:],
            peopleByPhoto: [:],
            groupCount: 0,
            groupCountResolved: false
        )
    }

    // MARK: - 分析（质量 / 人脸 / 人物）

    /// TS: loadQualityByPhoto + loadFaces + loadPeople —— 三个批量读一次装载。
    public func loadAnalyses(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: Mode
    ) async throws -> CullingLookupAnalyses {
        _ = mode // 两种模式经 Store 批量读等价（分块在 Store 内）；保留参数与旧签名对齐。
        let photoIds = photos.map(\.id)
        let qualityByPhoto = try await loadQualityByPhoto(photoIds: photoIds)
        let faces = try await loadFaces(photoIds: photoIds, sessionId: sessionId)
        let peopleByPhoto = try await loadPeople(photoIds: photoIds, sessionId: sessionId)
        return CullingLookupAnalyses(
            qualityByPhoto: qualityByPhoto,
            facesByPhoto: faces.facesByPhoto,
            analysisMaxByPhoto: faces.analysisMaxByPhoto,
            peopleByPhoto: peopleByPhoto
        )
    }

    /// TS: loadQualityByPhoto —— technical_quality 分析行 → 每照片质量对象。
    /// 行序为 updated_at DESC（Store 契约），首行即最新。
    private func loadQualityByPhoto(photoIds: [String]) async throws -> [String: CullingQuality] {
        guard !photoIds.isEmpty else { return [:] }
        var qualityByPhoto: [String: CullingQuality] = [:]
        for row in try await jobStore.technicalQualityRows(photoIds: photoIds) {
            // 显式忽略损坏的历史分析行（TS try/catch；非数据库错误）。
            guard let parsed = try? JSONValue.parse(row.resultJSON),
                  case .object(let dict) = parsed,
                  qualityByPhoto[row.requestedPhotoId] == nil else { continue }
            qualityByPhoto[row.requestedPhotoId] = CullingQuality(
                status: CullingQualityStatus(rawValue: dict["status"]?.stringValue ?? "succeeded")
                    ?? .succeeded,
                score: dict["qualityScore"]?.numberValue ?? 0,
                sharpness: dict["sharpness"]?.numberValue ?? 0,
                exposure: dict["exposure"]?.numberValue ?? 0,
                subjectSharpness: dict["subjectSharpness"]?.numberValue,
                closedEyeRisk: dict["closedEyeRisk"]?.numberValue
                    ?? dict["closedEyeProbability"]?.numberValue,
                closedEyeProbability: dict["closedEyeProbability"]?.numberValue,
                confidence: dict["confidence"]?.numberValue,
                relativeRank: dict["relativeRank"]?.numberValue,
                errorMessage: dict["errorMessage"]?.stringValue,
                warnings: dict["warnings"]?.arrayValue ?? []
            )
        }
        return qualityByPhoto
    }

    /// TS: loadFaces —— 人脸观测（bbox + 分析签名里的 previewMaxDimension）。
    /// Store 行序为 id 升序（每照片首个可解析签名决定 analysisMax）。
    private func loadFaces(
        photoIds: [String],
        sessionId: String
    ) async throws -> (facesByPhoto: [String: [[Double]]], analysisMaxByPhoto: [String: Double]) {
        guard !photoIds.isEmpty else { return ([:], [:]) }
        let faceRows = try await faceStore.observationsLite(sessionId: sessionId, photoIds: photoIds)
        var facesByPhoto: [String: [[Double]]] = [:]
        var analysisMaxByPhoto: [String: Double] = [:]
        for face in faceRows {
            facesByPhoto[face.photoId, default: []].append(face.bbox)
            if analysisMaxByPhoto[face.photoId] == nil {
                // 老观测早于持久化分析签名：显式退化为「无 max」（TS try/catch）。
                if let parsed = try? JSONValue.parse(face.analysisSignature),
                   case .object(let dict) = parsed,
                   let value = dict["previewMaxDimension"]?.numberValue,
                   value.isFinite {
                    analysisMaxByPhoto[face.photoId] = value
                }
            }
        }
        return (facesByPhoto, analysisMaxByPhoto)
    }

    /// TS: loadPeople —— 人物 → 照片映射（Store 按 p.name 排序；保序去重）。
    private func loadPeople(
        photoIds: [String],
        sessionId: String
    ) async throws -> [String: [String]] {
        guard !photoIds.isEmpty else { return [:] }
        let personRows = try await personStore.personNamesByPhoto(sessionId: sessionId, photoIds: photoIds)
        var peopleByPhoto: [String: [String]] = [:]
        for person in personRows {
            var names = peopleByPhoto[person.photoId] ?? []
            if !names.contains(person.name) { names.append(person.name) }
            peopleByPhoto[person.photoId] = names
        }
        return peopleByPhoto
    }

    // MARK: - summary 轻投影

    /// TS: loadSummaryCacheByPhoto —— rating/label 轻投影（跳过 keywords 重列）。
    public func loadSummaryCache(photoIds: [String]) async throws -> [String: (rating: Int64, label: String?)] {
        guard !photoIds.isEmpty else { return [:] }
        var cacheByPhoto: [String: (rating: Int64, label: String?)] = [:]
        for row in try await metadataStore.ratingLabels(photoIds: photoIds) {
            cacheByPhoto[row.photoId] = (row.rating, row.label)
        }
        return cacheByPhoto
    }

    // MARK: - 页模式富查询

    /// TS: buildRichLookup（mode == .page）—— 页内照片的全部富化查询。
    /// 会话级分析不经缓存（每页范围查询，旧语义）。
    public func loadPageLookup(
        photos: [CullingPhotoRow],
        sessionId: String
    ) async throws -> CullingAssetLookup {
        let decisions = try await loadDecisions(photos: photos, sessionId: sessionId, mode: .page)
        let cacheRows = try await loadMetadata(photoIds: photos.map(\.id))
        let outboxByPath = try await loadOutbox(sessionId: sessionId, photos: photos, mode: .page)
        let similarityMap = try await loadLatestSimilarity(sessionId: sessionId)
        let analyses = try await loadAnalyses(photos: photos, sessionId: sessionId, mode: .page)
        return CullingAssetLookup(
            decisions: decisions,
            cacheRows: cacheRows,
            outboxByPath: outboxByPath,
            similarityMap: similarityMap,
            qualityByPhoto: CullingAssembler.applyRelativeRank(
                analyses.qualityByPhoto, similarityMap: similarityMap),
            facesByPhoto: analyses.facesByPhoto,
            analysisMaxByPhoto: analyses.analysisMaxByPhoto,
            peopleByPhoto: analyses.peopleByPhoto,
            linkedCounts: Self.linkedCounts(photos)
        )
    }

    /// TS: buildRichLookup 的 linkedCounts 段 —— xmpPath → 共享该侧车的照片数。
    public static func linkedCounts(_ photos: [CullingPhotoRow]) -> [String: Int] {
        var linkedCounts: [String: Int] = [:]
        for photo in photos {
            linkedCounts[TSPath.xmpSidecarPath(photo.filepath), default: 0] += 1
        }
        return linkedCounts
    }
}
