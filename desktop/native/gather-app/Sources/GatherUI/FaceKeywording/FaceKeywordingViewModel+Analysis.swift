// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingViewModel+Analysis.swift
// Cut 4 / 4c-2b：分析/取消/重聚类、job 进度与挂载恢复、分析错误载体
// （原 FaceKeywordingView.swift 335-350、352-440、686-718、755-808 行，逐字搬移）。
import Foundation
import GatherProtocol

extension FaceKeywordingViewModel {
    /// analyze 成功后的可见结果：encodingFailures > 0 时不显示「分析完成」，
    /// 改为 warning 警示（这些脸没被编码，下次分析会自动重试——core 语义），
    /// 避免"部分失败"在 UI 上被伪装成一切正常。
    private func applyEncodingFailures(_ result: FaceAnalysisResult?) {
        let failures = result?.encodingFailures ?? 0
        guard failures > 0 else {
            encodingFailureWarning = nil
            notice = FaceNotice("人脸分析完成")
            return
        }
        encodingFailureWarning = LocalizedText(
            "有 %lld 张人脸编码失败，相关照片可能未被完整处理；下次分析会自动重试。",
            params: ["\(failures)"]
        )
        notice = nil
    }

    public func analyze() async {
        guard analysisPhase != .running else { return }
        analysisPhase = .running
        progressCurrent = 0
        progressTotal = 0
        progressPhase = "face.detecting"
        errorMessage = nil
        errorDetail = nil
        encodingFailureWarning = nil
        do {
            let result = try await face.analyze(FaceAnalyzeInput(
                sessionId: sessionId,
                eps: eps,
                minSamples: minSamples
            ))
            analysisResult = result
            if result.status == "cancelled" {
                analysisPhase = .cancelled
                notice = FaceNotice("人脸分析已取消")
                return
            }
            if result.status == "failed" {
                analysisPhase = .failed
                // 无内嵌前缀：横幅统一加「操作失败：」，避免双前缀。
                errorMessage = CommandError.localized(
                    "检测失败 %lld 张，编码失败 %lld 个人脸",
                    params: ["\(result.detectionFailures)", "\(result.encodingFailures)"]
                )
                return
            }
            finishAnalysis()
            applyEncodingFailures(analysisResult)
            await reload()
        } catch {
            if Self.rawMessage(for: error).localizedCaseInsensitiveContains("cancelled") {
                analysisPhase = .cancelled
                notice = FaceNotice("人脸分析已取消")
            } else {
                analysisPhase = .failed
                let failure = Self.analysisFailure(for: error)
                errorMessage = failure.error
                errorDetail = failure.detail
            }
        }
    }

