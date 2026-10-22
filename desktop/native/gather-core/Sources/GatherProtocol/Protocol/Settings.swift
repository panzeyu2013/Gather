// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Settings.swift
// TS 源: packages/shared/src/protocol/core.ts（settings.* 命令内联类型）
// + desktop/src/main/ipc/settings.ipc.ts（get_ml_status 响应形状，内联）。
// Phase 3.6 契约层。

import Foundation

// TS: settings.get_all / settings.get 响应 —— Record<string, string>。
// settings.set 响应 { done: true }；settings.set_language 响应 { language }。

// TS: settings.get_ml_status 响应（settings.ipc.ts:66-88 内联形状）。
public struct MLStatusData: Codable, Equatable, Sendable {
    public var platform: String
    public var autoBackend: String
    public var autoBackendLabel: String
    public var provider: String
    public var isAuto: Bool
    public var availableBackends: [MLBackendOption]
    public var modelResourcesDir: String
    public var detectorModel: MLModelPresence
    public var encoderModel: MLModelPresence
    public var modelInfo: MLModelInfo

    public init(
        platform: String,
        autoBackend: String,
        autoBackendLabel: String,
        provider: String,
        isAuto: Bool,
        availableBackends: [MLBackendOption],
        modelResourcesDir: String,
        detectorModel: MLModelPresence,
        encoderModel: MLModelPresence,
        modelInfo: MLModelInfo
    ) {
        self.platform = platform
        self.autoBackend = autoBackend
        self.autoBackendLabel = autoBackendLabel
        self.provider = provider
        self.isAuto = isAuto
        self.availableBackends = availableBackends
        self.modelResourcesDir = modelResourcesDir
        self.detectorModel = detectorModel
        self.encoderModel = encoderModel
        self.modelInfo = modelInfo
    }
}

// TS: BackendOption（provider.ts:94-97）—— getAvailableBackends() 的元素。
public struct MLBackendOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct MLModelPresence: Codable, Equatable, Sendable {
    public var path: String
    public var resolvedPath: String?
    public var exists: Bool

    public init(path: String, resolvedPath: String?, exists: Bool) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.exists = exists
    }
}

public struct MLModelInfo: Codable, Equatable, Sendable {
    public var detectInputSize: Int
    public var secondaryDetectInputSize: Int
    public var previewMaxDimension: Int
    public var encoderInputSize: Int
    public var embeddingDim: Int

    public init(detectInputSize: Int, secondaryDetectInputSize: Int, previewMaxDimension: Int, encoderInputSize: Int, embeddingDim: Int) {
        self.detectInputSize = detectInputSize
        self.secondaryDetectInputSize = secondaryDetectInputSize
        self.previewMaxDimension = previewMaxDimension
        self.encoderInputSize = encoderInputSize
        self.embeddingDim = embeddingDim
    }
}
