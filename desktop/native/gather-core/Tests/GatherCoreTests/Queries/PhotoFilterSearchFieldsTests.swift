// desktop/native/gather-core/Tests/GatherCoreTests/Queries/PhotoFilterSearchFieldsTests.swift
// Wave2 task-13：元数据检索字段覆盖（PhotoFilterQuery.jsonFields 扩到描述性字段全集）。
//
// 两层用例：
// 1. 契约完备性：jsonFields 的 JSON key 集合 == DescriptiveField 全集（contactInfo
//    是结构，不参与列式检索）；jsonArrayFields == 值为 list 形状的字段；
// 2. 真实查询：新字段（event / creator_job_title / subject_code 数组）能在
//    iptc_json 上按既有的 eq/contains/containsAny 语义命中。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("元数据检索字段覆盖")
struct PhotoFilterSearchFieldsTests {

    private func makeDB() throws -> DBConnection {
        let db = try makeTestDB()
        try insertSession(db, "s-1")
        try insertPhoto(db, id: "p1", sessionId: "s-1", filepath: "/tmp/search/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s-1", filepath: "/tmp/search/p2.jpg")
        return db
    }

    private func insertCache(_ db: DBConnection, photoId: String, descriptive: DescriptiveMetadata) throws {
        let data = try JSONEncoder().encode(descriptive)
        let json = String(decoding: data, as: UTF8.self)
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, keywords, iptc_json, cached_at)
            VALUES (?, 's-1', '[]', ?, '2026-01-01T00:00:00Z')
            """).run([.text(photoId), .text(json)])
    }

    private func rule(_ field: String, _ op: FilterOperator, _ value: JSONValue) -> FilterGroup {
        FilterGroup(logic: .and, conditions: [.rule(FilterRule(field: field, operator: op, value: value))])
    }

    @Test func jsonFieldsCoverAllDescriptiveFieldsExceptContact() {
        let covered = Set(PhotoFilterQuery.jsonFields.values)
        let expected = Set(DescriptiveField.allCases
            .filter { $0 != .contactInfo }
            .map(\.rawValue))
        #expect(covered == expected)
        #expect(PhotoFilterQuery.jsonFields.count == DescriptiveField.allCases.count - 1)
    }

    @Test func jsonArrayFieldsMatchListShapedDescriptors() {
        let listValues = Set(XMPFieldDescriptor.all.filter(\.isList).map { $0.field.rawValue })
        let expectedIds = Set(PhotoFilterQuery.jsonFields
            .filter { listValues.contains($0.value) }
            .map(\.key))
        #expect(PhotoFilterQuery.jsonArrayFields == expectedIds)
        #expect(PhotoFilterQuery.jsonArrayFields.contains("subject_code"))
        #expect(PhotoFilterQuery.jsonArrayFields.contains("scene"))
    }

    @Test func queriesNewScalarField() throws {
        let db = try makeDB()
        var descriptive = DescriptiveMetadata()
        descriptive.event = "Autumn Festival"
        descriptive.sublocation = "Hall A"
        descriptive.creatorJobTitle = "Staff Photographer"
        try insertCache(db, photoId: "p1", descriptive: descriptive)

        let query = PhotoFilterQuery(connection: db)
        let byEvent = try query.filterPhotos(
            sessionId: "s-1", criteria: rule("event", .contains, .string("Festival")))
        #expect(byEvent.map(\.id) == ["p1"])

        let byJobTitle = try query.filterPhotos(
            sessionId: "s-1", criteria: rule("creator_job_title", .eq, .string("Staff Photographer")))
        #expect(byJobTitle.map(\.id) == ["p1"])

        let bySublocation = try query.filterPhotos(
            sessionId: "s-1", criteria: rule("sublocation", .startsWith, .string("Hall")))
        #expect(bySublocation.map(\.id) == ["p1"])
    }

    @Test func queriesNewArrayField() throws {
        let db = try makeDB()
        var descriptive = DescriptiveMetadata()
        descriptive.subjectCode = ["Sports", "Football"]
        descriptive.scene = ["Action"]
        try insertCache(db, photoId: "p1", descriptive: descriptive)

        let query = PhotoFilterQuery(connection: db)
        let byAny = try query.filterPhotos(
            sessionId: "s-1",
            criteria: rule("subject_code", .containsAny, .array([.string("Sports"), .string("News")])))
        #expect(byAny.map(\.id) == ["p1"])

        let byAll = try query.filterPhotos(
            sessionId: "s-1",
            criteria: rule("subject_code", .containsAll,
                           .array([.string("Sports"), .string("Football")])))
        #expect(byAll.map(\.id) == ["p1"])

        let notInterested = try query.filterPhotos(
            sessionId: "s-1",
            criteria: rule("subject_code", .containsAny, .array([.string("Fashion")])))
        #expect(notInterested.isEmpty)

        let byScene = try query.filterPhotos(
            sessionId: "s-1", criteria: rule("scene", .eq, .string("Action")))
        #expect(byScene.map(\.id) == ["p1"])
    }
}
