// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/QualityContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/quality.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct QualityContractTests {

    // MARK: - Params

    @Test func qualityParamsKeysAndOptionality() throws {
        let fullAnalyze = QualityAnalyzeParams(sessionId: "s1", photoIds: ["p1", "p2"])
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(fullAnalyze))) == ["sessionId", "photoIds"])

        let minimalAnalyze = QualityAnalyzeParams(sessionId: "s1")
        #expect(Set(try jsonKeys(of: JSONEncoder().encode(minimalAnalyze))) == ["sessionId"], "TS photoIds? 未设置时必须省略")

        let fullGet = QualityGetParams(sessionId: "s1", photoIds: ["p1"])
        #expect(try JSONDecoder().decode(QualityGetParams.self, from: JSONEncoder().encode(fullGet)) == fullGet)
    }

    // MARK: - QualityResult

    @Test func qualityResultStatusRawValuesMatchTS() {
        let cases: [(QualityResultStatus, String)] = [
            (.succeeded, "succeeded"), (.failed, "failed"),
        ]
        for (status, raw) in cases {
            #expect(status.rawValue == raw)
        }
    }

    @Test func qualityResultRoundTripAndKeys() throws {
        let original = QualityResult(
            photoId: "p1",
            assetFileId: "af_1",
            status: .succeeded,
            errorMessage: "",
            qualityScore: 0.86,
            sharpness: 0.72,
            exposure: 0.65,
            subjectSharpness: 0.8,
            faceQuality: 0.9,
            closedEyeRisk: 0.01,
            closedEyeProbability: 0.02,
            confidence: 0.95,
            relativeRank: 3,
            warnings: ["低光照"],
            modelId: "m1",
            modelVersion: "v1",
            inputFingerprint: "fp",
            updatedAt: "2025-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QualityResult.self, from: data)
        #expect(decoded == original)

        let expected = [
            "photoId", "assetFileId", "status", "errorMessage", "qualityScore", "sharpness",
            "exposure", "subjectSharpness", "faceQuality", "closedEyeRisk",
            "closedEyeProbability", "confidence", "relativeRank", "warnings",
            "modelId", "modelVersion", "inputFingerprint", "updatedAt",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "QualityResult JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("quality_score"))
        #expect(!Set(try jsonKeys(of: data)).contains("closed_eye_risk"))
    }

    @Test func qualityResultOptionalsOmittedWhenNil() throws {
        let minimal = QualityResult(
            photoId: "p1", status: .failed, errorMessage: "MODEL_EXTRACT_FAILED",
            qualityScore: 0, sharpness: 0, exposure: 0, warnings: [],
            modelId: "", modelVersion: "", inputFingerprint: "", updatedAt: "t"
        )
        let keys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(!keys.contains("assetFileId"))
        #expect(!keys.contains("subjectSharpness"))
        #expect(!keys.contains("faceQuality"))
        #expect(!keys.contains("closedEyeRisk"))
        #expect(!keys.contains("closedEyeProbability"))
        #expect(!keys.contains("confidence"))
        #expect(!keys.contains("relativeRank"))
        #expect(keys.contains("errorMessage"), "显式设置的 errorMessage 必须输出")
    }

    @Test func qualityResultDecodesStatusRawValues() throws {
        let json = #"{"photoId":"p1","status":"failed","qualityScore":0,"sharpness":0,"exposure":0,"warnings":[],"modelId":"","modelVersion":"","inputFingerprint":"","updatedAt":"t"}"#
        let decoded = try JSONDecoder().decode(QualityResult.self, from: Data(json.utf8))
        #expect(decoded.status == .failed)
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
