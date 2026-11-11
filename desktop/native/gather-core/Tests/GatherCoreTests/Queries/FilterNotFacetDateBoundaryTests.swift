// desktop/native/gather-core/Tests/GatherCoreTests/Queries/FilterNotFacetDateBoundaryTests.swift
// Wave4b（task-45）：NOT 嵌套语义、facet 同维剔除对 NOT 组的存在量化处理、
// 相对日期窗口的真实数据边界（含今天/时区），以及集合差集的「被减数」顺序契约。
//
// 夹具：GatherTestSupport 的 makeQueryTestDB()（真实 SQLite + 当前 schema）；
// 日期一律按**本机时区**生成，与查询里的 date('now','localtime') 同口径。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

// MARK: - 夹具

private func insertFilterPhoto(_ db: DBConnection, id: String, sessionId: String) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status,
          width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'ready', 100, 80,
          '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([
        .text(id), .text(sessionId), .text("/shots/\(id).jpg"),
        .text("\(id).jpg"),
    ])
}

private func insertDateTaken(
    _ db: DBConnection, photoId: String, sessionId: String, dateTaken: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken, cached_at)
        VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z')
    """).run([.text(photoId), .text(sessionId), .text(dateTaken)])
}

private func makeRule(
    _ field: String, _ op: FilterOperator, _ value: JSONValue
) -> FilterRule {
    FilterRule(field: field, operator: op, value: value)
}

/// 用共享 WHERE 子句数照片（join 形状与 PhotoFilterQuery 的 SELECT 一致）。
private func countPhotos(_ db: DBConnection, _ clause: FilterWhereClause) throws -> Int {
    let whereSQL = clause.sql.isEmpty ? "1=1" : clause.sql
    let sql = """
        SELECT COUNT(*) FROM photos p
        LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
        WHERE \(whereSQL)
        """
    let row = try db.prepare(sql).query(clause.params).first
    return Int(row?[0].intValue ?? 0)
}

private func localDayString(daysFromToday: Int) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let date = calendar.date(byAdding: .day, value: daysFromToday, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func localMonthString(daysFromToday: Int) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let date = calendar.date(byAdding: .day, value: daysFromToday, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM"
    return formatter.string(from: date)
}

// MARK: - NOT 嵌套

@Suite("NOT 嵌套语义（task-45）")
struct FilterNotNestedWave4Tests {

    private func makeNotGroup(_ conditions: [FilterCondition]) -> FilterGroup {
        FilterGroup(logic: .not, conditions: conditions)
    }

    @Test("双重否定 = 肯定；NOT(NOT(集合)) 只命中集合成员")
    func doubleNegation() throws {
        let db = try makeQueryTestDB()
        try insertSession(db, "s1")
        try insertFilterPhoto(db, id: "p1", sessionId: "s1")
        try insertFilterPhoto(db, id: "p2", sessionId: "s1")
        _ = try db.prepare("""
            INSERT INTO collections (id, session_id, name, sort_order, created_at, updated_at)
            VALUES ('c1', 's1', 'A', 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([])
        _ = try db.prepare("""
            INSERT INTO collection_items (collection_id, photo_id, position, added_at)
            VALUES ('c1', 'p1', 0, '2026-01-01T00:00:00.000Z')
            """).run([])

        let membership = makeRule(FilterFields.collection, .eq, .string("c1"))
        let doubleNot = FilterGroup(logic: .and, conditions: [
            .group(makeNotGroup([.group(makeNotGroup([.rule(membership)]))])),
        ])
        let query = PhotoFilterQuery(connection: db)
        let clause = try query.whereClause(doubleNot)
        #expect(try countPhotos(db, clause) == 1, "NOT(NOT(inCollection)) = inCollection")
    }

    @Test("NOT 嵌套 AND/OR 子组：SQL 形状为 NOT(子表达式) 且参数顺序正确")
    func nestedBooleanGroups() throws {
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let camera = makeRule("camera_model", .eq, .string("X"))
        let label = makeRule("label", .eq, .string("red"))
        let nestedOr = FilterGroup(logic: .or, conditions: [.rule(camera), .rule(label)])
        let criteria = FilterGroup(logic: .and, conditions: [
            .group(makeNotGroup([.group(nestedOr)])),
        ])
        let clause = try query.whereClause(criteria)
        #expect(clause.sql.contains("NOT ("), "NOT 组必须整体取反而不是把子规则逐个否定")
        #expect(clause.params.count == 2, "嵌套组的参数按出现顺序绑定")
    }
}

