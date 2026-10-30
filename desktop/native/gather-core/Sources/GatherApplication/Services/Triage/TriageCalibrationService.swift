// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriageCalibrationService.swift
// P1 下一波 / §3.11.2：技术质量建议的阈值校准（反馈样本 → 分桶精确率 → 建议阈值）。
//
// 纪律：
// - 样本只取**人工决定**（TriageFeedbackRepo 的 SQL 已 JOIN 过滤 source ∈ manual/imported），
//   AI 自动应用不算"用户同意"，否则精确率恒为 1；
// - 样本 < triage_calibration_min_samples 时报告依然可读（曲线/样本量可见），但
//   isApplicable=false、apply 抛 TRIAGE_NOT_READY —— 不自动应用、不偷偷调参；
// - 应用只写三个置信度设置键（triage_keep_confidence_min / triage_reject_confidence_min /
//   triage_min_executable_confidence），**不改 triage_policy 版本字符串**
//   （TriagePolicy.usesModelSignals 用 version == "triage-v2" 精确比较）。
//   这三个值本来就在 TriageService.thresholdsDigest 里参与 input_fingerprint，
//   因此写设置即让旧建议 stale，无需另造版本号。
import Foundation
import GatherProtocol
import GatherPersistence

/// 校准需要的最小样本设置键（已由组合根注册进 SettingsService）。
public enum TriageCalibrationKeys {
    public static let minSamples = "triage_calibration_min_samples"
    public static let keepConfidenceMin = "triage_keep_confidence_min"
    public static let rejectConfidenceMin = "triage_reject_confidence_min"
    public static let minExecutableConfidence = "triage_min_executable_confidence"
}

/// 校准的读写设置端口（生产实现是 SettingsService，测试注入字典假件）。
public protocol TriageCalibrationSettings {
    func number(for key: String, defaultValue: Double) -> Double
    func write(_ key: String, value: String) throws
}

public enum TriageCalibrationError: Error, Equatable, CustomStringConvertible, Sendable {
    case insufficientSamples(samples: Int, minimum: Int)
    case invalidThreshold(Double)
    case targetNotFound(Double)

    public var code: String {
        switch self {
        case .insufficientSamples: return GatherErrorCode.TRIAGE_NOT_READY.rawValue
        case .invalidThreshold, .targetNotFound: return GatherErrorCode.TRIAGE_POLICY_INVALID.rawValue
        }
    }

    public var description: String {
        switch self {
        case .insufficientSamples(let samples, let minimum):
            return "\(GatherErrorCode.TRIAGE_NOT_READY.rawValue): 样本不足（\(samples)/\(minimum)）"
        case .invalidThreshold(let value):
            return "\(GatherErrorCode.TRIAGE_POLICY_INVALID.rawValue): 阈值越界（\(value)）"
        case .targetNotFound(let target):
            return "\(GatherErrorCode.TRIAGE_POLICY_INVALID.rawValue): 目标精确率不可达（\(target)）"
        }
    }
}

/// 10 桶之一（0.0–0.1 … 0.9–1.0）。
public struct TriageCalibrationBucket: Equatable, Sendable {
    public let lowerBound: Double
    public let upperBound: Double
    /// 桶内样本数（含 reject 建议与"用户改待定"的样本）。
    public let samples: Int
    /// 桶内"建议 keep"的样本数 = 精确率分母。
    public let keepSuggestions: Int
    /// 建议 keep 且用户也 keep = 分子。
    public let agreedKeep: Int

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

/// 当前生效的三个可执行置信度（来自设置）。
public struct TriageCalibrationThresholds: Equatable, Sendable {
    public let keep: Double
    public let reject: Double
    public let minExecutable: Double

    public init(keep: Double, reject: Double, minExecutable: Double) {
        self.keep = keep
        self.reject = reject
        self.minExecutable = minExecutable
    }
}

/// 一条建议阈值（保精确率 0.90/0.95/0.98）。
public struct TriageCalibrationSuggestion: Equatable, Sendable {
    /// 目标精确率。
    public let target: Double
    /// 建议置信度下限：低于它的建议降级为 review。
    public let confidence: Double
    /// 达到该阈值的样本数（诊断用：样本太少的高精确率不可信）。
    public let samples: Int
    public let keepPrecision: Double?
    public let rejectPrecision: Double?
    /// 按该阈值重算的建议分布。
    public let keep: Int
    public let reject: Int
    public let review: Int

