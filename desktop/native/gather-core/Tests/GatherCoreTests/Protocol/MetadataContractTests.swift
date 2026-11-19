// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/MetadataContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/metadata.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct MetadataContractTests {

    // MARK: - Enums

    @Test func metadataEnumsRawValuesMatchTS() {
        let fields: [(MetadataField, String)] = [
            (.rating, "rating"), (.label, "label"), (.keywords, "keywords"),
        ]
        for (field, raw) in fields {
            #expect(field.rawValue == raw)
        }
        let sources: [(MetadataMutationSource, String)] = [
            (.culling, "culling"), (.faceKeyword, "face-keyword"), (.similarity, "similarity"),
            (.template, "template"), (.manual, "manual"),
        ]
        for (source, raw) in sources {
            #expect(source.rawValue == raw)
        }
        let choices: [(MetadataConflictChoice, String)] = [
            (.keepLocal, "keep_local"), (.useRemote, "use_remote"),
        ]
        for (choice, raw) in choices {
            #expect(choice.rawValue == raw)
        }
        let actions: [(MetadataOrphanAction, String)] = [
            (.keep, "keep"), (.restore, "restore"), (.retry, "retry"),
        ]
        for (action, raw) in actions {
            #expect(action.rawValue == raw)
        }
    }

    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并）

    @Test("Metadata 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func metadataDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(MetadataMutationResult(
            photoId: "p1", xmpPath: "/u/a.xmp",
            dirtyFields: [.rating, .keywords], revision: 3, status: "pending"),
            keys: ["photoId", "xmpPath", "dirtyFields", "revision", "status"])
        try assertRoundTrip(MetadataConflictField(
            field: .rating, baseline: .number(3), local: .number(4),
            remote: .object(["source": .string("capture-one")])),
            keys: ["field", "baseline", "local", "remote"])
        try assertRoundTrip(MetadataConflict(
            xmpPath: "/u/a.xmp", photoPath: "/u/a.jpg", revision: 2,
            fields: [MetadataConflictField(field: .label, baseline: .string("红"),
                                           local: .string("蓝"), remote: .string("绿"))]),
            keys: ["xmpPath", "photoPath", "revision", "fields"])
        try assertRoundTrip(MetadataOrphan(
            xmpPath: "/u/o.xmp", photoPath: "/u/o.jpg", status: "orphan",
            revision: 1, errorMessage: "E", updatedAt: "t"),
            keys: ["xmpPath", "photoPath", "status", "revision", "errorMessage", "updatedAt"])
    }

    // MARK: - MetadataTags（P2：全量 + Partial 形状合并）

    @Test func metadataTagsRoundTripAndKeys() throws {
        try assertRoundTrip(MetadataTags(
            filename: "a.jpg", fileSize: 1024, format: "image/jpeg", width: 6000, height: 4000,
            mime: "image/jpeg", make: "SONY", model: "ILCE-7M4", serialNumber: "S123",
            lensModel: "FE 50mm", focalLength: 50, maxAperture: 1.8, aperture: 2.8,
            shutterSpeed: "1/250", iso: 100, exposureComp: "+0.3",
            meteringMode: "Multi-segment", whiteBalance: "Daylight",
            dateTaken: "2025-01-01T10:00:00Z", dateDigitized: "2025-01-01T10:00:00Z",
            title: "T", description: "D", author: "A", copyright: "C",
            keywords: ["街头"], rating: 4, label: "红",
            latitude: 31.23, longitude: 121.47, altitude: 12.5),
            keys: [
                "filename", "fileSize", "format", "width", "height", "mime", "make", "model",
                "serialNumber", "lensModel", "focalLength", "maxAperture", "aperture",
                "shutterSpeed", "iso", "exposureComp", "meteringMode", "whiteBalance",
                "dateTaken", "dateDigitized", "title", "description", "author", "copyright",
                "keywords", "rating", "label", "latitude", "longitude", "altitude",
            ],
            forbiddenKeys: ["serial_number", "shutter_speed"])
        // Partial<MetadataTags> 未设置字段必须省略；全空编码为 {}。
        try assertJSONKeys(MetadataTags(keywords: ["街头"], rating: 5), keys: ["rating", "keywords"],
                           name: "MetadataTags(partial)")
        try assertJSONKeys(MetadataTags(), keys: [], name: "MetadataTags(空)")
    }
}
