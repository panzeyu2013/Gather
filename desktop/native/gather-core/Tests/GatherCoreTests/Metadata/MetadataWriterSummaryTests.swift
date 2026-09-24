// Tests/GatherCoreTests/Metadata/MetadataWriterSummaryTests.swift
// mwsum / W4-3a：MetadataWriter.getSummary 直测。
// 语义基线：Services/MetadataSyncCoordinator.getSummary（轻投影 + outboxCounts 分组计数、
// 逐行过滤兜底）。三个用例覆盖：空 outbox、混合状态分组、Store 抛错上抛。

import Foundation
import Testing
@testable import GatherCore

@Suite("Metadata/MetadataWriter (mwsum)")
struct MetadataWriterSummaryTests {

    private func makeWriter(
        label: String
    ) async throws -> (writer: MetadataWriter, outbox: SQLiteWritebackStore, database: SQLiteDatabase, path: String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        for id in ["s1", "s2"] {
            try await database.run(
                """
                INSERT INTO sessions (id, name, created_at, updated_at)
                VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(id)]
            )
        }
        let outbox = SQLiteWritebackStore(database: database)
        let metadata = SQLiteMetadataStore(database: database)
        let writer = MetadataWriter(dependencies: .init(writebackStore: outbox, metadataStore: metadata))
        return (writer, outbox, database, path)
    }

    @Test func emptyOutboxSummaryIsAllZero() async throws {
        let (writer, _, _, path) = try await makeWriter(label: "mwsum-empty")
        defer { removeStoreFiles(path) }

        let summary = try await writer.getSummary(sessionId: "s1")

        #expect(summary.sessionId == "s1")
        #expect(summary.pending == 0)
        #expect(summary.writing == 0)
        #expect(summary.written == 0)
        #expect(summary.failed == 0)
        #expect(summary.conflict == 0)
        #expect(summary.synced == 0)
        #expect(summary.items.isEmpty)
    }

    @Test func mixedStatusRowsGroupCountsCorrectly() async throws {
        let (writer, outbox, _, path) = try await makeWriter(label: "mwsum-mixed")
        defer { removeStoreFiles(path) }

        // 六种受计状态各一行。DB CHECK 约束只允许枚举内状态，
        // 未知状态回退路径由 unknownStatusFallsBackToRowFilteringWhenCountsMissingKey 用替身覆盖。
        let statuses = ["pending", "writing", "written", "failed", "conflict", "synced"]
        for (index, status) in statuses.enumerated() {
            let xmpPath = "/v/IMG_\(index).xmp"
            _ = try await outbox.mergeOutboxPatch(
                xmpPath: xmpPath,
                sessionId: "s1",
                photoPath: "/v/IMG_\(index).jpg",
                patch: JSONValue.object(["rating": JSONValue.int(3)]),
                dirtyFields: ["rating"]
            )
            try await outbox.markOutboxStatus(xmpPath: xmpPath, status: status, errorMessage: "")
        }

        let summary = try await writer.getSummary(sessionId: "s1")

        #expect(summary.sessionId == "s1")
        #expect(summary.pending == 1)
        #expect(summary.writing == 1)
        #expect(summary.written == 1)
        #expect(summary.failed == 1)
        #expect(summary.conflict == 1)
        #expect(summary.synced == 1)
        #expect(summary.items.count == 6)

        // 轻投影逐行：未知状态回退 .pending；revision/attemptCount 为 Int 投影。
        let itemsByPath = Dictionary(uniqueKeysWithValues: summary.items.map { ($0.xmpPath, $0) })
        #expect(itemsByPath["/v/IMG_0.xmp"]?.status == .pending)
        #expect(itemsByPath["/v/IMG_5.xmp"]?.status == .synced)
        #expect(itemsByPath["/v/IMG_0.xmp"]?.revision == 1)
        #expect(itemsByPath["/v/IMG_0.xmp"]?.attemptCount == 0)
        #expect(itemsByPath["/v/IMG_0.xmp"]?.errorMessage == "")
        #expect(itemsByPath["/v/IMG_0.xmp"]?.updatedAt.isEmpty == false)

        // 会话隔离：s2 无行。
        let other = try await writer.getSummary(sessionId: "s2")
        #expect(other.items.isEmpty)
        #expect(other.pending == 0)
    }

    @Test func unknownStatusFallsBackToRowFilteringWhenCountsMissingKey() async throws {
        let (database, path) = try await makeMigratedStoreDatabase(label: "mwsum-fallback")
        defer { removeStoreFiles(path) }

        // outboxCounts 缺键（空字典）→ count(_:) 逐行过滤兜底；
        // 未知状态在轻投影中保守回退 .pending，故 fallback 计入 pending。
        let stub = StubWritebackStore(
            summaries: [
                OutboxSummary(
                    xmpPath: "/v/A.xmp", revision: 1, persistedRevision: 0, status: "pending",
                    attemptCount: 0, errorMessage: "", updatedAt: "2026-01-01T00:00:00.000Z"
                ),
                OutboxSummary(
                    xmpPath: "/v/B.xmp", revision: 2, persistedRevision: 0, status: "bogus",
                    attemptCount: 0, errorMessage: "", updatedAt: "2026-01-01T00:00:01.000Z"
                ),
                OutboxSummary(
                    xmpPath: "/v/C.xmp", revision: 3, persistedRevision: 1, status: "synced",
                    attemptCount: 2, errorMessage: "", updatedAt: "2026-01-01T00:00:02.000Z"
                ),
            ],
            counts: [:]
        )
        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: stub,
                metadataStore: SQLiteMetadataStore(database: database)
            )
        )

        let summary = try await writer.getSummary(sessionId: "s1")

        #expect(summary.pending == 2)
        #expect(summary.synced == 1)
        #expect(summary.writing == 0)
        #expect(summary.items.count == 3)
        #expect(summary.items.first { $0.xmpPath == "/v/B.xmp" }?.status == .pending)
    }

    @Test func storeFailurePropagates() async throws {
        let (database, path) = try await makeMigratedStoreDatabase(label: "mwsum-throw")
        defer { removeStoreFiles(path) }

        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: StubWritebackStore(failure: .init()),
                metadataStore: SQLiteMetadataStore(database: database)
            )
        )

        await #expect(throws: StubWritebackStore.InjectedFailure.self) {
            _ = try await writer.getSummary(sessionId: "s1")
        }
    }
}

/// Store 替身：可注入 summaries/counts 或抛错；其余协议方法不应被 getSummary 调用，
/// 以 fatalError 标记（若实现回归到其他读取路径，测试会以崩溃暴露）。
struct StubWritebackStore: WritebackStore {
    struct InjectedFailure: Error, Equatable {}

    var summaries: [OutboxSummary] = []
    var counts: [String: Int64] = [:]
    var failure: InjectedFailure?

    func outboxSummaries(sessionId: String) async throws -> [OutboxSummary] {
        if let failure { throw failure }
        return summaries
    }

    func outboxCounts(sessionId: String) async throws -> [String: Int64] { counts }

    func outboxEntry(xmpPath: String) async throws -> OutboxRecord? { fatalError("unused") }
    func outboxEntries(sessionId: String) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxEntries(sessionId: String, xmpPaths: [String]) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxEntries(xmpPaths: [String]) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxSessionIds(xmpPath: String) async throws -> [String] { fatalError("unused") }
    func hasActiveOtherModule(sessionId: String, module: String) async throws -> Bool { fatalError("unused") }
    func recoverableOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func recoverableActiveOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func orphanOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
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
