// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/FaceOutputs.swift
// Cut 1 / 阶段 1A：FaceAPI 的结果类型。
//
// 职责：face.models_status 的输出（旧命令是内联对象 {provider,
// fallbackToOnnxEnabled, modelsPresent, downloading}，没有 Protocol DTO）。
// 校验归属：无（纯输出）。

import Foundation

public struct FaceModelsStatus: Codable, Equatable, Sendable {
    public let provider: String
    public let fallbackToOnnxEnabled: Bool
    public let modelsPresent: Bool
    public let downloading: Bool

    public init(provider: String, fallbackToOnnxEnabled: Bool, modelsPresent: Bool, downloading: Bool) {
        self.provider = provider
        self.fallbackToOnnxEnabled = fallbackToOnnxEnabled
        self.modelsPresent = modelsPresent
        self.downloading = downloading
    }
}
/// TS: FaceAnalysisResult（fkw.analyze 返回；status 为 'done' | 'failed' | 'cancelled'）。
public struct FaceAnalysisResult: Codable, Equatable, Sendable {
    public let status: String
    public let detectionFailures: Int
    public let encodingFailures: Int

    public init(status: String, detectionFailures: Int, encodingFailures: Int) {
        self.status = status
        self.detectionFailures = detectionFailures
        self.encodingFailures = encodingFailures
    }
}

/// TS: FaceClusterData.binding（{ roleName, keywords }）。
public struct FaceClusterBinding: Codable, Equatable, Sendable {
    public let roleName: String
    public let keywords: [String]

    public init(roleName: String, keywords: [String]) {
        self.roleName = roleName
        self.keywords = keywords
    }
}

/// TS: FaceClusterData（fkw.clusters 返回；members 截断至预览窗口 4 条，
/// size 保持精确总数——见 face-kw.service.ts:756-783 注释）。
/// matchedPersonId/matchedPersonName/matchConfidence 是跨会话重识别建议
/// （person_embeddings 匹配所得），可选字段：未匹配时为 nil。
public struct FaceClusterData: Codable, Equatable, Sendable {
    public let id: Int
    public let sessionId: String
    public let label: String
    public let size: Int
    public let status: String
    /// IPC 契约字段：V1 的 face_clusters 已删除 thumbnail_base64（Cut 2 S5a），
    /// 缩略图由 thumbnail_path 的文件承载；为兼容 fkw.clusters 载荷保留，恒为空串。
    public let thumbnailBase64: String
    public let binding: FaceClusterBinding?
    public let thumbnailPhotoId: String?
    public let members: [ClusterMember]
    public let matchedPersonId: String?
    public let matchedPersonName: String?
    public let matchConfidence: Double?

    public init(
        id: Int,
        sessionId: String,
        label: String,
        size: Int,
        status: String,
        thumbnailBase64: String,
        binding: FaceClusterBinding?,
        thumbnailPhotoId: String?,
        members: [ClusterMember],
        matchedPersonId: String? = nil,
        matchedPersonName: String? = nil,
        matchConfidence: Double? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.label = label
        self.size = size
        self.status = status
        self.thumbnailBase64 = thumbnailBase64
        self.binding = binding
        self.thumbnailPhotoId = thumbnailPhotoId
        self.members = members
        self.matchedPersonId = matchedPersonId
        self.matchedPersonName = matchedPersonName
        self.matchConfidence = matchConfidence
    }
}

/// TS: fkw.unbind 返回（{ done, removedKeywords }）。
public struct FkwUnbindResult: Codable, Equatable, Sendable {
    public let done: Bool
    public let removedKeywords: [String]

    public init(done: Bool, removedKeywords: [String]) {
        self.done = done
        self.removedKeywords = removedKeywords
    }
}
