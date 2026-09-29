// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift
// 仓库层测试共享支撑：内存库迁移 + 会话/照片插入等常用 fixture。

import Foundation
@testable import GatherCore

/// 打开已迁移的内存库（外键开启、索引已建）。
func makeMigratedDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

func insertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String? = nil,
    checksum: String = ""
) throws {
    // 默认路径按 id 区分，避免 idx_photos_session_filepath 唯一索引冲突
    let path = filepath ?? "/tmp/fixtures/\(id).jpg"
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text(path), .text((path as NSString).lastPathComponent), .text(checksum)])
}

func insertAssetFile(
    _ db: DBConnection,
    id: String,
    normalizedPath: String,
    checksum: String = "",
    volumeId: String = "dev:1",
    fileIdentity: String = "",
    fileSize: Int64 = 0,
    fileMtimeMs: Double = 0
) throws {
    _ = try db.prepare("""
        INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '', 'unknown', ?, ?, ?, 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(id), .text(volumeId), .text(fileIdentity), .text(normalizedPath),
        .text((normalizedPath as NSString).lastPathComponent),
        .int(fileSize), .real(fileMtimeMs), .text(checksum),
    ])
}

/// 按**真实文件**的身份登记 asset_files 行：storedPath 是登记路径（可以已不存在，
/// 模拟"文件被移走"），statPath 是磁盘上取身份证据（dev/ino/size/mtime）的文件。
/// relinkRoot 只接受通过身份校验的行，故重链接用例必须用本函数而非裸 insertAssetFile。
func insertTrackedFile(
    _ db: DBConnection,
    id: String,
    storedPath: String,
    statPath: String,
    checksum: String = ""
) throws {
    guard let info = tsStat(statPath) else {
        preconditionFailure("fixture file missing: \(statPath)")
    }
    try insertAssetFile(
        db, id: id, normalizedPath: storedPath, checksum: checksum,
        volumeId: "dev:\(info.dev)", fileIdentity: String(info.ino),
        fileSize: info.size, fileMtimeMs: info.mtimeMs
    )
}

/// assets 行（session_assets.asset_id / photos.asset_id 外键）。
func insertAsset(_ db: DBConnection, id: String, status: String = "active") throws {
    _ = try db.prepare("""
        INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
        VALUES (?, '', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(status)])
}

/// 创建临时目录（测试结束由调用方删除）。
func makeTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-repo-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

/// 写一个真实文件并返回其路径（内容为固定字节）。
func writeTempFile(in dir: String, name: String, content: Data = Data("fake-image-bytes".utf8)) throws -> String {
    let path = dir + "/" + name
    try content.write(to: URL(fileURLWithPath: path))
    return path
}

/// 简单断言辅助：DB 行数（COUNT 结果值）。
func rowCount(_ db: DBConnection, _ sql: String, _ values: [DBValue?] = []) throws -> Int {
    guard let row = try db.prepare(sql).get(values) else { return 0 }
    return Int(row[0].intValue ?? 0)
}
