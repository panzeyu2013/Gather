// UI 对齐修复轮（§十一 11.11）：全局设施的单元测试。
// 覆盖 GatherLocalization 回退语义、GatherEventCenter 终态判定与
// GatherToast 自动消失/手动关闭。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("GatherLocalization", .serialized)
struct GatherLocalizationTests {
    @Test("已知错误码返回中文文案")
    func knownCode() {
        #expect(GatherLocalization.errorText("SESSION_NOT_FOUND") == "工作区不存在")
        #expect(GatherLocalization.errorText("C1_NOT_RUNNING").contains("Capture One"))
        #expect(GatherLocalization.errorText("C1_NO_SELECTED_PHOTOS").contains("选择"))
    }

    @Test("未知错误码回退通用文案")
    func unknownCodeFallsBack() {
        #expect(GatherLocalization.errorText("NOT_A_REAL_CODE") == "发生未知错误，请稍后重试")
    }

    @Test("参数化错误码按模板插值（CODE::p1::p2）")
    func parameterizedCodesInterpolate() {
        #expect(GatherLocalization.errorText("FILTER_FIELD_UNKNOWN::rating") == "未知的筛选字段：rating")
        #expect(GatherLocalization.errorText("CULLING_REVISION_CONFLICT::3::5") == "挑片版本冲突：期望 3，当前 5")
        #expect(GatherLocalization.errorText("FILTER_FIELD_UNKNOWN") == "未知的筛选字段：")
        #expect(GatherLocalization.message(for: "FILTER_FIELD_UNKNOWN::label") == "未知的筛选字段：label")
    }

    @Test("jobErrorMessage 仅翻译错误码，诊断原文回退")
    func jobErrorMessageSemantics() {
        #expect(GatherLocalization.jobErrorMessage("SIM_NO_PHOTOS") == "当前工作区没有照片")
        #expect(GatherLocalization.jobErrorMessage("worker_error") == "发生未知错误，请稍后重试")
        #expect(GatherLocalization.jobErrorMessage(nil) == "发生未知错误，请稍后重试")
    }

    @Test("message(for:) 翻译错误码字符串；GatherErrorText 负责 Error → 文案")
    func messageForTranslatesCode() {
        #expect(GatherLocalization.message(for: "PERSON_NOT_FOUND") == "人物不存在")
        #expect(GatherLocalization.message(for: "诊断信息") == "诊断信息")
        #expect(GatherErrorText.message(for: CodedError(code: "PERSON_NOT_FOUND")) == "人物不存在")
        // 非码值错误经单点映射回退通用文案（与 UI 出口一致）。
        #expect(GatherErrorText.message(for: CodedError(code: "诊断信息")) == "发生未知错误，请稍后重试")
    }

    /// 领域错误的测试替身：description 即错误码（与各域 *Error 约定一致）。
    private struct CodedError: Error, CustomStringConvertible {
        let code: String
        var description: String { code }
    }

    @Test("任务状态/类型/进度相位映射")
    func jobLabels() {
        #expect(GatherLocalization.jobStatusText("running") == "运行中")
        #expect(GatherLocalization.jobStatusText("unknown") == "unknown")
        #expect(GatherLocalization.jobTypeText("face.analyze") == "人脸分析")
        #expect(GatherLocalization.progressPhaseText("similarity.cluster") == "正在聚类相似照片…")
        #expect(GatherLocalization.progressPhaseText(nil) == "正在处理…")
        #expect(GatherLocalization.progressPhaseText("no.such.phase") == "正在处理…")
    }

    @Test("l() 查 Apple 本地化表：zh 回退 key、en 返回翻译、未知 key 回退")
    func localizedLookup() {
        let original = GatherLocalization.appLanguage
        defer { GatherLocalization.setAppLanguage(original) }

        GatherLocalization.setAppLanguage("zh-CN")
        #expect(GatherLocalization.l("挑片与写回") == "挑片与写回")
        #expect(GatherLocalization.l("不存在的文案") == "不存在的文案")

        GatherLocalization.setAppLanguage("en")
        #expect(GatherLocalization.l("挑片与写回") == "Culling & Writeback")
        #expect(GatherLocalization.l("人脸库") == "Face Library")
        #expect(GatherLocalization.l("不存在的文案") == "不存在的文案")

        #expect(GatherLocalization.l(" 等 %d 个") == " and %d more")
        #expect(String(format: GatherLocalization.l("写回队列：%d 项"), 3) == "Writeback Queue: 3 Items")
    }
}

@Suite("GatherEventCenter")
struct GatherEventCenterTests {
    private static func job(id: String, status: AnalysisJobStatus) -> AnalysisJobData {
        AnalysisJobData(
            id: id, type: .metadataScan, scopeType: "session", scopeId: "s1",
            dedupeKey: "d", status: status, priority: 1,
            progressCurrent: 0, progressTotal: 0, progressMessage: "",
            inputFingerprint: "", modelId: "", modelVersion: "", checkpoint: [:],
            attemptCount: 1, leaseOwner: "", heartbeatAt: "",
            errorCode: "", errorMessage: "",
            createdAt: "2026-08-12T00:00:00Z", startedAt: "", finishedAt: "", updatedAt: "2026-08-12T00:00:00Z"
        )
    }

