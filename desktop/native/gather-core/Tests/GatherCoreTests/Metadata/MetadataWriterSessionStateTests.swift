// Tests/GatherCoreTests/Metadata/MetadataWriterSessionStateTests.swift
// mwstate / W4-3b：MetadataWriter.getSessionState 直测。
// 语义基线：Metadata/MetadataSessionState.aggregateSessionState（设计 2.3.2 优先级链
// conflict > failed > syncing > c1Read > safeToCleanup）＋持久源 metadata_outbox
// 分组计数（WritebackStore.outboxCounts）＋外部事实 sessions.reload_acked_at（SessionStore）。
// 覆盖：真实库优先级链逐级升级、终态行无 reload ack 不得 safeToCleanup、
// 写入 ack 后才放行 safeToCleanup（且每次读穿，不缓存）。

import Foundation
import Testing
@testable import GatherCore

@Suite("Metadata/MetadataWriter (mwstate)")
struct MetadataWriterSessionStateTests {

    private func makeWriter(
        label: String
    ) async throws -> (
        writer: MetadataWriter,
        outbox: SQLiteWritebackStore,
        sessions: SQLiteSessionStore,
        path: String
    ) {
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
        let sessions = SQLiteSessionStore(database: database)
        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: outbox,
                metadataStore: metadata,
                sessionStore: sessions
            )
        )
        return (writer, outbox, sessions, path)
    }

    /// 建一行并直接置为目标状态（绕过写回生命周期，只为聚合计数服务）。
    private func addRow(
        _ outbox: SQLiteWritebackStore,
        index: Int,
        status: String,
        sessionId: String = "s1"
    ) async throws {
        let xmpPath = "/v/IMG_\(index).xmp"
        _ = try await outbox.mergeOutboxPatch(
            xmpPath: xmpPath,
            sessionId: sessionId,
            photoPath: "/v/IMG_\(index).jpg",
            patch: JSONValue.object(["rating": JSONValue.int(3)]),
            dirtyFields: ["rating"]
        )
        try await outbox.markOutboxStatus(xmpPath: xmpPath, status: status, errorMessage: "")
    }

    @Test func priorityChainEscalatesOverPersistedCounts() async throws {
        let (writer, outbox, sessions, path) = try await makeWriter(label: "mwstate-priority")
        defer { removeStoreFiles(path) }

        // 0 行：无待确认写回 → synced（无 ack 亦然）。
        var state = try await writer.getSessionState(sessionId: "s1")
        #expect(state == .synced)

        // written = 本轮写入尚未被 C1 reload：即使已有 ack 也不得 c1Read 以上。
        try await addRow(outbox, index: 0, status: "written")
        _ = try await sessions.setReloadAckedAt(sessionId: "s1", iso: "2026-01-02T00:00:00.000Z")
        state = try await writer.getSessionState(sessionId: "s1")
        #expect(state == .c1Read, "written 行压过陈旧 reload ack")

        // pending 压过 written。
        try await addRow(outbox, index: 1, status: "pending")
        state = try await writer.getSessionState(sessionId: "s1")
        #expect(state == .syncing)

        // failed 压过 pending/syncing。
        try await outbox.markOutboxStatus(xmpPath: "/v/IMG_1.xmp", status: "failed", errorMessage: "boom")
        state = try await writer.getSessionState(sessionId: "s1")
        #expect(state == .failed)

        // conflict 压过一切。
        try await addRow(outbox, index: 2, status: "conflict")
        state = try await writer.getSessionState(sessionId: "s1")
        #expect(state == .conflict)

        // 会话隔离：s2 无行 → synced。
        let other = try await writer.getSessionState(sessionId: "s2")
        #expect(other == .synced)
    }

    @Test func allTerminalRowsWithoutReloadAckAreNotSafeToCleanup() async throws {
        let (writer, outbox, _, path) = try await makeWriter(label: "mwstate-noack")
        defer { removeStoreFiles(path) }

        try await addRow(outbox, index: 0, status: "synced")
        try await addRow(outbox, index: 1, status: "clean")
        try await addRow(outbox, index: 2, status: "cleaned")

        // 行全部终态但 C1 从未确认 reload：C1 可能仍持旧元数据，不可 cleanup。
        let state = try await writer.getSessionState(sessionId: "s1")
        #expect(state == .c1Read)
    }

    @Test func allTerminalRowsWithReloadAckAreSafeToCleanup() async throws {
        let (writer, outbox, sessions, path) = try await makeWriter(label: "mwstate-ack")
        defer { removeStoreFiles(path) }

        try await addRow(outbox, index: 0, status: "synced")
        try await addRow(outbox, index: 1, status: "clean")
        try await addRow(outbox, index: 2, status: "cleaned")

        let before = try await writer.getSessionState(sessionId: "s1")
        #expect(before == .c1Read)

        // ack 由宿主桥写入后立即读穿（writer 不缓存外部事实）。
        let acked = try await sessions.setReloadAckedAt(sessionId: "s1", iso: "2026-01-02T00:00:00.000Z")
        #expect(acked)

        let after = try await writer.getSessionState(sessionId: "s1")
        #expect(after == .safeToCleanup)
    }
}
