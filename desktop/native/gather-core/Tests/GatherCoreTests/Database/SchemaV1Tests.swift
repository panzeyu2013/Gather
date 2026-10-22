// desktop/native/gather-core/Tests/GatherCoreTests/Database/SchemaV1Tests.swift
// Cut 2 / S1：SchemaV1 的结构门禁（只读断言，不接入 Database.open，不碰 Schema/Migrations）。
//
// 为什么需要这组测试：V1 一次成型、没有迁移链兜底，任何「少一列 / 少一索引 /
// 少一外键」都只会在运行期以静默错列（SELECT * 按位置取值）的形式暴露（draft §8 R1）。
// 因此这里把 43 / 373 / 69 / 62 / user_version=1 五个数字、43 张表的逐表列数、
// CHECK 与 FK 的拒绝路径、CASCADE / SET NULL / RESTRICT 的删除语义全部钉成回归。
//
// 用户数据 FK（D-025）：role_bindings.cluster_id、person_photos.photo_id / session_id 是
// RESTRICT；face_identity_feedback.person_id 是 SET NULL。CHECK（D-027）：
// asset_members.binding_source 必须接受生产值 'auto_raw_jpeg'。
//
// 全部用例使用 DBConnection(path: ":memory:")：不落盘、不共享连接、互不影响。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

// MARK: - 期望值（来自 docs/schema-v1-draft.md §7.1 的 DDL 与 §9.1 的实测表）

/// 一张表的列数期望。逐表断言，任何删列/加列都会让对应用例独立变红。
struct SchemaV1TableSpec: Sendable, CustomTestStringConvertible {
    let table: String
    let columns: Int
    var testDescription: String { "\(table) (\(columns) 列)" }
}

/// CHECK 拒绝用例：setup 建出满足 FK 的父行，failing 必须被 CHECK 拒绝。
struct SchemaV1CheckCase: Sendable, CustomTestStringConvertible {
    let name: String
    let setup: [String]
    let failing: String
    var testDescription: String { name }
}

/// 43 张表的逐表列数（draft §9.1，已用 §7.1 DDL 实测复算，合计 373；
/// Cut 5 / 5b-2b 给 similarity_cluster_meta +3：algorithm_version / input_signature / state_digest）。
private let schemaV1ColumnCounts: [SchemaV1TableSpec] = [
    SchemaV1TableSpec(table: "analysis_jobs", columns: 24),
    SchemaV1TableSpec(table: "analysis_runs", columns: 10),
    SchemaV1TableSpec(table: "app_settings", columns: 2),
    SchemaV1TableSpec(table: "asset_analysis", columns: 11),
    SchemaV1TableSpec(table: "asset_backfill_state", columns: 9),
    SchemaV1TableSpec(table: "asset_files", columns: 14),
    SchemaV1TableSpec(table: "asset_link_candidates", columns: 9),
    SchemaV1TableSpec(table: "asset_members", columns: 7),
    SchemaV1TableSpec(table: "assets", columns: 4),
    SchemaV1TableSpec(table: "culling_decisions", columns: 11),
    SchemaV1TableSpec(table: "culling_history", columns: 5),
    SchemaV1TableSpec(table: "deliveries", columns: 14),
    SchemaV1TableSpec(table: "delivery_intents", columns: 8),
    SchemaV1TableSpec(table: "delivery_items", columns: 11),
    SchemaV1TableSpec(table: "delivery_sessions", columns: 4),
    SchemaV1TableSpec(table: "duplicate_group_members", columns: 8),
    SchemaV1TableSpec(table: "duplicate_groups", columns: 8),
    SchemaV1TableSpec(table: "face_analysis_state", columns: 6),
    SchemaV1TableSpec(table: "face_cluster_members", columns: 7),
    SchemaV1TableSpec(table: "face_cluster_state", columns: 3),
    SchemaV1TableSpec(table: "face_clusters", columns: 9),
    SchemaV1TableSpec(table: "face_identity_feedback", columns: 11),
    SchemaV1TableSpec(table: "face_observations", columns: 17),
    SchemaV1TableSpec(table: "metadata_keyword_origins", columns: 6),
    SchemaV1TableSpec(table: "navigation_groups", columns: 10),
    SchemaV1TableSpec(table: "person_embeddings", columns: 7),
    SchemaV1TableSpec(table: "person_photos", columns: 7),
    SchemaV1TableSpec(table: "persons", columns: 8),
    SchemaV1TableSpec(table: "photo_metadata_cache", columns: 22),
    SchemaV1TableSpec(table: "photos", columns: 14),
    SchemaV1TableSpec(table: "role_bindings", columns: 7),
    SchemaV1TableSpec(table: "session_assets", columns: 5),
    SchemaV1TableSpec(table: "sessions", columns: 10),
    SchemaV1TableSpec(table: "sidecar_binding_files", columns: 3),
    SchemaV1TableSpec(table: "sidecar_bindings", columns: 7),
    SchemaV1TableSpec(table: "sidecar_metadata_state", columns: 6),
    SchemaV1TableSpec(table: "similarity_cluster_meta", columns: 11),
    SchemaV1TableSpec(table: "similarity_cluster_state", columns: 5),
    SchemaV1TableSpec(table: "similarity_hashes", columns: 6),
    SchemaV1TableSpec(table: "similarity_result_members", columns: 4),
    SchemaV1TableSpec(table: "similarity_results", columns: 7),
    SchemaV1TableSpec(table: "smart_albums", columns: 10),
    SchemaV1TableSpec(table: "workflow_templates", columns: 6),
]

