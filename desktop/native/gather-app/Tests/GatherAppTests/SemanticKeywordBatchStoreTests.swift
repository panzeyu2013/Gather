// desktop/native/gather-app/Tests/GatherAppTests/SemanticKeywordBatchStoreTests.swift
// Wave4c / task-50：撤销 scope 持久化的存储层（文件 JSON）回归。
// 覆盖：往返保真、会话隔离、清除、损坏回退、非法会话 id 不逃出目录。
import Foundation
import Testing
@testable import GatherUI

@MainActor
@Suite("场景标签写回批次持久化")
struct SemanticKeywordBatchStoreTests {
    private func makeStore() throws -> (store: FileSemanticKeywordBatchStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-batch-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (FileSemanticKeywordBatchStore(directory: dir), dir)
    }

    private func record(photoIds: [String] = ["p1", "p2"]) -> SemanticKeywordBatchRecord {
        SemanticKeywordBatchRecord(
            photoIds: photoIds, batchId: "b-1", savedAt: "2026-11-11T00:00:00Z",
            keywordsAdded: 2, keywordsRemoved: 0)
    }

    @Test("save → load 往返保真（photoIds/batchId/savedAt/计数）")
    func roundTrip() throws {
        let (store, dir) = try makeStore()
        defer { do { try FileManager.default.removeItem(at: dir) } catch {} }
        #expect(store.load(sessionId: "s1") == nil, "写之前应为空")
        store.save(record(), sessionId: "s1")
        #expect(store.load(sessionId: "s1") == record())
    }

    @Test("不同会话互不影响；clear 后回到空")
    func sessionsAreIsolated() throws {
        let (store, dir) = try makeStore()
        defer { do { try FileManager.default.removeItem(at: dir) } catch {} }
        store.save(record(photoIds: ["a"]), sessionId: "s1")
        store.save(record(photoIds: ["b"]), sessionId: "s2")
        #expect(store.load(sessionId: "s1")?.photoIds == ["a"])
        #expect(store.load(sessionId: "s2")?.photoIds == ["b"])
        store.clear(sessionId: "s1")
        #expect(store.load(sessionId: "s1") == nil)
        #expect(store.load(sessionId: "s2")?.photoIds == ["b"], "清一个会话不能误删另一个")
    }

    @Test("文件损坏 → load 返回 nil（回退无批次，不崩）")
    func corruptedFileFallsBack() throws {
        let (store, dir) = try makeStore()
        defer { do { try FileManager.default.removeItem(at: dir) } catch {} }
        let url = store.fileURL(sessionId: "s1")
        try Data("not-json{{{".utf8).write(to: url)
        #expect(store.load(sessionId: "s1") == nil)
        // 损坏后仍可被新的 save 覆盖为有效记录。
        store.save(record(), sessionId: "s1")
        #expect(store.load(sessionId: "s1") == record())
    }

    @Test("非法会话 id 的文件名被安全化：不逃出存储目录")
    func unsafeSessionIdStaysInsideDirectory() throws {
        let (store, dir) = try makeStore()
        defer { do { try FileManager.default.removeItem(at: dir) } catch {} }
        let url = store.fileURL(sessionId: "../../evil/session")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path
            == dir.standardizedFileURL.path, "会话 id 不能改变存储目录")
        #expect(!url.lastPathComponent.contains("/"))
        store.save(record(photoIds: ["x"]), sessionId: "../../evil/session")
        #expect(store.load(sessionId: "../../evil/session")?.photoIds == ["x"])
    }
}
