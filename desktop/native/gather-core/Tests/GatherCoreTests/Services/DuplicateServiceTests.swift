// desktop/native/gather-core/Tests/GatherCoreTests/Services/DuplicateServiceTests.swift
// DuplicateService 行为测试（Phase 3.6）。
// TS 源: tests/unit/services/duplicate/duplicate-service.test.ts（用例逐一对应：
// excludeExactDuplicateHashes / computeVisualHashes / 视觉 hash 期间取消不落库），
// 并补充扫描单飞/busy、精确/视觉分组、resolve/resolve_member、进度回调等
// TS 服务层行为基线。差异说明：
// - TS 用 vi.mock 的 fake imageService（getThumbnail 返回 sharp 预览 buffer）；
//   Swift 侧经 thumbnailProvider 注入（返回 9x8 灰度像素网格，72 字节），
//   对应 TS computeVisualHashes 的 sharp resize 之后输入。
// - 取消断言：TS 检查 db.transaction 未被调用；Swift 断言数据库无任何写入
//   （checksum 未回写 / similarity_hashes / duplicate_groups 均为空）。
// - fixture 为真实 1x1 JPEG / PNG 字节（代码内嵌 base64，无外部命令）。
// - 时序用例（单飞窗口）用轮询等待而非固定 sleep（工具链决议 #4）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 支撑

/// 9x8 均匀灰度像素网格（DHash 输出 64 个 0）。
private let uniformPixels = [UInt8](repeating: 128, count: 72)

/// 真实 1x1 JPEG / PNG fixture（校验过 file 可识别，仅作文件字节用——
/// 缩略图由注入的 thumbnailProvider 提供）。
private let jpegFixtureBytes = Data(base64Encoded: "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q==")!
private let pngFixtureBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
private let textFixtureBytes = Data("distinct-bytes-for-visual-only-photo".utf8)

private func hexSHA256(_ data: Data) -> String {
    SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
}

private func setMtime(_ path: String, _ timeIntervalSince1970: TimeInterval) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: timeIntervalSince1970)],
        ofItemAtPath: path
    )
}

private final class AsyncGate {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if released { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// 线程安全计数器（provider 调用次数等断言用）。
private final class CallCounter: @unchecked Sendable {
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

/// 轮询等待条件成立（swift-testing 并行下 Task 调度延迟明显，避免固定 sleep）。
private func waitUntil(
    timeoutMs: Double = 5000,
    _ condition: () throws -> Bool
) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutMs / 1000)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try condition()
}

private struct DuplicateHarness {
    let db: DBConnection
    let service: DuplicateService
    let sessionId: String
    let dir: String
}

private func makeDuplicateHarness(
    thumbnail: @escaping DuplicateService.ThumbnailProvider = { _, _ in uniformPixels },
    cluster: @escaping DuplicateService.ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
        try ClusterEngine.clusterByHash(
            entries: entries, threshold: threshold, minGroupSize: minGroupSize,
            mode: mode, onProgress: onProgress)
    }
) async throws -> DuplicateHarness {
    let db = try await makeMigratedDB()
    try insertSession(db, "session")
    let dir = try makeTempDir()
    let service = DuplicateService(
        connection: db,
        thumbnailProvider: thumbnail,
        clusterProvider: cluster
    )
    return DuplicateHarness(db: db, service: service, sessionId: "session", dir: dir)
}

/// 插入 photos 行（可预置 checksum 与文件统计，测试 checksum 复用路径）。
private func insertPhotoRow(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String,
    checksum: String = "",
    checksumFileSize: Int64 = 0,
    checksumFileMtimeMs: Double = 0
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([
            .text(id), .text(sessionId), .text(filepath),
            .text((filepath as NSString).lastPathComponent),
            .text(checksum), .int(checksumFileSize), .real(checksumFileMtimeMs),
        ])
}

/// 写真实文件 + 插 photos 行，返回文件路径。
@discardableResult
private func addPhoto(
    _ harness: DuplicateHarness,
    id: String,
    name: String,
    content: Data,
    checksum: String = "",
    checksumFileSize: Int64 = 0,
    checksumFileMtimeMs: Double = 0
) throws -> String {
    let path = try writeTempFile(in: harness.dir, name: name, content: content)
    try insertPhotoRow(
        harness.db, id: id, sessionId: harness.sessionId, filepath: path,
        checksum: checksum, checksumFileSize: checksumFileSize, checksumFileMtimeMs: checksumFileMtimeMs
    )
    return path
}

