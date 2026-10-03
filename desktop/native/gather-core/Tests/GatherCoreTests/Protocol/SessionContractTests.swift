// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/SessionContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 侧错误码数量变化（errors.ts）会在此触发失败。

import Foundation
import Testing
@testable import GatherCore

struct SessionContractTests {

    // MARK: - SessionData

    @Test func sessionDataRoundTripAndCamelCaseKeys() throws {
        let original = SessionData(
            id: "sess_1",
            name: "2025 街头",
            status: .analyzing,
            photoCount: 42,
            analysisStatus: .running,
            writebackStatus: .idle,
            importSource: "manual",
            sourcePath: "/Users/me/photos",
            failedWritebackCount: 0,
            truncatedImport: true,
            createdAt: "2025-01-01T00:00:00.000Z",
            updatedAt: "2025-01-02T00:00:00.000Z"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "id", "name", "status", "photoCount", "analysisStatus", "writebackStatus",
            "importSource", "sourcePath", "failedWritebackCount", "truncatedImport",
            "createdAt", "updatedAt",
        ]
        #expect(Set(keys) == Set(expected), "SessionData JSON key 必须与 TS 字段名一致")
        #expect(!keys.contains("photo_count"), "禁止 snake_case 泄漏")
        #expect(!keys.contains("analysis_status"))
        #expect(!keys.contains("import_source"))
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

    // MARK: - PhotoData

    @Test func photoDataRoundTripAndCamelCaseKeys() throws {
        let original = PhotoData(
            id: "photo_1",
            sessionId: "sess_1",
            filepath: "/Users/me/photos/DSC0001.ARW",
            filename: "DSC0001.ARW",
            checksum: "abc123",
            hasExistingXmp: true,
            faceCount: 2,
            width: 6000,
            height: 4000,
            metadata: ["keywords": .array([.string("街头"), .string("夜景")]), "rating": .number(4)],
            result: ["faceCount": .number(2), "notes": .null],
            status: "indexed",
            assetId: "asset_9",
            variantCount: 2,
            variants: [
                PhotoVariant(photoId: "photo_1", filepath: "/u/DSC0001.JPG", filename: "DSC0001.JPG", role: "preview"),
                PhotoVariant(photoId: "photo_1", filepath: "/u/DSC0001.ARW", filename: "DSC0001.ARW", role: "original"),
            ],
            createdAt: "2025-01-01T00:00:00.000Z",
            updatedAt: "2025-01-01T00:00:00.000Z"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoData.self, from: data)
        #expect(decoded == original)

        let keys = try jsonKeys(of: data)
        let expected = [
            "id", "sessionId", "filepath", "filename", "checksum", "hasExistingXmp",
            "faceCount", "width", "height", "metadata", "result", "status",
            "assetId", "variantCount", "variants", "createdAt", "updatedAt",
        ]
        #expect(Set(keys) == Set(expected), "PhotoData JSON key 必须与 TS 字段名一致")
        #expect(keys.contains("hasExistingXmp"))
        #expect(keys.contains("faceCount"))
        #expect(!keys.contains("has_existing_xmp"))
    }

    @Test func photoDataMetadataRoundTripsJSONValues() throws {
        let original = PhotoData(
            id: "p1", sessionId: "s1", filepath: "/u/a.jpg", filename: "a.jpg",
            checksum: "c", hasExistingXmp: false, faceCount: 0, width: 1, height: 1,
            metadata: ["keywords": .array([.string("a"), .string("b")]), "rating": .number(4)],
            result: [String: JSONValue](), status: "indexed",
            createdAt: "t", updatedAt: "t"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoData.self, from: data)
        #expect(decoded.metadata["keywords"] == .array([.string("a"), .string("b")]))
        #expect(decoded.metadata["rating"] == .number(4))
    }

    @Test func photoDataOptionalVariantsOmittedWhenNil() throws {
        let original = PhotoData(
            id: "p1", sessionId: "s1", filepath: "/u/a.jpg", filename: "a.jpg",
            checksum: "c", hasExistingXmp: false, faceCount: 0, width: 1, height: 1,
            metadata: [:], result: [:], status: "indexed",
            createdAt: "t", updatedAt: "t"
        )
        let data = try JSONEncoder().encode(original)
        let keys = try jsonKeys(of: data)
        #expect(!keys.contains("assetId"), "nil 可选字段不应输出 key")
        #expect(!keys.contains("variantCount"))
        #expect(!keys.contains("variants"))
    }

    // MARK: - Session params

    @Test func sessionCreateParamsKeysAndOptionality() throws {
        let full = SessionCreateParams(
            name: "n", filepaths: ["/u/a.jpg"], source: "local",
            sourcePath: "/u", truncatedImport: true
        )
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(
            Set(fullKeys) == Set(["name", "filepaths", "source", "sourcePath", "truncatedImport"])
        )

        let minimal = SessionCreateParams(name: "n")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["name"], "未设置的 TS 可选字段必须省略")
    }

