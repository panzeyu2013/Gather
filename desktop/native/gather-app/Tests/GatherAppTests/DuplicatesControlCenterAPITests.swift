// desktop/native/gather-app/Tests/GatherAppTests/DuplicatesControlCenterAPITests.swift
// Cut 1 / B5b：DuplicatesViewModel 与 SessionControlViewModel 的 API 边界测试。
//
// 覆盖：
// - DuplicatesViewModel：scan/groups/resolve/resolveMember 走 DuplicateAPI，
//   resolve/resolveMember 只从确认分支构造 Confirmed<T>（source=userDialog）；
//   扫描取消（JobCancelledError）走 notice 而非错误条；cancelScan 走
//   JobAPI.cancel（事件 jobId 未到时按 jobs.list 活跃任务兜底）；
//   DuplicateServiceError.groupNotFound（无 GatherErrorCode）经
//   APIErrorPresentation 回落通用文案，原始英文诊断不上屏；
// - SessionControlViewModel：index.scan 走 JobAPI.start（metadataScan +
//   dedupeKey 逐字一致）、quality.analyze 走 QualityAPI 且返回的 job 立即并入
//   列表，随后 load() 轮询 JobAPI.list 反映进度；retry/retryFailedJobs 走
//   JobAPI.retry；错误经 APIErrorPresentation 漏斗。
//
// 说明：ControlCenter 当前 UI 没有取消入口（历史如此），"cancel" 的迁移点是
// DuplicatesViewModel.cancelScan；quality.get 在本页也没有调用点（QualityAPI
// 的 results 已可用，无 UI 消费者）。两者都在 B5b 报告中列明。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

// MARK: - 夹具

