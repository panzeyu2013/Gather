// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PhotoSemanticsRepo.swift
// P1 下一波 / §3.11.5：photo_semantics 的读写（场景标签 + 图像 feature print）。
//
// 边界：
// - 本文件只做 SQL 与 DTO：向量编码（Float16）、余弦、标签合并都在
//   GatherApplication 的 SemanticIndex（Persistence 不依赖 Application）；
// - feature 以 BLOB 原样存取（写入方决定格式，读出方按 model_version 解释）；
// - 行删除全部经 photos 的 ON DELETE CASCADE 或显式 clear（设置页"清空语义索引"）。
import Foundation
import GatherProtocol

/// 语义行写入载荷（feature 已由调用方编码）。
public struct PhotoSemanticsInsert: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    /// Vision 分类标签 JSON（`[{"label":...,"confidence":...}]`），空串按 "[]" 落库。
    public let labelsJson: String
    /// 编码后的 feature print；nil = 只存标签（Vision 不可用/降级）。
    public let feature: Data?
    public let featureDim: Int
    public let modelVersion: String
    public let computedAt: String

    public init(
        photoId: String,
        sessionId: String,
        labelsJson: String,
        feature: Data?,
        featureDim: Int,
        modelVersion: String,
        computedAt: String
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.labelsJson = labelsJson
        self.feature = feature
        self.featureDim = featureDim
        self.modelVersion = modelVersion
        self.computedAt = computedAt
    }
}

/// 语义行读回投影。
public struct PhotoSemanticsRow: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let labelsJson: String
    public let feature: Data?
    public let featureDim: Int
    public let modelVersion: String
    public let computedAt: String

    public init(
        photoId: String,
        sessionId: String,
        labelsJson: String,
        feature: Data?,
        featureDim: Int,
        modelVersion: String,
        computedAt: String
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.labelsJson = labelsJson
        self.feature = feature
        self.featureDim = featureDim
        self.modelVersion = modelVersion
        self.computedAt = computedAt
    }
}

/// 语义存储端口。Application（SemanticIndex / ModelReviewService）只依赖它，
/// 测试可用内存假件，不需要真库。
public protocol PhotoSemanticsStore {
    /// 同一 photo 覆盖写（photo_semantics 以 photo_id 为主键）。
    func upsert(_ inserts: [PhotoSemanticsInsert]) throws
    func load(photoId: String) throws -> PhotoSemanticsRow?
    /// 会话内全部行（按 computed_at 升序，稳定顺序便于测试与分页）。
    func loadRows(sessionId: String, limit: Int) throws -> [PhotoSemanticsRow]
    /// 指定照片集合的行（分块 IN；图搜图的候选裁剪用）。
    func loadRows(sessionId: String, photoIds: [String]) throws -> [PhotoSemanticsRow]
    /// 已建语义行的 photo_id 集合（不回读 BLOB）：语义回填的增量判断用。
    func indexedPhotoIds(sessionId: String) throws -> Set<String>
    /// 已建语义行的 photo_id 集合，但**只算 `model_version` 相符的行**（P0-3）。
    ///
    /// 换语义模型后旧向量不是"已建索引"：同维不同模型是两种向量空间
    /// （EmbeddingModel.swift:12-14 明令禁止混用），算作已建就会静默沿用。
    func indexedPhotoIds(sessionId: String, modelVersion: String) throws -> Set<String>
    func count(sessionId: String) throws -> Int
    /// 清空一个会话的语义行（设置页"清空语义索引"按会话）。
    func deleteSession(_ sessionId: String) throws -> Int
    /// 清空全库语义行（隐私："清空语义索引"）。
    func deleteAll() throws -> Int
    /// 分批删除 `model_version` 不是 `keepingModelVersion` 的行（P0-3 的"重建语义索引"路径）。
    ///
    /// 返回删除行数。实现按批删（每批一个隐式事务），**不持一把大事务锁**：
    /// 语义行可随时重算，分批之间被打断只需下次继续清。
    /// **必须在事务外调用**：包进调用方事务后每批不再是独立事务，循环退化成一把大锁。
    func clearStaleRows(sessionId: String, keepingModelVersion: String) throws -> Int
}

public extension PhotoSemanticsStore {
    func loadRows(sessionId: String) throws -> [PhotoSemanticsRow] {
        try loadRows(sessionId: sessionId, limit: 0)
    }
}

