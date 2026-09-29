// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceIncrementalClusterTests.swift
// 增量人脸聚类（ADR-029 未做项）行为测试：
// - FaceClusterer.assignIncrementally：质心挂靠 / 质量门槛 / 歧义不猜 / 新簇路径 / 边界；
// - FaceKwService 接线：增量保留簇 id、matched_person_id、role_bindings，只追加新成员
//   与新簇；签名变化 / 开关关闭 / recluster 命令走全量；
// - 增量结果再次全量重聚类收敛为同一成员划分（增量不制造全量不会产生的划分）。
//
// 夹具策略：服务层用真实临时 SQLite（迁移已跑）+ 注入假解码/假推理（不跑 Vision）。
// 假解码把"照片路径"当图像字节回传，假推理按路径查向量表 → 每张照片稳定产出指定
// 方向的 4 维单位向量，从而精确控制质心与余弦相似度。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 纯聚类器支撑

/// L2 归一化构造单位向量（质心/点积语义都按单位向量定义）。
private func unit(_ values: [Double]) -> [Float] {
    let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return values.map { Float($0 / norm) }
}

private func entry(
    _ observationId: Int, _ embedding: [Float], quality: Double = 1.0
) -> EmbeddingEntry {
    EmbeddingEntry(
        observationId: observationId, photoId: "photo-\(observationId)",
        embedding: embedding, quality: quality)
}

private func ids(_ entries: [EmbeddingEntry]) -> [Int] {
    entries.map(\.observationId).sorted()
}

/// 规范成员划分：簇内升序 + 簇间字典序，避免依赖 DBSCAN 产出顺序。
private func partition(_ clusters: [[EmbeddingEntry]]) -> [[Int]] {
    clusters.map(ids).sorted { $0.lexicographicallyPrecedes($1) }
}

private let e0: [Float] = [1, 0, 0, 0]
private let e1: [Float] = [0, 1, 0, 0]
private let e2: [Float] = [0, 0, 1, 0]

// MARK: - FaceClusterer.assignIncrementally

@Suite("FaceClusterer 增量入口")
struct FaceIncrementalClustererTests {
    /// 老数据：A 组贴 e0、B 组贴 e1（组内相似度 1.0，组间 0）。
    private func oldEntries() -> [EmbeddingEntry] {
        [entry(1, e0), entry(2, e0), entry(3, e1), entry(4, e1)]
    }

    /// 新数据：两张回 A、一张回 B、两张互相成新簇（C）。
    private func incomingEntries() -> [EmbeddingEntry] {
        [entry(5, e0), entry(6, e0), entry(7, e1), entry(8, e2), entry(9, e2)]
    }

