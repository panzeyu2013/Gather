// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/KeywordInputTests.swift
// P0 / K0：关键词输入校验（预览与写入共用同一套规则）。
import Foundation
import Testing
@testable import GatherProtocol

@Suite("K0 keyword inputs")
struct KeywordInputTests {
    @Test("photoIds 非空、去重、最多 500")
    func photoIdValidation() throws {
        let input = try MetadataPreviewInput(
            photoIds: ["p1", "p1", "p2"], addedKeywords: ["Bride"])
        #expect(input.photoIds == ["p1", "p2"])
        #expect(input.addedKeywords == ["Bride"])

        #expect(throws: GatherError.self) {
            _ = try MetadataPreviewInput(photoIds: [])
        }
        let tooMany = (0...500).map { "p\($0)" }
        #expect(throws: GatherError.self) {
            _ = try MetadataPreviewInput(photoIds: tooMany, addedKeywords: ["A"])
        }
    }

    @Test("added/removed 大小写折叠后不得重叠；归一化后不得全空")
    func editValidation() {
        #expect(throws: GatherError.self) {
            _ = try MetadataKeywordApplyInput(
                photoIds: ["p"], addedKeywords: ["Bride"], removedKeywords: ["bride"])
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataKeywordApplyInput(photoIds: ["p"])
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataKeywordApplyInput(
                photoIds: ["p"], addedKeywords: ["   "])
        }
    }

    @Test("100 条限额按归一化去重后的净编辑数计")
    func editLimitAfterNormalization() throws {
        let repeated = Array(repeating: "Bride", count: 100)
        let input = try MetadataPreviewInput(photoIds: ["p"], addedKeywords: repeated)
        #expect(input.addedKeywords == ["Bride"])

        let unique = (0..<101).map { "kw-\($0)" }
        #expect(throws: GatherError.self) {
            _ = try MetadataPreviewInput(photoIds: ["p"], addedKeywords: unique)
        }
    }

    @Test("delta 计划：加词不能归一化/删除盘上既有词（含超长、双空格、NFD）")
    func plannerPreservesDiskSpelling() {
        let long = String(repeating: "x", count: 300)
        let spaced = "Client  Name"
        let nfd = "Cafe\u{301}"
        let after = KeywordPlanner.apply(
            existing: [long, spaced, nfd], added: ["new"], removed: [])
        #expect(after == [long, spaced, nfd, "new"])
    }

    @Test("解码缺省 added/removed 为空数组")
    func decodingDefaults() throws {
        let json = #"{"photoIds":["p"],"removedKeywords":["A"]}"#
        let decoded = try JSONDecoder().decode(
            MetadataKeywordApplyInput.self, from: Data(json.utf8))
        #expect(decoded.photoIds == ["p"])
        #expect(decoded.addedKeywords.isEmpty)
        #expect(decoded.removedKeywords == ["A"])
    }
}
