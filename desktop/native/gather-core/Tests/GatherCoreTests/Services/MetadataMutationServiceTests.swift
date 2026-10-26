// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataMutationServiceTests.swift
// Cut 2 / S5c-2b-3b-2b-2：手动元数据队列的交付模型门禁。
//
// 迁移前（旧 outbox）的行为由 MetadataSyncCoordinator 的测试覆盖；本文件只断言
// 新落点：
// 1. queuePhotoValues → deliveries(pending, revision+1) + delivery_items
//    (module=.metadata, attributes rating/label, keywords 列, 会话链接)；
// 2. 字段级合并（后写字段覆盖、未提及字段保留）与 revision 推进；
// 3. K0 delta（added/removed + owned）按盘上/未落盘基线计算净意图；
// 4. 刷盘由 WritebackService.execute 消费同一批 pending 项：rating/label 落盘、
//    关键词按 delta/merge 语义收敛；
// 5. 契约错误（空 values）不落任何交付行。
//
// 建库口径与 DeliveryRepoTests 一致：内存 DB + SchemaCurrent.createSQL（不跑迁移链）。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery

// MARK: - 假件

/// 可编程 XMP 假件：属性可注入，写盘/备份/恢复只记录（不触盘）。
private final class MutationTestXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttributes = MetadataWriteAttributes()
    private var storedWrites: [MetadataWriteAttributes] = []
    private var storedRestores: [(photoPath: String, backupPath: String)] = []
    private var existingPaths: Set<String> = []

    var attributes: MetadataWriteAttributes {
        get { lock.withLock { storedAttributes } }
        set { lock.withLock { storedAttributes = newValue } }
    }

    var writeCalls: [MetadataWriteAttributes] { lock.withLock { storedWrites } }
    var restoreCalls: [(photoPath: String, backupPath: String)] { lock.withLock { storedRestores } }

    var existingFiles: Set<String> {
        get { lock.withLock { existingPaths } }
        set { lock.withLock { existingPaths = newValue } }
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        lock.withLock { storedAttributes }.keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        lock.withLock { storedAttributes }
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        lock.withLock { storedWrites.append(attributes) }
    }

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {
        lock.withLock { storedRestores.append((photoPath, backupPath)) }
    }

    func fileExists(_ path: String) -> Bool { lock.withLock { existingPaths.contains(path) } }

    func removeFile(_ path: String) async throws {}
}

// MARK: - 夹具

private struct MutationFixture {
    let db: DBConnection
    let sessionId: String
    let photoId: String
    let photoPath: String
    let xmpPath: String
    let tempRoot: URL
    let xmp: MutationTestXMP
    let deliveryRepo: DeliveryRepo
    let mutations: MetadataMutationService
    let writeback: WritebackService

