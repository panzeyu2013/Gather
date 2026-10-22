// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SimilarityInputs.swift
// Cut 1 / 阶段 1A：SimilarityAPI 输入（sim.* 10 条 -> 10 个方法）。
//
// 对应命令：sim.result / analyze / recluster / cancel_analysis / preview_writeback /
// writeback_items / writeback / confirm_sync / retry_failed_writeback / cleanup。
// 校验归属：
// - threshold 0...64 整数、minGroupSize >= 2 在输入构造期显式失败（SIM_*）；
// - groupingMode 使用枚举：未知字符串在解码期失败，不再静默变 global（G3）；
// - assignments 在输入构造期 trim/去重/拒绝空关键词（对齐旧 validateAssignments）；
// - 破坏性入口 writeback/retryFailedWriteback/cleanup 使用 Confirmed<T>；
// - “preview 是否过期/待写项是否匹配”属于交付状态，留在 1B 实现（SIM_PREVIEW_STALE）。

import Foundation

/// sim.result 的查询（threshold 缺省 = 最近一次结果）。
public struct SimilarityResultQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let threshold: Int?

    public init(sessionId: String, threshold: Int? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let threshold {
            _ = try APIValidation.integerInRange(threshold, field: "threshold", 0...64)
        }
        self.threshold = threshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            threshold: try container.decodeIfPresent(Int.self, forKey: .threshold)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, threshold
    }
}

/// sim.analyze / sim.recluster 的输入。
public struct SimilarityAnalyzeInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let threshold: Int?
    public let minGroupSize: Int?
    /// 旧命令只识别 "sequential"，其余（含非法值）静默变 global；G3 改为枚举 + 缺省 global。
    public let groupingMode: SimilarityGroupingMode

    public init(
        sessionId: String,
        threshold: Int? = nil,
        minGroupSize: Int? = nil,
        groupingMode: SimilarityGroupingMode = .global
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let threshold {
            _ = try APIValidation.integerInRange(threshold, field: "threshold", 0...64)
        }
        self.threshold = threshold
        if let minGroupSize {
            _ = try APIValidation.integerInRange(minGroupSize, field: "minGroupSize", 2...1_000_000)
        }
        self.minGroupSize = minGroupSize
        self.groupingMode = groupingMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            threshold: try container.decodeIfPresent(Int.self, forKey: .threshold),
            minGroupSize: try container.decodeIfPresent(Int.self, forKey: .minGroupSize),
            groupingMode: try container.decodeIfPresent(SimilarityGroupingMode.self, forKey: .groupingMode) ?? .global
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, threshold, minGroupSize, groupingMode
    }
}

/// sim.preview_writeback 的输入。
public struct SimilarityPreviewWritebackInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let assignments: [SimilarityKeywordAssignment]
    public let threshold: Int?

    public init(
        sessionId: String,
        assignments: [SimilarityKeywordAssignment],
        threshold: Int? = nil
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.assignments = try Self.normalizedAssignments(assignments)
        if let threshold {
            _ = try APIValidation.integerInRange(threshold, field: "threshold", 0...64)
        }
        self.threshold = threshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            assignments: try container.decode([SimilarityKeywordAssignment].self, forKey: .assignments),
            threshold: try container.decodeIfPresent(Int.self, forKey: .threshold)
        )
    }

    private static func normalizedAssignments(
        _ assignments: [SimilarityKeywordAssignment]
    ) throws -> [SimilarityKeywordAssignment] {
        _ = try APIValidation.nonEmpty(assignments, field: "assignments")
        return try assignments.enumerated().map { index, assignment in
            let keywords = try normalizedKeywords(assignment.keywords, field: "assignments[\(index)].keywords")
            return SimilarityKeywordAssignment(groupId: assignment.groupId, keywords: keywords)
        }
    }

    private static func normalizedKeywords(_ keywords: [String], field: String) throws -> [String] {
        var seen = Set<String>()
        let normalized = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !normalized.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must contain at least one non-blank keyword")
        }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, assignments, threshold
    }
}

/// sim.writeback 的载荷（Confirmed<SimilarityWritebackInput>）。
public struct SimilarityWritebackInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let itemIds: [Int]
    public let threshold: Int?

    public init(sessionId: String, itemIds: [Int], threshold: Int? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        guard !itemIds.isEmpty else {
            throw GatherError(code: .SIM_PREVIEW_REQUIRED, params: ["field": "itemIds"])
        }
        self.itemIds = try APIValidation.nonEmpty(itemIds, field: "itemIds", maxCount: 10_000)
        if let threshold {
            _ = try APIValidation.integerInRange(threshold, field: "threshold", 0...64)
        }
        self.threshold = threshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            itemIds: try container.decode([Int].self, forKey: .itemIds),
            threshold: try container.decodeIfPresent(Int.self, forKey: .threshold)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, itemIds, threshold
    }
}