    public init(
        target: Double, confidence: Double, samples: Int,
        keepPrecision: Double?, rejectPrecision: Double?,
        keep: Int, reject: Int, review: Int
    ) {
        self.target = target
        self.confidence = confidence
        self.samples = samples
        self.keepPrecision = keepPrecision
        self.rejectPrecision = rejectPrecision
        self.keep = keep
        self.reject = reject
        self.review = review
    }
}

/// 分机型可靠性（"能做且诚实的是阈值校准 + 分机型/ISO 的可靠性报告"）。
public struct TriageCalibrationCameraReliability: Equatable, Sendable {
    public let cameraModel: String
    public let samples: Int
    public let keepPrecision: Double?

    public init(cameraModel: String, samples: Int, keepPrecision: Double?) {
        self.cameraModel = cameraModel
        self.samples = samples
        self.keepPrecision = keepPrecision
    }
}

public struct TriageCalibrationReport: Equatable, Sendable {
    /// nil = 全库（跨会话）口径。
    public let sessionId: String?
    public let samples: Int
    public let minSamples: Int
    public let buckets: [TriageCalibrationBucket]
    public let current: TriageCalibrationThresholds
    public let currentKeepPrecision: Double?
    public let currentRejectPrecision: Double?
    public let suggestions: [TriageCalibrationSuggestion]
    public let byCamera: [TriageCalibrationCameraReliability]
    public let generatedAt: String

    public init(
        sessionId: String?, samples: Int, minSamples: Int,
        buckets: [TriageCalibrationBucket],
        current: TriageCalibrationThresholds,
        currentKeepPrecision: Double?, currentRejectPrecision: Double?,
        suggestions: [TriageCalibrationSuggestion],
        byCamera: [TriageCalibrationCameraReliability],
        generatedAt: String
    ) {
        self.sessionId = sessionId
        self.samples = samples
        self.minSamples = minSamples
        self.buckets = buckets
        self.current = current
        self.currentKeepPrecision = currentKeepPrecision
        self.currentRejectPrecision = currentRejectPrecision
        self.suggestions = suggestions
        self.byCamera = byCamera
        self.generatedAt = generatedAt
    }

    /// 样本门禁：不足时 UI 只显示"样本不足"并禁用"应用"。
    public var isApplicable: Bool { samples >= minSamples && minSamples > 0 }

    /// 不可应用的原因（可直接上屏；nil = 可应用）。
    public var disabledReason: String? {
        guard !isApplicable else { return nil }
        return "样本不足（\(samples)/\(minSamples)）"
    }
}

public final class TriageCalibrationService {
    /// 保精确率的目标档位（plan §3.11.2）。
    public static let targets: [Double] = [0.90, 0.95, 0.98]
    /// 一条建议阈值至少要有这么多 keep 样本，否则"精确率 1.0"只是样本太少。
    public static let minimumThresholdSamples = 5
    /// 精确率分桶数。
    public static let bucketCount = 10
    /// 分机型报告最多列几个机型。
    public static let maxCameraRows = 5

    private let feedback: any TriageFeedbackStore
    private let settings: any TriageCalibrationSettings
    private let now: () -> String

    public init(
        feedback: any TriageFeedbackStore,
        settings: any TriageCalibrationSettings,
        now: @escaping () -> String = TriageService.defaultNow
    ) {
        self.feedback = feedback
        self.settings = settings
        self.now = now
    }

    // MARK: - 报告

    public func report(sessionId: String?) throws -> TriageCalibrationReport {
        let samples = try feedback.loadCalibrationSamples(sessionId: sessionId)
        let minimum = minSamplesSetting()
        let current = currentThresholds()
        return Self.buildReport(
            sessionId: sessionId,
            samples: samples,
            minimum: minimum,
            current: current,
            generatedAt: now())
    }

    /// 纯函数：样本科目的全部统计（测试直接构造样本，不碰库）。
    public static func buildReport(
        sessionId: String?,
        samples: [TriageCalibrationSample],
        minimum: Int,
        current: TriageCalibrationThresholds,
        generatedAt: String
    ) -> TriageCalibrationReport {
        let buckets = buckets(samples: samples)
        let currentKeep = precision(
            samples: samples, verdict: "keep", threshold: current.keep)
        let currentReject = precision(
            samples: samples, verdict: "reject", threshold: current.reject)
        let suggestions = targets.compactMap { target in
            suggestion(samples: samples, target: target)
        }
        return TriageCalibrationReport(
            sessionId: sessionId,
            samples: samples.count,
            minSamples: minimum,
            buckets: buckets,
            current: current,
            currentKeepPrecision: currentKeep,
            currentRejectPrecision: currentReject,
            suggestions: suggestions,
            byCamera: cameraReliability(samples: samples),
            generatedAt: generatedAt)
    }

