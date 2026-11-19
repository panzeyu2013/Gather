// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 侧错误码数量变化（errors.ts）会在此触发失败。

import Foundation
import Testing
@testable import GatherProtocol

struct SessionContractTests {

    // MARK: - SessionData / PhotoData（P2：合并为逐样本断言，含可选字段省略）

    @Test("Session 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func sessionDTOsRoundTripAndCamelCaseKeys() throws {
        try assertRoundTrip(SessionData(
            id: "sess_1", name: "2025 街头", status: .analyzing, photoCount: 42,
            analysisStatus: .running, writebackStatus: .idle, importSource: "manual",
            sourcePath: "/Users/me/photos", failedWritebackCount: 0, truncatedImport: true,
            createdAt: "2025-01-01T00:00:00.000Z", updatedAt: "2025-01-02T00:00:00.000Z"),
            keys: [
                "id", "name", "status", "photoCount", "analysisStatus", "writebackStatus",
                "importSource", "sourcePath", "failedWritebackCount", "truncatedImport",
                "createdAt", "updatedAt",
            ],
            forbiddenKeys: ["photo_count", "analysis_status", "import_source"])

        try assertRoundTrip(PhotoData(
            id: "photo_1", sessionId: "sess_1", filepath: "/Users/me/photos/DSC0001.ARW",
            filename: "DSC0001.ARW", checksum: "abc123", hasExistingXmp: true, faceCount: 2,
            width: 6000, height: 4000,
            metadata: ["keywords": .array([.string("街头"), .string("夜景")]), "rating": .number(4)],
            result: ["faceCount": .number(2), "notes": .null], status: "indexed",
            assetId: "asset_9", variantCount: 2,
            variants: [
                PhotoVariant(photoId: "photo_1", filepath: "/u/DSC0001.JPG", filename: "DSC0001.JPG", role: "preview"),
                PhotoVariant(photoId: "photo_1", filepath: "/u/DSC0001.ARW", filename: "DSC0001.ARW", role: "original"),
            ],
            createdAt: "2025-01-01T00:00:00.000Z", updatedAt: "2025-01-01T00:00:00.000Z"),
            keys: [
                "id", "sessionId", "filepath", "filename", "checksum", "hasExistingXmp",
                "faceCount", "width", "height", "metadata", "result", "status",
                "assetId", "variantCount", "variants", "createdAt", "updatedAt",
            ],
            forbiddenKeys: ["has_existing_xmp"]
        ) { decoded in
            // 正向键断言保留（精确键集合已隐含，显式写出防止将来改成子集断言时漏掉）。
            let keys = try jsonKeys(of: JSONEncoder().encode(decoded))
            #expect(keys.contains("hasExistingXmp"))
            #expect(keys.contains("faceCount"))
        }

        // nil 可选字段（assetId / variantCount / variants）不应输出 key。
        try assertJSONKeys(PhotoData(
            id: "p1", sessionId: "s1", filepath: "/u/a.jpg", filename: "a.jpg",
            checksum: "c", hasExistingXmp: false, faceCount: 0, width: 1, height: 1,
            metadata: [:], result: [:], status: "indexed", createdAt: "t", updatedAt: "t"),
            name: "PhotoData(nil variants)", forbiddenKeys: ["assetId", "variantCount", "variants"])
    }

    @Test func sessionDataDecodesStatusRawValues() throws {
        let json = """
        {
          "id": "s1", "name": "n", "status": "photos_loaded",
          "photoCount": 0, "analysisStatus": "cancelled", "writebackStatus": "partial",
          "importSource": "capture-one", "sourcePath": "/x", "failedWritebackCount": 1,
          "truncatedImport": false, "createdAt": "t", "updatedAt": "t"
        }
        """
        let session = try JSONDecoder().decode(SessionData.self, from: Data(json.utf8))
        #expect(session.status == .photosLoaded)
        #expect(session.analysisStatus == .cancelled)
        #expect(session.writebackStatus == .partial)
    }

