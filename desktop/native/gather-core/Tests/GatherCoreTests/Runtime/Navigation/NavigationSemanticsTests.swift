// Tests/GatherCoreTests/Runtime/Navigation/NavigationSemanticsTests.swift
// W2d-3b：从旧 NavigationServiceTests 迁移的语义（analyze 参数校验、阈值变化重算、manual 成员保留）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Navigation semantic migration (W2d-3b)")
struct NavigationSemanticsTests {

    private func makeRuntime(label: String) async throws -> (NavigationRuntime, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        try await database.run("""
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """)
        return (NavigationRuntime(store: SQLiteNavigationStore(database: database)), database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, filename: String, capturedAt: String) async throws {
        try await database.run("""
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, 's1', ?, ?, 'ready', ?, ?)
        """, [.text(id), .text("/photos/\(filename)"), .text(filename), .text(capturedAt), .text(capturedAt)])
    }

    /// 旧 rejectsUnsafeOrInvertedIntervals：burst/scene 间隔参数校验（错误码逐字）。
    @Test func analyzeRejectsUnsafeOrInvertedIntervals() async throws {
        let (runtime, _, path) = try await makeRuntime(label: "nav-semantics-intervals")
        defer { try? FileManager.default.removeItem(atPath: path) }
        await #expect(throws: NavigationError.self) {
            _ = try await runtime.analyze(sessionId: "s1", burstGapSeconds: 5, sceneGapSeconds: 2)
        }
        await #expect(throws: NavigationError.self) {
            _ = try await runtime.analyze(sessionId: "s1", burstGapSeconds: -1, sceneGapSeconds: 1800)
        }
    }

    /// 旧 recomputesWhenThresholdsChange：阈值变化后必须重算（不得复用旧指纹缓存）。
    @Test func analyzeRecomputesWhenThresholdsChange() async throws {
        let (runtime, database, path) = try await makeRuntime(label: "nav-semantics-recompute")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await insertPhoto(database, id: "p1", filename: "A_0001.JPG", capturedAt: "2026-01-01T00:00:00.000Z")
        try await insertPhoto(database, id: "p2", filename: "A_0002.JPG", capturedAt: "2026-01-01T00:00:01.000Z")
        let tight = try await runtime.analyze(sessionId: "s1", burstGapSeconds: 2, sceneGapSeconds: 1800)
        let loose = try await runtime.analyze(sessionId: "s1", burstGapSeconds: 1, sceneGapSeconds: 1800)
        #expect(tight.count != loose.count || tight != loose)
    }

    /// 旧 manualOverridesScopedToOwnType：自动分析必须保留 manual 组及其成员。
    @Test func analyzePreservesManualGroups() async throws {
        let (runtime, database, path) = try await makeRuntime(label: "nav-semantics-manual")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await insertPhoto(database, id: "p1", filename: "A_0001.JPG", capturedAt: "2026-01-01T00:00:00.000Z")
        try await insertPhoto(database, id: "p2", filename: "A_0002.JPG", capturedAt: "2026-01-01T00:00:01.000Z")
        let store = SQLiteNavigationStore(database: database)
        try await store.insertGroup(sessionId: "s1", group: NavigationGroupInsert(
            id: "manual-1",
            groupType: "scene",
            photoIdsJSON: NavigationAssembler.photoIdsJSON(["p1", "p2"]),
            leadPhotoId: "p1",
            explanation: "manual",
            source: "manual",
            fingerprint: "manual-fp"
        ))
        let groups = try await runtime.analyze(sessionId: "s1", burstGapSeconds: 2, sceneGapSeconds: 1800)
        #expect(groups.contains { $0.id == "manual-1" })
    }
}