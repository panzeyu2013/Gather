// FaceKeywordingViewModel 三步向导状态机单测：对齐 tests/unit/renderer/
// face-keywording-store.test.ts 的会话切换重置、迟到事件忽略、成功终态
// 进入审核等语义（Swift 端 VM 按 sessionId 重建，等价断言落在事件过滤上）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("FaceKeywordingViewModel 步骤状态机")
@MainActor
struct FaceKeywordingViewModelTests {
    private func makeViewModel(sessionId: String = "session-a") -> FaceKeywordingViewModel {
        FaceKeywordingViewModel(sessionId: sessionId, router: StubCommandRouter.empty())
    }

    /// 构造 face.analyze 任务的终态事件（GatherEventCenter.isTerminal 只看
    /// job.status；update.message 是真实 progressMessage，此处无需伪造）。
    private func terminalEvent(
        sessionId: String,
        status: AnalysisJobStatus = .succeeded
    ) -> GatherJobEvent {
        GatherJobEvent(
            job: AnalysisJobData(
                id: "job-1",
                type: .faceAnalyze,
                scopeType: "session",
                scopeId: sessionId,
                dedupeKey: "face.analyze:\(sessionId)",
                status: status,
                priority: 0,
                progressCurrent: 10,
                progressTotal: 10,
                progressMessage: "",
                inputFingerprint: "",
                modelId: "",
                modelVersion: "",
                checkpoint: [:],
                attemptCount: 0,
                leaseOwner: "",
                heartbeatAt: "",
                errorCode: "",
                errorMessage: "",
                createdAt: "",
                startedAt: "",
                finishedAt: "",
                updatedAt: ""
            ),
            update: JobProgressUpdate(current: 10, total: 10, message: status.rawValue)
        )
    }

    @Test("初始状态：分析步骤")
    func initialStepIsAnalyze() {
        let vm = makeViewModel()
        #expect(vm.step == .analyze)
        #expect(vm.analysisPhase == .idle)
    }

    @Test("分析成功终态（匹配会话）→ 进入审核步骤")
    func succeededTerminalMovesToReview() {
        let vm = makeViewModel(sessionId: "session-a")
        // 空库 stub：fkw.clusters/jobs.list/face.models_status 均返回空，load 安全。
        vm.applyJobEvent(terminalEvent(sessionId: "session-a"))
        #expect(vm.step == .review)
        #expect(vm.analysisPhase == .done)
    }

    @Test("迟到终态（其他会话的帧）→ 忽略，留在分析步骤")
    func lateTerminalFromOtherSessionIgnored() {
        let vm = makeViewModel(sessionId: "session-b")
        vm.applyJobEvent(terminalEvent(sessionId: "session-a"))
        #expect(vm.step == .analyze)
        #expect(vm.analysisPhase == .idle)
    }

    @Test("其他任务类型终态 → 忽略")
    func nonFaceJobIgnored() {
        let vm = makeViewModel(sessionId: "session-a")
        let event = terminalEvent(sessionId: "session-a")
        let nonFaceJob = AnalysisJobData(
            id: "job-1", type: .metadataScan, scopeType: "session",
            scopeId: "session-a", dedupeKey: "metadata.scan:session-a",
            status: .succeeded, priority: 0, progressCurrent: 10, progressTotal: 10,
            progressMessage: "metadata.scan", inputFingerprint: "", modelId: "",
            modelVersion: "", checkpoint: [:], attemptCount: 0, leaseOwner: "",
            heartbeatAt: "", errorCode: "", errorMessage: "", createdAt: "",
            startedAt: "", finishedAt: "", updatedAt: "")
        vm.applyJobEvent(GatherJobEvent(job: nonFaceJob, update: event.update))
        #expect(vm.step == .analyze)
    }

    @Test("进度帧 → 运行中，且不跳步骤")
    func progressFrameMarksRunning() {
        let vm = makeViewModel(sessionId: "session-a")
        let runningJob = AnalysisJobData(
            id: "job-1", type: .faceAnalyze, scopeType: "session",
            scopeId: "session-a", dedupeKey: "face.analyze:session-a",
            status: .running, priority: 0, progressCurrent: 3, progressTotal: 10,
            progressMessage: "face.detecting", inputFingerprint: "", modelId: "",
            modelVersion: "", checkpoint: [:], attemptCount: 0, leaseOwner: "",
            heartbeatAt: "", errorCode: "", errorMessage: "", createdAt: "",
            startedAt: "", finishedAt: "", updatedAt: "")
        vm.applyJobEvent(GatherJobEvent(
            job: runningJob,
            update: JobProgressUpdate(current: 3, total: 10, message: "face.detecting")
        ))
        #expect(vm.analysisPhase == .running)
        #expect(vm.step == .analyze)
        #expect(vm.progressCurrent == 3)
        #expect(vm.progressTotal == 10)
    }