/// CHECK 用例（覆盖 job / delivery / photo / session / 资产 / 相似度 / 人脸 / 挑片等状态列）。
private let schemaV1CheckCases: [SchemaV1CheckCase] = [
    SchemaV1CheckCase(
        name: "sessions.status = indexed",
        setup: [],
        failing: "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('c','indexed','t','t');"
    ),
    SchemaV1CheckCase(
        name: "sessions.truncated_import = 2",
        setup: [],
        failing: "INSERT INTO sessions (id,truncated_import,created_at,updated_at) VALUES ('c',2,'t','t');"
    ),
    SchemaV1CheckCase(
        name: "photos.status = imported",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO photos (id,session_id,filepath,status,created_at,updated_at)
            VALUES ('p','s','/p.NEF','imported','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "photos.width = -1",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO photos (id,session_id,filepath,width,created_at,updated_at)
            VALUES ('p','s','/p.NEF',-1,'t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "analysis_jobs.type = thumbnail",
        setup: [],
        failing: """
            INSERT INTO analysis_jobs (id,type,scope_type,scope_id,dedupe_key,status,created_at,updated_at)
            VALUES ('j','thumbnail','session','s','k','queued','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "analysis_jobs.status = done",
        setup: [],
        failing: """
            INSERT INTO analysis_jobs (id,type,scope_type,scope_id,dedupe_key,status,created_at,updated_at)
            VALUES ('j','face.analyze','session','s','k','done','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "analysis_runs.kind = metadata",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO analysis_runs (session_id,kind,photo_count,index_seq,started_at)
            VALUES ('s','metadata',0,0,'t');
            """
    ),
    SchemaV1CheckCase(
        name: "deliveries.status = clean（已删除的历史终态）",
        setup: [],
        failing: "INSERT INTO deliveries (xmp_path,status,created_at,updated_at) VALUES ('/c.xmp','clean','t','t');"
    ),
    SchemaV1CheckCase(
        name: "deliveries.revision = -1",
        setup: [],
        failing: """
            INSERT INTO deliveries (xmp_path,revision,created_at,updated_at)
            VALUES ('/c.xmp',-1,'t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "delivery_items.status = cleaned",
        setup: [
            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');",
            "INSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('p','s','/p.NEF','t','t');",
            "INSERT INTO deliveries (id,xmp_path,created_at,updated_at) VALUES (1,'/c.xmp','t','t');",
        ],
        failing: """
            INSERT INTO delivery_items (delivery_id,photo_id,module,status,created_at,updated_at)
            VALUES (1,'p','culling','cleaned','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "delivery_items.module = export",
        setup: [
            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');",
            "INSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('p','s','/p.NEF','t','t');",
            "INSERT INTO deliveries (id,xmp_path,created_at,updated_at) VALUES (1,'/c.xmp','t','t');",
        ],
        failing: """
            INSERT INTO delivery_items (delivery_id,photo_id,module,created_at,updated_at)
            VALUES (1,'p','export','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "delivery_intents.phase = done",
        setup: [],
        failing: """
            INSERT INTO delivery_intents (kind,xmp_path,phase,created_at,updated_at)
            VALUES ('cleanup','/c.xmp','done','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "delivery_intents.kind = delete",
        setup: [],
        failing: """
            INSERT INTO delivery_intents (kind,xmp_path,created_at,updated_at)
            VALUES ('delete','/c.xmp','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "culling_decisions.color_label = Black",
        setup: [
            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');",
            "INSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('p','s','/p.NEF','t','t');",
        ],
        failing: """
            INSERT INTO culling_decisions (session_id,photo_id,group_id,color_label,updated_at)
            VALUES ('s','p','g','Black','t');
            """
    ),
    SchemaV1CheckCase(
        name: "culling_decisions.decision = maybe",
        setup: [
            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');",
            "INSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('p','s','/p.NEF','t','t');",
        ],
        failing: """
            INSERT INTO culling_decisions (session_id,photo_id,group_id,decision,updated_at)
            VALUES ('s','p','g','maybe','t');
            """
    ),
    SchemaV1CheckCase(
        name: "duplicate_groups.resolution = keep_some",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO duplicate_groups (session_id,group_type,resolution,created_at)
            VALUES ('s','exact','keep_some','t');
            """
    ),
    SchemaV1CheckCase(
        name: "face_clusters.status = orphan",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: "INSERT INTO face_clusters (session_id,status) VALUES ('s','orphan');"
    ),
    SchemaV1CheckCase(
        name: "face_identity_feedback.decision = maybe",
        setup: [
            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');",
            "INSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('p','s','/p.NEF','t','t');",
        ],
        failing: """
            INSERT INTO face_identity_feedback
              (session_id,photo_id,bbox_x,bbox_y,bbox_w,bbox_h,decision,updated_at)
            VALUES ('s','p',0,0,0,0,'maybe','t');
            """
    ),
    SchemaV1CheckCase(
        name: "face_observations.quality = 1.5",
        setup: [
            "INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');",
            "INSERT INTO photos (id,session_id,filepath,created_at,updated_at) VALUES ('p','s','/p.NEF','t','t');",
        ],
        failing: """
            INSERT INTO face_observations
              (photo_id,session_id,bbox_x,bbox_y,bbox_w,bbox_h,embedding,quality)
            VALUES ('p','s',0,0,0,0,x'00',1.5);
            """
    ),
    SchemaV1CheckCase(
        name: "asset_files.media_type = video",
        setup: [],
        failing: """
            INSERT INTO asset_files (id,normalized_path,filename,media_type,created_at,updated_at)
            VALUES ('f','/v.mov','v.mov','video','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "asset_members.binding_source = auto_raw_heic（未登记值）",
        setup: [
            "INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a','active','t','t');",
            "INSERT INTO asset_files (id,normalized_path,filename,created_at,updated_at) VALUES ('f','/n','n','t','t');",
        ],
        failing: """
            INSERT INTO asset_members (asset_id,file_id,member_role,binding_source)
            VALUES ('a','f','camera_jpeg','auto_raw_heic');
            """
    ),
    SchemaV1CheckCase(
        name: "asset_members.member_role = jpeg",
        setup: [
            "INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a','active','t','t');",
            "INSERT INTO asset_files (id,normalized_path,filename,created_at,updated_at) VALUES ('f','/n','n','t','t');",
        ],
        failing: "INSERT INTO asset_members (asset_id,file_id,member_role) VALUES ('a','f','jpeg');"
    ),
    SchemaV1CheckCase(
        name: "asset_backfill_state.status = paused",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: "INSERT INTO asset_backfill_state (session_id,status,updated_at) VALUES ('s','paused','t');"
    ),
    SchemaV1CheckCase(
        name: "sidecar_bindings.status = inactive（单值集合也兜）",
        setup: [],
        failing: """
            INSERT INTO sidecar_bindings
              (id,xmp_path,normalized_xmp_path,binding_rule,status,created_at,updated_at)
            VALUES ('sb','/s.xmp','/s.n.xmp','same_basename','inactive','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "navigation_groups.group_type = scene2",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO navigation_groups (id,session_id,group_type,created_at,updated_at)
            VALUES ('n','s','scene2','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "metadata_keyword_origins.source = manual",
        setup: [],
        failing: """
            INSERT INTO metadata_keyword_origins (xmp_path,source,keyword,created_at,updated_at)
            VALUES ('/k.xmp','manual','kw','t','t');
            """
    ),
    SchemaV1CheckCase(
        name: "similarity_cluster_meta.grouping_mode = graph",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO similarity_cluster_meta (session_id,param_threshold,grouping_mode,updated_at)
            VALUES ('s',8,'graph','t');
            """
    ),
    SchemaV1CheckCase(
        name: "similarity_cluster_meta.algorithm_version = 0",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO similarity_cluster_meta
              (session_id,param_threshold,grouping_mode,algorithm_version,updated_at)
            VALUES ('s',8,'global',0,'t');
            """
    ),
    SchemaV1CheckCase(
        name: "similarity_results.param_threshold = 65",
        setup: ["INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s','draft','t','t');"],
        failing: """
            INSERT INTO similarity_results (session_id,groups_json,param_threshold,created_at)
            VALUES ('s','[]',65,'t');
            """
    ),
    SchemaV1CheckCase(
        name: "persons.match_threshold = 1.5",
        setup: [],
        failing: "INSERT INTO persons (id,name,match_threshold,created_at,updated_at) VALUES ('pe','n',1.5,'t','t');"
    ),
]

// MARK: - 公共辅助

/// 新建一个只在内存里的 V1 库（不存在于任何文件，测试结束随连接释放）。
private func makeSchemaV1Database() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaV1.sql)
    return db
}

/// 取单行单列的整数标量。
private func scalarInt(_ db: DBConnection, _ sql: String) throws -> Int {
    guard let raw = try db.prepare(sql).get([])?[0].intValue else {
        throw DBError.message("标量查询无结果: \(sql)")
    }
    return Int(raw)
}

/// 全部用户表名（升序，排除 sqlite_ 内部表）。
private func userTables(_ db: DBConnection) throws -> [String] {
    let rows = try db.prepare("""
        SELECT name FROM sqlite_master
         WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
         ORDER BY name
        """).query([])
    return rows.compactMap { $0[0].textValue }
}

/// 执行一条**必须失败**的语句，返回错误消息（成功则返回 nil）。
private func rejectionMessage(_ db: DBConnection, _ sql: String) -> String? {
    do {
        try db.exec(sql)
        return nil
    } catch let error as DBError {
        if case .message(let message) = error { return message }
        return "\(error)"
    } catch {
        return "\(error)"
    }
}

// MARK: - 测试

@Suite("SchemaV1")
struct SchemaV1Tests {

    // MARK: 建库与总量

    @Test("exec(SchemaV1.sql) 成功：43 张表 / 373 列")
    func appliesSchema() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        // 表清单必须与 draft §7.1 完全一致（多一张/少一张都红）。
        let expectedTables = Set(schemaV1ColumnCounts.map(\.table))
        let tables = try userTables(db)
        #expect(tables.count == 43, "表数漂移：期望 43，实际 \(tables.count)")
        #expect(Set(tables) == expectedTables, "表清单与 draft §7.1 不一致")

        var columns = 0
        for table in tables {
            columns += try db.prepare("PRAGMA table_info(\(table))").query([]).count
        }
        #expect(columns == 373, "列数漂移：期望 373，实际 \(columns)")
    }

    @Test("索引 69 个（含 8 个 UNIQUE）")
    func indexCount() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        let indexes = try scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
            """)
        #expect(indexes == 69, "索引数漂移：期望 69，实际 \(indexes)")

        // 「含 unique」：8 个显式 UNIQUE 索引（其余 61 个普通索引），
        // 且唯一性必须真的落在期望的列上（防止把 UNIQUE 写成普通 INDEX）。
        let uniqueIndexes = try scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
               AND sql LIKE 'CREATE UNIQUE INDEX%'
            """)
        #expect(uniqueIndexes == 8, "UNIQUE 索引数漂移：期望 8，实际 \(uniqueIndexes)")

        let photoPathUnique = try scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index' AND name = 'idx_photos_session_filepath'
               AND sql LIKE 'CREATE UNIQUE INDEX%'
            """)
        #expect(photoPathUnique == 1, "idx_photos_session_filepath 必须是 UNIQUE")
    }

    @Test("外键 62 个，PRAGMA foreign_key_check 干净")
    func foreignKeyCount() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        var foreignKeys = 0
        for table in try userTables(db) {
            foreignKeys += try db.prepare("PRAGMA foreign_key_list(\(table))").query([]).count
        }
        #expect(foreignKeys == 62, "外键数漂移：期望 62，实际 \(foreignKeys)")

        let dirty = try scalarInt(db, "SELECT COUNT(*) FROM pragma_foreign_key_check")
        #expect(dirty == 0, "空库的 foreign_key_check 必须干净（否则 FK 的父键不是 PK/UNIQUE）")
    }

    @Test("PRAGMA user_version = 1（与 SchemaV1.userVersion 一致）")
    func userVersion() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        #expect(SchemaV1.userVersion == 1)
        #expect(try scalarInt(db, "PRAGMA user_version") == SchemaV1.userVersion)
    }

    // MARK: 逐表列数（删列漂移门禁）

    @Test("逐表列数（43 张表）", arguments: schemaV1ColumnCounts)
    func columnCounts(_ spec: SchemaV1TableSpec) throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        let actual = try db.prepare("PRAGMA table_info(\(spec.table))").query([]).count
        #expect(
            actual == spec.columns,
            "表 \(spec.table) 列数漂移：期望 \(spec.columns)，实际 \(actual)"
        )
    }

    // MARK: CHECK

    @Test("CHECK 拒绝非法值", arguments: schemaV1CheckCases)
    func checkRejectsIllegalValue(_ spec: SchemaV1CheckCase) throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        // 父行先建好，确保失败原因只能是 CHECK，不是 FK。
        if !spec.setup.isEmpty {
            try db.exec(spec.setup.joined(separator: "\n"))
        }
        let message = rejectionMessage(db, spec.failing)
        #expect(
            message?.contains("CHECK constraint failed") == true,
            "\(spec.name) 应被 CHECK 拒绝，实际：\(message ?? "语句竟然成功")"
        )
    }

    @Test("similarity_cluster_meta 版本三列：默认值可插入、可读回（5b-2b）")
    func clusterMetaVersionColumnsHaveDefaults() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        // 不写三列的旧式插入必须仍然成功（CHECK 用例也依赖这一点）；默认值
        // 刻意是「当前版本 + 空指纹/空摘要」：空串永远不等于真实指纹，所以
        // 这类行只会被判为失效，不会被误当成可复用状态。
        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-meta','draft','t','t');
            INSERT INTO similarity_cluster_meta (session_id,param_threshold,grouping_mode,updated_at)
              VALUES ('s-meta',8,'global','t');
            """)

        let row = try #require(try db.prepare("""
            SELECT algorithm_version, input_signature, state_digest
            FROM similarity_cluster_meta WHERE session_id = 's-meta'
            """).get([]))
        #expect(row[0].intValue == 1, "algorithm_version 默认必须是当前版本 1（且 CHECK >= 1）")
        #expect(row[1].textValue == "", "input_signature 默认空串（不等于任何真实指纹）")
        #expect(row[2].textValue == "", "state_digest 默认空串（不等于任何真实摘要）")

        // 显式写入合法版本仍可用（NOT NULL 且非负）。
        try db.exec("""
            UPDATE similarity_cluster_meta
               SET algorithm_version = 2, input_signature = 'v2|t=8|m=2|g=global', state_digest = 'fnv1a64:00'
             WHERE session_id = 's-meta';
            """)
        let updated = try #require(try db.prepare("""
            SELECT algorithm_version, input_signature, state_digest
            FROM similarity_cluster_meta WHERE session_id = 's-meta'
            """).get([]))
        #expect(updated[0].intValue == 2)
        #expect(updated[1].textValue == "v2|t=8|m=2|g=global")
        #expect(updated[2].textValue == "fnv1a64:00")
    }

    // MARK: 外键

    @Test("非法外键被拒绝（photos.session_id）")
    func foreignKeyRejectsUnknownSession() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        let message = rejectionMessage(
            db,
            """
            INSERT INTO photos (id,session_id,filepath,created_at,updated_at)
            VALUES ('p','nope','/p.NEF','t','t');
            """
        )
        #expect(
            message?.contains("FOREIGN KEY constraint failed") == true,
            "引用不存在的 session 必须被 FK 拒绝，实际：\(message ?? "语句竟然成功")"
        )
    }

    @Test("非法外键被拒绝（delivery_items.photo_id）")
    func foreignKeyRejectsUnknownPhoto() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("INSERT INTO deliveries (id,xmp_path,created_at,updated_at) VALUES (1,'/x.xmp','t','t');")
        let message = rejectionMessage(
            db,
            """
            INSERT INTO delivery_items (delivery_id,photo_id,module,created_at,updated_at)
            VALUES (1,'ghost','culling','t','t');
            """
        )
        #expect(
            message?.contains("FOREIGN KEY constraint failed") == true,
            "引用不存在的 photo 必须被 FK 拒绝，实际：\(message ?? "语句竟然成功")"
        )
    }

    // MARK: 删除语义（CASCADE / SET NULL）

    @Test("删 sessions 级联清空 photos / delivery_sessions / delivery_items，deliveries 保留")
    func deletingSessionCascades() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s1','photos_loaded','t','t');
            INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a1','active','t','t');
            INSERT INTO photos (id,session_id,filepath,asset_id,created_at,updated_at)
              VALUES ('p1','s1','/x/1.NEF','a1','t','t');
            INSERT INTO deliveries (id,xmp_path,photo_path,status,created_at,updated_at)
              VALUES (1,'/x/1.xmp','/x/1.NEF','written','t','t');
            INSERT INTO delivery_sessions (delivery_id,session_id,confirmed_at) VALUES (1,'s1','t');
            INSERT INTO delivery_items (delivery_id,photo_id,module,status,created_at,updated_at)
              VALUES (1,'p1','culling','written','t','t');
            """)

        try db.exec("DELETE FROM sessions WHERE id = 's1';")

        #expect(try scalarInt(db, "SELECT COUNT(*) FROM photos") == 0, "photos 必须随会话级联删除")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM delivery_sessions") == 0, "delivery_sessions 必须级联删除")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM delivery_items") == 0, "delivery_items 必须级联删除")
        // deliveries 是文件级事实，刻意保留（draft §7.3 第 4 条；由孤儿清扫回收）。
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM deliveries") == 1, "deliveries 必须保留（不是会话的子行）")
    }

    @Test("删 assets 后 photos.asset_id 变 NULL，照片行保留")
    func deletingAssetSetsNull() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s2','draft','t','t');
            INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a2','active','t','t');
            INSERT INTO photos (id,session_id,filepath,asset_id,created_at,updated_at)
              VALUES ('p2','s2','/2.NEF','a2','t','t');
            """)

        try db.exec("DELETE FROM assets WHERE id = 'a2';")

        #expect(try scalarInt(db, "SELECT COUNT(*) FROM photos WHERE id = 'p2'") == 1, "照片行不得被删除")
        #expect(try scalarInt(db, """
            SELECT COUNT(*) FROM photos WHERE id = 'p2' AND asset_id IS NULL
            """) == 1, "photos.asset_id 必须置 NULL（ON DELETE SET NULL）")
    }

    // MARK: 用户数据 FK（RESTRICT / SET NULL）与 CHECK 补齐（D-025 / D-027）

    @Test("有 role_bindings 行时 DELETE face_clusters 被 RESTRICT 拒绝（R2-01）")
    func deletingClusterWithRoleBindingIsRejected() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-rb','draft','t','t');
            INSERT INTO face_clusters (id,session_id,label,status) VALUES (7,'s-rb','簇 A','bound');
            INSERT INTO role_bindings (cluster_id,session_id,role_name) VALUES (7,'s-rb','主角');
            """)

        // 绑定是用户身份凭据（也是 XMP 人物关键词的清理依据）：CASCADE 会静默删掉它，
        // 所以这里必须是 RESTRICT —— 删除簇前先显式迁移/删除绑定。
        let message = rejectionMessage(db, "DELETE FROM face_clusters WHERE id = 7;")
        #expect(
            message?.contains("FOREIGN KEY constraint failed") == true,
            "有 role_bindings 时删簇必须被 RESTRICT 拒绝，实际：\(message ?? "语句竟然成功")"
        )
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM role_bindings") == 1, "绑定行不得被静默删除")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM face_clusters") == 1, "簇行必须保留")

        // 显式解绑后同一句删除才允许通过（唯一合法入口）。
        try db.exec("DELETE FROM role_bindings WHERE cluster_id = 7;")
        try db.exec("DELETE FROM face_clusters WHERE id = 7;")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM face_clusters") == 0, "显式解绑后应允许删簇")
    }

    @Test("asset_members.binding_source 接受生产值 auto_raw_jpeg（R3-01）")
    func acceptsAutoRawJpegBindingSource() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO assets (id,status,created_at,updated_at) VALUES ('a-raw','active','t','t');
            INSERT INTO asset_files (id,normalized_path,filename,created_at,updated_at)
              VALUES ('f-jpeg','/x/1.JPG','1.JPG','t','t');
            INSERT INTO asset_members (asset_id,file_id,member_role,is_primary,binding_source)
              VALUES ('a-raw','f-jpeg','camera_jpeg',1,'auto_raw_jpeg');
            """)

        // AssetRepo.mergeFileAssets（acceptCandidate / reconcileRawJpegLinks 路径）写这个值；
        // V1 CHECK 漏了它，RAW/JPEG 合并就会抛 CHECK constraint failed。
        #expect(try scalarInt(db, """
            SELECT COUNT(*) FROM asset_members WHERE binding_source = 'auto_raw_jpeg'
            """) == 1, "RAW/JPEG 自动合并的生产值必须被接受")
    }

    @Test("photos.status 拒绝 'indexed'（R3-02：UI 阶段不落库，photos 无写入点）")
    func photosStatusRejectsIndexed() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-idx','draft','t','t');
            """)
        // 'indexed' 属于 WorkspaceStage；唯一写库点是测试夹具写 sessions.status（R3-02），
        // photos 没有任何生产/测试写入点，因此本 CHECK 刻意不加入该值（旧库整体 reset，无存量）。
        let message = rejectionMessage(db, """
            INSERT INTO photos (id,session_id,filepath,status,created_at,updated_at)
            VALUES ('p-idx','s-idx','/x/1.NEF','indexed','t','t');
            """)
        #expect(
            message?.contains("CHECK constraint failed") == true,
            "photos.status 不得接受 WorkspaceStage 值 'indexed'，实际：\(message ?? "语句竟然成功")"
        )
    }

    @Test("有 person_photos 时 DELETE photos 被 RESTRICT 拒绝（R2-02）")
    func deletingPhotoWithPersonPhotoIsRejected() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-pp','draft','t','t');
            INSERT INTO persons (id,name,created_at,updated_at) VALUES ('pe-pp','阿明','t','t');
            INSERT INTO photos (id,session_id,filepath,created_at,updated_at)
              VALUES ('p-pp','s-pp','/x/2.NEF','t','t');
            INSERT INTO person_photos (person_id,photo_id,session_id,face_bbox,created_at)
              VALUES ('pe-pp','p-pp','s-pp','0,0,1,1','t');
            """)

        let message = rejectionMessage(db, "DELETE FROM photos WHERE id = 'p-pp';")
        #expect(
            message?.contains("FOREIGN KEY constraint failed") == true,
            "有 person_photos 时删照片必须被 RESTRICT 拒绝，实际：\(message ?? "语句竟然成功")"
        )
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM person_photos") == 1, "身份-照片桥接不得被静默删除")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM photos") == 1, "照片行必须保留")

        // 显式解除身份关联后才允许删照片。
        try db.exec("DELETE FROM person_photos WHERE photo_id = 'p-pp';")
        try db.exec("DELETE FROM photos WHERE id = 'p-pp';")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM photos") == 0, "显式解绑后应允许删照片")
    }

    @Test("有 person_photos 时 DELETE sessions 被 RESTRICT 拒绝（R2-02）")
    func deletingSessionWithPersonPhotoIsRejected() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-ps','draft','t','t');
            INSERT INTO persons (id,name,created_at,updated_at) VALUES ('pe-ps','阿岚','t','t');
            INSERT INTO photos (id,session_id,filepath,created_at,updated_at)
              VALUES ('p-ps','s-ps','/x/3.NEF','t','t');
            INSERT INTO person_photos (person_id,photo_id,session_id,face_bbox,created_at)
              VALUES ('pe-ps','p-ps','s-ps','0,0,1,1','t');
            """)

        let message = rejectionMessage(db, "DELETE FROM sessions WHERE id = 's-ps';")
        #expect(
            message?.contains("FOREIGN KEY constraint failed") == true,
            "有 person_photos 时删会话必须被 RESTRICT 拒绝，实际：\(message ?? "语句竟然成功")"
        )
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM sessions") == 1, "会话行必须保留")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM person_photos") == 1, "身份-照片桥接必须保留")
    }

    @Test("删 persons 后 face_identity_feedback.person_id 置 NULL，人工判定保留（R2-04）")
    func deletingPersonSetsFeedbackPersonNull() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-fb','draft','t','t');
            INSERT INTO persons (id,name,created_at,updated_at) VALUES ('pe-fb','老周','t','t');
            INSERT INTO photos (id,session_id,filepath,created_at,updated_at)
              VALUES ('p-fb','s-fb','/x/4.NEF','t','t');
            INSERT INTO face_identity_feedback
              (session_id,photo_id,bbox_x,bbox_y,bbox_w,bbox_h,person_id,decision,updated_at)
            VALUES ('s-fb','p-fb',0,0,1,1,'pe-fb','confirmed','t');
            """)

        try db.exec("DELETE FROM persons WHERE id = 'pe-fb';")

        #expect(try scalarInt(db, "SELECT COUNT(*) FROM face_identity_feedback") == 1, "人工确认/否决证据不得随身份删除")
        #expect(try scalarInt(db, """
            SELECT COUNT(*) FROM face_identity_feedback WHERE person_id IS NULL AND decision = 'confirmed'
            """) == 1, "person_id 必须置 NULL（ON DELETE SET NULL）且 decision 保留")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM persons") == 0, "身份行应被删除")
    }

    @Test("删 photos 级联清空派生 person_embeddings（R2-03）")
    func deletingPhotoCascadesPersonEmbeddings() throws {
        let db = try makeSchemaV1Database()
        defer { db.close() }

        try db.exec("""
            INSERT INTO sessions (id,status,created_at,updated_at) VALUES ('s-pe','draft','t','t');
            INSERT INTO persons (id,name,created_at,updated_at) VALUES ('pe-vec','小柯','t','t');
            INSERT INTO photos (id,session_id,filepath,created_at,updated_at)
              VALUES ('p-pe','s-pe','/x/5.NEF','t','t');
            INSERT INTO person_embeddings (person_id,embedding,photo_id,session_id,created_at)
              VALUES ('pe-vec',x'00','p-pe','s-pe','t');
            """)

        try db.exec("DELETE FROM photos WHERE id = 'p-pe';")

        #expect(try scalarInt(db, "SELECT COUNT(*) FROM person_embeddings") == 0, "派生向量必须随照片级联删除")
        #expect(try scalarInt(db, "SELECT COUNT(*) FROM persons") == 1, "身份行不得被连带删除")
    }
}
