// UI 对齐修复轮（§十一 11.11）：全局设施的单元测试。
// 覆盖 GatherLocalization 回退语义、GatherEventCenter 终态判定与
// GatherToast 自动消失/手动关闭。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

@Suite("GatherLocalization", .serialized)
struct GatherLocalizationTests {
    /// 中文断言前钉死语言：本机系统语言可能是 en，文案层已随 appLanguage 变化。
    /// 切语言必须在 AppLanguageLock 内：否则并行套件会读到临时语言（既有 flake）。
    private func withChineseCopy(_ body: () -> Void) {
        AppLanguageLock.withCopy("zh-CN", body)
    }

    // 原 2 条用例（已知错误码 / 未知码回退）：同一函数仅输入不同 → 参数化。
    // exact=false 对应原 `.contains(...)` 断言，语义逐条保留。
    @Test("errorText：已知错误码返回中文文案 / 未知码回退通用文案", arguments: [
        ("SESSION_NOT_FOUND", "工作区不存在", true),
        ("C1_NOT_RUNNING", "Capture One", false),
        ("C1_NO_SELECTED_PHOTOS", "选择", false),
        ("NOT_A_REAL_CODE", "发生未知错误，请稍后重试", true),
    ])
    private func errorTextMatrix(code: String, expected: String, exact: Bool) {
        withChineseCopy {
            let text = GatherLocalization.errorText(code)
            if exact {
                #expect(text == expected)
            } else {
                #expect(text.contains(expected))
            }
        }
    }

    @Test("参数化错误码按模板插值（CODE::p1::p2）")
    func parameterizedCodesInterpolate() {
        withChineseCopy {
            #expect(GatherLocalization.errorText("FILTER_FIELD_UNKNOWN::rating") == "未知的筛选字段：rating")
            #expect(GatherLocalization.errorText("CULLING_REVISION_CONFLICT::3::5") == "挑片版本冲突：期望 3，当前 5")
            #expect(GatherLocalization.errorText("FILTER_FIELD_UNKNOWN") == "未知的筛选字段：")
            #expect(GatherLocalization.message(for: RouterCommandError(message: "FILTER_FIELD_UNKNOWN::label")) == "未知的筛选字段：label")
        }
    }

    @Test("jobErrorMessage 仅翻译错误码，诊断原文回退")
    func jobErrorMessageSemantics() {
        withChineseCopy {
            #expect(GatherLocalization.jobErrorMessage("SIM_NO_PHOTOS") == "当前工作区没有照片")
            #expect(GatherLocalization.jobErrorMessage("worker_error") == "发生未知错误，请稍后重试")
            #expect(GatherLocalization.jobErrorMessage(nil) == "发生未知错误，请稍后重试")
        }
    }

    @Test("message(for:) 翻译 RouterCommandError 中的错误码")
    func messageForTranslatesCode() {
        withChineseCopy {
            #expect(GatherLocalization.message(for: RouterCommandError(message: "PERSON_NOT_FOUND")) == "人物不存在")
            #expect(GatherLocalization.message(for: RouterCommandError(message: "诊断信息")) == "诊断信息")
        }
    }