    public func cancel() async {
        do {
            try await face.cancelAnalysis(sessionId)
            notice = FaceNotice("已请求取消人脸分析")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 「仅重新聚类」的影响面（破坏性确认文案用）：簇总数与其中已绑定人物/角色的簇数。
    /// 纯查询、无副作用，供 UI 在弹确认框前取真实计数。
    public func reclusterImpact() -> (clusterCount: Int, boundClusterCount: Int) {
        (
            clusters.count,
            clusters.filter { $0.binding != nil || $0.matchedPersonId != nil }.count
        )
    }

    public func recluster() async {
        guard analysisPhase != .running else { return }
        analysisPhase = .running
        errorMessage = nil
        errorDetail = nil
        do {
            try await face.recluster(FaceReclusterInput(
                sessionId: sessionId,
                eps: eps,
                minSamples: minSamples
            ))
            finishAnalysis()
            notice = FaceNotice("已重新聚类")
            await reload()
        } catch {
            if Self.rawMessage(for: error).localizedCaseInsensitiveContains("cancelled") {
                analysisPhase = .cancelled
            } else {
                analysisPhase = .failed
                let failure = Self.analysisFailure(for: error)
                errorMessage = failure.error
                errorDetail = failure.detail
            }
        }
    }

    /// TS jobs:progress 订阅入口（JobService 进度/终态帧）。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .faceAnalyze,
              event.job.scopeType == "session",
              event.job.scopeId == sessionId else { return }
        if event.isTerminal {
            switch event.job.status {
            case .succeeded:
                // TS finishAnalysis：succeeded 终态直接进入审核步骤。
                finishAnalysis()
                progressCurrent = event.job.progressCurrent
                progressTotal = event.job.progressTotal
                load()
            case .cancelled:
                analysisPhase = .cancelled
                notice = FaceNotice("人脸分析已取消")
            case .interrupted, .failed:
                analysisPhase = .failed
                // 与 analyze 的 catch 同一判定：中文可读原因直接上屏，
                // 英文散文回落通用文案并留在 tooltip。
                let failure = Self.analysisFailure(forMessage: event.job.errorMessage)
                errorMessage = failure.error
                errorDetail = failure.detail
            case .queued, .running, .cancelling:
                break
            }
            return
        }
        progressCurrent = event.update.current ?? event.job.progressCurrent
        progressTotal = event.update.total ?? event.job.progressTotal
        progressPhase = event.update.phase ?? event.update.message ?? "face.detecting"
        analysisPhase = .running
    }

    /// 分析类错误 → 错误载体（渲染期本地化）+ tooltip 原文。
    ///
    /// 判定规则（优先级）——只决定「什么进入 CommandError.code」，**不产出文案**：
    /// 1. 已知错误码（含 CODE::p1::p2 / CODE: 参数）→ code 存码值，
    ///    渲染期由 L10n.errorText 查表；
    /// 2. 其余散文（中英文都算）→ code 留空，原文只进 diagnostic/tooltip。
    ///
    /// Cut 4 / 4a-3b-2b 政策：core 的中文可读原因（FaceEmbeddingError.description）
    /// 也是 API 诊断，不再直接上屏——界面回退「发生未知错误」，原文保留在
    /// .help() 悬停提示里，供排查而非阅读。VM 本地校验文案走
    /// CommandError.localized，与 API 诊断严格分流。
    static func analysisFailure(for error: Error) -> (error: CommandError, detail: LocalizedText?) {
        // FaceEmbeddingError 是 core 的中文可读错误（CustomStringConvertible）；
        // 它不是 LocalizedError，NSError 桥接会丢掉 description，必须显式取。
        // Cut 3 / 3b-3（E-19 相邻）：经 UI 端口 DomainErrorMessaging 取原文
        // （GatherHost 为 FaceEmbeddingError 提供 conformance），UI 不 import 分析层。
        if let domain = error as? any DomainErrorMessaging,
           let message = domain.rawErrorMessage {
            return analysisFailure(forMessage: message)
        }
        return analysisFailure(forMessage: rawMessage(for: error))
    }

    static func analysisFailure(forMessage raw: String) -> (error: CommandError, detail: LocalizedText?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (CommandError(apiText: ""), nil) }
        // 已知码 → code 原样携带（渲染期查表）；码形判定只看码集合，不查文案表。
        if CommandError.isKnownErrorCode(trimmed) { return (CommandError(code: trimmed), nil) }
        // API/核心散文（中英文）只进 diagnostic + tooltip，不上屏。
        return (CommandError(apiText: trimmed), LocalizedText(trimmed))
    }

    private static func rawMessage(for error: Error) -> String {
        // API 边界：LiveFaceAPI 已把域错误收敛为 GatherError（码 + 可选原文），
        // 码值优先（errorText 可翻译）；原文只用于 tooltip/CJK 判定。
        if let gather = error as? GatherError {
            if let underlying = gather.underlying,
               !underlying.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return underlying
            }
            return gather.code.rawValue
        }
        // E-19 相邻：域错误原文经 UI 端口（GatherHost 为 JobServiceError /
        // FaceKwServiceError 提供 rawErrorMessage），GatherUI 不 import 领域层。
        if let domain = error as? any DomainErrorMessaging,
           let message = domain.rawErrorMessage,
           !message.isEmpty {
            return message
        }
        if let api = error as? APIError { return api.description }
        if let router = error as? RouterCommandError { return router.message }
        if let bridge = error as? BridgeError { return bridge.description }
        return (error as NSError).localizedDescription
    }
}
