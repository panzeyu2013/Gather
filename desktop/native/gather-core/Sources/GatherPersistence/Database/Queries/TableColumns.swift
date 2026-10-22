// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/TableColumns.swift
// Cut 2 / S5 预备（D-026 / D-028 R1-01）：V1 不改变行形的表的显式列清单。
//
// 用途：把 Repositories 里残留的 `SELECT *` / `alias.*` 展开成显式列。本文件只存
// 列名与列序，不参与 WHERE/JOIN/ORDER/LIMIT，也不编解码——行映射仍是各 Row 的
// `init(row: DBRow)` 位置读取（S5 再统一改 NamedRow / decoded(by:)）。
//
// 约定：
// 1. 列序 = 当前 Schema.swift 的 DDL 列序 = 现有 Row 映射器的位置下标顺序
//    （例如 AnalysisJobRow 读 0-23）。展开后结果集列序由本清单决定，不再随
//    物理列序漂移（升级库 ALTER 追加列会改变 `SELECT *` 的列序）。
// 2. 只列本表全部列，不增删；V1 会改变行形的表（photos / face_observations /
//    sessions / metadata_outbox / writeback_items）不在此处，按 D-028 单独处理。
// 3. 每个调用点在 SQL 上方注释表名与列数，便于逐条对账（见 §1.2 清单）。
enum TableColumns {
    /// 拼 `SELECT` 列清单：`id, name, ...`；传 prefix 时输出 `p.id, p.name, ...`。
    static func sql(_ columns: [String], prefix: String? = nil) -> String {
        guard let prefix else { return columns.joined(separator: ", ") }
        return columns.map { "\(prefix).\($0)" }.joined(separator: ", ")
    }

    /// analysis_jobs：24 列（Schema.swift DDL 列序；AnalysisJobRow 位置 0-23）。
    static let analysisJobs: [String] = [
        "id", "type", "scope_type", "scope_id", "dedupe_key", "status",
        "priority", "progress_current", "progress_total", "progress_message",
        "input_fingerprint", "model_id", "model_version", "checkpoint_json",
        "attempt_count", "lease_owner", "heartbeat_at", "cancel_requested_at",
        "error_code", "error_message", "created_at", "started_at", "finished_at",
        "updated_at",
    ]

    /// asset_files：14 列（AssetRepo 内联读取只用 0=id、3=normalized_path）。
    static let assetFiles: [String] = [
        "id", "volume_id", "file_identity", "normalized_path", "filename",
        "extension", "media_type", "file_size", "file_mtime_ms", "checksum",
        "online_status", "last_seen_at", "created_at", "updated_at",
    ]

    /// culling_decisions：11 列（CullingDecisionRow 位置 0-10）。
    static let cullingDecisions: [String] = [
        "id", "session_id", "photo_id", "group_id", "decision", "rating",
        "color_label", "decision_source", "revision", "created_at", "updated_at",
    ]

    /// role_bindings：7 列（RoleBindingRow 只读 0-4，尾部 created_at/updated_at 保持列序）。
    static let roleBindings: [String] = [
        "id", "cluster_id", "session_id", "role_name", "keywords",
        "created_at", "updated_at",
    ]

    /// photo_metadata_cache：22 列（MetadataCacheRow 位置 0-21）。
    static let photoMetadataCache: [String] = [
        "id", "photo_id", "session_id", "date_taken", "camera_make", "camera_model",
        "lens_model", "focal_length", "f_number", "exposure_time", "iso", "rating",
        "label", "gps_latitude", "gps_longitude", "width", "height", "file_size",
        "file_mtime", "keywords", "cached_at", "updated_at",
    ]

    /// persons：8 列（PersonRow 位置 0-7；get/listWithCounts 的追加列由调用点显式给出）。
    static let persons: [String] = [
        "id", "name", "keywords", "thumbnail_base64", "notes", "match_threshold",
        "created_at", "updated_at",
    ]

    /// person_photos：7 列（PersonPhotoRow 位置 0-6；getPhotosWithDetails 的 JOIN 列由调用点显式给出）。
    static let personPhotos: [String] = [
        "id", "person_id", "photo_id", "session_id", "face_bbox", "confidence",
        "created_at",
    ]

    /// similarity_results：7 列（SimilarityResultRow 位置 0-6）。
    static let similarityResults: [String] = [
        "id", "session_id", "groups_json", "stats_json", "param_threshold",
        "param_min_group_size", "created_at",
    ]

    /// smart_albums：10 列（SmartAlbumRow 位置 0-9）。
    static let smartAlbums: [String] = [
        "id", "filter_schema_version", "name", "description", "filter_criteria",
        "sort_by", "sort_order", "icon", "created_at", "updated_at",
    ]
}
