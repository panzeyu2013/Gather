// desktop/native/gather-app/Tests/GatherAppTests/CullingViewModelAPITests.swift
// Cut 1 / B3b：CullingViewModel 的 API 边界测试。
//
// 覆盖：
// - load 走 page/summary/groups/syncStatus/history 的 CullingAPI 方法，查询参数
//   （scope / limit=500 / history limit=500）与 reloadAckedAt 投影正确；
// - update/batchUpdate 构造 CullingUpdateInput/CullingBatchUpdateInput，应用返回
//   states、自动前进、history prepend，且 before 快照在 await 前采集；
// - undo 构造 CullingApplyHistoryInput 并标记 undone（redo 栈可用）；
// - reset/writeback/cleanup/finalizeSync/retryFailedWriteback 只从确认分支构造
//   Confirmed<T>，source 为用户弹窗；
// - GatherError 经 APIErrorPresentation 漏斗落到 errorMessage，不直出原始诊断；
// - navigation.* 已经由 NavigationAPI 承担（analyze 的 dryRun 透传）；
// - B8.2b：quality.analyze 走 QualityAPI、500ms 轮询走 JobAPI.list
//   （includeCheckpoint=false），取消走 JobAPI.cancel。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherTestSupport
@testable import GatherUI
@testable import GatherHost

// MARK: - 夹具

private func vmSyncSummary(
    sessionId: String = "s1",
    pending: Int = 0,
    writing: Int = 0,
    written: Int = 0,
    failed: Int = 0,
    conflict: Int = 0,
    synced: Int = 0
) -> MetadataSyncSummary {
    MetadataSyncSummary(
        sessionId: sessionId, pending: pending, writing: writing, written: written,
        failed: failed, conflict: conflict, synced: synced, items: []
    )
}