    /// 10 桶：索引 = clamp(Int(confidence × 10), 0, 9)。
    public static func buckets(samples: [TriageCalibrationSample]) -> [TriageCalibrationBucket] {
        var total = [Int](repeating: 0, count: bucketCount)
        var keeps = [Int](repeating: 0, count: bucketCount)
        var agreed = [Int](repeating: 0, count: bucketCount)
        for sample in samples {
            let index = bucketIndex(sample.suggestionConfidence)
            total[index] += 1
            guard sample.suggestionVerdict == "keep" else { continue }
            keeps[index] += 1
            if sample.userAction == "keep" { agreed[index] += 1 }
        }
        return (0..<bucketCount).map { index in
            TriageCalibrationBucket(
                lowerBound: Double(index) / Double(bucketCount),
                upperBound: Double(index + 1) / Double(bucketCount),
                samples: total[index],
                keepSuggestions: keeps[index],
                agreedKeep: agreed[index])
        }
    }

    /// 保精确率 target 的最低可行阈值（覆盖最大化）。不可达返回 nil。
    public static func suggestion(
        samples: [TriageCalibrationSample],
        target: Double
    ) -> TriageCalibrationSuggestion? {
        let keepSamples = samples.filter { $0.suggestionVerdict == "keep" }
        guard !keepSamples.isEmpty else { return nil }
        // 候选阈值 = 出现过的置信度（升序）：从低到高找第一个满足目标的，
        // 即同等精确率下覆盖最多的阈值。
        let candidates = Set(samples.map { $0.suggestionConfidence }).sorted()
        for threshold in candidates {
            let selected = keepSamples.filter { $0.suggestionConfidence >= threshold }
            guard selected.count >= minimumThresholdSamples else { continue }
            let agreed = selected.filter { $0.userAction == "keep" }.count
            let achieved = Double(agreed) / Double(selected.count)
            guard achieved >= target else { continue }
            let keep = selected.count
            let reject = samples.filter {
                $0.suggestionVerdict == "reject" && $0.suggestionConfidence >= threshold
            }.count
            let review = samples.filter { $0.suggestionConfidence < threshold }.count
            return TriageCalibrationSuggestion(
                target: target,
                confidence: threshold,
                samples: keep + reject,
                keepPrecision: achieved,
                rejectPrecision: Self.precision(
                    samples: samples, verdict: "reject", threshold: threshold),
                keep: keep,
                reject: reject,
                review: review)
        }
        return nil
    }

    /// 指定方向/阈值下的精确率（分母 0 → nil）。
    public static func precision(
        samples: [TriageCalibrationSample],
        verdict: String,
        threshold: Double
    ) -> Double? {
        let selected = samples.filter {
            $0.suggestionVerdict == verdict && $0.suggestionConfidence >= threshold
        }
        guard !selected.isEmpty else { return nil }
        let agreed = selected.filter { $0.userAction == verdict }.count
        return Double(agreed) / Double(selected.count)
    }

    public static func cameraReliability(
        samples: [TriageCalibrationSample]
    ) -> [TriageCalibrationCameraReliability] {
        var grouped: [String: [TriageCalibrationSample]] = [:]
        for sample in samples {
            guard let model = sample.cameraModel,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            grouped[model, default: []].append(sample)
        }
        return grouped
            .map { model, rows in
                TriageCalibrationCameraReliability(
                    cameraModel: model,
                    samples: rows.count,
                    keepPrecision: precision(
                        samples: rows, verdict: "keep", threshold: 0))
            }
            .sorted { lhs, rhs in
                if lhs.samples != rhs.samples { return lhs.samples > rhs.samples }
                return lhs.cameraModel < rhs.cameraModel
            }
            .prefix(maxCameraRows)
            .map { $0 }
    }

    // MARK: - 应用

