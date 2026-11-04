// desktop/native/gather-app/Sources/GatherUI/Culling/TriageCalibration.swift
// 建议（triage）的置信度分档、校准面板与管线（§3.11.1–§3.11.3）。
//
// #6 S1a：这 5 个类型原本与 CullingViewModel 挤在同一个 +Triage.swift 里，但它们
// 既不是 VM 的成员、也不被 VM 的写路径依赖——搬出来后 +Triage.swift 只剩扩展方法，
// 校准面板也能单独构造（不拖整机装配）。
import Foundation
import GatherProtocol

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
    /// minSamples <= 0 = 不设门槛（与服务侧 TriageCalibrationService 同口径）。
    public var isApplicable: Bool { minSamples <= 0 || samples >= minSamples }

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

