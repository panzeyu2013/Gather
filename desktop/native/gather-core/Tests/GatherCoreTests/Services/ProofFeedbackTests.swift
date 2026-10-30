// desktop/native/gather-core/Tests/GatherCoreTests/Services/ProofFeedbackTests.swift
// P1 下一波：客户校样反馈 v2（解析 / 冲突 / 幂等 / 端口断言）。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

private final class FakePickApplier: ProofPickApplying {
    var calls: [[String]] = []
    var applied = 0
    var failed = 0
    var skipFirstN = 0

    func applyImportedPicks(
        sessionId: String, photoIds: [String]
    ) throws -> (applied: Int, failed: Int) {
        calls.append(photoIds)
        let usable = max(0, photoIds.count - skipFirstN)
        return (applied == 0 ? usable : min(applied, usable), failed)
    }
}

private final class FakeMetadataQueue: ProofMetadataQueueing {
    struct Call: Equatable {
        let photoId: String
        let rating: Int?
        let label: String?
    }

    var calls: [Call] = []

    @discardableResult
    func queueRatingLabel(
        sessionId: String, photoId: String, rating: Int?, label: String?
    ) throws -> Bool {
        calls.append(Call(photoId: photoId, rating: rating, label: label))
        return true
    }
}

@Suite("客户校样反馈（v2）")
struct ProofFeedbackTests {
    private static let submitted = "2026-10-29T12:00:00.000Z"

    private func makeSession(_ db: DBConnection) throws -> String {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-proof-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let session = try SessionRepo(connection: db).create(
            name: "Proof", source: "local", sourcePath: source.path)
        return session.id
    }

    private func seedPhoto(_ db: DBConnection, sessionId: String, photoId: String) throws {
        let path = "/tmp/gather-proof-\(photoId).jpg"
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
              asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, '', 'ready', NULL, NULL, 100, 100,
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([
            .text(photoId), .text(sessionId), .text(path), .text(photoId + ".jpg"),
        ])
    }

