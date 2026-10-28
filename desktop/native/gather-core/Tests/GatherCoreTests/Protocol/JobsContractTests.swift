// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JobsContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/jobs.ts。

import Foundation
import Testing
@testable import GatherProtocol

struct JobsContractTests {

    // MARK: - Enums

    @Test func analysisJobTypeRawValuesMatchTS() {
        let cases: [(AnalysisJobType, String)] = [
            (.metadataScan, "metadata.scan"),
            (.thumbnailBuild, "thumbnail.build"),
            (.similarityAnalyze, "similarity.analyze"),
            (.duplicateScan, "duplicate.scan"),
            (.faceAnalyze, "face.analyze"),
            (.qualityScore, "quality.score"),
            (.outputRun, "output.run"),
            (.checksumBackfill, "checksum.backfill"),
        ]
        for (type, raw) in cases {
            #expect(type.rawValue == raw)
        }
    }

    @Test func analysisJobStatusRawValuesMatchTS() {
        let cases: [(AnalysisJobStatus, String)] = [
            (.queued, "queued"), (.running, "running"), (.succeeded, "succeeded"),
            (.failed, "failed"), (.cancelled, "cancelled"), (.interrupted, "interrupted"),
            (.cancelling, "cancelling"),
        ]
        for (status, raw) in cases {
            #expect(status.rawValue == raw)
        }
    }

    @Test func analysisJobTypeDecodesFromTSStrings() throws {
        #expect(try JSONDecoder().decode(AnalysisJobType.self, from: Data(#""checksum.backfill""#.utf8)) == .checksumBackfill)
    }

    // MARK: - AnalysisJobData

    @Test func analysisJobDataRoundTripAndKeys() throws {
        let original = AnalysisJobData(
            id: "job_1",
            type: .metadataScan,
            scopeType: "session",
            scopeId: "s1",
            dedupeKey: "metadata.scan:s1",
            status: .running,
            priority: 10,
            progressCurrent: 42,
            progressTotal: 120,
            progressMessage: "",
            inputFingerprint: "fp_1",
            modelId: "",
            modelVersion: "",
            checkpoint: ["index_seq": .number(7), "notes": .null],
            attemptCount: 1,
            leaseOwner: "main",
            heartbeatAt: "2025-01-01T00:00:00Z",
            errorCode: "",
            errorMessage: "",
            createdAt: "2025-01-01T00:00:00Z",
            startedAt: "2025-01-01T00:00:01Z",
            finishedAt: "2025-01-01T00:00:02Z",
            updatedAt: "2025-01-01T00:00:03Z"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnalysisJobData.self, from: data)
        #expect(decoded == original)
        #expect(decoded.checkpoint["index_seq"] == .number(7))

        let expected = [
            "id", "type", "scopeType", "scopeId", "dedupeKey", "status", "priority",
            "progressCurrent", "progressTotal", "progressMessage", "inputFingerprint",
            "modelId", "modelVersion", "checkpoint", "attemptCount", "leaseOwner",
            "heartbeatAt", "errorCode", "errorMessage", "createdAt", "startedAt",
            "finishedAt", "updatedAt",
        ]
        #expect(Set(try jsonKeys(of: data)) == Set(expected), "AnalysisJobData JSON key 必须与 TS 字段名一致")
        #expect(!Set(try jsonKeys(of: data)).contains("progress_current"))
    }

    // MARK: - JobCreateParams

    @Test func jobCreateParamsKeysAndOptionality() throws {
        let full = JobCreateParams(
            type: .similarityAnalyze, scopeType: "session", scopeId: "s1",
            dedupeKey: "similarity.analyze:s1", priority: 5,
            inputFingerprint: "fp", modelId: "m", modelVersion: "v1",
            checkpoint: ["threshold": .number(0.8)]
        )
        let fullKeys = try jsonKeys(of: JSONEncoder().encode(full))
        #expect(
            Set(fullKeys) == [
                "type", "scopeType", "scopeId", "dedupeKey", "priority",
                "inputFingerprint", "modelId", "modelVersion", "checkpoint",
            ]
        )

        let minimal = JobCreateParams(type: .metadataScan, scopeType: "session", scopeId: "s1", dedupeKey: "d")
        let minimalKeys = try jsonKeys(of: JSONEncoder().encode(minimal))
        #expect(Set(minimalKeys) == ["type", "scopeType", "scopeId", "dedupeKey"])
    }
    // MARK: - JobProgressUpdate

    @Test func jobProgressUpdateRoundTripAndKeys() throws {
        let original = JobProgressUpdate(
            current: 10, total: 100, phase: "index.scanning", message: "",
            checkpoint: ["rowid": .number(99)]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(JobProgressUpdate.self, from: data) == original)
        #expect(Set(try jsonKeys(of: data)) == ["current", "total", "phase", "message", "checkpoint"])
    }

    @Test func jobProgressUpdateEmptyEncodesEmptyObject() throws {
        let empty = JobProgressUpdate()
        let keys = try jsonKeys(of: JSONEncoder().encode(empty))
        #expect(keys.isEmpty, "全可选字段未设置时编码为 {}")
    }
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
