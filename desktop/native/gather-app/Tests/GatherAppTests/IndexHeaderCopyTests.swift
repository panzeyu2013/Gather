// SessionControlView 索引进度头推导单测：对齐 tests/unit/renderer/index-progress.test.ts
// 全部用例（扫描中…/实时进度含百分比/取整/上限 100/失败/精确计数/≥ 前缀规则）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("IndexHeaderCopy 推导（对齐 index-progress.test.ts）")
struct IndexHeaderCopyTests {
    private func status(
        stage: WorkspaceStage = .imported,
        indexing: WorkspaceIndexingProgress
    ) -> WorkspaceStatus {
        WorkspaceStatus(
            sessionId: "s1",
            stage: stage,
            softFlags: WorkspaceSoftFlags(culled: false, exported: false),
            indexing: indexing,
            staleAnalyses: [],
            xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 0,
            failedJobs: [],
            recommendedNext: nil,
            generatedAt: ""
        )
    }

    private func indexing(
        _ s: WorkspaceIndexingStatus, total: Int = 0, done: Int = 0, percent: Double = 0
    ) -> WorkspaceIndexingProgress {
        WorkspaceIndexingProgress(total: total, done: done, percent: percent, status: s)
    }

    private func session(photoCount: Int, truncatedImport: Bool = false) -> SessionData {
        SessionData(
            id: "s1", name: "测试", status: .photosLoaded, photoCount: photoCount,
            analysisStatus: .idle, writebackStatus: .idle, importSource: "local",
            sourcePath: "", failedWritebackCount: 0, truncatedImport: truncatedImport,
            createdAt: "", updatedAt: "")
    }

    /// 通过 SessionControlView 实例调用（推导为实例方法，参数化后与 session 解耦）。
    private func copy(_ status: WorkspaceStatus, _ session: SessionData?) -> IndexHeaderCopy {
        SessionControlView(
            sessionId: "s1",
            commands: .testEmpty()
        ).indexHeaderCopy(status, session: session)
    }

    @Test("无任务且无计数 → 暂无照片（旧版 null 的 Swift 等价）")
    func noJobNoCount() {
        let c = copy(status(indexing: indexing(.idle)), session(photoCount: 0))
        #expect(c.mode == .count)
        #expect(c.text == "暂无照片")
    }

    @Test("排队/运行且无数值 → 扫描中…")
    func queuedNoNumbers() {
        let c1 = copy(status(indexing: indexing(.active)), session(photoCount: 0))
        #expect(c1.mode == .scanning)
        #expect(c1.text == "扫描中…")
        #expect(c1.percent == nil)
    }

    @Test("运行中且有数值 → 实时进度 + 百分比")
    func liveProgressWithPercent() {
        let c = copy(
            status(indexing: indexing(.active, total: 12847, done: 12547, percent: 97.7)),
            session(photoCount: 0))
        #expect(c.mode == .scanning)
        #expect(c.text == "正在索引 12547 / 12847")
        #expect(c.percent != nil)
        #expect(Int(c.percent!.rounded()) == 98)
    }

    @Test("百分比向下取整（旧版 round）")
    func percentRounding() {
        let c = copy(
            status(indexing: indexing(.active, total: 3, done: 1, percent: 33.3)),
            session(photoCount: 0))
        #expect(Int(c.percent!.rounded()) == 33)
    }

    @Test("百分比上限 100")
    func percentClamped() {
        let c = copy(
            status(indexing: indexing(.active, total: 2, done: 5, percent: 250)),
            session(photoCount: 0))
        #expect(Int(c.percent!.rounded()) == 100)
    }

    @Test("失败 → 索引失败")
    func failedJob() {
        let c = copy(
            status(indexing: indexing(.failed, total: 100, done: 100)),
            session(photoCount: 0))
        #expect(c.mode == .error)
        #expect(c.text == "索引失败")
        #expect(c.percent == nil)
    }

    @Test("截断导入索引完成 → 精确计数（去掉 ≥）")
    func truncatedSucceededExact() {
        let c = copy(
            status(stage: .indexed, indexing: indexing(.idle)),
            session(photoCount: 12847, truncatedImport: true))
        #expect(c.mode == .count)
        #expect(c.text == "已索引 12847 张照片")
    }

    @Test("截断导入未索引完成 → 保留 ≥")
    func truncatedUnknownKeepsGE() {
        let c = copy(
            status(stage: .imported, indexing: indexing(.idle)),
            session(photoCount: 50000, truncatedImport: true))
        #expect(c.mode == .count)
        #expect(c.text == "已索引 ≥50000 张照片")
    }

    @Test("非截断会话无任务 → 精确计数")
    func nonTruncatedExact() {
        let c = copy(
            status(indexing: indexing(.idle)),
            session(photoCount: 12))
        #expect(c.mode == .count)
        #expect(c.text == "已索引 12 张照片")
    }
}