private func photoChecksum(_ db: DBConnection, _ id: String) throws -> String {
    let row = try db.prepare("SELECT checksum FROM photos WHERE id = ?").get([.text(id)])
    return row?[0].textValue ?? ""
}

// MARK: - 纯函数（TS 对账：excludeExactDuplicateHashes / computeVisualHashes）

@Suite("duplicate 纯函数（TS 对账）")
struct DuplicatePureFunctionTests {
    @Test("exact 重复的照片不出现在视觉 hash 行里")
    func excludeExactDuplicateHashesFiltersExactIds() {
        let rows: [(photoId: String, hashHex: String)] = [
            (photoId: "exact-a", hashHex: "0000"),
            (photoId: "exact-b", hashHex: "0000"),
            (photoId: "visual-a", hashHex: "0001"),
            (photoId: "visual-b", hashHex: "0002"),
        ]

        let filtered = excludeExactDuplicateHashes(
            rows: rows,
            exactPhotoIds: Set(["exact-a", "exact-b"])
        )

        #expect(filtered.map(\.photoId) == ["visual-a", "visual-b"])
        #expect(filtered.map(\.hashHex) == ["0001", "0002"])
    }

    @Test("相同像素的缩略图得到相同视觉 hash，每张照片恰好调用一次")
    func computeVisualHashesSamePixelsSameHash() async {
        let calls = CallCounter()
        let hashes = await computeVisualHashes(
            photos: [
                (id: "first", filepath: "/first.raw"),
                (id: "second", filepath: "/second.raw"),
            ],
            thumbnailProvider: { _, _ in
                calls.increment()
                return uniformPixels
            }
        )

        #expect(hashes.count == 2)
        #expect(hashes["first"] == hashes["second"])
        #expect(hashes["first"] == DHash.compute(pixels9x8: uniformPixels))
        #expect(calls.value == 2)
    }

    @Test("corrupt 图片静默跳过，不影响其余照片")
    func computeVisualHashesSkipsCorruptPhotos() async {
        let hashes = await computeVisualHashes(
            photos: [
                (id: "corrupt", filepath: "/corrupt.raw"),
                (id: "ok", filepath: "/ok.raw"),
            ],
            thumbnailProvider: { filepath, _ in
                filepath == "/corrupt.raw" ? nil : uniformPixels
            }
        )

        #expect(hashes["corrupt"] == nil)
        #expect(hashes["ok"] == DHash.compute(pixels9x8: uniformPixels))
    }
}

// MARK: - 扫描：精确/视觉分组、复用、单飞、取消、进度

@Suite("DuplicateService scan")
struct DuplicateScanTests {
    @Test("同内容文件形成精确组（含 checksum 回写与 similarity_hashes 落库）")
    func exactDuplicatesFormExactGroup() async throws {
        let harness = try await makeDuplicateHarness()
        try addPhoto(harness, id: "a1", name: "a1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "a2", name: "a2.jpg", content: jpegFixtureBytes)

        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)

        #expect(result.exactGroups.count == 1)
        let group = result.exactGroups[0]
        #expect(group.groupType == .exact)
        #expect(group.checksum == hexSHA256(jpegFixtureBytes))
        #expect(group.memberCount == 2)
        #expect(Set(group.members.map(\.photoId)) == Set(["a1", "a2"]))
        #expect(group.members.allSatisfy { $0.isKept })
        #expect(group.members.allSatisfy { $0.fileSize == jpegFixtureBytes.count })
        #expect(group.members.allSatisfy { $0.fileMtime != nil })
        #expect(result.visualGroups.isEmpty)
        #expect(result.totalDuplicates == 2)

        // 精确重复不进视觉组：uniform 像素的 hash 已写库但被排除。
        let hashCount = try rowCount(
            harness.db,
            "SELECT COUNT(*) FROM similarity_hashes WHERE session_id = ?",
            [.text(harness.sessionId)]
        )
        #expect(hashCount == 2)
        let hashRows = try harness.db.prepare(
            "SELECT hash_hex, file_size FROM similarity_hashes WHERE session_id = ? ORDER BY photo_id"
        ).query([.text(harness.sessionId)])
        #expect(hashRows.allSatisfy { $0[0].textValue == "0000000000000000" })
        #expect(hashRows.allSatisfy { $0[1].intValue == Int64(jpegFixtureBytes.count) })

        // checksum 与文件统计回写 photos。
        #expect(try photoChecksum(harness.db, "a1") == hexSHA256(jpegFixtureBytes))
        #expect(try photoChecksum(harness.db, "a2") == hexSHA256(jpegFixtureBytes))
    }

