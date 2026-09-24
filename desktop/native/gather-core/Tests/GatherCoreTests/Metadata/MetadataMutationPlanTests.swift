// desktop/native/gather-core/Tests/GatherCoreTests/Metadata/MetadataMutationPlanTests.swift
// validateMetadataPatch / normalizeKeywords
//（Services/MetadataContract.swift → Metadata/MetadataMutationPlan.swift）
// 直测：逐字段校验、规范化、错误码逐字。原文件零专用单测（仅被
// MetadataMutationService 间接覆盖），用例按 TS metadata-contract.ts 补齐。

import Foundation
import Testing
@testable import GatherCore

struct MetadataMutationPlanTests {

    // MARK: - normalizeKeywords

    @Test func normalizeKeywordsTrimsDropsEmptyAndDeduplicatesPreservingFirstOrder() throws {
        let fromStrings = try normalizeKeywords([" b ", "a", "", "  ", "a", "b"])
        #expect(fromStrings == ["b", "a"])

        let fromJSON = try normalizeKeywords(.array([
            .string(" b "), .number(1), .string("a"), .string(""), .string("a"),
        ]))
        #expect(fromJSON == ["b", "a"], "非字符串元素按 TS type guard 静默丢弃")

        // TS value.trim() 覆盖换行/制表；Swift 旧实现仅去空格/制表。
        let fromMultiline = try normalizeKeywords([" \n\t街头\r "])
        #expect(fromMultiline == ["街头"], "trim 对齐 JS trim（whitespacesAndNewlines）")
    }

    @Test func normalizeKeywordsThrowsKeywordsInvalidForNonArrayUnknown() {
        let nonArrays: [JSONValue] = [
            .number(1), .string("a"), .null, .bool(true), .object(["k": .string("v")]),
        ]
        for value in nonArrays {
            #expect(throws: MetadataContractError.keywordsInvalid) {
                try normalizeKeywords(value)
            }
        }
    }

    // MARK: - validateMetadataPatch

    @Test func validateMetadataPatchAcceptsAndNormalizesFullPatch() throws {
        let normalized = try validateMetadataPatch(MetadataPatch(
            rating: MetadataRatingPatch(value: 4),
            label: MetadataLabelPatch(value: "Red"),
            keywords: MetadataKeywordsPatch(op: .replace, values: [" 街头 ", "街头", ""])
        ))
        #expect(normalized.rating == MetadataRatingPatch(op: .set, value: 4))
        #expect(normalized.label == MetadataLabelPatch(op: .set, value: "Red"))
        #expect(normalized.keywords == MetadataKeywordsPatch(op: .replace, values: ["街头"]))
    }

    @Test func validateMetadataPatchAcceptsBoundaryRatingsAndEmptyLabel() throws {
        #expect(try validateMetadataPatch(MetadataPatch(rating: MetadataRatingPatch(value: 0)))
            .rating == MetadataRatingPatch(op: .set, value: 0))
        #expect(try validateMetadataPatch(MetadataPatch(rating: MetadataRatingPatch(value: 5)))
            .rating == MetadataRatingPatch(op: .set, value: 5))
        #expect(try validateMetadataPatch(MetadataPatch(label: MetadataLabelPatch(value: "")))
            .label == MetadataLabelPatch(op: .set, value: ""))
    }

    @Test func validateMetadataPatchRejectsInvalidRatings() {
        for value in [-1.0, 6.0, 2.5, Double.nan, Double.infinity] {
            #expect(throws: MetadataContractError.ratingInvalid) {
                try validateMetadataPatch(MetadataPatch(rating: MetadataRatingPatch(value: value)))
            }
        }
    }

    @Test func validateMetadataPatchRejectsUnknownLabel() {
        #expect(throws: MetadataContractError.labelInvalid) {
            try validateMetadataPatch(MetadataPatch(label: MetadataLabelPatch(value: "red")))
        }
    }

    @Test func validateMetadataPatchRejectsEmptyPatch() {
        #expect(throws: MetadataContractError.patchEmpty) {
            try validateMetadataPatch(MetadataPatch())
        }
    }

    @Test func metadataContractErrorDescriptionsMatchTSVerbatim() {
        #expect(MetadataContractError.keywordsInvalid.description == "METADATA_KEYWORDS_INVALID")
        #expect(MetadataContractError.patchInvalid.description == "METADATA_PATCH_INVALID")
        #expect(MetadataContractError.ratingInvalid.description == "METADATA_RATING_INVALID")
        #expect(MetadataContractError.labelInvalid.description == "METADATA_LABEL_INVALID")
        #expect(MetadataContractError.keywordsOpInvalid.description == "METADATA_KEYWORDS_OP_INVALID")
        #expect(MetadataContractError.patchEmpty.description == "METADATA_PATCH_EMPTY")
        #expect(MetadataContractError.unsupportedSource("x").description == "Unsupported metadata mutation source: x")
    }
}
