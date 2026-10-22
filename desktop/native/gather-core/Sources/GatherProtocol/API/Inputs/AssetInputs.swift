// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/AssetInputs.swift
// Cut 1 / 阶段 1A：AssetAPI 输入（assets.* 5 条 -> 5 个方法）。
//
// 对应命令：assets.candidates / volumes / accept_candidate / reject_candidate /
// relink_root。
// 校验归属：
// - candidates 的 sessionId 可选（nil = 全部会话）；
// - accept / reject / relink_root 为破坏性入口，使用 Confirmed<T>；
// - 根目录新旧关系（相同/嵌套/存在性）属于资产域，由 1B 调用 AssetRepo 校验
//   （ASSET_RELINK_* 码）。

import Foundation

/// assets.candidates 的查询。
public struct AssetCandidatesQuery: Decodable, Sendable, Equatable {
    public let sessionId: String?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
    }
}

/// assets.accept_candidate / reject_candidate 的载荷。
public struct AssetCandidateReference: Decodable, Sendable, Equatable {
    public let candidateId: String

    public init(candidateId: String) throws {
        self.candidateId = try APIValidation.nonBlank(candidateId, field: "candidateId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(candidateId: try container.decode(String.self, forKey: .candidateId))
    }

    private enum CodingKeys: String, CodingKey {
        case candidateId
    }
}

/// assets.relink_root 的载荷（Confirmed<AssetRelinkInput>）。
public struct AssetRelinkInput: Decodable, Sendable, Equatable {
    public let oldRoot: String
    public let newRoot: String

    public init(oldRoot: String, newRoot: String) throws {
        self.oldRoot = try APIValidation.path(oldRoot, field: "oldRoot")
        self.newRoot = try APIValidation.path(newRoot, field: "newRoot")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            oldRoot: try container.decode(String.self, forKey: .oldRoot),
            newRoot: try container.decode(String.self, forKey: .newRoot)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case oldRoot, newRoot
    }
}
