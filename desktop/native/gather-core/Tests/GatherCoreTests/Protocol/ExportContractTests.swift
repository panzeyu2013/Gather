// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/ExportContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/export.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct ExportContractTests {

    // MARK: - Enums

    @Test func exportEnumRawValuesMatchTS() {
        let scopes: [(ExportScope, String)] = [
            (.selected, "selected"), (.filtered, "filtered"), (.session, "session"),
        ]
        for (value, raw) in scopes {
            #expect(value.rawValue == raw)
        }

        let variants: [(ExportVariantPolicy, String)] = [
            (.preferred, "preferred"), (.raw, "raw"), (.jpeg, "jpeg"), (.all, "all"),
        ]
        for (value, raw) in variants {
            #expect(value.rawValue == raw)
        }

        let formats: [(ExportFormat, String)] = [
            (.original, "original"), (.jpeg, "jpeg"), (.tiff, "tiff"),
        ]
        for (value, raw) in formats {
            #expect(value.rawValue == raw)
        }

        let compressions: [(ExportTiffCompression, String)] = [
            (.none, "none"), (.lzw, "lzw"), (.deflate, "deflate"),
        ]
        for (value, raw) in compressions {
            #expect(value.rawValue == raw)
        }

        let watermarkTypes: [(ExportWatermarkType, String)] = [
            (.text, "text"), (.image, "image"),
        ]
        for (value, raw) in watermarkTypes {
            #expect(value.rawValue == raw)
        }

        let positions: [(ExportWatermarkPosition, String)] = [
            (.center, "center"), (.bottomRight, "bottom-right"), (.bottomLeft, "bottom-left"),
        ]
        for (value, raw) in positions {
            #expect(value.rawValue == raw)
        }

        let reportFormats: [(ReportFormat, String)] = [
            (.csv, "csv"), (.md, "md"),
        ]
        for (value, raw) in reportFormats {
            #expect(value.rawValue == raw)
        }
    }

    // MARK: - ExportOptions

    @Test func exportOptionsFullRoundTripAndCamelCaseKeys() throws {
        let original = ExportOptions(
            scope: .selected,
            variantPolicy: .preferred,
            format: .jpeg,
            quality: 92,
            maxDimension: 2048,
            tiffCompression: nil,
            watermark: ExportWatermark(
                type: .text,
                content: "© 2025",
                position: .bottomRight,
                opacity: 0.5,
                fontSize: 24
            ),
            naming: ExportNaming(pattern: "{name}_{counter}", counterStart: 1, dateFormat: "yyyyMMdd"),
            includeXmp: true,
            destination: "/Users/me/Exports"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExportOptions.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "scope", "variantPolicy", "format", "quality", "maxDimension",
            "watermark", "naming", "includeXmp", "destination",
        ]
        #expect(Set(keys) == Set(expected), "ExportOptions JSON key 必须与 TS 字段名一致")
        #expect(!keys.contains("tiffCompression"), "nil 可选字段不应输出 key")
        #expect(!keys.contains("variant_policy"))
    }

    @Test func exportOptionsMinimalKeys() throws {
        let minimal = ExportOptions(
            scope: .session,
            format: .original,
            naming: ExportNaming(pattern: "{name}"),
            includeXmp: false,
            destination: "/u"
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(
            Set(keys) == ["scope", "format", "naming", "includeXmp", "destination"],
            "仅必填字段应出现"
        )
    }

    @Test func exportWatermarkNestedRoundTrip() throws {
        let watermark = ExportWatermark(type: .image, content: "/u/logo.png", position: .bottomLeft, opacity: 0.3)
        let data = try JSONEncoder().encode(watermark)
        #expect(try JSONDecoder().decode(ExportWatermark.self, from: data) == watermark)
        #expect(Set(try jsonKeys(of: data)) == ["type", "content", "position", "opacity"])
    }

    // MARK: - Params

    @Test func exportPreviewParamsRoundTrip() throws {
        let params = ExportPreviewParams(
            sessionId: "s1",
            options: ExportOptions(
                scope: .filtered, format: .tiff, tiffCompression: .lzw,
                naming: ExportNaming(pattern: "{name}"), includeXmp: true, destination: "/u"
            )
        )
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(ExportPreviewParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "options"])
    }

    @Test func exportExecuteParamsRoundTrip() throws {
        let params = ExportExecuteParams(
            sessionId: "s1",
            options: ExportOptions(
                scope: .selected, format: .jpeg, quality: 90,
                naming: ExportNaming(pattern: "{name}"), includeXmp: false, destination: "/u"
            ),
            confirmed: true
        )
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(ExportExecuteParams.self, from: data) == params)
        #expect(Set(try jsonKeys(of: data)) == ["sessionId", "options", "confirmed"])
    }

    @Test func exportCancelParamsEncodesEmptyObject() throws {
        let data = try JSONEncoder().encode(ExportCancelParams())
        let keys = try jsonKeys(of: data)
        #expect(keys.isEmpty, "ExportCancelParams 必须编码为 {}")
        #expect(try JSONDecoder().decode(ExportCancelParams.self, from: data) == ExportCancelParams())
    }

    @Test func exportReportParamsOptionality() throws {
        let full = ExportReportParams(sessionId: "s1", reportType: "session", format: "csv")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(full))) == ["sessionId", "reportType", "format"])

        let minimal = ExportReportParams(sessionId: "s1", reportType: "session")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimal))) == ["sessionId", "reportType"])
    }

    // MARK: - Results

    @Test func exportPreviewRoundTrip() throws {
        let original = ExportPreview(
            totalFiles: 2,
            totalSizeBytes: 2048,
            freeSpaceBytes: 1_000_000,
            files: [
                ExportPreviewFile(photoId: "p1", filename: "a.jpg", fileSize: 1024),
                ExportPreviewFile(photoId: "p2", filename: "b.jpg", fileSize: 1024),
            ]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ExportPreview.self, from: data) == original)
        // D09：预览多了"输出计划"字段（输出名/格式/边车/逐项诊断 + 物理文件数），
        // 键集合必须同步，否则跨端契约会静默漂移。
        #expect(Set(try jsonKeys(of: data)) == [
            "totalFiles", "totalSizeBytes", "freeSpaceBytes", "files",
            "photoCount", "sidecarCount", "physicalFileCount", "issueCount",
        ])
        let fileData = try JSONEncoder().encode(original.files[0])
        #expect(Set(try jsonKeys(of: fileData)) == [
            "photoId", "filename", "fileSize", "outputName", "format",
            "includesXmp", "isSizeEstimate", "willSkip",
        ])
    }

    /// P2-6（审计 3）：新字段必须能解码**旧载荷**（没有这些键的 JSON）。
    @Test func exportPreviewDecodesLegacyPayload() throws {
        let legacyFile = #"{"photoId":"p1","filename":"a.jpg","fileSize":1024}"#
        let legacyPreview = #"{"totalFiles":1,"totalSizeBytes":1024,"freeSpaceBytes":999,"files":["#
            + legacyFile + "]}"
        let decoded = try JSONDecoder().decode(ExportPreview.self, from: Data(legacyPreview.utf8))
        #expect(decoded.files.first?.outputName == "a.jpg", "缺 outputName 时退回源文件名")
        #expect(decoded.files.first?.format == "original")
        #expect(decoded.files.first?.includesXmp == false)
        #expect(decoded.files.first?.willSkip == false)
        #expect(decoded.photoCount == 1, "缺 photoCount 时回退 totalFiles")
        #expect(decoded.sidecarCount == 0)
        #expect(decoded.physicalFileCount == 1)
        #expect(decoded.issueCount == 0)
    }

    @Test func exportResultRoundTrip() throws {
        let original = ExportResult(totalFiles: 10, exported: 9, failed: 1, skipped: 0, errors: ["/u/bad.jpg"])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ExportResult.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["totalFiles", "exported", "failed", "skipped", "errors"])
    }

    @Test func reportDataRoundTrip() throws {
        let original = ReportData(path: "/u/report.csv", content: "a,b", format: .csv)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ReportData.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["path", "content", "format"])
    }

    // MARK: - helpers

    private func jsonKeys(of data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractTestError.invalidJSON
        }
        return Array(object.keys)
    }

    private enum ContractTestError: Error {
        case invalidJSON
    }
}