    @Test("cancellationNotice：四处取消文案逐字一致，且与 Culling 变体不同")
    func cancellationNoticeCopy() {
        withChineseCopy {
            // 合并前 Duplicates/Settings/FaceKeywording/Similarity 的原文案。
            #expect(GatherLocalization.cancellationNotice("写入 XMP") == "已取消“写入 XMP”，未执行任何更改")
            #expect(GatherLocalization.cancellationNotice("") == "已取消“”，未执行任何更改")
            // Culling 的 noteCancelledAction 是另一句，不得被并入。
            #expect(GatherLocalization.cancellationNotice("写入 XMP")
                != String(format: GatherLocalization.l("已取消：%@"), "写入 XMP"))
        }
    }

    @Test("任务状态/类型/进度相位映射（zh）")
    func jobLabels() {
        withChineseCopy {
            #expect(GatherLocalization.jobStatusText("running") == "运行中")
            #expect(GatherLocalization.jobStatusText("unknown") == "unknown")
            #expect(GatherLocalization.jobTypeText("face.analyze") == "人脸分析")
            #expect(GatherLocalization.progressPhaseText("similarity.cluster") == "正在聚类相似照片…")
            #expect(GatherLocalization.progressPhaseText(nil) == "正在处理…")
            #expect(GatherLocalization.progressPhaseText("no.such.phase") == "正在处理…")
        }
    }

    @Test("任务文案/通用回退跟随 appLanguage（en 表齐全，不再恒中文）")
    func jobLabelsFollowLanguage() {
        AppLanguageLock.withCopy("en") {
        #expect(GatherLocalization.jobStatusText("running") == "Running")
        #expect(GatherLocalization.jobStatusText("queued") == "Queued")
        #expect(GatherLocalization.jobTypeText("face.analyze") == "Face Analysis")
        #expect(GatherLocalization.progressPhaseText("similarity.cluster") == "Clustering similar photos…")
        #expect(GatherLocalization.progressPhaseText(nil) == "Processing…")
        #expect(GatherLocalization.jobErrorMessage(nil) == "Something went wrong. Please try again later.")
        #expect(GatherLocalization.errorText("NOT_A_REAL_CODE") == "Something went wrong. Please try again later.")
        }
    }

    @Test("l() 查 Apple 本地化表：zh 回退 key、en 返回翻译、未知 key 回退")
    func localizedLookup() {
        AppLanguageLock.withStableCopy {
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
}

/// 观察者闭包在 @Sendable 上下文执行（NotificationCenter），不能捕获可变局部
/// 变量做累加。线程安全说明（Swift 6 `Sendable`）：可变状态
/// `terminalEvents`/`progressCount` 只在 `lock`（NSLock）临界区内读写，
/// 观察者队列固定为 .main，读写不重入；锁纪律无法被编译器静态验证，故 @unchecked。
private final class JobEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var terminalEvents: [GatherJobEvent] = []
    private var progressCount = 0

    func appendTerminal(_ event: GatherJobEvent) {
        lock.lock()
        terminalEvents.append(event)
        lock.unlock()
    }

    func bumpProgress() {
        lock.lock()
        progressCount += 1
        lock.unlock()
    }

    var terminalSnapshot: [GatherJobEvent] {
        lock.lock()
        defer { lock.unlock() }
        return terminalEvents
    }

    var progress: Int {
        lock.lock()
        defer { lock.unlock() }
        return progressCount
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

    @Test("终态判定：只看 job.status；message 为真实进度/错误文案时不漏判")
    func terminalDetection() {
        let succeeded = Self.job(id: "j1", status: .succeeded)
        #expect(GatherJobEvent(job: succeeded, update: JobProgressUpdate(current: 1, total: 1, message: "succeeded")).isTerminal)
        // 终态帧的 update.message 是真实 progressMessage/errorMessage（不再等于
        // status.rawValue），判定必须只看状态，否则漏判。
        let terminalWithRealMessage = GatherJobEvent(job: succeeded, update: JobProgressUpdate(current: 1, total: 5, message: "index.done"))
        #expect(terminalWithRealMessage.isTerminal)
        let running = Self.job(id: "j2", status: .running)
        #expect(!GatherJobEvent(job: running, update: JobProgressUpdate(message: "index.scanning")).isTerminal)
    }

    // MARK: - 终态事件发射（GatherEventCenter emit 路径；状态机判定）

    @MainActor
    @Test("非终态帧只发 jobProgress；running→succeeded 转移（message 是真实文案）发 jobTerminal")
    func terminalTransitionEmitsTerminal() {
        let center = GatherEventCenter.shared
        let sink = JobEventSink()
        let terminalToken = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.jobTerminal, object: nil, queue: .main
        ) { note in
            if let event = note.object as? GatherJobEvent { sink.appendTerminal(event) }
        }
        let progressToken = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.jobProgress, object: nil, queue: .main
        ) { _ in sink.bumpProgress() }
        defer {
            NotificationCenter.default.removeObserver(terminalToken)
            NotificationCenter.default.removeObserver(progressToken)
        }

        let jobId = "transition-\(UUID().uuidString)"

        // 非终态帧：仅 jobProgress，不发 jobTerminal。
        center.post(job: Self.job(id: jobId, status: .running), update: JobProgressUpdate(current: 4, total: 5, message: "index.scanning"))
        #expect(sink.progress == 1)
        #expect(sink.terminalSnapshot.isEmpty)

        // 终态转移：status 已 succeeded（message 仍是上一帧的真实进度文案）
        // → 按状态判定发 jobTerminal。
        center.post(job: Self.job(id: jobId, status: .succeeded), update: JobProgressUpdate(current: 5, total: 5, message: "index.scanning"))
        #expect(sink.progress == 2)
        #expect(sink.terminalSnapshot.count == 1)
        #expect(sink.terminalSnapshot[0].job.id == jobId)
        #expect(sink.terminalSnapshot[0].job.status == .succeeded)
    }

    @MainActor
    @Test("首次见到即终态帧同样发 jobTerminal")
    func firstSightingTerminalEmitsTerminal() {
        let center = GatherEventCenter.shared
        let sink = JobEventSink()
        let terminalToken = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.jobTerminal, object: nil, queue: .main
        ) { note in
            if let event = note.object as? GatherJobEvent { sink.appendTerminal(event) }
        }
        defer {
            NotificationCenter.default.removeObserver(terminalToken)
        }

        let jobId = "first-seen-\(UUID().uuidString)"
        center.post(job: Self.job(id: jobId, status: .succeeded), update: JobProgressUpdate(current: 1, total: 1, message: "index.done"))
        #expect(sink.terminalSnapshot.count == 1)
        #expect(sink.terminalSnapshot[0].job.status == .succeeded)
    }
}

