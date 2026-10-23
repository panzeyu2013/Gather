// desktop/native/gather-core/Tests/GatherCoreTests/Queries/PhotoFilterQueryTests.swift
// PhotoFilterQuery 的 SQL 边界（真实 SQLite）。
// 与 Services/FilterEngineTests 的分工：那边通过 FilterEngine 断言端到端行为；
// 这里只钉 Query 层新增/未被覆盖的边界：21 个字段的别名矩阵、递归组的参数
// 顺序、空组/空数组/单界 between、session 参数与 limit/offset 的拼接顺序、
// 全局资产去重计数、limit 钳制、directory 的 LIKE 转义真实执行、suggest 上限。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

private func emptyGroup() -> FilterGroup {
    FilterGroup(logic: .and, conditions: [])
}

private func group(_ rule: FilterRule) -> FilterGroup {
    FilterGroup(logic: .and, conditions: [.rule(rule)])
}

private func rule(_ field: String, _ op: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: op, value: value)
}

@Suite("PhotoFilterQuery SQL 边界")
struct PhotoFilterQueryBoundaryTests {
    @Test("简单/元数据字段解析到 p/pmc 别名，未知字段报 FILTER_FIELD_UNKNOWN")
    func fieldResolutionMatrix() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let simple: [(String, String)] = [
            ("filename", "p.filename"), ("filepath", "p.filepath"), ("checksum", "p.checksum"),
            ("status", "p.status"), ("created_at", "p.created_at"),
        ]
        let metadata: [(String, String)] = [
            ("date_taken", "pmc.date_taken"), ("camera_make", "pmc.camera_make"),
            ("camera_model", "pmc.camera_model"), ("lens_model", "pmc.lens_model"),
            ("focal_length", "pmc.focal_length"), ("f_number", "pmc.f_number"),
            ("exposure_time", "pmc.exposure_time"), ("iso", "pmc.iso"),
            ("rating", "pmc.rating"), ("gps_latitude", "pmc.gps_latitude"),
            ("gps_longitude", "pmc.gps_longitude"), ("width", "pmc.width"),
            ("height", "pmc.height"), ("file_size", "pmc.file_size"),
            ("file_mtime", "pmc.file_mtime"), ("label", "pmc.label"),
        ]
        #expect(PhotoFilterQuery.simpleFields.count == simple.count)
        #expect(PhotoFilterQuery.metadataFields.count == metadata.count)
        #expect(PhotoFilterQuery.simpleFields.union(PhotoFilterQuery.metadataFields).count == 21)
        for (field, column) in simple + metadata {
            let clause = try query.whereClause(group(rule(field, .eq, .string("v"))))
            #expect(clause.sql == "\(column) = ?", "字段 \(field) 必须解析到 \(column)")
            #expect(clause.params == [.text("v")])
        }
        #expect(throws: PhotoFilterQueryError.fieldUnknown("notes")) {
            _ = try query.whereClause(group(rule("notes", .eq, .string("x"))))
        }
    }

    @Test("递归组的 SQL 括号与参数保持遍历顺序")
    func nestedGroupParameterOrder() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let criteria = FilterGroup(logic: .or, conditions: [
            .rule(rule("filename", .eq, .string("a.jpg"))),
            .group(FilterGroup(logic: .and, conditions: [
                .rule(rule("rating", .gte, .number(4))),
                .rule(rule("status", .in, .array([.string("ready"), .string("missing")]))),
                .group(emptyGroup()),
            ])),
            .rule(rule("iso", .between, .array([.number(100), .number(400)]))),
        ])
        let clause = try query.whereClause(criteria)
        #expect(clause.sql == "p.filename = ? OR (pmc.rating >= ? AND p.status IN (?, ?)) OR pmc.iso BETWEEN ? AND ?")
        #expect(clause.params == [
            .text("a.jpg"), .real(4), .text("ready"), .text("missing"), .real(100), .real(400),
        ])
    }

    @Test("空组/空 IN/空 contains_any/单值 between 的退化为安全常量")
    func degenerateConditions() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let empty = try query.whereClause(emptyGroup())
        #expect(empty == FilterWhereClause(sql: "", params: []))
        let onlyEmpty = try query.whereClause(FilterGroup(logic: .or, conditions: [.group(emptyGroup())]))
        #expect(onlyEmpty == FilterWhereClause(sql: "", params: []))

        let emptyIn = try query.whereClause(group(rule("status", .in, .array([]))))
        #expect(emptyIn.sql == "1=0")
        #expect(emptyIn.params.isEmpty)

        let emptyAny = try query.whereClause(group(rule("keywords", .containsAny, .array([]))))
        #expect(emptyAny.sql == "1=0")
        #expect(emptyAny.params.isEmpty)

        let emptyAll = try query.whereClause(group(rule("status", .containsAll, .array([]))))
        #expect(emptyAll.sql == "1=0")
        #expect(emptyAll.params.isEmpty)

        // 标量 between：不足二元组时上下界都绑同一个值。
        let oneBound = try query.whereClause(group(rule("rating", .between, .number(3))))
        #expect(oneBound.sql == "pmc.rating BETWEEN ? AND ?")
        #expect(oneBound.params == [.real(3), .real(3)])
    }

    @Test("filterPhotos 先绑 session 再绑 where 参数，limit/offset 透传且排序回退 filename")
    func filterPhotosParameterOrderAndPagination() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1", name: "One")
        try queryInsertSession(db, id: "s2", name: "Two")
        try queryInsertAsset(db, id: "asset-shared")
        try queryInsertPhoto(db, id: "p1", sessionId: "s1", filepath: "/s1/a.jpg", assetId: "asset-shared")
        try queryInsertPhoto(db, id: "p2", sessionId: "s1", filepath: "/s1/b.jpg")
        try queryInsertPhoto(db, id: "p3", sessionId: "s1", filepath: "/s1/c.jpg")
        try queryInsertPhoto(db, id: "p4", sessionId: "s2", filepath: "/s2/d.jpg", assetId: "asset-shared")
        try queryInsertCache(db, photoId: "p1", sessionId: "s1", rating: 5)
        try queryInsertCache(db, photoId: "p2", sessionId: "s1", rating: 4)
        try queryInsertCache(db, photoId: "p3", sessionId: "s1", rating: 3)
        try queryInsertCache(db, photoId: "p4", sessionId: "s2", rating: 5)

        let query = PhotoFilterQuery(connection: db)
        let high = group(rule("rating", .gte, .number(4)))

        // 元数据排序 + 第二页：sessionId 插在 clause 参数之前，offset/limit 依序追加。
        let second = try query.filterPhotos(
            sessionId: "s1", criteria: high, sortBy: "rating", sortOrder: "desc",
            limit: 1, offset: 1
        )
        #expect(second.map(\.id) == ["p2"])

        // 未知 sortBy 回退 p.filename。
        let fallback = try query.filterPhotos(
            sessionId: "s1", criteria: high, sortBy: "not_a_field", sortOrder: "asc"
        )
        #expect(fallback.map(\.id) == ["p1", "p2"])

        // __global__ 去掉 session 参数，跨会话返回（每物理行一条）。
        let global = try query.filterPhotos(
            sessionId: "__global__", criteria: high, sortBy: "filename", sortOrder: "desc"
        )
        #expect(global.map(\.id) == ["p4", "p2", "p1"])

        // limit 0 透传（引擎层不钳制）。
        let none = try query.filterPhotos(sessionId: "s1", criteria: high, limit: 0)
        #expect(none.isEmpty)

        // 会话内按照片去重；__global__ 按资产去重。
        #expect(try query.countPhotos(sessionId: "s1", criteria: high) == 2)
        #expect(try query.countPhotos(sessionId: "__global__", criteria: high) == 2)
    }

    @Test("filterGlobally 代表行、limit 钳制 1...500 与 offset 下限 0")
    func filterGloballyLimitClamp() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s", name: "Global")
        for i in 1...501 {
            try queryInsertAsset(db, id: "ga\(i)")
            try queryInsertPhoto(db, id: "gp\(i)", sessionId: "s",
                                 filepath: "/global/\(i).jpg", assetId: "ga\(i)")
        }
        let query = PhotoFilterQuery(connection: db)
        let criteria = emptyGroup()

        let clamped = try query.filterGlobally(criteria: criteria, limit: 999)
        #expect(clamped.count == 500)
        #expect(clamped.first?.photoId == "gp1")
        #expect(clamped.last?.photoId == "gp500")

        let zero = try query.filterGlobally(criteria: criteria, limit: 0)
        #expect(zero.map(\.photoId) == ["gp1"], "limit 0 必须钳到 1")

        let last = try query.filterGlobally(criteria: criteria, limit: 1, offset: 500)
        #expect(last.map(\.photoId) == ["gp501"])

        let negativeOffset = try query.filterGlobally(criteria: criteria, limit: 1, offset: -5)
        #expect(negativeOffset.map(\.photoId) == ["gp1"], "负 offset 必须钳到 0")

        let pastEnd = try query.filterGlobally(criteria: criteria, limit: 1, offset: 999)
        #expect(pastEnd.isEmpty)

        #expect(try query.countGlobally(criteria: criteria) == 501)
    }

    @Test("directory 的 LIKE 转义在 SQL 中真实生效（_ 与 % 不作通配符）")
    func directoryEscapesWildcardsInSQL() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try queryInsertPhoto(db, id: "p1", sessionId: "s", filepath: "/shoot/a_b/one.jpg")
        try queryInsertPhoto(db, id: "p2", sessionId: "s", filepath: "/shoot/axb/two.jpg")
        try queryInsertPhoto(db, id: "p3", sessionId: "s", filepath: "/shoot/a%b/three.jpg")
        let query = PhotoFilterQuery(connection: db)

        let underscore = try query.filterPhotos(
            sessionId: "s", criteria: group(rule("directory", .eq, .string("/shoot/a_b")))
        )
        #expect(underscore.map(\.id) == ["p1"])

        let percent = try query.filterPhotos(
            sessionId: "s", criteria: group(rule("directory", .startsWith, .string("/shoot/a%")))
        )
        #expect(percent.map(\.id) == ["p3"])

        #expect(throws: PhotoFilterQueryError.unsupportedOperatorForField(field: "directory", op: "contains")) {
            _ = try query.whereClause(group(rule("directory", .contains, .string("/shoot"))))
        }
    }

    @Test("suggest 先 trim 再卡 2 字符下限，DISTINCT 结果最多 5 条")
    func suggestTrimAndLimit() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        for i in 1...6 {
            try queryInsertPhoto(db, id: "p\(i)", sessionId: "s", filepath: "/s/\(i).jpg")
            try queryInsertCache(db, photoId: "p\(i)", sessionId: "s", cameraMake: "Canon \(i)")
        }
        let query = PhotoFilterQuery(connection: db)

        #expect(try query.suggest("s", keyword: "  c  ").isEmpty)
        #expect(try query.suggest("s", keyword: "  ").isEmpty)

        let suggestions = try query.suggest("s", keyword: " canon ")
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.field == "camera_make")
        #expect(suggestions.first?.values.count == 5, "SQL LIMIT 5")
        #expect(suggestions.first?.values.allSatisfy { $0.hasPrefix("Canon ") } == true)
    }
}