private func vmPhoto(_ id: String) -> PhotoData {
    PhotoData(
        id: id,
        sessionId: "s1",
        filepath: "/shoot/\(id).jpg",
        filename: "\(id).jpg",
        checksum: "",
        hasExistingXmp: false,
        faceCount: 0,
        width: 100,
        height: 100,
        metadata: [:],
        result: [:],
        status: "ready",
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func vmState(
    _ id: String,
    revision: Int = 1,
    pickState: PickState = .unreviewed,
    rating: Double = 0,
    colorLabel: CaptureOneColorLabel = .none
) -> AssetCullingState {
    AssetCullingState(
        photoId: id,
        pickState: pickState,
        rating: rating,
        colorLabel: colorLabel,
        source: .manual,
        revision: revision,
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func vmAsset(
    _ id: String,
    revision: Int = 1,
    pickState: PickState = .unreviewed,
    rating: Double = 0,
    colorLabel: CaptureOneColorLabel = .none,
    similarityGroupId: String? = nil
) -> CullingAsset {
    CullingAsset(
        photo: vmPhoto(id),
        state: vmState(
            id, revision: revision, pickState: pickState,
            rating: rating, colorLabel: colorLabel),
        xmpPath: "/shoot/\(id).xmp",
        syncStatus: .clean,
        people: [],
        keywords: [],
        similarityGroupId: similarityGroupId,
        linkedVariantCount: 1,
        faceBboxes: []
    )
}

private func vmPage(_ assets: [CullingAsset]) -> CullingPage {
    CullingPage(assets: assets, total: assets.count)
}

// MARK: - API 替身

private actor StubCullingAPI: CullingAPI {
    var pageResult = CullingPage(assets: [], total: 0)
    /// B3 恢复定位用：多页夹具（按请求顺序返回，最后一个反复返回）。
    /// 空队列 = 走 setPage 的单页结果（既有用例全部走这条，行为不变）。
    var pageResultsQueue: [CullingPage] = []
    var summaryResult = CullingSummary(
        totalGroups: 0, totalPhotos: 0, kept: 0, rejected: 0, pending: 0, rated: 0, labeled: 0
    )
    var groupsResult: [CullingGroup] = []
    var syncStatusResult = CullingSyncStatus(summary: vmSyncSummary())
    var historyResult: [CullingHistoryOperation] = []
    var updateResult = CullingUpdateResult(states: [], xmpPath: "", syncStatus: .clean)
    var batchUpdateResults: [CullingUpdateResult] = []
    var updateSelectionResult = CullingSelectionUpdateResult(requested: 0, applied: 0)
    var applyHistoryResults: [CullingUpdateResult] = []
    var decideGroupResults: [CullingUpdateResult] = []
    var writebackResult = WritebackResult(
        totalAffected: 0, written: 0, failed: 0, skipped: 0,
        errors: [], failedItems: [], report: ""
    )
    var cleanupResult = CleanupResult(deletedCount: 0, errors: [])
    var flushSummary = vmSyncSummary()
    var retrySyncSummary = vmSyncSummary()
    var finalizeSummary = vmSyncSummary(synced: 1)
    var resetResult = true
    var confirmSyncResult = true
    var selectionResult = CullingSelectionIds(ids: [])
    var moveRejectedResultOverride: CullingMoveRejectedResult?
    /// Wave5 batch6 / R6：淘汰红标（报告可注入；默认空报告 = 无淘汰项）。
    var rejectedColorTagReport = C1VariantWritebackReport()
    var rejectedColorTagError: GatherError?
    var pageError: GatherError?
    var updateError: GatherError?

    private(set) var pageQueries: [CullingPageQuery] = []
    private(set) var historyQueries: [CullingHistoryQuery] = []
    private(set) var updateInputs: [CullingUpdateInput] = []
    private(set) var batchUpdateInputs: [CullingBatchUpdateInput] = []
    private(set) var updateSelectionInputs: [CullingSelectionUpdateInput] = []
    private(set) var applyHistoryInputs: [CullingApplyHistoryInput] = []
    private(set) var decideGroupInputs: [CullingDecideGroupInput] = []
    private(set) var resetInputs: [Confirmed<CullingResetInput>] = []
    private(set) var writebackInputs: [Confirmed<CullingWritebackInput>] = []
    private(set) var retryWritebackInputs: [Confirmed<SessionReference>] = []
    private(set) var cleanupInputs: [Confirmed<SessionReference>] = []
    private(set) var finalizeInputs: [Confirmed<SessionReference>] = []
    private(set) var flushCalls: [String] = []
    private(set) var retrySyncCalls: [String] = []
    private(set) var confirmSyncCalls: [String] = []
    private(set) var selectionQueries: [CullingSelectionQuery] = []
    private(set) var moveRejectedInputs: [Confirmed<CullingMoveRejectedInput>] = []
    private(set) var rejectedColorTagCalls: [String] = []
    private(set) var triageGenerateCalls = 0

    /// 回归用：让 update 在返回前挂起，连拍才能真正重叠。
    var updateDelay = Duration.zero

    func setPage(_ value: CullingPage) { pageResult = value }
    func setPageResults(_ values: [CullingPage]) { pageResultsQueue = values }
    func setUpdateDelay(_ value: Duration) { updateDelay = value }
    func setUpdateSelectionResult(_ value: CullingSelectionUpdateResult) {
        updateSelectionResult = value
    }
    func setGroups(_ value: [CullingGroup]) { groupsResult = value }
    func setSummary(_ value: CullingSummary) { summaryResult = value }
    func setSyncStatus(_ value: CullingSyncStatus) { syncStatusResult = value }
    func setHistory(_ value: [CullingHistoryOperation]) { historyResult = value }
    func setUpdateResult(_ value: CullingUpdateResult) { updateResult = value }
    func setBatchUpdateResults(_ value: [CullingUpdateResult]) { batchUpdateResults = value }
    func setApplyHistoryResults(_ value: [CullingUpdateResult]) { applyHistoryResults = value }
    func setWritebackResult(_ value: WritebackResult) { writebackResult = value }
    func setCleanupResult(_ value: CleanupResult) { cleanupResult = value }
    func setPageError(_ value: GatherError?) { pageError = value }
    func setSelection(_ value: CullingSelectionIds) { selectionResult = value }
    func setMoveRejectedResult(_ value: CullingMoveRejectedResult) {
        moveRejectedResultOverride = value
    }
    func setRejectedColorTagReport(_ value: C1VariantWritebackReport) {
        rejectedColorTagReport = value
    }
    func setRejectedColorTagError(_ value: GatherError?) {
        rejectedColorTagError = value
    }

    func page(_ query: CullingPageQuery) async throws -> CullingPage {
        pageQueries.append(query)
        if let pageError { throw pageError }
        guard !pageResultsQueue.isEmpty else { return pageResult }
        // 队列：首页 → 第二页……；最后一个一直返回（"读到底"用例用得到）。
        if pageResultsQueue.count > 1 { return pageResultsQueue.removeFirst() }
        return pageResultsQueue[0]
    }

    func history(_ query: CullingHistoryQuery) async throws -> [CullingHistoryOperation] {
        historyQueries.append(query)
        return historyResult
    }

    func applyHistory(_ input: CullingApplyHistoryInput) async throws -> [CullingUpdateResult] {
        applyHistoryInputs.append(input)
        // 夹具对齐真实 CullingService：applyHistory 落库后，history 查询立即反映
        // undone 标记。否则 undo() 内的 refreshSilently() 会用旧 history（undone=false）
        // 覆盖本地刚标记的状态——并行调度下 detached 刷新先落地就必红（R8 P1-1）。
        historyResult = historyResult.map { operation in
            guard operation.id == input.historyOperationId else { return operation }
            var updated = operation
            updated.undone = input.direction == .undo
            return updated
        }
        return applyHistoryResults
    }

    func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult {
        updateInputs.append(input)
        // 替身注入的响应延迟：模拟真实 CullingService 的异步写入，不是"等落定"的固定 sleep。
        if updateDelay > .zero { try? await Task.sleep(for: updateDelay) }
        if let updateError { throw updateError }
        return updateResult
    }

    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult] {
        batchUpdateInputs.append(input)
        return batchUpdateResults
    }

    func updateSelection(
        _ input: CullingSelectionUpdateInput
    ) async throws -> CullingSelectionUpdateResult {
        updateSelectionInputs.append(input)
        return updateSelectionResult
    }

    func decideGroup(_ input: CullingDecideGroupInput) async throws -> [CullingUpdateResult] {
        decideGroupInputs.append(input)
        return decideGroupResults
    }

    func groups(_ sessionId: String) async throws -> [CullingGroup] {
        groupsResult
    }

    func summary(_ sessionId: String) async throws -> CullingSummary {
        summaryResult
    }

    // P1 / D：淘汰移动（stub：直接回成功，不碰文件系统）。
    func moveRejected(_ input: Confirmed<CullingMoveRejectedInput>) async throws -> CullingMoveRejectedResult {
        moveRejectedInputs.append(input)
        return moveRejectedResultOverride
            ?? CullingMoveRejectedResult(moved: input.value.photoIds, newPaths: [], failed: [])
    }

    func selection(_ query: CullingSelectionQuery) async throws -> CullingSelectionIds {
        selectionQueries.append(query)
        return selectionResult
    }

    func syncStatus(_ sessionId: String) async throws -> CullingSyncStatus {
        syncStatusResult
    }

    // Wave5 batch6 / R6：淘汰红标（stub 只记录 sessionId + 返回注入报告/错误）。
    func writeRejectedColorTags(_ sessionId: String) async throws -> C1VariantWritebackReport {
        rejectedColorTagCalls.append(sessionId)
        if let rejectedColorTagError { throw rejectedColorTagError }
        return rejectedColorTagReport
    }

    func reset(_ input: Confirmed<CullingResetInput>) async throws -> Bool {
        resetInputs.append(input)
        return resetResult
    }

    func writeback(_ input: Confirmed<CullingWritebackInput>) async throws -> WritebackResult {
        writebackInputs.append(input)
        return writebackResult
    }

    func flush(_ sessionId: String) async throws -> MetadataSyncSummary {
        flushCalls.append(sessionId)
        return flushSummary
    }

    func retrySync(_ sessionId: String) async throws -> MetadataSyncSummary {
        retrySyncCalls.append(sessionId)
        return retrySyncSummary
    }

    func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult {
        retryWritebackInputs.append(input)
        return writebackResult
    }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        cleanupInputs.append(input)
        return cleanupResult
    }

    func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataSyncSummary {
        finalizeInputs.append(input)
        return finalizeSummary
    }

    func generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary {
        triageGenerateCalls += 1
        return summaryResult.triage ?? TriageSummary(
            counts: TriageCounts(keep: 0, reject: 0, review: 0, total: 0, coverage: 0),
            stale: false, policyVersion: "triage-v1",
            inputFingerprint: "", generatedAt: ""
        )
    }

    func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult {
        TriageApplyResult()
    }

    func modelReview(_ photoId: String) async throws -> ModelReviewResult? {
        nil
    }

    func importClientSelection(
        _ input: Confirmed<ClientSelectionImportInput>
    ) async throws -> ClientSelectionImportReport {
        ClientSelectionImportReport(picked: 0, applied: 0, skipped: 0)
    }

    func confirmSync(_ sessionId: String) async throws -> Bool {
        confirmSyncCalls.append(sessionId)
        return confirmSyncResult
    }
}

private actor StubNavigationAPI: NavigationAPI {
    var listResult: [NavigationGroup] = []
    var analyzeResult: [NavigationGroup] = []
    var splitResult: [NavigationGroup] = []
    var mergeResult: [NavigationGroup] = []
    private(set) var listCalls: [String] = []
    private(set) var analyzeInputs: [NavigationAnalyzeParams] = []
    private(set) var splitInputs: [NavigationSplitParams] = []
    private(set) var mergeInputs: [NavigationMergeParams] = []

    func setListResult(_ value: [NavigationGroup]) { listResult = value }
    func setAnalyzeResult(_ value: [NavigationGroup]) { analyzeResult = value }

    func list(_ sessionId: String) async throws -> [NavigationGroup] {
        listCalls.append(sessionId)
        return listResult
    }

    func split(_ input: NavigationSplitParams) async throws -> [NavigationGroup] {
        splitInputs.append(input)
        return splitResult
    }

    func merge(_ input: NavigationMergeParams) async throws -> [NavigationGroup] {
        mergeInputs.append(input)
        return mergeResult
    }

    func analyze(_ input: NavigationAnalyzeParams) async throws -> [NavigationGroup] {
        analyzeInputs.append(input)
        return analyzeResult
    }
}

// MARK: - 用例

@MainActor
@Suite("B3b CullingViewModel API 迁移")
struct CullingViewModelAPITests {
    @Test("load：读取走 CullingAPI，查询参数与 reloadAckedAt 投影正确")
    func loadUsesTypedCullingAPI() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2", revision: 2)]))
        await api.setSummary(CullingSummary(
            totalGroups: 1, totalPhotos: 2, kept: 1, rejected: 0, pending: 1, rated: 1, labeled: 0
        ))
        await api.setSyncStatus(CullingSyncStatus(
            summary: vmSyncSummary(written: 3),
            reloadAckedAt: "2026-09-01T10:00:00.000Z"
        ))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )

        await vm.load()

        let pageQueries = await api.pageQueries
        #expect(pageQueries.count == 1)
        #expect(pageQueries.first?.sessionId == "s1")
        #expect(pageQueries.first?.scope == .all)
        #expect(pageQueries.first?.limit == 500)
        let historyQueries = await api.historyQueries
        #expect(historyQueries.first?.limit == 500)
        #expect(await navigation.listCalls == ["s1"])
        #expect(vm.page?.assets.map(\.photo.id) == ["p1", "p2"])
        #expect(vm.currentPhotoId == "p1")
        #expect(vm.summary?.totalPhotos == 2)
        #expect(vm.syncStatus?.written == 3)
        #expect(vm.reloadAcked)
    }

    @Test("update：expectedRevision/patch 进类型化输入，应用 states 并自动前进 + prepend history")
    func updateUsesTypedInputAndAppliesResult() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let asset = vmAsset("p1", revision: 3)
        await api.setPage(vmPage([asset, vmAsset("p2")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()

        let updatedState = vmState("p1", revision: 4, pickState: .picked)
        await api.setUpdateResult(CullingUpdateResult(
            states: [updatedState], xmpPath: "/shoot/p1.xmp",
            syncStatus: .pending, historyOperationId: 9
        ))
        // 刷新快照不能把刚应用的决策冲掉：让后台 refresh 拿到同一份新页。
        await api.setPage(vmPage([
            vmAsset("p1", revision: 4, pickState: .picked), vmAsset("p2")
        ]))
        // 同理，后台 refresh 的 history 快照也必须已含本次操作：否则 detached
        // 刷新在 update 之后落地会用旧 history（空）覆盖本地 prepend 的 op 9。
        // 串行调度下 update 通常先落地；并行/满载时会随机红（实测 50 次中 1 次）。
        await api.setHistory([
            CullingHistoryOperation(
                id: 9,
                sessionId: "s1",
                entries: [
                    CullingHistoryEntry(
                        photoId: "p1",
                        before: CullingStateSnapshot(
                            pickState: .unreviewed, rating: 0, colorLabel: .none),
                        after: CullingStateSnapshot(
                            pickState: .picked, rating: 0, colorLabel: .none),
                        expectedRevision: 3,
                        fields: [.pickState]),
                ],
                undone: false,
                createdAt: "2026-09-01T10:00:00.000Z")
        ])

        await vm.update(asset, patch: CullingUpdatePatch(pickState: .picked), nextPhotoId: "p2")
        await vm.refreshTask?.value

        let inputs = await api.updateInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.photoId == "p1")
        #expect(inputs.first?.expectedRevision == 3)
        #expect(inputs.first?.patch.pickState == .picked)
        #expect(vm.currentPhotoId == "p2")
        #expect(vm.page?.assets.first?.state.pickState == .picked)
        #expect(vm.undoOperation?.id == 9)
        #expect(vm.undoOperation?.entries.first?.before.pickState == .unreviewed)
        #expect(vm.undoOperation?.entries.first?.after.pickState == .picked)
    }

    // R1 F1 回归：commit 的串行链必须线性排队。旧实现「先 await 前驱、后赋值」，
    // 第三拍会与第二拍同时续行，两者带同一 expectedRevision 重复提交同一张照片。
    @Test("连按三拍：commit 串行级联，逐张落到 p1/p2/p3")
    func rapidCommitsSerializeAcrossPhotos() async {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        await api.setUpdateDelay(.milliseconds(40))

        async let first: Void = vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        async let second: Void = vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        async let third: Void = vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        _ = await (first, second, third)

        let ids = await api.updateInputs.map(\.photoId)
        #expect(ids.count == 3)
        #expect(Set(ids) == ["p1", "p2", "p3"], "三拍必须逐张前进；重复照片 = 过期 revision 冲突")
    }

    @Test("batchUpdate：选中集合进类型化输入，返回的历史操作只 prepend 一次")
    func batchUpdateUsesSelectionAndHistory() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.toggleSelection("p1")
        vm.toggleSelection("p2")

        let states = [vmState("p1", revision: 2, pickState: .rejected), vmState("p2", revision: 2, pickState: .rejected)]
        await api.setBatchUpdateResults([
            CullingUpdateResult(states: states, xmpPath: "/shoot/p1.xmp", syncStatus: .pending, historyOperationId: 11)
        ])
        await api.setPage(vmPage([
            vmAsset("p1", revision: 2, pickState: .rejected),
            vmAsset("p2", revision: 2, pickState: .rejected),
            vmAsset("p3")
        ]))
        // 与 update 用例同因：detached refresh 若在 batchUpdate 之后落地，会用它拿到的
        // history 快照覆盖本地 prepend。夹具按「服务端已应用本次操作」返回 op 11，
        // 并在断言前 await 刷新任务，消除落地顺序的影响。
        await api.setHistory([
            CullingHistoryOperation(
                id: 11,
                sessionId: "s1",
                entries: [
                    CullingHistoryEntry(
                        photoId: "p1",
                        before: CullingStateSnapshot(
                            pickState: .unreviewed, rating: 0, colorLabel: .none),
                        after: CullingStateSnapshot(
                            pickState: .rejected, rating: 0, colorLabel: .none),
                        expectedRevision: 1,
                        fields: [.pickState]),
                    CullingHistoryEntry(
                        photoId: "p2",
                        before: CullingStateSnapshot(
                            pickState: .unreviewed, rating: 0, colorLabel: .none),
                        after: CullingStateSnapshot(
                            pickState: .rejected, rating: 0, colorLabel: .none),
                        expectedRevision: 1,
                        fields: [.pickState]),
                ],
                undone: false,
                createdAt: "2026-09-01T10:00:00.000Z")
        ])

        await vm.batchUpdate(patch: CullingUpdatePatch(pickState: .rejected))
        await vm.refreshTask?.value

        let inputs = await api.batchUpdateInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.photoIds == ["p1", "p2"])
        #expect(inputs.first?.patch.pickState == .rejected)
        #expect(vm.undoOperation?.id == 11)
        #expect(vm.undoOperation?.entries.count == 2)
        #expect(vm.page?.assets.filter { $0.state.pickState == .rejected }.count == 2)
    }

    @Test("跨页批量：提交完整选择集，不再与当前页求交（P1-7）")
    func batchUpdateSubmitsCrossPageSelection() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        // p3 是第 2 页（未加载）；用户通过服务端全选后它仍在选择集里。
        vm.selectedPhotoIds = ["p1", "p2", "p3"]
        await api.setBatchUpdateResults([
            CullingUpdateResult(
                states: [
                    vmState("p1", revision: 2, pickState: .rejected),
                    vmState("p2", revision: 2, pickState: .rejected),
                    vmState("p3", revision: 2, pickState: .rejected),
                ],
                xmpPath: "/shoot/p1.xmp", syncStatus: .pending, historyOperationId: 12)
        ])

        await vm.batchUpdate(patch: CullingUpdatePatch(pickState: .rejected))

        let inputs = await api.batchUpdateInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.photoIds == ["p1", "p2", "p3"],
                "跨页选择必须整份提交；不得静默截成当前页")
    }

    @Test("P1：单击后连续按 P 写到下一张（自动前进同步选择集）")
    func autoAdvanceMovesSelectionWithDecision() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.selectCurrent("p1")
        await vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        #expect(vm.currentPhotoId == "p2")
        #expect(vm.selectedPhotoIds == ["p2"], "自动前进必须把选择集一起移到下一张")

        await vm.commit(patch: CullingUpdatePatch(pickState: .picked))
        let photoIds = await api.updateInputs.map(\.photoId)
        #expect(photoIds == ["p1", "p2"], "第二次 P 必须写到 p2，而不是重写 p1")
    }

    @Test("undo：applyHistory 带 direction=undo，操作标记 undone 且 redo 可用")
    func undoUsesTypedApplyHistory() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        await api.setPage(vmPage([vmAsset("p1", revision: 2, pickState: .picked)]))
        let entry = CullingHistoryEntry(
            photoId: "p1",
            before: CullingStateSnapshot(pickState: .unreviewed, rating: 0, colorLabel: .none),
            after: CullingStateSnapshot(pickState: .picked, rating: 0, colorLabel: .none),
            expectedRevision: 1,
            fields: [.pickState]
        )
        await api.setHistory([
            CullingHistoryOperation(
                id: 7, sessionId: "s1", entries: [entry], undone: false,
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        ])
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()

        await api.setApplyHistoryResults([
            CullingUpdateResult(
                states: [vmState("p1", revision: 3, pickState: .unreviewed)],
                xmpPath: "/shoot/p1.xmp", syncStatus: .pending, historyOperationId: 7
            )
        ])
        await api.setPage(vmPage([vmAsset("p1", revision: 3, pickState: .unreviewed)]))

        await vm.undo()

        let inputs = await api.applyHistoryInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.direction == .undo)
        #expect(inputs.first?.historyOperationId == 7)
        #expect(inputs.first?.entries.first?.photoId == "p1")
        #expect(inputs.first?.entries.first?.patch.pickState == .unreviewed)
        #expect(vm.history.first?.undone == true)
        #expect(vm.undoOperation == nil)
        #expect(vm.redoOperation?.id == 7)
    }

    @Test("破坏性入口：只有确认分支构造 Confirmed<T>，source 为用户弹窗")
    func destructiveEntriesUseConfirmed() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        await api.setPage(vmPage([vmAsset("p1")]))
        await api.setWritebackResult(WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        ))
        await api.setCleanupResult(CleanupResult(deletedCount: 2, errors: []))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()

        await vm.writeback(target: .rating, confirmed: true, l10n: L10n(language: .zhCN))
        await vm.cleanup(confirmed: true, l10n: L10n(language: .zhCN))
        await vm.reset(confirmed: true)
        await vm.finalizeSync(confirmed: true)
        await vm.retryFailedWriteback(confirmed: true, l10n: L10n(language: .zhCN))
        await vm.flush(retry: true)
        await vm.confirmSync()

        let writebacks = await api.writebackInputs
        #expect(writebacks.first?.value.target == .rating)
        #expect(writebacks.first?.source == .userDialog)
        let cleanups = await api.cleanupInputs
        #expect(cleanups.first?.value.sessionId == "s1")
        #expect(cleanups.first?.source == .userDialog)
        let resets = await api.resetInputs
        #expect(resets.first?.value.sessionId == "s1")
        #expect(resets.first?.source == .userDialog)
        let finalizes = await api.finalizeInputs
        #expect(finalizes.first?.source == .userDialog)
        let retries = await api.retryWritebackInputs
        #expect(retries.first?.source == .userDialog)
        #expect(await api.retrySyncCalls == ["s1"])
        #expect(await api.confirmSyncCalls == ["s1"])

        let resetCountBefore = resets.count
        await vm.reset(confirmed: false)
        #expect(await api.resetInputs.count == resetCountBefore)
        #expect(vm.errorMessage != nil)
    }

    @Test("错误：GatherError 只落错误载体（码/参数），不直出原始诊断")
    func gatherErrorMapsThroughPresentation() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let error = GatherError(
            code: .CULLING_REVISION_CONFLICT,
            params: ["expectedRevision": "1", "currentRevision": "2"],
            underlying: "sensitive raw diagnostic"
        )
        await api.setPageError(error)
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )

        await vm.load()

        // Cut 4 / 4a-3b-1：VM 只存码/参数/诊断，文案在渲染期本地化。
        #expect(vm.errorMessage?.code == "CULLING_REVISION_CONFLICT")
        #expect(vm.errorMessage?.params == ["1", "2"])
        #expect(vm.errorMessage?.diagnostic == "sensitive raw diagnostic")
        #expect(vm.errorMessage?.code != "sensitive raw diagnostic")
        #expect(vm.page == nil)
    }

    @Test("navigation.* 走 NavigationAPI：list 与 analyze(dryRun) 透传")
    func navigationUsesTypedAPI() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let group = NavigationGroup(
            id: "g1", type: .burst, photoIds: ["p1"], startAt: "t0", endAt: "t1",
            explanation: "", source: .automatic
        )
        await navigation.setListResult([group])
        await navigation.setAnalyzeResult([group])
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )

        await vm.loadNavigation()
        #expect(vm.navigationGroups.map(\.id) == ["g1"])
        await vm.analyzeNavigation(dryRun: true)

        let inputs = await navigation.analyzeInputs
        #expect(inputs.first?.sessionId == "s1")
        #expect(inputs.first?.dryRun == true)
        #expect(vm.notice != nil)
    }

    // MARK: - B8.2b：quality.analyze / jobs.list / jobs.cancel

    @Test("B8.2b：analyzeQuality 建单走 QualityAPI，轮询走 JobAPI.list")
    func analyzeQualityUsesQualityAndJobAPI() async throws {
        let culling = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let quality = B5bQualityAPIStub()
        let jobs = B5bJobAPIStub()
        let queued = b5bJobData(id: "q1", type: .qualityScore, status: .queued, scopeId: "s1")
        quality.analyzeResult = queued
        // 建单后第一轮 500ms 轮询读到终态：任务收尾 + 刷新挑片页。
        jobs.jobs = [b5bJobData(id: "q1", type: .qualityScore, status: .succeeded, scopeId: "s1")]
        await culling.setPage(vmPage([vmAsset("p1")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: jobs, quality: quality
        )
        // WP4d：默认不可见（PageVisibility），页面挂载才启动画质轮询。
        vm.setVisible(true)

        let task = Task { await vm.analyzeQuality() }
        await task.value

        #expect(quality.analyzeInputs.count == 1)
        #expect(quality.analyzeInputs.first?.sessionId == "s1")
        #expect(quality.analyzeInputs.first?.photoIds == nil)
        #expect(jobs.listFilters.first?.includeCheckpoint == false)
        #expect(vm.qualityJob?.status == .succeeded)
        AppLanguageLock.withStableCopy {
            #expect(vm.notice == CullingNotice("技术质量分析已完成"))
        }
        let pageQueries = await culling.pageQueries
        #expect(pageQueries.count == 1, "终态后必须刷新一次挑片页")
    }

    @Test("T0：summary 未加载时生成结果不丢")
    func generateTriageKeepsResultWithoutSummary() async {
        let culling = StubCullingAPI()
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm.setTriageEnabled(true)
        await vm.generateTriage()
        #expect(vm.triageSummary != nil)
    }

    @Test("T0：质量分析成功后按开关自动生成建议")
    func autoGenerateTriageAfterQuality() async throws {
        let culling = StubCullingAPI()
        let quality = B5bQualityAPIStub()
        let jobs = B5bJobAPIStub()
        let queued = b5bJobData(id: "q1", type: .qualityScore, status: .queued, scopeId: "s1")
        quality.analyzeResult = queued
        jobs.jobs = [b5bJobData(id: "q1", type: .qualityScore, status: .succeeded, scopeId: "s1")]
        let triage = TriageSummary(
            counts: TriageCounts(keep: 1, reject: 0, review: 0, total: 1, coverage: 1),
            stale: false, policyVersion: "triage-v1",
            inputFingerprint: "fp", generatedAt: "t")
        await culling.setSummary(CullingSummary(
            totalGroups: 0, totalPhotos: 1, kept: 0, rejected: 0, pending: 1,
            rated: 0, labeled: 0, triage: triage))
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: jobs, quality: quality)
        vm.setVisible(true)
        vm.setTriageEnabled(true)
        vm.triageAutoGenerate = true

        let task = Task { await vm.analyzeQuality() }
        await task.value
        #expect(await culling.triageGenerateCalls == 1)
    }

    @Test("B8.2b：cancelQualityAnalysis 走 JobAPI.cancel 且保留可见文案")
    func cancelQualityUsesJobAPI() async throws {
        let culling = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let quality = B5bQualityAPIStub()
        let jobs = B5bJobAPIStub()
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: navigation,
            metadata: B6bMetadataAPIStub(), jobs: jobs, quality: quality
        )
        vm.applyQualityJobForTesting(
            b5bJobData(id: "q1", type: .qualityScore, status: .running, scopeId: "s1")
        )

        vm.cancelQualityAnalysis()

        // JobAPI.cancel 的写入与 notice 回写都在同一个 MainActor Task 内：等 notice
        // 落地即覆盖「cancel 已完成」，否则会读到 cancel 已记录但文案尚未回写的中间态。
        #expect(await waitUntilAsync {
            AppLanguageLock.withStableCopy {
                vm.notice == CullingNotice("已请求取消质量分析")
            }
        })
        #expect(jobs.cancelledIds == ["q1"])
        #expect(vm.errorMessage == nil)
    }

    // MARK: - B6b：metadata.conflicts / resolve_conflict 迁移

    @Test("B6b：load 的冲突列表走 MetadataAPI.conflicts（按 sessionId 查询）")
    func loadsConflictsFromMetadataAPI() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let metadata = B6bMetadataAPIStub()
        metadata.conflicts = [b6bConflict()]
        await api.setPage(vmPage([vmAsset("p1")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: metadata, jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )

        await vm.load()

        // 冲突查询是 detached 任务（P2-8 版本守卫），等待其落地。
        #expect(await waitUntilAsync { vm.conflicts.count == 1 })
        #expect(vm.conflicts.first?.xmpPath == "/shoot/a.xmp")
        #expect(metadata.conflictCalls == ["s1"])
    }

    @Test("B6b：冲突裁决只从确认分支构造 Confirmed(source: .userDialog)")
    func resolveConflictUsesConfirmedMetadataAPI() async throws {
        let api = StubCullingAPI()
        let navigation = StubNavigationAPI()
        let metadata = B6bMetadataAPIStub()
        await api.setPage(vmPage([vmAsset("p1")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: navigation,
            metadata: metadata, jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        let conflict = b6bConflict()

        await vm.resolve(conflict, choices: [.rating: .useRemote], confirmed: true)
        #expect(metadata.resolveConflictInputs.count == 1)
        let confirmed = try #require(metadata.resolveConflictInputs.first)
        #expect(confirmed.source == .userDialog)
        #expect(confirmed.value.sessionId == "s1")
        #expect(confirmed.value.xmpPath == conflict.xmpPath)
        #expect(confirmed.value.choices == [.rating: .useRemote])
        #expect(vm.notice != nil)

        // 未确认：不发请求，写可见错误（与旧路由门禁同语义）。
        await vm.resolve(conflict, choices: [.rating: .useRemote], confirmed: false)
        #expect(metadata.resolveConflictInputs.count == 1)
        #expect(vm.errorMessage != nil)
    }

    @Test("P2-5：批量冲突按同一策略逐项应用")
    func resolveAllConflictsUsesOneStrategy() async throws {
        let api = StubCullingAPI()
        let metadata = B6bMetadataAPIStub()
        metadata.conflicts = [
            b6bConflict(xmpPath: "/shoot/a.xmp"),
            b6bConflict(xmpPath: "/shoot/b.xmp"),
        ]
        await api.setPage(vmPage([vmAsset("p1")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: metadata, jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        #expect(await waitUntilAsync { vm.conflicts.count == 2 })

        await vm.resolveAllConflicts(choice: .useRemote, confirmed: true)

        #expect(metadata.resolveConflictInputs.count == 2)
        #expect(metadata.resolveConflictInputs.allSatisfy {
            $0.value.choices == [.rating: .useRemote]
        })
        #expect(vm.notice != nil)
        #expect(vm.errorMessage == nil)
    }

    @Test("B6b：空 choices（保留 Gather 并结清）归一化为逐字段 keep_local")
    func emptyChoicesSettleAsKeepLocal() throws {
        let conflict = b6bConflict()
        #expect(
            CullingViewModel.apiChoices(for: conflict, choices: [:])
                == [.rating: .keepLocal]
        )
        // 非空 choices 原样透传，不改变逐字段裁决。
        #expect(
            CullingViewModel.apiChoices(for: conflict, choices: [.rating: .useRemote])
                == [.rating: .useRemote]
        )
    }

    // MARK: - Cut 4 / 4a-2b：可见性钩子

    @Test("4a-2b：setVisible(false) 停画质轮询，true 恢复，shutdown 后不复活")
    func setVisibleControlsQualityPolling() async {
        #expect(CullingViewModel.defaultQualityPollIntervalMilliseconds == 500)
        let culling = B8CullingAPIStub()
        let navigation = B8NavigationAPIStub()
        let metadata = B6bMetadataAPIStub()
        let quality = B5bQualityAPIStub()
        let jobs = B5bJobAPIStub()
        let queued = b5bJobData(
            id: "q-poll", type: .qualityScore, status: .queued, scopeId: "s1"
        )
        quality.analyzeResult = queued
        // 任务始终排队（不终态），轮询会持续发 jobs.list。
        jobs.jobs = [queued]
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: navigation,
            metadata: metadata, jobs: jobs, quality: quality,
            qualityPollIntervalMilliseconds: 10
        )
        // WP4d：默认不可见（统一 PageVisibility 契约），页面挂载后才变为可见。
        #expect(!vm.isActive)
        vm.setVisible(true)
        #expect(vm.isActive)

        let analyze = Task { await vm.analyzeQuality() }
        #expect(await waitUntilAsync(timeout: 5) { jobs.listFilters.count >= 1 })

        // 隐藏：轮询任务被取消，analyzeQuality 立即返回，窗口内不得再发命令。
        vm.setVisible(false)
        await analyze.value
        #expect(vm.isActive == false)
        // 隐藏只取消轮询：隐藏前已在途的一次 jobs.list 可能尚未记上，先等它
        // 落定再取基线，随后窗口内再出现调用才说明轮询没停。
        let stopped = await awaitStableCount { jobs.listFilters.count }
        #expect(await awaitStableCount { jobs.listFilters.count } == stopped, "隐藏后不得继续轮询 JobAPI.list")

        // 恢复：仍在排队的画质任务重新开轮询（进度不丢）。
        vm.setVisible(true)
        #expect(await waitUntilAsync(timeout: 5) { jobs.listFilters.count > stopped })

        // 关闭：取消轮询；setVisible(true) 明确 no-op。
        vm.shutdown()
        // 同隐藏窗口：关闭前已在途的调用先落定。
        let shutDown = await awaitStableCount { jobs.listFilters.count }
        vm.setVisible(true)
        #expect(await awaitStableCount { jobs.listFilters.count } == shutDown, "shutdown 后 setVisible(true) 不得重启轮询")
    }

    @Test("4a-2b：隐藏期领域变更只登记，setVisible(true) 补刷")
    func setVisibleFlushesDeferredDomainRefresh() async {
        let culling = B8CullingAPIStub()
        let navigation = B8NavigationAPIStub()
        let metadata = B6bMetadataAPIStub()
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: navigation,
            metadata: metadata, jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        let base = culling.pageQueries.count

        vm.setVisible(false)
        vm.handleDomainChange(GatherApplicationChange(
            domain: .culling, sessionId: "s1", origin: "gallery"
        ))
        #expect(vm.pendingDomainRefresh, "隐藏期领域变更必须只登记")
        await awaitNegativeWindow(.milliseconds(100))
        #expect(culling.pageQueries.count == base, "隐藏期不得发 page 查询")

        vm.setVisible(true)
        #expect(await waitUntilAsync { culling.pageQueries.count > base }, "恢复可见必须补刷隐藏期领域变更")
    }

    // MARK: - Cut 4 / 4a-3b-2b：notice 延迟本地化

    @Test("notice 存 key：渲染期随语言切换，不残留旧语言文案")
    func noticeResolvesAtRenderTime() {
        let vm = CullingViewModel(
            sessionId: "s1", culling: B8CullingAPIStub(), navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        vm.noteCancelledAction(LocalizedText("重置挑片状态"))
        #expect(vm.notice == CullingNotice(cancelled: LocalizedText("重置挑片状态")))
        #expect(vm.notice?.resolve(with: L10n(language: .zhCN)) == "已取消：重置挑片状态")
        // 动作名本身也走表：切到 en 后不能残留中文（4b-2a 修复的嵌套预格式化）。
        #expect(vm.notice?.resolve(with: L10n(language: .en)) == "Cancelled: Reset Culling State")
    }

    @Test("写回成功提示：计数句 + 指引句在渲染期组合（两种语言都不冻结尾部）")
    func writebackNoticeResolvesAtRenderTime() {
        let notice = CullingNotice(
            writebackLabel: LocalizedText("评分"),
            written: 3, failed: 0, skipped: 1
        )
        #expect(notice.resolve(with: L10n(language: .zhCN))
            == "评分：成功 3，失败 0，跳过 1；请让 Capture One 重新加载元数据后确认同步")
        #expect(notice.resolve(with: L10n(language: .en))
            == "Rating: 3 succeeded, 0 failed, 1 skipped; load metadata in Capture One again, then confirm the sync")
    }

    // MARK: - P0 / A1：跨页选择与移出

    @Test("移出：不在当前页的选择也整份提交（不再按 page.assets 过滤）")
    func moveRejectedSubmitsCrossPageSelection() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p2", pickState: .rejected)]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        // p1 不在当前页（模拟第 1 页已翻走），但仍是用户选择集的一部分。
        vm.selectedPhotoIds = ["p1", "p2"]

        await vm.moveRejectedOut()

        let inputs = await api.moveRejectedInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.value.photoIds == ["p1", "p2"])
    }

    @Test("移出：skipped 只提示，不把未移出的照片从选择集删掉")
    func moveRejectedKeepsSkippedSelection() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1", pickState: .rejected)]))
        await api.setMoveRejectedResult(CullingMoveRejectedResult(
            moved: ["p1"], newPaths: ["/shoot/_rejects/p1.jpg"],
            skipped: [CullingMoveRejectedSkip(photoId: "p2", reason: "not_rejected")],
            failed: []))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.selectedPhotoIds = ["p1", "p2"]

        await vm.moveRejectedOut()

        #expect(vm.selectedPhotoIds == ["p2"], "只有真正移出的照片离开选择集")
    }

    @Test("全选：走 selection API 取当前 scope 的完整集合")
    func selectAllUsesSelectionAPI() async throws {
        let api = StubCullingAPI()
        await api.setSelection(CullingSelectionIds(ids: ["p1", "p2", "p3"]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        await vm.selectAllInScope()

        #expect(vm.selectedPhotoIds == ["p1", "p2", "p3"])
        let queries = await api.selectionQueries
        #expect(queries.first?.sessionId == "s1")
        #expect(queries.first?.scope == .all)
    }

    @Test("跨页全选：commit 先确认，确认后走 updateSelection（P1-7）")
    func crossPageCommitConfirmsThenUsesSelectionAPI() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2")]))
        await api.setSelection(CullingSelectionIds(
            ids: ["p1", "p2", "p3"], idsHash: "hash-3"))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        await vm.selectAllInScope()

        await vm.commit(patch: CullingUpdatePatch(pickState: .rejected))
        #expect(vm.pendingCrossPageBatch != nil, "跨页选择必须先确认")
        #expect(await api.updateSelectionInputs.isEmpty, "确认前不得写入")

        await api.setUpdateSelectionResult(CullingSelectionUpdateResult(
            requested: 3,
            applied: 3,
            states: [
                vmState("p1", revision: 2, pickState: .rejected),
                vmState("p2", revision: 2, pickState: .rejected),
            ]))
        let plan = try #require(vm.pendingCrossPageBatch)
        await vm.performCrossPageBatch(plan, onlyVisible: false)

        let input = try #require(await api.updateSelectionInputs.last)
        #expect(input.expectedIdsHash == "hash-3")
        #expect(input.expectedCount == 3)
        #expect(input.patch.pickState == .rejected)
        #expect(vm.page?.assets.first(where: { $0.photo.id == "p1" })?.state.pickState == .rejected,
                "updateSelection 返回的 states 必须就地回显")
    }

    @Test("P2-4：离开“按筛选”范围清空 filters，避免检查器残留 N 项筛选")
    func leavingFilteredScopeClearsFilters() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        await vm.setFilterState { $0.rating = 5 }
        #expect(vm.scopeMode == .filtered)
        #expect(vm.filterState.isActive)
        #expect(vm.activeFilterCount == 1)

        await vm.setScope(.all)
        #expect(vm.scopeMode == .all)
        #expect(!vm.filterState.isActive, "离开筛选范围后必须有可清除的空状态")
        #expect(vm.activeFilterCount == 0)
    }

    @Test("P2-3：多选星级/色标显示混合态，单选显示统一值")
    func selectionSummaryShowsMixedValues() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([
            vmAsset("p1", rating: 5, colorLabel: .red),
            vmAsset("p2", rating: 3, colorLabel: .blue),
        ]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.selectedPhotoIds = ["p1", "p2"]
        let mixed = try #require(vm.selectionSummary)
        #expect(mixed.hasMixedRating)
        #expect(mixed.hasMixedColorLabel)
        #expect(mixed.rating == nil)
        #expect(mixed.colorLabel == nil)

        vm.selectCurrent("p1")
        let single = try #require(vm.selectionSummary)
        #expect(!single.hasMixedRating)
        #expect(single.rating == 5)
        #expect(single.colorLabel == .red)
    }

    @Test("P2-3：对比优先显式选中的 2/4 张，否则当前 ± 相邻")
    func comparisonUsesSelectionOrNeighbors() {
        let assets = (1...5).map { vmAsset("p\($0)") }
        let current = assets[2]

        let selected = CullingComparison.assets(
            current: current, assets: assets,
            selectedIds: ["p1", "p3"], compareCount: 2)
        #expect(selected.map(\.photo.id) == ["p1", "p3"])

        let pair = CullingComparison.assets(
            current: current, assets: assets,
            selectedIds: [], compareCount: 2)
        #expect(pair.map(\.photo.id) == ["p3", "p4"],
                "无显式选择时必须从当前照片取相邻，而不是列表开头")

        let four = CullingComparison.assets(
            current: current, assets: assets,
            selectedIds: [], compareCount: 4)
        #expect(four.count == 4)
        #expect(four.contains { $0.photo.id == current.photo.id })
        #expect(four.map(\.photo.id) == ["p2", "p3", "p4", "p5"])
    }

    @Test("普通点击当前照片：清空旧多选，P/X 只作用于当前（P1-6）")
    func selectCurrentClearsMultiSelection() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.toggleSelection("p1")
        vm.toggleSelection("p2")
        #expect(vm.selectedPhotoIds == ["p1", "p2"])

        vm.selectCurrent("p3")
        #expect(vm.currentPhotoId == "p3")
        #expect(vm.selectedPhotoIds == ["p3"],
                "普通点击必须收敛为单选，否则后续 P/X 会写进旧选择")
    }

    @Test("胶片条 Shift：从当前到目标做范围选择，并把当前移到目标")
    func selectRangeFromCurrentUsesCurrentAnchor() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.selectCurrent("p1")
        vm.selectRangeFromCurrent(to: "p3")
        #expect(vm.selectedPhotoIds == ["p1", "p2", "p3"])
        #expect(vm.currentPhotoId == "p3")
    }

    @Test("连续 Shift：锚点保持，第二次范围不丢第一段")
    func repeatedShiftKeepsAnchor() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.selectCurrent("p1")
        vm.selectRangeFromCurrent(to: "p3")
        #expect(vm.selectedPhotoIds == ["p1", "p2", "p3"])
        vm.selectRangeFromCurrent(to: "p2")
        #expect(vm.selectedPhotoIds == ["p1", "p2"],
                "锚点仍是 p1；第二次 Shift 不能变成从 p3 到 p2")
    }

    @Test("相似组决策：按完整组员数生成影响面，不只看已加载页（P1-8）")
    func prepareGroupDecisionUsesFullGroup() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([
            vmAsset("p1", similarityGroupId: "g1"),
            vmAsset("p2", similarityGroupId: "g1"),
        ]))
        await api.setGroups([
            CullingGroup(
                groupId: "g1", groupIndex: 0,
                images: [
                    CullingImage(photoId: "p1", filepath: "/shoot/p1.jpg", filename: "p1.jpg", decision: .pending),
                    CullingImage(photoId: "p2", filepath: "/shoot/p2.jpg", filename: "p2.jpg", decision: .pending),
                    CullingImage(photoId: "p3", filepath: "/shoot/p3.jpg", filename: "p3.jpg", decision: .pending),
                ],
                keepCount: 0, rejectCount: 0, pendingCount: 3
            )
        ])
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()

        let plan = try #require(await vm.prepareGroupDecision(
            groupId: "g1", keepPhotoIds: ["p1"]))
        #expect(plan.totalCount == 3, "必须显示完整组员数，而不是已加载的 2 张")
        #expect(plan.visibleCount == 2)
        #expect(plan.keepPhotoIds == ["p1"])
        #expect(plan.sampleRejectedNames == ["p2.jpg", "p3.jpg"])

        await vm.performGroupDecision(plan)
        let inputs = await api.decideGroupInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.groupId == "g1")
        #expect(inputs.first?.keepPhotoIds == ["p1"])
    }

    @Test("triage undo 入口：以 undoAvailable 为准，不因 written 为空而丢弃批次")
    func triageUndoEntryUsesUndoAvailable() async throws {
        let metadata = B6bMetadataAPIStub()
        metadata.triageApplyResult = TriageWritebackResult(
            batchId: "b-uncertain", written: [], skipped: [],
            failed: [MetadataApplyFailureDTO(photoId: "p1", message: "read-back failed")],
            undoAvailable: true)
        let vm = CullingViewModel(
            sessionId: "s1", culling: StubCullingAPI(), navigation: StubNavigationAPI(),
            metadata: metadata, jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        let input = try TriageWritebackInput(
            policy: .ratingOnlyWhenEmpty,
            items: [try TriageWritebackItem(photoId: "p1", verdict: "keep")])
        await vm.applyTriageWriteback(Confirmed(input, source: .userDialog))

        #expect(vm.lastTriageWritebackBatchId == "b-uncertain",
                "回读失败但可能已写盘的批次必须可撤销")
    }

    // MARK: - Wave5 批次 1：B1 决策目标 / B2 切布局续页

    @Test("B1：对比/Survey 的决策只写当前照片，不批量写选择集")
    func comparisonCommitTargetsCurrentPhotoOnly() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        // 为构造 2 图对比先多选 p1/p2，当前仍是 p1。
        // 旧实现：按 X 走选择集分支，把两张都标掉（20-culling-viewer §2 P1）。
        vm.selectedPhotoIds = ["p1", "p2"]
        vm.currentPhotoId = "p1"

        await vm.commit(patch: CullingUpdatePatch(pickState: .rejected), currentOnly: true)
        await vm.refreshTask?.value

        let batchInputs = await api.batchUpdateInputs
        let updateIds = await api.updateInputs.map(\.photoId)
        #expect(batchInputs.isEmpty, "对比/Survey 不得把选择集当写入目标")
        #expect(updateIds == ["p1"], "只写当前照片")
        #expect(vm.selectedPhotoIds == ["p1", "p2"], "自动前进保留对比选择集（它只是画面）")
        #expect(vm.currentPhotoId == "p2", "下一拍的目标随之移动")
    }

    @Test("B1：显式打开「作用于全部选中」后仍走批量分支")
    func comparisonCommitWithExplicitBatchStillBatches() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage([vmAsset("p1"), vmAsset("p2"), vmAsset("p3")]))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        await vm.load()
        vm.selectedPhotoIds = ["p1", "p2"]
        vm.currentPhotoId = "p1"
        await api.setBatchUpdateResults([
            CullingUpdateResult(
                states: [
                    vmState("p1", revision: 2, pickState: .rejected),
                    vmState("p2", revision: 2, pickState: .rejected),
                ],
                xmpPath: "/shoot/p1.xmp", syncStatus: .pending, historyOperationId: 21)
        ])

        // 开关打开 = 用户明确要求批量：不传 currentOnly，沿用旧的选择集分支。
        await vm.commit(patch: CullingUpdatePatch(pickState: .rejected))
        await vm.refreshTask?.value

        let singleInputs = await api.updateInputs
        let batchInputs = await api.batchUpdateInputs
        #expect(singleInputs.isEmpty, "批量口径不得拆成逐张单拍")
        #expect(batchInputs.map(\.photoIds) == [["p1", "p2"]])
    }

    @Test("B2：切布局页变小（500→200）保留已加载窗口与当前照片")
    func layoutPageShrinkKeepsCurrentPhoto() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage((1...250).map { vmAsset("p\($0)") }))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        vm.applyPageLimit(500)
        await vm.load()
        // 第 221 张：超过网格的 200/页。旧实现 reset 后回退到第一张。
        vm.currentPhotoId = "p221"
        let queriesBefore = await api.pageQueries.count

        await vm.setPageLimit(200)

        #expect(vm.pageLimit == 200)
        #expect(await api.pageQueries.count == queriesBefore, "页变小不该重取首页")
        #expect(vm.currentPhotoId == "p221", "当前照片不能被踢回第一张")
        #expect(vm.page?.assets.count == 250, "已加载窗口保持（不再整页 reset）")
    }

    @Test("B2：页变大时按新页大小重取首页并保住当前照片")
    func layoutPageGrowReloadsWithNewLimit() async throws {
        let api = StubCullingAPI()
        await api.setPage(vmPage((1...250).map { vmAsset("p\($0)") }))
        let vm = CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
        vm.applyPageLimit(200)
        await vm.load()
        vm.currentPhotoId = "p80"

        await vm.setPageLimit(500)

        let queries = await api.pageQueries
        #expect(vm.pageLimit == 500)
        #expect(queries.last?.limit == 500, "页变大重取一次，按新页大小")
        #expect(queries.last?.cursor == nil, "重取的是首页")
        #expect(vm.currentPhotoId == "p80", "当前照片仍在新的首页内")
    }

    // MARK: - Wave5 批次 2：B3 浏览状态恢复

    /// B3 夹具：独立 UserDefaults suite + 可注入存档（测完清理，不碰真实默认值）。
    private func makeViewStateStore() -> (store: CullingViewStateStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "culling-viewstate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return (CullingViewStateStore(defaults: defaults), defaults, suiteName)
    }

    @Test("B3：进页恢复筛选/范围/排序/布局，并跨页定位到存档里的当前照片")
    func restoresViewStateAndSeeksCurrentPhoto() async throws {
        let (store, defaults, suiteName) = makeViewStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionId = "s-restore"

        var filters = CullingViewFilters()
        filters.unreviewedOnly = true
        filters.rating = 4
        store.save(CullingViewState(
            scope: ScopeMode.filtered.rawValue,
            filters: filters,
            sort: CullingSort.ratingDesc.rawValue,
            layout: CullingLayoutMode.grid.rawValue,
            density: CullingGridDensity.l.rawValue,
            currentPhotoId: "p501",
            filmstripExpanded: false,
            inspectorVisible: false), sessionId: sessionId)

        let api = StubCullingAPI()
        await api.setPageResults([
            CullingPage(
                assets: (1...500).map { vmAsset("p\($0)") }, total: 520,
                nextCursor: CullingPageCursor(sort: .ratingDesc, numberKey: 5, rowId: 500)),
            CullingPage(assets: (501...520).map { vmAsset("p\($0)") }, total: 520),
        ])
        let vm = CullingViewModel(
            sessionId: sessionId, culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm.viewStateStore = store
        vm.viewStateDebounceMilliseconds = 0
        vm.viewStateSleep = { _ in await Task.yield() }

        let restored = try #require(vm.takeSavedViewState())
        #expect(restored.layout == CullingLayoutMode.grid.rawValue)
        #expect(vm.scopeMode == .filtered)
        #expect(vm.filterState.unreviewedOnly)
        #expect(vm.filterState.rating == 4)
        #expect(vm.sortMode == .ratingDesc)
        #expect(vm.savedViewLayout == .grid)
        #expect(vm.savedViewDensity == .l)
        #expect(vm.savedViewInspectorVisible == false)
        #expect(vm.savedViewFilmstripExpanded == false)

        // 与页面 .task 同序：先按恢复后的布局设置页大小，再首载。
        vm.applyPageLimit(CullingLayoutMode.grid.pageLimit)
        await vm.load()

        let queries = await api.pageQueries
        #expect(queries.count == 2, "首页 + 续读一页（目标在第 501 张）")
        #expect(queries.first?.scope == .filtered)
        #expect(queries.first?.sort == .ratingDesc)
        #expect(queries.first?.limit == CullingLayoutMode.grid.pageLimit)
        #expect(queries.last?.cursor != nil, "续页必须带键集游标")
        #expect(queries.last?.limit == CullingViewStateRestore.seekPageLimit,
                "定位用服务端单次上限的大页，不逐页 200 张爬")
        #expect(vm.page?.assets.count == 520)
        #expect(vm.currentPhotoId == "p501")
        #expect(vm.selectedPhotoIds == ["p501"], "只恢复当前照片，不恢复多选")
    }

    @Test("B3：存档里的照片已不存在 → 回退第一张并把回退结果写回存档")
    func restoresMissingPhotoFallsBackToFirst() async throws {
        let (store, defaults, suiteName) = makeViewStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionId = "s-missing"

        store.save(CullingViewState(
            scope: ScopeMode.all.rawValue,
            sort: CullingSort.importOrder.rawValue,
            layout: CullingLayoutMode.single.rawValue,
            density: CullingGridDensity.m.rawValue,
            currentPhotoId: "gone"), sessionId: sessionId)

        let api = StubCullingAPI()
        await api.setPageResults([
            CullingPage(assets: [vmAsset("p1"), vmAsset("p2")], total: 2)
        ])
        let vm = CullingViewModel(
            sessionId: sessionId, culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm.viewStateStore = store
        vm.viewStateDebounceMilliseconds = 0
        vm.viewStateSleep = { _ in await Task.yield() }

        _ = vm.takeSavedViewState()
        await vm.load()

        #expect(vm.currentPhotoId == "p1", "找不到就回退第一张")
        vm.flushViewStateSave()
        let saved = try #require(store.load(sessionId: sessionId))
        #expect(saved.currentPhotoId == "p1",
                "回退结果立即写回，下次进页不再 seek 一张已不存在的照片")
    }

    @Test("B3：没有存档时不改变默认行为，并直接进入可保存态")
    func restoreWithoutSavedStateKeepsDefaults() async throws {
        let (store, defaults, suiteName) = makeViewStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let api = StubCullingAPI()
        await api.setPageResults([
            CullingPage(assets: [vmAsset("p1"), vmAsset("p2")], total: 2)
        ])
        let vm = CullingViewModel(
            sessionId: "s-fresh", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm.viewStateStore = store

        #expect(vm.takeSavedViewState() == nil)
        #expect(vm.isViewStateRestorationFinished, "无存档也要允许后续保存")
        await vm.load()
        #expect(vm.currentPhotoId == "p1")
        #expect(vm.scopeMode == .all)
        #expect(vm.filterState.isActive == false)
    }

    @Test("B3：flush 后按会话落盘（筛选/范围/排序/当前照片/参考槽/布局面板）")
    func flushPersistsViewState() async throws {
        let (store, defaults, suiteName) = makeViewStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionId = "s-persist"

        let api = StubCullingAPI()
        await api.setPageResults([
            CullingPage(assets: [vmAsset("p1"), vmAsset("p2"), vmAsset("p3")], total: 3)
        ])
        let vm = CullingViewModel(
            sessionId: sessionId, culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm.viewStateStore = store
        vm.viewStateDebounceMilliseconds = 0
        vm.viewStateSleep = { _ in await Task.yield() }
        _ = vm.takeSavedViewState()
        await vm.load()

        vm.filterState.rating = 3
        vm.scopeMode = .filtered
        vm.sortMode = .captureAsc
        vm.currentPhotoId = "p2"
        let reference = CullingViewReference(
            photoId: "p1", filepath: "/shoot/p1.jpg", filename: "p1.jpg")
        vm.viewerReference = reference
        vm.noteViewChrome(
            layout: .compare2, density: .l,
            inspectorVisible: false, filmstripExpanded: false)
        vm.scheduleViewStateSave()
        vm.flushViewStateSave()

        let saved = try #require(store.load(sessionId: sessionId))
        #expect(saved.scope == ScopeMode.filtered.rawValue)
        #expect(saved.filters.rating == 3)
        #expect(saved.sort == CullingSort.captureAsc.rawValue)
        #expect(saved.currentPhotoId == "p2")
        #expect(saved.reference == reference)
        #expect(saved.layout == CullingLayoutMode.compare2.rawValue)
        #expect(saved.density == CullingGridDensity.l.rawValue)
        #expect(saved.inspectorVisible == false)
        #expect(saved.filmstripExpanded == false)

        // 新 VM（模拟重启）读回同一份存档：参考槽与布局面板都恢复。
        let vm2 = CullingViewModel(
            sessionId: sessionId, culling: StubCullingAPI(), navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm2.viewStateStore = store
        _ = vm2.takeSavedViewState()
        #expect(vm2.viewerReference == reference)
        #expect(vm2.savedViewLayout == .compare2)
        #expect(vm2.savedViewDensity == .l)
        #expect(vm2.filterState.rating == 3)
        #expect(vm2.sortMode == .captureAsc)
    }

    @Test("B3：shutdown 时把节流中的状态 flush 掉（会话关闭是最后落盘机会）")
    func shutdownFlushesPendingViewState() async throws {
        let (store, defaults, suiteName) = makeViewStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionId = "s-shutdown"

        let api = StubCullingAPI()
        await api.setPageResults([
            CullingPage(assets: [vmAsset("p1"), vmAsset("p2")], total: 2)
        ])
        let vm = CullingViewModel(
            sessionId: sessionId, culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub())
        vm.viewStateStore = store
        _ = vm.takeSavedViewState()
        await vm.load()
        vm.currentPhotoId = "p2"
        vm.scheduleViewStateSave()
        // 不调 flush：验证 shutdown 自己会写。
        vm.shutdown()

        let saved = try #require(store.load(sessionId: sessionId))
        #expect(saved.currentPhotoId == "p2")
    }
}
// MARK: - Wave5 batch6 / R6 + G11：淘汰红标 / C1 调整提示（VM 入口）

@Suite("CullingViewModel 淘汰红标与 C1 调整提示")
@MainActor
struct CullingRejectedColorTagViewModelTests {
    private func makeVM(api: StubCullingAPI) -> CullingViewModel {
        CullingViewModel(
            sessionId: "s1", culling: api, navigation: StubNavigationAPI(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(), quality: B5bQualityAPIStub()
        )
    }

    @Test("rejectedPhotoCount 走 CullingSummary：0 = 菜单禁用口径；随 summary 变化")
    func rejectedCountFollowsSummary() {
        let api = StubCullingAPI()
        let vm = makeVM(api: api)
        #expect(vm.rejectedPhotoCount == 0, "未加载 summary 前视为没有淘汰项")
        vm.summary = CullingSummary(
            totalGroups: 2, totalPhotos: 5, kept: 2, rejected: 3, pending: 0,
            rated: 1, labeled: 0)
        #expect(vm.rejectedPhotoCount == 3)
    }

    @Test("成功：只发 notice（带张数）、errorMessage 清空；sessionId 传给 API")
    func markRejectedSuccess() async {
        let api = StubCullingAPI()
        await api.setRejectedColorTagReport(C1VariantWritebackReport(written: 2))
        let vm = makeVM(api: api)
        await vm.markRejectedInCaptureOne()
        #expect(vm.errorMessage == nil)
        let calls = await api.rejectedColorTagCalls
        #expect(calls == ["s1"], "红标必须只写当前会话")
        guard case .text(let text)? = vm.notice?.payload else {
            Issue.record("期望文本 notice，实际 \(String(describing: vm.notice))")
            return
        }
        #expect(text.key == C1RejectedColorTagCopy.successTemplate)
        #expect(text.params == ["2"])
    }

    @Test("部分成功：errorMessage 落到 partialTemplate 并带四个计数（不谎报全成功）")
    func markRejectedPartial() async {
        let api = StubCullingAPI()
        await api.setRejectedColorTagReport(C1VariantWritebackReport(
            written: 1, notFound: ["/shoot/a.cr2"],
            skipped: 2, skippedMultiVariant: ["/shoot/b.cr2"]))
        let vm = makeVM(api: api)
        await vm.markRejectedInCaptureOne()
        #expect(vm.notice == nil)
        #expect(vm.errorMessage?.code == C1RejectedColorTagCopy.partialTemplate)
        #expect(vm.errorMessage?.params == ["1", "1", "1", "2"])
    }

    @Test("未接线（实现抛错）：显式失败落到 INVALID_PARAM，不装成功")
    func markRejectedNotWired() async {
        let api = StubCullingAPI()
        await api.setRejectedColorTagError(
            GatherError.invalidParameter(
                field: "writeRejectedColorTags", reason: "rejected color tag API not wired"))
        let vm = makeVM(api: api)
        await vm.markRejectedInCaptureOne()
        #expect(vm.notice == nil)
        #expect(vm.errorMessage?.code == GatherErrorCode.INVALID_PARAM.rawValue)
    }

    @Test("CullingAPI 默认实现 = 未接线：显式抛 INVALID_PARAM（不返回空报告伪造成功）")
    func protocolDefaultImplementationThrows() async {
        // B8CullingAPIStub（Support 夹具）没有覆写 → 走协议默认实现。
        let stub = B8CullingAPIStub()
        do {
            _ = try await stub.writeRejectedColorTags("s1")
            Issue.record("未接线的默认实现必须抛错，不能返回空报告")
        } catch let error as GatherError {
            #expect(error.code == .INVALID_PARAM)
        } catch {
            Issue.record("意外的错误类型：\(error)")
        }
    }

    @Test("G11：未注入 C1 往返扩展端口时，调整提示静默 nil（不阻塞看图）")
    func adjustmentHintIsSilentlyHidden() async {
        let vm = makeVM(api: StubCullingAPI())
        // 测试便利构造器注入的是具体 CaptureOneBridge（不是 C1RoundTripExtending 门面）
        // → 端口未接线：必须 nil，而不是抛错/阻塞。
        let hint = await vm.c1AdjustmentHint(for: "/shoot/a.cr2")
        #expect(hint == nil)
        let emptyPath = await vm.c1AdjustmentHint(for: "")
        #expect(emptyPath == nil)
    }
}

