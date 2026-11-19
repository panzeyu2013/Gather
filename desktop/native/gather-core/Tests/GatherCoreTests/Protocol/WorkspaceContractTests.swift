// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/WorkspaceContractTests.swift
// 契约对账测试：Swift 侧构造的契约类型，其 Codable JSON key 必须与 TS 字段名（camelCase）
// 逐字一致；JSON 往返编解码必须稳定。TS 源: packages/shared/src/protocol/workspace.ts。
// 特别注意 TS `recommendedNext: WorkspaceRecommendedNext | null`：key 恒存在，nil 编码为 JSON null。

import Foundation
import Testing
@testable import GatherProtocol

struct WorkspaceContractTests {

    // MARK: - Enums

    @Test func workspaceEnumsRawValuesMatchTS() {
        let stages: [(WorkspaceStage, String)] = [
            (.created, "created"), (.imported, "imported"), (.indexed, "indexed"), (.analyzed, "analyzed"),
        ]
        for (stage, raw) in stages {
            #expect(stage.rawValue == raw)
        }
        let indexingStatuses: [(WorkspaceIndexingStatus, String)] = [
            (.idle, "idle"), (.active, "active"), (.failed, "failed"),
        ]
        for (status, raw) in indexingStatuses {
            #expect(status.rawValue == raw)
        }
        let kinds: [(WorkspaceStaleAnalysisKind, String)] = [
            (.similarity, "similarity"), (.face, "face"),
        ]
        for (kind, raw) in kinds {
            #expect(kind.rawValue == raw)
        }
    }

    // MARK: - 子结构（P2：合并为逐样本断言）

    @Test("Workspace 子结构：JSON 往返稳定 + camelCase key 冻结")
    func workspaceSubDTOsRoundTripAndKeys() throws {
        try assertRoundTrip(WorkspaceIndexingProgress(total: 100, done: 42, percent: 42.0, status: .active),
                            keys: ["total", "done", "percent", "status"])
        try assertRoundTrip(WorkspaceStaleAnalysis(kind: .similarity, lastRunAt: "2025-01-01T00:00:00Z"),
                            keys: ["kind", "lastRunAt"])
        try assertRoundTrip(WorkspaceXmpCounts(pending: 3, conflict: 1), keys: ["pending", "conflict"])
        try assertRoundTrip(WorkspaceFailedJob(id: "job_1", type: "metadata.scan",
                                               code: "SCAN_READ_FAILED", message: "E"),
                            keys: ["id", "type", "code", "message"])
        try assertRoundTrip(WorkspaceRecommendedNext(action: "index", target: "s1"),
                            keys: ["action", "target"])
    }

    // MARK: - WorkspaceStatus

    @Test func workspaceStatusRoundTripAndKeys() throws {
        try assertRoundTrip(WorkspaceStatus(
            sessionId: "s1", stage: .indexed,
            softFlags: WorkspaceSoftFlags(culled: true, exported: false),
            indexing: WorkspaceIndexingProgress(total: 100, done: 100, percent: 100.0, status: .idle),
            staleAnalyses: [WorkspaceStaleAnalysis(kind: .face, lastRunAt: "t")],
            xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 2, failedJobs: [],
            recommendedNext: WorkspaceRecommendedNext(action: "culling", target: "s1"),
            generatedAt: "2025-01-01T00:00:00Z"),
            keys: [
                "sessionId", "stage", "softFlags", "indexing", "staleAnalyses", "xmp",
                "offlinePhotos", "failedJobs", "recommendedNext", "generatedAt",
            ],
            forbiddenKeys: ["offline_photos", "stale_analyses"])
    }

    @Test func workspaceStatusRecommendedNextNullAlwaysEncoded() throws {
        let status = WorkspaceStatus(
            sessionId: "s1", stage: .analyzed,
            softFlags: WorkspaceSoftFlags(culled: true, exported: true),
            indexing: WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: .idle),
            staleAnalyses: [], xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 0, failedJobs: [], recommendedNext: nil, generatedAt: "t")
        let object = try jsonObject(of: JSONEncoder().encode(status))
        #expect(object["recommendedNext"] is NSNull, "TS recommendedNext: X | null —— nil 必须编码为 null 且 key 恒存在")
    }

    @Test func workspaceStatusRecommendedNextDecodesFromNull() throws {
        let json = #"{"sessionId":"s1","stage":"imported","softFlags":{"culled":false,"exported":false},"indexing":{"total":0,"done":0,"percent":0,"status":"idle"},"staleAnalyses":[],"xmp":{"pending":0,"conflict":0},"offlinePhotos":0,"failedJobs":[],"recommendedNext":null,"generatedAt":"t"}"#
        let decoded = try JSONDecoder().decode(WorkspaceStatus.self, from: Data(json.utf8))
        #expect(decoded.recommendedNext == nil)
        #expect(decoded.stage == .imported)
    }
}
