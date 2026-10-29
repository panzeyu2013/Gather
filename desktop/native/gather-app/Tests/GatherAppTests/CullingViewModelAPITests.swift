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
    pickState: PickState = .unreviewed
) -> CullingAsset {
    CullingAsset(
        photo: vmPhoto(id),
        state: vmState(id, revision: revision, pickState: pickState),
        xmpPath: "/shoot/\(id).xmp",
        syncStatus: .clean,
        people: [],
        keywords: [],
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
    var summaryResult = CullingSummary(
        totalGroups: 0, totalPhotos: 0, kept: 0, rejected: 0, pending: 0, rated: 0, labeled: 0
    )
    var groupsResult: [CullingGroup] = []
    var syncStatusResult = CullingSyncStatus(summary: vmSyncSummary())
    var historyResult: [CullingHistoryOperation] = []
    var updateResult = CullingUpdateResult(states: [], xmpPath: "", syncStatus: .clean)
    var batchUpdateResults: [CullingUpdateResult] = []
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
    var pageError: GatherError?
    var updateError: GatherError?

    private(set) var pageQueries: [CullingPageQuery] = []
    private(set) var historyQueries: [CullingHistoryQuery] = []
    private(set) var updateInputs: [CullingUpdateInput] = []
    private(set) var batchUpdateInputs: [CullingBatchUpdateInput] = []
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
    private(set) var triageGenerateCalls = 0

    func setPage(_ value: CullingPage) { pageResult = value }
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

    func page(_ query: CullingPageQuery) async throws -> CullingPage {
        pageQueries.append(query)
        if let pageError { throw pageError }
        return pageResult
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
        if let updateError { throw updateError }
        return updateResult
    }

    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult] {
        batchUpdateInputs.append(input)
        return batchUpdateResults
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
    ) async throws -> ClientSelectionImportResult {
        ClientSelectionImportResult(picked: 0, applied: 0, skipped: 0)
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

        await vm.batchUpdate(patch: CullingUpdatePatch(pickState: .rejected))

        let inputs = await api.batchUpdateInputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.photoIds == ["p1", "p2"])
        #expect(inputs.first?.patch.pickState == .rejected)
        #expect(vm.undoOperation?.id == 11)
        #expect(vm.undoOperation?.entries.count == 2)
        #expect(vm.page?.assets.filter { $0.state.pickState == .rejected }.count == 2)
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
        vm.setTriageAutoGenerate(true)

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
        await awaitNegativeWindow(.milliseconds(100))
        let stopped = jobs.listFilters.count
        await awaitNegativeWindow(.milliseconds(200))
        #expect(jobs.listFilters.count == stopped, "隐藏后不得继续轮询 JobAPI.list")

        // 恢复：仍在排队的画质任务重新开轮询（进度不丢）。
        vm.setVisible(true)
        #expect(await waitUntilAsync(timeout: 5) { jobs.listFilters.count > stopped })

        // 关闭：取消轮询；setVisible(true) 明确 no-op。
        vm.shutdown()
        // 同隐藏窗口：关闭前已在途的调用先落定。
        await awaitNegativeWindow(.milliseconds(100))
        let shutDown = jobs.listFilters.count
        vm.setVisible(true)
        await awaitNegativeWindow(.milliseconds(200))
        #expect(jobs.listFilters.count == shutDown, "shutdown 后 setVisible(true) 不得重启轮询")
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
}