    @Test("exact 重复的照片绝不进入视觉组")
    func exactDuplicatesExcludedFromVisualGroups() async throws {
        let harness = try await makeDuplicateHarness()
        try addPhoto(harness, id: "c1", name: "c1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "c2", name: "c2.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "d1", name: "d1.png", content: pngFixtureBytes)
        try addPhoto(harness, id: "d2", name: "d2.png", content: pngFixtureBytes)

        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)

        #expect(result.exactGroups.count == 2)
        #expect(result.exactGroups.allSatisfy { $0.memberCount == 2 })
        #expect(result.visualGroups.isEmpty)
        #expect(result.totalDuplicates == 4)
    }

    @Test("内容不同但视觉 hash 相同的文件形成视觉组")
    func visualDuplicatesFormVisualGroup() async throws {
        let harness = try await makeDuplicateHarness()
        try addPhoto(harness, id: "v1", name: "v1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "v2", name: "v2.png", content: pngFixtureBytes)

        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)

        #expect(result.exactGroups.isEmpty)
        #expect(result.visualGroups.count == 1)
        let group = result.visualGroups[0]
        #expect(group.groupType == .visual)
        #expect(group.hashHex == "0000000000000000")
        #expect(group.memberCount == 2)
        #expect(Set(group.members.map(\.photoId)) == Set(["v1", "v2"]))
        #expect(result.totalDuplicates == 2)
    }

    @Test("corrupt 缩略图静默跳过，其余照片照常分组")
    func corruptThumbnailIsSkippedSilently() async throws {
        let calls = CallCounter()
        let harness = try await makeDuplicateHarness(thumbnail: { filepath, _ in
            calls.increment()
            return filepath.hasSuffix("c1.jpg") ? nil : uniformPixels
        })
        // c1/c2 同内容（精确对，且 c1/c2 因同 size 进入 sha256 候选）；
        // c3/c4 各自独立内容但视觉 hash 相同。
        try addPhoto(harness, id: "c1", name: "c1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "c2", name: "c2.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "c3", name: "c3.txt", content: textFixtureBytes)
        try addPhoto(harness, id: "c4", name: "c4.txt", content: Data("another-distinct-content".utf8))

        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)

        #expect(calls.value == 4)
        #expect(result.exactGroups.count == 1)
        #expect(Set(result.exactGroups[0].members.map(\.photoId)) == Set(["c1", "c2"]))
        #expect(result.visualGroups.count == 1)
        #expect(Set(result.visualGroups[0].members.map(\.photoId)) == Set(["c3", "c4"]))
        #expect(result.visualGroups.flatMap { $0.members }.allSatisfy { $0.photoId != "c1" })
        // 文件本身可读：checksum 照常回写。
        #expect(try photoChecksum(harness.db, "c1") == hexSHA256(jpegFixtureBytes))
    }

    @Test("checksum 与 size/mtime 一致时复用，不重新哈希")
    func matchingChecksumRowsAreNotRehashed() async throws {
        let harness = try await makeDuplicateHarness()
        let pathA = try addPhoto(harness, id: "a", name: "a.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "b", name: "b.jpg", content: jpegFixtureBytes)
        let statA = tsStat(pathA)!
        // a：正确的 checksum 行 → 复用；b：size 不匹配 → 必须重算。
        _ = try harness.db.prepare("""
            UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ? WHERE id = ?
            """).run([
                .text(hexSHA256(jpegFixtureBytes)), .int(statA.size), .real(statA.mtimeMs), .text("a"),
            ])
        _ = try harness.db.prepare("""
            UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ? WHERE id = ?
            """).run([
                .text(hexSHA256(jpegFixtureBytes)), .int(statA.size + 1), .real(statA.mtimeMs), .text("b"),
            ])

        var progress: [(message: String, current: Int, total: Int)] = []
        let result = try await harness.service.scanDuplicates(
            sessionId: harness.sessionId,
            onProgress: { current, total, message in
                progress.append((message, current, total))
            }
        )

        // 2 张照片 + 1 个候选（仅 b 重算）。
        #expect(progress.contains { $0.message == "duplicate.hash" && $0.current == 3 && $0.total == 6 })
        // 复用路径下精确组照常由已存 checksum 聚合。
        #expect(result.exactGroups.count == 1)
        #expect(result.exactGroups[0].memberCount == 2)
    }

    @Test("similarity_hashes 行在 size/mtime 一致时复用，provider 只为缺失照片调用")
    func matchingVisualHashRowsAreReused() async throws {
        let calls = CallCounter()
        let harness = try await makeDuplicateHarness(thumbnail: { _, _ in
            calls.increment()
            return uniformPixels
        })
        let pathA = try addPhoto(harness, id: "a", name: "a.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "b", name: "b.png", content: pngFixtureBytes)
        let statA = tsStat(pathA)!
        _ = try harness.db.prepare("""
            INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
            VALUES (?, ?, ?, ?, ?)
            """).run([
                .text(harness.sessionId), .text("a"), .text("0000000000000000"),
                .int(statA.size), .real(statA.mtimeMs),
            ])

        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)

        // 仅 b 缺失视觉 hash → provider 只被调用一次。
        #expect(calls.value == 1)
        #expect(result.visualGroups.count == 1)
        #expect(Set(result.visualGroups[0].members.map(\.photoId)) == Set(["a", "b"]))
    }

    @Test("扫描结果持久化，getGroups 按 group_type, id 读取一致")
    func scanResultsPersistAndReload() async throws {
        let harness = try await makeDuplicateHarness()
        let pathE1 = try addPhoto(harness, id: "e1", name: "e1.jpg", content: jpegFixtureBytes)
        let pathE2 = try addPhoto(harness, id: "e2", name: "e2.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "v1", name: "v1.png", content: pngFixtureBytes)
        try addPhoto(harness, id: "v2", name: "v2.txt", content: textFixtureBytes)

        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)
        let groups = try harness.service.getGroups(sessionId: harness.sessionId)

        #expect(groups.map(\.groupType) == [.exact, .visual])
        #expect(groups[0] == result.exactGroups[0])
        #expect(groups[1] == result.visualGroups[0])
        // 成员 JOIN photos 带回真实路径与文件名。
        #expect(groups[0].members.map(\.filepath).sorted() == [pathE1, pathE2].sorted())
        #expect(groups[0].members.map(\.filename).sorted() == ["e1.jpg", "e2.jpg"].sorted())
        #expect(groups[1].members.map(\.filename).sorted() == ["v1.png", "v2.txt"].sorted())
    }

    @Test("scan 单飞：同参数共享在飞结果，不同参数抛 DUPLICATE_SCAN_BUSY")
    func scanIsSingleFlight() async throws {
        let gate = AsyncGate()
        let calls = CallCounter()
        let harness = try await makeDuplicateHarness(thumbnail: { _, _ in
            calls.increment()
            await gate.wait()
            return uniformPixels
        })
        try addPhoto(harness, id: "p1", name: "p1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "p2", name: "p2.png", content: pngFixtureBytes)

        let firstTask = Task {
            try await harness.service.scanDuplicates(sessionId: harness.sessionId)
        }
        // 等首扫进入视觉 hash 阶段（provider 已卡在 gate 上）。
        let entered = try waitUntil { calls.value > 0 }
        #expect(entered)

        // 不同参数 → busy（经 Task 包装制造真实挂起点，避免无 async 操作警告）。
        let busyOther = Task {
            try await harness.service.scanDuplicates(sessionId: "other-session")
        }
        await #expect(throws: DuplicateServiceError.scanBusy) {
            try await busyOther.value
        }
        let busyThreshold = Task {
            try await harness.service.scanDuplicates(sessionId: harness.sessionId, visualThreshold: 8)
        }
        await #expect(throws: DuplicateServiceError.scanBusy) {
            try await busyThreshold.value
        }
        #expect(try await DuplicateServiceError.scanBusy.gatherCode == .DUPLICATE_SCAN_BUSY)

        // 同参数 → 与在飞扫描共享同一结果（不触发第二次扫描）。
        let secondTask = Task {
            try await harness.service.scanDuplicates(sessionId: harness.sessionId)
        }
        gate.release()

        let first = try await firstTask.value
        let second = try await secondTask.value
        #expect(first == second)
        #expect(calls.value == 2)
    }

    @Test("视觉 hash 计算期间取消：抛取消且不落任何库")
    func cancellationDuringVisualHashPersistsNothing() async throws {
        let signal = JobAbortSignal()
        let harness = try await makeDuplicateHarness(thumbnail: { _, _ in
            signal.abort()
            return nil
        })
        try addPhoto(harness, id: "p1", name: "p1.jpg", content: jpegFixtureBytes)

        await #expect(throws: JobCancelledError()) {
            try await harness.service.scanDuplicates(
                sessionId: harness.sessionId,
                signal: signal
            )
        }

        // TS 等价断言：取消在 computeVisualHashes 期间到达，persist 与 scan
        // 事务必须从未执行——checksum 未回写、无 hash 行、无分组行。
        #expect(try photoChecksum(harness.db, "p1") == "")
        #expect(try rowCount(
            harness.db, "SELECT COUNT(*) FROM similarity_hashes WHERE session_id = ?",
            [.text(harness.sessionId)]
        ) == 0)
        #expect(try rowCount(
            harness.db, "SELECT COUNT(*) FROM duplicate_groups WHERE session_id = ?",
            [.text(harness.sessionId)]
        ) == 0)
    }

    @Test("进度回调三个阶段：duplicate.read / duplicate.hash / duplicate.done")
    func progressReportsThreePhases() async throws {
        let harness = try await makeDuplicateHarness()
        try addPhoto(harness, id: "p1", name: "p1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "p2", name: "p2.png", content: pngFixtureBytes)

        var progress: [(message: String, current: Int, total: Int)] = []
        _ = try await harness.service.scanDuplicates(
            sessionId: harness.sessionId,
            onProgress: { current, total, message in
                progress.append((message, current, total))
            }
        )

        // 2 张照片：total 恒为 6；hash 阶段无候选（size 不同）current = 2。
        #expect(progress.map(\.message) == ["duplicate.read", "duplicate.hash", "duplicate.done"])
        #expect(progress.map(\.current) == [2, 2, 6])
        #expect(progress.map(\.total) == [6, 6, 6])
    }

    @Test("二次扫描完全复用已落库的 checksum 与视觉 hash")
    func secondScanReusesPersistedData() async throws {
        let calls = CallCounter()
        let harness = try await makeDuplicateHarness(thumbnail: { _, _ in
            calls.increment()
            return uniformPixels
        })
        try addPhoto(harness, id: "p1", name: "p1.jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: "p2", name: "p2.png", content: pngFixtureBytes)

        let first = try await harness.service.scanDuplicates(sessionId: harness.sessionId)
        #expect(calls.value == 2)

        var progress: [(message: String, current: Int)] = []
        let second = try await harness.service.scanDuplicates(
            sessionId: harness.sessionId,
            onProgress: { current, _, message in
                progress.append((message, current))
            }
        )

        #expect(calls.value == 2)
        #expect(progress.contains { $0.message == "duplicate.hash" && $0.current == 2 })
        // 重扫重建分组：组/成员 id 更新，但分组语义与成员集合一致。
        #expect(second.exactGroups.map(\.memberCount) == first.exactGroups.map(\.memberCount))
        #expect(second.visualGroups.map(\.memberCount) == first.visualGroups.map(\.memberCount))
        #expect(second.visualGroups[0].members.map(\.photoId).sorted()
            == first.visualGroups[0].members.map(\.photoId).sorted())
        #expect(second.totalDuplicates == first.totalDuplicates)
    }
}

