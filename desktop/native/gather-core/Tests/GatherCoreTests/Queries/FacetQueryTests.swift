// desktop/native/gather-core/Tests/GatherCoreTests/Queries/FacetQueryTests.swift
// P1 / C：facet 计数——排除自身维度（同维多选取并集）、跨维取交集、空/空串不成桶。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("facet 计数")
struct FacetQueryTests {
    private func makeDB() throws -> (DBConnection, String) {
        let db = try makeTestDB()
        let sessionId = "s-1"
        _ = try db.prepare("""
            INSERT INTO sessions (id, name, status, created_at, updated_at)
            VALUES (?, '', 'photos_loaded', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([.text(sessionId)])
        let photos: [(String, String, Int, String)] = [
            ("p1", "A", 200, "XF23"),
            ("p2", "A", 400, "XF56"),
            ("p3", "B", 400, "XF23"),
        ]
        for (id, camera, iso, lens) in photos {
            _ = try db.prepare("""
                INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'ready', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([.text(id), .text(sessionId), .text("/tmp/\(id).CR3"), .text("\(id).CR3")])
            try MetadataCacheRepo(connection: db).upsert(
                photoId: id, sessionId: sessionId,
                data: MetadataCacheInput(
                    dateTaken: "2026-10-25T10:00:00Z",
                    cameraModel: camera,
                    lensModel: lens,
                    iso: Int64(iso)
                )
            )
        }
        return (db, sessionId)
    }

    @Test("排除自身维度：选相机 A 后相机 facet 仍显示 A/B，镜头 facet 只剩 A 的")
    func excludesOwnDimension() throws {
        let (db, sessionId) = try makeDB()
        let query = FacetQuery(connection: db)
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(field: "camera_model", operator: .eq, value: .string("A"))),
        ])

        let cameras = try query.buckets(sessionId: sessionId, criteria: criteria, dimension: .camera)
        let cameraCounts = Dictionary(uniqueKeysWithValues: cameras.map { ($0.value, $0.count) })
        #expect(cameraCounts["A"] == 2)
        #expect(cameraCounts["B"] == 1, "相机维度必须排除自身条件，否则多选取会退化成单选")

        let lenses = try query.buckets(sessionId: sessionId, criteria: criteria, dimension: .lens)
        #expect(Set(lenses.map(\.value)) == ["XF23", "XF56"], "镜头维度受相机条件约束")
        #expect(lenses.first { $0.value == "XF56" }?.count == 1)
    }

    @Test("ISO 与年份维度按字符串桶聚合")
    func isoAndYearBuckets() throws {
        let (db, sessionId) = try makeDB()
        let query = FacetQuery(connection: db)
        let empty = FilterGroup(logic: .and, conditions: [])

        let iso = try query.buckets(sessionId: sessionId, criteria: empty, dimension: .iso)
        #expect(Dictionary(uniqueKeysWithValues: iso.map { ($0.value, $0.count) })["400"] == 2)

        let year = try query.buckets(sessionId: sessionId, criteria: empty, dimension: .year)
        #expect(year.first?.value == "2026")
        #expect(year.first?.count == 3)
    }

    @Test("RAW/JPEG 同一逻辑资产只计一次（与网格 countGlobally 口径一致）")
    func countsLogicalAssetsOnce() throws {
        let (db, sessionId) = try makeDB()
        // p1 与 p4 共享 asset_id：网格只显示一张，facet 也必须是 1。
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES ('p4', ?, '/tmp/p1.jpg', 'p1.jpg', 'ready', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """).run([.text(sessionId)])
        for asset in ["asset-1", "asset-2", "asset-3"] {
            _ = try db.prepare("""
                INSERT INTO assets (id, status, created_at, updated_at)
                VALUES (?, 'active', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
                """).run([.text(asset)])
        }
        _ = try db.prepare("UPDATE photos SET asset_id = 'asset-1' WHERE id IN ('p1','p4')").run([])
        _ = try db.prepare("UPDATE photos SET asset_id = 'asset-2' WHERE id = 'p2'").run([])
        _ = try db.prepare("UPDATE photos SET asset_id = 'asset-3' WHERE id = 'p3'").run([])
        try MetadataCacheRepo(connection: db).upsert(
            photoId: "p4", sessionId: sessionId,
            data: MetadataCacheInput(cameraModel: "A", lensModel: "XF23", iso: 200))

        let query = FacetQuery(connection: db)
        let empty = FilterGroup(logic: .and, conditions: [])
        let cameras = try query.buckets(sessionId: sessionId, criteria: empty, dimension: .camera)
        #expect(cameras.first { $0.value == "A" }?.count == 2, "A 是 asset-1 + asset-2，不是 3 行")
        let total = try PhotoFilterQuery(connection: db).countGlobally(criteria: empty, sessionId: sessionId)
        #expect(total == 3)
    }

    @Test("limit 生效，且结果按计数降序")
    func limitAndOrder() throws {
        let (db, sessionId) = try makeDB()
        let query = FacetQuery(connection: db)
        let empty = FilterGroup(logic: .and, conditions: [])
        let top = try query.buckets(sessionId: sessionId, criteria: empty, dimension: .camera, limit: 1)
        #expect(top.count == 1)
        #expect(top[0].count == 2)
    }

    @Test("输入契约：Protocol 白名单与 FacetDimension 一一对应；未知维/越界 limit 显式失败")
    func inputContract() throws {
        // Protocol 不能依赖 Persistence，白名单是手抄的字符串；这里把它钉在枚举上。
        #expect(PhotoFacetInput.allowedDimensions.sorted()
                == FacetDimension.allCases.map(\.rawValue).sorted())

        let empty = FilterGroup(logic: .and, conditions: [])
        let input = try PhotoFacetInput(
            sessionId: "s-1", criteria: empty,
            dimensions: ["camera", " camera ", "LENS"], limit: 10)
        #expect(input.dimensions == ["camera", "lens"], "去重并归一大小写/空白")

        #expect(throws: GatherError.self) {
            _ = try PhotoFacetInput(sessionId: "s-1", criteria: empty, dimensions: ["nope"])
        }
        #expect(throws: GatherError.self) {
            _ = try PhotoFacetInput(sessionId: "s-1", criteria: empty, limit: 0)
        }
        #expect(throws: GatherError.self) {
            _ = try PhotoFacetInput(sessionId: "s-1", criteria: empty, limit: 201)
        }
    }
}
