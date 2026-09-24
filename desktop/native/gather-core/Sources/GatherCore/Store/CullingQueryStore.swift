// Store/CullingQueryStore.swift
// W2b（Store 读模型）：Culling 分页/计数 SQL 的唯一所有者（纯新增，不改服务 API）。
//
// 从 Services/CullingService.swift 原样搬移（W2b 设计 §2.0，约 1380-1617 行）：
//   pagePhotosQuery / loadAssetRows / preferredRowPredicate /
//   buildFilteredWhere / buildSimilarityClause / countForScope。
// - 谓词语义、参数顺序、PhotoFormats.rawExtensionLikeSQL、json_valid 质量守卫、
//   stats_json NOT LIKE '%"precomputed":true%' 与游标来源逐字对齐；
// - compile(_:sessionId:) 是唯一 WHERE 编译点，page 与 count 共用，避免两份谓词漂移；
// - .all scope 委托注入的 any PhotoStore（getAssetPage / countAssetsBySession），
//   避免第三份资产分组 SQL，也保持既有 .all 分页语义不变。
import Foundation

// MARK: - 质量谓词 / 过滤规格

/// 技术质量谓词（TS CullingFilters.qualityStatus 的 SQL 形态）。
public enum CullingQualityPredicate: String, Equatable, Sendable {
    /// json_extract(result_json, '$.status') = 'succeeded'。
    case succeeded
    /// json_extract(result_json, '$.status') = 'failed'。
    case failed
    /// NOT EXISTS（无合法技术质量分析行）：损坏 JSON 与缺失等价。
    case absent
}

/// Culling 过滤器（Service 侧 CullingFilters 的 SQL 可表达子集）。
///
/// 空数组 / false / nil 均表示「该维度不过滤」。metadataConflictOnly 依赖 JS 计算的
/// XMP 侧车路径，刻意不在此表达（与 buildFilteredWhere 同语义）。
/// CullingFilters → 本规格的唯一映射入口（CullingAssembler.specs(from:) 的
/// 空规格归一化建立在此 init 之上）。
public struct CullingFilterSpec: Equatable, Sendable {
    public var unreviewed: Bool
    public var pickStates: [PickState]
    public var ratings: [Double]
    public var colorLabels: [CaptureOneColorLabel]
    public var quality: CullingQualityPredicate?

    public init(
        unreviewed: Bool = false,
        pickStates: [PickState] = [],
        ratings: [Double] = [],
        colorLabels: [CaptureOneColorLabel] = [],
        quality: CullingQualityPredicate? = nil
    ) {
        self.unreviewed = unreviewed
        self.pickStates = pickStates
        self.ratings = ratings
        self.colorLabels = colorLabels
        self.quality = quality
    }

    /// TS CullingFilters → SQL 规格（unreviewedOnly == true / 非空数组 /
    /// qualityStatus 三态映射；metadataConflictOnly 留待 JS 侧）。
    public init(filters: CullingFilters) {
        let quality: CullingQualityPredicate?
        switch filters.qualityStatus {
        case .analysed: quality = .succeeded
        case .failed: quality = .failed
        case .unanalysed: quality = .absent
        case nil: quality = nil
        }
        self.init(
            unreviewed: filters.unreviewedOnly == true,
            pickStates: filters.pickStates ?? [],
            ratings: filters.ratings ?? [],
            colorLabels: filters.colorLabels ?? [],
            quality: quality
        )
    }
}

// MARK: - Scope / 查询 / 结果

/// 分页与计数的 scope（W2b 设计 §2.0）。
///
/// 无法解析的组 id 不构造成 scope（见 similarityGroup(groupId:)）：调用方回退
/// JS 相似度映射，SQL 层不产生谓词。
public enum CullingQueryScope: Equatable, Sendable {
    /// 全部逻辑资产（委托 PhotoStore.getAssetPage / countAssetsBySession）。
    case all
    /// 过滤后的逻辑资产；多个规格按 AND 叠加（与服务单一 filters 等价）。
    case filtered([CullingFilterSpec])
    /// 指定相似度结果的可解析组（TS requestedGroupId = "<resultId>:<groupIndex>"）。
    case similarityGroup(resultId: Int, groupIndex: Int)
    /// 最新非预计算相似度结果的全部成员（TS requestedGroupId == nil）。
    case similarityLatest
}

public extension CullingQueryScope {
    /// TS buildSimilarityClause 的组 id 解析：取最后一个冒号，两侧必须为整数。
    /// 缺冒号 / 非整数 → nil：无 SQL 谓词，调用方回退 JS 相似度映射
    /// （页面仍精确、可能不满页）。
    static func similarityGroup(groupId: String) -> CullingQueryScope? {
        guard let separator = groupId.lastIndex(of: ":") else { return nil }
        guard let resultId = Int(groupId[groupId.startIndex..<separator]),
              let groupIndex = Int(groupId[groupId.index(after: separator)...]) else {
            return nil
        }
        return .similarityGroup(resultId: resultId, groupIndex: groupIndex)
    }