    @Test("终态帧判定：update.message == status.rawValue 且状态为终态")
    func terminalDetection() {
        let succeeded = Self.job(id: "j1", status: .succeeded)
        let terminal = GatherJobEvent(job: succeeded, update: JobProgressUpdate(current: 1, total: 1, message: "succeeded"))
        #expect(terminal.isTerminal)
        let progress = GatherJobEvent(job: succeeded, update: JobProgressUpdate(current: 1, total: 5, message: "index.scanning"))
        #expect(!progress.isTerminal)
        let running = Self.job(id: "j2", status: .running)
        #expect(!GatherJobEvent(job: running, update: JobProgressUpdate(message: "running")).isTerminal)
    }

    // MARK: - 终态转移检测（GatherEventCenter emit 路径；状态机判定补 message 启发式）

    @MainActor
    @Test("非终态帧只发 jobProgress；running→succeeded 转移（message 不匹配）发 jobTerminal")
    func terminalTransitionEmitsTerminal() {
        let center = GatherEventCenter.shared
        var terminalEvents: [GatherJobEvent] = []
        var progressCount = 0
        let terminalToken = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.jobTerminal, object: nil, queue: .main
        ) { note in
            if let event = note.object as? GatherJobEvent { terminalEvents.append(event) }
        }
        let progressToken = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.jobProgress, object: nil, queue: .main
        ) { _ in progressCount += 1 }
        defer {
            NotificationCenter.default.removeObserver(terminalToken)
            NotificationCenter.default.removeObserver(progressToken)
        }

        let jobId = "transition-\(UUID().uuidString)"

        // 非终态帧：仅 jobProgress，不发 jobTerminal。
        center.post(job: Self.job(id: jobId, status: .running), update: JobProgressUpdate(current: 4, total: 5, message: "index.scanning"))
        #expect(progressCount == 1)
        #expect(terminalEvents.isEmpty)

        // 终态转移：status 已 succeeded 但 message 不匹配（旧 message 启发式
        // 漏判场景）→ 状态机判定仍发 jobTerminal。
        center.post(job: Self.job(id: jobId, status: .succeeded), update: JobProgressUpdate(current: 5, total: 5, message: "index.scanning"))
        #expect(progressCount == 2)
        #expect(terminalEvents.count == 1)
        #expect(terminalEvents[0].job.id == jobId)
        #expect(terminalEvents[0].job.status == .succeeded)
    }

    @MainActor
    @Test("首次见到即终态（emitTerminal 约定帧）同样发 jobTerminal")
    func firstSightingTerminalEmitsTerminal() {
        let center = GatherEventCenter.shared
        var terminalEvents: [GatherJobEvent] = []
        let terminalToken = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.jobTerminal, object: nil, queue: .main
        ) { note in
            if let event = note.object as? GatherJobEvent { terminalEvents.append(event) }
        }
        defer {
            NotificationCenter.default.removeObserver(terminalToken)
        }

        let jobId = "first-seen-\(UUID().uuidString)"
        center.post(job: Self.job(id: jobId, status: .succeeded), update: JobProgressUpdate(current: 1, total: 1, message: "succeeded"))
        #expect(terminalEvents.count == 1)
        #expect(terminalEvents[0].job.status == .succeeded)
    }
}

@Suite("GatherToast")
struct GatherToastTests {
    @MainActor
    private func freshCenter() -> GatherToastCenter {
        let center = GatherToastCenter.shared
        for toast in center.toasts { center.dismiss(id: toast.id) }
        return center
    }

    @MainActor
    @Test("show 入列且 5s 后自动移除")
    func autoDismiss() async throws {
        let center = freshCenter()
        center.show(type: .success, message: "测试")
        #expect(center.toasts.count == 1)
        try await Task.sleep(for: .seconds(5.2))
        #expect(center.toasts.isEmpty)
    }

    @MainActor
    @Test("dismiss 手动移除指定项")
    func manualDismiss() {
        let center = freshCenter()
        center.show(type: .error, message: "a")
        center.show(type: .info, message: "b")
        #expect(center.toasts.count == 2)
        let first = center.toasts[0]
        #expect(first.message == "b")
        center.dismiss(id: first.id)
        #expect(center.toasts.count == 1)
        #expect(center.toasts[0].message == "a")
    }

    @MainActor
    @Test("可堆叠多条不同类型")
    func stacking() {
        let center = freshCenter()
        center.show(type: .warning, message: "w")
        center.show(type: .success, message: "s")
        #expect(center.toasts.map(\.type) == [.success, .warning])
        for toast in center.toasts { center.dismiss(id: toast.id) }
    }
}
