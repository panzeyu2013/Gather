// WP5b：FaceKwService 拆分（纯移动，行为不变）——Review（簇审阅/绑定/匹配）。
// 源：HEAD 95f0075 的 Services/FaceKwService.swift；仅调整跨文件访问级。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension FaceKwService {
    /// TS: getClusters（fkw.clusters）。成员截断至预览窗口，size 保持精确总数。
    /// 建议字段：matchedPersonId 来自 face_clusters 匹配列，名字按身份批量解析
    /// （解析失败只丢名字，不影响簇清单）。
    public func getClusters(sessionId: String) throws -> [FaceClusterData] {
        let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
        let matchedIds = Array(Set(clusters.compactMap(\.matchedPersonId)))
        let summaries = (try? personRepo.summaries(ids: matchedIds)) ?? [:]
        return clusters.map { cluster in
            let previewMembers = Array((cluster.members ?? []).prefix(Self.maxPreviewMembers))
            return FaceClusterData(
                id: Int(cluster.id),
                sessionId: cluster.sessionId,
                label: cluster.label,
                size: Int(cluster.memberCount),
                status: cluster.status,
                // V1 已删除 face_clusters.thumbnail_base64：DTO 保留为空串，
                // 不再从行读（网格用 members 的 photoPath+bbox 裁切）。
                thumbnailBase64: "",
                binding: cluster.binding.map { FaceClusterBinding(roleName: $0.roleName, keywords: $0.keywords) },
                thumbnailPhotoId: previewMembers.first?.photoId,
                members: previewMembers.map { member in
                    ClusterMember(
                        memberId: Int(member.id),
                        photoId: member.photoId,
                        photoPath: member.photoPath,
                        filename: (member.photoPath as NSString).lastPathComponent,
                        bbox: Self.parseBbox(member.bbox),
                        confidence: member.confidence
                    )
                },
                matchedPersonId: cluster.matchedPersonId,
                matchedPersonName: cluster.matchedPersonId.flatMap { summaries[$0]?.name },
                matchConfidence: cluster.matchConfidence
            )
        }
    }

    // ─────────────────────────── 绑定 / 合并 / 成员 ───────────────────────────

    /// 批量照片的人脸观测计数（photo.id → 数量），供宿主 photo 列表分页附带
    /// faceCount（TS photo.ipc.ts assemblePhotos 的人脸计数小查询下沉）。
    public func faceCounts(sessionId: String, photoIds: [String]) throws -> [String: Int] {
        try faceRepo.countsByPhoto(sessionId: sessionId, photoIds: photoIds)
    }

    /// TS: bindCluster（fkw.bind）。绑定、人工身份约束与人物库在同一事务提交。
    public func bindCluster(sessionId: String, clusterId: Int64, roleName: String, keywords: [String]) throws {
        let clusterSessionId = try faceRepo.getClusterSessionId(clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        let normalizedRoleName = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRoleName.isEmpty { throw FaceKwServiceError.roleNameEmpty }
        // TS 的 FKW_KEYWORDS_INVALID（Array.isArray / typeof === 'string' 校验）
        // 属 JSON 契约层职责；Swift 参数类型已强约束，此处不做重复校验。
        var seen = Set<String>()
        let dedupedKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        try transactions.transaction {
            try faceRepo.updateBinding(clusterId: clusterId, roleName: normalizedRoleName, keywords: dedupedKeywords)
        // 身份链接 + 人物库投影 + 跨会话向量入库（单一身份入口 PersonRepo.bindRole
        // 负责 adopt-or-create、照片桥接与 matched_person_id 链接；随后把该簇成员的
        // 观察向量写入 person_embeddings，作为其它会话 analyze/recluster 的匹配库）。
        // 任一身份或向量写入失败会回滚绑定，避免半套身份投影。
            let members = try faceRepo.getClusterMembers(clusterId)
            let outcome = try personRepo.bindRole(
                clusterId: clusterId,
                sessionId: sessionId,
                roleName: normalizedRoleName,
                keywords: dedupedKeywords,
                members: members.map { member in
                    PersonPhotoInput(photoId: member.photoId, faceBbox: member.bbox, confidence: member.confidence)
                }
            )
            if let personId = outcome.personId {
                for member in members {
                    try self.feedback.record(sessionId: sessionId, photoId: member.photoId,
                        bbox: member.bbox, personId: personId, confirmed: true, keywords: dedupedKeywords)
                }
                let embeddings = try faceRepo.getClusterMemberEmbeddings(clusterId)
                try personRepo.saveEmbeddings(embeddings: embeddings.map { member in
                    SaveEmbeddingInput(
                        personId: personId,
                        embedding: member.embedding,
                        photoId: member.photoId,
                        sessionId: member.sessionId,
                        faceObservationId: member.observationId
                    )
                })
            }
        }
    }

    /// TS: unbindCluster（fkw.unbind 的服务层步骤；解除绑定并重算人物库）。
    public func unbindCluster(sessionId: String, clusterId: Int64) throws {
        let clusterSessionId = try faceRepo.getClusterSessionId(clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        try transactions.transaction {
            let cluster = try faceRepo.getClusters(sessionId, includeMembers: true).first { $0.id == clusterId }
            let repo = feedback
            for member in cluster?.members ?? [] {
                try repo.forgetConfirmation(sessionId: sessionId, photoId: member.photoId,
                    bbox: Self.parseBbox(member.bbox), personId: cluster?.matchedPersonId)
            }
            try faceRepo.deleteBinding(clusterId: clusterId)
            try personRepo.reconcileSession(sessionId: sessionId)
        }

    }

    /// TS: face-kw.ipc.ts fkw.unbind 全流程：确认 → 受保护关键字过滤 →
    /// removeOwnedFaceKeywords（写回）→ unbindCluster。
    public func unbind(sessionId: String, clusterId: Int64, confirmed: Bool) async throws -> FkwUnbindResult {
        guard confirmed else { throw FaceKwServiceError.unbindConfirmRequired }
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        // getClusters(includeMembers=true) 是一次昂贵的批量读；结果同时用于
        // 目标查找与剩余已绑定集群的扫描（TS 注释 133-135）。
        let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
        guard let cluster = clusters.first(where: { $0.id == clusterId }) else {
            throw FaceKwServiceError.clusterNotFound
        }
        var protectedByPath: [String: Set<String>] = [:]
        for remaining in clusters {
            if remaining.id == clusterId { continue }
            guard let binding = remaining.binding else { continue }
            for member in remaining.members ?? [] {
                let xmpPath = TSPath.xmpSidecarPath(member.photoPath)
                var protected = protectedByPath[xmpPath] ?? []
                for keyword in ([binding.roleName] + binding.keywords)
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    if !keyword.isEmpty { protected.insert(keyword) }
                }
                protectedByPath[xmpPath] = protected
            }
        }
        let roleKeywords = [cluster.binding?.roleName ?? ""] + (cluster.binding?.keywords ?? [])
        let entries = (cluster.members ?? []).map { member in
            let xmpPath = TSPath.xmpSidecarPath(member.photoPath)
            let protected = protectedByPath[xmpPath] ?? []
            let keywords = roleKeywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !protected.contains($0) }
            return FaceKeywordEntry(photoId: member.photoId, xmpPath: xmpPath, keywords: keywords)
        }
        let removedKeywords = try await writebackProvider.removeOwnedFaceKeywords(
            sessionId: sessionId, entries: entries)
        try unbindCluster(sessionId: sessionId, clusterId: clusterId)
        return FkwUnbindResult(done: true, removedKeywords: removedKeywords)
    }

    /// TS: mergeClusters（fkw.merge）。
    public func mergeClusters(sessionId: String, sourceId: Int64, targetId: Int64) throws {
        if sourceId == targetId { throw FaceKwServiceError.selfMerge }
        let sourceSessionId = try faceRepo.getClusterSessionId(sourceId)
        let targetSessionId = try faceRepo.getClusterSessionId(targetId)
        guard let sourceSessionId, let targetSessionId else { throw FaceKwServiceError.clusterNotFound }
        if sourceSessionId != sessionId || targetSessionId != sessionId {
            throw FaceKwServiceError.clusterNotInSession
        }
        try transactions.transaction {
            try faceRepo.mergeClusters(sourceId: sourceId, targetId: targetId)
            try personRepo.reconcileSession(sessionId: sessionId)
            if let target = try faceRepo.getClusters(sessionId, includeMembers: true).first(where: { $0.id == targetId }),
               let binding = target.binding, let personId = target.matchedPersonId {
                for member in target.members ?? [] {
                    try feedback.record(sessionId: sessionId, photoId: member.photoId,
                        bbox: Self.parseBbox(member.bbox), personId: personId, confirmed: true, keywords: binding.keywords)
                }
            }
        }
    }

    /// TS: removeMember（fkw.remove_member）。
    public func removeMember(sessionId: String, clusterId: Int64, memberId: Int64) throws {
        let clusterSessionId = try faceRepo.getClusterSessionId(clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        try transactions.transaction {
            let cluster = try faceRepo.getClusters(sessionId, includeMembers: true).first { $0.id == clusterId }
            guard let member = cluster?.members?.first(where: { $0.id == memberId }) else {
                throw FaceKwServiceError.clusterMemberNotFound
            }
            try feedback.record(sessionId: sessionId,
                photoId: member.photoId, bbox: Self.parseBbox(member.bbox),
                personId: cluster?.matchedPersonId, confirmed: false)
            if !(try faceRepo.removeMemberFromCluster(clusterId: clusterId, memberId: memberId)) {
                throw FaceKwServiceError.clusterMemberNotFound
            }
            try personRepo.reconcileSession(sessionId: sessionId)
        }

    }

    /// 人员匹配兜底阈值（与 persons.match_threshold 列默认值 0.65 一致）。
    static let defaultPersonMatchThreshold = 0.65

    /// 跨会话重识别：把新簇的成员向量与 person_embeddings 库比对，写入建议
    /// （face_clusters.matched_person_id / match_confidence）。
    /// - 已绑定的簇（matched_person_id 非空，含刚迁移回来的绑定）不被建议覆盖；
    /// - 阈值取该人物自己的 persons.match_threshold，取不到用 0.65；
    /// - 库为空、维度不一致或没有合格候选时静默跳过（建议是可选增强，
    ///   不是分析结果的必要条件）。
    ///
    /// Cut 5 / 5c-1（去 N+1）：旧实现簇循环内每簇 1 次 getClusterMembers + 1 次
    /// FaceFeedbackRepo.list（2C 次查询）、每条 query 重扫库并重算库行范数。现在：
    /// - 成员一次批量读（getClusterMatchRows 的簇+成员 LEFT JOIN，800 分块 IN）；
    /// - feedback 一次 list，rejected 集合在簇循环外按成员 bbox 算好；
    /// - 一个 FaceMatcher 实例做一次批量 match(clusters:)，库/范数只准备一次。
    ///
    /// Cut 5 / 5c-2：modelSpace 由 B 阶段快照传入（不再为取模型空间重读全表
    /// observations）；固定 SELECT = 4（库向量 / 簇+成员 / feedback / 人物阈值），
    /// 与簇数无关（C ≤ 800；FaceMatcherBatchTests / FaceKwMatchBatchTests 守门）。
    /// 未传 modelSpace 时保留旧的自省路径（直接调用方/测试兼容）。
    /// internal（非 private）仅为 @testable 查询计数守门；生产调用点在 FaceKwService+Clusters.swift。
    func matchClustersAgainstLibrary(
        sessionId: String,
        clusters: [(clusterId: Int64, embeddings: [[Float]])],
        modelSpace: String? = nil
    ) throws {
        guard !clusters.isEmpty else { return }
        let resolvedSpace: String
        if let modelSpace {
            guard !modelSpace.isEmpty else { return }
            resolvedSpace = modelSpace
        } else {
            let spaces = Set(try faceRepo.getObservations(sessionId).map {
                FaceIdentityPolicy.modelSpace(analysisSignature: $0.analysisSignature)
            })
            guard spaces.count == 1, let space = spaces.first, !space.isEmpty else { return }
            resolvedSpace = space
        }
        let library = try personRepo.getAllEmbeddings(modelSpace: resolvedSpace).compactMap { ref -> LibraryEmbedding? in
            let floats = Self.floats(from: ref.embedding)
            guard !floats.isEmpty else { return nil }
            return LibraryEmbedding(personId: ref.personId, embedding: floats)
        }
        guard let libraryDim = library.first?.embedding.count else { return }
        let usable = library.filter { $0.embedding.count == libraryDim }

        // 成员一次批量读：簇匹配状态 + 成员几何来自同一条 LEFT JOIN（无成员的簇也有
        // 一行，memberPhotoId == nil），不再经过 getClusters 的簇/成员/绑定三次查询。
        let matchRows = try faceRepo.getClusterMatchRows(
            sessionId: sessionId, clusterIds: clusters.map(\.clusterId))
        var membersByCluster: [Int64: [(photoId: String, bbox: String)]] = [:]
        var linkedClusterIds = Set<Int64>()
        for row in matchRows {
            if row.matchedPersonId != nil { linkedClusterIds.insert(row.clusterId) }
            if let photoId = row.memberPhotoId {
                membersByCluster[row.clusterId, default: []].append(
                    (photoId: photoId, bbox: row.memberBbox))
            }
        }
        // feedback 一次读（旧实现簇循环内每簇重读整表）。
        let feedback = try self.feedback.list(sessionId: sessionId)
        let rejectedByPhoto = Dictionary(
            grouping: feedback.filter { $0.decision == "rejected" }, by: \.photoId)

        let summaries = (try? personRepo.summaries(ids: Array(Set(usable.map(\.personId))))) ?? [:]
        let thresholds = summaries.mapValues(\.matchThreshold)
        let margin = max(0, getNumber("face_match_margin", 0.01))

        // 簇循环只做内存过滤：已绑定跳过、rejected 集合、维度过滤。
        var queries: [FaceMatchCluster] = []
        queries.reserveCapacity(clusters.count)
        for cluster in clusters where !linkedClusterIds.contains(cluster.clusterId) {
            let members = membersByCluster[cluster.clusterId] ?? []
            var rejected = Set<String>()
            var rejectsWholeCluster = false
            for member in members {
                let bbox = Self.parseBbox(member.bbox)
                for correction in rejectedByPhoto[member.photoId] ?? []
                    where FaceIdentityPolicy.overlap(bbox, correction.bbox) >= 0.5 {
                    guard let personId = correction.personId else {
                        // 无 personId 的 rejected（"不是人脸"）整簇不猜（旧行为 continue）。
                        rejectsWholeCluster = true
                        break
                    }
                    rejected.insert(personId)
                }
                if rejectsWholeCluster { break }
            }
            if rejectsWholeCluster { continue }
            let embeddings = cluster.embeddings.filter { $0.count == libraryDim }
            guard !embeddings.isEmpty else { continue }
            queries.append(FaceMatchCluster(
                clusterId: cluster.clusterId,
                embeddings: embeddings,
                excludedPersonIds: rejected))
        }
        guard !queries.isEmpty else { return }

        let matcher = FaceMatcher(library: usable)
        let decisions = try matcher.match(
            clusters: queries,
            thresholds: thresholds,
            defaultThreshold: Self.defaultPersonMatchThreshold,
            margin: margin)
        for decision in decisions {
            guard case let .accepted(personId, score) = decision.decision else { continue }
            try faceRepo.setClusterMatch(
                clusterId: decision.clusterId, personId: personId, confidence: score)
        }
    }

    func captureManualIdentityFeedback(sessionId: String) throws {
        let repo = feedback
        let recorded = try repo.list(sessionId: sessionId)
        for cluster in try faceRepo.getClusters(sessionId, includeMembers: true) {
            guard let binding = cluster.binding else { continue }
            let personId = try cluster.matchedPersonId ?? personRepo.upsertByName(name: binding.roleName)
            try faceRepo.setClusterMatch(clusterId: cluster.id, personId: personId, confidence: 1)
            for member in cluster.members ?? [] {
                let bbox = Self.parseBbox(member.bbox)
                guard !recorded.contains(where: {
                    $0.photoId == member.photoId && FaceIdentityPolicy.overlap($0.bbox, bbox) >= 0.5
                }) else { continue }
                try repo.record(sessionId: sessionId, photoId: member.photoId,
                                bbox: bbox, personId: personId, confirmed: true, keywords: binding.keywords)
            }
        }
    }

    /// 存储 BLOB 的 Float32 视图（TS: Float32Array 视图，零拷贝语义）。
    static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }

    /// TS: JSON.parse(m.bbox)。
    private static func parseBbox(_ raw: String) -> [Double] {
        guard let value = try? JSONValue.parse(raw), case .array(let items) = value else { return [] }
        return items.compactMap {
            if case .number(let v) = $0 { return v }
            return nil
        }
    }
}
