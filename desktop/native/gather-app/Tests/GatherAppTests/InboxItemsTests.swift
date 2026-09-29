// SessionControlView Action Inbox 推导单测：对齐 workspace-view.test.ts
// deriveInboxItems（固定优先级 7 类、全部健康为空、scan_incomplete 置顶、
// 失败任务 ≤3 行截断、export_pending 条件）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@MainActor
@Suite("deriveInboxItems（对齐 workspace-view.test.ts）")
struct InboxItemsTests {
    private func status(
        stage: WorkspaceStage = .analyzed,
        indexing: WorkspaceIndexingStatus = .idle,
        pending: Int = 0,
        conflict: Int = 0,
        stale: [WorkspaceStaleAnalysisKind] = [],
        offlinePhotos: Int = 0,
        failedJobs: [WorkspaceFailedJob] = [],
        culled: Bool = false,
        exported: Bool = false
    ) -> WorkspaceStatus {
        WorkspaceStatus(
            sessionId: "s1",
            stage: stage,
            softFlags: WorkspaceSoftFlags(culled: culled, exported: exported),
            indexing: WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: indexing),
            staleAnalyses: stale.map {
                WorkspaceStaleAnalysis(kind: $0, lastRunAt: "2026-01-01T00:00:00.000Z")
            },
            xmp: WorkspaceXmpCounts(pending: pending, conflict: conflict),
            offlinePhotos: offlinePhotos,
            failedJobs: failedJobs,
            recommendedNext: nil,
            generatedAt: ""
        )
    }

    private func failedJob(_ id: String, type: String = "similarity.analyze", code: String = "worker_error") -> WorkspaceFailedJob {
        WorkspaceFailedJob(id: id, type: type, code: code, message: "timeout")
    }

    private func items(_ status: WorkspaceStatus, truncated: Bool = false) -> [InboxItem] {
        // 文案经 l() 出当前语言：锁内钉死 zh-CN（含「人脸」等断言）。
        AppLanguageLock.withCopy("zh-CN") {
            SessionControlView(sessionId: "s1", router: StubCommandRouter.empty())
                .inboxItems(status, truncatedImport: truncated)
        }
    }

    @Test("全部健康 → 空")
    func healthyIsEmpty() {
        #expect(items(status()).isEmpty)
    }

    @Test("固定优先级排序，scan_incomplete 置顶")
    func priorityOrder() {
        let s = status(
            stage: .imported,
            indexing: .active,
            pending: 2,
            conflict: 3,
            stale: [.similarity],
            offlinePhotos: 4,
            failedJobs: [failedJob("j1"), failedJob("j2", type: "export.execute")],
            culled: true
        )
        let kinds = items(s).map(\.kind)
        #expect(kinds == [
            .scanIncomplete, .xmpConflict, .analysisStale, .xmpPending,
            .offlinePhotos, .jobFailed, .jobFailed, .exportPending,
        ])
    }

    @Test("截断导入未索引完成 → scan_incomplete（TS truncatedImport && stage==imported）")
    func truncatedImportTriggersScanIncomplete() {
        let s = status(stage: .imported)
        #expect(items(s, truncated: true).first?.kind == .scanIncomplete)
        // 已索引完成：不再提示。
        let indexed = status(stage: .indexed)
        #expect(items(indexed, truncated: true).isEmpty)
    }

    @Test("索引失败 → scan_incomplete")
    func failedIndexTriggersScanIncomplete() {
        let s = status(indexing: .failed)
        #expect(items(s).first?.kind == .scanIncomplete)
    }

    @Test("分析过期：全部人脸 → 跳人脸页；含相似度 → 跳相似度")
    func staleAnalysisNavigation() {
        let faceOnly = status(stale: [.face])
        #expect(items(faceOnly).first(where: { $0.kind == .analysisStale })?.action == .navigateTab(.faceKw))
        let mixed = status(stale: [.face, .similarity])
        #expect(items(mixed).first(where: { $0.kind == .analysisStale })?.action == .navigateSimilarity)
        #expect(items(mixed).first(where: { $0.kind == .analysisStale })?.label.contains("人脸") == true)
    }

    @Test("失败任务最多 3 行（TS MAX_FAILED_JOB_ROWS）")
    func failedJobsTruncated() {
        let many = (0..<5).map { failedJob("j\($0)") }
        let s = status(failedJobs: many)
        #expect(items(s).filter { $0.kind == .jobFailed }.count == 3)
    }

    @Test("已挑片但未导出 → export_pending；已导出则无")
    func exportPendingCondition() {
        let culled = items(status(culled: true))
        #expect(culled.contains { $0.kind == .exportPending })
        let exported = items(status(culled: true, exported: true))
        #expect(!exported.contains { $0.kind == .exportPending })
    }

    @Test("xmp 冲突/待写入计数入文案")
    func xmpCountsInLabels() {
        let s = status(pending: 2, conflict: 3)
        #expect(items(s).first(where: { $0.kind == .xmpConflict })?.label == "3 个 XMP 冲突待裁决")
        #expect(items(s).first(where: { $0.kind == .xmpPending })?.label == "2 个 XMP 待写入")
    }
}
