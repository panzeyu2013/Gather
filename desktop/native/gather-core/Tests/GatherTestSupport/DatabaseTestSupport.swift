// desktop/native/gather-core/Tests/GatherTestSupport/DatabaseTestSupport.swift
// GatherTestSupport：core 测试共享 fixture（Cut 3 / 3a-4）。
// 原 Tests/GatherCoreTests/Database/Repositories/RepoTestSupport.swift（108 行，9 个函数）。
//
// 独立 library target 的原因见 docs/module-split-map-v2.md §5.2：
// - 普通 target，不用 @testable（对 -enable-testing 无隐性依赖）；
// - public API 便于 gather-app 的 GatherAppTests 将来复用（package 访问级跨 package 不可用）。
// 全部 fixture 只调用 GatherPersistence 的 public API（DBConnection / DBStatement / SchemaCurrent）。

import Foundation
import GatherPersistence

/// 打开测试用内存库：**当前 schema 形态**。
///
/// 不写 user_version（夹具不参与版本门禁，版本由 Database.open 测）。
/// 本函数是 core/app 测试唯一的建库入口。
///
/// 成本（task-43，Linux 微基准 .gather/round7/db-bench.txt）：单次 ≈3.1ms CPU，
/// 其中 ≈3.08ms 是 SchemaCurrent.ddl 的 SQLite 执行（144 条语句 / 55 表 / 86 索引），
/// 连接 open+close ≈0.024ms；DDL 事务包裹实测仅再省 ≈1.6%（噪声级），故保持现状。
/// 用例内请一次建库、多断言，避免在循环里反复调用（N 次 ≈ N×3.1ms）。
public func makeTestDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaCurrent.ddl)
    return db
}

/// 最小会话行（V1 10 列；写回态/import_source/failed_count 已删）。
public func insertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, created_at, updated_at)
        VALUES (?, '', 'draft', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

public func insertPhoto(
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

public func insertAssetFile(
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

/// fixture 文件缺失：让用例抛错失败，而不是 preconditionFailure 杀掉整个测试进程。
public struct MissingFixtureFileError: Error, CustomStringConvertible {
    public let path: String
    public var description: String { "fixture file missing: \(path)" }
}

/// 按**真实文件**的身份登记 asset_files 行：storedPath 是登记路径（可以已不存在，
/// 模拟"文件被移走"），statPath 是磁盘上取身份证据（dev/ino/size/mtime）的文件。
/// relinkRoot 只接受通过身份校验的行，故重链接用例必须用本函数而非裸 insertAssetFile。
public func insertTrackedFile(
    _ db: DBConnection,
    id: String,
    storedPath: String,
    statPath: String,
    checksum: String = ""
) throws {
    guard let info = tsStat(statPath) else {
        throw MissingFixtureFileError(path: statPath)
    }
    try insertAssetFile(
        db, id: id, normalizedPath: storedPath, checksum: checksum,
        volumeId: "dev:\(info.dev)", fileIdentity: String(info.ino),
        fileSize: info.size, fileMtimeMs: info.mtimeMs
    )
}

/// assets 行（session_assets.asset_id / photos.asset_id 外键）。
public func insertAsset(_ db: DBConnection, id: String, status: String = "active") throws {
    _ = try db.prepare("""
        INSERT INTO assets (id, status, created_at, updated_at)
        VALUES (?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(status)])
}

/// 创建临时目录：登记到 TempHygiene，进程退出时统一删除（调用方仍可 defer 提前删，
/// 遗留的中断路径由 atexit 兜底）。
public func makeTempDir(prefix: String = "gather-repo-tests") throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    TempHygiene.track(dir)
    return dir.path
}

/// 写一个真实文件并返回其路径（内容为固定字节）。
public func writeTempFile(in dir: String, name: String, content: Data = Data("fake-image-bytes".utf8)) throws -> String {
    let path = dir + "/" + name
    try content.write(to: URL(fileURLWithPath: path))
    return path
}

/// 简单断言辅助：DB 行数（COUNT 结果值）。
public func rowCount(_ db: DBConnection, _ sql: String, _ values: [DBValue?] = []) throws -> Int {
    guard let row = try db.prepare(sql).get(values) else { return 0 }
    return Int(row[0].intValue ?? 0)
}