private func b5bSession() -> SessionData {
    SessionData(
        id: "s1",
        name: "Workspace",
        status: .photosLoaded,
        photoCount: 0,
        analysisStatus: .idle,
        writebackStatus: .idle,
        importSource: "local",
        sourcePath: "/shoot",
        failedWritebackCount: 0,
        truncatedImport: false,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func b5bWorkspace(
    failedJobs: [WorkspaceFailedJob] = [],
    indexing: WorkspaceIndexingStatus = .idle
) -> WorkspaceStatus {
    WorkspaceStatus(
        sessionId: "s1",
        stage: .analyzed,
        softFlags: WorkspaceSoftFlags(culled: false, exported: false),
        indexing: WorkspaceIndexingProgress(total: 0, done: 0, percent: 0, status: indexing),
        staleAnalyses: [],
        xmp: WorkspaceXmpCounts(pending: 0, conflict: 0),
        offlinePhotos: 0,
        failedJobs: failedJobs,
        recommendedNext: nil,
        generatedAt: ""
    )
}

@MainActor
private func makeControlViewModel(
    jobAPI: B5bJobAPIStub = B5bJobAPIStub(),
    qualityAPI: B5bQualityAPIStub = B5bQualityAPIStub(),
    workspace: WorkspaceStatus = b5bWorkspace()
) async throws -> SessionControlViewModel {
    // B8.2a：session.get / workspace.status / culling.sync_status 全部走类型化
    // 夹具（SessionAPI + CullingAPI），不再维护 [命令: JSONValue] 响应表。
    let sessionAPI = B8SessionAPIStub(session: b5bSession(), status: workspace)
    let viewModel = SessionControlViewModel(
        sessionId: "s1",
        session: sessionAPI,
        culling: B8CullingAPIStub(),
        jobAPI: jobAPI,
        qualityAPI: qualityAPI
    )
    await viewModel.load()
    return viewModel
}

// MARK: - DuplicatesViewModel

@MainActor
@Suite("B5b DuplicatesViewModel API 迁移")
struct DuplicatesViewModelAPITests {
    @Test("scan：DuplicateAPI.scan 收到 sessionId/阈值，结果与阈值落状态")
    func scanUsesDuplicateAPI() async {
        let scanResult = DuplicateScanResult(
            exactGroups: [], visualGroups: [], totalDuplicates: 3
        )
        let duplicate = B5bDuplicateAPIStub()
        duplicate.scanResult = scanResult
        let jobs = B5bJobAPIStub()
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: jobs)
        vm.threshold = 7

        await vm.scan()

        #expect(duplicate.scanInputs.count == 1)
        #expect(duplicate.scanInputs.first?.sessionId == "s1")
        #expect(duplicate.scanInputs.first?.visualThreshold == 7)
        #expect(vm.scanResult == scanResult)
        #expect(vm.scannedThreshold == 7)
        #expect(vm.notice != nil)
        #expect(vm.errorMessage == nil)
        // scan 成功后刷新分组（load 也走 DuplicateAPI）。
        #expect(duplicate.groupsCalls == ["s1"])
        #expect(vm.isScanning == false)
    }

    @Test("scan 取消：JobCancelledError 落 notice，不显示错误条")
    func scanCancellationIsNotice() async {
        let duplicate = B5bDuplicateAPIStub()
        duplicate.scanError = JobCancelledError()
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: B5bJobAPIStub())

        await vm.scan()

        #expect(vm.errorMessage == nil)
        #expect(vm.notice?.key.contains("取消") == true)
        #expect(vm.scanResult == nil)
    }

    @Test("load：分组走 DuplicateAPI.groups，错误落 CommandError（码/参数）")
    func loadUsesGroupsAPI() async {
        let duplicate = B5bDuplicateAPIStub()
        let group = b5bDuplicateGroup(id: 3, photoIds: ["p1", "p2"])
        duplicate.groups = [group]
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: B5bJobAPIStub())

        await vm.load()
        #expect(vm.groups.map(\.id) == [3])

        let error = GatherError(code: .INVALID_PARAM, params: ["field": "sessionId"])
        duplicate.groupsError = error
        await vm.load()
        // Cut 4 / 4a-3b-1：VM 只存错误载体，文案在渲染期本地化；断言码/参数。
        #expect(vm.errorMessage?.code == "INVALID_PARAM")
        #expect(vm.errorMessage?.params == ["sessionId"])
    }

    @Test("resolve：Confirmed(source=.userDialog) + 本地 patch")
    func resolveUsesConfirmed() async {
        let duplicate = B5bDuplicateAPIStub()
        let group = b5bDuplicateGroup(id: 5, photoIds: ["p1", "p2"])
        duplicate.groups = [group]
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: B5bJobAPIStub())
        await vm.load()

        await vm.resolveGroup(group, resolution: .keepOne, confirmed: true)

        #expect(duplicate.resolveInputs.count == 1)
        #expect(duplicate.resolveInputs.first?.source == .userDialog)
        #expect(duplicate.resolveInputs.first?.value.groupId == 5)
        #expect(duplicate.resolveInputs.first?.value.resolution == .keepOne)
        let patched = vm.groups.first { $0.id == 5 }
        #expect(patched?.resolution == "keep_one")
        #expect(patched?.members.filter(\.isKept).count == 1)
        // 推荐保留 = 分数最高（fileSize/mtime 最大的最后一张）。
        #expect(patched?.members.last?.isKept == true)
        #expect(vm.notice?.resolved(with: L10n(language: .zhCN)).contains("#5") == true)
    }

    @Test("resolve/resolveMember 未确认：不调用 API")
    func unconfirmedDoesNotCallAPI() async {
        let duplicate = B5bDuplicateAPIStub()
        let group = b5bDuplicateGroup(id: 1)
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: B5bJobAPIStub())

        await vm.resolveGroup(group, resolution: .keepAll, confirmed: false)
        await vm.setMemberKept(group.members[0], isKept: false, confirmed: false)

        #expect(duplicate.resolveInputs.isEmpty)
        #expect(duplicate.resolveMemberInputs.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("resolveMember：Confirmed 载荷驱动本地成员状态")
    func resolveMemberUsesConfirmed() async {
        let duplicate = B5bDuplicateAPIStub()
        let group = b5bDuplicateGroup(id: 2, photoIds: ["p1", "p2"])
        duplicate.groups = [group]
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: B5bJobAPIStub())
        await vm.load()
        let member = group.members[0]

        await vm.setMemberKept(member, isKept: false, confirmed: true)

        #expect(duplicate.resolveMemberInputs.count == 1)
        #expect(duplicate.resolveMemberInputs.first?.source == .userDialog)
        #expect(duplicate.resolveMemberInputs.first?.value.memberId == member.id)
        #expect(duplicate.resolveMemberInputs.first?.value.isKept == false)
        let patched = vm.groups.first?.members.first { $0.id == member.id }
        #expect(patched?.isKept == false)
        #expect(patched?.resolution == "keep_one")
    }

    @Test("DuplicateServiceError（非 GatherError）经漏斗回落，原始诊断不上屏")
    func duplicateServiceErrorIsCompatible() async {
        let duplicate = B5bDuplicateAPIStub()
        let group = b5bDuplicateGroup(id: 9)
        duplicate.groups = [group]
        duplicate.resolveError = DuplicateServiceError.groupNotFound(9)
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: duplicate, jobs: B5bJobAPIStub())
        await vm.load()

        await vm.resolveGroup(group, resolution: .keepAll, confirmed: true)

        // 无协议码的领域错误：code 只带 NSError 描述，渲染期回退通用文案。
        let l10n = L10n(language: .zhCN)
        let text = CommandErrorText.resolve(vm.errorMessage!, with: l10n)
        #expect(text == l10n.errorText("NOT_A_CODE"))
        #expect(!text.contains("Duplicate group"))
        // 失败不得就地 patch 成功状态。
        #expect(vm.groups.first?.resolution == nil)
    }

    @Test("cancelScan：事件 jobId 未到时按 jobs.list 活跃任务兜底走 JobAPI.cancel")
    func cancelScanFallsBackToJobAPI() async {
        let jobs = B5bJobAPIStub()
        jobs.jobs = [
            b5bJobData(id: "job-other", type: .duplicateScan, status: .running, scopeId: "s2"),
            b5bJobData(id: "job-dup", type: .duplicateScan, status: .running, scopeId: "s1"),
        ]
        let vm = DuplicatesViewModel(sessionId: "s1", duplicate: B5bDuplicateAPIStub(), jobs: jobs)

        await vm.cancelScan()

        #expect(jobs.cancelledIds == ["job-dup"])
        #expect(vm.notice != nil)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - ControlCenter

@MainActor
@Suite("B5b ControlCenter API 迁移")
struct ControlCenterAPITests {
    @Test("scanIndex：JobAPI.start 建 metadata.scan（dedupeKey 与旧 index.scan 一致）")
    func scanIndexUsesJobAPIStart() async throws {
        let jobs = B5bJobAPIStub()
        let vm = try await makeControlViewModel(jobAPI: jobs)

        await vm.scanIndex()

        #expect(jobs.startRequests.count == 1)
        let request = try #require(jobs.startRequests.first)
        #expect(request.type == .metadataScan)
        #expect(request.scopeType == "session")
        #expect(request.scopeId == "s1")
        #expect(request.dedupeKey == "metadata.scan:s1")
        #expect(
            request == JobCreateParams.metadataScan(sessionId: "s1", requestedPaths: nil),
            "ControlCenter 必须走协议层 metadata.scan 工厂"
        )
        #expect(vm.notice != nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.isWorking == false)
    }

    @Test("quality：analyze 走 QualityAPI，返回 job 立即可见；load 轮询反映进度")
    func qualityAnalyzeAndPolling() async throws {
        let running = b5bJobData(
            id: "q1", type: .qualityScore, status: .running, scopeId: "s1",
            progressCurrent: 2, progressTotal: 5
        )
        let jobs = B5bJobAPIStub()
        jobs.jobs = [running]
        let quality = B5bQualityAPIStub()
        quality.analyzeResult = running
        let vm = try await makeControlViewModel(jobAPI: jobs, qualityAPI: quality)

        await vm.analyzeQuality()

        #expect(quality.analyzeInputs.count == 1)
        #expect(quality.analyzeInputs.first?.sessionId == "s1")
        #expect(quality.analyzeInputs.first?.photoIds == nil)
        // 建单返回值先并入列表，用户不必等下一轮轮询才看到任务。
        #expect(vm.jobs.map(\.id) == ["q1"])
        #expect(await waitUntilAsync { vm.activeJobs.map(\.id) == ["q1"] }, "activeJobs 未在超时内反映 q1")
        #expect(vm.activeJobs.first?.progressCurrent == 2)

        // 轮询推进：任务完成后进入历史分组。
        jobs.jobs = [b5bJobData(id: "q1", type: .qualityScore, status: .succeeded, scopeId: "s1")]
        await vm.load()
        #expect(await waitUntilAsync { vm.historyJobs.map(\.id) == ["q1"] }, "historyJobs 未在超时内反映已完成任务")
        #expect(vm.activeJobs.isEmpty)
        #expect(vm.historyJobs.first?.status == .succeeded)
    }

    @Test("load：JobAPI.list(includeCheckpoint=false) 且只保留当前会话")
    func loadFiltersJobsBySession() async throws {
        let jobs = B5bJobAPIStub()
        jobs.jobs = [
            b5bJobData(id: "a", status: .running, scopeId: "s1"),
            b5bJobData(id: "b", status: .running, scopeId: "s2"),
        ]
        let vm = try await makeControlViewModel(jobAPI: jobs)

        #expect(await waitUntilAsync { vm.jobs.map(\.id) == ["a"] }, "jobs 未在超时内只保留当前会话")
        #expect(vm.activeJobs.map(\.id) == ["a"])
        #expect(jobs.listFilters.first?.includeCheckpoint == false)
    }

    @Test("retry：走 JobAPI.retry 并刷新任务列表")
    func retryUsesJobAPI() async throws {
        let jobs = B5bJobAPIStub()
        let vm = try await makeControlViewModel(jobAPI: jobs)

        vm.retry(jobId: "job-failed")

        #expect(await waitUntilAsync { jobs.retriedIds == ["job-failed"] }, "retry 未在超时内到达 JobAPI")
        #expect(await waitUntilAsync { vm.notice != nil }, "retry 完成文案未在超时内落地")
        #expect(jobs.retriedIds == ["job-failed"])
        #expect(vm.errorMessage == nil)
        #expect(!jobs.listFilters.isEmpty)
    }

    @Test("retryFailedJobs：逐个失败任务走 JobAPI.retry")
    func retryFailedJobsUsesJobAPI() async throws {
        let jobs = B5bJobAPIStub()
        let workspace = b5bWorkspace(failedJobs: [
            WorkspaceFailedJob(id: "f1", type: "quality.analyze", code: "worker_error", message: "boom"),
            WorkspaceFailedJob(id: "f2", type: "metadata.scan", code: "worker_error", message: "boom"),
        ])
        let vm = try await makeControlViewModel(jobAPI: jobs, workspace: workspace)

        vm.retryFailedJobs()

        // notice 在循环结束后才写入：两个条件一起等，避免在最后一轮
        // retry 返回与 notice 赋值之间读到中间态（MainActor 调度竞态）。
        #expect(await waitUntilAsync { jobs.retriedIds.count == 2 && vm.notice != nil }, "retryFailedJobs 未在超时内完成两次 retry 并写入 notice")
        #expect(jobs.retriedIds == ["f1", "f2"])
        #expect(vm.notice != nil)
    }

    @Test("错误：QualityAPI/GatherError 落错误载体（码/参数）")
    func qualityErrorUsesPresentation() async throws {
        let quality = B5bQualityAPIStub()
        let error = GatherError(code: .INVALID_PARAM, params: ["field": "sessionId"])
        quality.analyzeError = error
        let vm = try await makeControlViewModel(qualityAPI: quality)

        await vm.analyzeQuality()

        #expect(vm.errorMessage?.code == "INVALID_PARAM")
        #expect(vm.errorMessage?.params == ["sessionId"])
        #expect(vm.isWorking == false)
    }

    @Test("错误：jobs.list 失败走同一漏斗，不覆盖已加载的工作区状态")
    func jobListErrorUsesPresentation() async throws {
        let jobs = B5bJobAPIStub()
        let error = GatherError(code: .INVALID_PARAM, params: ["field": "job"])
        jobs.listError = error
        let vm = try await makeControlViewModel(jobAPI: jobs)

        #expect(await waitUntilAsync { vm.errorMessage != nil }, "jobs.list 失败未在超时内写入错误载体")
        #expect(vm.errorMessage?.code == "INVALID_PARAM")
        #expect(vm.errorMessage?.params == ["job"])
        #expect(vm.workspaceStatus != nil)
    }

    // MARK: - Cut 4 / 4a-2b：轮询迁入 VM

    @Test("4a-2b：setVisible 启停兜底轮询（幂等），shutdown 后不复活")
    func setVisibleControlsFallbackPolling() async {
        let sessionAPI = B8SessionAPIStub(session: b5bSession(), status: b5bWorkspace())
        let vm = SessionControlViewModel(
            sessionId: "s1",
            session: sessionAPI,
            culling: B8CullingAPIStub(),
            jobAPI: B5bJobAPIStub(),
            qualityAPI: B5bQualityAPIStub(),
            pollInterval: .milliseconds(20),
            activePollInterval: .milliseconds(10)
        )
        #expect(sessionAPI.getCalls.isEmpty, "VM 不再由 init 启动轮询，只由 setVisible 驱动")

        // 重复 setVisible(true) 不得叠加第二个轮询任务（startPolling 幂等）。
        vm.setVisible(true)
        vm.setVisible(true)
        #expect(await waitUntilAsync { sessionAPI.getCalls.count >= 2 }, "setVisible(true) 后兜底轮询未在超时内跑满两轮")

        vm.setVisible(false)
        // 隐藏只取消轮询：隐藏前已交给 provider 的一次 session.get 可能仍在途
        //（非隔离 async 调用进入 stub 前有调度窗口）。先等它落定再取基线，
        // 窗口内再出现新调用才说明轮询没停。
        await awaitNegativeWindow(.milliseconds(50))
        let running = sessionAPI.getCalls.count
        await awaitNegativeWindow(.milliseconds(100))
        #expect(sessionAPI.getCalls.count == running, "隐藏后兜底轮询必须停止")

        vm.setVisible(true)
        #expect(await waitUntilAsync { sessionAPI.getCalls.count > running }, "恢复可见后轮询必须重启")

        // stop 幂等：即使多调了 start，setVisible(false) 也必须全部停下。
        vm.setVisible(true)
        vm.setVisible(false)
        let stopped = sessionAPI.getCalls.count
        await awaitNegativeWindow(.milliseconds(100))
        #expect(sessionAPI.getCalls.count == stopped)

        vm.setVisible(true)
        #expect(await waitUntilAsync { sessionAPI.getCalls.count > stopped })

        vm.shutdown()
        // 同隐藏窗口：关闭前已在途的 session.get 先落定，避免把旧请求记成
        // 关闭后的新轮询。
        await awaitNegativeWindow(.milliseconds(50))
        let shutDown = sessionAPI.getCalls.count
        vm.setVisible(true)
        await awaitNegativeWindow(.milliseconds(100))
        #expect(sessionAPI.getCalls.count == shutDown, "shutdown 后 setVisible(true) 不得重启轮询")
    }
}