// MARK: - facet 同维剔除对 NOT 的处理

@Suite("facet 同维剔除 × NOT（task-45）")
struct FacetPruningNotWave4Tests {

    @Test("AND 上下文：NOT 组里的同维规则被剔除，组空则整组消失（= TRUE）")
    func prunesSameFieldInsideNot() throws {
        let camera = makeRule("camera_model", .eq, .string("X"))
        let label = makeRule("label", .eq, .string("red"))
        let criteria = FilterGroup(logic: .and, conditions: [
            .group(FilterGroup(logic: .not, conditions: [.rule(camera)])),
            .rule(label),
        ])
        let pruned = criteria.removing(field: "camera_model")
        #expect(!pruned.references(field: "camera_model"))
        #expect(pruned.conditions.count == 1, "只留 label 规则；空的 NOT 组必须整组消失")
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        let clause = try query.whereClause(pruned)
        #expect(clause.sql.contains("label"))
        #expect(!clause.sql.contains("NOT"), "剔除后不应留下空 NOT（空 NOT=1=0）")
    }

    @Test("NOT(同维, 其它)：剔同维后保留 NOT(其它)（存在量化 = NOT(其它)）")
    func keepsOtherFieldsInsideNot() throws {
        let camera = makeRule("camera_model", .eq, .string("X"))
        let label = makeRule("label", .eq, .string("red"))
        let criteria = FilterGroup(logic: .and, conditions: [
            .group(FilterGroup(logic: .not, conditions: [.rule(camera), .rule(label)])),
        ])
        let pruned = criteria.removing(field: "camera_model")
        #expect(!pruned.references(field: "camera_model"))
        #expect(pruned.references(field: "label"))
        guard case .group(let notGroup)? = pruned.conditions.first else {
            Issue.record("剔除后应保留 NOT 组")
            return
        }
        #expect(notGroup.logic == .not)
        #expect(notGroup.conditions.count == 1)
    }

    @Test("根组自身是 NOT 且被剔空：变成无约束（不是空 NOT=1=0）")
    func emptyRootNotBecomesUnconstrained() throws {
        let criteria = FilterGroup(logic: .not, conditions: [
            .rule(makeRule("camera_model", .eq, .string("X"))),
        ])
        let pruned = criteria.removing(field: "camera_model")
        #expect(pruned.logic == .and)
        #expect(pruned.conditions.isEmpty)
        let query = PhotoFilterQuery(connection: try makeQueryTestDB())
        #expect(try query.whereClause(pruned).sql.isEmpty)
    }

    @Test("OR 组保持旧行为：不拆同维叶子（避免改变其它规则含义）")
    func doesNotPruneInsideOr() throws {
        let camera = makeRule("camera_model", .eq, .string("X"))
        let label = makeRule("label", .eq, .string("red"))
        let criteria = FilterGroup(logic: .and, conditions: [
            .group(FilterGroup(logic: .or, conditions: [.rule(camera), .rule(label)])),
            .rule(makeRule("iso", .eq, .int(400))),
        ])
        let pruned = criteria.removing(field: "camera_model")
        #expect(pruned.references(field: "camera_model"), "OR 下的同维规则不剔除（保守）")
    }
}

// MARK: - 相对日期边界

@Suite("相对日期窗口边界（task-45）")
struct RelativeDateBoundaryWave4Tests {

    private func makeWindowDB() throws -> (DBConnection, [String: String]) {
        let db = try makeQueryTestDB()
        try insertSession(db, "s1")
        let dates: [String: String] = [
            "today": localDayString(daysFromToday: 0),
            "six": localDayString(daysFromToday: -6),
            "seven": localDayString(daysFromToday: -7),
            "twentyNine": localDayString(daysFromToday: -29),
            "thirty": localDayString(daysFromToday: -30),
        ]
        for (id, date) in dates {
            try insertFilterPhoto(db, id: id, sessionId: "s1")
            try insertDateTaken(db, photoId: id, sessionId: "s1", dateTaken: date)
        }
        return (db, dates)
    }

