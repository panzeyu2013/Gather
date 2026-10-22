// desktop/native/gather-core/Tests/GatherCoreTests/Delivery/DeliveryTestSupport.swift
// WP2b 新增测试的共享夹具：内存 SchemaV1 + 可观测的文件端口。
//
// 只被 Tests/GatherCoreTests/Delivery 下的测试使用；不复用 DeliveryCoordinatorTests
// 的私有 fixtures，避免测试之间互相耦合。

import Foundation
import Testing
@testable import GatherDelivery
@testable import GatherPersistence
@testable import GatherProtocol

enum DeliveryTestSupport {
    static let sessionId = "s1"
    static let otherSessionId = "s2"
    static let photoId = "p1"
    static let xmpPath = "/v/IMG_1.xmp"
    static let photoPath = "/v/IMG_1.jpg"
    static let backupPath = "/backup/IMG_1.xmp"

    static func makeDB() throws -> DBConnection {
        let db = try DBConnection(path: ":memory:")
        try db.exec(SchemaV1.sql)
        try insertSession(db, sessionId)
        try insertSession(db, otherSessionId)
        try insertPhoto(db, photoId, sessionId: sessionId)
        return db
    }

    static func insertSession(_ db: DBConnection, _ id: String) throws {
        _ = try db.prepare("""
            INSERT INTO sessions (id, name, status, reload_acked_at, created_at, updated_at)
            VALUES (?, '', 'draft', '2026-01-01T00:00:00.000Z',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([.text(id)])
    }

    static func insertPhoto(
        _ db: DBConnection,
        _ id: String,
        sessionId: String
    ) throws {
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([
                .text(id), .text(sessionId), .text("/photos/" + id + ".jpg"), .text(id + ".jpg"),
            ])
    }

    /// 建一条 synced 交付（可选关联本会话与 culling item）。
    @discardableResult
    static func makeSyncedDelivery(
        repo: DeliveryRepo,
        xmpPath: String = xmpPath,
        photoPath: String = photoPath,
        revision: Int64 = 1,
        backupPath: String = backupPath,
        baseFingerprint: String = "fp-base",
        sessionId: String? = sessionId,
        itemModule: DeliveryModule? = nil,
        itemStatus: DeliveryItemStatus = .written
    ) throws -> DeliveryRow {
        _ = try repo.createOrGet(
            xmpPath: xmpPath, photoPath: photoPath, revision: revision)
        if let sessionId {
            _ = try repo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
        }
        if let itemModule {
            _ = try repo.upsertItem(
                xmpPath: xmpPath,
                photoId: photoId,
                module: itemModule,
                status: itemStatus
            )
        }
        _ = try repo.markWriting(xmpPath: xmpPath, revision: revision)
        _ = try repo.markWritten(
            xmpPath: xmpPath,
            revision: revision,
            baseFingerprint: baseFingerprint,
            baseValues: .object([:]),
            backupPath: backupPath
        )
        _ = try repo.markSynced(xmpPath: xmpPath, revision: revision)
        guard let row = try repo.get(xmpPath) else {
            throw DeliveryTestSupportError.rowMissing
        }
        return row
    }

    static func cleanupPayload(
        for row: DeliveryRow,
        action: DeliveryIntentAction = .cleanup,
        module: DeliveryModule? = .culling
    ) -> DeliveryCleanupPayload {
        DeliveryCleanupPayload(
            delivery: row,
            photoPath: row.photoPath,
            action: action,
            module: module
        )
    }
}

enum DeliveryTestSupportError: Error {
    case rowMissing
}

/// 可观测的内存文件端口：restore = 备份覆盖写（幂等），remove = 删键。
/// onRestore 允许测试在 restore 的 await 窗口里注入新输入（file phase 竞态）。
final class DeliveryTestFilePort: DeliveryFilePort, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]
    private var restoredTargets: [String] = []
    private var removedPaths: [String] = []
    private var restoreFailure: Error?
    private var removeFailure: Error?
    var onRestore: (@Sendable () throws -> Void)?
    var onRemove: (@Sendable () throws -> Void)?

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    func setContents(_ path: String, _ value: String) {
        lock.withLock { storage[path] = value }
    }

    func contents(_ path: String) -> String? {
        lock.withLock { storage[path] }
    }

    func setRestoreFailure(_ error: Error?) {
        lock.withLock { restoreFailure = error }
    }

    func setRemoveFailure(_ error: Error?) {
        lock.withLock { removeFailure = error }
    }

    var restoreCallCount: Int {
        lock.withLock { restoredTargets.count }
    }

    var restoredTargetsSnapshot: [String] {
        lock.withLock { restoredTargets }
    }

    var removedPathsSnapshot: [String] {
        lock.withLock { removedPaths }
    }

    func fileExists(_ path: String) -> Bool {
        lock.withLock { storage[path] != nil }
    }

    func restore(photoPath: String, backupPath: String) async throws {
        let target = TSPath.xmpSidecarPath(photoPath)
        try onRestore?()
        try lock.withLock {
            restoredTargets.append(target)
            if let restoreFailure { throw restoreFailure }
            guard let backup = storage[backupPath] else {
                throw DeliveryTestFileError.missingBackup(backupPath)
            }
            storage[target] = backup
        }
    }

    func removeFile(_ path: String) async throws {
        try onRemove?()
        try lock.withLock {
            removedPaths.append(path)
            if let removeFailure { throw removeFailure }
            storage.removeValue(forKey: path)
        }
    }
}

enum DeliveryTestFileError: Error, Equatable {
    case missingBackup(String)
}

/// 并发探针：统计同时进入文件阶段的最大并发数（验证 XMPFileLock 串行化）。
final class DeliveryTestConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maxActive = 0

    func begin() {
        lock.withLock {
            active += 1
            maxActive = max(maxActive, active)
        }
    }

    func end() {
        lock.withLock { active -= 1 }
    }

    var maximum: Int {
        lock.withLock { maxActive }
    }
}
