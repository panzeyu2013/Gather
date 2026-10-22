// desktop/native/gather-core/Sources/GatherProtocol/API/Core/PageRequest.swift
// Cut 1 / 阶段 1A：分页请求的共享原语。
//
// 职责：承载 Router 的 clampedLimit / clampedOffset 语义（§6.1）：
// - photo.list_page：limit 缺省 200、上限 1000；
// - filter.photos(_global)：limit 缺省 100、上限 500，offset >= 0；
// - album.get_photos：limit 缺省 100、上限 500，offset >= 0；
// - culling.history：limit 缺省 100、上限 500（查询类型直接校验，不用 PageRequest）。
//
// 校验归属：旧命令是“钳制”（floor + clamp），本类型保留该归一化语义并在注释中
// 标明；不把越界值静默变成默认值——lower/upper 钳制是显式、可预测的规则。

import Foundation

public struct PageRequest: Sendable, Equatable, Hashable {
    public static let filterDefaultLimit = 100
    public static let filterMaxLimit = 500
    public static let photoDefaultLimit = 200
    public static let photoMaxLimit = 1_000
    public static let albumDefaultLimit = 100
    public static let albumMaxLimit = 500

    public let limit: Int
    public let offset: Int

    /// 已归一化的分页（limit >= 1，offset >= 0）。
    public init(limit: Int, offset: Int = 0) {
        self.limit = Swift.max(1, limit)
        self.offset = Swift.max(0, offset)
    }

    /// 旧 clampedLimit 的等价物：缺省 defaultLimit，越界钳到 1...maxLimit。
    public static func normalizedLimit(_ limit: Int?, default defaultLimit: Int, max maxLimit: Int) -> Int {
        let raw = limit ?? defaultLimit
        return Swift.min(Swift.max(raw, 1), maxLimit)
    }

    public static func filter(limit: Int? = nil, offset: Int? = nil) -> PageRequest {
        PageRequest(
            limit: normalizedLimit(limit, default: filterDefaultLimit, max: filterMaxLimit),
            offset: Swift.max(0, offset ?? 0)
        )
    }

    public static func photo(limit: Int? = nil) -> PageRequest {
        PageRequest(limit: normalizedLimit(limit, default: photoDefaultLimit, max: photoMaxLimit))
    }

    public static func album(limit: Int? = nil, offset: Int? = nil) -> PageRequest {
        PageRequest(
            limit: normalizedLimit(limit, default: albumDefaultLimit, max: albumMaxLimit),
            offset: Swift.max(0, offset ?? 0)
        )
    }
}