// MARK: - resolve / resolve_member

@Suite("DuplicateService resolve")
struct DuplicateResolveTests {
    private func scanExactPair(
        _ harness: DuplicateHarness,
        idA: String = "a",
        idB: String = "b"
    ) async throws -> DuplicateScanResult {
        try addPhoto(harness, id: idA, name: "\(idA).jpg", content: jpegFixtureBytes)
        try addPhoto(harness, id: idB, name: "\(idB).jpg", content: jpegFixtureBytes)
        return try await harness.service.scanDuplicates(sessionId: harness.sessionId)
    }

    @Test("keep_one 保留分数最高（size*1000 + mtimeMs）的成员并重算照片状态")
    func resolveGroupKeepOneKeepsBestMember() async throws {
        let harness = try await makeDuplicateHarness()
        let pathA = try addPhoto(harness, id: "a", name: "a.jpg", content: jpegFixtureBytes)
        let pathB = try addPhoto(harness, id: "b", name: "b.jpg", content: jpegFixtureBytes)
        // 同内容同 size，用 mtime 决出最优：b 更新 → 保留 b。
        try setMtime(pathA, 1_700_000_000)
        try setMtime(pathB, 1_700_000_060)
        let result = try await harness.service.scanDuplicates(sessionId: harness.sessionId)
        let group = result.exactGroups[0]

        try harness.service.resolveGroup(groupId: group.id, resolution: .keepOne)

        let members = try harness.service.getGroups(sessionId: harness.sessionId)[0].members
        let byPhoto = Dictionary(uniqueKeysWithValues: members.map { ($0.photoId, $0) })
        #expect(byPhoto["a"]?.isKept == false)
        #expect(byPhoto["b"]?.isKept == true)
        #expect(members.allSatisfy { $0.resolution == "keep_one" })
        // 照片状态：未保留的 a → removed，保留的 b → ready。
        let statuses = try harness.db.prepare(
            "SELECT id, status FROM photos WHERE session_id = ? ORDER BY id"
        ).query([.text(harness.sessionId)]).map { ($0[0].textValue ?? "", $0[1].textValue ?? "") }
        #expect(statuses.map(\.1) == ["removed", "ready"])

        // 重扫：removed 照片复位 ready（unremove 路径），分组重建且 resolution 重置。
        let rescanned = try await harness.service.scanDuplicates(sessionId: harness.sessionId)
        #expect(rescanned.exactGroups.count == 1)
        #expect(rescanned.exactGroups[0].members.allSatisfy { $0.isKept })
        let afterRescan = try harness.db.prepare(
            "SELECT status FROM photos WHERE id = ?"
        ).get([.text("a")])?[0].textValue
        #expect(afterRescan == "ready")
        let groupResolution = try harness.db.prepare(
            "SELECT resolution FROM duplicate_groups WHERE session_id = ?"
        ).get([.text(harness.sessionId)])?[0].textValue
        #expect(groupResolution == nil)
    }

