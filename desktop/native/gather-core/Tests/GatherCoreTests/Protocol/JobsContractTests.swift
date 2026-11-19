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
            (.metadataScan, "metadata.scan"), (.thumbnailBuild, "thumbnail.build"),
            (.similarityAnalyze, "similarity.analyze"), (.duplicateScan, "duplicate.scan"),
            (.faceAnalyze, "face.analyze"), (.qualityScore, "quality.score"),
            (.outputRun, "output.run"), (.checksumBackfill, "checksum.backfill"),
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

    // MARK: - DTO 往返 + key 冻结（P2：逐样本合并，含可选字段省略）

    @Test("Jobs 契约 DTO：JSON 往返稳定 + camelCase key 冻结")
    func jobsDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(AnalysisJobData(
            id: "job_1", type: .metadataScan, scopeType: "session", scopeId: "s1",
            dedupeKey: "metadata.scan:s1", status: .running, priority: 10,
            progressCurrent: 42, progressTotal: 120, progressMessage: "",
            inputFingerprint: "fp_1", modelId: "", modelVersion: "",
            checkpoint: ["index_seq": .number(7), "notes": .null],
            attemptCount: 1, leaseOwner: "main", heartbeatAt: "2025-01-01T00:00:00Z",
            errorCode: "", errorMessage: "",
            createdAt: "2025-01-01T00:00:00Z", startedAt: "2025-01-01T00:00:01Z",
            finishedAt: "2025-01-01T00:00:02Z", updatedAt: "2025-01-01T00:00:03Z"),
            keys: [
                "id", "type", "scopeType", "scopeId", "dedupeKey", "status", "priority",
                "progressCurrent", "progressTotal", "progressMessage", "inputFingerprint",
                "modelId", "modelVersion", "checkpoint", "attemptCount", "leaseOwner",
                "heartbeatAt", "errorCode", "errorMessage", "createdAt", "startedAt",
                "finishedAt", "updatedAt",
            ],
            forbiddenKeys: ["progress_current"]
        ) { decoded in
            #expect(decoded.checkpoint["index_seq"] == .number(7))
        }
        try assertRoundTrip(JobProgressUpdate(
            current: 10, total: 100, phase: "index.scanning", message: "",
            checkpoint: ["rowid": .number(99)]),
            keys: ["current", "total", "phase", "message", "checkpoint"])
        // JobCreateParams：全量/缺省两组键集合，以及 JobProgressUpdate 全可选为空对象。
        try assertJSONKeys(JobCreateParams(
            type: .similarityAnalyze, scopeType: "session", scopeId: "s1",
            dedupeKey: "similarity.analyze:s1", priority: 5,
            inputFingerprint: "fp", modelId: "m", modelVersion: "v1",
            checkpoint: ["threshold": .number(0.8)]),
            keys: ["type", "scopeType", "scopeId", "dedupeKey", "priority",
                   "inputFingerprint", "modelId", "modelVersion", "checkpoint"],
            name: "JobCreateParams(全量)")
        try assertJSONKeys(JobCreateParams(type: .metadataScan, scopeType: "session", scopeId: "s1",
                                           dedupeKey: "d"),
                           keys: ["type", "scopeType", "scopeId", "dedupeKey"],
                           name: "JobCreateParams(缺省)")
        try assertJSONKeys(JobProgressUpdate(), keys: [], name: "JobProgressUpdate(空)")
    }
}
