// desktop/native/gather-core/Tests/GatherCoreTests/Metadata/MetadataConflictRulesTests.swift
// MetadataConflictFields（Services/MetadataConflictFields.swift → Metadata/MetadataConflictRules.swift）
// 直测：dirty-fields 解析 / fieldConflicts 逐字段列表 / hasFieldConflict 门控。
// 语义承接：原文件零专用单测，用例按 TS metadata-conflict-fields.ts 语义补齐。

import Foundation
import Testing
@testable import GatherCore

struct MetadataConflictRulesTests {

    // MARK: - parseDirtyFields / tryParseDirtyFields

    @Test func parseDirtyFieldsParsesKnownFieldsAndDropsUnknown() {
        #expect(MetadataConflictFields.parseDirtyFields(#"["rating","label","keywords"]"#)
            == [.rating, .label, .keywords])
        #expect(MetadataConflictFields.parseDirtyFields(#"["unknown","rating"]"#) == [.rating])
        #expect(MetadataConflictFields.parseDirtyFields(#"[]"#).isEmpty)
    }

    @Test func parseDirtyFieldsCorruptOrNonArrayIsEmpty() {
        #expect(MetadataConflictFields.parseDirtyFields("not json").isEmpty)
        #expect(MetadataConflictFields.parseDirtyFields(#"{"rating":true}"#).isEmpty)
        #expect(MetadataConflictFields.parseDirtyFields(#""rating""#).isEmpty)
    }

    @Test func tryParseDirtyFieldsStrictVariantReturnsNilOnlyForCorrupt() {
        #expect(MetadataConflictFields.tryParseDirtyFields(#"["rating"]"#) == [.rating])
        #expect(MetadataConflictFields.tryParseDirtyFields(#"["nope"]"#) == [])
        #expect(MetadataConflictFields.tryParseDirtyFields(#"[]"#) == [])
        #expect(MetadataConflictFields.tryParseDirtyFields("not json") == nil)
        #expect(MetadataConflictFields.tryParseDirtyFields(#"{"rating":true}"#) == nil)
    }

    // MARK: - fieldConflicts

    @Test func fieldConflictsOnlyReportsFieldsWhoseRemoteDiffersFromBaseline() {
        let base: JSONValue = .object(["rating": .number(3)])
        let local: JSONValue = .object(["rating": .number(5)])
        // 远端仍是基线值 3 → 无冲突。
        let clean = MetadataConflictFields.fieldConflicts(
            base: base, local: local,
            current: MetadataWriteAttributes(rating: 3),
            dirtyFields: [.rating]
        )
        #expect(clean.isEmpty)

        // 远端改成 4 → 逐字段条目携带 baseline/local/remote。
        let conflicted = MetadataConflictFields.fieldConflicts(
            base: base, local: local,
            current: MetadataWriteAttributes(rating: 4),
            dirtyFields: [.rating]
        )
        #expect(conflicted == [
            MetadataConflictField(field: .rating, baseline: .number(3), local: .number(5), remote: .number(4)),
        ])
    }

    @Test func fieldConflictsNormalizesMissingBaselineDefaults() {
        // label 缺失基线按 ""（TS undefined 归一到空串）；keywords 缺失按 []。
        let noConflict = MetadataConflictFields.fieldConflicts(
            base: .object([:]), local: .object([:]),
            current: MetadataWriteAttributes(keywords: [], label: ""),
            dirtyFields: [.label, .keywords]
        )
        #expect(noConflict.isEmpty)

        // rating 缺失基线按 null：当前仍是 nil → 无冲突。
        let ratingStillNil = MetadataConflictFields.fieldConflicts(
            base: .object([:]), local: .object([:]),
            current: MetadataWriteAttributes(),
            dirtyFields: [.rating]
        )
        #expect(ratingStillNil.isEmpty)

        let keywordConflict = MetadataConflictFields.fieldConflicts(
            base: .object([:]), local: .object(["keywords": .array([.string("本地")])]),
            current: MetadataWriteAttributes(keywords: ["远端"]),
            dirtyFields: [.keywords]
        )
        #expect(keywordConflict == [
            MetadataConflictField(
                field: .keywords,
                baseline: .array([]),
                local: .array([.string("本地")]),
                remote: .array([.string("远端")])
            ),
        ])

        let labelConflict = MetadataConflictFields.fieldConflicts(
            base: .object([:]), local: .object([:]),
            current: MetadataWriteAttributes(label: "Red"),
            dirtyFields: [.label]
        )
        #expect(labelConflict == [
            MetadataConflictField(field: .label, baseline: .string(""), local: .null, remote: .string("Red")),
        ])
    }

    @Test func fieldConflictsIgnoresFieldsNotDirty() {
        let conflicts = MetadataConflictFields.fieldConflicts(
            base: .object(["rating": .number(3)]),
            local: .object([:]),
            current: MetadataWriteAttributes(rating: 5, label: "Red"),
            dirtyFields: []
        )
        #expect(conflicts.isEmpty)
    }

    // MARK: - hasFieldConflict

    @Test func hasFieldConflictRatingComparesToBaselineNumber() {
        let base: JSONValue = .object(["rating": .number(3)])
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: base, current: MetadataWriteAttributes(rating: 3), dirtyFields: [.rating]))
        #expect(MetadataConflictFields.hasFieldConflict(
            base: base, current: MetadataWriteAttributes(rating: 4), dirtyFields: [.rating]))
        // 基线缺失（nil）与当前 nil：TS undefined === undefined → 无冲突。
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: .object([:]), current: MetadataWriteAttributes(), dirtyFields: [.rating]))
        #expect(MetadataConflictFields.hasFieldConflict(
            base: .object([:]), current: MetadataWriteAttributes(rating: 3), dirtyFields: [.rating]))
    }

    @Test func hasFieldConflictLabelTreatsMissingAsEmptyString() {
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: .object([:]), current: MetadataWriteAttributes(label: ""), dirtyFields: [.label]))
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: .object(["label": .string("Red")]), current: MetadataWriteAttributes(label: "Red"), dirtyFields: [.label]))
        #expect(MetadataConflictFields.hasFieldConflict(
            base: .object(["label": .string("Red")]), current: MetadataWriteAttributes(label: "Green"), dirtyFields: [.label]))
        #expect(MetadataConflictFields.hasFieldConflict(
            base: .object([:]), current: MetadataWriteAttributes(label: "Red"), dirtyFields: [.label]))
    }

    @Test func hasFieldConflictKeywordsComparesStringifiedArrays() {
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: .object([:]), current: MetadataWriteAttributes(keywords: []), dirtyFields: [.keywords]))
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: .object(["keywords": .array([.string("a"), .string("b")])]),
            current: MetadataWriteAttributes(keywords: ["a", "b"]),
            dirtyFields: [.keywords]))
        // 顺序不同 = 字符串化不同 → 冲突（TS JSON.stringify 语义）。
        #expect(MetadataConflictFields.hasFieldConflict(
            base: .object(["keywords": .array([.string("a"), .string("b")])]),
            current: MetadataWriteAttributes(keywords: ["b", "a"]),
            dirtyFields: [.keywords]))
        #expect(MetadataConflictFields.hasFieldConflict(
            base: .object([:]), current: MetadataWriteAttributes(keywords: ["a"]), dirtyFields: [.keywords]))
    }

    @Test func hasFieldConflictEmptyDirtyFieldsIsFalse() {
        #expect(!MetadataConflictFields.hasFieldConflict(
            base: .object(["rating": .number(1)]),
            current: MetadataWriteAttributes(keywords: ["x"], rating: 5, label: "Red"),
            dirtyFields: []))
    }
}