    /// 规范化组 id（仅 similarityGroup 有值；与决策行 group_id 同形）。
    var groupId: String? {
        guard case .similarityGroup(let resultId, let groupIndex) = self else { return nil }
        return "\(resultId):\(groupIndex)"
    }
}

/// 分页请求：sessionId + scope + keyset 游标 + 组数上限。
public struct CullingPageQuery: Equatable, Sendable {
    public var sessionId: String
    public var scope: CullingQueryScope
    /// 上一页 CullingAssetGroupPage.cursor（组首 rowid）；nil 从 0 开始。
    public var afterRowId: Int64?
    /// 至多返回的逻辑资产组数（上限由 QueryBuilder 校验）。
    public var limit: Int

    public init(
        sessionId: String,
        scope: CullingQueryScope,
        afterRowId: Int64? = nil,
        limit: Int = 200
    ) {
        self.sessionId = sessionId
        self.scope = scope
        self.afterRowId = afterRowId
        self.limit = limit
    }
}

/// 一个逻辑资产组（COALESCE(NULLIF(asset_id,''), id)）及其首 rowid。
public struct CullingAssetGroup: Equatable, Sendable {
    public var groupId: String
    public var firstRowId: Int64

    public init(groupId: String, firstRowId: Int64) {
        self.groupId = groupId
        self.firstRowId = firstRowId
    }
}

/// 一页完整资产组。
///
/// - rows 只含本页组**全部**行（RAW/JPEG 变体一起返回，绝不跨页）；
/// - cursor 只来自组查询的最后组 first_rowid —— 绝非从 rows 推导（最小 rowid 可能
///   属于不匹配谓词的变体，重新推导会让下一页重复选中该资产）。
public struct CullingAssetGroupPage: Equatable, Sendable {
    public var rows: [PhotoPage]
    public var groups: [CullingAssetGroup]
    public var cursor: Int64?

    public init(rows: [PhotoPage], groups: [CullingAssetGroup], cursor: Int64?) {
        self.rows = rows
        self.groups = groups
        self.cursor = cursor
    }
}

// MARK: - 协议

public protocol CullingQueryStore: Sendable {
    /// 一组完整资产的分页（keyset）：至多 limit 个资产组，rows 含这些组的全部行。
    func assetGroupPage(_ query: CullingPageQuery) async throws -> CullingAssetGroupPage
    /// 与 assetGroupPage 同源 WHERE 的逻辑资产组计数（忽略 afterRowId/limit）。
    func countAssetGroups(_ query: CullingPageQuery) async throws -> Int
}

// MARK: - SQLite 实现

public struct SQLiteCullingQueryStore: CullingQueryStore {
    /// 与 SQLitePhotoStore.getAssetPage 相同的分块大小（SQLite 变量上限内）。
    private static let groupChunkSize = 800

    /// filtered scope 的组查询/计数 JOIN（对应 buildFilteredWhere 的 d./c. 列引用）。
    private static let filteredJoins = """
    LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
    LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
    """

    /// json_valid 守卫：历史行 result_json 非法时 json_extract 会抛 malformed-JSON
    /// 错误使整页查询失败，故先排除非法的技术质量行。
    private static let qualityStatusClause = """
    json_extract(COALESCE((
      SELECT a3.result_json
      FROM asset_analysis a3
      WHERE a3.asset_file_id = p.asset_file_id
        AND a3.analysis_type = 'technical_quality'
        AND json_valid(a3.result_json)
      ORDER BY a3.updated_at DESC
      LIMIT 1
    ), '{}'), '$.status') = ?
    """

    /// 未分析：只有合法 JSON 行算作已分析；result_json 损坏视为无质量结果，
    /// NOT EXISTS 守卫必须镜像该语义（与上方 analysed/failed 分支同源）。
    private static let qualityAbsentClause = """
    NOT EXISTS (
      SELECT 1 FROM asset_analysis a3
      WHERE a3.asset_file_id = p.asset_file_id
        AND a3.analysis_type = 'technical_quality'
        AND json_valid(a3.result_json)
    )
    """

    private let database: SQLiteDatabase
    private let photoStore: any PhotoStore

    public init(database: SQLiteDatabase, photoStore: (any PhotoStore)? = nil) {
        self.database = database
        self.photoStore = photoStore ?? SQLitePhotoStore(database: database)
    }

    // MARK: CullingQueryStore

