// desktop/native/gather-app/Tests/GatherAppTests/Support/TestHelpers.swift
// app 测试共享小工具（task-36 收口；task-39 扩展错误辅助与 VM 库夹具）。
//
// containsCJK 原先在 5 个本地化/文案测试文件里逐份复制；LockedFlag 在
// APIDuplicateQualityTests / APIExportMetadataTests 各有一份。语义逐字一致
// （CJK 标点/汉字/全角区间并集；NSLock 保护的布尔探针），统一到本文件，
// 调用点仍按原名使用。
//
// task-39：API-live 套件里的 gatherError / asyncError / waitForJob 与 VM 测试里的
// insertSession / insertPhoto SQL 夹具此前各有 2–5 份逐字副本，现收敛到这里；
// 各文件调用点改为共享实现（VM 侧只保留差异化的薄包装）。
import Foundation
import GatherApplication
import GatherPersistence
import GatherProtocol
import GatherTestSupport

/// 文本是否含中日韩字符（汉字、CJK 标点、全角字符）。
func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3000...0x303F).contains(scalar.value)
            || (0x3400...0x9FFF).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }
}

/// 线程安全布尔探针（并发用例断言阶段是否进入/完成）。
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

// MARK: - 失败路径辅助（API-live 套件共用）

/// 只接受 GatherError：命中返回该错误，非 GatherError 返回 nil（便于 #expect）。
func gatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

/// 同步版：只接受 GatherError，非 GatherError 返回 nil。
func syncGatherError<T>(_ body: () throws -> T) -> GatherError? {
    do {
        _ = try body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

/// 任意错误：只断言「必须抛错」、不断言错误类型时用。
func asyncError<T>(_ body: () async throws -> T) async -> Error? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// 等 JobService 出现指定类型的 job（异步条件等待，替代固定 sleep）。
func waitForJob(
    _ jobService: JobService,
    type: AnalysisJobType,
    timeout: TimeInterval = 2
) async throws {
    let seen = try await waitUntilCondition(timeout: timeout) {
        try jobService.list(includeCheckpoint: false).contains(where: { $0.type == type })
    }
    guard seen else { throw TestHelperError.jobNotCreated }
}

/// 共享等待辅助的超时错误：让用例以抛错失败，而不是静默变绿。
enum TestHelperError: Error {
    case jobNotCreated
}

// MARK: - VM 测试库夹具（真实 SQLite）

/// 会话行（VM 测试共用）：status 固定 photos_loaded（列表加载以照片已入会话为前提）。
///
/// 与 GatherTestSupport.insertSession 的差异：后者是 core 侧最小行（draft/空名），
/// app 的 VM 用例需要可读名称与确定性 updated_at（会话列表按最近活动排序）。
func insertSessionRow(
    _ db: DBConnection,
    _ id: String,
    name: String = "工作区",
    updatedAt: String = "2026-01-01T00:00:00.000Z"
) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, created_at, updated_at)
        VALUES (?, ?, 'photos_loaded', ?, ?)
    """).run([.text(id), .text(name), .text(updatedAt), .text(updatedAt)])
}

/// 照片行（VM 测试共用）：未写列取与旧夹具一致的库默认值（checksum 空、status ready、
/// 尺寸 0）。`metadata` 非空时同时写 photo_metadata_cache（Library 过滤/排序依赖 cache 行）。
func insertPhotoRow(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String? = nil,
    filename: String? = nil,
    checksum: String = "",
    status: String = "ready",
    assetId: String? = nil,
    assetFileId: String? = nil,
    width: Int64 = 0,
    height: Int64 = 0,
    checksumFileSize: Int64 = 0,
    checksumFileMtimeMs: Double = 0,
    metadata: (rating: Int, label: String, keywords: String)? = nil
) throws {
    let path = filepath ?? "/tmp/\(id).jpg"
    let name = filename ?? (path as NSString).lastPathComponent
    _ = try db.prepare("""
        INSERT INTO photos (
            id, session_id, filepath, filename, checksum, checksum_file_size,
            checksum_file_mtime_ms, status, asset_id, asset_file_id, width, height,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """).run([
        .text(id), .text(sessionId), .text(path), .text(name), .text(checksum),
        .int(checksumFileSize), .real(checksumFileMtimeMs), .text(status),
        assetId.map { .text($0) } ?? .null,
        assetFileId.map { .text($0) } ?? .null,
        .int(width), .int(height),
        .text("2026-01-01T00:00:00.000Z"), .text("2026-01-01T00:00:00.000Z"),
    ])
    if let metadata {
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache (photo_id, session_id, rating, label, keywords, cached_at)
            VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z')
        """).run([
            .text(id), .text(sessionId), .int(Int64(metadata.rating)),
            .text(metadata.label), .text(metadata.keywords),
        ])
    }
}
