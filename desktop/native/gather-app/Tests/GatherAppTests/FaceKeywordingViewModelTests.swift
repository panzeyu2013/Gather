// FaceKeywordingViewModel 三步向导状态机单测：对齐 tests/unit/renderer/
// face-keywording-store.test.ts 的会话切换重置、迟到事件忽略、成功终态
// 进入审核等语义（Swift 端 VM 按 sessionId 重建，等价断言落在事件过滤上）。
//
// Cut 1 / B8.1a：VM 用 FaceAPI / JobAPI 的类型化替身构造；确认语义断言
// 类型化入参（Confirmed.source / clusterId），不再断言字符串命令名。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

@Suite("FaceKeywordingViewModel 步骤状态机", .serialized)
@MainActor
struct FaceKeywordingViewModelTests {
    /// 类型化三依赖装配；quality/jobs 生产构造器之外的上游不再经过字符串命令。
    private func makeStack(
        sessionId: String = "session-a",
        initialRoleFilter: String? = nil
    ) -> (FaceKeywordingViewModel, B8FaceAPIStub, B5bJobAPIStub) {
        let face = B8FaceAPIStub()
        let jobs = B5bJobAPIStub()
        let viewModel = FaceKeywordingViewModel(
            sessionId: sessionId,
            face: face,
            jobs: jobs,
            captureOne: CaptureOneBridge(),
            initialRoleFilter: initialRoleFilter
        )
        return (viewModel, face, jobs)
    }

    private func makeViewModel(sessionId: String = "session-a") -> FaceKeywordingViewModel {
        makeStack(sessionId: sessionId).0
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
        let cluster = b8FaceCluster(id: 42, sessionId: "session-a", size: 3)
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

    @Test("默认无 initialRoleFilter → roleFilter 为 nil，不跳步骤")
    func defaultInitialRoleFilterLeavesRoleFilterNil() async {
        let vm = makeViewModel(sessionId: "session-a")
        await vm.reload()
        #expect(vm.roleFilter == nil)
        #expect(vm.step == .analyze)
    }

    @Test("initialRoleFilter 深链：播种角色过滤；分析已完成 → 直接进入审核步骤")
    func initialRoleFilterSeedsFilterAndJumpsToReview() async {
        let (vm, face, _) = makeStack(
            sessionId: "session-a",
            initialRoleFilter: "张三"
        )
        face.clustersValue = [b8FaceCluster(id: 1, sessionId: "session-a", roleName: "张三")]
        await vm.reload()
        #expect(vm.roleFilter == "张三", "深链角色应播种到角色过滤")
        #expect(vm.analysisPhase == .done, "存在簇 → 恢复为已完成")
        #expect(vm.step == .review, "分析已完成时深链直接落在审核步骤")
    }

    @Test("initialRoleFilter 深链：分析未完成时只播种过滤，不强制跳步骤")
    func initialRoleFilterSeedsFilterWithoutJump() async {
        let (vm, _, _) = makeStack(
            sessionId: "session-a",
            initialRoleFilter: "张三"
        )
        await vm.reload()
        #expect(vm.roleFilter == "张三")
        #expect(vm.analysisPhase == .idle)
        #expect(vm.step == .analyze)
    }

    @Test("initialRoleFilter 深链播种只执行一次：后续 load 不再强制跳回审核")
    func initialRoleFilterSeedIsOneShot() async {
        let (vm, face, _) = makeStack(
            sessionId: "session-a",
            initialRoleFilter: "张三"
        )
        face.clustersValue = [b8FaceCluster(id: 1, sessionId: "session-a", roleName: "张三")]
        await vm.reload()
        #expect(vm.step == .review)
        // 用户手动切到写回步骤后，刷新数据不应被深链拉回审核。
        vm.setStep(.writeback)
        await vm.reload()
        #expect(vm.step == .writeback)
        #expect(vm.roleFilter == "张三")
    }

    // ── 破坏性动作确认语义（Confirmed 只能来自用户确认分支）──

    @Test("unbind：未确认不发 API，确认后带 Confirmed(.userDialog)")
    func unbindRequiresConfirmation() async {
        let (vm, face, _) = makeStack(sessionId: "session-a")
        let cluster = b8FaceCluster(id: 7, sessionId: "session-a", size: 3)
        await vm.unbind(cluster, confirmed: false)
        #expect(face.unbindInputs.isEmpty, "用户取消后不得调用 FaceAPI.unbind")
        await vm.unbind(cluster, confirmed: true)
        #expect(face.unbindInputs.count == 1, "确认后必须调用 FaceAPI.unbind")
        #expect(face.unbindInputs.first?.source == .userDialog)
        #expect(face.unbindInputs.first?.value.sessionId == "session-a")
        #expect(face.unbindInputs.first?.value.clusterId == 7)
    }

    @Test("writeback 重试：未确认不发 API")
    func retryRequiresConfirmation() async {
        let (vm, face, _) = makeStack(sessionId: "session-a")
        await vm.retryFailed(confirmed: false)
        #expect(face.writebackInputs.isEmpty, "用户取消后不得调用 FaceAPI.writeback")
    }

    @Test("cleanup：未确认不发 API，确认后带 Confirmed(.userDialog)")
    func cleanupRequiresConfirmation() async {
        let (vm, face, _) = makeStack(sessionId: "session-a")
        await vm.cleanup(confirmed: false)
        #expect(face.cleanupInputs.isEmpty, "用户取消后不得调用 FaceAPI.cleanup")
        await vm.cleanup(confirmed: true)
        #expect(face.cleanupInputs.count == 1, "确认后必须调用 FaceAPI.cleanup")
        #expect(face.cleanupInputs.first?.source == .userDialog)
        #expect(face.cleanupInputs.first?.value.sessionId == "session-a")
    }

    // ── 错误上屏判定（对抗审查高 4：中文可读原因被 errorText 吞掉） ──

    @Test("错误判定：core 中文原因只进 diagnostic/tooltip，不上屏（4a-3b-2b）")
    func embeddingErrorReasonGoesToTooltipOnly() {
        let missing = "/tmp/gather-embed-\(UUID().uuidString).mlmodelc"
        let error = FaceEmbeddingError.modelNotFound(missing)
        AppLanguageLock.withStableCopy {
            let failure = FaceKeywordingViewModel.analysisFailure(for: error)
            let l10n = L10n(language: .zhCN)
            let text = CommandErrorText.resolve(failure.error, with: l10n)
            #expect(text == l10n.errorText("NOT_A_CODE"), "API 中文诊断不得直接上屏")
            #expect(!text.contains("人脸嵌入模型不存在"))
            #expect(failure.error.diagnostic.contains("人脸嵌入模型不存在"))
            #expect(failure.error.diagnostic.contains(missing))
            #expect(failure.detail?.key.contains("人脸嵌入模型不存在") == true, "原文保留在 tooltip")
            #expect(failure.detail?.key.contains(missing) == true)
        }
    }

    @Test("错误判定：英文 NSError 散文不泄露——回落通用文案，原文只进 tooltip")
    func englishNSErrorProseDoesNotLeak() {
        let prose = "Failed to load model at /tmp/x.mlmodel: The file couldn't be opened."
        let error = NSError(
            domain: "FaceEmbeddingError",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: prose]
        )
        AppLanguageLock.withStableCopy {
            let failure = FaceKeywordingViewModel.analysisFailure(for: error)
            let l10n = L10n(language: .zhCN)
            let text = CommandErrorText.resolve(failure.error, with: l10n)
            #expect(text == l10n.errorText("NOT_A_CODE"), "必须回落通用文案")
            #expect(!text.contains("Failed"))
            #expect(!text.contains("couldn't"))
            #expect(failure.detail?.key == prose, "原文必须保留在 tooltip")
        }
    }

