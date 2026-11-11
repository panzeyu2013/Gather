// desktop/native/gather-core/Tests/GatherCoreTests/Queries/FilterWave2QueryTests.swift
// Wave2（task-15）：NOT 组、容器成员（手动集合 / 堆栈）、相对日期窗口的 SQL 边界，
// 以及集合运算（并/交/差）的仓储语义。
//
// 夹具：QueryTestSupport 的 makeQueryTestDB()（真实 SQLite + 当前 schema），
// 与 PhotoFilterQueryTests 同口径；这里只钉 Wave2 新增的分支，不重复既有字段矩阵。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

// MARK: - 夹具

private func makeRule(_ field: String, _ op: FilterOperator, _ value: JSONValue) -> FilterRule {
    FilterRule(field: field, operator: op, value: value)
}

private func insertCollectionPhoto(
    _ db: DBConnection, id: String, sessionId: String, checksum: String = ""
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'ready', 100, 80,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(id), .text(sessionId), .text("/shots/\(id).jpg"),
        .text("\(id).jpg"), .text(checksum),
    ])
}

private func insertCollection(
    _ db: DBConnection, id: String, sessionId: String, name: String
) throws {
    _ = try db.prepare("""
        INSERT INTO collections (id, session_id, name, sort_order, created_at, updated_at)
        VALUES (?, ?, ?, 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text(name)])
}

private func insertCollectionItem(
    _ db: DBConnection, collectionId: String, photoId: String, position: Int
) throws {
    _ = try db.prepare("""
        INSERT INTO collection_items (collection_id, photo_id, position, added_at)
        VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z')
    """).run([.text(collectionId), .text(photoId), .int(Int64(position))])
}

private func insertStack(
    _ db: DBConnection, id: String, sessionId: String, name: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photo_stacks (id, session_id, name, created_at, updated_at)
        VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text(name)])
}

private func insertStackMember(
    _ db: DBConnection, stackId: String, photoId: String, position: Int
) throws {
    _ = try db.prepare("""
        INSERT INTO photo_stack_members (stack_id, photo_id, position)
        VALUES (?, ?, ?)
    """).run([.text(stackId), .text(photoId), .int(Int64(position))])
}

// MARK: - SQL 边界

@Suite("Wave2 · NOT 组与容器成员 SQL")
struct FilterWave2QueryTests {

    @Test("NOT 组：子条件按 OR 组合后整体取反（参数顺序不变）")
    func notGroupBuildsNegatedOr() throws {
        let db = try makeQueryTestDB()
        let query = PhotoFilterQuery(connection: db)
        let group = FilterGroup(logic: .not, conditions: [
            .rule(makeRule(FilterFields.collection, .eq, .string("c1"))),
            .rule(makeRule(FilterFields.collection, .eq, .string("c2"))),
        ])
        let clause = try query.whereClause(group)
        #expect(clause.sql.hasPrefix("NOT ("), "NOT 组必须以 NOT ( 包住整体")
        #expect(clause.sql.contains(" OR "), "组内子条件按 OR 组合")
        #expect(clause.params == [.text("c1"), .text("c2")])
    }

    @Test("空 NOT 组 = 无约束（编辑器删光子条件不应变成空集）")
    func emptyNotGroupIsUnconstrained() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let clause = try query.whereClause(FilterGroup(logic: .not, conditions: []))
        #expect(clause.sql.isEmpty)
        #expect(clause.params.isEmpty)
    }

    @Test("集合成员：eq / neq / in / contains_all / exists 的 SQL 形状")
    func collectionMembershipMatrix() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())

        let eq = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.collection, .eq, .string("c1"))),
        ]))
        #expect(eq.sql.contains("collection_items"))
        #expect(eq.sql.contains("m.collection_id = ?"))
        #expect(eq.params == [.text("c1")])

        let neq = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.collection, .neq, .string("c1"))),
        ]))
        #expect(neq.sql.hasPrefix("NOT ("), "neq = 不属于（差集的一半）")

        let anyOf = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.collection, .in, .array([.string("c1"), .string("c2")]))),
        ]))
        #expect(anyOf.sql.contains(" IN (?, ?)"))
        #expect(anyOf.params == [.text("c1"), .text("c2")])

        let allOf = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(
                FilterFields.collection, .containsAll,
                .array([.string("c1"), .string("c2")]))),
        ]))
        #expect(allOf.sql.contains("COUNT(DISTINCT m.collection_id)"))
        #expect(allOf.params == [.text("c1"), .text("c2"), .int(2)], "参数 = ids + 期望计数")

        let exists = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.collection, .exists, .bool(true))),
        ]))
        #expect(exists.sql.contains("EXISTS (SELECT 1 FROM collection_items m"))
        #expect(exists.params.isEmpty)
    }

    @Test("堆栈成员：走 photo_stack_members，不误用集合表")
    func stackMembershipUsesStackTable() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let clause = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.stack, .eq, .string("stk1"))),
        ]))
        #expect(clause.sql.contains("photo_stack_members"))
        #expect(!clause.sql.contains("collection_items"))
        #expect(clause.params == [.text("stk1")])
    }

    @Test("相对日期：last7 / last30 / 本月按 locatime 求值，未知 token 显式报错")
    func relativeDateWindows() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())

        func sql(_ token: String) throws -> String {
            try query.whereClause(FilterGroup(logic: .and, conditions: [
                .rule(makeRule(FilterFields.relativeDate, .eq, .string(token))),
            ])).sql
        }
        #expect(try sql(RelativeDateRange.last7.rawValue).contains("-6 days"))
        #expect(try sql(RelativeDateRange.last30.rawValue).contains("-29 days"))
        let month = try sql(RelativeDateRange.thisMonth.rawValue)
        #expect(month.contains("%Y-%m"))
        #expect(month.contains("localtime"))

        #expect(throws: PhotoFilterQueryError.self) {
            _ = try sql("last_ninety")
        }
    }

    @Test("布尔组合：AND(c1) + NOT(c2) 生成互斥的差集条件")
    func differenceComposition() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let group = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule.inCollection("c1")),
            .group(FilterGroup(logic: .not, conditions: [
                .rule(FilterRule.inCollection("c2")),
            ])),
        ])
        let clause = try query.whereClause(group)
        #expect(clause.sql.contains(" AND "))
        #expect(clause.sql.contains("NOT ("))
        #expect(clause.params == [.text("c1"), .text("c2")])
    }
}

// MARK: - 真实库语义

@Suite("Wave2 · 容器成员与集合运算（真实库）")
struct FilterWave2DatabaseTests {

    private func seededDB() throws -> DBConnection {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s1", name: "S1")
        try insertCollectionPhoto(db, id: "p1", sessionId: "s1")
        try insertCollectionPhoto(db, id: "p2", sessionId: "s1")
        try insertCollectionPhoto(db, id: "p3", sessionId: "s1")
        try insertCollection(db, id: "c1", sessionId: "s1", name: "C1")
        try insertCollection(db, id: "c2", sessionId: "s1", name: "C2")
        try insertCollectionItem(db, collectionId: "c1", photoId: "p1", position: 1024)
        try insertCollectionItem(db, collectionId: "c1", photoId: "p2", position: 2048)
        try insertCollectionItem(db, collectionId: "c2", photoId: "p2", position: 1024)
        try insertCollectionItem(db, collectionId: "c2", photoId: "p3", position: 2048)
        return db
    }

    @Test("集合成员筛选：属于 / 任一 / 同时属于全部")
    func membershipFiltering() throws {
        let db = try seededDB()
        let query = PhotoFilterQuery(connection: db)

        func ids(_ rules: [FilterRule]) throws -> Set<String> {
            let rows = try query.filterPhotos(
                sessionId: "s1",
                criteria: FilterGroup(logic: .and, conditions: rules.map { .rule($0) }))
            return Set(rows.map(\.id))
        }
        #expect(try ids([FilterRule.inCollection("c1")]) == ["p1", "p2"])
        #expect(try ids([FilterRule.collectionMembership(anyOf: ["c1", "c2"])])
                == ["p1", "p2", "p3"])
        #expect(try ids([FilterRule.collectionMembership(allOf: ["c1", "c2"])]) == ["p2"])
        #expect(try ids([FilterRule.notInCollection("c2")]) == ["p1"])
    }

    @Test("堆栈成员筛选")
    func stackMembershipFiltering() throws {
        let db = try seededDB()
        try insertStack(db, id: "stk1", sessionId: "s1", name: "S")
        try insertStackMember(db, stackId: "stk1", photoId: "p3", position: 1024)
        let query = PhotoFilterQuery(connection: db)
        let rows = try query.filterPhotos(
            sessionId: "s1",
            criteria: FilterGroup(logic: .and, conditions: [
                .rule(FilterRule.inStack("stk1")),
            ]))
        #expect(Set(rows.map(\.id)) == ["p3"])
    }

    @Test("集合运算仓储：并集按拼接序、交集/差集以第一个集合为准")
    func setOperationPhotoIds() throws {
        let db = try seededDB()
        let repo = CollectionRepo(connection: db)
        #expect(try repo.setOperationPhotoIds(
            sessionId: "s1", collectionIds: ["c1", "c2"], operation: .union
        ) == ["p1", "p2", "p3"])
        #expect(try repo.setOperationPhotoIds(
            sessionId: "s1", collectionIds: ["c1", "c2"], operation: .intersection
        ) == ["p2"])
        #expect(try repo.setOperationPhotoIds(
            sessionId: "s1", collectionIds: ["c1", "c2"], operation: .difference
        ) == ["p1"])
    }
}
