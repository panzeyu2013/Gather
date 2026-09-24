// Tests/GatherCoreTests/Metadata/MetadataWriterConflictsTests.swift
// mwconf / W4-3c：MetadataWriter.listOrphans + getConflicts 直测。
// 语义基线：Services/MetadataSyncCoordinator.listOrphans（孤儿行全量投影）与
// getConflicts（仅 status == "conflict" 行、每行读一次 sidecar、并发上限 2、
// base=baseValuesJSON / local=patchJSON / MetadataConflictFields.fieldConflicts）。
// 覆盖：孤儿空/非空（含真实库：无 session 链接才算孤儿）、conflicts 行过滤、
// 每冲突行恰好一次 sidecar 读、并发峰值恰为 2（计数替身）、空集不读 sidecar、
// 端口未接线抛错、Store 抛错上抛、dirtyFields 损坏按空列表处理。

import Foundation
import Testing
@testable import GatherCore

@Suite("Metadata/MetadataWriter (mwconf)")
struct MetadataWriterConflictsTests {

    // MARK: - 基建

    /// 建临时库并接线 writer；store 为注入替身，xmp 缺省表示端口未接线。
    private func makeWriter(
        label: String,
        store: MwConfStubWritebackStore,
        xmp: (any XMPProvider)? = nil
    ) async throws -> (writer: MetadataWriter, path: String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: store,
                metadataStore: SQLiteMetadataStore(database: database),
                xmpProvider: xmp
            )
        )
        return (writer, path)
    }

    /// 构造 outbox 行（memberwise init 经 @testable 可见）：
    /// 基线 rating=3、本地 patch rating=5、dirtyFields=["rating"]，便于字段冲突判定。
    private func mwConfRow(
        _ index: Int,
        status: String,
        errorMessage: String = "",
        dirtyFields: String = #"["rating"]"#
    ) -> OutboxRecord {
        OutboxRecord(
            xmpPath: "/v/IMG_\(index).xmp",
            ownerSessionId: "s1",
            createdBySessionId: "s1",
            photoPath: "/v/IMG_\(index).jpg",
            patchJSON: #"{"rating":5}"#,
            dirtyFields: dirtyFields,
            sourceModule: "metadata",
            revision: Int64(index + 1),
            persistedRevision: 0,
            baseFingerprint: "",
            baseValuesJSON: #"{"rating":3}"#,
            backupPath: "",
            status: status,
            attemptCount: 0,
            errorMessage: errorMessage,
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    /// 冲突行集 0..<count 的 sidecar 远端值：rating=9（偏离基线 3 → 触发冲突）。
    private func conflictXMP(
        count: Int,
        readDelayNanoseconds: UInt64 = 0
    ) -> MwConfCountingXMP {
        let attributes = Dictionary(
            uniqueKeysWithValues: (0..<count).map { ("/v/IMG_\($0).jpg", MetadataWriteAttributes(rating: 9)) }
        )
        return MwConfCountingXMP(
            attributesByPhoto: attributes,
            readDelayNanoseconds: readDelayNanoseconds
        )
    }

    // MARK: - listOrphans

    @Test func listOrphansEmptyReturnsEmpty() async throws {
        let (writer, path) = try await makeWriter(
            label: "mwconf-orphan-empty",
            store: MwConfStubWritebackStore(orphans: [])
        )
        defer { removeStoreFiles(path) }

        let orphans = try await writer.listOrphans()
        #expect(orphans.isEmpty)
    }

    @Test func listOrphansProjectsStoreRowsInOrder() async throws {
        let store = MwConfStubWritebackStore(orphans: [
            mwConfRow(0, status: "failed", errorMessage: "boom"),
            mwConfRow(1, status: "conflict"),
        ])
        let (writer, path) = try await makeWriter(label: "mwconf-orphan-map", store: store)
        defer { removeStoreFiles(path) }

        let orphans = try await writer.listOrphans()
        #expect(orphans == [
            MetadataOrphan(
                xmpPath: "/v/IMG_0.xmp",
                photoPath: "/v/IMG_0.jpg",
                status: "failed",
                revision: 1,
                errorMessage: "boom",
                updatedAt: "2026-01-01T00:00:00.000Z"
            ),
            MetadataOrphan(
                xmpPath: "/v/IMG_1.xmp",
                photoPath: "/v/IMG_1.jpg",
                status: "conflict",
                revision: 2,
                errorMessage: "",
                updatedAt: "2026-01-01T00:00:00.000Z"
            ),
        ])
    }

    /// 真实 Store：只有失去 metadata_outbox_sessions 链接的行才是孤儿。
    @Test func listOrphansRealStoreExcludesSessionLinkedRows() async throws {
        let (database, path) = try await makeMigratedStoreDatabase(label: "mwconf-orphan-real")
        defer { removeStoreFiles(path) }
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        let outbox = SQLiteWritebackStore(database: database)
        _ = try await outbox.mergeOutboxPatch(
            xmpPath: "/v/LINKED.xmp",
            sessionId: "s1",
            photoPath: "/v/LINKED.jpg",
            patch: .object(["rating": .int(4)]),
            dirtyFields: ["rating"]
        )
        _ = try await outbox.mergeOutboxPatch(
            xmpPath: "/v/ORPHAN.xmp",
            sessionId: "s1",
            photoPath: "/v/ORPHAN.jpg",
            patch: .object(["rating": .int(5)]),
            dirtyFields: ["rating"]
        )
        // 摘掉孤儿行的会话链接：另一行保持链接，必须被 orphanOutbox 过滤。
        try await database.run(
            "DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?",
            [.text("/v/ORPHAN.xmp")]
        )
        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: outbox,
                metadataStore: SQLiteMetadataStore(database: database)
            )
        )

        let orphans = try await writer.listOrphans()
        #expect(orphans.count == 1)
        #expect(orphans.first?.xmpPath == "/v/ORPHAN.xmp")
        #expect(orphans.first?.photoPath == "/v/ORPHAN.jpg")
        #expect(orphans.first?.status == "pending")
    }

    // MARK: - getConflicts

    @Test func getConflictsReadsEachConflictRowExactlyOnce() async throws {
        let store = MwConfStubWritebackStore(
            entries: (0..<6).map { mwConfRow($0, status: "conflict") } + [
                mwConfRow(6, status: "pending"),
                mwConfRow(7, status: "failed"),
            ]
        )
        let xmp = conflictXMP(count: 6)
        let (writer, path) = try await makeWriter(label: "mwconf-read-once", store: store, xmp: xmp)
        defer { removeStoreFiles(path) }

        let conflicts = try await writer.getConflicts(sessionId: "s1")

        // 仅 conflict 行入结果，且保持 Store 返回顺序（ConcurrentMap 保序）。
        #expect(conflicts.count == 6)
        #expect(conflicts.map(\.xmpPath) == (0..<6).map { "/v/IMG_\($0).xmp" })
        #expect(conflicts.map(\.revision) == Array(1...6))

        // 每冲突行恰好读一次 sidecar；pending/failed 行一次都不读。
        let readCount = await xmp.readCount
        let readPaths = await xmp.readPhotoPaths
        #expect(readCount == 6)
        #expect(readPaths.sorted() == (0..<6).map { "/v/IMG_\($0).jpg" })

        // 字段冲突语义：baseline=baseValuesJSON、local=patchJSON、remote=磁盘当前值。
        for conflict in conflicts {
            #expect(conflict.fields.count == 1)
            let field = try #require(conflict.fields.first)
            #expect(field.field == .rating)
            #expect(field.baseline.numberValue == 3)
            #expect(field.local.numberValue == 5)
            #expect(field.remote.numberValue == 9)
        }
    }

    @Test func getConflictsCapsSidecarReadConcurrencyAtTwo() async throws {
        let store = MwConfStubWritebackStore(
            entries: (0..<6).map { mwConfRow($0, status: "conflict") }
        )
        // 每次读挂起 40ms：若并发不受控，峰值会达到 6；上限为 2 时峰值恰为 2。
        let xmp = conflictXMP(count: 6, readDelayNanoseconds: 40_000_000)
        let (writer, path) = try await makeWriter(label: "mwconf-concurrency", store: store, xmp: xmp)
        defer { removeStoreFiles(path) }

        let conflicts = try await writer.getConflicts(sessionId: "s1")

        let maxActive = await xmp.maxActive
        let readCount = await xmp.readCount
        #expect(conflicts.count == 6)
        #expect(readCount == 6)
        #expect(maxActive <= 2, "sidecar 并发读不得超过 2")
        #expect(maxActive == 2, "6 行 / 上限 2 必须出现真并发（否则并发被压成串行）")
    }

    @Test func getConflictsEmptyConflictSetSkipsSidecarReads() async throws {
        let store = MwConfStubWritebackStore(entries: [
            mwConfRow(0, status: "pending"),
            mwConfRow(1, status: "failed"),
            mwConfRow(2, status: "written"),
        ])
        let xmp = conflictXMP(count: 3)
        let (writer, path) = try await makeWriter(label: "mwconf-empty", store: store, xmp: xmp)
        defer { removeStoreFiles(path) }

        let conflicts = try await writer.getConflicts(sessionId: "s1")
        let readCount = await xmp.readCount

        #expect(conflicts.isEmpty)
        #expect(readCount == 0, "无冲突行不得触碰 sidecar")
    }

    @Test func getConflictsMalformedDirtyFieldsYieldsNoFields() async throws {
        let store = MwConfStubWritebackStore(entries: [
            mwConfRow(0, status: "conflict", dirtyFields: "not-json"),
        ])
        let xmp = conflictXMP(count: 1)
        let (writer, path) = try await makeWriter(label: "mwconf-dirty-corrupt", store: store, xmp: xmp)
        defer { removeStoreFiles(path) }

        let conflicts = try await writer.getConflicts(sessionId: "s1")
        #expect(conflicts.count == 1)
        let readCount = await xmp.readCount
        #expect(conflicts.first?.fields.isEmpty == true, "脏字段损坏按空列表处理，不伪造冲突字段")
        #expect(readCount == 1)
    }

    @Test func getConflictsWithoutSidecarPortThrowsDetailsUnavailable() async throws {
        let store = MwConfStubWritebackStore(entries: [mwConfRow(0, status: "conflict")])
        let (writer, path) = try await makeWriter(label: "mwconf-no-port", store: store)
        defer { removeStoreFiles(path) }

        await #expect(throws: MetadataSyncError.conflictDetailsUnavailable) {
            _ = try await writer.getConflicts(sessionId: "s1")
        }
    }

    // MARK: - 错误传播

    @Test func storeFailuresPropagate() async throws {
        let (writer, path) = try await makeWriter(
            label: "mwconf-throw",
            store: MwConfStubWritebackStore(failure: .init())
        )
        defer { removeStoreFiles(path) }

        await #expect(throws: MwConfStubWritebackStore.InjectedFailure.self) {
            _ = try await writer.listOrphans()
        }
        await #expect(throws: MwConfStubWritebackStore.InjectedFailure.self) {
            _ = try await writer.getConflicts(sessionId: "s1")
        }
    }
}

