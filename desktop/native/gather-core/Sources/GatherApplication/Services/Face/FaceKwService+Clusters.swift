// WP5b：FaceKwService 拆分（纯移动，行为不变）——Clusters（A/B/C 聚类管线）。
// 源：HEAD 95f0075 的 Services/FaceKwService.swift；仅调整跨文件访问级。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension FaceKwService {
    // ─────────────────────────── 内部 ───────────────────────────

    // ─────────────── 聚类（Cut 5 / 5c-2：B 锁外纯内存 + C 短事务） ───────────────

    /// A 阶段产出的迁移观察（尚未落库）。
    /// 模型迁移时旧观测必须保留到"全部照片都成功"之后（FaceIdentityArchitectureTests
    /// 的「失败/取消不发布半成品向量」契约）：A 只把结果放在内存，B 用覆盖层参与
    /// 聚类，C 才在同一个短事务里写入。观察 id 用负数临时占位，落库后按
    /// photoId + 序号回填真实 id。
    struct PreparedObservations {
        let observations: [FaceObservationInput]
        let sourceFileSize: Int64
        let sourceFileMtimeMs: Double
        /// 本次运行的 analysis_signature（0 张脸时 observations.first 为空，不能从输入反推）。
        let analysisSignature: String
        let complete: Bool
    }

    /// B 阶段的一次性只读快照：observations + feedback + 已有簇（含成员/绑定）
    /// + 人工反馈引用的人物行。读取在同一个读事务内完成；事务结束即释放连接锁，
    /// 随后的聚类是纯内存计算（不持 DB 锁）。
    private struct ClusterReadSnapshot {
        let observations: [FaceObservationRow]
        let feedback: [FaceIdentityFeedback]
        let clusters: [FaceClusterRow]
        let personRows: [String: PersonRow]
    }

    /// 聚类输入的统一视图（DB 行或 A 阶段待提交的迁移观察）。
    private struct ClusterObservation {
        let id: Int64
        let photoId: String
        let bbox: [Double]
        let confidence: Double
        let quality: Double
        let embedding: [Float]
        let analysisSignature: String
    }

    /// 角色绑定迁移的只读投影（Persistence 的 FaceBindingDetail 没有公开构造器，
    /// 服务层从"已有簇（含绑定）"快照里自行组装；也省掉 getBindingsBySession 的
    /// 两次额外查询）。
    private struct ClusterBindingSnapshot {
        let clusterId: Int64
        let roleName: String
        let keywords: [String]
        let memberPhotoIds: [String]
    }

    /// 人工确认簇在 C 阶段要写的绑定（人物名/关键词在 B 阶段一次读完）。
    private struct ManualBindingWrite {
        let index: Int
        let personId: String
        let roleName: String
        let keywords: [String]
    }

    /// 全量路径的 C 阶段输入（B 内算完，C 只落库）。
    private struct FullClusterPlan {
        let clusterInputs: [FaceClusterInput]
        /// 每个新簇的查询向量集合（外层按簇、内层按成员）。
        let embeddingsByCluster: [[[Float]]]
        let manualBindings: [ManualBindingWrite]
        let previousBindings: [ClusterBindingSnapshot]
        let feedbackWasEmpty: Bool
    }

    /// B/C 共用入口：读快照（一个读事务）→ 纯内存聚类 → C 短事务落库。
    ///
    /// 失败边界（审计 §4.3/§4.4）：
    /// - A 已提交的照片级观测/状态保留（checkpoint = face_analysis_state）；
    /// - B 失败不改簇；只清 cluster_signature，避免下次把旧簇误判为最新；
    /// - C 的 index_seq 守卫失败 / 取消 → 整个 C 事务回滚，不留半套簇。
    func clusterStoredObservations(
        sessionId: String,
        photos: [PhotoProjectionRow],
        indexSeq: Int,
        eps: Double,
        minPts: Int,
        options: FaceClusterOptions,
        signature: String,
        signal: JobAbortSignal?,
        clearOnEmpty: Bool,
        incremental: Bool = false,
        prepared: [String: PreparedObservations] = [:],
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws {
        do {
            try runClusterStoredObservations(
                sessionId: sessionId, photos: photos, indexSeq: indexSeq, eps: eps,
                minPts: minPts, options: options, signature: signature, signal: signal,
                clearOnEmpty: clearOnEmpty, incremental: incremental,
                prepared: prepared, onProgress: onProgress)
        } catch {
            // A 与 C 之间失败的统一失效：观测可能已是新的，簇还是旧的；签名必须清空，
            // 否则下一次 analyze 的 "photosNeedingAnalysis.isEmpty && signatureMatches"
            // 快路径会永远跳过重聚类。
            try? faceRepo.clearClusterSignature(sessionId: sessionId)
            throw error
        }
    }

    private func runClusterStoredObservations(
        sessionId: String,
        photos: [PhotoProjectionRow],
        indexSeq: Int,
        eps: Double,
        minPts: Int,
        options: FaceClusterOptions,
        signature: String,
        signal: JobAbortSignal?,
        clearOnEmpty: Bool,
        incremental: Bool,
        prepared: [String: PreparedObservations],
        onProgress: ((Int, Int) -> Void)?
    ) throws {
        if signal?.aborted ?? false { throw JobCancelledError() }
        let cancelCheck: (() throws -> Void)? = signal.map { signal in
            { if signal.aborted { throw JobCancelledError() } }
        }
        let snapshot = try readClusterSnapshot(sessionId: sessionId)
        let (observations, tempIdsByPhoto) = Self.clusterObservations(
            snapshot.observations, photos: photos, prepared: prepared)
        let spaces = Set(observations.map {
            FaceIdentityPolicy.modelSpace(analysisSignature: $0.analysisSignature)
        })
        guard spaces.count <= 1 else {
            throw DBError.message("当前工作区包含不同人脸模型的向量，请先完成全量人脸分析")
        }
        let modelSpace = spaces.first
        let feedbackByPhoto = Dictionary(grouping: snapshot.feedback, by: \.photoId)
        let observationById = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })

        var entries: [EmbeddingEntry] = []
        for observation in observations {
            if observation.embedding.contains(where: { $0 != 0 }) {
                entries.append(EmbeddingEntry(
                    observationId: Int(observation.id),
                    photoId: observation.photoId,
                    embedding: observation.embedding,
                    // quality ≤ 0 = v34 迁移的旧行（或注入式假推理未提供质量）：按"不设限"
                    // 处理，否则升级后旧库会被质量门槛整库判成噪声；真实质量分恒 > 0。
                    quality: observation.quality > 0 ? observation.quality : 1))
            }
        }

        // 增量资格在 run 开始时的状态上判定（signatureMatches / hasClusters 取分析前
        // 的快照）：设置开启 + 聚类签名未变 + 库里已有簇 + 本次分析没有整体失败。
        // recluster 命令恒走全量。约束检查与旧实现逐行相同。
        let constraintsPermitIncremental = snapshot.feedback.allSatisfy { correction in
            guard correction.decision == "confirmed" else { return false }
            let matchingObservations = observations.filter {
                $0.photoId == correction.photoId && FaceIdentityPolicy.overlap(
                    $0.bbox, correction.bbox) >= 0.5
            }
            return matchingObservations.allSatisfy { observation in
                snapshot.clusters.contains { cluster in
                    cluster.matchedPersonId == correction.personId &&
                    (cluster.members ?? []).contains { $0.observationId == observation.id }
                }
            }
        }
        if incremental && !entries.isEmpty && constraintsPermitIncremental {
            try commitIncrementalClusters(
                sessionId: sessionId, indexSeq: indexSeq, signature: signature,
                entries: entries, observationById: observationById, photoById: photoById,
                existingRows: snapshot.clusters, modelSpace: modelSpace,
                eps: eps, minPts: minPts, options: options, signal: signal,
                cancelCheck: cancelCheck, onProgress: onProgress)
            return
        }

        // 全量：自动/人工确认/待复核分类（与旧实现逐行相同）。
        var automatic: [EmbeddingEntry] = []
        var confirmed: [String: [EmbeddingEntry]] = [:]
        var review: [[EmbeddingEntry]] = []
        for entry in entries {
            guard let observation = observationById[Int64(entry.observationId)] else { continue }
            let decisions = (feedbackByPhoto[entry.photoId] ?? []).filter {
                FaceIdentityPolicy.overlap($0.bbox, observation.bbox) >= 0.5
            }
            if let identity = decisions.last(where: { $0.decision == "confirmed" })?.personId {
                confirmed[identity, default: []].append(entry)
            } else if decisions.contains(where: { $0.decision == "rejected" }) {
                // Keep the face visible for reassignment, but never silently restore a rejected label.
                review.append([entry])
            } else { automatic.append(entry) }
        }
        // B：聚类计算在连接锁之外执行（isCancelled 注入到 DBSCAN 内）。
        let clustered = try clusterProvider(
            automatic, eps, minPts, options, onProgress, cancelCheck)
        let manualIds = confirmed.keys.sorted()
        let automaticClusters = clustered.clusters.filter { !$0.isEmpty }
        let resolvedClusters = automaticClusters + manualIds.compactMap { confirmed[$0] } + review
        let manualOffset = automaticClusters.count
        if signal?.aborted ?? false { throw JobCancelledError() }

        let clusterInputs = resolvedClusters.enumerated().map { index, cluster in
            FaceClusterInput(
                label: "Person \(index + 1)",
                members: cluster.map { entry in
                    memberInput(for: entry, observationById: observationById, photoById: photoById)
                }
            )
        }
        // 人工绑定所需的 person.name / keywords 也来自 B 的快照（C 内零读取）。
        var manualBindings: [ManualBindingWrite] = []
        for (offset, personId) in manualIds.enumerated() {
            guard let person = snapshot.personRows[personId] else { continue }
            let keywords = snapshot.feedback.last(where: {
                $0.personId == personId && $0.decision == "confirmed"
            })?.keywords ?? Self.parseKeywords(person.keywords)
            manualBindings.append(ManualBindingWrite(
                index: manualOffset + offset, personId: personId,
                roleName: person.name, keywords: keywords))
        }
        let plan = FullClusterPlan(
            clusterInputs: clusterInputs,
            embeddingsByCluster: resolvedClusters.map { $0.map(\.embedding) },
            manualBindings: manualBindings,
            previousBindings: Self.bindings(from: snapshot.clusters),
            feedbackWasEmpty: snapshot.feedback.isEmpty)
        try commitFullClusters(
            sessionId: sessionId, indexSeq: indexSeq, signature: signature, plan: plan,
            photos: photos, prepared: prepared, tempIdsByPhoto: tempIdsByPhoto,
            clearOnEmpty: clearOnEmpty, signal: signal, modelSpace: modelSpace)
    }

    /// B 阶段读快照（唯一读事务；不包含任何写）。
    private func readClusterSnapshot(sessionId: String) throws -> ClusterReadSnapshot {
        try transactions.transaction {
            let observations = try faceRepo.getObservations(sessionId)
            let feedback = try self.feedback.list(sessionId: sessionId)
            let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
            // 人工确认簇要在 C 里写 role_name/keywords：person 行（含 keywords）在
            // 读事务内一次取齐，B/C 都不再回读。确认身份通常个位数，逐条 get 可接受。
            let personIds = Set(feedback.filter { $0.decision == "confirmed" }.compactMap(\.personId))
            var personRows: [String: PersonRow] = [:]
            for personId in personIds {
                if let row = try personRepo.get(id: personId) { personRows[personId] = row }
            }
            return ClusterReadSnapshot(
                observations: observations, feedback: feedback,
                clusters: clusters, personRows: personRows)
        }
    }

    /// DB 行 + A 阶段迁移观察的合并视图。迁移照片的旧行被覆盖层替换；覆盖层追加在
    /// 未变化行之后（旧实现先 replace 再 getObservations，新行 id 恒更大），并分配
    /// 负数临时 id 供 C 回填。
    private static func clusterObservations(
        _ rows: [FaceObservationRow],
        photos: [PhotoProjectionRow],
        prepared: [String: PreparedObservations]
    ) -> (observations: [ClusterObservation], tempIdsByPhoto: [String: [Int64]]) {
        var observations: [ClusterObservation] = []
        observations.reserveCapacity(rows.count)
        for row in rows where prepared[row.photoId] == nil {
            observations.append(ClusterObservation(
                id: row.id,
                photoId: row.photoId,
                bbox: [row.bboxX, row.bboxY, row.bboxW, row.bboxH],
                confidence: row.confidence,
                quality: row.quality,
                embedding: floats(from: row.embedding),
                analysisSignature: row.analysisSignature))
        }
        var tempIdsByPhoto: [String: [Int64]] = [:]
        var nextTempId: Int64 = -1
        for photo in photos {
            guard let item = prepared[photo.id] else { continue }
            var tempIds: [Int64] = []
            tempIds.reserveCapacity(item.observations.count)
            for input in item.observations {
                let tempId = nextTempId
                nextTempId -= 1
                tempIds.append(tempId)
                observations.append(ClusterObservation(
                    id: tempId,
                    photoId: input.photoId,
                    bbox: [input.bboxX, input.bboxY, input.bboxW, input.bboxH],
                    confidence: input.confidence,
                    quality: input.quality,
                    embedding: input.embedding,
                    analysisSignature: input.analysisSignature ?? item.analysisSignature))
            }
            tempIdsByPhoto[photo.id] = tempIds
        }
        return (observations, tempIdsByPhoto)
    }

    /// 已有簇（含绑定）→ 绑定迁移快照。
    private static func bindings(from clusters: [FaceClusterRow]) -> [ClusterBindingSnapshot] {
        clusters.compactMap { cluster in
            guard let binding = cluster.binding else { return nil }
            return ClusterBindingSnapshot(
                clusterId: cluster.id,
                roleName: binding.roleName,
                keywords: binding.keywords,
                memberPhotoIds: (cluster.members ?? []).map(\.photoId))
        }
    }

    /// C 阶段（全量）：一个短事务落库 + 一个 best-effort 的身份/匹配阶段。
    private func commitFullClusters(
        sessionId: String,
        indexSeq: Int,
        signature: String,
        plan: FullClusterPlan,
        photos: [PhotoProjectionRow],
        prepared: [String: PreparedObservations],
        tempIdsByPhoto: [String: [Int64]],
        clearOnEmpty: Bool,
        signal: JobAbortSignal?,
        modelSpace: String?
    ) throws {
        let pathById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })
        var newClusterIds: [Int64] = []
        try transactions.transaction {
            guard try sessionRepo.getIndexSeq(id: sessionId) == indexSeq else {
                throw DBError.message("工作区内容已变化，请重新运行人脸分析")
            }
            if signal?.aborted ?? false { throw JobCancelledError() }

            // 迁移观察在 C 内落库：任一步失败整事务回滚，旧观测/旧簇/旧绑定保持原样。
            var realIdByTemp: [Int64: Int64] = [:]
            for photoId in prepared.keys.sorted() {
                guard let result = prepared[photoId], let path = pathById[photoId],
                      case let .ok(size, mtime) = Self.sourceStat(path),
                      size == result.sourceFileSize, mtime == result.sourceFileMtimeMs else {
                    throw DBError.message("分析期间原始照片已变化，请重新运行人脸分析")
                }
                let ids = try faceRepo.replaceObservationsByPhoto(
                    sessionId: sessionId, photoId: photoId, observations: result.observations)
                if result.complete {
                    try faceRepo.upsertAnalysisState(
                        sessionId: sessionId, photoId: photoId,
                        sourceFileSize: result.sourceFileSize,
                        sourceFileMtimeMs: result.sourceFileMtimeMs,
                        analysisSignature: result.analysisSignature)
                }
                for (index, tempId) in (tempIdsByPhoto[photoId] ?? []).enumerated() where index < ids.count {
                    realIdByTemp[tempId] = ids[index]
                }
            }

            if plan.clusterInputs.isEmpty {
                // 分析成功但无脸时不应留下陈旧集群；全失败 run 则保留（TS 注释）。
                if clearOnEmpty {
                    try faceRepo.clearClusterMembers(sessionId: sessionId)
                    try faceRepo.deleteUnboundClusters(sessionId: sessionId)
                }
                try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
                return
            }

            // 幂等重放（Cut 5 / 5c-2）：目标状态与库中现有簇逐行一致时只推进签名。
            // recluster 同参数重跑不再"删全表重插"（簇 id / 绑定 / UI 选中都不抖动）；
            // 成员或反馈变化时走下面的替换路径（旧语义不变）。
            if prepared.isEmpty, plan.feedbackWasEmpty,
               let current = try? faceRepo.getClusters(sessionId, includeMembers: true),
               Self.clusterRowsMatch(plan.clusterInputs, current) {
                try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
                newClusterIds = current.map(\.id)
                return
            }

            // 新结果就绪才替换旧集群（TS 注释 689-693）：用户绑定的角色经成员
            // 重叠迁移，否则重新聚类后绑定会静默消失。删旧 + 建新 + 迁移同事务，
            // 避免中途失败留下半套簇（审计 P1「聚类替换非原子」）。
            try faceRepo.deleteClustersBySession(sessionId)
            let resolvedInputs = plan.clusterInputs.map { input in
                FaceClusterInput(
                    label: input.label,
                    members: input.members.map { member in
                        FaceClusterMemberInput(
                            photoId: member.photoId,
                            photoPath: member.photoPath,
                            bbox: member.bbox,
                            confidence: member.confidence,
                            // 迁移观察的临时 id 在同一个事务里已回填为真实行 id。
                            observationId: member.observationId.flatMap { realIdByTemp[$0] ?? $0 })
                    })
            }
            let ids = try faceRepo.saveClusters(sessionId: sessionId, clusters: resolvedInputs)
            if plan.feedbackWasEmpty && !plan.previousBindings.isEmpty {
                let membersByCluster = ids.enumerated().map { index, clusterId in
                    (
                        clusterId: clusterId,
                        photoIds: Set(
                            plan.clusterInputs[index].members.map(\.photoId).filter { !$0.isEmpty }
                        )
                    )
                }
                migrateBindings(plan.previousBindings, newMembers: membersByCluster)
            }
            for manual in plan.manualBindings where manual.index < ids.count {
                try faceRepo.updateBinding(
                    clusterId: ids[manual.index], roleName: manual.roleName,
                    keywords: manual.keywords)
                try faceRepo.setClusterMatch(
                    clusterId: ids[manual.index], personId: manual.personId, confidence: 1)
            }
            let restoredNames = Set(try faceRepo.getBindingsBySession(sessionId).map(\.roleName))
            for binding in plan.previousBindings where !restoredNames.contains(binding.roleName) {
                let orphan = try faceRepo.saveClusters(sessionId: sessionId, clusters: [
                    FaceClusterInput(label: binding.roleName, members: [])
                ])[0]
                try faceRepo.updateBinding(clusterId: orphan, roleName: binding.roleName, keywords: binding.keywords)
            }
            try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
            newClusterIds = ids
        }

        // C2（txn2，best-effort）：身份投影 + 跨会话重识别都不再决定本次分析成败。
        // 旧实现把两者放在分析事务里，匹配建议写失败会连带回滚整批簇；阶段化后
        // 落库已完成，失败只记日志（下次重算可复原，与增量路径同口径）。
        try reconcileAndMatch(
            sessionId: sessionId,
            clusters: newClusterIds.enumerated().map { index, clusterId in
                (clusterId: clusterId, embeddings: plan.embeddingsByCluster[index])
            },
            modelSpace: modelSpace,
            reconcileEvenWhenEmpty: plan.clusterInputs.isEmpty)
    }

    /// C2：身份投影（短事务）+ 跨库匹配（读/算/写各自短语句，不持长事务）。
    private func reconcileAndMatch(
        sessionId: String,
        clusters: [(clusterId: Int64, embeddings: [[Float]])],
        modelSpace: String?,
        reconcileEvenWhenEmpty: Bool
    ) throws {
        if reconcileEvenWhenEmpty || !clusters.isEmpty {
            do {
                try transactions.transaction {
                    try personRepo.reconcileSession(sessionId: sessionId)
                }
            } catch {
                GatherLogger.log(
                    "Face analysis: person reconciliation failed (best-effort) \(error)",
                    level: .warn)
            }
        }
        guard !clusters.isEmpty else { return }
        do {
            try matchClustersAgainstLibrary(
                sessionId: sessionId, clusters: clusters, modelSpace: modelSpace)
        } catch {
            GatherLogger.log(
                "Face analysis: cross-session match failed (best-effort) \(error)", level: .warn)
        }
    }

    /// 目标簇与库中现有簇逐行一致（标签 + 成员顺序 + 照片/观察 id/置信度）。
    /// 只用于 C 的幂等重放判定：不一致时必须走完整替换，不能跳过绑定迁移。
    private static func clusterRowsMatch(
        _ inputs: [FaceClusterInput],
        _ rows: [FaceClusterRow]
    ) -> Bool {
        guard inputs.count == rows.count else { return false }
        for (input, row) in zip(inputs, rows) {
            let members = row.members ?? []
            guard row.label == input.label, members.count == input.members.count else { return false }
            for (expected, actual) in zip(input.members, members) {
                guard actual.photoId == expected.photoId,
                      actual.observationId == expected.observationId,
                      actual.confidence == expected.confidence else { return false }
            }
        }
        return true
    }

    /// 增量聚类落库（analyze 且 face_incremental_clustering = "1"、签名未变、
    /// 库里已有簇时）。语义：
    /// - 已有簇行、id、matched_person_id、role_bindings 一律保留（不删不重建，
    ///   因此用户绑定不会像全量那样被冲掉）；
    /// - 本次读到、且未被任何已有簇成员引用的观测是"新增/变化"集合：命中某簇质心
    ///   的追加为该簇成员，未命中的只对彼此跑全量同参 DBSCAN 产出新簇；
    /// - 引用已消失观测的"幽灵成员行"在**落库事务内**清理（删除推迟到最后，取消
    ///   不落库）：重推理会替换观察行（新 id），不清理会让同一张照片同时留下旧成员
    ///   行与新成员行（簇大小虚高），而全量路径本来就会丢弃这些行；
    /// - 跨会话身份匹配只对新簇做，已有簇的 matched_person_id 不重算；
    ///   person_photos 由 reconcileSession 按绑定+成员幂等重放（best-effort）。
    ///
    /// Cut 5 / 5c-2：质心匹配 + 未命中集合 DBSCAN 全部在事务之外（B）；C 的落库
    /// 事务以 index_seq 守卫开头、同事务写签名；身份桥接/跨库匹配降级为 txn2
    /// best-effort（失败只记日志，不回滚已提交的簇）。
    private func commitIncrementalClusters(
        sessionId: String,
        indexSeq: Int,
        signature: String,
        entries: [EmbeddingEntry],
        observationById: [Int64: ClusterObservation],
        photoById: [String: String],
        existingRows: [FaceClusterRow],
        modelSpace: String?,
        eps: Double,
        minPts: Int,
        options: FaceClusterOptions,
        signal: JobAbortSignal?,
        cancelCheck: (() throws -> Void)?,
        onProgress: ((Int, Int) -> Void)?
    ) throws {
        if signal?.aborted ?? false { throw JobCancelledError() }
        let entryByObservationId = Dictionary(
            uniqueKeysWithValues: entries.map { (Int64($0.observationId), $0) })

        // 1) 已有簇及其"现存"成员（observation_id 仍在当前观察集合 → 转 EmbeddingEntry）；
        //    引用 NULL/已消失观察的成员行收集为幽灵，随后在落库事务内一并删除。
        //    同一观察只会被一个簇认领（covered），重复成员行按幽灵处理。
        var covered = Set<Int64>()
        var ghostMemberIds: [Int64] = []
        var existing: [(clusterId: Int, entries: [EmbeddingEntry])] = []
        for row in existingRows {
            var members: [EmbeddingEntry] = []
            for member in row.members ?? [] {
                guard let observationId = member.observationId,
                      let entry = entryByObservationId[observationId],
                      covered.insert(observationId).inserted
                else {
                    ghostMemberIds.append(member.id)
                    continue
                }
                members.append(entry)
            }
            existing.append((clusterId: Int(row.id), entries: members))
        }
        let newEntries = entries.filter { !covered.contains(Int64($0.observationId)) }
        if newEntries.isEmpty {
            // 没有新增观测就不需要聚类；只有确有幽灵行时才落一次清理事务。
            guard !ghostMemberIds.isEmpty else { return }
            if signal?.aborted ?? false { throw JobCancelledError() }
            try transactions.transaction {
                guard try sessionRepo.getIndexSeq(id: sessionId) == indexSeq else {
                    throw DBError.message("工作区内容已变化，请重新运行人脸分析")
                }
                try deleteClusterMembers(ids: ghostMemberIds)
                try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
            }
            return
        }

        // B：质心匹配 + 未命中集合 DBSCAN（连接锁外；isCancelled 注入）。
        let incremental = try FaceClusterer.assignIncrementally(
            existingClusters: existing,
            newEntries: newEntries,
            eps: eps,
            minPts: minPts,
            coreQualityFloor: options.coreQualityFloor,
            retryMinSamples: options.retryMinSamples,
            // 歧义不猜：与 matchClustersAgainstLibrary 的 face_match_margin 同源同语义，
            // 冠军/亚军近似并列时宁可另立新簇，也不把脸塞进可能错误的人。
            ambiguityMargin: max(0, getNumber("face_match_margin", 0.01)),
            onProgress: onProgress,
            isCancelled: cancelCheck)
        if signal?.aborted ?? false { throw JobCancelledError() }

        // 2) 落库：清理幽灵成员 + 追加新成员 + 建新簇（同一事务）。已有簇行与其
        //    绑定/匹配列不动。
        var appendedMembers: [(clusterId: Int64, members: [FaceClusterMemberInput])] = []
        var newClusters: [FaceClusterInput] = []
        var newClusterEntries: [[EmbeddingEntry]] = []
        let labelBase = existingRows.count
        for assignment in incremental.assignments {
            let members = assignment.entries.map {
                memberInput(for: $0, observationById: observationById, photoById: photoById)
            }
            if let clusterId = assignment.clusterId {
                appendedMembers.append((Int64(clusterId), members))
            } else {
                newClusters.append(FaceClusterInput(
                    label: "Person \(labelBase + newClusters.count + 1)", members: members))
                newClusterEntries.append(assignment.entries)
            }
        }
        var createdClusterIds: [Int64] = []
        try transactions.transaction {
            guard try sessionRepo.getIndexSeq(id: sessionId) == indexSeq else {
                throw DBError.message("工作区内容已变化，请重新运行人脸分析")
            }
            if signal?.aborted ?? false { throw JobCancelledError() }
            if !ghostMemberIds.isEmpty {
                try deleteClusterMembers(ids: ghostMemberIds)
            }
            if !appendedMembers.isEmpty {
                // 语句准备与 bbox JSON 编码都在 Repo 内（与 saveClusters 同一实现）。
                try faceRepo.appendClusterMembers(
                    sessionId: sessionId,
                    groups: appendedMembers.map { (clusterId: $0.clusterId, members: $0.members) }
                )
            }
            if !newClusters.isEmpty {
                createdClusterIds = try faceRepo.saveClusters(sessionId: sessionId, clusters: newClusters)
            }
            try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
        }

        // 3) 身份桥接与跨会话建议只针对新簇；已有簇的 matched_person_id 不被覆盖。
        //    Best-effort：落库已完成，桥接失败只记日志（下次重算可复原）。
        try reconcileAndMatch(
            sessionId: sessionId,
            clusters: createdClusterIds.enumerated().map { index, clusterId in
                (clusterId: clusterId, embeddings: newClusterEntries[index].map(\.embedding))
            },
            modelSpace: modelSpace,
            reconcileEvenWhenEmpty: true)
    }

    /// 增量成员落库输入（bbox/confidence 取自观察行；照片路径缺失回落空串，同全量）。
    private func memberInput(
        for entry: EmbeddingEntry,
        observationById: [Int64: ClusterObservation],
        photoById: [String: String]
    ) -> FaceClusterMemberInput {
        let observation = observationById[Int64(entry.observationId)]
        return FaceClusterMemberInput(
            photoId: entry.photoId,
            photoPath: photoById[entry.photoId] ?? "",
            bbox: observation?.bbox ?? [0, 0, 0, 0],
            confidence: observation?.confidence ?? 0,
            observationId: Int64(entry.observationId))
    }

    /// 按成员行 id 删除（幽灵成员清理；分批防 SQLite 参数上限）。
    private func deleteClusterMembers(ids: [Int64]) throws {
        try faceRepo.deleteClusterMembers(ids: ids)
    }

    private static func parseKeywords(_ raw: String) -> [String] {
        (try? JSONValue.parse(raw))?.arrayElements?.compactMap(\.stringValue) ?? []
    }

    /// TS: migrateBindings —— 按照片 id 重叠度把角色绑定挂回新集群；重叠降序
    /// 认领（竞争由更优匹配者获胜）；消失的脸对应的绑定被丢弃。Best-effort：
    /// 迁移失败不得使分析本身失败。
    private func migrateBindings(
        _ previousBindings: [ClusterBindingSnapshot],
        newMembers: [(clusterId: Int64, photoIds: Set<String>)]
    ) {
        var candidates: [(binding: ClusterBindingSnapshot, clusterId: Int64, overlap: Int)] = []
        for binding in previousBindings {
            let memberPhotos = Set(binding.memberPhotoIds)
            for candidate in newMembers {
                var overlap = 0
                for photoId in candidate.photoIds where memberPhotos.contains(photoId) {
                    overlap += 1
                }
                if overlap > 0 {
                    candidates.append((binding, candidate.clusterId, overlap))
                }
            }
        }
        candidates.sort { $0.overlap > $1.overlap }
        var claimedClusters = Set<Int64>()
        var migratedBindings = Set<Int64>()
        for candidate in candidates {
            if claimedClusters.contains(candidate.clusterId) { continue }
            if migratedBindings.contains(candidate.binding.clusterId) { continue }
            claimedClusters.insert(candidate.clusterId)
            migratedBindings.insert(candidate.binding.clusterId)
            do {
                try faceRepo.updateBinding(
                    clusterId: candidate.clusterId,
                    roleName: candidate.binding.roleName,
                    keywords: candidate.binding.keywords
                )
            } catch {
                GatherLogger.log("Failed to migrate role binding after re-clustering \(error)", level: .warn)
            }
        }
    }

    /// 聚类调参（竞品对标：PhotoPrism CLUSTER_CORE / CLUSTER_CORE_RETRY）：
    /// - `face_core_quality`（默认 0.35）：低于此质量的脸不能成为核心点。0.35 的标定依据——
    ///   96px 以上清晰正脸 ≈ 0.9，30px 但清晰 ≈ 0.6，明显模糊/侧倾 < 0.3；门槛只影响
    ///   "谁能带簇"，低质量脸仍会被吸收为边界点（见 FaceClusterer）。
    /// - `face_core_retry_min_samples`（默认 2）：二遍核心点阈值，用于恢复被严格首遍漏掉的
    ///   小簇；< 2 视为关闭——= 1 会让单张噪声脸各自成簇（PhotoPrism 的 retry 不产生单点簇）。
    static func clusterOptions(from getNumber: (String, Double) -> Double) -> FaceClusterOptions {
        let floor = min(max(getNumber("face_core_quality", 0.35), 0), 1)
        let retry = getNumber("face_core_retry_min_samples", 2).safeInt(fallback: 2)
        return FaceClusterOptions(coreQualityFloor: floor, retryMinSamples: retry >= 2 ? retry : nil)
    }

    /// `face_incremental_clustering`（默认 "1" = 开；只有逐字 "1" 视为开，其余
    /// （含 "0"/"true"/空串）一律关闭）：开启且聚类签名未变、库里已有簇时，analyze
    /// 走增量路径保留已有簇 id 与用户绑定；首次分析、签名变化、recluster 命令与
    /// 全失败 run 仍走全量。用字符串而非 getNumber 判定：避免 "true"/"1" 两种写法
    /// 的解析歧义（键值由设置界面下拉写入，取值域就是 "1"/"0"）。
    static func incrementalClusteringEnabled(_ getString: (String, String) -> String) -> Bool {
        getString("face_incremental_clustering", "1") == "1"
    }

    /// 聚类签名（缓存键）：除 eps/minPts 外必须包含质量门槛与二遍阈值——
    /// 否则改了 face_core_quality 之后旧簇会被判定"仍然有效"而跳过重聚类。
    static func clusterSignature(eps: Double, minPts: Int, options: FaceClusterOptions) -> String {
        "\(eps):\(minPts):q\(options.coreQualityFloor):r\(options.retryMinSamples.map(String.init) ?? "-")"
    }
}