    private func seedCache(
        _ db: DBConnection, sessionId: String, photoId: String,
        rating: Int, label: String, updatedAt: String
    ) throws {
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, rating, label, keywords, cached_at, updated_at)
            VALUES (?, ?, ?, ?, '[]', ?, ?)
        """).run([
            .text(photoId), .text(sessionId), .int(Int64(rating)), .text(label),
            .text(updatedAt), .text(updatedAt),
        ])
    }

    private func makeService(
        _ db: DBConnection,
        applyRating: Bool = true,
        picks: FakePickApplier = FakePickApplier(),
        queue: FakeMetadataQueue = FakeMetadataQueue()
    ) -> (ProofFeedbackService, FakePickApplier, FakeMetadataQueue) {
        let service = ProofFeedbackService(
            repo: ProofFeedbackRepo(connection: db),
            picks: picks,
            metadata: queue,
            getString: { key, defaultValue in
                key == ProofFeedbackService.applyRatingSettingKey
                    ? (applyRating ? "1" : "0") : defaultValue
            },
            now: { Date(timeIntervalSince1970: 1_760_000_000) })
        return (service, picks, queue)
    }

    private func v2JSON(items: String, submittedAt: String? = submitted) -> Data {
        let stamp = submittedAt.map { ",\"submittedAt\":\"\($0)\"" } ?? ""
        return Data("""
        {"version":2,"title":"婚礼 A 场"\(stamp),"items":[\(items)]}
        """.utf8)
    }

    // MARK: - 解析

    @Test("v1 兼容：picks 仍可解，勾选项进入 pickedPhotoIds")
    func parsesV1() throws {
        let json = Data("""
        {"version":1,"title":"Proof","picks":[
          {"id":"p1","name":"a.jpg","pick":true},
          {"id":"p2","name":"b.jpg","pick":false}
        ]}
        """.utf8)
        let parsed = try ClientSelectionParser.parse(json)
        #expect(parsed.version == 1)
        #expect(parsed.pickedPhotoIds == ["p1"])
        #expect(parsed.items.count == 2)
        #expect(parsed.items[1].pick == false)
    }

    @Test("v2：items + rating/label/comment；非法 rating 夹取、未知色标归一为无")
    func parsesV2() throws {
        let json = v2JSON(items: """
        {"id":"p1","name":"a.jpg","pick":true,"rating":9,"label":"green",
         "comment":" 这张做主图 "},
        {"id":"p2","name":"b.jpg","pick":false,"rating":-3,"label":"Rainbow"}
        """)
        let parsed = try ClientSelectionParser.parse(json)
        #expect(parsed.version == 2)
        #expect(parsed.items[0].rating == 5, "rating 必须夹到 0…5")
        #expect(parsed.items[0].label == "Green", "色标归一成 C1 规范名")
        #expect(parsed.items[0].comment == "这张做主图", "评论去首尾空白")
        #expect(parsed.items[1].rating == 0)
        #expect(parsed.items[1].label == nil, "未知色标按无处理")
        #expect(parsed.pickedPhotoIds == ["p1"])
    }

    @Test("重复 id 去重并计数；空 id 计入 invalid")
    func dedupesIDs() throws {
        let json = v2JSON(items: """
        {"id":"p1","pick":true},{"id":"p1","pick":true},{"id":"","pick":true}
        """)
        let parsed = try ClientSelectionParser.parse(json)
        #expect(parsed.items.count == 1)
        #expect(parsed.duplicateCount == 1)
        #expect(parsed.invalidCount == 1)
    }

    @Test("坏 JSON 抛 INVALID_PARAM（不新增错误码）")
    func rejectsBadJSON() {
        do {
            _ = try ClientSelectionParser.parse(Data("not-json".utf8))
            Issue.record("坏 JSON 必须抛错")
        } catch let error as ClientSelectionError {
            #expect(error.code == GatherErrorCode.INVALID_PARAM.rawValue)
        } catch {
            Issue.record("错误类型应为 ClientSelectionError")
        }
    }

    // MARK: - 导入

    @Test("v2 导入：勾选 + 评分/色标入队 + 评论落库")
    func importsV2() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        try seedPhoto(db, sessionId: sessionId, photoId: "p2")
        let (service, picks, queue) = makeService(db)
        let json = v2JSON(items: """
        {"id":"p1","pick":true,"rating":4,"label":"Green","comment":"这张做主图"},
        {"id":"p2","pick":true}
        """)
        let report = try service.`import`(sessionId: sessionId, data: json)
        #expect(report.picked == 2)
        #expect(picks.calls == [["p1", "p2"]])
        #expect(report.ratingApplied == 1)
        #expect(report.labelApplied == 1)
        #expect(report.comments == 1)
        #expect(report.conflicts.isEmpty)
        #expect(queue.calls == [FakeMetadataQueue.Call(
            photoId: "p1", rating: 4, label: "Green")])
        // 原始反馈落库（含评论），且 batch_id = 内容哈希。
        let rows = try ProofFeedbackRepo(connection: db).rows(
            batchId: ProofFeedbackService.batchId(for: json))
        #expect(rows.count == 2)
        #expect(rows.contains { $0.comment == "这张做主图" })
        // 被消费的行要标 applied_at（审计：这一行有没有被应用）。
        #expect(rows.contains { $0.isApplied })
    }

    @Test("未知 id：跳过但计数，不落库、不应用")
    func skipsUnknownIDs() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        let (service, picks, _) = makeService(db)
        let json = v2JSON(items: """
        {"id":"p1","pick":true},{"id":"ghost","pick":true,"rating":5}
        """)
        let report = try service.`import`(sessionId: sessionId, data: json)
        #expect(picks.calls == [["p1"]], "未知 id 不得进入应用批次")
        #expect(report.skipped >= 1)
        let rows = try ProofFeedbackRepo(connection: db).rows(
            batchId: ProofFeedbackService.batchId(for: json))
        #expect(rows.count == 1, "未知 id 不落库")
    }

    @Test("幂等：同一份文件第二次导入 0 变更")
    func idempotent() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        let (service, picks, queue) = makeService(db)
        let json = v2JSON(items: """
        {"id":"p1","pick":true,"rating":4,"label":"Green"}
        """)
        _ = try service.`import`(sessionId: sessionId, data: json)
        let second = try service.`import`(sessionId: sessionId, data: json)
        #expect(second.alreadyImported)
        #expect(second.applied == 0)
        #expect(picks.calls.count == 1)
        #expect(queue.calls.count == 1)
    }

    @Test("设置关闭（proof_feedback_apply_rating=0）：只落库，不入队")
    func doesNotApplyRatingWhenDisabled() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        let (service, _, queue) = makeService(db, applyRating: false)
        let json = v2JSON(items: """
        {"id":"p1","pick":true,"rating":4,"label":"Green"}
        """)
        let report = try service.`import`(sessionId: sessionId, data: json)
        #expect(queue.calls.isEmpty, "关闭时不得改动本地评分/色标")
        #expect(report.ratingApplied == 0)
        let rows = try ProofFeedbackRepo(connection: db).rows(
            batchId: ProofFeedbackService.batchId(for: json))
        #expect(rows.first?.rating == 4, "反馈本身仍要落库")
    }

    @Test("冲突：本地比客户提交更新 → 保留本地并上报")
    func reportsConflict() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        // 本地在客户提交之后改过（2026-12 > 2026-10-29）。
        try seedCache(db, sessionId: sessionId, photoId: "p1",
                      rating: 5, label: "Red", updatedAt: "2026-12-01T00:00:00.000Z")
        let (service, _, queue) = makeService(db)
        let json = v2JSON(items: """
        {"id":"p1","rating":2,"label":"Blue"}
        """)
        let report = try service.`import`(sessionId: sessionId, data: json)
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.localRating == 5)
        #expect(report.conflicts.first?.clientRating == 2)
        #expect(queue.calls.isEmpty, "冲突时不得覆盖本地值")
    }

    @Test("客户更新：本地更新时间早于提交 → 直接采用客户值")
    func appliesWhenClientIsNewer() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        try seedCache(db, sessionId: sessionId, photoId: "p1",
                      rating: 5, label: "Red", updatedAt: "2026-01-01T00:00:00.000Z")
        let (service, _, queue) = makeService(db)
        let json = v2JSON(items: """
        {"id":"p1","rating":2,"label":"Blue"}
        """)
        let report = try service.`import`(sessionId: sessionId, data: json)
        #expect(report.conflicts.isEmpty)
        #expect(queue.calls == [FakeMetadataQueue.Call(
            photoId: "p1", rating: 2, label: "Blue")])
    }

    @Test("只有评论：不进入评分/色标入队（不写 XMP）")
    func commentOnly() throws {
        let db = try makeTestDB()
        let sessionId = try makeSession(db)
        try seedPhoto(db, sessionId: sessionId, photoId: "p1")
        let (service, _, queue) = makeService(db)
        let json = v2JSON(items: """
        {"id":"p1","comment":"换了裁切更好"}
        """)
        let report = try service.`import`(sessionId: sessionId, data: json)
        #expect(report.comments == 1)
        #expect(queue.calls.isEmpty)
        #expect(try service.comments(sessionId: sessionId)["p1"] == "换了裁切更好")
    }

    @Test("batch_id 只取决于内容：同内容同 id，改一个字就换 id")
    func batchIdIsContentHash() {
        let a = Data("{\"version\":2,\"items\":[]}".utf8)
        let b = Data("{\"version\":2,\"items\":[ ]}".utf8)
        #expect(ProofFeedbackService.batchId(for: a).count == 12)
        #expect(ProofFeedbackService.batchId(for: a) == ProofFeedbackService.batchId(for: a))
        #expect(ProofFeedbackService.batchId(for: a) != ProofFeedbackService.batchId(for: b))
    }
}