// MARK: - Duplicates 本地化（Cut 4 / 4b-2j）

/// 4b-2j：页面模型（PendingGroupResolution / PendingMemberDecision / VisualPreset）
/// 只存 key + 参数，由**显式传入**的 L10n 在渲染期解析。若实现退回进程全局
/// l()/appLanguage，下面的 en 断言会读到中文（或随系统语言漂移）而变红。
@MainActor
@Suite("Duplicates 本地化（4b-2j）")
struct DuplicatesLocalizationTests {
    /// DuplicatesView 的全部 key：60 个来自 4b-2j 前的 l() 调用点，
    /// 另外 5 个是此前已经迁移的 LocalizedText/l10n（4 条 notice + 操作失败横幅）。
    private static let pageKeys: [String] = [
        "保留最佳，丢弃其余",
        "全部保留",
        "推荐照片",
        "组 #%lld 共 %lld 张：仅保留推荐「%@」，其余 %lld 张标记为丢弃；被丢弃的照片会在导出时被排除，不会删除文件。",
        "组 #%lld 共 %lld 张全部标记为保留，不再从导出中排除任何成员。",
        "保留最佳（组 #%lld）",
        "全部保留（组 #%lld）",
        "保留此照片",
        "丢弃此照片",
        "将「%@」（%@）改回保留，重新参与导出。",
        "将「%@」（%@）标记为丢弃；该照片会从重复组中排除并在导出时被跳过，不会删除文件。",
        "保留「%@」",
        "丢弃「%@」",
        "严格",
        "均衡",
        "宽松",
        "重复扫描完成",
        "重复扫描已取消",
        "已请求取消重复扫描",
        "已处理重复组 #%lld",
        "操作失败：%@",
        "完全重复：%lld 组 · 视觉相似：%lld 组 · 总计重复：%lld 张",
        "当前匹配强度为 %lld，上面的结果来自 %lld；请重新扫描。",
        "扫描会先识别内容完全一致的文件，再查找视觉近似候选；不会删除照片。",
        "加载更多（还有 %lld 组）",
        "确认更改这张照片的保留状态？",
        "确认处理这个重复组？",
        "重复照片检测",
        "返回",
        "返回到上一页",
        "刷新",
        "刷新重复照片",
        "取消",
        "加载中…",
        "匹配强度",
        "视觉相似阈值",
        "0 (严格) — 10 (宽松)",
        "高级：相似阈值",
        "扫描中…",
        "开始扫描",
        "当前档位：%@",
        "类型",
        "完全重复",
        "视觉相似",
        "重复类型",
        "载入重复照片失败",
        "重试",
        "尚未扫描",
        "用上方的「开始扫描」检测内容完全一致的文件与视觉近似候选。",
        "未发现完全重复的照片",
        "当前工作区没有内容完全一致的文件。",
        "未发现视觉相似的照片",
        "可适当放宽匹配强度后重新扫描。",
        "保留最佳",
        "处理",
        "保留全部",
        "收起",
        "展开全部（共 %lld 张）",
        "%@ · %lld 张照片",
        "推荐",
        "保留",
        "丢弃",
        "%.1f MB",
        "查看照片",
        "在图库中打开这张照片",
    ]

