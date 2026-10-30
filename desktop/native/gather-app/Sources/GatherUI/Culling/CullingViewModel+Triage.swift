// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Triage.swift
// P0 / T0：技术质量建议的 UI 状态与动作（生成 / 应用 / 复核队列）。
//
// 边界：
//   - 建议只写 Gather 决策（服务层 source=ai），本文件不触发任何 XMP 写回；
//   - 生成/应用都必须带当前 fingerprint；stale 时禁止应用；
//   - 应用是破坏性但可撤销的动作，确认由 View 的确认 sheet 提供，VM 不伪造 Confirmed。
import Foundation
import GatherProtocol

extension CullingViewModel {
    /// 当前会话的建议摘要；未生成时为 nil（不是 0）。
    public var triageSummary: TriageSummary? { summary?.triage }

    /// 建议是否已过期（指纹/策略不一致）。
    public var isTriageStale: Bool { triageSummary?.stale == true }

    /// 可应用的 keep/reject 建议数（review 不参与）。
    public var triageApplicableCount: Int {
        guard let counts = triageSummary?.counts else { return 0 }
        return counts.keep + counts.reject
    }

    /// 已完成技术质量分析的占比（0...100）。
    /// 建议只覆盖无人工决策的逻辑资产，不能拿 suggestions.total 当分母。
    public var triageCoveragePercent: Int {
        guard let coverage = triageSummary?.counts.coverage else { return 0 }
        return min(100, max(0, Int((coverage * 100).rounded())))
    }

    public var canGenerateTriage: Bool { !isTriageBusy && !sessionId.isEmpty }

    public var canApplyTriage: Bool {
        !isTriageBusy && !isTriageStale && !triageApplied && triageApplicableCount > 0
    }

    /// 当前策略是否真的使用模型信号（v1 下卡片不展示芯片，避免误导）。
    public var triageUsesModelSignals: Bool {
        triageSummary?.policyVersion == "triage-v2"
    }

    /// W1：读取当前照片的模型级信号（检查器卡片用）。失败/未接线 = nil，不弹错。
    public func loadModelReview() async {
        guard triageEnabled, let photoId = currentAsset?.photo.id else {
            currentModelReview = nil
            return
        }
        // 换照片时先清掉上一张的信号：`await` 期间界面已经按新 asset 渲染，
        // 旧值会被当成新照片的「主体闭眼/微笑/审美」，快速翻图时张冠李戴。
        if currentModelReview?.photoId != photoId { currentModelReview = nil }
        do {
            let review = try await cullingAPI.modelReview(photoId)
            // 快速翻图：晚到的旧照片结果不能盖到新照片上。
            guard currentAsset?.photo.id == photoId else { return }
            currentModelReview = review
        } catch {
            guard currentAsset?.photo.id == photoId else { return }
            currentModelReview = nil
        }
    }

    /// 生成/重新生成建议。成功后刷新 summary 与当前页角标。
    public func generateTriage(force: Bool = false) async {
        guard canGenerateTriage else { return }
        isTriageBusy = true
        triageError = nil
        var autoApplyRequested = false
        defer {
            isTriageBusy = false
            // 自动应用必须在 busy 复位之后：applyTriage 的 canApplyTriage
            // 要求 !isTriageBusy，直接在本函数里调会静默 no-op。
            if autoApplyRequested {
                Task { @MainActor [weak self] in
                    _ = await self?.applyTriage()
                }
            }
        }
        do {
            let result = try await cullingAPI.generateTriage(
                TriageGenerateInput(sessionId: sessionId, force: force)
            )
            triageApplied = false
            mergeTriageSummary(result)
            notice = CullingNotice("技术质量建议已生成")
            await loadPage(reset: true)
            // 生成结果是本次请求的权威值；summary 查询可能落后一帧，回填防抖动。
            mergeTriageSummary(result)
            // 自动应用（默认关）：门槛由服务端策略的 executionFloor 决定。
            if let provider = triageAutoApplyProvider, await provider() {
                autoApplyRequested = true
            }
        } catch {
            triageError = CommandError(error)
        }
    }