// MARK: - 计数替身

/// sidecar 读取替身（actor 内建计数，无锁、无并发标注）：
/// - readCount / readPhotoPaths：断言「每冲突行恰好读一次」；
/// - maxActive：在飞 readAttributes 的峰值，断言并发上限（每次读挂起制造重叠窗口）。
private actor MwConfCountingXMP: XMPProvider {
    private let attributesByPhoto: [String: MetadataWriteAttributes]
    private let readDelayNanoseconds: UInt64
    private(set) var readCount = 0
    private(set) var readPhotoPaths: [String] = []
    private(set) var maxActive = 0
    private var active = 0

    init(
        attributesByPhoto: [String: MetadataWriteAttributes] = [:],
        readDelayNanoseconds: UInt64 = 0
    ) {
        self.attributesByPhoto = attributesByPhoto
        self.readDelayNanoseconds = readDelayNanoseconds
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        attributesByPhoto[photoPath]?.keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        readCount += 1
        readPhotoPaths.append(photoPath)
        active += 1
        if active > maxActive { maxActive = active }
        if readDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: readDelayNanoseconds)
        }
        active -= 1
        return attributesByPhoto[photoPath] ?? MetadataWriteAttributes()
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    nonisolated func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

// MARK: - Store 替身

/// Store 替身：orphans / entries 可注入，或对两个读取端口整体抛错；
/// 其余协议方法不应被 listOrphans/getConflicts 调用，以 fatalError 标记
/// （实现若回归到其他读取路径，测试会以崩溃暴露而不是静默通过）。
struct MwConfStubWritebackStore: WritebackStore {
    struct InjectedFailure: Error, Equatable {}

