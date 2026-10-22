// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/HistoricalV1Shape.swift
// WP6b / P1-4：Cut 5 之前的 370 列 V1 列形（**已知旧库**，可迁移）。
//
// 历史：Cut 5 / 5b-2b 给 similarity_cluster_meta 加了 algorithm_version /
// input_signature / state_digest 三列（370 → 373），但没有 bump user_version。
// 因此「user_version=1 + 373 列」与「user_version=1 + 370 列」都是真实存在的 V1：
// 前者是当前 V1 快照，后者是 Cut 2–4 期间生成的旧 V1。只按版本号或只按 373 形态
// 判定会把后者误判为 corrupt，剥夺升级路径。
//
// 识别口径：计数（43 表 / 370 列 / 69 索引 / 62 外键）+ 关键列（373 的关键列
// 去掉三列）+ 指纹。指纹由 373 的 canonical 去掉三行列后在开发期重算并钉死
// （7fb8…）；不要用 DDL 自动计算，否则任何一个 370 形态的库都能自证「已知」。
//
// 这里只描述形态，不改 DDL：真正的补列在 MigrationV1ToV2（ALTER 三列，默认/
// CHECK 与 SchemaV1.ddl 逐字一致），由 SchemaMigrator 在 BEGIN IMMEDIATE 内执行。
import Foundation

/// Cut 5 之前（370 列）的已知 V1 列形：OpenState 用它把旧库判为 `.older(.v1)`，
/// 而不是 `.corrupt(.shapeMismatch)`。
enum HistoricalV1Shape {
    static let tableCount = 43
    static let columnCount = 370
    static let explicitIndexCount = 69
    static let foreignKeyCount = 62

    /// 373 canonical 去掉 similarity_cluster_meta 三行列后的 SHA-256。
    static let fingerprint =
        "7fb85cbfe010055f23e6dc37f385a1910f446c19e8b3c7bb8a81d9c42be68e91"

    /// 与 SchemaV1.requiredTableColumns 同源，只把 similarity_cluster_meta 的三列
    /// 换成旧版的 8 列。禁止在这里另写一份全量关键列。
    static let requiredColumns: [String: Set<String>] = {
        var columns = SchemaV1.requiredTableColumns
        var meta = columns["similarity_cluster_meta"] ?? []
        meta.subtract(["algorithm_version", "input_signature", "state_digest"])
        columns["similarity_cluster_meta"] = meta
        return columns
    }()

    static let shape = SchemaShapeExpectation(
        tableCount: tableCount,
        columnCount: columnCount,
        explicitIndexCount: explicitIndexCount,
        foreignKeyCount: foreignKeyCount,
        requiredColumns: requiredColumns,
        fingerprint: fingerprint
    )
}