// MARK: - Gallery 索引头推导（对齐 indexProgress.ts deriveIndexHeaderCopy:32-63
// + workspace-view.ts deriveWorkspaceHeaderCopy:289-322；GalleryViewModel 纯函数）

@Suite("GalleryIndexHeaderCopy 推导（deriveIndexHeaderCopy 语义）")
struct GalleryIndexHeaderCopyTests {
    private func status(
        stage: WorkspaceStage = .imported,
        indexing: WorkspaceIndexingProgress
    ) -> WorkspaceStatus {
        WorkspaceStatus(
            sessionId: "s1",
            stage: stage,
            softFlags: WorkspaceSoftFlags(culled: false, exported: false),
            indexing: indexing,
            staleAnalyses: [],
            xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
            offlinePhotos: 0,
            failedJobs: [],
            recommendedNext: nil,
            generatedAt: ""
        )
    }

    private func indexing(
        _ s: WorkspaceIndexingStatus, total: Int = 0, done: Int = 0
    ) -> WorkspaceIndexingProgress {
        WorkspaceIndexingProgress(total: total, done: done, percent: 0, status: s)
    }

    private func copy(
        _ status: WorkspaceStatus?,
        photoCount: Int,
        truncatedImport: Bool = false
    ) -> GalleryIndexHeaderCopy? {
        GalleryViewModel.indexHeaderCopy(
            status: status,
            photoCount: photoCount,
            truncatedImport: truncatedImport
        )
    }

    @Test("无任务且无计数 → 不渲染（nil，而非「暂无照片」）")
    func noJobNoCountRendersNothing() {
        #expect(copy(nil, photoCount: 0) == nil)
        #expect(copy(status(indexing: indexing(.idle)), photoCount: 0) == nil)
    }

    @Test("排队/运行且无数值 → 扫描中…（无进度条）")
    func activeZeroZeroScanningEllipsis() {
        let c = copy(status(indexing: indexing(.active)), photoCount: 0)
        #expect(c?.kind == .scanning)
        #expect(c?.text == "扫描中…")
        #expect(c?.percent == nil)
    }

    @Test("created 窗口（一跳化导入）→ 扫描中…")
    func createdWindowScanning() {
        let c = copy(status(stage: .created, indexing: indexing(.idle)), photoCount: 0)
        #expect(c?.kind == .scanning)
        #expect(c?.text == "扫描中…")
        #expect(c?.percent == nil)
    }

    @Test("运行中有数值 → 文案内联百分比（自算 round，12547/12847 → 98%）")
    func liveInlinePercent() {
        let c = copy(
            status(indexing: indexing(.active, total: 12847, done: 12547)),
            photoCount: 0)
        #expect(c?.kind == .scanning)
        #expect(c?.text == "正在索引 12547 / 12847（98%）")
        #expect(c?.percent == 98)
    }

    @Test("百分比向下取整（旧版 round 语义）")
    func percentRounds() {
        let c = copy(
            status(indexing: indexing(.active, total: 3, done: 1)),
            photoCount: 0)
        #expect(c?.percent == 33)
    }

    @Test("百分比上限 100")
    func percentClamped() {
        let c = copy(
            status(indexing: indexing(.active, total: 2, done: 5)),
            photoCount: 0)
        #expect(c?.percent == 100)
    }

    @Test("失败 → 索引失败（视图附重试按钮）")
    func failedJob() {
        let c = copy(status(indexing: indexing(.failed)), photoCount: 12)
        #expect(c?.kind == .error)
        #expect(c?.text == "索引失败")
        #expect(c?.percent == nil)
    }

    @Test("索引成功（stage indexed）→ 精确计数（截断导入也去 ≥）")
    func succeededExact() {
        let c = copy(
            status(stage: .indexed, indexing: indexing(.idle)),
            photoCount: 12847, truncatedImport: true)
        #expect(c?.kind == .count)
        #expect(c?.text == "已索引 12847 张照片")
        #expect(c?.percent == nil)
    }

    @Test("截断导入未索引完成 → 保留 ≥")
    func truncatedUnknownKeepsGE() {
        let c = copy(
            status(stage: .imported, indexing: indexing(.idle)),
            photoCount: 50000, truncatedImport: true)
        #expect(c?.kind == .count)
        #expect(c?.text == "已索引 ≥50000 张照片")
    }

    @Test("非截断会话无任务 → 精确计数")
    func nonTruncatedExact() {
        let c = copy(status(indexing: indexing(.idle)), photoCount: 12)
        #expect(c?.kind == .count)
        #expect(c?.text == "已索引 12 张照片")
    }
}