    @Test("取消终态 → 取消态，不跳步骤")
    func cancelledStaysOnAnalyze() {
        let vm = makeViewModel(sessionId: "session-a")
        vm.applyJobEvent(terminalEvent(sessionId: "session-a", status: .cancelled))
        #expect(vm.analysisPhase == .cancelled)
        #expect(vm.step == .analyze)
    }

    @Test("select 簇 → 选中 + 清空合并目标")
    func selectClearsMergeTarget() {
        let vm = makeViewModel(sessionId: "session-a")
        vm.mergeTargetId = 99
        let cluster = FaceClusterData(
            id: 42, sessionId: "session-a", label: "簇 42", size: 3,
            status: "new", thumbnailBase64: "t1", binding: nil,
            thumbnailPhotoId: nil, members: [])
        vm.select(cluster)
        #expect(vm.selectedClusterId == 42)
        #expect(vm.mergeTargetId == nil)
    }

    @Test("setStep 回点已过步骤（审核可回分析）")
    func setStepAllowsBackNavigation() {
        let vm = makeViewModel(sessionId: "session-a")
        vm.applyJobEvent(terminalEvent(sessionId: "session-a"))
        #expect(vm.step == .review)
        vm.setStep(.analyze)
        #expect(vm.step == .analyze)
    }

    // ── initialRoleFilter 深链（Persons 页 ?role=，3.8/3.20 对齐）──

    /// 构造带指定角色绑定的簇（供 fkw.clusters stub 返回）。
    private func boundCluster(id: Int, roleName: String) -> FaceClusterData {
        FaceClusterData(
            id: id, sessionId: "session-a", label: "簇 \(id)", size: 2,
            status: "new", thumbnailBase64: "t\(id)",
            binding: FaceClusterBinding(roleName: roleName, keywords: [roleName]),
            thumbnailPhotoId: nil,
            members: [
                ClusterMember(
                    memberId: id * 10, photoId: "p\(id)", photoPath: "/vault/a\(id).jpg",
                    filename: "a\(id).jpg", bbox: [], confidence: 0.9
                )
            ]
        )
    }

    @Test("默认无 initialRoleFilter → roleFilter 为 nil，不跳步骤")
    func defaultInitialRoleFilterLeavesRoleFilterNil() {
        let vm = makeViewModel(sessionId: "session-a")
        vm.load()
        #expect(vm.roleFilter == nil)
        #expect(vm.step == .analyze)
    }