    public func assetGroupPage(_ query: CullingPageQuery) async throws -> CullingAssetGroupPage {
        guard let compiled = compile(query.scope, sessionId: query.sessionId) else {
            // .all：委托注入的 PhotoStore，避免第三份分组 SQL。
            let page = try await photoStore.getAssetPage(
                sessionId: query.sessionId,
                afterFirstRowid: query.afterRowId,
                limit: query.limit
            )
            return CullingAssetGroupPage(
                rows: page.rows,
                groups: Self.groups(from: page.rows),
                cursor: page.cursor
            )
        }
        let groups = try await groupPage(query, compiled: compiled)
        let rows = try await loadAssetRows(sessionId: query.sessionId, groups: groups)
        // cursor 只来自组查询（绝不是 rows 的最小 rowid 重新推导）。
        return CullingAssetGroupPage(rows: rows, groups: groups, cursor: groups.last?.firstRowId)
    }

    public func countAssetGroups(_ query: CullingPageQuery) async throws -> Int {
        guard let compiled = compile(query.scope, sessionId: query.sessionId) else {
            return try await photoStore.countAssetsBySession(sessionId: query.sessionId)
        }
        let row = try await database.queryOne(
            """
            SELECT COUNT(*) AS count
            FROM (SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
                  FROM photos p
                  \(Self.joins(for: query.scope))
                  WHERE \(compiled.sql)
                  GROUP BY gid)
            """,
            compiled.params
        )
        return Int(row?.int("count") ?? 0)
    }

    // MARK: 私有单点编译 / 查询

    /// 唯一 WHERE 编译点：page 与 count 共用（谓词与参数顺序因此逐字一致）。
    /// .all 返回 nil —— 该分支委托 any PhotoStore，SQL 不在此重复。
    private func compile(
        _ scope: CullingQueryScope,
        sessionId: String
    ) -> (sql: String, params: [SQLiteValue])? {
        switch scope {
        case .all:
            return nil
        case .filtered(let specs):
            var clauses: [String] = ["p.session_id = ?"]
            var params: [SQLiteValue] = [.text(sessionId)]
            for spec in specs {
                Self.appendFilterClauses(spec, to: &clauses, params: &params)
            }
            clauses.append(Self.preferredRowPredicate())
            return (clauses.joined(separator: " AND "), params)
        case .similarityGroup(let resultId, let groupIndex):
            let similarity = (sql: """
            EXISTS (
              SELECT 1 FROM similarity_result_members srm
              WHERE srm.result_id = ? AND srm.group_index = ? AND srm.session_id = ?
                AND srm.photo_id = p.id
            )
            """, params: [SQLiteValue.int(Int64(resultId)), .int(Int64(groupIndex)), .text(sessionId)])
            return (
                "p.session_id = ? AND \(similarity.sql) AND \(Self.preferredRowPredicate())",
                [.text(sessionId)] + similarity.params
            )
        case .similarityLatest:
            // 预计算阈值层共享同一张表（stats_json 的标记，见 similarity-result.repo）：
            // 裸 MAX(id) 会选中最新层而非 getLatest 解析到的分析/重聚类行，故 JS 侧
            // 相似度映射与 SQL 谓词必须一致。
            let similarity = (sql: """
            EXISTS (
              SELECT 1 FROM similarity_result_members srm
              WHERE srm.session_id = ? AND srm.photo_id = p.id
                AND srm.result_id = (
                  SELECT MAX(id) FROM similarity_results
                  WHERE session_id = ? AND stats_json NOT LIKE '%"precomputed":true%'
                )
            )
            """, params: [SQLiteValue.text(sessionId), .text(sessionId)])
            return (
                "p.session_id = ? AND \(similarity.sql) AND \(Self.preferredRowPredicate())",
                [.text(sessionId)] + similarity.params
            )
        }
    }

    /// 组页查询：取至多 limit 个资产组（first_rowid > afterRowId），cursor 即最后组首 rowid。
    private func groupPage(
        _ query: CullingPageQuery,
        compiled: (sql: String, params: [SQLiteValue])
    ) async throws -> [CullingAssetGroup] {
        let rows = try await database.query(
            """
            SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid, MIN(p.rowid) AS first_rowid
            FROM photos p
            \(Self.joins(for: query.scope))
            WHERE \(compiled.sql)
            GROUP BY COALESCE(NULLIF(p.asset_id, ''), p.id)
            HAVING MIN(p.rowid) > ?
            ORDER BY first_rowid
            LIMIT ?
            """,
            compiled.params + [.int(query.afterRowId ?? 0), .int(Int64(query.limit))]
        )
        return rows.map {
            CullingAssetGroup(groupId: $0.text("gid") ?? "", firstRowId: $0.int("first_rowid") ?? 0)
        }
    }

