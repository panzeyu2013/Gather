// desktop/native/gather-core/Tests/GatherCoreTests/Services/KeywordLibraryTests.swift
// Wave2 task-13：关键词库（受控词表）的树/补全/改名/合并/删除/同义词用例。
//
// 覆盖两层：
// 1. Protocol 层纯函数：树子级、补全合并（同义词参与）、输入校验；
// 2. Application + Persistence：KeywordLibraryService 对真实 KeywordRepo 的
//    事务化改名（子孙 + photo_keywords + keyword_synonyms 一致）、合并、删除守卫
//    与错误码映射（GatherError.METADATA_KEYWORDS_INVALID）。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("关键词库：树/补全/改名/合并/同义词")
struct KeywordLibraryTests {

    private struct Fixture {
        let db: DBConnection
        let repo: KeywordRepo
        let service: KeywordLibraryService
    }

    private func makeFixture() throws -> Fixture {
        let db = try makeTestDB()
        try insertSession(db, "s-1")
        try insertPhoto(db, id: "p1", sessionId: "s-1", filepath: "/tmp/kw/p1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s-1", filepath: "/tmp/kw/p2.jpg")
        let repo = KeywordRepo(connection: db)
        return Fixture(db: db, repo: repo, service: KeywordLibraryService(store: repo))
    }

    /// 测试内路径构造：非法路径直接让用例失败（避免 #require 嵌在数组字面量里
    /// 触发类型检查器复杂度）。
    private func path(_ raw: String) throws -> KeywordPath {
        try #require(KeywordPath(raw))
    }