    /// 应用 keep/reject 建议。调用方必须已经过确认 sheet；失败时返回 nil 并保留错误。
    @discardableResult
    public func applyTriage(
        verdicts: [TriageVerdict] = [.keep, .reject],
        minConfidence: Double? = nil
    ) async -> TriageApplyResult? {
        guard canApplyTriage, let summary = triageSummary else {
            if isTriageStale {
                triageError = CommandError.localized("技术质量建议已过期，请重新生成")
            }
            return nil
        }
        isTriageBusy = true
        triageError = nil
        defer { isTriageBusy = false }
        do {
            let input = TriageApplyInput(
                sessionId: sessionId,
                verdicts: verdicts,
                minConfidence: minConfidence,
                fingerprint: summary.inputFingerprint
            )
            let result = try await cullingAPI.applyTriage(Confirmed(input))
            triageApplied = true
            triageHistoryOperationId = result.historyOperationId
            triageError = nil
            notice = CullingNotice(
                "已应用 %lld 条建议",
                params: ["\(result.appliedAssets)"]
            )
            postCullingChange()
            await loadPage(reset: true)
            return result
        } catch {
            triageError = CommandError(error)
            return nil
        }
    }

    /// 进入复核队列：只看待复核、低置信度优先、网格布局由调用方设置。
    // MARK: - P1 / E：把建议写回成可移植信号

    /// 准备写回输入（只分页读取，不写盘）。确认弹窗由 View 持有：
    /// VM 不得自行构造 Confirmed（D-011：破坏性入口的类型层确认）。
    public func prepareTriageWriteback(
        policy: TriageWritebackPolicy = .ratingOnlyWhenEmpty,
        ratingMode: TriageRatingMode? = nil
    ) async -> TriageWritebackInput? {
        var items: [TriageWritebackItem] = []
        var seen = Set<String>()
        var cursor: CullingPageCursor?
        var pages = 0
        do {
            repeat {
                let query = try CullingPageQuery(
                    sessionId: sessionId,
                    scope: .filtered,
                    filters: CullingFilters(triageVerdicts: [.keep, .reject]),
                    sort: .importOrder,
                    cursor: cursor,
                    limit: 200
                )
                let result = try await cullingAPI.page(query)
                for asset in result.assets {
                    guard let triage = asset.triage else { continue }
                    guard triage.verdict == .keep || triage.verdict == .reject else { continue }
                    guard seen.insert(asset.photo.id).inserted else { continue }
                    // 人工已决策（manual 且非 unreviewed）→ 服务端绝不写 rating，但信号仍记录。
                    let manuallyDecided = asset.state.source == .manual
                        && asset.state.pickState != .unreviewed
                    do {
                        items.append(try TriageWritebackItem(
                            photoId: asset.photo.id,
                            verdict: triage.verdict.rawValue,
                            manuallyDecided: manuallyDecided))
                    } catch {
                        // 显式校验失败不能被 try? 吞成"按钮没反应"。
                        triageError = CommandError(error)
                        return nil
                    }
                }
                cursor = result.nextCursor
                pages += 1
            } while cursor != nil && pages < 500   // 500×200 = 100k，与输入上限一致
        } catch {
            triageError = CommandError(error)
            return nil
        }
        guard !items.isEmpty else { return nil }
        do {
            return try TriageWritebackInput(
                policy: policy, ratingMode: ratingMode ?? triageRatingMode, items: items)
        } catch {
            triageError = CommandError(error)
            return nil
        }
    }

    /// 执行已确认的写回（Confirmed 只能由 View 的确认弹窗构造）。
    public func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async {
        do {
            let result = try await metadataAPI.applyTriageWriteback(input)
            if let failure = result.failed.first {
                triageError = CommandError(APIError.failed(failure.message))
            }
            // P1：用 undoAvailable 而不是 written.isEmpty —— 回读失败（uncertain）
            // 的照片可能已写盘，批次仍在，界面必须保留撤销入口。
            lastTriageWritebackBatchId = result.undoAvailable ? result.batchId : nil
            if !result.skipped.isEmpty {
                notice = CullingNotice(
                    "已处理；%lld 张无需写入（已有星级或人工决策）",
                    params: ["\(result.skipped.count)"])
            }
            await loadPage(reset: true)
        } catch {
            triageError = CommandError(error)
        }
    }

    /// 撤销最近一次建议写回（rating/关键词还原，私有信号清除）。
    public func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async {
        do {
            let result = try await metadataAPI.undoTriageWriteback(input)
            if result.failed.isEmpty {
                lastTriageWritebackBatchId = nil
            }
            if let failure = result.failed.first {
                triageError = CommandError(APIError.failed(failure.message))
            }
            // P1：星级因"盘上已被人工改动"跳过时必须可见，否则用户以为已还原。
            if !result.skipped.isEmpty {
                notice = CullingNotice(
                    "已撤销；%lld 张的星级已被人工改动，保留现值",
                    params: ["\(result.skipped.count)"])
            }
            await loadPage(reset: true)
        } catch {
            triageError = CommandError(error)
        }
    }