public final class PhotoSemanticsRepo: PhotoSemanticsStore {
    /// 单条 SQL 的 IN 上限（与其它仓储一致的 800 分块）。
    public static let chunkSize = 800
    /// 分批清理语义行的单批行数（P0-3）：每批一个隐式事务，单次写锁只压在一批上。
    static let staleRowBatchSize = 2_000

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func upsert(_ inserts: [PhotoSemanticsInsert]) throws {
        guard !inserts.isEmpty else { return }
        try connection.transaction {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO photo_semantics (
                  photo_id, session_id, labels_json, feature, feature_dim,
                  model_version, computed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            for insert in inserts {
                let labels = insert.labelsJson.isEmpty ? "[]" : insert.labelsJson
                _ = try statement.run([
                    .text(insert.photoId),
                    .text(insert.sessionId),
                    .text(labels),
                    insert.feature.map(DBValue.blob) ?? .null,
                    .int(Int64(max(0, insert.featureDim))),
                    .text(insert.modelVersion),
                    .text(insert.computedAt),
                ])
            }
        }
    }

    public func load(photoId: String) throws -> PhotoSemanticsRow? {
        let row = try connection.prepare("""
            SELECT photo_id, session_id, labels_json, feature, feature_dim,
                   model_version, computed_at
            FROM photo_semantics
            WHERE photo_id = ?
            """).get([.text(photoId)])
        return row.map(Self.decode)
    }

    /// 会话内全部行（按 computed_at, photo_id 升序）。
    ///
    /// **LIMIT 在 SQL 里先生效、不按 model_version 过滤**：调用方（SemanticIndex）解码时
    /// 才剔除旧版本行，旧行会占配额（版本过滤下推 SQL 是后续项）。
    public func loadRows(sessionId: String, limit: Int) throws -> [PhotoSemanticsRow] {
        var params: [DBValue?] = [.text(sessionId)]
        var sql = """
            SELECT photo_id, session_id, labels_json, feature, feature_dim,
                   model_version, computed_at
            FROM photo_semantics
            WHERE session_id = ?
            ORDER BY computed_at ASC, photo_id ASC
            """
        if limit > 0 {
            sql += "\nLIMIT ?"
            params.append(.int(Int64(limit)))
        }
        return try connection.prepare(sql).query(params).map(Self.decode)
    }

    public func loadRows(sessionId: String, photoIds: [String]) throws -> [PhotoSemanticsRow] {
        guard !photoIds.isEmpty else { return [] }
        var rows: [PhotoSemanticsRow] = []
        for chunk in chunks(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var params: [DBValue?] = [.text(sessionId)]
            params.append(contentsOf: chunk.map { .text($0) })
            let queryRows = try connection.prepare("""
                SELECT photo_id, session_id, labels_json, feature, feature_dim,
                       model_version, computed_at
                FROM photo_semantics
                WHERE session_id = ? AND photo_id IN (\(placeholders))
                ORDER BY photo_id ASC
                """).query(params)
            rows.append(contentsOf: queryRows.map(Self.decode))
        }
        return rows
    }

    public func indexedPhotoIds(sessionId: String) throws -> Set<String> {
        let rows = try connection.prepare(
            "SELECT photo_id FROM photo_semantics WHERE session_id = ?"
        ).query([.text(sessionId)])
        return Set(rows.compactMap { $0[0].textValue })
    }

    public func indexedPhotoIds(sessionId: String, modelVersion: String) throws -> Set<String> {
        let rows = try connection.prepare("""
            SELECT photo_id FROM photo_semantics
            WHERE session_id = ? AND model_version = ?
            """).query([.text(sessionId), .text(modelVersion)])
        return Set(rows.compactMap { $0[0].textValue })
    }

    public func count(sessionId: String) throws -> Int {
        let row = try connection.prepare(
            "SELECT COUNT(*) FROM photo_semantics WHERE session_id = ?"
        ).get([.text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func deleteSession(_ sessionId: String) throws -> Int {
        try connection.prepare("DELETE FROM photo_semantics WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    public func deleteAll() throws -> Int {
        try connection.prepare("DELETE FROM photo_semantics").run([])
    }

    /// 分批清理"不是当前模型版本"的行（换语义模型后的重建路径）。
    ///
    /// 为什么不写成一条 `DELETE ... WHERE model_version <> ?`：库是 WAL + 单写者
    /// （DB.swift:113），一条覆盖 100k 行的大 DELETE 会把整批撤销页写进 WAL 并长期持
    /// 写锁——期间 analyze 的其它落库与只读池查询都被拖住，崩溃时只能整段回滚。
    /// 这里按 rowid 子查询每批删 `staleRowBatchSize` 行（各自隐式事务），
    /// 单次持锁是毫秒级；中途被打断也已删掉前面几批，下次继续。
    /// 用 IN (SELECT ... LIMIT) 而不是 `DELETE ... LIMIT`：后者要求
    /// SQLITE_ENABLE_UPDATE_DELETE_LIMIT，系统 libsqlite3 不保证编进。
    ///
    /// **调用方必须在事务外调用**：本方法靠"每批一个隐式事务"控写锁时长，包进外层事务后分批失效。
    public func clearStaleRows(sessionId: String, keepingModelVersion: String) throws -> Int {
        // 旧库 ALTER 加列可能是 NULL：`<> ?` 对 NULL 恒 unknown 会永久漏删，故 COALESCE 成空串。
        let statement = try connection.prepare("""
            DELETE FROM photo_semantics
            WHERE rowid IN (
                SELECT rowid FROM photo_semantics
                WHERE session_id = ? AND COALESCE(model_version, '') <> ?
                LIMIT ?
            )
            """)
        var removed = 0
        while true {
            let batch = try statement.run([
                .text(sessionId), .text(keepingModelVersion), .int(Int64(Self.staleRowBatchSize)),
            ])
            if batch <= 0 { break }
            removed += batch
        }
        return removed
    }

    // MARK: - 行映射

    private static func decode(_ row: DBRow) -> PhotoSemanticsRow {
        PhotoSemanticsRow(
            photoId: row[0].textValue ?? "",
            sessionId: row[1].textValue ?? "",
            labelsJson: row[2].textValue ?? "[]",
            feature: Self.blobData(row[3]),
            featureDim: Int(row[4].intValue ?? 0),
            modelVersion: row[5].textValue ?? "",
            computedAt: row[6].textValue ?? ""
        )
    }

    /// DBValue 没有 blob 访问器（只有 text/int/real）；BLOB 列在这里显式解包。
    private static func blobData(_ value: DBValue) -> Data? {
        if case .blob(let data) = value { return data }
        return nil
    }

    private func chunks(_ ids: [String]) -> [[String]] {
        guard ids.count > Self.chunkSize else { return [ids] }
        return stride(from: 0, to: ids.count, by: Self.chunkSize).map {
            Array(ids[$0..<min($0 + Self.chunkSize, ids.count)])
        }
    }
}
