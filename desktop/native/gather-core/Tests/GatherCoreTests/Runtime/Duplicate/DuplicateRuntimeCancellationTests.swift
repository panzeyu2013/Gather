// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Duplicate/DuplicateRuntimeCancellationTests.swift
// W2c：DuplicateRuntime 取消语义测试（承接旧 DuplicateServiceTests 的
// 「视觉 hash 计算期间取消不落库」用例，并补充扫描前中止 / 聚类后中止）。
//
// 取消契约（对齐旧实现）：
// - 扫描前已中止 → JobCancelledError，零写入；
// - 视觉 hash 阶段（provider 内）中止 → 落库前复查，checksum / hash / 分组零写入；
// - 聚类返回后中止 → 分组不重建（abort 补查），错误为 JobCancelledError。

import Foundation
import Testing
@testable import GatherCore

private let cancelUniformPixels = [UInt8](repeating: 128, count: 72)
private let cancelJpegBytes = Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q==")!
private let cancelPngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

private struct DuplicateCancelEnv {
    let db: SQLiteDatabase
    let runtime: DuplicateRuntime
    let sessionId: String
    let dir: String
}

private func makeCancelEnv(
    thumbnail: @escaping DuplicateRuntime.ThumbnailProvider = { _, _ in cancelUniformPixels },
    cluster: @escaping DuplicateRuntime.ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
        try ClusterEngine.clusterByHash(
            entries: entries, threshold: threshold, minGroupSize: minGroupSize,
            mode: mode, onProgress: onProgress)
    }
) async throws -> DuplicateCancelEnv {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-dup-cancel-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedStore(path: path)
    try await insertSession(db, "session")
    let dir = try makeTempDir()
    let runtime = DuplicateRuntime(
        store: SQLiteDuplicateStore(database: db),
        thumbnailProvider: thumbnail,
        clusterProvider: cluster
    )
    return DuplicateCancelEnv(db: db, runtime: runtime, sessionId: "session", dir: dir)
}

@discardableResult
private func cancelAddPhoto(_ env: DuplicateCancelEnv, id: String, name: String, content: Data) async throws -> String {
    let path = try writeTempFile(in: env.dir, name: name, content: content)
    _ = try await env.db.run("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """, [
            .text(id), .text(env.sessionId), .text(path),
            .text((path as NSString).lastPathComponent),
        ])
    return path
}

@Suite("DuplicateRuntime cancellation（W2c）")
struct DuplicateRuntimeCancellationTests {
    @Test("视觉 hash 计算期间取消：抛取消且不落任何库")
    func cancellationDuringVisualHashPersistsNothing() async throws {
        let signal = JobAbortSignal()
        let env = try await makeCancelEnv(thumbnail: { _, _ in
            signal.abort()
            return nil
        })
        try await cancelAddPhoto(env, id: "p1", name: "p1.jpg", content: cancelJpegBytes)

        await #expect(throws: JobCancelledError()) {
            try await env.runtime.scanDuplicates(
                sessionId: env.sessionId,
                signal: signal
            )
        }

        // TS 等价断言：取消在 computeVisualHashes 期间到达，persist 与 scan
        // 事务必须从未执行——checksum 未回写、无 hash 行、无分组行。
        let checksum = try await env.db.queryOne("SELECT checksum FROM photos WHERE id = ?", [.text("p1")])?.text(at: 0)
        #expect(checksum == "")
        #expect(try await rowCount(
            env.db, "SELECT COUNT(*) FROM similarity_hashes WHERE session_id = ?",
            [.text(env.sessionId)]
        ) == 0)
        #expect(try await rowCount(
            env.db, "SELECT COUNT(*) FROM duplicate_groups WHERE session_id = ?",
            [.text(env.sessionId)]
        ) == 0)
    }

    @Test("扫描前已中止：立即抛取消且零写入")
    func preAbortedScanThrowsWithoutWrites() async throws {
        let env = try await makeCancelEnv()
        try await cancelAddPhoto(env, id: "p1", name: "p1.jpg", content: cancelJpegBytes)
        let signal = JobAbortSignal()
        signal.abort()

        await #expect(throws: JobCancelledError()) {
            try await env.runtime.scanDuplicates(sessionId: env.sessionId, signal: signal)
        }
        #expect(try await rowCount(
            env.db, "SELECT COUNT(*) FROM similarity_hashes WHERE session_id = ?",
            [.text(env.sessionId)]
        ) == 0)
    }

    @Test("聚类返回后取消：抛取消且不重建分组")
    func cancellationAfterClusteringDoesNotRebuildGroups() async throws {
        let signal = JobAbortSignal()
        let clusterCalls = CallCounterBox()
        let env = try await makeCancelEnv(cluster: { entries, _, _, _, _ in
            clusterCalls.increment()
            signal.abort()
            return ClusterResult(groups: [entries.map(\.photoId)], ungrouped: [])
        })
        try await cancelAddPhoto(env, id: "p1", name: "p1.jpg", content: cancelJpegBytes)
        try await cancelAddPhoto(env, id: "p2", name: "p2.png", content: cancelPngBytes)

        await #expect(throws: JobCancelledError()) {
            try await env.runtime.scanDuplicates(sessionId: env.sessionId, signal: signal)
        }

        #expect(clusterCalls.value == 1)
        // 取消补查发生在重建分组之前：无组/成员写入。
        #expect(try await rowCount(
            env.db, "SELECT COUNT(*) FROM duplicate_groups WHERE session_id = ?",
            [.text(env.sessionId)]
        ) == 0)
        #expect(try await rowCount(
            env.db, "SELECT COUNT(*) FROM duplicate_group_members WHERE session_id = ?",
            [.text(env.sessionId)]
        ) == 0)
        // 聚类前的 hash 落库已完成（旧实现同序：writeScanResults 先于聚类），
        // 但分组未重建。
        #expect(try await rowCount(
            env.db, "SELECT COUNT(*) FROM similarity_hashes WHERE session_id = ?",
            [.text(env.sessionId)]
        ) == 2)
    }
}

/// 线程安全计数器（本文件私有，避免与 DuplicateRuntimeTests 的 CallCounter 混淆）。
private final class CallCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