    @Test func photoDataMetadataRoundTripsJSONValues() throws {
        let original = PhotoData(
            id: "p1", sessionId: "s1", filepath: "/u/a.jpg", filename: "a.jpg",
            checksum: "c", hasExistingXmp: false, faceCount: 0, width: 1, height: 1,
            metadata: ["keywords": .array([.string("a"), .string("b")]), "rating": .number(4)],
            result: [String: JSONValue](), status: "indexed", createdAt: "t", updatedAt: "t")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoData.self, from: data)
        #expect(decoded.metadata["keywords"] == .array([.string("a"), .string("b")]))
        #expect(decoded.metadata["rating"] == .number(4))
    }

    // MARK: - 状态枚举

    @Test func sessionStatusRawValuesMatchTS() {
        let cases: [(SessionStatus, String)] = [
            (.draft, "draft"), (.photosLoaded, "photos_loaded"), (.analyzing, "analyzing"),
            (.review, "review"), (.completed, "completed"),
        ]
        for (status, raw) in cases {
            #expect(status.rawValue == raw)
        }
    }

    // MARK: - GatherErrorCode

    @Test func gatherErrorCodeCountIsPinned() {
        // TS 参考实现（packages/shared/src/errors.ts）已随原生迁移删除，156 项
        // 是其历史清单。原生新增 7 个 sidecar 文档故障码（XMP_DOCUMENT_CORRUPT /
        // _UNSUPPORTED / _READ_FAILED、XMP_WRITE_FAILED / _VERIFICATION_FAILED、
        // XMP_BACKUP_FAILED、XMP_RESTORE_FAILED）后总数 163。
        // 审查修复轮再补 6 个结构化码：XMP_CONFIRM_OTHER_SESSION_PENDING、
        // DUP_THRESHOLD_INVALID、ASSET_RELINK_SAME_ROOT / _NESTED_ROOT /
        // _NO_FILES_REGISTERED / _NO_VERIFIED_FILE → 169。
        // UI 审计第三轮补 1 个宿主启动码：GATHER_BOOTSTRAPPING（启动早期触发 C1
        // 导入时发射；此前是裸字符串 → 用户看到「未知错误」，且文案表交叉契约测试
        // 会把它当孤儿码挡下来）→ 174。
        // 深度审查 D02 补 1 个交付失败码：EXPORT_ALL_FAILED（全失败不再谎报成功）
        // → 175。深度审查 D09 再补 2 个计划诊断码（EXPORT_SOURCE_MISSING /
        // EXPORT_SOURCE_UNREADABLE：逐项可执行性诊断进枚举，才能过本地化交叉契约）
        // → 177。Cut 1 D-010 再补 2 个通用码（INVALID_PARAM / PHOTO_NOT_FOUND）→ 179。
        // P0 收口（75f0cf65：4 个初筛码 TRIAGE_NOT_READY / _STALE / _APPLY_INVALID /
        // _POLICY_INVALID + 1 个通用码）→ 184；淘汰移出目标路径冲突再补 1
        // （ASSET_RELINK_TARGET_EXISTS，4b006626）→ 185；P1 JPEG 内嵌清空失败再补 1
        // （JPEG_EMBEDDED_CLEAR_UNSUPPORTED，f8d1177b）→ 186；W3 整套交付/WebDAV 发布
        // 再补 9 个（OUTPUT_* ×5 + WEBDAV_* ×4：此前只有裸字符串，UI 一律退化成
        // 「发生未知错误」，a59a2fbc）→ 195。
        // P1-3 setSourceRoot 再补 1 个根目录排除照片码（SESSION_SOURCE_EXCLUDES_PHOTOS）
        // → 196；P1-4 再补 1 个预览过期码（FKW_PREVIEW_STALE）→ 197；P1-7 再补
        // CULLING_SELECTION_CHANGED → 198；METADATA_PREVIEW_STALE → 199；
        // 摄取失败 4 码 → 203；模板批次 4 码 + 重复组 2 码 → 209；
        // Wave2 G3：C1 判断读取降级码（C1_JUDGEMENTS_UNAVAILABLE）→ 210。
        // 增删错误码时必须同步此断言、ErrorCodeContractTests 的清单与
        // GatherLocalization.errorMessages（缺一即被交叉契约测试挡下）。
        #expect(GatherErrorCode.allCases.count == 210)
    }

    @Test func gatherErrorCodeRawValueMatchesCaseName() {
        for code in GatherErrorCode.allCases {
            #expect(code.rawValue == String(describing: code), "rawValue 必须等于 TS 码字符串")
        }
    }

    @Test func gatherErrorCodeSpotValues() {
        #expect(GatherErrorCode.SESSION_NOT_FOUND.rawValue == "SESSION_NOT_FOUND")
        #expect(GatherErrorCode.SESSION_DELETE_NOT_CONFIRMED.rawValue == "SESSION_DELETE_NOT_CONFIRMED")
        #expect(GatherErrorCode.FKW_NO_OBSERVATIONS.rawValue == "FKW_NO_OBSERVATIONS")
        #expect(GatherErrorCode.SIM_THRESHOLD_INVALID.rawValue == "SIM_THRESHOLD_INVALID")
    }

    @Test func gatherErrorCodeCodableRoundTrip() throws {
        for code in GatherErrorCode.allCases {
            let data = try JSONEncoder().encode(code)
            let decoded = try JSONDecoder().decode(GatherErrorCode.self, from: data)
            #expect(decoded == code)
        }
    }
}
