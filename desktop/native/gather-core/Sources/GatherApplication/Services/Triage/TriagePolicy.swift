// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriagePolicy.swift
// P0 / T0：Triage v1 的策略常量。纯值，无 I/O。
//
// 任何阈值改动都必须升 version（triage-v2）并重新生成建议；指纹会把 version
// 与阈值一起纳入，跨版本行不得混排。设置页只暴露 keep/reject/minExecutable
// 三个置信度（见 x0 §3）。
import Foundation
import GatherProtocol

public struct TriagePolicy: Equatable, Sendable {
    public var version: String

    public var keepScoreMin: Double
    public var groupKeepMargin: Double
    public var groupRejectMargin: Double
    public var tieEpsilon: Double

    public var blurSharpnessMax: Double
    public var exposureMin: Double
    public var closedEyeSuspectMin: Double

    public var facePrimaryAreaMin: Double
    public var faceSmallAreaMax: Double
    public var multiFaceCount: Int

    public var keepConfidenceMin: Double
    public var rejectConfidenceMin: Double
    public var minExecutableConfidence: Double
    public var maxReasons: Int

    public init(
        version: String = "triage-v1",
        keepScoreMin: Double = 0.60,
        groupKeepMargin: Double = 0.06,
        groupRejectMargin: Double = 0.12,
        tieEpsilon: Double = 0.02,
        blurSharpnessMax: Double = 0.12,
        exposureMin: Double = 0.30,
        closedEyeSuspectMin: Double = 0.72,
        facePrimaryAreaMin: Double = 0.03,
        faceSmallAreaMax: Double = 0.01,
        multiFaceCount: Int = 3,
        keepConfidenceMin: Double = 0.60,
        rejectConfidenceMin: Double = 0.75,
        minExecutableConfidence: Double = 0.55,
        maxReasons: Int = 3
    ) {
        self.version = version
        self.keepScoreMin = keepScoreMin
        self.groupKeepMargin = groupKeepMargin
        self.groupRejectMargin = groupRejectMargin
        self.tieEpsilon = tieEpsilon
        self.blurSharpnessMax = blurSharpnessMax
        self.exposureMin = exposureMin
        self.closedEyeSuspectMin = closedEyeSuspectMin
        self.facePrimaryAreaMin = facePrimaryAreaMin
        self.faceSmallAreaMax = faceSmallAreaMax
        self.multiFaceCount = multiFaceCount
        self.keepConfidenceMin = keepConfidenceMin
        self.rejectConfidenceMin = rejectConfidenceMin
        self.minExecutableConfidence = minExecutableConfidence
        self.maxReasons = maxReasons
    }

    public static let v1 = TriagePolicy()

    /// 可执行门限（T0 唯一判据）：方向下限与全局可执行下限取大者。
    ///
    /// 生成与应用必须共用这一条门限：低于该值的建议只能落在 review，
    /// 任何调用方都不允许把它写成 keep/reject。设置值只是 `minExecutableConfidence`
    /// 的输入，不能绕过本方法直接读 `keepConfidenceMin`/`rejectConfidenceMin`。
    public func executionFloor(for verdict: TriageVerdict) -> Double {
        switch verdict {
        case .keep:
            return max(keepConfidenceMin, minExecutableConfidence)
        case .reject:
            return max(rejectConfidenceMin, minExecutableConfidence)
        case .review:
            return minExecutableConfidence
        }
    }

    /// 设置页只暴露 policy version + 三个可执行置信度；其余阈值仍由版本常量控制。
    /// 设置变更即时生效：composition 用 provider 每次重建 policy（见 `Core.swift`）。
    public static func fromSettings(_ settings: SettingsService) -> TriagePolicy {
        var policy = TriagePolicy.v1
        let version = settings.get("triage_policy", defaultValue: policy.version)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { policy.version = version }
        policy.keepConfidenceMin = clamp(
            settings.getNumber("triage_keep_confidence_min", defaultValue: policy.keepConfidenceMin))
        policy.rejectConfidenceMin = clamp(
            settings.getNumber("triage_reject_confidence_min", defaultValue: policy.rejectConfidenceMin))
        policy.minExecutableConfidence = clamp(
            settings.getNumber("triage_min_executable_confidence", defaultValue: policy.minExecutableConfidence))
        return policy
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