    /// 写三个设置键（阈值立即进入 input_fingerprint → 旧建议自动 stale）。
    /// - Parameter onApplied: 组合根注入（失效门控缓存 + 触发重算）；可为 nil。
    @discardableResult
    public func apply(
        _ suggestion: TriageCalibrationSuggestion,
        minimumSamples: Int? = nil,
        onApplied: (() -> Void)? = nil
    ) throws -> TriageCalibrationThresholds {
        let threshold = suggestion.confidence
        guard threshold.isFinite, threshold >= 0, threshold <= 1 else {
            throw TriageCalibrationError.invalidThreshold(threshold)
        }
        let minimum = minimumSamples ?? minSamplesSetting()
        // 门禁用**可用样本数**（已按人工决定过滤），不是原始行数：
        // AI 自动应用写的 feedback 会因为 source=ai 被过滤掉，用它凑数等于骗自己。
        let sampleCount = try feedback.loadCalibrationSamples(sessionId: nil).count
        guard sampleCount >= minimum, minimum > 0 else {
            throw TriageCalibrationError.insufficientSamples(
                samples: sampleCount, minimum: minimum)
        }
        let current = currentThresholds()
        // minExecutable 只降不升：提高它会把本次阈值之外的建议也一并废掉。
        let minExecutable = min(current.minExecutable, threshold)
        try settings.write(
            TriageCalibrationKeys.keepConfidenceMin, value: Self.format(threshold))
        try settings.write(
            TriageCalibrationKeys.rejectConfidenceMin, value: Self.format(threshold))
        try settings.write(
            TriageCalibrationKeys.minExecutableConfidence, value: Self.format(minExecutable))
        onApplied?()
        return TriageCalibrationThresholds(
            keep: threshold,
            reject: threshold,
            minExecutable: minExecutable)
    }

    /// API 入口：显式应用三个阈值（不经过 suggestion 的 keep=reject 假设）。
    public func applyThresholds(
        keep: Double,
        reject: Double,
        minExecutable: Double,
        minimumSamples: Int? = nil,
        onApplied: (() -> Void)? = nil
    ) throws -> TriageCalibrationThresholds {
        for value in [keep, reject, minExecutable] {
            guard value.isFinite, value >= 0, value <= 1 else {
                throw TriageCalibrationError.invalidThreshold(value)
            }
        }
        let minimum = minimumSamples ?? minSamplesSetting()
        let sampleCount = try feedback.loadCalibrationSamples(sessionId: nil).count
        guard sampleCount >= minimum, minimum > 0 else {
            throw TriageCalibrationError.insufficientSamples(
                samples: sampleCount, minimum: minimum)
        }
        try settings.write(
            TriageCalibrationKeys.keepConfidenceMin, value: Self.format(keep))
        try settings.write(
            TriageCalibrationKeys.rejectConfidenceMin, value: Self.format(reject))
        // 可执行下限只降不升：不高于当前值，也不高于本次 keep/reject。
        let floor = min(minExecutable, currentThresholds().minExecutable, keep, reject)
        try settings.write(
            TriageCalibrationKeys.minExecutableConfidence, value: Self.format(floor))
        onApplied?()
        return TriageCalibrationThresholds(
            keep: keep, reject: reject, minExecutable: floor)
    }

    /// 当前阈值（UI 显示"当前 vs 建议"）。
    public func currentThresholds() -> TriageCalibrationThresholds {
        let keep = settings.number(for: TriageCalibrationKeys.keepConfidenceMin, defaultValue: 0.60)
        let reject = settings.number(
            for: TriageCalibrationKeys.rejectConfidenceMin, defaultValue: 0.75)
        let floor = settings.number(
            for: TriageCalibrationKeys.minExecutableConfidence, defaultValue: 0.55)
        return TriageCalibrationThresholds(
            keep: Self.clamp(keep), reject: Self.clamp(reject), minExecutable: Self.clamp(floor))
    }

    public func minSamplesSetting() -> Int {
        let raw = settings.number(for: TriageCalibrationKeys.minSamples, defaultValue: 50)
        guard raw.isFinite, raw > 0 else { return 0 }
        return Int(min(raw, 1_000_000))
    }

    // MARK: - 工具

    static func bucketIndex(_ confidence: Double) -> Int {
        guard confidence.isFinite else { return 0 }
        let raw = Int((max(0, min(1, confidence)) * Double(bucketCount)).rounded(.down))
        return max(0, min(bucketCount - 1, raw))
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    /// 设置值统一 3 位小数：避免 0.9500000000000001 这类噪声进入指纹。
    static func format(_ value: Double) -> String {
        String(format: "%.3f", clamp(value))
    }
}

// MARK: - 生产装配

extension SettingsService: TriageCalibrationSettings {
    public func number(for key: String, defaultValue: Double) -> Double {
        getNumber(key, defaultValue: defaultValue)
    }

    public func write(_ key: String, value: String) throws {
        try set(key, value: value)
    }
}
