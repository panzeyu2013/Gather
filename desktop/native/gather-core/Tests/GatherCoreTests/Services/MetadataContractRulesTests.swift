// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataContractRulesTests.swift
// MetadataContract 的规则边界测试（原实现无直测）：标签/星级校验、关键词归一化、
// 可写字段集合的唯一真相源。Protocol/MetadataContractTests.swift 只覆盖契约类型
// 的 Codable 形状，本套件覆盖取值规则本身。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherDomain

@Suite("MetadataContractRules")
struct MetadataContractRulesTests {
    // TS: LABELS —— Capture One 颜色标签 = 协议枚举全集 + 空串（未设标签）。
    private let acceptedLabels: Set<String> = Set(CaptureOneColorLabel.allCases.map(\.rawValue)).union([""])

    @Test("label 校验：合法集合全通过；大小写/空白/未知值全拒绝")
    func labelValidationBoundaries() throws {
        for label in acceptedLabels.sorted() {
            let normalized = try validateMetadataPatch(MetadataPatch(label: MetadataLabelPatch(value: label)))
            #expect(normalized.label?.value == label)
        }
        for bad in ["red", "RED", "Teal", " None", "None ", "#FF0000", "none"] {
            #expect(throws: MetadataContractError.labelInvalid) {
                _ = try validateMetadataPatch(MetadataPatch(label: MetadataLabelPatch(value: bad)))
            }
        }
    }

    @Test("rating 校验：0/5/2.0 通过；-1/5.5/6/NaN/±∞ 拒绝；空 patch 拒绝")
    func ratingValidationBoundaries() throws {
        for good in [0.0, 5.0, 2.0] {
            _ = try validateMetadataPatch(MetadataPatch(rating: MetadataRatingPatch(value: good)))
        }
        for bad in [-1.0, 5.5, 6.0, Double.nan, Double.infinity, -Double.infinity] {
            #expect(throws: MetadataContractError.ratingInvalid) {
                _ = try validateMetadataPatch(MetadataPatch(rating: MetadataRatingPatch(value: bad)))
            }
        }
        #expect(throws: MetadataContractError.patchEmpty) { _ = try validateMetadataPatch(MetadataPatch()) }
    }

    @Test("关键词归一化：JSONValue 与 String 两个重载在全部边界输入上同结果")
    func keywordNormalizationBothOverloadsAgree() throws {
        let cases: [[JSONValue]] = [
            [],
            [.string(""), .string("   ")],
            [.string(" a "), .string("a"), .string("b")],
            [.string("k1"), .number(7), .bool(true), .null, .string("k1"), .string(" k2 ")],
            [.array([.string("x")]), .object(["y": .string("z")])],
        ]
        for input in cases {
            let viaJSON = try normalizeKeywords(input)
            let viaStrings = try normalizeKeywords(input.compactMap { $0.stringValue })
            #expect(viaJSON == viaStrings, "两个重载必须逐字相同：\(input)")
        }
        #expect(try normalizeKeywords([.string("k1"), .number(7), .bool(true), .null, .string("k1"), .string(" k2 ")]) == ["k1", "k2"])
        #expect(try normalizeKeywords([JSONValue]()) == [])
        #expect(try normalizeKeywords([.string("   ")]) == [])
    }

    @Test("可写字段名集合的唯一真相源是 MetadataField（三字段），非法字段名派生 nil")
    func writableNamesComeFromContractEnum() {
        #expect(MetadataField.writableNames == ["rating", "label", "keywords"])
        #expect(MetadataField(rawValue: "rating") == .rating)
        #expect(MetadataField(rawValue: "source") == nil)
        #expect(MetadataField(rawValue: "bogus") == nil)
    }
}