    public func showTriageReviewQueue() async {
        sortMode = .triageConfidenceAsc
        scopeMode = .filtered
        var next = FilterState()
        next.triageVerdicts = [.review]
        filterState = next
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    /// 从生成结果回填 summary（不覆盖其他 CullingSummary 字段）。
    func mergeTriageSummary(_ value: TriageSummary) {
        // 生成/应用可能发生在首帧 summary 尚未加载时；此时必须创建承载对象，
        // 否则 optional chaining 会静默丢掉本次生成结果。
        if var current = summary {
            current.triage = value
            summary = current
        } else {
            summary = CullingSummary(
                totalGroups: 0, totalPhotos: 0, kept: 0, rejected: 0,
                pending: 0, rated: 0, labeled: 0, triage: value)
        }
    }
}

// MARK: - 校准 / 置信度 / 管线（§3.11.1–§3.11.3）

/// 置信度三档（§3.11.3）。刻意不显示裸 confidence：0.83 看起来像精确概率。
public enum TriageConfidenceTier: String, Equatable, Sendable, CaseIterable {
    case high
    case medium
    case low

    /// 三档阈值（由设置的三个可执行置信度推导；默认值与 TriagePolicy 默认一致）。
    public static func tier(
        for confidence: Double,
        thresholds: TriageConfidenceThresholds = .default
    ) -> TriageConfidenceTier {
        guard confidence.isFinite else { return .low }
        if confidence >= thresholds.high { return .high }
        if confidence >= thresholds.medium { return .medium }
        return .low
    }
}

public struct TriageConfidenceThresholds: Equatable, Sendable {
    /// 高：可执行 keep 的下限（策略 keepConfidenceMin 与 minExecutable 取大）。
    public let high: Double
    /// 中：仍可展示为建议、但进入复核的门限（minExecutable）。
    public let medium: Double

    public init(high: Double, medium: Double) {
        self.high = max(0, min(1, high))
        self.medium = max(0, min(1, medium))
    }

    /// TriagePolicy 默认值（keep 0.60 / minExecutable 0.55）之上留一档余量：
    /// 0.75/0.55 —— 与「高置信才值得自动应用」的产品口径一致。
    public static let `default` = TriageConfidenceThresholds(high: 0.75, medium: 0.55)
}

/// 校准面板快照（UI 模型）。
///
/// 为什么不直接用应用层的 TriageCalibrationReport：GatherUI 不允许 import
/// GatherApplication（分层门禁），由 Host 做一次映射（字段一一对应，无逻辑）。
public struct TriageCalibrationPanelModel: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable, Identifiable {
        public let lowerBound: Double
        public let upperBound: Double
        public let samples: Int
        public let keepSuggestions: Int
        public let agreedKeep: Int

        public var id: Double { lowerBound }

        public init(
            lowerBound: Double, upperBound: Double, samples: Int,
            keepSuggestions: Int, agreedKeep: Int
        ) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.samples = samples
            self.keepSuggestions = keepSuggestions
            self.agreedKeep = agreedKeep
        }

        /// nil = 桶内没有 keep 建议（不是 0 精确率）。
        public var precision: Double? {
            guard keepSuggestions > 0 else { return nil }
            return Double(agreedKeep) / Double(keepSuggestions)
        }
    }

    public struct Suggestion: Equatable, Sendable, Identifiable {
        public let target: Double
        public let confidence: Double
        public let samples: Int
        public let keep: Int
        public let reject: Int
        public let review: Int

        public var id: Double { target }

        public init(
            target: Double, confidence: Double, samples: Int,
            keep: Int, reject: Int, review: Int
        ) {
            self.target = target
            self.confidence = confidence
            self.samples = samples
            self.keep = keep
            self.reject = reject
            self.review = review
        }
    }

    public let samples: Int
    public let minSamples: Int
    public let buckets: [Bucket]
    public let currentKeep: Double
    public let currentReject: Double
    public let currentMinExecutable: Double
    public let currentKeepPrecision: Double?
    public let suggestions: [Suggestion]

    public init(
        samples: Int, minSamples: Int, buckets: [Bucket],
        currentKeep: Double, currentReject: Double, currentMinExecutable: Double,
        currentKeepPrecision: Double?, suggestions: [Suggestion]
    ) {
        self.samples = samples
        self.minSamples = minSamples
        self.buckets = buckets
        self.currentKeep = currentKeep
        self.currentReject = currentReject
        self.currentMinExecutable = currentMinExecutable
        self.currentKeepPrecision = currentKeepPrecision
        self.suggestions = suggestions
    }

    /// 样本门禁：不足时只显示"样本不足"，禁用"应用"。
    public var isApplicable: Bool { minSamples > 0 && samples >= minSamples }

    /// 由当前设置推导的三档阈值（keep=高、minExecutable=中）。
    public var confidenceThresholds: TriageConfidenceThresholds {
        TriageConfidenceThresholds(high: currentKeep, medium: currentMinExecutable)
    }
}

