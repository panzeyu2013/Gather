// desktop/native/gather-core/Sources/GatherProtocol/Protocol/TriageCalibration.swift
// P1 下一波 §3.11.2：技术质量建议的阈值校准（IPC 快照 + 应用输入）。
//
// 应用层的 TriageCalibrationService 产出更细的报告；LiveCullingAPI 在这里映射成
// 可编码快照，GatherUI 再映射成面板模型（UI 不 import Application）。

import Foundation

public struct TriageCalibrationBucketSnapshot: Codable, Equatable, Sendable {
    public var lowerBound: Double
    public var upperBound: Double
    public var samples: Int
    public var keepSuggestions: Int
    public var agreedKeep: Int

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
}

public struct TriageCalibrationThresholdSnapshot: Codable, Equatable, Sendable {
    public var keep: Double
    public var reject: Double
    public var minExecutable: Double

    public init(keep: Double, reject: Double, minExecutable: Double) {
        self.keep = keep
        self.reject = reject
        self.minExecutable = minExecutable
    }
}

public struct TriageCalibrationSuggestionSnapshot: Codable, Equatable, Sendable {
    public var target: Double
    public var confidence: Double
    public var samples: Int
    public var keepPrecision: Double?
    public var rejectPrecision: Double?
    public var keep: Int
    public var reject: Int
    public var review: Int

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

public struct TriageCalibrationCameraSnapshot: Codable, Equatable, Sendable {
    public var cameraModel: String
    public var samples: Int
    public var keepPrecision: Double?

    public init(cameraModel: String, samples: Int, keepPrecision: Double?) {
        self.cameraModel = cameraModel
        self.samples = samples
        self.keepPrecision = keepPrecision
    }
}

public struct TriageCalibrationSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var samples: Int
    public var minSamples: Int
    public var buckets: [TriageCalibrationBucketSnapshot]
    public var current: TriageCalibrationThresholdSnapshot
    public var currentKeepPrecision: Double?
    public var currentRejectPrecision: Double?
    public var suggestions: [TriageCalibrationSuggestionSnapshot]
    public var byCamera: [TriageCalibrationCameraSnapshot]
    public var generatedAt: String

    public init(
        sessionId: String?,
        samples: Int,
        minSamples: Int,
        buckets: [TriageCalibrationBucketSnapshot],
        current: TriageCalibrationThresholdSnapshot,
        currentKeepPrecision: Double?,
        currentRejectPrecision: Double?,
        suggestions: [TriageCalibrationSuggestionSnapshot],
        byCamera: [TriageCalibrationCameraSnapshot],
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

    /// 0（或负）= 不设门槛。UI 与服务端必须同口径，否则设 0 会得到
    /// "恒样本不足（N/0）"这种自相矛盾的状态（B8）。
    public var isApplicable: Bool { minSamples <= 0 || samples >= minSamples }
}

public struct TriageCalibrationQuery: Codable, Equatable, Sendable {
    /// nil = 全库（跨会话）口径。
    public var sessionId: String?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

public struct TriageCalibrationApplyInput: Codable, Equatable, Sendable {
    public var keep: Double
    public var reject: Double
    public var minExecutable: Double

    public init(keep: Double, reject: Double, minExecutable: Double) {
        self.keep = keep
        self.reject = reject
        self.minExecutable = minExecutable
    }
}
