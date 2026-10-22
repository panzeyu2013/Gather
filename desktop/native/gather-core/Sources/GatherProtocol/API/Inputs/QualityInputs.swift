// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/QualityInputs.swift
// Cut 1 / 阶段 1A：QualityAPI 输入（quality.* 2 条 -> 2 个方法）。
//
// 对应命令：quality.analyze / quality.get（quality.get -> results）。
// 校验归属：
// - analyze 的 photoIds 允许 nil（全会话），但“提供且为空”必须显式失败
//   （旧 INVALID_PARAM:photoIds）；
// - results 复用 Protocol/Quality.swift 的 QualityGetParams（字段形状一致）。

import Foundation

/// quality.analyze 的输入。
public struct QualityAnalyzeInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let photoIds: [String]?

    public init(sessionId: String, photoIds: [String]? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let photoIds {
            _ = try APIValidation.nonEmpty(photoIds, field: "photoIds", maxCount: 10_000)
            for (index, id) in photoIds.enumerated() {
                _ = try APIValidation.nonBlank(id, field: "photoIds[\(index)]", maxLength: 128)
            }
        }
        self.photoIds = photoIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            photoIds: try container.decodeIfPresent([String].self, forKey: .photoIds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, photoIds
    }
}