    @Test("清晰可分数据上增量结果与全量结果逐簇成员集合相等")
    func matchesFullClusteringOnSeparableData() throws {
        let old = oldEntries()
        let incoming = incomingEntries()
        let oldFull = try FaceClusterer.clusterEmbeddings(entries: old, eps: 0.6, minPts: 2)
        let full = try FaceClusterer.clusterEmbeddings(entries: old + incoming, eps: 0.6, minPts: 2)
        let incremental = try FaceClusterer.assignIncrementally(
            existingClusters: oldFull.clusters.enumerated().map { index, cluster in
                (clusterId: index + 100, entries: cluster)
            },
            newEntries: incoming,
            eps: 0.6,
            minPts: 2)

        // 组装"已有簇 + 追加 + 新簇"的完整划分，与全量逐簇比较（顺序无关）。
        var merged = oldFull.clusters
        for assignment in incremental.assignments {
            if let clusterId = assignment.clusterId {
                merged[clusterId - 100].append(contentsOf: assignment.entries)
            } else {
                merged.append(assignment.entries)
            }
        }
        #expect(partition(merged) == partition(full.clusters))
        #expect(incremental.noise.isEmpty)
        // 已有簇的原成员不在返回值里，成员集合只可能"新增"。
        let oldIds = Set(old.map(\.observationId))
        for assignment in incremental.assignments where assignment.clusterId != nil {
            #expect(Set(ids(assignment.entries)).isDisjoint(with: oldIds))
            #expect(!assignment.entries.isEmpty)
        }
        #expect(incremental.assignments.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("低质量新脸不参与质心判定，也不得成核心点（数字断言）")
    func lowQualityNewFacesAreExcluded() throws {
        let existing = [(clusterId: 7, entries: [entry(1, e0), entry(2, e0)])]
        let lowQuality = [entry(11, e0, quality: 0.2), entry(12, e0, quality: 0.2)]

        // 质量 0.2 < floor 0.5：质心相似度本可达到 1.0（>= eps 0.6），但门槛先拦住；
        // 两张低质量脸在"未命中集合"内也都不够核心点资格 → 全部留在 noise。
        let gated = try FaceClusterer.assignIncrementally(
            existingClusters: existing, newEntries: lowQuality, eps: 0.6, minPts: 2,
            coreQualityFloor: 0.5, retryMinSamples: 2)
        #expect(gated.assignments.isEmpty)
        #expect(ids(gated.noise) == [11, 12])

        // 对照 1：质量合格（1.0 >= 0.5）时两张脸都挂到簇 7 —— 证明差异只来自质量门槛。
        let qualified = try FaceClusterer.assignIncrementally(
            existingClusters: existing, newEntries: [entry(11, e0), entry(12, e0)], eps: 0.6,
            minPts: 2, coreQualityFloor: 0.5, retryMinSamples: 2)
        #expect(qualified.assignments.count == 1)
        #expect(qualified.assignments[0].clusterId == 7)
        #expect(ids(qualified.assignments[0].entries) == [11, 12])
        #expect(qualified.noise.isEmpty)

        // 对照 2：门槛归零时低质量脸同样按质心（相似度 ≈ 1.0）挂靠。
        let ungated = try FaceClusterer.assignIncrementally(
            existingClusters: existing, newEntries: lowQuality, eps: 0.6, minPts: 2,
            coreQualityFloor: 0)
        #expect(ungated.assignments.count == 1)
        #expect(ids(ungated.assignments[0].entries) == [11, 12])
    }

    @Test("新脸与两簇近似等距时不入任一簇（走新簇）；margin=0 才取最相似者")
    func ambiguousNewFacesFallThroughToNewCluster() throws {
        let clusterA = (clusterId: 1, entries: [entry(1, e0), entry(2, e0)])
        let clusterB = (clusterId: 2, entries: [entry(3, e1), entry(4, e1)])
        // (e0 + e1)/√2 与两个质心的余弦都 ≈ 0.7071（>= eps 0.6）且彼此严格并列
        // （差 = 0 < margin 0.01）——按 face_match_margin 的"歧义不猜"语义，
        // 宁可另立新簇，也不把脸塞进可能错误的人。
        let bisector = unit([1, 1, 0, 0])
        let ambiguous = [entry(11, bisector), entry(12, bisector)]
        let guarded = try FaceClusterer.assignIncrementally(
            existingClusters: [clusterA, clusterB], newEntries: ambiguous, eps: 0.6, minPts: 2,
            ambiguityMargin: 0.01)
        #expect(guarded.assignments.count == 1)
        #expect(guarded.assignments[0].clusterId == nil)
        #expect(ids(guarded.assignments[0].entries) == [11, 12])
        #expect(guarded.noise.isEmpty)

        // margin = 0：恢复"取最相似簇"；完全并列时按传入顺序取冠军（簇 1）。
        let decided = try FaceClusterer.assignIncrementally(
            existingClusters: [clusterA, clusterB], newEntries: ambiguous, eps: 0.6, minPts: 2,
            ambiguityMargin: 0)
        #expect(decided.assignments.count == 1)
        #expect(decided.assignments[0].clusterId == 1)
        #expect(ids(decided.assignments[0].entries) == [11, 12])
    }

    @Test("existingClusters 为空时退化为与全量等价的聚类")
    func emptyExistingClustersDegradeToFull() throws {
        let incoming = incomingEntries()
        let full = try FaceClusterer.clusterEmbeddings(entries: incoming, eps: 0.6, minPts: 2)
        let incremental = try FaceClusterer.assignIncrementally(
            existingClusters: [], newEntries: incoming, eps: 0.6, minPts: 2)
        #expect(partition(incremental.assignments.map(\.entries)) == partition(full.clusters))
        #expect(incremental.assignments.allSatisfy { $0.clusterId == nil })
        #expect(ids(incremental.noise) == ids(full.noise))
    }

    @Test("newEntries 为空 = 无操作；eps 仍按全量语义校验")
    func emptyNewEntriesIsNoOp() throws {
        let existing = [(clusterId: 5, entries: [entry(1, e0), entry(2, e0)])]
        let result = try FaceClusterer.assignIncrementally(existingClusters: existing, newEntries: [])
        #expect(result.assignments.isEmpty)
        #expect(result.noise.isEmpty)
        #expect(throws: ClustererError.similarityThresholdOutOfRange(1.5)) {
            try FaceClusterer.assignIncrementally(existingClusters: existing, newEntries: [], eps: 1.5)
        }
    }

