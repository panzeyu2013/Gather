// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/CullingRejectInputs.swift
// P1 / D：把淘汰照片移出工作目录（移到 _rejects，不删除）。
import Foundation

public struct CullingMoveRejectedInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let photoIds: [String]
    /// nil = 使用会话根目录下的 _rejects。
    public let destinationRoot: String?

    /// 单次移出上限：与"全选当前范围"（SelectionIds 上限）一致，避免一次请求
    /// 在内存里展开整个 10 万级会话。
    public static let maxPhotoIds = 20_000

    public init(sessionId: String, photoIds: [String], destinationRoot: String? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.photoIds = try APIValidation.nonEmpty(
            photoIds, field: "photoIds", maxCount: Self.maxPhotoIds)
        self.destinationRoot = destinationRoot.map { $0.isEmpty ? nil : $0 } ?? nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            photoIds: try container.decode([String].self, forKey: .photoIds),
            destinationRoot: try container.decodeIfPresent(String.self, forKey: .destinationRoot)
        )
    }

    private enum CodingKeys: String, CodingKey { case sessionId, photoIds, destinationRoot }
}

/// 被服务端判定为"不该移出"的照片（不是失败：文件没动，DB 没动）。
///
/// P0 / A1：旧实现只要选中集混进一张保留件就整批抛 INVALID_PARAM，用户看到的是
/// "一张都移不动"。现在按张过滤并逐条说明原因，UI 汇总展示。
public struct CullingMoveRejectedSkip: Codable, Equatable, Sendable {
    public var photoId: String
    /// not_rejected / already_archived / not_in_session
    public var reason: String
    public init(photoId: String, reason: String) {
        self.photoId = photoId
        self.reason = reason
    }
}

public struct CullingMoveRejectedResult: Codable, Equatable, Sendable {
    public var moved: [String]
    public var newPaths: [String]
    public var skipped: [CullingMoveRejectedSkip]
    public var failed: [MetadataApplyFailureDTO]
    public init(
        moved: [String],
        newPaths: [String],
        skipped: [CullingMoveRejectedSkip] = [],
        failed: [MetadataApplyFailureDTO]
    ) {
        self.moved = moved
        self.newPaths = newPaths
        self.skipped = skipped
        self.failed = failed
    }
}