    @Test("last7 含今天与 6 天前、不含 7 天前；last30 含 29 天前、不含 30 天前")
    func lastDaysBoundaries() throws {
        let (db, _) = try makeWindowDB()
        let query = PhotoFilterQuery(connection: db)
        func count(_ token: RelativeDateRange) throws -> Int {
            let clause = try query.whereClause(FilterGroup(logic: .and, conditions: [
                .rule(makeRule(FilterFields.relativeDate, .eq, .string(token.rawValue))),
            ]))
            return try countPhotos(db, clause)
        }
        #expect(try count(.last7) == 2, "今天 + 6 天前（含今天共 7 天）")
        #expect(try count(.last30) == 4, "今天/-6/-7/-29（跨 30 天），不含 -30")
    }

    @Test("本月按本机时区求值，上月日期不计入")
    func thisMonthBoundary() throws {
        let (db, dates) = try makeWindowDB()
        let query = PhotoFilterQuery(connection: db)
        let clause = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.relativeDate, .eq, .string(RelativeDateRange.thisMonth.rawValue))),
        ]))
        let actual = try countPhotos(db, clause)
        let currentMonth = localMonthString(daysFromToday: 0)
        let expected = dates.values.filter { $0.prefix(7) == currentMonth }.count
        #expect(actual == expected, "本月窗口 = 与今天同 yyyy-MM 的照片数")
    }

    @Test("多 token = OR；NOT(相对日期) = 窗口外")
    func multipleTokensAndNegation() throws {
        let (db, _) = try makeWindowDB()
        let query = PhotoFilterQuery(connection: db)
        let union = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .rule(makeRule(FilterFields.relativeDate, .in, .array([
                .string(RelativeDateRange.last7.rawValue),
                .string(RelativeDateRange.last30.rawValue),
            ]))),
        ]))
        #expect(try countPhotos(db, union) == 4, "last7 ∪ last30 = last30（并集去重口径）")
        let negated = try query.whereClause(FilterGroup(logic: .and, conditions: [
            .group(FilterGroup(logic: .not, conditions: [
                .rule(makeRule(FilterFields.relativeDate, .eq, .string(RelativeDateRange.last7.rawValue))),
            ])),
        ]))
        #expect(try countPhotos(db, negated) == 3, "5 张里窗口外 = -7/-29/-30")
    }
}

// MARK: - 集合差集顺序（被减数）

@Suite("集合差集顺序契约（task-45）")
struct CollectionDifferenceOrderWave4Tests {

    private func makeCurationService(_ db: DBConnection) -> CurationService {
        CurationService(
            collections: CollectionRepo(connection: db),
            stacks: StackRepo(connection: db),
            duplicates: GlobalDuplicateQuery(connection: db),
            transactions: db
        )
    }

    @Test("difference：第一个 id = 被减数；交换顺序结果不同")
    func differenceHonorsMinuendOrder() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        for photoId in ["p1", "p2", "p3"] {
            try insertPhoto(db, id: photoId, sessionId: "s1")
        }
        let repo = CollectionRepo(connection: db)
        let a = try repo.create(sessionId: "s1", name: "A", sortOrder: nil)
        let b = try repo.create(sessionId: "s1", name: "B", sortOrder: nil)
        _ = try repo.appendItems(collectionId: a.id, photoIds: ["p1", "p2"])
        _ = try repo.appendItems(collectionId: b.id, photoIds: ["p2", "p3"])
        let service = makeCurationService(db)

        let bMinusA = try service.combineCollections(CollectionCombineInput(
            sessionId: "s1", name: "B 减 A", operation: .difference,
            collectionIds: [b.id, a.id]))
        let bMinusAMembers = try service.collectionItems(collectionId: bMinusA.id)
        #expect(Set(bMinusAMembers.map(\.photoId)) == ["p3"])

        let aMinusB = try service.combineCollections(CollectionCombineInput(
            sessionId: "s1", name: "A 减 B", operation: .difference,
            collectionIds: [a.id, b.id]))
        let aMinusBMembers = try service.collectionItems(collectionId: aMinusB.id)
        #expect(Set(aMinusBMembers.map(\.photoId)) == ["p1"], "第一个 id 是被减数")
    }
}