    @Test("质心为空或维度不一致的已有簇被跳过；维度不一致的新观测不入簇")
    func invalidCentroidsAndDimensionsAreSkipped() throws {
        let empty = (clusterId: 1, entries: [EmbeddingEntry]())
        // 成员维度不一致（4 维 + 3 维）→ 整簇跳过，不抛错。
        let mixedDimension = (clusterId: 2, entries: [entry(1, e0), entry(2, [1, 0, 0])])
        let valid = (clusterId: 3, entries: [entry(3, e0), entry(4, e0)])
        let result = try FaceClusterer.assignIncrementally(
            existingClusters: [empty, mixedDimension, valid],
            // 9 号 3 维观测与唯一可用质心（4 维）维度不一致 → 只能落 noise；
            // 10 号 4 维观测正常挂到簇 3。
            newEntries: [entry(9, [1, 0, 0]), entry(10, e0)],
            eps: 0.6,
            minPts: 2)
        #expect(result.assignments.count == 1)
        #expect(result.assignments[0].clusterId == 3)
        #expect(ids(result.assignments[0].entries) == [10])
        #expect(ids(result.noise) == [9])
    }
}

// MARK: - 服务层支撑

/// 线程安全向量表（假解码/假推理共用；锁保护唯一可变状态）。
private final class VectorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var vectors: [String: [Float]] = [:]

    func set(_ path: String, _ vector: [Float]) {
        lock.lock()
        vectors[path] = vector
        lock.unlock()
    }

    func vector(_ path: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return vectors[path]
    }
}

/// 线程安全进度相位收集器（断言 analyze 命中缓存快路径）。
private final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []

    func append(_ phase: String) {
        lock.lock()
        phases.append(phase)
        lock.unlock()
    }

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return phases.last
    }
}

/// 服务夹具（不可变存储，构造后只读；DBConnection 自带连接锁）。
private struct IncrementalFaceHarness: @unchecked Sendable {
    let db: DBConnection
    let service: FaceKwService
    let faceRepo: FaceRepo
    let personRepo: PersonRepo
    let sessionId: String
    let store: VectorStore
    let dir: String
}

private struct ClusterSnapshot {
    let id: Int64
    let matchedPersonId: String?
    let binding: String?
    /// 成员引用的 observation_id（已排序；NULL 成员不计——增量会先清理幽灵行）。
    let memberObservationIds: [Int64]
    var memberCount: Int { memberObservationIds.count }
}

