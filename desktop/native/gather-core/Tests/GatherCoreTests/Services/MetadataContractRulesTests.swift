// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataContractRulesTests.swift
// Metadata 契约层剩余规则：可写字段集合来自 MetadataField 本身。
import Testing
@testable import GatherProtocol

@Suite("MetadataContractRules")
struct MetadataContractRulesTests {
    @Test("可写字段名集合的唯一真相源是 MetadataField（三字段），非法字段名派生 nil")
    func writableNamesComeFromContractEnum() {
        #expect(MetadataField.writableNames == ["rating", "label", "keywords", "descriptive"])
        #expect(MetadataField(rawValue: "rating") == .rating)
        #expect(MetadataField(rawValue: "source") == nil)
        #expect(MetadataField(rawValue: "bogus") == nil)
    }
}