    @Test("错误判定：已知错误码仍走本地化模板（与既有错误漏斗一致）")
    func knownErrorCodeStillTranslates() {
        AppLanguageLock.withStableCopy {
            let failure = FaceKeywordingViewModel.analysisFailure(forMessage: "SESSION_NOT_FOUND")
            let l10n = L10n(language: .zhCN)
            #expect(failure.error.code == "SESSION_NOT_FOUND")
            #expect(CommandErrorText.resolve(failure.error, with: l10n) == l10n.errorText("SESSION_NOT_FOUND"))
            #expect(failure.detail == nil)
        }
    }

    @Test("分析失败端到端：core 中文诊断只进 tooltip，不上屏")
    func analyzeFailureHidesChineseReasonEndToEnd() async {
        let missing = "/tmp/gather-embed-\(UUID().uuidString).mlmodelc"
        let (vm, face, _) = makeStack(sessionId: "session-a")
        face.analyzeError = FaceEmbeddingError.modelNotFound(missing)

        await vm.analyze()

        #expect(vm.analysisPhase == .failed)
        let l10n = L10n(language: .zhCN)
        let message = CommandErrorText.resolve(vm.errorMessage!, with: l10n)
        #expect(message == l10n.errorText("NOT_A_CODE"), "实际：\(message)")
        #expect(!message.contains(missing))
        #expect(vm.errorDetail?.key.contains("人脸嵌入模型不存在") == true)
        #expect(vm.errorTooltip?.key.contains(missing) == true)
    }

    @Test("分析失败端到端：英文诊断上屏为通用文案，原文只进 tooltip")
    func analyzeFailureHidesEnglishProseEndToEnd() async {
        let prose = "The operation couldn't be completed. (FaceEmbeddingError error 0.)"
        let (vm, face, _) = makeStack(sessionId: "session-a")
        face.analyzeError = NSError(
            domain: "FaceEmbeddingError",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: prose]
        )