// .serialized：三个用例共用进程级单例 GatherToastCenter.shared。并行执行时
// autoDismiss 在 5s 睡眠期间，manualDismiss 会留下 "a"、stacking 会整体清空 ——
// 「toasts 为空」的结论会退化成对调度顺序的依赖（本来就是脆的）。串行化后该
// 断言只反映被测行为；用例本身都是毫秒级，串行化不增加墙钟时间。
@Suite("GatherToast", .serialized)
struct GatherToastTests {
    @MainActor
    private func freshCenter() -> GatherToastCenter {
        let center = GatherToastCenter.shared
        for toast in center.toasts { center.dismiss(id: toast.id) }
        return center
    }

    @MainActor
    @Test("生产默认自动消失时长为 5s")
    func productionDefaultAutoDismissDelay() {
        #expect(GatherToastCenter.shared.autoDismissDelay == .seconds(5))
    }

    @MainActor
    @Test("show 入列且到达注入的自动消失时长后移除")
    func autoDismiss() async throws {
        // 注入 50ms 而非等满生产默认的 5s：被测行为（到期后自动移除）不变，
        // 但不再让这个用例成为整个 app 套件的墙钟下界。
        let center = GatherToastCenter(autoDismissDelay: .milliseconds(50))
        center.show(type: .success, message: "测试")
        #expect(center.toasts.count == 1)
        let shownId = try #require(center.toasts.first?.id)
        // 不写死 2s：MainActor 满载时兜底上限由 AsyncWait（默认 10s，可配置）统一提供。
        #expect(await waitUntilAsync { !center.toasts.contains { $0.id == shownId } },
                "该 toast 应在注入的 50ms 后自动移除")
        #expect(!center.toasts.contains { $0.id == shownId })
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