    // 4b-2j：页面 key 的 en 覆盖不靠进程全局——逐条用显式 L10n(en) 查表。
    @Test("页面 65 个 key 在显式 L10n(en) 下全部出英文，不回落中文")
    func englishTableCoversPageKeys() {
        let en = L10n(language: .en)
        for key in Self.pageKeys {
            let text = en(key)
            #expect(!text.isEmpty, "en 查询为空：\(key)")
            // "%.1f MB" 是语言中性的单位模板，其余 key 在 en 表必须与中文 key 不同。
            #expect(text != key || key == "%.1f MB", "en 表缺 key：\(key)")
            #expect(!Self.containsCJK(text), "en 译文回落中文：\(key) -> \(text)")
        }
    }

    @Test("VisualPreset.label(with:)：档位名逐条走显式 L10n")
    func presetLabelsUseExplicitLanguage() {
        let zh = L10n(language: .zhCN)
        let en = L10n(language: .en)
        #expect(VisualPreset.allCases.map { $0.label(with: zh) } == ["严格", "均衡", "宽松"])
        #expect(VisualPreset.allCases.map { $0.label(with: en) } == ["Strict", "Balanced", "Relaxed"])
    }

    @Test("PendingGroupResolution：confirmLabel/scopeText/cancelCopy 在渲染期解析（zh/en）")
    func groupPendingResolutionRendersInBothLanguages() {
        let group = b5bDuplicateGroup(id: 5, photoIds: ["p1", "p2"])
        let zh = L10n(language: .zhCN)
        let en = L10n(language: .en)

        let keepOne = PendingGroupResolution(
            group: group, resolution: .keepOne, recommendedFilename: "p2.jpg"
        )
        #expect(keepOne.confirmLabel.resolve(with: zh) == "保留最佳，丢弃其余")
        #expect(keepOne.confirmLabel.resolve(with: en) == "Keep the best, discard the rest")
        #expect(keepOne.scopeText(with: zh)
            == "组 #5 共 2 张：仅保留推荐「p2.jpg」，其余 1 张标记为丢弃；被丢弃的照片会在导出时被排除，不会删除文件。")
        #expect(keepOne.scopeText(with: en)
            == "Group #5 has 2 photos: keep only the recommended “p2.jpg” and mark the other 1 as discarded; discarded photos are excluded from the export and never deleted.")
        #expect(keepOne.cancelCopy.resolve(with: zh) == "保留最佳（组 #5）")
        #expect(keepOne.cancelCopy.resolve(with: en) == "Keep the best (group #5)")

        let keepAll = PendingGroupResolution(
            group: group, resolution: .keepAll, recommendedFilename: nil
        )
        #expect(keepAll.confirmLabel.resolve(with: en) == "Keep all")
        #expect(keepAll.scopeText(with: zh)
            == "组 #5 共 2 张全部标记为保留，不再从导出中排除任何成员。")
        #expect(keepAll.scopeText(with: en)
            == "Group #5: all 2 photos stay kept; no member is excluded from the export anymore.")
        #expect(keepAll.cancelCopy.resolve(with: en) == "Keep all (group #5)")

        // 推荐文件名缺失 → 回落到「推荐照片」key，仍在渲染期本地化（不预先拼串）。
        let missingRecommendation = PendingGroupResolution(
            group: group, resolution: .keepOne, recommendedFilename: nil
        )
        #expect(missingRecommendation.scopeText(with: en)
            == "Group #5 has 2 photos: keep only the recommended “Recommended photo” and mark the other 1 as discarded; discarded photos are excluded from the export and never deleted.")
    }

    @Test("PendingMemberDecision：保留/丢弃两态的文案在渲染期解析（zh/en）")
    func memberPendingDecisionRendersInBothLanguages() {
        let group = b5bDuplicateGroup(id: 2, photoIds: ["p1"])
        let member = group.members[0]
        let zh = L10n(language: .zhCN)
        let en = L10n(language: .en)

        let keep = PendingMemberDecision(member: member, isKept: true)
        #expect(keep.confirmLabel.resolve(with: zh) == "保留此照片")
        #expect(keep.confirmLabel.resolve(with: en) == "Keep this photo")
        #expect(keep.scopeText(with: zh)
            == "将「p1.jpg」（/shoot/p1.jpg）改回保留，重新参与导出。")
        #expect(keep.scopeText(with: en)
            == "Change “p1.jpg” (/shoot/p1.jpg) back to kept so it takes part in the export again.")
        #expect(keep.cancelCopy.resolve(with: en) == "Keep “p1.jpg”")

        let discard = PendingMemberDecision(member: member, isKept: false)
        #expect(discard.confirmLabel.resolve(with: en) == "Discard this photo")
        #expect(discard.scopeText(with: zh)
            == "将「p1.jpg」（/shoot/p1.jpg）标记为丢弃；该照片会从重复组中排除并在导出时被跳过，不会删除文件。")
        #expect(discard.scopeText(with: en)
            == "Mark “p1.jpg” (/shoot/p1.jpg) as discarded; it is excluded from the duplicate group and skipped during export, but the file is never deleted.")
        #expect(discard.cancelCopy.resolve(with: zh) == "丢弃「p1.jpg」")
        #expect(discard.cancelCopy.resolve(with: en) == "Discard “p1.jpg”")
    }

    @Test("%.1f MB / %@ + %lld 模板：l10n.format 不传 locale，保留 %.1f")
    func numberAndMultiPlaceholderTemplates() {
        let zh = L10n(language: .zhCN)
        let en = L10n(language: .en)
        // 大数值不得出现千分位（String(format:locale:) 才会加）；%.1f 精度保留。
        #expect(zh.format("%.1f MB", 12345678.0) == "12345678.0 MB")
        #expect(en.format("%.1f MB", 12345678.0) == "12345678.0 MB")
        #expect(en.format("%@ · %lld 张照片", "Exact Duplicates", 12847)
            == "Exact Duplicates · 12847 photos")
        #expect(zh.format("%@ · %lld 张照片", "完全重复", 12847) == "完全重复 · 12847 张照片")
        #expect(en.format("展开全部（共 %lld 张）", 13) == "Expand all (13 photos)")
        #expect(en.format("当前档位：%@", VisualPreset.strict.label(with: en)) == "Current preset: Strict")
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
                || (0x3000...0x303F).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}
