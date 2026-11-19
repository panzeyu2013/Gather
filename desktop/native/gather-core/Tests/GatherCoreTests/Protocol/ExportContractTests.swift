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
        let reportFormats: [(ReportFormat, String)] = [(.csv, "csv"), (.md, "md")]
        for (value, raw) in reportFormats {
            #expect(value.rawValue == raw)
        }
    }

    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并，含可选字段省略）

    @Test("Export 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func exportDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(ExportOptions(
            scope: .selected, variantPolicy: .preferred, format: .jpeg,
            quality: 92, maxDimension: 2048, tiffCompression: nil,
            watermark: ExportWatermark(type: .text, content: "© 2025",
                                       position: .bottomRight, opacity: 0.5, fontSize: 24),
            naming: ExportNaming(pattern: "{name}_{counter}", counterStart: 1, dateFormat: "yyyyMMdd"),
            includeXmp: true, destination: "/Users/me/Exports"),
            keys: [
                "scope", "variantPolicy", "format", "quality", "maxDimension",
                "watermark", "naming", "includeXmp", "destination",
            ],
            name: "ExportOptions(完整)", forbiddenKeys: ["tiffCompression", "variant_policy"])
        try assertRoundTrip(ExportWatermark(type: .image, content: "/u/logo.png",
                                            position: .bottomLeft, opacity: 0.3),
                            keys: ["type", "content", "position", "opacity"])
        // P0-5（Wave1）：色彩空间 / DPI / 输出锐化（nested ExportSharpening）。
        let specsData = try assertRoundTrip(ExportOptions(
            scope: .session, format: .jpeg, quality: 90, maxDimension: 2048,
            colorSpace: .displayP3, dpi: 300,
            sharpening: ExportSharpening(radius: 1.2, intensity: 0.6),
            naming: ExportNaming(pattern: "{original}"), includeXmp: false, destination: "/u/out"),
            name: "ExportOptions(输出规格)")
        #expect(Set(try jsonKeys(of: specsData)).isSuperset(of: ["colorSpace", "dpi", "sharpening"]))
        let preview = ExportPreview(
            totalFiles: 2, totalSizeBytes: 2048, freeSpaceBytes: 1_000_000,
            files: [
                ExportPreviewFile(photoId: "p1", filename: "a.jpg", fileSize: 1024),
                ExportPreviewFile(photoId: "p2", filename: "b.jpg", fileSize: 1024),
            ])
        try assertRoundTrip(preview,
                            keys: ["totalFiles", "totalSizeBytes", "freeSpaceBytes", "files",
                                   "photoCount", "sidecarCount", "physicalFileCount", "issueCount"])
        // D09：预览多了"输出计划"字段（输出名/格式/sidecar/逐项诊断 + 物理文件数），
        // 文件键集合必须同步，否则跨端契约会静默漂移。
        let fileData = try JSONEncoder().encode(preview.files[0])
        #expect(Set(try jsonKeys(of: fileData)) == [
            "photoId", "filename", "fileSize", "outputName", "format",
            "includesXmp", "isSizeEstimate", "willSkip",
        ])
        try assertRoundTrip(ExportResult(totalFiles: 10, exported: 9, failed: 1, skipped: 0,
                                         errors: ["/u/bad.jpg"]),
                            keys: ["totalFiles", "exported", "failed", "skipped", "errors"])
        try assertRoundTrip(ReportData(path: "/u/report.csv", content: "a,b", format: .csv),
                            keys: ["path", "content", "format"])
        // 仅必填字段的 ExportOptions：可选字段必须省略。
        try assertJSONKeys(ExportOptions(scope: .session, format: .original,
                                         naming: ExportNaming(pattern: "{name}"),
                                         includeXmp: false, destination: "/u"),
                           keys: ["scope", "format", "naming", "includeXmp", "destination"],
                           name: "ExportOptions(缺省)")
    }

    /// 旧载荷（job checkpoint / 旧客户端）没有三个新键：必须解码成 nil = 旧行为。
    @Test func exportOptionsDecodesLegacyPayloadWithoutOutputSpecs() throws {
        let legacy = #"{"scope":"session","format":"jpeg","quality":90,"naming":{"pattern":"{original}"},"includeXmp":false,"destination":"/u/out"}"#
        let decoded = try JSONDecoder().decode(ExportOptions.self, from: Data(legacy.utf8))
        #expect(decoded.colorSpace == nil)
        #expect(decoded.dpi == nil)
        #expect(decoded.sharpening == nil)
    }

    @Test func exportColorSpaceRawValuesAreFrozen() {
        // 持久化在配方 JSON / job checkpoint 里：rawValue 改名等于破坏兼容。
        #expect(ExportColorSpace.sRGB.rawValue == "sRGB")
        #expect(ExportColorSpace.displayP3.rawValue == "display-p3")
        #expect(ExportColorSpace.adobeRGB1998.rawValue == "adobe-rgb-1998")
        #expect(ExportColorSpace.allCases.count == 3)
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
}