/// 校准面板依赖：Host 用 TriageCalibrationService（经 CullingAPI）适配这两个闭包。
/// nil = 未接线：面板显示"校准未接线"，不崩、不假报成功。
public struct TriageCalibrationBridge {
    public var load: @MainActor () async throws -> TriageCalibrationPanelModel
    /// 应用建议阈值 → 返回应用后的 (keep, reject, minExecutable)。
    public var apply: @MainActor (TriageCalibrationPanelModel.Suggestion) async throws
        -> (keep: Double, reject: Double, minExecutable: Double)

    public init(
        load: @escaping @MainActor () async throws -> TriageCalibrationPanelModel,
        apply: @escaping @MainActor (TriageCalibrationPanelModel.Suggestion) async throws
            -> (keep: Double, reject: Double, minExecutable: Double)
    ) {
        self.load = load
        self.apply = apply
    }
}

/// 校准面板状态机。
///
/// 独立于 CullingViewModel 的原因：校准只在设置 sheet 里用一次，塞进挑片 VM
/// 会多出一堆一生只用一次的状态；而 View 用 @State 持有本类即可。
@MainActor
@Observable
public final class TriageCalibrationViewModel {
    public private(set) var model: TriageCalibrationPanelModel?
    public private(set) var error: CommandError?
    public private(set) var isBusy = false
    /// 最近一次应用成功的阈值（面板回显"当前值"）。
    public private(set) var appliedThreshold: Double?

    public init() {}

    public var canApply: Bool {
        guard let model, model.isApplicable, !isBusy, !model.suggestions.isEmpty else { return false }
        return true
    }

    /// 拉取报告；bridge 为 nil 时只落一条"未接线"提示（不假装成功）。
    public func refresh(_ bridge: TriageCalibrationBridge?) async {
        guard let bridge else {
            error = CommandError.localized("校准未接线（缺少 CullingAPI 的校准方法）")
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            model = try await bridge.load()
        } catch {
            self.error = CommandError(error)
        }
    }

    /// 应用一条建议阈值（写设置键 → 建议自动 stale，由服务层/宿主重算）。
    public func apply(
        _ suggestion: TriageCalibrationPanelModel.Suggestion,
        bridge: TriageCalibrationBridge?
    ) async {
        guard let bridge, let loaded = model, loaded.isApplicable else {
            error = CommandError.localized("样本不足，暂不能应用校准阈值")
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let applied = try await bridge.apply(suggestion)
            appliedThreshold = applied.keep
            // 应用后重取：曲线/当前值都要反映新设置。
            model = try await bridge.load()
        } catch {
            self.error = CommandError(error)
        }
    }
}

/// §3.11.1：导入后自动初审管线的 UI 投影（纯映射，无状态、无 API 依赖）。
public struct TriagePipelineProgress: Equatable, Sendable {
    public let phase: String
    public let current: Int
    public let total: Int
    public let isRunning: Bool
    /// 取消/部分失败：已产出的建议保留但标记 partial（不写 apply）。
    public let isPartial: Bool
    public let message: String

    public init(
        phase: String, current: Int, total: Int,
        isRunning: Bool, isPartial: Bool, message: String
    ) {
        self.phase = phase
        self.current = current
        self.total = total
        self.isRunning = isRunning
        self.isPartial = isPartial
        self.message = message
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(total)))
    }
}

extension CullingViewModel {
    /// 管线 job → 进度投影（nil = 没有在跑/没有历史）。
    /// 取消（cancelled）与中断（interrupted）都算 partial：**不要**显示成成功。
    public func triagePipelineProgress(_ job: AnalysisJobData?) -> TriagePipelineProgress? {
        guard let job else { return nil }
        let running = job.status == .running || job.status == .queued || job.status == .cancelling
        let partial = job.status == .cancelled || job.status == .interrupted
        return TriagePipelineProgress(
            phase: job.progressMessage.isEmpty ? job.type.rawValue : job.progressMessage,
            current: job.progressCurrent,
            total: job.progressTotal,
            isRunning: running,
            isPartial: partial,
            message: job.errorMessage)
    }

    /// 当前照片所在建议的置信度三档（阈值来自校准报告；未加载时用默认）。
    public func triageConfidenceTier(
        _ confidence: Double,
        thresholds: TriageConfidenceThresholds = .default
    ) -> TriageConfidenceTier {
        TriageConfidenceTier.tier(for: confidence, thresholds: thresholds)
    }
}