    @Test("keep_one 分数公式：size 分量可压过 mtime 分量")
    func resolveGroupKeepOneScoresBySizeThenMtime() async throws {
        let db = try await makeMigratedDB()
        try insertSession(db, "session")
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES ('p1', 'session', '/p1.jpg', 'p1.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
                   ('p2', 'session', '/p2.jpg', 'p2.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run()
        _ = try db.prepare("""
            INSERT INTO duplicate_groups (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at)
            VALUES ('session', 'exact', 'abc', NULL, 2, NULL, '2026-01-01T00:00:00.000Z')
            """).run()
        let groupId = Int(db.lastInsertRowid)
        // p1：size 100_000_000 但更旧；p2：size 500 但更新。
        _ = try db.prepare("""
            INSERT INTO duplicate_group_members (group_id, photo_id, session_id, is_kept, file_size, file_mtime)
            VALUES (?, 'p1', 'session', 1, 100000000, '2024-01-01T00:00:00.000Z'),
                   (?, 'p2', 'session', 1, 500, '2025-01-01T00:00:00.000Z')
            """).run([.int(Int64(groupId)), .int(Int64(groupId))])
        let service = DuplicateService(connection: db)

        try service.resolveGroup(groupId: groupId, resolution: .keepOne)

        let flags = try db.prepare(
            "SELECT photo_id, is_kept FROM duplicate_group_members WHERE group_id = ? ORDER BY id"
        ).query([.int(Int64(groupId))]).map { ($0[0].textValue ?? "", $0[1].intValue ?? 0) }
        // score: p1 = 100000000*1000 + 2024ms > p2 = 500*1000 + 2025ms
        //（size 分量压过一年 mtime 差：1e11 > 3.16e10）。
        #expect(flags.map(\.1) == [1, 0])
    }

    @Test("keep_all 保留全部成员并复位照片状态")
    func resolveGroupKeepAllKeepsAllMembers() async throws {
        let harness = try await makeDuplicateHarness()
        _ = try await scanExactPair(harness)
        let group = try harness.service.getGroups(sessionId: harness.sessionId)[0]

        try harness.service.resolveGroup(groupId: group.id, resolution: .keepAll)

        let members = try harness.service.getGroups(sessionId: harness.sessionId)[0].members
        #expect(members.allSatisfy { $0.isKept })
        #expect(members.allSatisfy { $0.resolution == "keep_all" })
        let statuses = try harness.db.prepare(
            "SELECT status FROM photos WHERE session_id = ?"
        ).query([.text(harness.sessionId)]).map { $0[0].textValue ?? "" }
        #expect(statuses == ["ready", "ready"])
    }

    @Test("组不存在或无成员：抛错且 UPDATE 回滚")
    func resolveGroupMissingOrEmptyThrowsAndRollsBack() async throws {
        let db = try await makeMigratedDB()
        try insertSession(db, "session")
        // 有组但无成员：UPDATE resolution 必须先执行再抛错，事务回滚。
        _ = try db.prepare("""
            INSERT INTO duplicate_groups (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at)
            VALUES ('session', 'exact', 'abc', NULL, 0, NULL, '2026-01-01T00:00:00.000Z')
            """).run()
        let groupId = Int(db.lastInsertRowid)
        let service = DuplicateService(connection: db)

        #expect(throws: DuplicateServiceError.groupNotFound(groupId)) {
            try service.resolveGroup(groupId: groupId, resolution: .keepOne)
        }
        #expect(throws: DuplicateServiceError.groupNotFound(9999)) {
            try service.resolveGroup(groupId: 9999, resolution: .keepOne)
        }
        // 事务回滚：resolution 保持 NULL。
        let resolution = try db.prepare(
            "SELECT resolution FROM duplicate_groups WHERE id = ?"
        ).get([.int(Int64(groupId))])?[0].textValue
        #expect(resolution == nil)
    }

