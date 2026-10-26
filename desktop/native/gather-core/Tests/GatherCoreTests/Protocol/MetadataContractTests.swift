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

    // MARK: - MetadataMutationResult

    @Test func metadataMutationResultRoundTrip() throws {
        let original = MetadataMutationResult(
            photoId: "p1", xmpPath: "/u/a.xmp",
            dirtyFields: [.rating, .keywords], revision: 3, status: "pending"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MetadataMutationResult.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["photoId", "xmpPath", "dirtyFields", "revision", "status"])
    }

    // MARK: - MetadataConflict

    @Test func metadataConflictFieldRoundTripsJSONValues() throws {
        let original = MetadataConflictField(
            field: .rating,
            baseline: .number(3),
            local: .number(4),
            remote: .object(["source": .string("capture-one")])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetadataConflictField.self, from: data)
        #expect(decoded == original)
        #expect(Set(try jsonKeys(of: data)) == ["field", "baseline", "local", "remote"])
    }

    @Test func metadataConflictRoundTrip() throws {
        let original = MetadataConflict(
            xmpPath: "/u/a.xmp",
            photoPath: "/u/a.jpg",
            revision: 2,
            fields: [
                MetadataConflictField(field: .label, baseline: .string("红"), local: .string("蓝"), remote: .string("绿")),
            ]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MetadataConflict.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["xmpPath", "photoPath", "revision", "fields"])
    }

    // MARK: - MetadataOrphan

    @Test func metadataOrphanRoundTrip() throws {
        let original = MetadataOrphan(
            xmpPath: "/u/o.xmp", photoPath: "/u/o.jpg", status: "orphan",
            revision: 1, errorMessage: "E", updatedAt: "t"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MetadataOrphan.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["xmpPath", "photoPath", "status", "revision", "errorMessage", "updatedAt"])
    }

    // MARK: - MetadataTags

    @Test func metadataTagsRoundTripAndKeys() throws {
        let original = MetadataTags(
            filename: "a.jpg", fileSize: 1024, format: "image/jpeg", width: 6000, height: 4000,
            mime: "image/jpeg", make: "SONY", model: "ILCE-7M4", serialNumber: "S123",
            lensModel: "FE 50mm", focalLength: 50, maxAperture: 1.8, aperture: 2.8,
            shutterSpeed: "1/250", iso: 100, exposureComp: "+0.3",
            meteringMode: "Multi-segment", whiteBalance: "Daylight",
            dateTaken: "2025-01-01T10:00:00Z", dateDigitized: "2025-01-01T10:00:00Z",
            title: "T", description: "D", author: "A", copyright: "C",
            keywords: ["街头"], rating: 4, label: "红",
            latitude: 31.23, longitude: 121.47, altitude: 12.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetadataTags.self, from: data)
        #expect(decoded == original)

        let expected = [
            "filename", "fileSize", "format", "width", "height", "mime", "make", "model",
            "serialNumber", "lensModel", "focalLength", "maxAperture", "aperture",
            "shutterSpeed", "iso", "exposureComp", "meteringMode", "whiteBalance",
            "dateTaken", "dateDigitized", "title", "description", "author", "copyright",
            "keywords", "rating", "label", "latitude", "longitude", "altitude",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "MetadataTags JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("serial_number"))
        #expect(!Set(try jsonKeys(of: data)).contains("shutter_speed"))
    }

    @Test func metadataTagsPartialEncodesOnlySetKeys() throws {
        let partial = MetadataTags(keywords: ["街头"], rating: 5)
        let keys = try jsonKeys(of: JSONEncoder().encode(partial))
        #expect(Set(keys) == ["rating", "keywords"], "Partial<MetadataTags> 未设置字段必须省略")

        let empty = MetadataTags()
        #expect(try jsonKeys(of: JSONEncoder().encode(empty)).isEmpty)
    }

    private func jsonKeys(of data: Data) throws -> [String] {
        Array(try jsonObject(of: data).keys)
    }

    private func jsonObject(of data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractTestError.invalidJSON
        }
        return object
    }

    private enum ContractTestError: Error {
        case invalidJSON
    }
}
