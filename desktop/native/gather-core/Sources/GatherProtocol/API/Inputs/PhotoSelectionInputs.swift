// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/PhotoSelectionInputs.swift
// P2-2：图库服务端全选。查询与筛选语义与图库搜索/过滤器一致。
import Foundation

public enum PhotoSelectionFilter: String, Codable, CaseIterable, Sendable, Equatable {
    case all
    case hasFace
    case noFace
    case offline
}

public struct PhotoSelectionQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let search: String?
    public let filter: PhotoSelectionFilter
    public let limit: Int?

    public init(
        sessionId: String,
        search: String? = nil,
        filter: PhotoSelectionFilter = .all,
        limit: Int? = nil
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.search = trimmed.isEmpty ? nil : trimmed
        self.filter = filter
        if let limit {
            self.limit = try APIValidation.integerInRange(limit, field: "limit", 1...20_000)
        } else {
            self.limit = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            search: try container.decodeIfPresent(String.self, forKey: .search),
            filter: try container.decodeIfPresent(PhotoSelectionFilter.self, forKey: .filter) ?? .all,
            limit: try container.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, search, filter, limit
    }
}

public struct PhotoSelectionIds: Codable, Sendable, Equatable {
    public let ids: [String]
    public let idsHash: String
    public let truncated: Bool

    public init(ids: [String], idsHash: String, truncated: Bool) {
        self.ids = ids
        self.idsHash = idsHash
        self.truncated = truncated
    }
}
