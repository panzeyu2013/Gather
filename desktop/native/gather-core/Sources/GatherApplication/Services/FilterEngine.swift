// desktop/native/gather-core/Sources/GatherApplication/Services/FilterEngine.swift
// TS 源: desktop/src/main/services/filter/filter-engine.ts（Phase 3.6 移植）
//
// WP3b-1：SQL 生成与执行已下沉到 GatherPersistence/PhotoFilterQuery。本文件只剩
// 公开门面与返回类型映射：
//   - filterPhotos / filterGlobally / countPhotos / countGlobally / suggest 委托；
//   - buildWhereClause 保留为公开包装（album IPC 用它做 criteria 校验）；
//   - FilteredPhotoData 形状不变。
// 行为红线（与 TS 逐条对应）仍由 PhotoFilterQuery 的 SQL 保证，见其文件头。
import Foundation
import GatherPersistence
import GatherProtocol

/// TS: WhereClauseResult。
public struct WhereClauseResult: Equatable, Sendable {
    public let sql: String
    public let params: [FilterValue]

    public init(sql: String, params: [FilterValue]) {
        self.sql = sql
        self.params = params
    }
}

/// TS: PhotoData（filterPhotos 返回）。
public struct FilteredPhotoData: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let hasExistingXmp: Bool
    public let faceCount: Int
    public let width: Int
    public let height: Int
    /// 仅为 IPC 形状兼容恒为 "{}"；V1 photos 不再存 metadata/result。
    public let metadata: String
    /// 同上：不参与 SQL 投影与行映射。
    public let result: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String
}

public final class FilterEngine {
    private let query: any PhotoFilterQuerying

    public init(query: any PhotoFilterQuerying) {
        self.query = query
    }

    // MARK: API

    /// TS: filterPhotos —— 引擎内不钳制 limit/offset。
    public func filterPhotos(
        sessionId: String,
        criteria: FilterGroup,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> [FilteredPhotoData] {
        try translated {
            try query.filterPhotos(
                sessionId: sessionId,
            criteria: criteria,
            sortBy: sortBy,
            sortOrder: sortOrder,
                limit: limit,
                offset: offset
            ).map { row in
                FilteredPhotoData(
                id: row.id,
                sessionId: row.sessionId,
                filepath: row.filepath,
                filename: row.filename,
                checksum: row.checksum,
                hasExistingXmp: false,
                faceCount: row.faceCount,
                width: 0, // TS: SELECT 未含 width/height，row.width ?? 0 → 恒 0
                height: 0,
                metadata: "{}",
                result: "{}",
                    status: row.status,
                    createdAt: row.createdAt,
                    updatedAt: row.updatedAt
                )
            }
        }
    }

    /// TS: filterGlobally —— 引擎内钳制 limit 1..500 / offset ≥0。
    public func filterGlobally(
        criteria: FilterGroup,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        sessionId: String? = nil
    ) throws -> [GlobalPhotoResult] {
        try translated {
            try query.filterGlobally(
                criteria: criteria,
                sortBy: sortBy,
                sortOrder: sortOrder,
                limit: limit,
                offset: offset,
                sessionId: sessionId
            )
        }
    }

    /// TS: countGlobally。
    public func countGlobally(criteria: FilterGroup, sessionId: String? = nil) throws -> Int {
        try translated { try query.countGlobally(criteria: criteria, sessionId: sessionId) }
    }

    /// TS: countPhotos —— __global__ 时 asset 去重。
    public func countPhotos(sessionId: String, criteria: FilterGroup) throws -> Int {
        try translated { try query.countPhotos(sessionId: sessionId, criteria: criteria) }
    }

    /// TS: suggest —— 仅 camera_make LIKE，<2 字符返回空。
    public func suggest(_ sessionId: String, keyword: String) throws -> [FilterSuggestion] {
        try translated { try query.suggest(sessionId, keyword: keyword) }
    }

    // MARK: buildWhereClause（public —— album IPC 用它做 criteria 校验）

    /// TS: buildWhereClause —— 递归组合；空组 → sql:''（调用方视为 1=1）。
    public func buildWhereClause(_ group: FilterGroup) throws -> WhereClauseResult {
        let clause = try translated { try query.whereClause(group) }
        return WhereClauseResult(sql: clause.sql, params: clause.params.map(FilterValue.init))
    }

    /// Persistence 的查询错误 → 既有公开错误类型（码/文案不变）。
    private func translated<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as PhotoFilterQueryError {
            switch error {
            case .fieldUnknown(let field):
                throw FilterEngineError.fieldUnknown(field)
            case .unsupportedOperatorForField(let field, let op):
                throw FilterEngineError.unsupportedOperatorForField(field: field, op: op)
            }
        }
    }
}

private extension FilterValue {
    init(_ value: DBValue) {
        switch value {
        case .null: self = .null
        case .int(let value): self = .int(value)
        case .real(let value): self = .real(value)
        case .text(let value): self = .text(value)
        case .blob(let value): self = .blob(value)
        }
    }
}

/// 过滤引擎错误（description 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
public enum FilterEngineError: Error, CustomStringConvertible {
    case fieldUnknown(String)
    case unsupportedOperatorForField(field: String, op: String)

    public var description: String {
        switch self {
        case .fieldUnknown: return "FILTER_FIELD_UNKNOWN"
        case .unsupportedOperatorForField(let field, let op):
            return "Unsupported operator for \(field) field: \(op)"
        }
    }
}
