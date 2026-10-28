// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Queries.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// 读模型：资产列表/分组/历史/摘要 + 富查询装配与状态投影。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    // MARK: - 列表

    /// TS: list —— 会话全量资产列表。
    public func list(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil
    ) throws -> [CullingAsset] {
        // P1：只列仍在工作区的照片（归档件从所有列表/代表行消失）。
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }
            .map { CullingPhotoRow(row: $0) }
        let lookup = try buildRichLookup(photos: photos, sessionId: sessionId, mode: .session)
        return filterVisible(
            assembleAssets(photos: photos, lookup: lookup),
            scope: scope,
            filters: filters,
            requestedGroupId: requestedGroupId,
            conflictingPhotoPaths: try conflictPhotoPaths(sessionId: sessionId, filters: filters)
        )
    }
    /// TS: getGroups —— 相似度分组（决策计数 + 成员轻投影）。
    public func getGroups(sessionId: String) throws -> [CullingGroup] {
        guard let resultRow = try similarityResultRepo.getLatest(sessionId: sessionId) else {
            return []
        }
        // 轻投影：只取 id/filepath/filename，重 JSON 列跳过；归档变体不参与组结构。
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }
            .map { CullingPhotoRow(row: $0) }
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let membership = try similarityResultRepo.getPhotoGroupMap(sessionId: sessionId, resultId: resultRow.id)
        let originalCounts = try similarityResultRepo.groupMemberCounts(
            sessionId: sessionId, resultId: resultRow.id)
        var membersByGroup: [String: [String]] = [:]
        for photo in photos {
            guard let groupId = membership[photo.id] else { continue }
            membersByGroup[groupId, default: []].append(photo.id)
        }
        let decisions = Dictionary(
            uniqueKeysWithValues: try cullingDecisionRepo.getBySession(sessionId)
                .map { ($0.photoId, $0.decision) }
        )

        var groups: [(index: Int, insertion: Int, group: CullingGroup)] = []
        var insertion = 0
        for (groupId, photoIds) in membersByGroup {
            // 损坏的遗留成员行不得产生打乱组排序的 NaN 键。
            let parsedIndex = Int(groupId.split(separator: ":").last ?? "") ?? 0
            var keepCount = 0
            var rejectCount = 0
            var pendingCount = 0
            var images: [CullingImage] = []
            for photoId in photoIds {
                guard let photo = photoById[photoId] else { continue }
                let decision = decisions[photoId] ?? "pending"
                if decision == "keep" { keepCount += 1 }
                else if decision == "reject" { rejectCount += 1 }
                else { pendingCount += 1 }
                images.append(CullingImage(
                    photoId: photoId,
                    filepath: photo.filepath,
                    filename: photo.filename,
                    decision: CullingDecisionValue(rawValue: decision) ?? .pending
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
            insertion += 1
        }
        // 稳定排序（TS Array.sort 稳定；Swift sort 不保证稳定，同索引时按首见序）。
        // P1：只剩 1 个可见成员的组不具备"相似组"语义（决策要求 ≥2 张），直接隐藏；
        // 否则用户会看到一个无法决策的幽灵组。
        return groups
            .filter { entry in
                // 归档导致成员不足才隐藏；minGroupSize=1 的合法单成员组保留。
                let original = originalCounts[entry.group.groupIndex] ?? entry.group.images.count
                return entry.group.images.count >= 2 || original < 2
            }
            .sorted { $0.index == $1.index ? $0.insertion < $1.insertion : $0.index < $1.index }
            .map(\.group)
    }
    /// TS: getDecisions —— 写回计划的决策输入（photo_id, decision）。
    public func getDecisions(sessionId: String) throws -> [CullingDecisionLiteRow] {
        try cullingDecisionRepo.getDecisions(sessionId)
    }
    /// TS: getHistory —— 历史栈（limit 缺省 100，仓库内 clamp 到 500）。
    ///
    /// 契约：返回数组（id DESC）**必然包含当前 undo/redo 栈顶**——窗口外只剩栈顶
    /// 时把它补进来。读取方据此可以用「MAX(id) 未撤销 / MIN(id) 已撤销」这条唯一
    /// 规则推导按钮可用性与目标操作；旧实现只给最近 limit 条，深度撤销后重做栈顶
    /// 落在窗口外，UI 会误报「没有可撤销/可重做的挑片操作」。
    public func getHistory(sessionId: String, limit: Int = 100) throws -> [CullingHistoryOperation] {
        guard let cullingHistoryRepo else { return [] }
        var operations = try cullingHistoryRepo.list(sessionId: sessionId, limit: limit)
        let tops = try cullingHistoryRepo.stackTops(sessionId: sessionId)
        let loaded = Set(operations.map(\.id))
        var extras: [CullingHistoryOperation] = []
        for id in [tops.undoId, tops.redoId].compactMap({ $0 }) where !loaded.contains(id) {
            if let operation = try cullingHistoryRepo.get(sessionId: sessionId, operationId: id) {
                extras.append(operation)
            }
        }
        if !extras.isEmpty {
            operations = (operations + extras).sorted { $0.id > $1.id }
        }
        return operations
    }
    /// 首屏摘要：SQL 聚合（20k 不搬全量 photos/decisions/cache）。
    public func getSummary(sessionId: String) throws -> CullingSummary {
        let lookup = try getSessionLookup(sessionId: sessionId)
        var totalGroups = 0
        if let resultRow = lookup.resultRow {
            // 契约：总组数来自相似度 stats_json（分析快照）；只扣掉"成员全部归档"
            // 的组，避免整组移出后摘要仍显示旧组数（部分归档不改动快照口径）。
            totalGroups = max(
                0,
                parseTotalGroups(resultRow)
                    - (try similarityResultRepo.countFullyArchivedGroups(
                        sessionId: sessionId, resultId: resultRow.id))
            )
        }
        let labels = Self.colorLabels.filter { $0 != .none }.map(\.rawValue).sorted()
        let counts = try richQuery.summaryCounts(sessionId: sessionId, colorLabels: labels)
        return CullingSummary(
            totalGroups: totalGroups,
            totalPhotos: counts.totalPhotos,
            kept: counts.kept,
            rejected: counts.rejected,
            pending: max(0, counts.totalPhotos - counts.kept - counts.rejected),
            rated: counts.rated,
            labeled: counts.labeled
        )
    }
    // MARK: - 富查询（TS buildRichLookup 及支撑）

    /// 交付项的 module → 旧 MetadataMutationSource 投影（每个 sidecar 取最近更新的 item）。
    ///
    /// 旧 outbox 的 patch_json.source 已无生产写入；V1 的归属由
    /// delivery_items.module 结构化表达（schema-v1-draft §5.3-3）。module 值不在
    /// MetadataMutationSource 里（如 "metadata"）时留空，不伪造来源。
    func loadDeliveryMetadataSourceByPath(
        xmpPaths: [String]
    ) throws -> [String: MetadataMutationSource] {
        let unique = Array(Set(xmpPaths))
        guard !unique.isEmpty else { return [:] }
        let rows = try richQuery.deliveryModuleRows(xmpPaths: unique)
        var result: [String: MetadataMutationSource] = [:]
        // 每个 sidecar 取最近更新的 item（SQL 已按 updated_at DESC, id DESC 排序）。
        for row in rows where result[row.xmpPath] == nil {
            result[row.xmpPath] = MetadataMutationSource(rawValue: row.module)
        }
        return result
    }

    /// P0 / T0：triage_suggestions → gid 建议。损坏 reasons 跳过（不伪造建议）。
    /// 门控匹配的行才进入资产（stale/旧策略不展示，契约 §4.3）。
    func loadTriageByAsset(
        sessionId: String,
        photoIds: [String]? = nil,
        policy: TriageDisplayPolicy?
    ) throws -> [String: TriageSuggestion] {
        guard policy != .hidden else { return [:] }
        var gate: TriageSuggestionGate?
        if case .matching(let value) = policy { gate = value }
        var result: [String: TriageSuggestion] = [:]
        let decoder = JSONDecoder()
        let rows = if let photoIds {
            try richQuery.triageRows(sessionId: sessionId, photoIds: photoIds)
        } else {
            try richQuery.triageRows(sessionId: sessionId)
        }
        for row in rows {
            guard let verdict = TriageVerdict(rawValue: row.verdict) else { continue }
            if let gate,
               row.inputFingerprint != gate.fingerprint
                   || row.policyVersion != gate.policyVersion {
                continue
            }
            let reasons: [TriageReason]
            do {
                reasons = try decoder.decode(
                    [TriageReason].self, from: Data(row.reasonsJSON.utf8))
            } catch {
                GatherLogger.log(
                    "triage reasons decode failed photo=\(row.photoId)", level: .warn)
                continue
            }
            result[row.gid] = TriageSuggestion(
                photoId: row.photoId,
                verdict: verdict,
                score: row.score,
                confidence: row.confidence,
                reasons: reasons,
                groupId: row.groupId,
                policyVersion: row.policyVersion,
                inputFingerprint: row.inputFingerprint,
                computedAt: row.computedAt
            )
        }
        return result
    }

    /// TS: loadQualityByPhoto —— technical_quality 分析行 → 每照片质量对象。
    func loadQualityByPhoto(photos: [CullingPhotoRow]) throws -> [String: CullingQuality] {
        var qualityByPhoto: [String: CullingQuality] = [:]
        if photos.isEmpty { return qualityByPhoto }
        let qualityRows = try richQuery.qualityRows(photoIds: photos.map(\.id))
        for row in qualityRows {
            // 忽略损坏的历史分析行（TS try/catch）。
            guard let parsed = try? JSONValue.parse(row.resultJSON),
                  case .object(let dict) = parsed,
                  qualityByPhoto[row.photoId] == nil else { continue }
            qualityByPhoto[row.photoId] = CullingQuality(
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
    func loadFaces(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: LookupMode
    ) throws -> (facesByPhoto: [String: [[Double]]], analysisMaxByPhoto: [String: Double]) {
        struct FaceRow {
            let photoId: String
            let bbox: [Double]
            let analysisSignature: String
        }
        let faceRows: [CullingFaceObservationRow] = mode == .session
            ? try richQuery.faceRows(sessionId: sessionId)
            : try richQuery.faceRows(sessionId: sessionId, photoIds: photos.map(\.id))
        var facesByPhoto: [String: [[Double]]] = [:]
        var analysisMaxByPhoto: [String: Double] = [:]
        for face in faceRows {
            facesByPhoto[face.photoId, default: []].append(face.bbox)
            if analysisMaxByPhoto[face.photoId] == nil {
                // 老观测早于持久化分析签名（TS try/catch）。
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

    /// TS: loadPeople —— 人物 → 照片映射（按名排序，去重）。
    func loadPeople(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: LookupMode
    ) throws -> [String: [String]] {
        let personRows: [CullingPersonNameRow] = mode == .session
            ? try richQuery.personRows(sessionId: sessionId)
            : try richQuery.personRows(sessionId: sessionId, photoIds: photos.map(\.id))
        var peopleByPhoto: [String: [String]] = [:]
        for person in personRows {
            var names = peopleByPhoto[person.photoId] ?? []
            if !names.contains(person.name) { names.append(person.name) }
            peopleByPhoto[person.photoId] = names
        }
        return peopleByPhoto
    }

    /// TS: buildRichLookup —— 把原始照片集合富化为 CullingAssets 所需的全部
    /// 每照片查询。
    func buildRichLookup(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: LookupMode
    ) throws -> CullingRichLookup {
        let photoIds = photos.map(\.id)
        let decisions = Dictionary(
            uniqueKeysWithValues: try (mode == .session
                ? cullingDecisionRepo.getBySession(sessionId)
                : cullingDecisionRepo.getByPhotoIds(sessionId: sessionId, photoIds: photoIds))
                .map { ($0.photoId, $0) }
        )
        let cacheRows = Dictionary(
            uniqueKeysWithValues: try metadataCacheRepo.getBatch(photoIds)
                .map { ($0.photoId, $0) }
        )
        // 同步态读交付行（不再读旧 outbox）：一次 IN 查询覆盖本次页/会话的照片；
        // 交付项 module 投影成旧 MetadataMutationSource 供 UI 显示来源。
        let xmpPaths = photos.map { DeliveryPath.sidecar($0.filepath) }
        let deliveryByPath = try deliveryItems.getMany(xmpPaths: xmpPaths)
        let metadataSourceByPath = try loadDeliveryMetadataSourceByPath(xmpPaths: xmpPaths)
        let similarityMap = try getLatestSimilarityMap(sessionId: sessionId)
        let displayPolicy = try triageDisplayPolicy?(sessionId)
        var triageByAsset = try loadTriageByAsset(
            sessionId: sessionId,
            photoIds: mode == .session ? nil : photoIds,
            policy: displayPolicy
        )
        // 人工决策过的逻辑资产不展示建议（契约：已人工决策 = nil），
        // 避免“手动改选后网格仍显示旧淘汰徽标”。
        if !triageByAsset.isEmpty {
            for photo in photos {
                guard let decision = decisions[photo.id],
                      decision.decisionSource == CullingDecisionSource.manual.rawValue,
                      decision.decision != CullingDecisionValue.pending.rawValue
                else { continue }
                let gid = photo.assetId.flatMap { $0.isEmpty ? nil : $0 } ?? photo.id
                triageByAsset.removeValue(forKey: gid)
            }
        }
        // 会话级分析表（质量/人脸/人物）只被后台分析重写，故会话模式复用
        // 版本键控缓存而不是每次调用全量重读；页模式保持每页范围查询。
        let sessionLookup = try getSessionLookup(sessionId: sessionId)
        var qualityByPhoto: [String: CullingQuality]
        let facesByPhoto: [String: [[Double]]]
        let analysisMaxByPhoto: [String: Double]
        let peopleByPhoto: [String: [String]]
        if mode == .session {
            if !sessionLookup.analysesLoaded {
                sessionLookup.analysesLoaded = true
                sessionLookup.qualityByPhoto = try loadQualityByPhoto(photos: photos)
                let faces = try loadFaces(photos: photos, sessionId: sessionId, mode: .session)
                sessionLookup.facesByPhoto = faces.facesByPhoto
                sessionLookup.analysisMaxByPhoto = faces.analysisMaxByPhoto
                sessionLookup.peopleByPhoto = try loadPeople(photos: photos, sessionId: sessionId, mode: .session)
            }
            qualityByPhoto = sessionLookup.qualityByPhoto
            facesByPhoto = sessionLookup.facesByPhoto
            analysisMaxByPhoto = sessionLookup.analysisMaxByPhoto
            peopleByPhoto = sessionLookup.peopleByPhoto
        } else {
            qualityByPhoto = try loadQualityByPhoto(photos: photos)
            let faces = try loadFaces(photos: photos, sessionId: sessionId, mode: .page)
            facesByPhoto = faces.facesByPhoto
            analysisMaxByPhoto = faces.analysisMaxByPhoto
            peopleByPhoto = try loadPeople(photos: photos, sessionId: sessionId, mode: .page)
        }
        var linkedCounts: [String: Int] = [:]
        for photo in photos {
            let xmpPath = DeliveryPath.sidecar(photo.filepath)
            linkedCounts[xmpPath, default: 0] += 1
        }

        // 组内相对排名：同一相似度组内成功质量按分数降序 → 1 起排名。TS 原地
        // 改 qualityByPhoto 里的对象引用；Swift 值类型按 photoId 回写。
        var qualityGroups: [String: [(photoId: String, quality: CullingQuality)]] = [:]
        for (photoId, quality) in qualityByPhoto {
            guard let groupId = similarityMap[photoId],
                  quality.status == .succeeded else { continue }
            qualityGroups[groupId, default: []].append((photoId, quality))
        }
        for (_, members) in qualityGroups {
            let sorted = members.sorted { $0.quality.score > $1.quality.score }
            for (index, member) in sorted.enumerated() {
                guard var updated = qualityByPhoto[member.photoId] else { continue }
                updated.relativeRank = Double(index + 1)
                qualityByPhoto[member.photoId] = updated
            }
        }
        return CullingRichLookup(
            decisions: decisions,
            cacheRows: cacheRows,
            deliveryByPath: deliveryByPath,
            metadataSourceByPath: metadataSourceByPath,
            similarityMap: similarityMap,
            qualityByPhoto: qualityByPhoto,
            triageByAsset: triageByAsset,
            facesByPhoto: facesByPhoto,
            analysisMaxByPhoto: analysisMaxByPhoto,
            peopleByPhoto: peopleByPhoto,
            linkedCounts: linkedCounts
        )
    }

    /// TS: assembleAssets —— 富化 + 按逻辑资产分组 + RAW 优先折叠变体。
    func assembleAssets(
        photos: [CullingPhotoRow],
        lookup: CullingRichLookup
    ) -> [CullingAsset] {
        let assets: [CullingAsset] = photos.map { photo in
            let decision = lookup.decisions[photo.id]
            let cache = lookup.cacheRows[photo.id]
            let xmpPath = DeliveryPath.sidecar(photo.filepath)
            let deliveryStatus = lookup.deliveryByPath[xmpPath]?.typedStatus
            // 来源由交付项 module 投影（旧 outbox patch_json.source 已无生产写入）。
            let metadataSource = lookup.metadataSourceByPath[xmpPath]
            let keywords: [String] = cache?.keywords ?? []
            let triageGid = (photo.assetId?.isEmpty == false ? photo.assetId! : photo.id)
            let sourceWidth = max(1, photo.width)
            let sourceHeight = max(1, photo.height)
            let analysisMax = lookup.analysisMaxByPhoto[photo.id]
                ?? max(
                    getNumber("detect_input_size", 640),
                    getNumber("face_preview_max_dimension", 2048)
                )
            let analysisScale = min(1, analysisMax / Double(max(sourceWidth, sourceHeight)))
            let analysisWidth = Double(sourceWidth) * analysisScale
            let analysisHeight = Double(sourceHeight) * analysisScale
            // 当前检测器观测已归一化。老数据库存的是预览像素坐标，为范围外的
            // 值保留有界的兼容换算（TS 注释逐字语义）。
            let normalizedFaces = (lookup.facesByPhoto[photo.id] ?? []).map { face in
                let alreadyNormalized = face.count >= 4
                    && face[0] >= 0 && face[1] >= 0 && face[2] >= 0 && face[3] >= 0
                    && face[0] <= 1 && face[1] <= 1 && face[2] <= 1 && face[3] <= 1
                let values = alreadyNormalized
                    ? face
                    : [face[0] / analysisWidth, face[1] / analysisHeight,
                       face[2] / analysisWidth, face[3] / analysisHeight]
                return values.map { min(1, max(0, $0)) }
            }.sorted { ($0[2] * $0[3]) > ($1[2] * $1[3]) }

            return CullingAsset(
                photo: photoRowToData(
                    photo,
                    faceCount: lookup.facesByPhoto[photo.id]?.count ?? 0
                ),
                state: rowToState(
                    photoId: photo.id,
                    decisionRow: decision,
                    cachedRating: cache?.rating ?? 0,
                    cachedLabel: cache?.label
                ),
                xmpPath: xmpPath,
                syncStatus: deliveryStatus.map { Self.syncStatus(from: $0) } ?? .clean,
                people: lookup.peopleByPhoto[photo.id] ?? [],
                keywords: keywords,
                similarityGroupId: lookup.similarityMap[photo.id],
                linkedVariantCount: lookup.linkedCounts[xmpPath] ?? 1,
                faceBboxes: normalizedFaces,
                quality: lookup.qualityByPhoto[photo.id],
                triage: lookup.triageByAsset[triageGid],
                metadataSource: metadataSource
            )
        }

        // 按逻辑资产 id 单遍分组（替代整数组每组的过滤，大会话下 O(n²)）。
        // TS 的 Map 保插入序；Swift Dictionary.values 顺序不定，故显式维护
        // 首见顺序，资产顺序与 TS `[...assetsByAssetId.values()]` 一致。
        var assetsByAssetId: [String: [CullingAsset]] = [:]
        var assetIdOrder: [String] = []
        for asset in assets {
            let assetId = asset.photo.assetId ?? "photo:\(asset.photo.id)"
            if assetsByAssetId[assetId] == nil { assetIdOrder.append(assetId) }
            assetsByAssetId[assetId, default: []].append(asset)
        }
        return assetIdOrder.compactMap { assetsByAssetId[$0] }.map { variants in
            // 代表行=「RAW 变体优先，其次最小 rowid」，与 SQL 的
            // PhotoRepo.preferredRowOrderSQL 是同一条规则，这里是它的内存态实现：
            // 输入数组按 rowid 升序（getBySession / getAssetPage / loadAssetRows 都
            // 是），故「首个 RAW，否则首个」≡「RAW 优先，其次最小 rowid」。
            // 不能直接调用 SQL 排序的原因：list() 走 getBySession 全量读、不经过
            // 任何组查询（scope: .all 的分页也不选代表行），shared 规则只有 SQL 串
            // 形态；RAW 判定本身已复用共享表 PhotoRepo.rawExtensions。
            // 两条路径的一致性由 CullingRepresentativeRowRuleTests 双向钉住
            //（list 与 filtered 分页在 JPEG 先入时都必须给 RAW）。
            let preferred = variants.first(where: {
                isPreferredRawVariant(filename: $0.photo.filename)
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

    /// TS: filterVisible —— SQL 下推之上的最终安全网。已下推的过滤器
    /// （pick/rating/label/quality/similarity/metadataConflictOnly）SQL 谓词已作用
    /// 在首选行，此 JS 遍恒通过（同一 photo_path 判定规则，见 conflictPhotoPaths）。
    func filterVisible(
        _ assets: [CullingAsset],
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        conflictingPhotoPaths: Set<String>
    ) -> [CullingAsset] {
        assets.filter { asset in
            if scope == .similarityGroup {
                guard let similarityGroupId = asset.similarityGroupId else { return false }
                if let requestedGroupId, similarityGroupId != requestedGroupId { return false }
            }
            return scope != .filtered
                || matchesFilters(asset, filters: filters, conflictingPhotoPaths: conflictingPhotoPaths)
        }
    }

    /// TS: matchesFilters。
    /// metadataConflictOnly 与 SQL 下推用**同一条规则**：该资产首选变体的 photo_path
    /// 存在 status='conflict' 的 outbox 行。用 syncStatus（每资产首选的 sidecar 行）会让
    /// 两遍在「变体与首选不同行」时发散，故这里显式用同一集合。
    func matchesFilters(
        _ asset: CullingAsset,
        filters: CullingFilters?,
        conflictingPhotoPaths: Set<String>
    ) -> Bool {
        guard let filters else { return true }
        if filters.unreviewedOnly == true && asset.state.pickState != .unreviewed { return false }
        if let ratings = filters.ratings, !ratings.isEmpty,
           !ratings.contains(asset.state.rating) { return false }
        if let pickStates = filters.pickStates, !pickStates.isEmpty,
           !pickStates.contains(asset.state.pickState) { return false }
        if let colorLabels = filters.colorLabels, !colorLabels.isEmpty,
           !colorLabels.contains(asset.state.colorLabel) { return false }
        if filters.qualityStatus == .analysed && asset.quality?.status != .succeeded { return false }
        if filters.qualityStatus == .failed && asset.quality?.status != .failed { return false }
        if filters.qualityStatus == .unanalysed && asset.quality != nil { return false }
        if filters.metadataConflictOnly == true
            && !conflictingPhotoPaths.contains(asset.photo.filepath) { return false }
        return true
    }

    /// metadataConflictOnly 的冲突照片路径集合（SQL 下推与 JS 安全网共用的唯一规则）。
    /// 冲突态读统一交付模型（deliveries.status='conflict'），未启用该过滤时返回空集合。
    func conflictPhotoPaths(
        sessionId: String,
        filters: CullingFilters?
    ) throws -> Set<String> {
        guard filters?.metadataConflictOnly == true else { return [] }
        return try richQuery.conflictPhotoPaths(sessionId: sessionId)
    }
    // MARK: - Summary 支撑

    /// TS: parseTotalGroups —— 相似度结果行的组计数。当前管线把 totalGroups 写进
    /// 小的 stats_json 对象，多 MB 的 groups_json 只为旧行解析。损坏行退化为 0
    /// （与旧 groups_json 解析相同）。
    func parseTotalGroups(_ resultRow: SimilarityResultRow) -> Int {
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
    /// TS: rowToState —— 决策行（取舍/版本/来源）+ 唯一真相源（星级/色标）→
    /// AssetCullingState。
    ///
    /// 禁止在决策行存在时改读 row.rating / row.colorLabel：那两列是镜像列，
    /// 读取它们等于恢复「读 A 走 B」的双真相源（见文件头注）。
    func rowToState(
        photoId: String,
        decisionRow: CullingDecisionRow?,
        cachedRating: Int64,
        cachedLabel: String?
    ) -> AssetCullingState {
        let rating = (0...5).contains(cachedRating) ? cachedRating : 0
        return AssetCullingState(
            photoId: photoId,
            pickState: decisionToPickState(decisionRow?.decision),
            rating: Double(rating),
            colorLabel: Self.colorLabel(cachedLabel),
            source: sourceFromDecisionRow(decisionRow),
            revision: Int(decisionRow?.revision ?? 0),
            updatedAt: decisionRow?.updatedAt ?? ""
        )
    }

    /// 合法色标解析：nil / 未知 / 非法值一律归 .none（唯一真相源里可能有历史脏值）。
    static func colorLabel(_ raw: String?) -> CaptureOneColorLabel {
        guard let raw, let parsed = CaptureOneColorLabel(rawValue: raw),
              colorLabels.contains(parsed) else { return .none }
        return parsed
    }
    /// TS: rowToState 的 source 分支（决策行存在时取合法 decision_source，缺省
    /// manual；行缺失时为 imported）。
    private func sourceFromDecisionRow(_ row: CullingDecisionRow?) -> CullingDecisionSource {
        guard let row else { return .imported }
        return CullingDecisionSource(rawValue: row.decisionSource) ?? .manual
    }
    /// TS: decisionToPickState。
    private func decisionToPickState(_ decision: String?) -> PickState {
        switch decision {
        case "keep": .picked
        case "reject": .rejected
        default: .unreviewed
        }
    }
    /// TS: photoRowToData —— 照片行 → PhotoData。
    /// V1 的 photos 不再有 metadata/result 列（Cut 2 S5a）：PhotoData 的这两个
    /// 字段保留为协议形状，但不再从行读，恒为空对象（UI 亦不消费它们）。
    private func photoRowToData(_ row: CullingPhotoRow, faceCount: Int) -> PhotoData {
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
            metadata: [:],
            result: [:],
            status: row.status,
            assetId: row.assetId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// TS: isPreferredRawVariant —— 首选 RAW 变体探测（小写扩展名集合的 O(1)
    /// 探测替代 per-candidate `some(...endsWith)` 扫描）。扩展名表来自共享的
    /// PhotoRepo.rawExtensions，与 preferredRowOrderSQL 的 LIKE 链同源。
    private func isPreferredRawVariant(filename: String) -> Bool {
        let lower = filename.lowercased()
        guard let dot = lower.lastIndex(of: ".") else { return false }
        return Self.preferredRawExtensions.contains(String(lower[dot...]))
    }
}