    /// 取给定资产组的全部行（分块，SQLite 参数上限内）。只读本页组 ⇒ IO ∝ 页大小
    /// （不再全量读 session 后过滤）。
    private func loadAssetRows(
        sessionId: String,
        groups: [CullingAssetGroup]
    ) async throws -> [PhotoPage] {
        guard !groups.isEmpty else { return [] }
        var rows: [PhotoPage] = []
        for chunk in groups.map(\.groupId).chunked(by: Self.groupChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let chunkRows = try await database.query(
                """
                SELECT \(PhotoFormats.pageColumns) FROM photos p
                WHERE p.session_id = ? AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (\(placeholders))
                ORDER BY p.rowid
                """,
                [.text(sessionId)] + chunk.map { .text($0) }
            )
            rows.append(contentsOf: try chunkRows.map { try $0.decode(PhotoPage.self) })
        }
        return rows
    }

    // MARK: 谓词（原样搬移）

    /// TS preferredRowPredicate —— 每个资产组限定到首选行的 SQL 谓词：RAW 变体
    /// 优先（与 JS 侧 assembleAssets 的偏好同一扩展名表），其次最小 rowid。谓词
    /// 对未分组照片是 no-op（gid = id ⇒ 子查询返回自身）。
    private static func preferredRowPredicate() -> String {
        "p.id = (" +
            "SELECT p2.id FROM photos p2" +
            " WHERE p2.session_id = p.session_id" +
            " AND COALESCE(NULLIF(p2.asset_id, ''), p2.id) = COALESCE(NULLIF(p.asset_id, ''), p.id)" +
            " ORDER BY CASE WHEN \(PhotoFormats.rawExtensionLikeSQL) THEN 1 ELSE 0 END DESC, p2.rowid" +
            " LIMIT 1" +
        ")"
    }

    /// TS buildFilteredWhere —— matchesFilters 的精确超集（除 metadataConflictOnly
    /// —— 它依赖 JS 计算的 XMP 侧车路径）。子句/参数顺序与原实现逐字一致。
    private static func appendFilterClauses(
        _ spec: CullingFilterSpec,
        to clauses: inout [String],
        params: inout [SQLiteValue]
    ) {
        if spec.unreviewed {
            clauses.append("COALESCE(d.decision, 'pending') = 'pending'")
        }
        if !spec.pickStates.isEmpty {
            let decisions = spec.pickStates.map { state -> String in
                switch state {
                case .picked: "keep"
                case .rejected: "reject"
                case .unreviewed: "pending"
                }
            }
            let placeholders = decisions.map { _ in "?" }.joined(separator: ",")
            clauses.append("COALESCE(d.decision, 'pending') IN (\(placeholders))")
            params.append(contentsOf: decisions.map { .text($0) })
        }
        if !spec.ratings.isEmpty {
            let placeholders = spec.ratings.map { _ in "?" }.joined(separator: ",")
            clauses.append("COALESCE(d.rating, c.rating, 0) IN (\(placeholders))")
            params.append(contentsOf: spec.ratings.map { SQLiteValue.real($0) })
        }
        if !spec.colorLabels.isEmpty {
            let placeholders = spec.colorLabels.map { _ in "?" }.joined(separator: ",")
            clauses.append("""
                COALESCE(NULLIF(d.color_label, ''), NULLIF(c.label, ''), 'None') IN (\(placeholders))
                """)
            params.append(contentsOf: spec.colorLabels.map { .text($0.rawValue) })
        }
        switch spec.quality {
        case .succeeded:
            clauses.append(Self.qualityStatusClause)
            params.append(.text("succeeded"))
        case .failed:
            clauses.append(Self.qualityStatusClause)
            params.append(.text("failed"))
        case .absent:
            clauses.append(Self.qualityAbsentClause)
        case nil:
            break
        }
    }

    /// 组查询 JOIN 片段（filtered 用 d./c.；相似度 scope 只查 photos）。
    private static func joins(for scope: CullingQueryScope) -> String {
        switch scope {
        case .filtered:
            return filteredJoins
        case .all, .similarityGroup, .similarityLatest:
            return ""
        }
    }

    /// .all 分支的组列表从 PhotoStore 返回行按 rowid 顺序推导：每组首行即组首
    /// rowid（getAssetPage 已按 rowid 升序返回整组行），不额外发分组 SQL。
    private static func groups(from rows: [PhotoPage]) -> [CullingAssetGroup] {
        var groups: [CullingAssetGroup] = []
        var seen = Set<String>()
        for row in rows {
            let groupId = row.assetId.flatMap { $0.isEmpty ? nil : $0 } ?? row.id
            if seen.insert(groupId).inserted {
                groups.append(CullingAssetGroup(groupId: groupId, firstRowId: row.rowid))
            }
        }
        return groups
    }
}