    @Test func sessionCreateFromDirectoryParams() throws {
        let params = SessionCreateFromDirectoryParams(sourcePath: "/Users/me/Documents")
        let keys = try jsonKeys(of: JSONEncoder().encode(params))
        #expect(Set(keys) == ["sourcePath"])
    }

    @Test func sessionParamsRoundTrip() throws {
        let params = SessionAddPhotosParams(
            sessionId: "s1", filepaths: ["/u/1.jpg", "/u/2.jpg"], source: "capture-one"
        )
        let data = try JSONEncoder().encode(params)
        #expect(try JSONDecoder().decode(SessionAddPhotosParams.self, from: data) == params)
    }

    // MARK: - ResponseOk / ResponseErr

    @Test func responseOkRoundTripAndForcesTrue() throws {
        let session = SessionData(
            id: "s1", name: "n", status: .review, photoCount: 1,
            analysisStatus: .done, writebackStatus: .done,
            importSource: "manual", sourcePath: "/u", failedWritebackCount: 0,
            truncatedImport: false, createdAt: "t", updatedAt: "t"
        )
        let original = ResponseOk(id: .string("r1"), data: session)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseOk<SessionData>.self, from: data)
        #expect(decoded == original)
        #expect(decoded.ok)

        let keys = try jsonKeys(of: data)
        #expect(keys.contains("ok"))
        #expect(keys.contains("data"))
        #expect(keys.contains("id"))
    }

    @Test func responseOkRejectsOkFalse() {
        let json = #"{"id":1,"ok":false,"data":{"x":1}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ResponseOk<[String: Int]>.self, from: Data(json.utf8))
        }
    }

    @Test func responseErrStringCode() throws {
        let original = ResponseErr(error: .code("SESSION_NOT_FOUND"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseErr.self, from: data)
        #expect(decoded == original)
        #expect(!decoded.ok)
        #expect(decoded.error == .code("SESSION_NOT_FOUND"))

        let keys = try jsonKeys(of: data)
        #expect(Set(keys) == ["ok", "error"])
    }

    @Test func responseErrDetailWithParams() throws {
        let original = ResponseErr(
            id: .number(7),
            error: .detail(ErrorDetail(
                type: "ValidationError",
                message: "SESSION_NOT_FOUND",
                params: ["revision": .number(3), "extra": .string("x")]
            ))
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseErr.self, from: data)
        #expect(decoded == original)
    }

    @Test func responseUnionDecodesBothVariants() throws {
        let okJSON = #"{"ok":true,"data":{"ok":false}}"#
        let okResponse = try JSONDecoder().decode(Response<[String: Bool]>.self, from: Data(okJSON.utf8))
        if case .ok = okResponse {
            // ok
        } else {
            Issue.record("ok:true 应解码为 .ok")
        }

        let errJSON = #"{"ok":false,"error":"SESSION_NOT_FOUND"}"#
        let errResponse = try JSONDecoder().decode(Response<[String: Bool]>.self, from: Data(errJSON.utf8))
        if case .err(let err) = errResponse {
            #expect(err.error == .code("SESSION_NOT_FOUND"))
        } else {
            Issue.record("ok:false 应解码为 .err")
        }
    }

    @Test func responseIDNumberAndString() throws {
        let number = try JSONDecoder().decode(ResponseID.self, from: Data("42".utf8))
        #expect(number == .number(42))
        let string = try JSONDecoder().decode(ResponseID.self, from: Data(#""abc""#.utf8))
        #expect(string == .string("abc"))
    }

    // MARK: - 状态枚举

    @Test func sessionStatusRawValuesMatchTS() {
        let cases: [(SessionStatus, String)] = [
            (.draft, "draft"),
            (.photosLoaded, "photos_loaded"),
            (.analyzing, "analyzing"),
            (.review, "review"),
            (.completed, "completed"),
        ]
        for (status, raw) in cases {
            #expect(status.rawValue == raw)
        }
    }

    // MARK: - GatherErrorCode

    @Test func gatherErrorCodeCountIsPinned() {
        // TS 参考实现（packages/shared/src/errors.ts）已随原生迁移删除，156 项
        // 是其历史清单。原生新增 7 个侧车文档故障码（XMP_DOCUMENT_CORRUPT /
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
        // → 177。增删错误码时必须同步此断言与 GatherLocalization.errorMessages。
        #expect(GatherErrorCode.allCases.count == 177)
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