    @Test func treeChildrenAndUsage() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [
            try path("Travel"),
            try path("Travel|Paris"),
            try path("Food"),
        ])
        _ = try fixture.repo.setSynonyms(
            path: try path("Travel"), synonyms: ["旅", "trip"])
        _ = try fixture.repo.replacePhotoKeywords(
            photoId: "p1",
            paths: [try path("Travel|Paris")],
            source: "manual")

        let nodes = try fixture.service.library(try KeywordLibraryQuery())
        #expect(nodes.count == 3)
        let travel = try #require(nodes.first { $0.path == "Travel" })
        #expect(travel.synonyms == ["trip", "旅"].sorted())
        #expect(travel.usageCount == 0)
        let paris = try #require(nodes.first { $0.path == "Travel|Paris" })
        #expect(paris.usageCount == 1)
        #expect(paris.parentPath == "Travel")
        #expect(KeywordLibraryTree.children(of: "Travel", in: nodes).map(\.path) == ["Travel|Paris"])
        #expect(KeywordLibraryTree.children(of: nil, in: nodes).map(\.path) == ["Food", "Travel"])
    }

    @Test func suggestionsIncludeSynonymHits() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [try path("Travel|Paris")])
        _ = try fixture.repo.setSynonyms(
            path: try path("Travel|Paris"), synonyms: ["巴黎"])
        _ = try fixture.repo.replacePhotoKeywords(
            photoId: "p1",
            paths: [try path("Travel|Paris")],
            source: "manual")

        let byPath = try fixture.service.suggestions(
            try KeywordSuggestionQuery(prefix: "Tra"))
        // 祖先 "Travel" 也命中路径前缀；更高 usage（有照片）的叶子排第一。
        #expect(byPath.first?.path == "Travel|Paris")
        #expect(byPath.contains { $0.path == "Travel" })
        #expect(byPath.first?.matchedSynonym == nil)

        let bySynonym = try fixture.service.suggestions(
            try KeywordSuggestionQuery(prefix: "巴黎"))
        #expect(bySynonym.map(\.path) == ["Travel|Paris"])
        #expect(bySynonym.first?.matchedSynonym == "巴黎")
    }

    @Test func renameCascadesChildrenMembersAndSynonyms() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [
            try path("Travel"),
            try path("Travel|Paris"),
        ])
        _ = try fixture.repo.setSynonyms(
            path: try path("Travel"), synonyms: ["旅"])
        _ = try fixture.repo.setSynonyms(
            path: try path("Travel|Paris"), synonyms: ["巴黎"])
        _ = try fixture.repo.replacePhotoKeywords(
            photoId: "p1",
            paths: [try path("Travel|Paris")],
            source: "manual")

        let summary = try fixture.service.rename(
            try KeywordRenameInput(from: "Travel", to: "Trips"))
        #expect(summary.nodes == 2)
        #expect(summary.members == 1)
        #expect(summary.synonyms == 2)

        let nodes = try fixture.service.library(try KeywordLibraryQuery())
        #expect(nodes.map(\.path).sorted() == ["Trips", "Trips|Paris"])
        #expect(try fixture.repo.photoKeywordPaths(photoId: "p1") == ["Trips|Paris"])
        #expect(try fixture.repo.synonyms(path: "Trips") == ["旅"])
    }

    @Test func mergeMovesMembersAndSynonymsIntoExistingTarget() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [
            try path("City"),
            try path("Travel|Paris"),
        ])
        _ = try fixture.repo.setSynonyms(
            path: try path("Travel|Paris"), synonyms: ["巴黎"])
        _ = try fixture.repo.replacePhotoKeywords(
            photoId: "p1",
            paths: [try path("Travel|Paris")],
            source: "manual")

        let summary = try fixture.service.merge(
            try KeywordMergeInput(source: "Travel|Paris", target: "City"))
        #expect(summary.nodes == 1)
        #expect(summary.members == 1)
        #expect(try fixture.repo.memberCount(path: "City", includeDescendants: false) == 1)
        #expect(try fixture.repo.synonyms(path: "City") == ["巴黎"])
        let nodes = try fixture.service.library(try KeywordLibraryQuery())
        #expect(!nodes.contains { $0.path == "Travel|Paris" })
    }

    @Test func mergeRejectsNonLeafSource() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [
            try path("City"),
            try path("Travel"),
            try path("Travel|Paris"),
        ])
        do {
            _ = try fixture.service.merge(
                try KeywordMergeInput(source: "Travel", target: "City"))
            Issue.record("non-leaf merge should fail")
        } catch let error as GatherError {
            #expect(error.code == .METADATA_KEYWORDS_INVALID)
            #expect(error.params["reason"]?.contains("叶子") == true)
        }
    }

    @Test func deleteGuardsMapToKeywordErrorCode() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [
            try path("Travel"),
            try path("Travel|Paris"),
            try path("Food"),
        ])
        // 有子级：非级联删除拒绝。
        do {
            _ = try fixture.service.delete(try KeywordDeleteInput(path: "Travel"))
            Issue.record("delete with children should fail")
        } catch let error as GatherError {
            #expect(error.code == .METADATA_KEYWORDS_INVALID)
            #expect(error.params["reason"]?.contains("子级") == true)
        }
        // 无成员/无子级/无同义词：允许删除。
        _ = try fixture.service.delete(try KeywordDeleteInput(path: "Food"))
        #expect(!(try fixture.service.library(try KeywordLibraryQuery()).contains { $0.path == "Food" }))
        // 同义词仍存在：非级联删除拒绝（防止 CASCADE 静默丢用户数据）。
        _ = try fixture.repo.setSynonyms(
            path: try path("Travel|Paris"), synonyms: ["巴黎"])
        do {
            _ = try fixture.service.delete(try KeywordDeleteInput(path: "Travel|Paris"))
            Issue.record("delete with synonyms should fail")
        } catch let error as GatherError {
            #expect(error.code == .METADATA_KEYWORDS_INVALID)
            #expect(error.params["reason"]?.contains("同义词") == true)
        }
    }

    @Test func createMaterializesAncestors() throws {
        let fixture = try makeFixture()
        let summary = try fixture.service.create(
            try KeywordCreateInput(path: "New|Child"))
        #expect(summary.nodes == 2)
        let nodes = try fixture.service.library(try KeywordLibraryQuery())
        #expect(nodes.map(\.path).sorted() == ["New", "New|Child"])
        // 幂等：重复创建不再新增。
        let again = try fixture.service.create(try KeywordCreateInput(path: "New|Child"))
        #expect(again.nodes == 0)
    }

    @Test func setSynonymsReplacesAndNormalizes() throws {
        let fixture = try makeFixture()
        _ = try fixture.repo.ensure(paths: [try path("Travel")])
        _ = try fixture.service.setSynonyms(
            try KeywordSynonymsInput(path: "Travel", synonyms: [" trip ", "TRIP", "旅"]))
        #expect(try fixture.repo.synonyms(path: "Travel") == ["trip", "旅"])
        _ = try fixture.service.setSynonyms(
            try KeywordSynonymsInput(path: "Travel", synonyms: []))
        #expect(try fixture.repo.synonyms(path: "Travel").isEmpty)
    }

    @Test func validatorRejectsSamePathRename() throws {
        #expect(throws: GatherError.self) {
            _ = try KeywordRenameInput(from: "Travel", to: "Travel")
        }
        #expect(throws: GatherError.self) {
            _ = try KeywordSuggestionQuery(prefix: "   ")
        }
    }
}