    init() throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec(SchemaCurrent.createSQL)
        let sessionId = "s-2b2"
        let photoId = "p-2b2"
        _ = try db.prepare("""
            INSERT INTO sessions (id, name, status, created_at, updated_at)
            VALUES (?, '', 'draft', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([.text(sessionId)])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-2b2-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photoPath = root.appendingPathComponent("IMG_1.jpg").path
        try Data("photo".utf8).write(to: URL(fileURLWithPath: photoPath))
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES (?, ?, ?, 'IMG_1.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([.text(photoId), .text(sessionId), .text(photoPath)])

        let xmp = MutationTestXMP()
        let deliveryRepo = DeliveryRepo(connection: db)
        let assetResolver = PhotoAssetResolver(connection: db)
        self.db = db
        self.sessionId = sessionId
        self.photoId = photoId
        self.photoPath = photoPath
        self.tempRoot = root
        self.xmp = xmp
        self.deliveryRepo = deliveryRepo
        // 与组合根同一接线：手动队列落交付项，执行器负责刷盘。
        self.xmpPath = TSPath.normalize(TSPath.xmpSidecarPath(photoPath))
        self.mutations = MetadataMutationService(
            deliveryRepo: deliveryRepo, xmp: xmp, assetResolver: assetResolver)
        self.writeback = WritebackService(
            deliveryRepo: deliveryRepo,
            xmp: xmp,
            photoRepo: PhotoRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            assetResolver: assetResolver
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
        db.close()
    }

    func item() throws -> DeliveryItemRow? {
        try deliveryRepo.item(xmpPath: xmpPath, photoId: photoId, module: .metadata)
    }

    func count(_ table: String) throws -> Int {
        guard let row = try db.prepare("SELECT COUNT(*) FROM \(table)").get([]) else { return 0 }
        return Int(row[0].intValue ?? 0)
    }
}

// MARK: - 用例

@Suite("S5c-2b-3b-2b-2 手动元数据队列")
struct MetadataMutationServiceTests {
    @Test("queuePhotoValues：落 deliveries(pending, revision+1) + metadata item + 会话链接")
    func queuePhotoValuesWritesDeliveryModel() throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }

        let result = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            values: ["rating": .number(4), "keywords": .array([.string("keep")])],
            source: .manual
        )

        #expect(result.photoId == fixture.photoId)
        #expect(result.xmpPath == fixture.xmpPath)
        #expect(Set(result.dirtyFields) == Set([.rating, .keywords]))
        #expect(result.revision == 1)
        #expect(result.status == DeliveryStatus.pending.rawValue)

        let delivery = try #require(try fixture.deliveryRepo.get(fixture.xmpPath))
        #expect(delivery.typedStatus == .pending)
        #expect(delivery.revision == 1)
        #expect(delivery.photoPath == fixture.photoPath)

        let item = try #require(try fixture.item())
        #expect(item.typedModule == .metadata)
        #expect(item.attributes["rating"] == .number(4))
        #expect(item.keywordList == ["keep"])
        // queuePhotoValues 给的是完整词表 → 权威覆盖模式。
        #expect(item.attributes[MetadataMutationService.keywordsModeKey]?.stringValue
            == MetadataKeywordWriteMode.replace.rawValue)
        #expect(item.typedStatus == .pending)

        // 会话链接 + 摘要都能看到这条交付。
        #expect(try fixture.deliveryRepo.conflictDeliveries(sessionId: fixture.sessionId).isEmpty)
        let summary = try fixture.deliveryRepo.metadataSummary(sessionId: fixture.sessionId)
        #expect(summary.pending == 1)
    }

    @Test("queuePhotoValues：字段级合并（后写覆盖同名字段，未提及字段保留）")
    func queuePhotoValuesMergesFields() throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }

        _ = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            values: ["rating": .number(4), "label": .string("Green")],
            source: .manual
        )
        // schedule=false 只影响旧计时器；交付模型里两次入队落库一致。
        let second = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            values: ["label": .string("Red")],
            source: .manual,
            schedule: false
        )

        #expect(second.dirtyFields == [.label])
        #expect(second.revision == 2)
        let item = try #require(try fixture.item())
        #expect(item.attributes["rating"] == .number(4))
        #expect(item.attributes["label"] == .string("Red"))
    }

    @Test("linkSession 失败整体回滚：revision 不推进、无 item、confirm 不被阻断")
    func linkSessionFailureRollsBackWholeEnqueue() throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }

        // 在 linkSession 的 INSERT 上注入失败（等价于会话并发删除 / FK 拒绝）。
        let linkFailureTrigger = """
            CREATE TRIGGER fail_delivery_session_link
            BEFORE INSERT ON delivery_sessions
            BEGIN SELECT RAISE(ABORT, 'forced link failure'); END;
            """
        try fixture.db.exec(linkFailureTrigger)

        #expect(throws: (any Error).self) {
            _ = try fixture.mutations.queuePhotoValues(
                sessionId: fixture.sessionId,
                photoId: fixture.photoId,
                values: ["rating": .number(5), "keywords": .array([.string("keep")])],
                source: .manual)
        }

        // 开行与 mergeItem 都已执行过，但 linkSession 失败必须整体回滚：
        // 没有交付行（revision 未推进）、没有 item、没有会话链接。
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath) == nil)
        #expect(try fixture.item() == nil)
        #expect(try fixture.count("deliveries") == 0)
        #expect(try fixture.count("delivery_items") == 0)
        #expect(try fixture.count("delivery_sessions") == 0)
        // 无 pending 孤儿 → 会话确认门禁不被阻断。
        let summary = try DeliverySummaryQuery(connection: fixture.db)
            .summary(sessionId: fixture.sessionId)
        #expect(summary.isEmpty)
        #expect(summary.isConfirmable)

        // 解除注入后重试同一输入：失败没有消耗 revision（首个成功输入仍是 revision 1），
        // item 与 link 由同一次提交落库。
        try fixture.db.exec("DROP TRIGGER fail_delivery_session_link")
        let first = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            values: ["rating": .number(5), "keywords": .array([.string("keep")])],
            source: .manual)
        #expect(first.revision == 1)
        #expect(first.status == DeliveryStatus.pending.rawValue)
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath)?.revision == 1)
        let queueItem = try #require(try fixture.item())
        #expect(queueItem.attributes["rating"] == .number(5))
        #expect(queueItem.keywordList == ["keep"])
        #expect(try fixture.count("delivery_sessions") == 1)

        // 已有输入上再次失败：revision 停在 1，item 保持上次提交值（无半提交）。
        try fixture.db.exec(linkFailureTrigger)
        #expect(throws: (any Error).self) {
            _ = try fixture.mutations.queuePhotoValues(
                sessionId: fixture.sessionId,
                photoId: fixture.photoId,
                values: ["rating": .number(1)],
                source: .manual)
        }
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath)?.revision == 1)
        let unchanged = try #require(try fixture.item())
        #expect(unchanged.attributes["rating"] == .number(5))
        #expect(unchanged.keywordList == ["keep"])
        #expect(try fixture.count("delivery_items") == 1)
        #expect(try fixture.count("delivery_sessions") == 1)
    }

    @Test("重复入队幂等：不产生重复交付/项/链接，字段保持最近输入")
    func repeatedEnqueueIsIdempotentForRows() throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }

        let values: [String: JSONValue] = [
            "rating": .number(4), "label": .string("Green"),
            "keywords": .array([.string("keep")]),
        ]
        let first = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            values: values, source: .manual)
        let second = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            values: values, source: .manual)

        // 每次入队都是新输入（revision +1），但落库行唯一：一个交付/一个 item/一条链接。
        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(try fixture.count("deliveries") == 1)
        #expect(try fixture.count("delivery_items") == 1)
        #expect(try fixture.count("delivery_sessions") == 1)
        let delivery = try #require(try fixture.deliveryRepo.get(fixture.xmpPath))
        #expect(delivery.revision == 2)
        let item = try #require(try fixture.item())
        #expect(item.attributes["rating"] == .number(4))
        #expect(item.attributes["label"] == .string("Green"))
        #expect(item.keywordList == ["keep"])
    }

    @Test("K0 生成词来源：culling/similarity/template/face 均映射到 origin")
    func generatedKeywordSourcesMap() {
        #expect(WritebackService.keywordOriginSource(for: "culling") == "culling")
        #expect(WritebackService.keywordOriginSource(for: "similarity") == "similarity")
        #expect(WritebackService.keywordOriginSource(for: "template") == "template")
        #expect(WritebackService.keywordOriginSource(for: "face_kw") == "face-keyword")
        #expect(WritebackService.keywordOriginSource(for: "metadata") == nil)
    }

    @Test("K0 delta：连续 add→remove 的净意图不残留")
    func deltaAddThenRemoveIsNet() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["base"])

        _ = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            added: ["X"], removed: [], owned: [:])
        _ = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            added: [], removed: ["X"], owned: [:])

        var item = try #require(try fixture.item())
        #expect(item.keywordList == ["base"])
        let added = item.attributes["keywords_added"]?.arrayElements?.compactMap(\.stringValue) ?? []
        let removed = item.attributes["keywords_remove"]?.arrayElements?.compactMap(\.stringValue) ?? []
        #expect(!added.contains("X"))
        #expect(removed.contains("X"))

        let items = try fixture.writeback.getItems(sessionId: fixture.sessionId, module: "metadata")
        _ = try await fixture.writeback.execute(
            sessionId: fixture.sessionId, module: "metadata", items: items)
        let written = try #require(fixture.xmp.writeCalls.last)
        #expect(written.keywords == ["base"])
    }

    @Test("queuePhotoValues：无可写字段抛 METADATA_MUTATION_EMPTY 且不落交付")
    func queuePhotoValuesRejectsEmpty() throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }

        #expect(throws: MetadataMutationError.empty) {
            _ = try fixture.mutations.queuePhotoValues(
                sessionId: fixture.sessionId,
                photoId: fixture.photoId,
                values: ["make": .string("Canon")],
                source: .manual
            )
        }
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath) == nil)
    }

    @Test("执行器刷盘：rating/label 落盘，交付收敛 written")
    func writebackFlushesManualValues() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }

        _ = try fixture.mutations.queuePhotoValues(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            values: ["rating": .number(4), "label": .string("Green")],
            source: .manual
        )
        let items = try fixture.writeback.getItems(sessionId: fixture.sessionId, module: "metadata")
        #expect(items.count == 1)

        let result = try await fixture.writeback.execute(
            sessionId: fixture.sessionId, module: "metadata", items: items)

        #expect(result.written == 1)
        let written = try #require(fixture.xmp.writeCalls.last)
        #expect(written.rating == 4)
        #expect(written.label == "Green")
        let delivery = try #require(try fixture.deliveryRepo.get(fixture.xmpPath))
        #expect(delivery.typedStatus == .written)
        let item = try #require(try fixture.item())
        #expect(item.typedStatus == .written)
    }

    @Test("K0 delta：written item 不得覆盖盘上基线（外部新增词可删除）")
    func keywordDeltaUsesDiskAfterWrite() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            added: ["Cat"], removed: [], owned: [:])
        let items = try fixture.writeback.getItems(sessionId: fixture.sessionId, module: "metadata")
        _ = try await fixture.writeback.execute(
            sessionId: fixture.sessionId, module: "metadata", items: items)
        #expect(try fixture.item()?.typedStatus == .written)

        // C1 外部新增 Bird；回到 Gather 删除 Bird 必须产生真实 delta。
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["Cat", "Bird"])
        let queued = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            added: [], removed: ["Bird"], owned: [:])
        #expect(queued != nil, "written item 的旧快照不能让删除静默 no-op")
        #expect(try fixture.item()?.keywordList == ["Cat"])
    }

    @Test("K0 delta：入队保留 added/remove，执行器按 disk∪added−removed 落盘")
    func keywordDeltaQueueAndFlush() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["old", "keep"])

        let queued = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            added: ["new"],
            removed: ["old"],
            owned: [:]
        )
        #expect(queued != nil)
        let item = try #require(try fixture.item())
        #expect(item.attributes["keywords_mode"]?.stringValue == "delta")
        #expect(item.attributes["keywords_added"]?.arrayElements?.compactMap(\.stringValue) == ["new"])
        #expect(item.attributes["keywords_remove"]?.arrayElements?.compactMap(\.stringValue) == ["old"])
        #expect(item.keywordList == ["keep", "new"])

        let items = try fixture.writeback.getItems(sessionId: fixture.sessionId, module: "metadata")
        _ = try await fixture.writeback.execute(
            sessionId: fixture.sessionId, module: "metadata", items: items)
        let written = try #require(fixture.xmp.writeCalls.last)
        #expect(written.keywords == ["keep", "new"])
    }

    @Test("K0 delta：生成词删除被阻止且不落交付行")
    func keywordDeltaBlocksOwnedRemoval() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["人物A"])

        do {
            _ = try await fixture.mutations.queueKeywordDelta(
                sessionId: fixture.sessionId,
                photoId: fixture.photoId,
                added: [],
                removed: ["人物A"],
                owned: [KeywordNormalizer.fold("人物A"): [.faceKeyword]]
            )
            Issue.record("expected KEYWORD_OWNED_BY_SOURCE")
        } catch let error as GatherError {
            #expect(error.code == .KEYWORD_OWNED_BY_SOURCE)
        }
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath) == nil)
    }

    @Test("K0 预览只读；apply 入队 delta 但不直接写 XMP")
    func keywordPreviewIsReadOnlyAndApplyQueuesDelta() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["old"])
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: fixture.db),
            xmp: fixture.xmp,
            photoRepo: PhotoRepo(connection: fixture.db),
            transactions: fixture.db,
            mutations: fixture.mutations,
            origins: MetadataKeywordOriginRepo(connection: fixture.db)
        )
        let before = try fixture.count("delivery_items")
        let preview = try await service.previewKeywords(
            photoIds: [fixture.photoId], added: ["new"], removed: ["old"])
        #expect(try fixture.count("delivery_items") == before)
        let item = try #require(preview.items.first)
        #expect(item.keywords == ["new"])
        #expect(item.preview?.dirtyFields == [.keywords])
        #expect(item.xmpStatus == "pending")
        #expect(fixture.xmp.writeCalls.isEmpty)

        _ = try await service.applyKeywordDelta(
            photoIds: [fixture.photoId], added: ["new"], removed: ["old"])
        #expect(try fixture.count("delivery_items") == before + 1)
        let queued = try #require(try fixture.item())
        #expect(queued.attributes["keywords_mode"]?.stringValue == "delta")
        #expect(queued.keywordList == ["new"])
        #expect(fixture.xmp.writeCalls.isEmpty)
    }

    @Test("K0 delta：连续入队累积 added，后一批不丢前一批")
    func keywordDeltaAccumulates() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["base"])

        _ = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            added: ["A"], removed: [], owned: [:])
        _ = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId, photoId: fixture.photoId,
            added: ["B"], removed: [], owned: [:])

        let item = try #require(try fixture.item())
        #expect(item.attributes["keywords_added"]?.arrayElements?.compactMap(\.stringValue) == ["A", "B"])
        #expect(item.keywordList == ["base", "A", "B"])

        let items = try fixture.writeback.getItems(sessionId: fixture.sessionId, module: "metadata")
        _ = try await fixture.writeback.execute(
            sessionId: fixture.sessionId, module: "metadata", items: items)
        #expect(fixture.xmp.writeCalls.last?.keywords == ["base", "A", "B"])
    }

    @Test("K0 delta：归一化后无变化返回 nil，不建交付行")
    func keywordDeltaNoChange() async throws {
        let fixture = try MutationFixture()
        defer { fixture.cleanup() }
        fixture.xmp.attributes = MetadataWriteAttributes(keywords: ["Bride"])

        let queued = try await fixture.mutations.queueKeywordDelta(
            sessionId: fixture.sessionId,
            photoId: fixture.photoId,
            added: [" bride "],
            removed: [],
            owned: [:]
        )
        #expect(queued == nil)
        #expect(try fixture.deliveryRepo.get(fixture.xmpPath) == nil)
    }
}


@Suite("K0 keyword suggestions")
struct KeywordSuggestionTests {
    @Test("会话内关键词/相机建议；1 个汉字也可命中")
    func suggestsKeywordsAndCameraInSession() throws {
        let db = try DBConnection(path: ":memory:")
        defer { db.close() }
        try db.exec(SchemaCurrent.createSQL)
        _ = try db.prepare("""
            INSERT INTO sessions (id, name, status, created_at, updated_at)
            VALUES ('s', '', 'draft', 't', 't')
            """).run([])
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES ('p1', 's', '/p1.jpg', 'p1.jpg', 't', 't')
            """).run([])
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, camera_make, keywords, cached_at, updated_at)
            VALUES ('p1', 's', 'Canon', '["婚礼|仪式","Bride"]', 't', 't')
            """).run([])

        let query = PhotoFilterQuery(connection: db)
        let keyword = try query.suggest("s", keyword: "婚")
        #expect(keyword.contains { $0.field == "keyword" && $0.values.contains("婚礼|仪式") })

        let camera = try query.suggest("s", keyword: "Can")
        #expect(camera.first?.field == "camera_make")
        #expect(camera.first?.values.contains("Canon") == true)

        let none = try query.suggest("s", keyword: "不存在的词")
        #expect(none.allSatisfy { $0.values.isEmpty })
    }
}
@Suite("K0 KeywordPlanner")
struct KeywordPlannerTests {
    @Test("归一化/大小写去重保留首次拼写")
    func normalizeAndUnique() {
        #expect(KeywordNormalizer.normalize("  Bride   Smith ") == "Bride Smith")
        #expect(KeywordNormalizer.normalize("   ") == nil)
        #expect(KeywordNormalizer.unique(["Bride", "bride", "BRIDE", "Groom"]) == ["Bride", "Groom"])
    }

    @Test("delta：保留生成词、删除手动词、新增去重")
    func planDelta() {
        let plan = KeywordPlanner.plan(
            existing: ["Bride", "人物A", "Old"],
            added: ["New", "new"],
            removed: ["old", "人物A"],
            owned: [KeywordNormalizer.fold("人物A"): [.faceKeyword]]
        )
        #expect(plan.after == ["Bride", "人物A", "New"])
        #expect(plan.blocked.map(\.keyword) == ["人物A"])
        #expect(plan.added == ["New"])
        #expect(plan.removed == ["Old"])
    }

    @Test("层级词原样保留，不展开父级")
    func hierarchicalKeywordIsLiteral() {
        let plan = KeywordPlanner.plan(
            existing: [], added: ["婚礼|仪式"], removed: [], owned: [:])
        #expect(plan.after == ["婚礼|仪式"])
    }
}
