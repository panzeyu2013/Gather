// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift
// 仓库层测试共享支撑：内存库迁移 + 会话/照片插入等常用 fixture。

import Foundation
@testable import GatherCore

/// Store 库 + Store schema：统一用 StoreMigrator 建表（legacy MigrationRunner 已退役）。
@discardableResult
func makeMigratedStore(path: String) async throws -> SQLiteDatabase {
    let database = try SQLiteDatabase(path: path)
    try await StoreMigrator().migrate(database)
    return database
}


/// 打开已迁移的临时文件库（外键开启、索引已建）。
/// 说明：统一用唯一临时文件，避免 :memory: 实例无法共享。
func makeMigratedStore() async throws -> SQLiteDatabase {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-store-\(UUID().uuidString).sqlite").path
    return try await makeMigratedStore(path: path)
}

func insertSession(_ db: SQLiteDatabase, _ id: String) async throws {
    _ = try await db.run("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """, [.text(id)])
}

func insertPhoto(
    _ db: SQLiteDatabase,
    id: String,
    sessionId: String,
    filepath: String? = nil,
    checksum: String = ""
) async throws {
    // 默认路径按 id 区分，避免 idx_photos_session_filepath 唯一索引冲突
    let path = filepath ?? "/tmp/fixtures/\(id).jpg"
    _ = try await db.run("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """, [.text(id), .text(sessionId), .text(path), .text((path as NSString).lastPathComponent), .text(checksum)])
}

func insertAssetFile(
    _ db: SQLiteDatabase,
    id: String,
    normalizedPath: String,
    checksum: String = "",
    volumeId: String = "dev:1",
    fileIdentity: String = ""
) async throws {
    _ = try await db.run("""
        INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '', 'unknown', 0, 0, ?, 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """, [
        .text(id), .text(volumeId), .text(fileIdentity), .text(normalizedPath),
        .text((normalizedPath as NSString).lastPathComponent), .text(checksum),
    ])
}

/// assets 行（session_assets.asset_id / photos.asset_id 外键）。
func insertAsset(_ db: SQLiteDatabase, id: String, status: String = "active") async throws {
    _ = try await db.run("""
        INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
        VALUES (?, '', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """, [.text(id), .text(status)])
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
func rowCount(_ db: SQLiteDatabase, _ sql: String, _ values: [SQLiteValue] = []) async throws -> Int {
    guard let row = try await db.queryOne(sql, values) else { return 0 }
    return Int(row.values[row.columnOrder[0]]?.intValue ?? 0)
}