private func makeIncrementalFaceHarness(
    settings: [String: String] = [:]
) throws -> IncrementalFaceHarness {
    let db = try makeMigratedDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Run", source: "folder")
    let store = VectorStore()
    let dir = try makeTempDir()
    let faceRepo = FaceRepo(connection: db)
    let personRepo = PersonRepo(connection: db)
    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        faceRepo: faceRepo,
        personRepo: personRepo,
        connection: db,
        getNumber: { _, defaultValue in defaultValue },
        getString: { key, defaultValue in settings[key] ?? defaultValue },
        decodeProvider: { path, _ in Data(path.utf8) },
        inferenceProvider: { images, _, _ in
            images.map { data in
                let path = String(decoding: data, as: UTF8.self)
                guard let vector = store.vector(path) else {
                    return FaceInferenceItem(error: "unknown fixture photo")
                }
                return FaceInferenceItem(observations: [
                    FaceInferenceObservation(
                        bbox: [1, 2, 3, 4], confidence: 0.95,
                        embedding: vector.map(Double.init), quality: 1.0,
                        faceSizePx: 80, rollDegrees: 0),
                ])
            }
        }
    )
    return IncrementalFaceHarness(
        db: db, service: service, faceRepo: faceRepo, personRepo: personRepo,
        sessionId: session.id, store: store, dir: dir)
}

/// 建真实临时文件 + photos 行 + 向量表登记（analyze 的 stat 需要真实文件）。
@discardableResult
private func addFacePhoto(
    _ harness: IncrementalFaceHarness, id: String, vector: [Float]
) throws -> String {
    let path = try writeTempFile(in: harness.dir, name: "\(id).jpg")
    try insertPhoto(harness.db, id: id, sessionId: harness.sessionId, filepath: path)
    harness.store.set(path, vector)
    return path
}

