// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/CullingRejectInputs.swift
// P1 / D：把淘汰照片移出工作目录（移到 _rejects，不删除）。
import Foundation

public struct CullingMoveRejectedInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let photoIds: [String]
    /// nil = 使用会话根目录下的 _rejects。
    public let destinationRoot: String?

    public init(sessionId: String, photoIds: [String], destinationRoot: String? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        guard !photoIds.isEmpty else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must not be empty")
        }
        self.photoIds = photoIds
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

public struct CullingMoveRejectedResult: Codable, Equatable, Sendable {
    public var moved: [String]
    public var newPaths: [String]
    public var failed: [MetadataApplyFailureDTO]
    public init(moved: [String], newPaths: [String], failed: [MetadataApplyFailureDTO]) {
        self.moved = moved
        self.newPaths = newPaths
        self.failed = failed
    }
}
