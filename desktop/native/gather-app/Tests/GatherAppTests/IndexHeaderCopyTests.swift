// SessionControlView 索引进度头推导单测：对齐 tests/unit/renderer/index-progress.test.ts
// 全部用例（扫描中…/实时进度含百分比/取整/上限 100/失败/精确计数/≥ 前缀规则）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@MainActor
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
        // 文案在 AppLanguageLock 内以 zh-CN 生成：否则并行套件临时切到 en
        // （或系统语言为 en）时会与下面的中文断言不一致（既有 flake 根因）。
        AppLanguageLock.withCopy("zh-CN") {
            SessionControlView(
                sessionId: "s1",
                router: StubCommandRouter.empty()
            ).indexHeaderCopy(status, session: session)
        }
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

    // 原 3 条用例（实时进度含文案 / 向下取整 / 上限 100）：同一换算仅输入不同。
    // 断言等值保留；`Int(c.percent!.rounded())` 改写为 map 形式，失败时给断言
    // 而不是崩溃（非 nil 仍由下一行的 #expect 保证）。
    @Test("百分比换算：实时进度文案 / round / 上限 100", arguments: [
        (12547, 12847, 97.7, 98, "正在索引 12547 / 12847" as String?),
        (1, 3, 33.3, 33, nil as String?),
        (5, 2, 250, 100, nil as String?),
    ])
    private func percentMatrix(
        done: Int, total: Int, percent: Double, expectedRounded: Int, expectedText: String?
    ) {
        let c = copy(
            status(indexing: indexing(.active, total: total, done: done, percent: percent)),
            session(photoCount: 0))
        #expect(c.mode == .scanning)
        #expect(c.percent != nil)
        #expect(c.percent.map { Int($0.rounded()) } == expectedRounded)
        if let expectedText { #expect(c.text == expectedText) }
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

    // created 窗口（一跳化导入）：即使 photoCount 为 0（或已有计数但索引未开始），
    // 也必须报「扫描中…」，不得退化成「暂无照片」/计数文案。
    // 守卫此窗口的是本用例：删掉 indexHeaderCopy 的 `status.stage == .created`
    // 分支后本用例变红（Gallery 侧同窗口另有 createdWindowScanning 对账）。
    @Test("created 窗口（一跳化导入）→ 扫描中…，优先于计数分支")
    func createdWindowIsScanning() {
        let zero = copy(status(stage: .created, indexing: indexing(.idle)), session(photoCount: 0))
        #expect(zero.mode == .scanning)
        #expect(zero.text == "扫描中…")
        #expect(zero.percent == nil)

        let counted = copy(status(stage: .created, indexing: indexing(.idle)), session(photoCount: 12))
        #expect(counted.mode == .scanning)
        #expect(counted.text == "扫描中…")
    }

    // 原 3 条用例（截断已索引 / 截断未索引 / 非截断）：同一计数文案仅输入不同。
    @Test("计数文案：精确计数 / 截断保留 ≥", arguments: [
        (WorkspaceStage.indexed, 12847, true, "已索引 12847 张照片"),
        (WorkspaceStage.imported, 50000, true, "已索引 ≥50000 张照片"),
        (WorkspaceStage.imported, 12, false, "已索引 12 张照片"),
    ])
    private func countCopyMatrix(
        stage: WorkspaceStage, photoCount: Int, truncatedImport: Bool, expectedText: String
    ) {
        let c = copy(
            status(stage: stage, indexing: indexing(.idle)),
            session(photoCount: photoCount, truncatedImport: truncatedImport))
        #expect(c.mode == .count)
        #expect(c.text == expectedText)
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
        AppLanguageLock.withCopy("zh-CN") {
            GalleryViewModel.indexHeaderCopy(
                status: status,
                photoCount: photoCount,
                truncatedImport: truncatedImport
            )
        }
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

    // 扫描已开始但尚无进度帧（total 已知、done == 0）：仍显示「扫描中…」，
    // 不得内联「正在索引 0 / N（0%）」占位文案与 0% 进度条。
    // 去掉 `status.indexing.done > 0` 守卫后本用例变红。
    @Test("active 且 total>0、done==0 → 扫描中…（不显示 0% 进度）")
    func activeTotalKnownButNoProgressYet() {
        let c = copy(status(indexing: indexing(.active, total: 500, done: 0)), photoCount: 0)
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

    // 原 3 条用例（内联文案 / 向下取整 / 上限 100）：同一换算仅输入不同。
    @Test("百分比换算：内联文案 / round / 上限 100", arguments: [
        (12547, 12847, 98, "正在索引 12547 / 12847（98%）" as String?),
        (1, 3, 33, nil as String?),
        (5, 2, 100, nil as String?),
    ])
    private func inlinePercentMatrix(
        done: Int, total: Int, expectedPercent: Int, expectedText: String?
    ) {
        let c = copy(status(indexing: indexing(.active, total: total, done: done)), photoCount: 0)
        #expect(c?.kind == .scanning)
        #expect(c?.percent == expectedPercent)
        if let expectedText { #expect(c?.text == expectedText) }
    }

    @Test("失败 → 索引失败（视图附重试按钮）")
    func failedJob() {
        let c = copy(status(indexing: indexing(.failed)), photoCount: 12)
        #expect(c?.kind == .error)
        #expect(c?.text == "索引失败")
        #expect(c?.percent == nil)
    }

    // 原 3 条用例（截断已索引 / 截断未索引 / 非截断）：同一计数文案仅输入不同。
    // 三条都补上 `percent == nil`（原本只有第一条有），断言只增不减。
    @Test("计数文案：精确计数 / 截断保留 ≥", arguments: [
        (WorkspaceStage.indexed, 12847, true, "已索引 12847 张照片"),
        (WorkspaceStage.imported, 50000, true, "已索引 ≥50000 张照片"),
        (WorkspaceStage.imported, 12, false, "已索引 12 张照片"),
    ])
    private func countCopyMatrix(
        stage: WorkspaceStage, photoCount: Int, truncatedImport: Bool, expectedText: String
    ) {
        let c = copy(status(stage: stage, indexing: indexing(.idle)),
                     photoCount: photoCount, truncatedImport: truncatedImport)
        #expect(c?.kind == .count)
        #expect(c?.text == expectedText)
        #expect(c?.percent == nil)
    }
}