    var orphans: [OutboxRecord] = []
    var entries: [OutboxRecord] = []
    var failure: InjectedFailure?

    func orphanOutbox() async throws -> [OutboxRecord] {
        if let failure { throw failure }
        return orphans
    }

    func outboxEntries(sessionId: String) async throws -> [OutboxRecord] {
        if let failure { throw failure }
        return entries
    }

    func outboxEntry(xmpPath: String) async throws -> OutboxRecord? { fatalError("unused") }
    func outboxEntries(sessionId: String, xmpPaths: [String]) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxEntries(xmpPaths: [String]) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxSummaries(sessionId: String) async throws -> [OutboxSummary] { fatalError("unused") }
    func outboxSessionIds(xmpPath: String) async throws -> [String] { fatalError("unused") }
    func outboxCounts(sessionId: String) async throws -> [String: Int64] { fatalError("unused") }
    func hasActiveOtherModule(sessionId: String, module: String) async throws -> Bool { fatalError("unused") }
    func recoverableOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func recoverableActiveOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func mergeOutboxPatch(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) async throws -> OutboxRecord { fatalError("unused") }
    func mergeOutboxPatches(_ requests: [OutboxMergeRequest]) async throws -> [OutboxRecord] { fatalError("unused") }
    func claimOutbox(xmpPath: String, expectedRevision: Int64) async throws -> Bool { fatalError("unused") }
    func markOutboxWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) async throws { fatalError("unused") }
    func markOutboxStatus(xmpPath: String, status: String, errorMessage: String) async throws { fatalError("unused") }
    func markOutboxStatus(
        xmpPath: String,
        expectedRevision: Int,
        status: OutboxStatus,
        errorMessage: String?
    ) async throws -> Bool { fatalError("unused") }
    func resetOutboxForRetry(xmpPath: String) async throws { fatalError("unused") }
    func setOutboxBackupPath(xmpPath: String, backupPath: String) async throws { fatalError("unused") }
    func initializeOutboxBaseline(xmpPath: String, baselineFingerprint: String, baselineValues: JSONValue) async throws { fatalError("unused") }
    @discardableResult func recoverInterruptedOutbox() async throws -> Int { fatalError("unused") }
    func resolveOutboxConflict(
        xmpPath: String,
        patch: JSONValue,
        dirtyFields: [String],
        baselineFingerprint: String,
        baselineValues: JSONValue,
        acceptRemote: Bool
    ) async throws { fatalError("unused") }
    func markSessionSynced(sessionId: String, sourceModule: String) async throws { fatalError("unused") }
    func deleteOutbox(xmpPath: String) async throws { fatalError("unused") }
    func clearOutboxBackupPath(xmpPath: String, backupPath: String) async throws { fatalError("unused") }
    func deleteOutboxByRevision(xmpPath: String, revision: Int64) async throws { fatalError("unused") }
    func discardModulePending(sessionId: String, sourceModule: String) async throws { fatalError("unused") }
    func saveWritebackItems(sessionId: String, module: String, items: [WritebackItemInput]) async throws { fatalError("unused") }
    func writebackItems(sessionId: String, module: String?, status: String?) async throws -> [WritebackItemRecord] { fatalError("unused") }
    func writebackItem(itemId: Int64) async throws -> WritebackItemRecord? { fatalError("unused") }
    func updateWritebackStatus(itemId: Int64, status: String, error: String?) async throws { fatalError("unused") }
    func failedWritebackCount(sessionId: String, module: String?) async throws -> Int { fatalError("unused") }
    func deleteWritebackItems(sessionId: String, module: String?) async throws { fatalError("unused") }
    func deleteWritebackItems(sessionId: String, module: String, ids: [Int64]) async throws { fatalError("unused") }
    func updateWritebackBackupPath(itemId: Int64, path: String) async throws { fatalError("unused") }
    func updateWritebackAttributes(itemId: Int64, attributes: [String: JSONValue]) async throws { fatalError("unused") }
    func updateWritebackKeywords(itemId: Int64, keywords: [String]) async throws { fatalError("unused") }
    func updateWritebackAttributes(_ updates: [WritebackAttributesUpdate]) async throws { fatalError("unused") }
    func updateWritebackKeywords(_ updates: [WritebackKeywordsUpdate]) async throws { fatalError("unused") }
    func markWritebackWrittenAsSynced(sessionId: String, module: String) async throws { fatalError("unused") }
    func updateWritebackStatusByXmpPath(sessionId: String, module: String, xmpPath: String, status: String) async throws { fatalError("unused") }
    func hasActiveWriteback(xmpPath: String) async throws -> Bool { fatalError("unused") }
    @discardableResult func discardWritebackPending(xmpPath: String) async throws -> Int { fatalError("unused") }
    @discardableResult func reconcileWritebackProjection(
        sessionId: String,
        module: String,
        snapshot: [String: OutboxStatus]
    ) async throws -> Int { fatalError("unused") }
    @discardableResult func applyAcceptedRemoteValues(
        sessionId: String,
        xmpPath: String,
        rating: Int?,
        label: String?,
        keywords: [String]?
    ) async throws -> Int { fatalError("unused") }
}