    @Test("initialRoleFilter 深链：播种角色过滤；分析已完成 → 直接进入审核步骤")
    func initialRoleFilterSeedsFilterAndJumpsToReview() {
        let router = StubCommandRouter(responses: [
            "fkw.clusters": .array([
                try! JSONValue(from: boundCluster(id: 1, roleName: "张三")),
            ]),
        ])
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router, initialRoleFilter: "张三")
        vm.load()
        #expect(vm.roleFilter == "张三", "深链角色应播种到角色过滤")
        #expect(vm.analysisPhase == .done, "存在簇 → 恢复为已完成")
        #expect(vm.step == .review, "分析已完成时深链直接落在审核步骤")
    }

    @Test("initialRoleFilter 深链：分析未完成时只播种过滤，不强制跳步骤")
    func initialRoleFilterSeedsFilterWithoutJump() {
        let vm = FaceKeywordingViewModel(
            sessionId: "session-a",
            router: StubCommandRouter.empty(),
            initialRoleFilter: "张三"
        )
        vm.load()
        #expect(vm.roleFilter == "张三")
        #expect(vm.analysisPhase == .idle)
        #expect(vm.step == .analyze)
    }

    @Test("initialRoleFilter 深链播种只执行一次：后续 load 不再强制跳回审核")
    func initialRoleFilterSeedIsOneShot() {
        let router = StubCommandRouter(responses: [
            "fkw.clusters": .array([
                try! JSONValue(from: boundCluster(id: 1, roleName: "张三")),
            ]),
        ])
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router, initialRoleFilter: "张三")
        vm.load()
        #expect(vm.step == .review)
        // 用户手动切到写回步骤后，刷新数据不应被深链拉回审核。
        vm.setStep(.writeback)
        vm.load()
        #expect(vm.step == .writeback)
        #expect(vm.roleFilter == "张三")
    }

    // ── 破坏性命令确认语义（confirmed 只能来自用户确认分支）──

    @Test("fkw.unbind：未确认不发命令，确认后带 confirmed: true")
    func unbindRequiresConfirmation() async {
        let router = RecordingCommandRouter()
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router)
        let cluster = FaceClusterData(
            id: 7, sessionId: "session-a", label: "簇 7", size: 3,
            status: "new", thumbnailBase64: "", binding: nil,
            thumbnailPhotoId: nil, members: [])
        await vm.unbind(cluster, confirmed: false)
        #expect(router.params(for: "fkw.unbind").isEmpty, "用户取消后不得发出 fkw.unbind")
        await vm.unbind(cluster, confirmed: true)
        #expect(router.confirmedCallCount("fkw.unbind") == 1, "确认后必须带 confirmed: true 发出")
    }

    @Test("fkw.writeback 重试：未确认不发命令")
    func retryRequiresConfirmation() async {
        let router = RecordingCommandRouter()
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router)
        await vm.retryFailed(confirmed: false)
        #expect(router.params(for: "fkw.writeback").isEmpty, "用户取消后不得发出 fkw.writeback")
    }

    @Test("fkw.cleanup：未确认不发命令，确认后带 confirmed: true")
    func cleanupRequiresConfirmation() async {
        let router = RecordingCommandRouter()
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router)
        await vm.cleanup(confirmed: false)
        #expect(router.params(for: "fkw.cleanup").isEmpty, "用户取消后不得发出 fkw.cleanup")
        await vm.cleanup(confirmed: true)
        #expect(router.confirmedCallCount("fkw.cleanup") == 1, "确认后必须带 confirmed: true 发出")
    }

    // ── 错误上屏判定（对抗审查高 4：中文可读原因被 errorText 吞掉） ──

    @Test("错误判定：FaceEmbeddingError 的中文原因原样上屏，不回落通用文案")
    func embeddingErrorReasonIsShownVerbatim() {
        let missing = "/tmp/gather-embed-\(UUID().uuidString).mlmodelc"
        let error = FaceEmbeddingError.modelNotFound(missing)
        AppLanguageLock.withStableCopy {
            let failure = FaceKeywordingViewModel.analysisFailure(for: error)
            #expect(failure.text == error.description, "必须原样复用 core 的中文原因")
            #expect(failure.text.contains("人脸嵌入模型不存在"), "实际：\(failure.text)")
            #expect(failure.text.contains(missing), "路径必须可见，用户才知道改哪个设置")
            #expect(failure.detail == nil, "中文可读原因已上屏，不需要 tooltip")
        }
    }

    @Test("错误判定：英文 NSError 散文不泄露——回落通用文案，原文只进 tooltip")
    func englishNSErrorProseDoesNotLeak() {
        let prose = "Failed to load model at /tmp/x.mlmodel: The file couldn't be opened."
        let error = NSError(
            domain: "GatherCore.FaceEmbeddingError",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: prose]
        )
        AppLanguageLock.withStableCopy {
            let failure = FaceKeywordingViewModel.analysisFailure(for: error)
            #expect(failure.text == GatherLocalization.errorText("NOT_A_CODE"), "必须回落通用文案")
            #expect(!failure.text.contains("Failed"))
            #expect(!failure.text.contains("couldn't"))
            #expect(failure.detail == prose, "原文必须保留在 tooltip")
        }
    }

    @Test("错误判定：已知错误码仍走本地化模板（与既有错误漏斗一致）")
    func knownErrorCodeStillTranslates() {
        AppLanguageLock.withStableCopy {
            let failure = FaceKeywordingViewModel.analysisFailure(forMessage: "SESSION_NOT_FOUND")
            #expect(failure.text == GatherLocalization.errorText("SESSION_NOT_FOUND"))
            #expect(failure.detail == nil)
        }
    }

    @Test("分析失败端到端：core 中文诊断经命令层错误信封上屏")
    func analyzeFailureShowsChineseReasonEndToEnd() async {
        let missing = "/tmp/gather-embed-\(UUID().uuidString).mlmodelc"
        let reason = FaceEmbeddingError.modelNotFound(missing).description
        let vm = FaceKeywordingViewModel(
            sessionId: "session-a",
            router: FailingAnalyzeRouter(errorPayload: reason)
        )
        await vm.analyze()
        #expect(vm.analysisPhase == .failed)
        let message = vm.errorMessage ?? ""
        #expect(message.contains("人脸嵌入模型不存在"), "实际：\(message)")
        #expect(message.contains(missing))
        #expect(AppLanguageLock.withStableCopy { message != GatherLocalization.errorText("NOT_A_CODE") })
        #expect(vm.errorDetail == nil)
        #expect(vm.errorTooltip == nil, "中文原因直接上屏，tooltip 不应重复")
    }

    @Test("分析失败端到端：英文诊断上屏为通用文案，原文只进 tooltip")
    func analyzeFailureHidesEnglishProseEndToEnd() async {
        let prose = "The operation couldn't be completed. (GatherCore.FaceEmbeddingError error 0.)"
        let vm = FaceKeywordingViewModel(
            sessionId: "session-a",
            router: FailingAnalyzeRouter(errorPayload: prose)
        )
        await vm.analyze()
        #expect(vm.analysisPhase == .failed)
        let message = vm.errorMessage ?? ""
        // analyze 是异步的，锁外执行期间其它套件可能临时切换界面语言；两种语言下的
        // 通用回退文案都算合法结果，但"必须是回退文案"这一断言不放宽。
        let zhFallback = AppLanguageLock.withCopy("zh-CN") { GatherLocalization.errorText("NOT_A_CODE") }
        let enFallback = AppLanguageLock.withCopy("en") { GatherLocalization.errorText("NOT_A_CODE") }
        #expect(message == zhFallback || message == enFallback, "实际：\(message)")
        #expect(!message.contains("operation"))
        #expect(vm.errorTooltip == prose)
    }

    // ── 部分失败可见性（新增高风险：done + encodingFailures > 0 伪装成完成） ──

    @Test("部分失败可见：done + encodingFailures > 0 必须警示，不得显示『分析完成』")
    func partialEncodingFailuresWarn() async {
        let router = StubCommandRouter()
        router.asyncResponses = [
            "fkw.analyze": try! JSONValue(from: FaceAnalysisResult(
                status: "done", detectionFailures: 0, encodingFailures: 2)),
        ]
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router)
        await vm.analyze()
        #expect(vm.analysisPhase == .done)
        let warning = vm.encodingFailureWarning ?? ""
        #expect(warning.contains("2"), "必须给出失败数量，实际：\(warning)")
        #expect(warning.contains("重试"), "必须说明下次分析会自动重试")
        #expect(vm.notice == nil, "存在编码失败时不得出示『人脸分析完成』")
    }

    @Test("零编码失败：警示清除并恢复『分析完成』提示")
    func cleanAnalysisClearsEncodingWarning() async {
        let router = StubCommandRouter()
        router.asyncResponses = [
            "fkw.analyze": try! JSONValue(from: FaceAnalysisResult(
                status: "done", detectionFailures: 0, encodingFailures: 3)),
        ]
        let vm = FaceKeywordingViewModel(sessionId: "session-a", router: router)
        await vm.analyze()
        #expect(vm.encodingFailureWarning != nil, "先有一次部分失败")

        router.asyncResponses = [
            "fkw.analyze": try! JSONValue(from: FaceAnalysisResult(
                status: "done", detectionFailures: 0, encodingFailures: 0)),
        ]
        await vm.analyze()
        #expect(vm.encodingFailureWarning == nil)
        #expect(vm.notice == GatherLocalization.l("人脸分析完成"))
    }
}

