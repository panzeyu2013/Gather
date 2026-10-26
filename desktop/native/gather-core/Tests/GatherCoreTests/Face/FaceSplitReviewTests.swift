// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceSplitReviewTests.swift
// P0 / F0：拆分、约束保持、复核队列的集成测试（真实 SQLite + Schema V3）。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherApplication
@testable import GatherPersistence
@testable import GatherProtocol

private func makeFixture() throws -> (db: DBConnection, sessionId: String, faceRepo: FaceRepo, service: FaceKwService) {
    let db = try makeTestDB()
    let sessions = SessionRepo(connection: db)
    let session = try sessions.create(name: "F0", source: "folder")
    let faces = FaceRepo(connection: db)
    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessions,
        faceRepo: faces,
        personRepo: PersonRepo(connection: db),
        connection: db,
        getNumber: { _, defaultValue in defaultValue }
    )
    return (db, session.id, faces, service)
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, created_at, updated_at)
        VALUES (?, ?, ?, 't', 't')
        """).run([.text(id), .text(sessionId), .text("/photos/\(id).jpg")])
}

@discardableResult
private func addMember(
    _ faces: FaceRepo,
    sessionId: String,
    photoId: String,
    embedding: [Float],
    quality: Double = 0.9,
    faceSize: Double = 160
) throws -> (memberId: Int64, observationId: Int64) {
    let observationIds = try faces.replaceObservationsByPhoto(
        sessionId: sessionId,
        photoId: photoId,
        observations: [
            FaceObservationInput(
                photoId: photoId,
                bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.2,
                embedding: embedding,
                confidence: 0.9,
                analysisSignature: "sig",
                quality: quality,
                faceSizePx: faceSize
            )
        ]
    )
    return (0, observationIds[0])
}

@Suite("F0 拆分与复核")
struct FaceSplitReviewTests {

    @Test("拆分：新簇/成员移动/separate 约束；全选与绑定簇拒绝")
    func splitCreatesConstraintAndGuards() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        try insertPhoto(fixture.db, id: "p1", sessionId: fixture.sessionId)
        try insertPhoto(fixture.db, id: "p2", sessionId: fixture.sessionId)
        try insertPhoto(fixture.db, id: "p3", sessionId: fixture.sessionId)
        try insertPhoto(fixture.db, id: "p4", sessionId: fixture.sessionId)
        var members: [FaceClusterMemberInput] = []
        let embeddingSets: [[Float]] = [[1, 0], [0.98, 0.02], [0.97, 0.03], [0.96, 0.04]]
        for (index, embedding) in embeddingSets.enumerated() {
            let photoId = "p\(index + 1)"
            let added = try addMember(fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId, embedding: embedding)
            members.append(FaceClusterMemberInput(
                photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9, observationId: added.observationId))
        }
        let clusterId = try fixture.faceRepo.saveClusters(
            sessionId: fixture.sessionId,
            clusters: [FaceClusterInput(label: "Person 1", members: members)]
        )[0]
        let full = try fixture.faceRepo.getClusterMembersFull(clusterId: clusterId)
        #expect(try fixture.faceRepo.reviewRevision(sessionId: fixture.sessionId) != nil)
        // 先填充复核缓存，拆分后 revision 必须使旧缓存失效。
        let before = try fixture.service.review(FaceReviewInput(
            sessionId: fixture.sessionId, limit: 10, includeResolved: true))
        #expect(before.clusters.count == 1)

        let result = try fixture.service.splitCluster(
            sessionId: fixture.sessionId, clusterId: clusterId,
            memberIds: [full[0].id, full[1].id])
        #expect(result.movedCount == 2)
        #expect(result.remainingCount == 2)
        let after = try fixture.service.review(FaceReviewInput(
            sessionId: fixture.sessionId, limit: 10, includeResolved: true))
        #expect(after.clusters.count == 2)
        let constraints = try fixture.faceRepo.getConstraints(sessionId: fixture.sessionId)
        #expect(constraints.count == 1)
        #expect(constraints[0].kind == .separate)
        #expect(constraints[0].memberKeys.count == 2)
        #expect(constraints[0].peerKeys.count == 2)

        #expect(throws: FaceKwServiceError.splitKeepOne) {
            _ = try fixture.service.splitCluster(
                sessionId: fixture.sessionId, clusterId: clusterId,
                memberIds: (try fixture.faceRepo.getClusterMembersFull(clusterId: clusterId)).map(\.id))
        }
        try fixture.service.bindCluster(
            sessionId: fixture.sessionId, clusterId: clusterId, roleName: "Bride", keywords: ["bride"])
        #expect(throws: FaceKwServiceError.clusterBound) {
            _ = try fixture.service.splitCluster(
                sessionId: fixture.sessionId, clusterId: clusterId,
                memberIds: [full[0].id])
        }
    }

    @Test("重聚类后 separate 仍保持（applyClusterConstraints）")
    func constraintSurvivesRecluster() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        try insertPhoto(fixture.db, id: "a1", sessionId: fixture.sessionId)
        try insertPhoto(fixture.db, id: "a2", sessionId: fixture.sessionId)
        try insertPhoto(fixture.db, id: "a3", sessionId: fixture.sessionId)
        try insertPhoto(fixture.db, id: "a4", sessionId: fixture.sessionId)
        var members: [FaceClusterMemberInput] = []
        let embeddingSets: [[Float]] = [[1, 0], [0.99, 0.01], [0.98, 0.02], [0.97, 0.03]]
        for (index, embedding) in embeddingSets.enumerated() {
            let photoId = "a\(index + 1)"
            let added = try addMember(fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId, embedding: embedding)
            members.append(FaceClusterMemberInput(
                photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9, observationId: added.observationId))
        }
        let clusterId = try fixture.faceRepo.saveClusters(
            sessionId: fixture.sessionId,
            clusters: [FaceClusterInput(label: "Person 1", members: members)]
        )[0]
        let full = try fixture.faceRepo.getClusterMembersFull(clusterId: clusterId)
        let split = try fixture.service.splitCluster(
            sessionId: fixture.sessionId, clusterId: clusterId,
            memberIds: [full[0].id, full[1].id])

        // 模拟全量 recluster：把所有成员合回源簇、删除空的新簇。
        _ = try fixture.faceRepo.moveClusterMembers(
            memberIds: full.map(\.id), toClusterId: clusterId, sessionId: fixture.sessionId)
        _ = try fixture.faceRepo.deleteEmptyUnboundClusters(ids: [Int64(split.newClusterId)])
        #expect(try fixture.faceRepo.getClusters(fixture.sessionId).count == 1)

        let report = try fixture.service.applyClusterConstraints(sessionId: fixture.sessionId)
        #expect(report.separateApplied == 1)
        let clusters = try fixture.faceRepo.getClusters(fixture.sessionId)
        #expect(clusters.count == 2)
        let sizes = clusters.map(\.memberCount).sorted()
        #expect(sizes == [2, 2])
    }

    @Test("moveClusterMembers 期望簇守卫：陈旧快照不会搬走别人的成员")
    func guardedMoveRejectsStaleCluster() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        var clusters: [Int64] = []
        for photoId in ["g1", "g2"] {
            try insertPhoto(fixture.db, id: photoId, sessionId: fixture.sessionId)
            let added = try addMember(
                fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId,
                embedding: [1, 0])
            clusters.append(try fixture.faceRepo.saveClusters(
                sessionId: fixture.sessionId,
                clusters: [FaceClusterInput(label: "C-\(photoId)", members: [
                    FaceClusterMemberInput(
                        photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                        bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9,
                        observationId: added.observationId),
                ])]
            )[0])
        }
        let member = try #require(try fixture.faceRepo.getClusterMembersFull(clusterId: clusters[0]).first)
        // 陈旧快照（以为成员在 c2）：不应搬动，返回 0。
        let stale = try fixture.faceRepo.moveClusterMembers(
            memberIds: [member.id], toClusterId: clusters[1],
            sessionId: fixture.sessionId, expectedClusterId: clusters[1])
        #expect(stale == 0)
        #expect(try fixture.faceRepo.getClusterMembersFull(clusterId: clusters[0]).count == 1)
        // 正确期望：搬动成功。
        let moved = try fixture.faceRepo.moveClusterMembers(
            memberIds: [member.id], toClusterId: clusters[1],
            sessionId: fixture.sessionId, expectedClusterId: clusters[0])
        #expect(moved == 1)
        #expect(try fixture.faceRepo.getClusterMembersFull(clusterId: clusters[1]).count == 2)
    }

    @Test("绑定簇禁止合并，避免静默丢 role_bindings")
    func boundMergeRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        var clusters: [Int64] = []
        for photoId in ["b1", "b2"] {
            try insertPhoto(fixture.db, id: photoId, sessionId: fixture.sessionId)
            let added = try addMember(
                fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId,
                embedding: [1, 0])
            clusters.append(try fixture.faceRepo.saveClusters(
                sessionId: fixture.sessionId,
                clusters: [FaceClusterInput(label: "Person", members: [
                    FaceClusterMemberInput(
                        photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                        bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9,
                        observationId: added.observationId)
                ])])[0])
        }
        try fixture.faceRepo.updateBinding(
            clusterId: clusters[0], roleName: "Alice", keywords: ["Alice"])
        #expect(throws: FaceKwServiceError.self) {
            try fixture.service.mergeClusters(
                sessionId: fixture.sessionId, sourceId: clusters[0], targetId: clusters[1])
        }
    }

    @Test("review：未解析成员占多数时不污染 model 众数")
    func unresolvedMembersDoNotPoisonModelMode() {
        func member(_ id: Int64, model: String, embedding: [Float], observation: Int64?) -> FaceReviewMemberRow {
            FaceReviewMemberRow(
                clusterId: 1, clusterLabel: "Person 1", memberId: id,
                photoId: "p\(id)", photoPath: "/photos/p\(id).jpg",
                bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9,
                observationId: observation, embedding: embedding,
                quality: 0.9, faceSizePx: 160,
                modelId: model, modelVersion: "1")
        }
        var members: [FaceReviewMemberRow] = [
            member(1, model: "vision", embedding: [1, 0], observation: 1),
            member(2, model: "vision", embedding: [0.99, 0.01], observation: 2),
        ]
        for id in 3...12 {
            members.append(member(Int64(id), model: "", embedding: [], observation: nil))
        }
        let output = FaceReviewEngine.evaluate(
            [.init(clusterId: 1, label: "Person 1", members: members)],
            thresholds: .defaults)
        #expect(output.summaries.first?.cohesion != nil)
        let valid = output.items.filter { $0.memberId == 1 || $0.memberId == 2 }
        #expect(valid.allSatisfy { !$0.flags.contains(.incompatibleModel) })
    }

    @Test("review：suspect/低质量标记、分页与摘要")
    func reviewFlagsAndPagination() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        var members: [FaceClusterMemberInput] = []
        let embeddings: [[Float]] = [[1, 0], [0.98, 0.02], [0.97, 0.03], [0, 1]]
        for (index, embedding) in embeddings.enumerated() {
            let photoId = "r\(index + 1)"
            try insertPhoto(fixture.db, id: photoId, sessionId: fixture.sessionId)
            let added = try addMember(
                fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId,
                embedding: embedding,
                quality: index == 3 ? 0.1 : 0.9,
                faceSize: index == 3 ? 20 : 160)
            members.append(FaceClusterMemberInput(
                photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9, observationId: added.observationId))
        }
        let clusterId = try fixture.faceRepo.saveClusters(
            sessionId: fixture.sessionId,
            clusters: [FaceClusterInput(label: "Person 1", members: members)]
        )[0]

        let reviewOnly = try fixture.service.review(FaceReviewInput(
            sessionId: fixture.sessionId, clusterId: Int(clusterId), limit: 10, includeResolved: false))
        #expect(reviewOnly.total == 1)
        #expect(reviewOnly.items.count == 1)
        #expect(reviewOnly.nextCursor == nil)
        #expect(reviewOnly.suspectTotal == 0)
        #expect(reviewOnly.clusters.first?.clusterId == Int(clusterId))
        #expect(reviewOnly.items.first?.flags.contains(.lowQuality) == true)

        let all = try fixture.service.review(FaceReviewInput(
            sessionId: fixture.sessionId, clusterId: Int(clusterId), limit: 2, includeResolved: true))
        #expect(all.total == 4)
        #expect(all.items.count == 2)
        #expect(all.nextCursor != nil)

        let second = try fixture.service.review(FaceReviewInput(
            sessionId: fixture.sessionId, clusterId: Int(clusterId), cursor: all.nextCursor, limit: 10,
            includeResolved: true))
        #expect(second.items.count == 2)
    }

    @Test("split 只删除跨拆分两侧的 together，保留内部约束")
    func splitKeepsInternalTogether() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        var members: [FaceClusterMemberInput] = []
        var keys: [String: FaceClusterConstraintKey] = [:]
        for (index, photoId) in ["t1", "t2", "t3"].enumerated() {
            try insertPhoto(fixture.db, id: photoId, sessionId: fixture.sessionId)
            let added = try addMember(
                fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId,
                embedding: [1, Float(index) * 0.01])
            keys[photoId] = FaceClusterConstraintKey(
                observationId: added.observationId, photoId: photoId,
                bbox: [0.1, 0.1, 0.2, 0.2])
            members.append(FaceClusterMemberInput(
                photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9,
                observationId: added.observationId))
        }
        let clusterId = try fixture.faceRepo.saveClusters(
            sessionId: fixture.sessionId,
            clusters: [FaceClusterInput(label: "Person 1", members: members)])[0]
        _ = try fixture.faceRepo.insertConstraint(
            sessionId: fixture.sessionId, kind: .together,
            memberKeys: [keys["t1"]!, keys["t2"]!], peerKeys: [])
        let full = try fixture.faceRepo.getClusterMembersFull(clusterId: clusterId)
        let target = full.first { $0.photoId == "t3" }!

        _ = try fixture.service.splitCluster(
            sessionId: fixture.sessionId, clusterId: clusterId,
            memberIds: [target.id])
        let together = try fixture.faceRepo.getConstraints(sessionId: fixture.sessionId)
            .filter { $0.kind == .together }
        #expect(together.count == 1)
        #expect(Set(together[0].memberKeys.map(\.photoId)) == ["t1", "t2"])
    }

    @Test("merge 只删除 source/target 之间的 separate，保留外部约束")
    func mergeKeepsExternalSeparate() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        var clusters: [Int64] = []
        var keys: [String: FaceClusterConstraintKey] = [:]
        for (index, photoId) in ["s1", "s2", "s3"].enumerated() {
            try insertPhoto(fixture.db, id: photoId, sessionId: fixture.sessionId)
            let added = try addMember(
                fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId,
                embedding: index == 2 ? [0, 1] : [1, Float(index) * 0.01])
            keys[photoId] = FaceClusterConstraintKey(
                observationId: added.observationId, photoId: photoId,
                bbox: [0.1, 0.1, 0.2, 0.2])
            clusters.append(try fixture.faceRepo.saveClusters(
                sessionId: fixture.sessionId,
                clusters: [FaceClusterInput(label: "Person \(index + 1)", members: [
                    FaceClusterMemberInput(
                        photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                        bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9,
                        observationId: added.observationId)
                ])])[0])
        }
        _ = try fixture.faceRepo.insertConstraint(
            sessionId: fixture.sessionId, kind: .separate,
            memberKeys: [keys["s1"]!], peerKeys: [keys["s3"]!])

        try fixture.service.mergeClusters(
            sessionId: fixture.sessionId, sourceId: clusters[0], targetId: clusters[1])
        let constraints = try fixture.faceRepo.getConstraints(sessionId: fixture.sessionId)
        let separate = constraints.filter { $0.kind == .separate }
        #expect(separate.count == 1)
        #expect(Set(separate[0].memberKeys.map(\.photoId)).contains("s1"))
        #expect(Set(separate[0].peerKeys.map(\.photoId)).contains("s3"))
    }

    @Test("拆分后合并：separate 删除、together 写入（可逆）")
    func mergeAfterSplitReversesConstraint() throws {
        let fixture = try makeFixture()
        defer { fixture.db.close() }
        var members: [FaceClusterMemberInput] = []
        let embeddingSets: [[Float]] = [[1, 0], [0.99, 0.01], [0.98, 0.02], [0.97, 0.03]]
        for (index, embedding) in embeddingSets.enumerated() {
            let photoId = "m\(index + 1)"
            try insertPhoto(fixture.db, id: photoId, sessionId: fixture.sessionId)
            let added = try addMember(
                fixture.faceRepo, sessionId: fixture.sessionId, photoId: photoId, embedding: embedding)
            members.append(FaceClusterMemberInput(
                photoId: photoId, photoPath: "/photos/\(photoId).jpg",
                bbox: [0.1, 0.1, 0.2, 0.2], confidence: 0.9, observationId: added.observationId))
        }
        let clusterId = try fixture.faceRepo.saveClusters(
            sessionId: fixture.sessionId,
            clusters: [FaceClusterInput(label: "Person 1", members: members)]
        )[0]
        let full = try fixture.faceRepo.getClusterMembersFull(clusterId: clusterId)
        let split = try fixture.service.splitCluster(
            sessionId: fixture.sessionId, clusterId: clusterId,
            memberIds: [full[0].id, full[1].id])
        #expect(try fixture.faceRepo.getConstraints(sessionId: fixture.sessionId).count == 1)

        try fixture.service.mergeClusters(
            sessionId: fixture.sessionId,
            sourceId: Int64(split.newClusterId),
            targetId: clusterId)

        #expect(try fixture.faceRepo.getClusters(fixture.sessionId).count == 1)
        let constraints = try fixture.faceRepo.getConstraints(sessionId: fixture.sessionId)
        #expect(!constraints.contains { $0.kind == .separate })
        #expect(constraints.contains { $0.kind == .together })
    }
}