    @Test("resolve_member：isKept=false 移除成员并写 keep_one，照片置 removed")
    func resolveMemberIsKeptFalseMarksRemoved() async throws {
        let harness = try await makeDuplicateHarness()
        let result = try await scanExactPair(harness)
        let members = result.exactGroups[0].members
        let memberA = members.first { $0.photoId == "a" }!

        try harness.service.resolveMember(memberId: memberA.id, isKept: false)

        let stored = try harness.service.getGroups(sessionId: harness.sessionId)[0].members
        let byPhoto = Dictionary(uniqueKeysWithValues: stored.map { ($0.photoId, $0) })
        #expect(byPhoto["a"]?.isKept == false)
        #expect(byPhoto["a"]?.resolution == "keep_one")
        #expect(byPhoto["b"]?.isKept == true)
        #expect(byPhoto["b"]?.resolution == nil)
        let statuses = try harness.db.prepare(
            "SELECT id, status FROM photos WHERE session_id = ? ORDER BY id"
        ).query([.text(harness.sessionId)]).map { ($0[0].textValue ?? "", $0[1].textValue ?? "") }
        // TS 语义：resolveMember 只重算该成员照片状态——a → removed，
        // b 保持原状态（pending，未被触碰）。
        #expect(statuses.map(\.1) == ["removed", "pending"])
    }

