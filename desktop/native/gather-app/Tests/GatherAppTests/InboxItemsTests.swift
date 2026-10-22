// SessionControlView Action Inbox 推导单测：对齐 workspace-view.test.ts
// deriveInboxItems（固定优先级 7 类、全部健康为空、scan_incomplete 置顶、
// 失败任务 ≤3 行截断、export_pending 条件）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

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
        // Cut 4 / 4b-2f：文案由**显式传入**的 L10n 解析（含「人脸」等断言），
        // 不读进程全局语言。
        SessionControlView(
            workspace: makeTestControlWorkspace(),
            culling: B8CullingAPIStub()
        )
        .inboxItems(status, truncatedImport: truncated, with: L10n(language: .zhCN))
    }

    private func view() -> SessionControlView {
        SessionControlView(
            workspace: makeTestControlWorkspace(),
            culling: B8CullingAPIStub()
        )
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

    @Test("分析过期：全部人脸 → 直达人脸分析步骤；含相似度 → 跳相似度")
    func staleAnalysisNavigation() {
        let faceOnly = status(stale: [.face])
        // D10：只切到人脸页不够——用户还得自己找分析入口（有缓存时还会回到上次步骤）。
        #expect(items(faceOnly).first(where: { $0.kind == .analysisStale })?.action == .reviewStaleAnalysis)
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

    @Test("D10：待办动作必须携带「要处理的问题」，不只是目标页")
    func todoActionsCarryIntent() {
        // 冲突待办：走专用动作（进入挑片 + 只看冲突），而不是普通跳页。
        // 旧实现 action == .navigateTab(.culling)：用户到达普通挑片页，还得自己找冲突。
        let conflict = items(status(conflict: 3)).first { $0.kind == .xmpConflict }
        #expect(conflict?.action == .reviewXmpConflicts)

        // 导出待办：带 picks 范围意图（N05，已有的同型契约）。
        let culled = items(status(culled: true)).first { $0.kind == .exportPending }
        #expect(culled?.action == .navigateTab(.export))

        // 离线照片：进入图库并只看离线（旧实现只是普通进图库，用户看不到离线照片）。
        let offline = items(status(offlinePhotos: 2)).first { $0.kind == .offlinePhotos }
        #expect(offline?.action == .reviewOfflinePhotos)
    }

    // 4b-2f：裸 View 上没有 languageStore env——en 断言证明语言由显式 L10n 决定，
    // 而不是进程全局 / .zhCN 兜底。jobTypeLabel 的类型名同样经 l10n 解析。
    @Test("显式 L10n：en 文案（含 jobTypeLabel 类型名）")
    func englishLabels() {
        let en = L10n(language: .en)
        let s = status(
            pending: 2,
            conflict: 3,
            failedJobs: [failedJob("j1", type: "similarity.analyze")]
        )
        let items = view().inboxItems(s, truncatedImport: false, with: en)
        #expect(items.first { $0.kind == .xmpConflict }?.label == "3 XMP conflicts awaiting resolution")
        #expect(items.first { $0.kind == .xmpPending }?.label == "2 XMP files pending write")
        #expect(items.first { $0.kind == .jobFailed }?.label == "Similarity Analysis task failed")
        #expect(items.first { $0.kind == .xmpConflict }?.actionLabel == "Resolve One by One")
    }
}