        await vm.analyze()

        #expect(vm.analysisPhase == .failed)
        // analyze 是异步的，锁外执行期间其它套件可能临时切换界面语言；两种语言下的
        // 通用回退文案都算合法结果，但"必须是回退文案"这一断言不放宽。
        let zhFallback = L10n(language: .zhCN).errorText("NOT_A_CODE")
        let enFallback = L10n(language: .en).errorText("NOT_A_CODE")
        let zhMessage = CommandErrorText.resolve(vm.errorMessage!, with: L10n(language: .zhCN))
        let enMessage = CommandErrorText.resolve(vm.errorMessage!, with: L10n(language: .en))
        #expect(zhMessage == zhFallback || enMessage == enFallback, "实际：\(zhMessage) / \(enMessage)")
        #expect(!zhMessage.contains("operation"))
        #expect(!enMessage.contains("operation"))
        #expect(vm.errorTooltip?.key == prose)
    }

    // ── 部分失败可见性（新增高风险：done + encodingFailures > 0 伪装成完成） ──

    @Test("部分失败可见：done + encodingFailures > 0 必须警示，不得显示『分析完成』")
    func partialEncodingFailuresWarn() async {
        let (vm, face, _) = makeStack(sessionId: "session-a")
        face.analyzeResultValue = FaceAnalysisResult(
            status: "done", detectionFailures: 0, encodingFailures: 2
        )
        await vm.analyze()
        #expect(vm.analysisPhase == .done)
        // Cut 4 / 4b-2b：VM 只存 key + 参数，渲染期才解析（这里固定 zh 断言）。
        let warning = vm.encodingFailureWarning
            .map { $0.resolve(with: L10n(language: .zhCN)) } ?? ""
        #expect(warning.contains("2"), "必须给出失败数量，实际：\(warning)")
        #expect(warning.contains("重试"), "必须说明下次分析会自动重试")
        #expect(vm.notice == nil, "存在编码失败时不得出示『人脸分析完成』")
    }

    @Test("零编码失败：警示清除并恢复『分析完成』提示")
    func cleanAnalysisClearsEncodingWarning() async {
        let (vm, face, _) = makeStack(sessionId: "session-a")
        face.analyzeResultValue = FaceAnalysisResult(
            status: "done", detectionFailures: 0, encodingFailures: 3
        )
        await vm.analyze()
        #expect(vm.encodingFailureWarning != nil, "先有一次部分失败")

        face.analyzeResultValue = FaceAnalysisResult(
            status: "done", detectionFailures: 0, encodingFailures: 0
        )
        await vm.analyze()
        #expect(vm.encodingFailureWarning == nil)
        #expect(vm.notice == FaceNotice("人脸分析完成"))
    }

    // ── 类型化输入（B8.1a：clusters / bind / 任务恢复） ──

    @Test("clusters/bind：reload 读 FaceAPI，bind 送角色与关键字并刷新")
    func clustersAndBindUseFaceAPI() async {
        let (vm, face, _) = makeStack(sessionId: "session-a")
        let cluster = b8FaceCluster(id: 7, sessionId: "session-a", roleName: "张三")
        face.clustersValue = [cluster]

        await vm.reload()
        #expect(face.clusterCalls == ["session-a"])
        #expect(vm.clusters.map(\.id) == [7])

        vm.select(cluster)
        vm.roleName = " 张三 "
        vm.keywords = "朋友, 旅行"
        await vm.bind(cluster)

        #expect(face.bindInputs.count == 1)
        #expect(face.bindInputs.first?.sessionId == "session-a")
        #expect(face.bindInputs.first?.clusterId == 7)
        #expect(face.bindInputs.first?.roleName == "张三", "角色名必须 trim")
        #expect(face.bindInputs.first?.keywords == ["朋友", "旅行"])
        #expect(face.clusterCalls.count == 2, "bind 成功后应 reload")
        #expect(vm.reviewActionError == nil)
    }

    @Test("reload：JobAPI 的活跃 face.analyze 恢复进度")
    func reloadRecoversRunningJob() async {
        let (vm, _, jobs) = makeStack(sessionId: "session-a")
        jobs.jobs = [b5bJobData(
            id: "job-face-1",
            type: .faceAnalyze,
            status: .running,
            scopeId: "session-a",
            progressCurrent: 4,
            progressTotal: 12,
            progressMessage: "face.detecting"
        )]

        await vm.reload()

        #expect(vm.analysisPhase == .running)
        #expect(vm.progressCurrent == 4)
        #expect(vm.progressTotal == 12)
        #expect(vm.progressPhase == "face.detecting")
    }
}