// MARK: - 确认语义测试支撑

/// 记录命令与参数的路由（StubCommandRouter 不回放调用记录，无法断言「没发命令」）。
private final class RecordingCommandRouter: CommandRouter, @unchecked Sendable {
    private(set) var executed: [(command: String, params: [String: GatherCore.JSONValue])] = []

    func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue {
        executed.append((command, params))
        return .null
    }

    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping @Sendable (WebResponse) -> Void
    ) {
        executed.append((command, params))
        completion(WebResponse(ok: true, data: .null))
    }

    /// 某命令的全部调用参数（用于「取消不发命令」断言）。
    func params(for command: String) -> [[String: GatherCore.JSONValue]] {
        executed.filter { $0.command == command }.map(\.params)
    }

    /// 某命令带 confirmed: true 的调用次数（用于「确认后才传 true」断言）。
    func confirmedCallCount(_ command: String) -> Int {
        params(for: command).filter { params in
            if case .bool(true) = params["confirmed"] { return true }
            return false
        }.count
    }
}

/// fkw.analyze 返回错误信封、其余命令成功：复现命令层错误的真实上抛路径
/// （WebResponse.error → NativeCommandClient 抛 NativeCommandError.failed）。
private final class FailingAnalyzeRouter: CommandRouter, @unchecked Sendable {
    private let errorPayload: String

    init(errorPayload: String) {
        self.errorPayload = errorPayload
    }

    func execute(
        _ command: String,
        params: [String: GatherCore.JSONValue]
    ) throws -> GatherCore.JSONValue {
        .null
    }

    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping @Sendable (WebResponse) -> Void
    ) {
        if command == "fkw.analyze" {
            completion(WebResponse(ok: false, error: errorPayload))
        } else {
            completion(WebResponse(ok: true, data: .null))
        }
    }
}