    @Test("resolve_member：COALESCE 语义——已定的 resolution 不被覆盖")
    func resolveMemberCoalescesExistingResolution() async throws {
        let harness = try await makeDuplicateHarness()
        let result = try await scanExactPair(harness)
        let memberA = result.exactGroups[0].members.first { $0.photoId == "a" }!
        try harness.service.resolveMember(memberId: memberA.id, isKept: false)

        // 重新保留：is_kept 恢复 1，resolution 保持 keep_one 不被覆盖。
        try harness.service.resolveMember(memberId: memberA.id, isKept: true)

        let stored = try harness.service.getGroups(sessionId: harness.sessionId)[0].members
        let byPhoto = Dictionary(uniqueKeysWithValues: stored.map { ($0.photoId, $0) })
        #expect(byPhoto["a"]?.isKept == true)
        #expect(byPhoto["a"]?.resolution == "keep_one")
        // 仅 a 被重算 → ready；b 从未被触碰 → pending。
        let statuses = try harness.db.prepare(
            "SELECT status FROM photos WHERE session_id = ? ORDER BY id"
        ).query([.text(harness.sessionId)]).map { $0[0].textValue ?? "" }
        #expect(statuses == ["ready", "pending"])
    }

    @Test("resolve_member：成员不存在抛错")
    func resolveMemberMissingMemberThrows() async throws {
        let db = try await makeMigratedDB()
        let service = DuplicateService(connection: db)

        #expect(throws: DuplicateServiceError.memberNotFound(9999)) {
            try service.resolveMember(memberId: 9999, isKept: false)
        }
    }
}
