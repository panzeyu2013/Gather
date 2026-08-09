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
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
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
    fileIdentity: String = ""
) throws {
    _ = try db.prepare("""
        INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '', 'unknown', 0, 0, ?, 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(id), .text(volumeId), .text(fileIdentity), .text(normalizedPath),
        .text((normalizedPath as NSString).lastPathComponent), .text(checksum),
    ])
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
