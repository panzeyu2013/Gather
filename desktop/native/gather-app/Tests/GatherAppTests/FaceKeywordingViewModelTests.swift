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

    /// 构造 face.analyze 任务的成功终态事件（终态帧语义：update.message ==
    /// job.status.rawValue，GatherEventCenter.isTerminal 依赖该约定）。
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
                progressMessage: status.rawValue,
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
}
