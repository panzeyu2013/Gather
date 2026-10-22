// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/DuplicateInputs.swift
// Cut 1 / 阶段 1A：DuplicateAPI 输入（dup.* 4 条 -> 4 个方法）。
//
// 对应命令：dup.scan / groups / resolve / resolve_member。
// 校验归属：
// - visualThreshold 为 0...64 整数（DUP_THRESHOLD_INVALID），拒绝 NaN/小数/越界；
// - resolution 使用 DupResolution 枚举，未知字符串解码期失败；
// - resolve / resolveMember 为破坏性入口，使用 Confirmed<T>。

import Foundation

/// dup.scan 的输入（visualThreshold 缺省由服务使用设置值）。
public struct DuplicateScanInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let visualThreshold: Int?

    public init(sessionId: String, visualThreshold: Int? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let visualThreshold {
            guard (0...64).contains(visualThreshold) else {
                throw GatherError(code: .DUP_THRESHOLD_INVALID, params: ["field": "visualThreshold"])
            }
        }
        self.visualThreshold = visualThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            visualThreshold: try container.decodeIfPresent(Int.self, forKey: .visualThreshold)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, visualThreshold
    }
}

/// dup.resolve 的载荷（Confirmed<DuplicateResolveInput>）。
public struct DuplicateResolveInput: Decodable, Sendable, Equatable {
    public let groupId: Int
    public let resolution: DupResolution

    public init(groupId: Int, resolution: DupResolution) throws {
        self.groupId = try APIValidation.nonNegative(groupId, field: "groupId")
        self.resolution = resolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            groupId: try container.decode(Int.self, forKey: .groupId),
            resolution: try container.decode(DupResolution.self, forKey: .resolution)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case groupId, resolution
    }
}

/// dup.resolve_member 的载荷（Confirmed<DuplicateResolveMemberInput>）。
public struct DuplicateResolveMemberInput: Decodable, Sendable, Equatable {
    public let memberId: Int
    public let isKept: Bool

    public init(memberId: Int, isKept: Bool = true) throws {
        self.memberId = try APIValidation.nonNegative(memberId, field: "memberId")
        self.isKept = isKept
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            memberId: try container.decode(Int.self, forKey: .memberId),
            isKept: try container.decodeIfPresent(Bool.self, forKey: .isKept) ?? true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case memberId, isKept
    }
}
