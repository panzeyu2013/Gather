// desktop/native/gather-core/Tests/GatherCoreTests/Queries/QueryTestSupport.swift
// WP3b SQL Query 直接边界测试的共享夹具。
//
// 目的：PortFakeTests 用内存替身验证服务只经端口访问；本目录反过来直接构造
// **真实 SQLite**（makeTestDB：:memory: + SchemaV1 DDL），把 Query 类的 SQL
// 边界（字段解析、参数顺序、COALESCE/IN 空集、游标、分块）钉在库层。
// 与 *ServiceTests 的分工：服务测试断言端到端行为，这里只构造最小行并断言
// Query 的返回形状/顺序/计数，避免重复。

import Foundation
import GatherTestSupport
@testable import GatherPersistence

func makeQueryTestDB() throws -> DBConnection {
    try makeTestDB()
}

func queryInsertSession(_ db: DBConnection, id: String, name: String = "S") throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, created_at, updated_at)
        VALUES (?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(name)])
}

func queryInsertAsset(_ db: DBConnection, id: String) throws {
    _ = try db.prepare("""
        INSERT INTO assets (id, created_at, updated_at)
        VALUES (?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id)])
}

func queryInsertPhoto(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String? = nil,
    assetId: String? = nil,
    checksum: String = "",
    status: String = "pending"
) throws {
    let path = filepath ?? "/shots/\(id).jpg"
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          asset_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(id), .text(sessionId), .text(path),
        .text((path as NSString).lastPathComponent), .text(checksum), .text(status),
        assetId.map { DBValue.text($0) } ?? .null,
    ])
}

func queryInsertCache(
    _ db: DBConnection,
    photoId: String,
    sessionId: String,
    rating: Int? = nil,
    label: String? = nil,
    cameraMake: String? = nil,
    keywords: String = "[]"
) throws {
    _ = try db.prepare("""
        INSERT INTO photo_metadata_cache
          (photo_id, session_id, camera_make, rating, label, keywords, cached_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(photoId), .text(sessionId),
        cameraMake.map { DBValue.text($0) } ?? .null,
        rating.map { DBValue.int(Int64($0)) } ?? .null,
        label.map { DBValue.text($0) } ?? .null,
        .text(keywords),
    ])
}

func queryInsertDecision(
    _ db: DBConnection,
    sessionId: String,
    photoId: String,
    decision: String
) throws {
    _ = try db.prepare("""
        INSERT INTO culling_decisions
          (session_id, photo_id, group_id, decision, updated_at)
        VALUES (?, ?, 'ungrouped', ?, '2026-01-01T00:00:00.000Z')
    """).run([.text(sessionId), .text(photoId), .text(decision)])
}

@discardableResult
func queryInsertDelivery(
    _ db: DBConnection,
    photoPath: String,
    status: String,
    sessionIds: [String]
) throws -> Int64 {
    let xmpPath = "/sidecars/\(UUID().uuidString).xmp"
    _ = try db.prepare("""
        INSERT INTO deliveries (xmp_path, photo_path, status, created_at, updated_at)
        VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(xmpPath), .text(photoPath), .text(status)])
    let id = db.lastInsertRowid
    let link = try db.prepare("""
        INSERT INTO delivery_sessions (delivery_id, session_id) VALUES (?, ?)
    """)
    for sessionId in sessionIds {
        _ = try link.run([.int(id), .text(sessionId)])
    }
    return id
}

@discardableResult
func queryInsertSimilarityResult(
    _ db: DBConnection,
    sessionId: String,
    members: [(photoId: String, groupIndex: Int)],
    statsJSON: String = #"{"totalGroups":1}"#
) throws -> Int64 {
    _ = try db.prepare("""
        INSERT INTO similarity_results
          (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
        VALUES (?, '{"groups":[]}', ?, 10, 2, '2026-01-01T00:00:00.000Z')
    """).run([.text(sessionId), .text(statsJSON)])
    let resultId = db.lastInsertRowid
    let insert = try db.prepare("""
        INSERT INTO similarity_result_members (result_id, session_id, group_index, photo_id)
        VALUES (?, ?, ?, ?)
    """)
    for member in members {
        _ = try insert.run([
            .int(resultId), .text(sessionId), .int(Int64(member.groupIndex)), .text(member.photoId),
        ])
    }
    return resultId
}

@discardableResult
func queryInsertDuplicateGroup(
    _ db: DBConnection,
    sessionId: String,
    groupType: String = "exact",
    checksum: String? = nil,
    hashHex: String? = nil,
    memberCount: Int = 0,
    resolution: String? = nil
) throws -> Int {
    _ = try db.prepare("""
        INSERT INTO duplicate_groups
          (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at)
        VALUES (?, ?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z')
    """).run([
        .text(sessionId), .text(groupType),
        checksum.map { DBValue.text($0) } ?? .null,
        hashHex.map { DBValue.text($0) } ?? .null,
        .int(Int64(memberCount)),
        resolution.map { DBValue.text($0) } ?? .null,
    ])
    return Int(db.lastInsertRowid)
}

@discardableResult
func queryInsertDuplicateMember(
    _ db: DBConnection,
    groupId: Int,
    photoId: String,
    sessionId: String,
    isKept: Bool = true,
    fileSize: Int64? = nil,
    fileMtime: String? = nil,
    resolution: String? = nil
) throws -> Int {
    _ = try db.prepare("""
        INSERT INTO duplicate_group_members
          (group_id, photo_id, session_id, is_kept, file_size, file_mtime, resolution)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """).run([
        .int(Int64(groupId)), .text(photoId), .text(sessionId),
        .int(isKept ? 1 : 0),
        fileSize.map { DBValue.int($0) } ?? .null,
        fileMtime.map { DBValue.text($0) } ?? .null,
        resolution.map { DBValue.text($0) } ?? .null,
    ])
    return Int(db.lastInsertRowid)
}