private func runAnalyze(
    _ harness: IncrementalFaceHarness, eps: Double = 0.6
) async throws -> FaceAnalysisResult {
    try await harness.service.analyze(
        sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx", eps: eps)
}

private func clusterSnapshots(_ harness: IncrementalFaceHarness) throws -> [ClusterSnapshot] {
    try harness.faceRepo.getClusters(harness.sessionId, includeMembers: true).map { cluster in
        ClusterSnapshot(
            id: cluster.id,
            matchedPersonId: cluster.matchedPersonId,
            binding: cluster.binding?.roleName,
            memberObservationIds: (cluster.members ?? []).compactMap(\.observationId).sorted())
    }.sorted { $0.id < $1.id }
}

/// 观察级成员划分（簇内升序 + 簇间字典序）：用于"增量 vs 全量"收敛断言。
private func observationPartition(_ harness: IncrementalFaceHarness) throws -> [[Int64]] {
    try clusterSnapshots(harness)
        .map(\.memberObservationIds)
        .filter { !$0.isEmpty }
        .sorted { $0.lexicographicallyPrecedes($1) }
}

// MARK: - FaceKwService 增量接线

@Suite("FaceKwService 增量聚类接线")
struct FaceKwIncrementalServiceTests {
    @Test("增量保留簇 id / matched_person_id / 角色绑定；全量重建会丢这些身份")
    func incrementalPreservesClusterIdentity() async throws {
        let harness = try makeIncrementalFaceHarness()
        try addFacePhoto(harness, id: "p1", vector: e0)
        try addFacePhoto(harness, id: "p2", vector: e0)
        try addFacePhoto(harness, id: "p3", vector: e1)
        try addFacePhoto(harness, id: "p4", vector: e1)
        let first = try await runAnalyze(harness)
        #expect(first.status == "done")
        let before = try clusterSnapshots(harness)
        #expect(before.count == 2)

        // 簇 A（e0）绑角色 "Alice"；簇 B（e1）挂 Bob 的跨会话匹配建议（无绑定）。
        let boundClusterId = before[0].id
        let matchedClusterId = before[1].id
        try harness.faceRepo.updateBinding(clusterId: boundClusterId, roleName: "Alice", keywords: [])
        let bob = try harness.personRepo.create(name: "Bob")
        try harness.faceRepo.setClusterMatch(clusterId: matchedClusterId, personId: bob, confidence: 0.8)

        // 新增两张同人照片 → 第二次 analyze 走增量（签名未变 + 已有簇 + 有新观测）。
        try addFacePhoto(harness, id: "p5", vector: e0)
        try addFacePhoto(harness, id: "p6", vector: e1)
        let second = try await runAnalyze(harness)
        #expect(second.status == "done")
        let afterIncremental = try clusterSnapshots(harness)
        #expect(afterIncremental.map(\.id) == before.map(\.id))
        #expect(afterIncremental[0].binding == "Alice")
        #expect(afterIncremental[1].matchedPersonId == bob)
        #expect(afterIncremental[0].memberCount == 3)
        #expect(afterIncremental[1].memberCount == 3)

        // 增量路径必须把 face_cluster_state 写成当前签名：无变化的第三次 analyze 应
        // 命中"缓存簇"快路径（若签名没更新，这里会再走一次全量并重建簇）。
        let phases = PhaseCollector()
        _ = try await harness.service.analyze(
            sessionId: harness.sessionId, detectorPath: "det.onnx", encoderPath: "enc.onnx",
            onProgress: { _, _, phase in phases.append(phase) })
        #expect(phases.last == "face.cached-clusters")
        #expect(try clusterSnapshots(harness).map(\.id) == afterIncremental.map(\.id))

        // 对照：recluster 命令走全量 → 删簇重建，id 全换，Bob 的匹配建议丢失。
        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)
        let afterFull = try clusterSnapshots(harness)
        #expect(afterFull.count == 2)
        #expect(Set(afterFull.map(\.id)).isDisjoint(with: Set(before.map(\.id))))
        #expect(afterFull.allSatisfy { $0.matchedPersonId != bob })
        // 角色绑定经"成员重叠迁移"幸存（既有缓解），但簇身份行已经换了。
        #expect(afterFull.contains { $0.binding == "Alice" })
    }

    @Test("聚类签名变化 → 走全量重建并更新 face_cluster_state 签名")
    func signatureChangeForcesFullRebuild() async throws {
        let harness = try makeIncrementalFaceHarness()
        try addFacePhoto(harness, id: "p1", vector: e0)
        try addFacePhoto(harness, id: "p2", vector: e0)
        _ = try await runAnalyze(harness, eps: 0.6)
        let idsBefore = try clusterSnapshots(harness).map(\.id)
        let options = FaceKwService.clusterOptions(from: { _, defaultValue in defaultValue })
        #expect(
            try harness.faceRepo.getClusterSignature(harness.sessionId)
                == FaceKwService.clusterSignature(eps: 0.6, minPts: 2, options: options))

        // eps 6.0 → 5.0：签名失配（不是"新增观测"的问题），必须全量重建。
        try addFacePhoto(harness, id: "p3", vector: e0)
        _ = try await runAnalyze(harness, eps: 0.5)
        let idsAfter = try clusterSnapshots(harness).map(\.id)
        #expect(
            try harness.faceRepo.getClusterSignature(harness.sessionId)
                == FaceKwService.clusterSignature(eps: 0.5, minPts: 2, options: options))
        #expect(Set(idsAfter).isDisjoint(with: Set(idsBefore)))
        #expect(idsAfter.count == 1)
    }

    @Test("face_incremental_clustering：默认 \"1\" 开增量；\"0\" 与其它值关闭走全量")
    func settingTogglesIncrementalPath() async throws {
        func run(setting: String?) async throws -> (before: [Int64], after: [Int64], members: Int) {
            let harness = try makeIncrementalFaceHarness(
                settings: setting.map { ["face_incremental_clustering": $0] } ?? [:])
            try addFacePhoto(harness, id: "p1", vector: e0)
            try addFacePhoto(harness, id: "p2", vector: e0)
            _ = try await runAnalyze(harness)
            let before = try clusterSnapshots(harness).map(\.id)
            try addFacePhoto(harness, id: "p3", vector: e0)
            _ = try await runAnalyze(harness)
            let after = try clusterSnapshots(harness)
            return (before, after.map(\.id), after.first?.memberCount ?? 0)
        }

        // 未设置 → 默认 "1"：簇 id 保留、成员从 2 增到 3 = 增量。
        let enabled = try await run(setting: nil)
        #expect(enabled.before == enabled.after)
        #expect(enabled.members == 3)
        // "0"：簇 id 全换 = 全量；成员照样是 3。
        let disabled = try await run(setting: "0")
        #expect(disabled.before != disabled.after)
        #expect(disabled.members == 3)
        // 非 "1" 的其它写法（如 "true"）视为关闭（避免 "true"/"1" 解析歧义）。
        let literalTrue = try await run(setting: "true")
        #expect(literalTrue.before != literalTrue.after)
    }

    @Test("增量后再次全量重聚类：成员划分收敛一致（不制造全量不会产生的划分）")
    func incrementalThenFullReclusterConverges() async throws {
        let harness = try makeIncrementalFaceHarness()
        try addFacePhoto(harness, id: "p1", vector: e0)
        try addFacePhoto(harness, id: "p2", vector: e0)
        try addFacePhoto(harness, id: "p3", vector: e1)
        try addFacePhoto(harness, id: "p4", vector: e1)
        _ = try await runAnalyze(harness)
        try addFacePhoto(harness, id: "p5", vector: e0)
        try addFacePhoto(harness, id: "p6", vector: e1)
        _ = try await runAnalyze(harness)
        let incrementalPartition = try observationPartition(harness)
        let incrementalIds = try clusterSnapshots(harness).map(\.id)

        try await harness.service.recluster(sessionId: harness.sessionId, eps: 0.6, minPts: 2)
        let fullPartition = try observationPartition(harness)
        let fullIds = try clusterSnapshots(harness).map(\.id)
        #expect(incrementalPartition == fullPartition)
        // 全量确实重建过（ids 全换），划分仍一致 ⇒ 增量没有制造"全量永远得不到"的簇。
        #expect(Set(incrementalIds).isDisjoint(with: Set(fullIds)))
    }

    @Test("失效的幽灵成员（observation_id = NULL）在增量落库时清理，不产生重复成员")
    func ghostMembersArePrunedOnIncrementalRun() async throws {
        let harness = try makeIncrementalFaceHarness()
        try addFacePhoto(harness, id: "p1", vector: e0)
        try addFacePhoto(harness, id: "p2", vector: e0)
        _ = try await runAnalyze(harness)
        let before = try clusterSnapshots(harness)
        #expect(before.count == 1)
        #expect(before[0].memberCount == 2)

        // 模拟 Indexer 的内容失效效果：p2 的观察被删、成员引用被置 NULL，但聚类签名
        // 保留（本用例只验证幽灵清理；签名失效路径由上面的用例覆盖 → 走全量）。
        let staleRow = try harness.db.prepare(
            "SELECT id FROM face_observations WHERE session_id = ? AND photo_id = 'p2'"
        ).get([.text(harness.sessionId)])
        let staleObservationId = try #require(staleRow?[0].intValue)
        _ = try harness.db.prepare(
            "UPDATE face_cluster_members SET observation_id = NULL WHERE session_id = ? AND observation_id = ?"
        ).run([.text(harness.sessionId), .int(staleObservationId)])
        _ = try harness.db.prepare("DELETE FROM face_observations WHERE id = ?")
            .run([.int(staleObservationId)])

        // 新增 p3（同人）→ 增量：清理 NULL 幽灵行 + 追加新成员，不出现同一照片两行。
        try addFacePhoto(harness, id: "p3", vector: e0)
        _ = try await runAnalyze(harness)
        let after = try clusterSnapshots(harness)
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after[0].memberCount == 2)
        #expect(Set(after[0].memberObservationIds).count == after[0].memberObservationIds.count)
        let ghosts = try harness.db.prepare(
            "SELECT COUNT(*) FROM face_cluster_members WHERE session_id = ? AND observation_id IS NULL"
        ).get([.text(harness.sessionId)])?[0].intValue
        #expect(ghosts == 0)
    }
}
