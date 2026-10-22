// desktop/native/gather-core/Tests/GatherCoreTests/Database/SchemaV1RowMappingTests.swift
// Cut 2 / S4a：V1 行映射的命名解码门禁 + DB 层 NamedRow/queryNamed 的最小回归。
//
// 背景（R1 / D-028 / D-032）：
// - V1 的 photos 只有 14 列（旧 PhotoRow 守卫 row.count >= 16、按位置读 0…15）；
// - V1 的 face_observations 只有 17 列（旧 FaceObservationRow 读 row[18] → 越界 trap）；
// - face_clusters 删了 thumbnail_base64（只改 SELECT 不改 mapper 会把 matched_person_id
//   当成 thumbnail_path）；sessions 14→11 列（派生 analysis_status）。
//
// 生产 Row 已在 S5a 按下面清单迁移；V1*Row 保留为独立 oracle（列清单 + NamedRow
// 按名解码），防止生产映射回退。S5b 追加生产写路径的 V1 冒烟（R1-06）。
// 已迁移列清单：
//   PhotoRow (14): id, session_id, filepath, filename, checksum, checksum_file_size,
//     checksum_file_mtime_ms, status, asset_id, asset_file_id, width, height,
//     created_at, updated_at（删 metadata/result）。
//   FaceObservationRow (17): id, photo_id, session_id, bbox_x/y/w/h, embedding,
//     confidence, analysis_signature, quality, face_size_px, roll_degrees, model_id,
//     model_version, embedding_dim, created_at（删 source_file_size/source_file_mtime_ms；
//     created_at 移到列尾）。
//   FaceClusterRow (10 结果列): id, session_id, label, COUNT(*) AS member_count, status,
//     thumbnail_path, matched_person_id, match_confidence, created_at, updated_at
//     （SELECT 删 thumbnail_base64，COUNT 别名保留）。
//   SessionRow (11 结果列): id, name, status, analysis_status（派生别名）, source_path,
//     truncated_import, reload_acked_at, index_seq, photo_count, created_at, updated_at
//     （删 writeback_status/import_source/failed_writeback_count）。
//
// 全部用例用 DBConnection(path: ":memory:") + SchemaV1.sql 建库，不跑迁移链。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

private let v1Timestamp = "2026-01-01T00:00:00.000Z"

// MARK: - S5 目标映射（测试内副本，生产查询未改）

/// S5 的 PhotoRow：V1 photos 14 列，全部按列名解码。
private struct V1PhotoRow: Equatable {
    static let columns = [
        "id", "session_id", "filepath", "filename", "checksum", "checksum_file_size",
        "checksum_file_mtime_ms", "status", "asset_id", "asset_file_id", "width", "height",
        "created_at", "updated_at",
    ]

    let id: String
    let sessionId: String
    let filepath: String
    let filename: String
    let checksum: String
    let checksumFileSize: Int
    let checksumFileMtimeMs: Double
    let status: String
    let assetId: String?
    let assetFileId: String?
    let width: Int
    let height: Int
    let createdAt: String
    let updatedAt: String

    init(named row: NamedRow) throws {
        id = try row.decoded(by: "id")
        sessionId = try row.decoded(by: "session_id")
        filepath = try row.decoded(by: "filepath")
        filename = try row.decoded(by: "filename")
        checksum = try row.decoded(by: "checksum")
        checksumFileSize = try row.decoded(by: "checksum_file_size")
        checksumFileMtimeMs = try row.decoded(by: "checksum_file_mtime_ms")
        status = try row.decoded(by: "status")
        assetId = try row.decodedIfPresent(by: "asset_id")
        assetFileId = try row.decodedIfPresent(by: "asset_file_id")
        width = try row.decoded(by: "width")
        height = try row.decoded(by: "height")
        createdAt = try row.decoded(by: "created_at")
        updatedAt = try row.decoded(by: "updated_at")
    }
}

/// S5 的 FaceObservationRow：V1 17 列；旧实现的 row[16]/row[18] 不再存在。
private struct V1FaceObservationRow: Equatable {
    static let columns = [
        "id", "photo_id", "session_id", "bbox_x", "bbox_y", "bbox_w", "bbox_h",
        "embedding", "confidence", "analysis_signature", "quality", "face_size_px",
        "roll_degrees", "model_id", "model_version", "embedding_dim", "created_at",
    ]

    let id: Int64
    let photoId: String
    let sessionId: String
    let bboxX: Double
    let bboxY: Double
    let bboxW: Double
    let bboxH: Double
    let embedding: Data
    let confidence: Double
    let analysisSignature: String
    let quality: Double
    let faceSizePx: Double
    let rollDegrees: Double
    let modelId: String
    let modelVersion: String
    let embeddingDim: Int
    let createdAt: String

    init(named row: NamedRow) throws {
        id = try row.decoded(by: "id")
        photoId = try row.decoded(by: "photo_id")
        sessionId = try row.decoded(by: "session_id")
        bboxX = try row.decoded(by: "bbox_x")
        bboxY = try row.decoded(by: "bbox_y")
        bboxW = try row.decoded(by: "bbox_w")
        bboxH = try row.decoded(by: "bbox_h")
        embedding = try row.decoded(by: "embedding")
        confidence = try row.decoded(by: "confidence")
        analysisSignature = try row.decoded(by: "analysis_signature")
        quality = try row.decoded(by: "quality")
        faceSizePx = try row.decoded(by: "face_size_px")
        rollDegrees = try row.decoded(by: "roll_degrees")
        modelId = try row.decoded(by: "model_id")
        modelVersion = try row.decoded(by: "model_version")
        embeddingDim = try row.decoded(by: "embedding_dim")
        createdAt = try row.decoded(by: "created_at")
    }
}

/// S5 的 FaceClusterRow：10 个结果列（9 个物理列 + COUNT 别名，无 thumbnail_base64）。
private struct V1FaceClusterRow: Equatable {
    static let columns = [
        "id", "session_id", "label", "member_count", "status", "thumbnail_path",
        "matched_person_id", "match_confidence", "created_at", "updated_at",
    ]

    let id: Int64
    let sessionId: String
    let label: String
    let memberCount: Int64
    let status: String
    let thumbnailPath: String
    let matchedPersonId: String?
    let matchConfidence: Double?
    let createdAt: String
    let updatedAt: String

    init(named row: NamedRow) throws {
        id = try row.decoded(by: "id")
        sessionId = try row.decoded(by: "session_id")
        label = try row.decoded(by: "label")
        memberCount = try row.decoded(by: "member_count")
        status = try row.decoded(by: "status")
        thumbnailPath = try row.decoded(by: "thumbnail_path")
        matchedPersonId = try row.decodedIfPresent(by: "matched_person_id")
        matchConfidence = try row.decodedIfPresent(by: "match_confidence")
        createdAt = try row.decoded(by: "created_at")
        updatedAt = try row.decoded(by: "updated_at")
    }
}

/// S5 的 SessionRow：10 个物理列 + 派生 analysis_status = 11 个结果列。
private struct V1SessionRow: Equatable {
    static let columns = [
        "id", "name", "status", "analysis_status", "source_path", "truncated_import",
        "reload_acked_at", "index_seq", "photo_count", "created_at", "updated_at",
    ]

    let id: String
    let name: String
    let status: String
    let analysisStatus: String
    let sourcePath: String
    let truncatedImport: Int
    let reloadAckedAt: String?
    let indexSeq: Int
    let photoCount: Int
    let createdAt: String
    let updatedAt: String

    init(named row: NamedRow) throws {
        id = try row.decoded(by: "id")
        name = try row.decoded(by: "name")
        status = try row.decoded(by: "status")
        analysisStatus = try row.decoded(by: "analysis_status")
        sourcePath = try row.decoded(by: "source_path")
        truncatedImport = try row.decoded(by: "truncated_import")
        reloadAckedAt = try row.decodedIfPresent(by: "reload_acked_at")
        indexSeq = try row.decoded(by: "index_seq")
        photoCount = try row.decoded(by: "photo_count")
        createdAt = try row.decoded(by: "created_at")
        updatedAt = try row.decoded(by: "updated_at")
    }
}

// MARK: - fixtures

private func makeRowMappingDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaV1.sql)
    return db
}

private func insertMappingSession(
    _ db: DBConnection,
    id: String = "s1",
    name: String = "Session 1",
    reloadAckedAt: String? = nil
) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (
          id, name, status, source_path, truncated_import, reload_acked_at,
          index_seq, photo_count, created_at, updated_at
        ) VALUES (?, ?, 'review', '/src', 1, ?, 7, 42, ?, ?)
        """).run([
            .text(id), .text(name),
            reloadAckedAt.map { DBValue.text($0) } ?? .null,
            .text(v1Timestamp), .text(v1Timestamp),
        ])
}

private func insertMappingPhotoFixture(_ db: DBConnection) throws {
    try insertMappingSession(db)
    _ = try db.prepare("INSERT INTO assets (id, created_at, updated_at) VALUES ('a1', ?, ?)")
        .run([.text(v1Timestamp), .text(v1Timestamp)])
    _ = try db.prepare("""
        INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at)
        VALUES ('af1', '/v/IMG_1.jpg', 'IMG_1.jpg', ?, ?)
        """).run([.text(v1Timestamp), .text(v1Timestamp)])
    _ = try db.prepare("""
        INSERT INTO photos (
          id, session_id, filepath, filename, checksum, checksum_file_size,
          checksum_file_mtime_ms, status, asset_id, asset_file_id, width, height,
          created_at, updated_at
        ) VALUES ('p1', 's1', '/v/IMG_1.jpg', 'IMG_1.jpg', 'sum-1', 4096,
                  1700000000123.5, 'ready', 'a1', 'af1', 4000, 3000, ?, ?)
        """).run([.text(v1Timestamp), .text(v1Timestamp)])
}

// MARK: - DB 层：NamedRow / queryNamed

struct SchemaV1RowMappingTests {
    @Test func namedRowDecodesShuffledColumnsAndRejectsMissingOrWrongType() throws {
        let db = try makeRowMappingDB()
        defer { db.close() }

        // 结果列序与任何“物理列序”都不同；按名解码必须与位置无关。
        let named = try #require(try db.prepare("""
            SELECT 'text' AS label, 42 AS answer, 2.5 AS ratio,
                   x'0102' AS payload, NULL AS optional
            """).getNamed())

        #expect(named.columns == ["label", "answer", "ratio", "payload", "optional"])
        #expect(named.values.count == named.columns.count)

        let label: String = try named.decoded(by: "label")
        let answer: Int = try named.decoded(by: "answer")
        let ratio: Double = try named.decoded(by: "ratio")
        let payload: Data = try named.decoded(by: "payload")
        let optional: String? = try named.decodedIfPresent(by: "optional")
        #expect(label == "text")
        #expect(answer == 42)
        #expect(ratio == 2.5)
        #expect(payload == Data([0x01, 0x02]))
        #expect(optional == nil)
        #expect(named.contains("answer"))
        #expect(named["missing"] == nil)
        #expect(named.valuesByColumn["answer"] == .int(42))

        // [String: DBValue] 构造：列名按字典序固定，取值仍按名。
        let fromDictionary = NamedRow(["b": .text("two"), "a": .int(1)])
        #expect(fromDictionary.columns == ["a", "b"])
        let dictionaryA: Int = try fromDictionary.decoded(by: "a")
        #expect(dictionaryA == 1)

        // 缺列必须显式失败（不能静默 nil/0）。
        #expect(throws: DBError.self) {
            let _: Int = try named.decoded(by: "missing")
        }
        // 类型错必须显式失败（TEXT 当 INTEGER、INTEGER 当 TEXT）。
        #expect(throws: DBError.self) {
            let _: Int = try named.decoded(by: "label")
        }
        #expect(throws: DBError.self) {
            let _: String = try named.decoded(by: "answer")
        }
        // 可选列的缺列同样不可静默（查询列清单漂移要暴露）。
        #expect(throws: DBError.self) {
            let _: String? = try named.decodedIfPresent(by: "missing_optional")
        }

        // queryNamed 与 getNamed 同语义；重复列名必须显式要求 AS 别名。
        let rows = try db.prepare("SELECT 7 AS id, 'x' AS name").queryNamed()
        #expect(rows.count == 1)
        let id: Int = try rows[0].decoded(by: "id")
        #expect(id == 7)
        #expect(throws: DBError.self) {
            _ = try db.prepare("SELECT 1 AS duplicate, 2 AS duplicate").queryNamed()
        }
    }

    // MARK: photos（14 列）

    @Test func photoRowV1MapsFourteenColumnsByName() throws {
        let db = try makeRowMappingDB()
        defer { db.close() }
        try insertMappingPhotoFixture(db)

        #expect(V1PhotoRow.columns.count == 14,
                "V1 photos 只有 14 列；旧 PhotoRow 的 row.count >= 16 会响亮失败")
        #expect(V1PhotoRow.columns.firstIndex(of: "asset_id") == 8,
                "旧实现 assetId=row[10]；V1 按名解码后与位置无关")
        #expect(V1PhotoRow.columns.firstIndex(of: "width") == 10)
        #expect(V1PhotoRow.columns.firstIndex(of: "created_at") == 12)
        #expect(V1PhotoRow.columns.firstIndex(of: "updated_at") == 13)

        // 逆序列投影：旧位置映射在这里会整体错列；命名映射必须全部正确。
        let shuffled = Array(V1PhotoRow.columns.reversed())
        let raw = try #require(try db.prepare("""
            SELECT \(shuffled.joined(separator: ", ")) FROM photos WHERE id = ?
            """).getNamed([.text("p1")]))
        #expect(raw.columns == shuffled)
        #expect(raw.values.count == 14)

        let row = try V1PhotoRow(named: raw)
        #expect(row.id == "p1")
        #expect(row.sessionId == "s1")
        #expect(row.filepath == "/v/IMG_1.jpg")
        #expect(row.filename == "IMG_1.jpg")
        #expect(row.checksum == "sum-1")
        #expect(row.checksumFileSize == 4096)
        #expect(row.checksumFileMtimeMs == 1_700_000_000_123.5)
        #expect(row.status == "ready")
        #expect(row.assetId == "a1")
        #expect(row.assetFileId == "af1")
        #expect(row.width == 4000)
        #expect(row.height == 3000)
        #expect(row.createdAt == v1Timestamp)
        #expect(row.updatedAt == v1Timestamp)
    }

    // MARK: face_observations（17 列）

    @Test func faceObservationRowV1MapsSeventeenColumnsByName() throws {
        let db = try makeRowMappingDB()
        defer { db.close() }
        try insertMappingPhotoFixture(db)

        let embedding = Data([0x01, 0x02, 0x03, 0x04])
        _ = try db.prepare("""
            INSERT INTO face_observations (
              id, photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding,
              confidence, analysis_signature, quality, face_size_px, roll_degrees,
              model_id, model_version, embedding_dim, created_at
            ) VALUES (7, 'p1', 's1', 0.11, 0.22, 0.33, 0.44, ?, 0.98, 'sig-1',
                      0.87, 120.5, 1.25, 'sface', '1.0', 512, ?)
            """).run([.blob(embedding), .text(v1Timestamp)])

        #expect(V1FaceObservationRow.columns.count == 17,
                "V1 face_observations 只有 17 列；旧 FaceObservationRow 的 row[18] 必然越界")
        #expect(V1FaceObservationRow.columns.firstIndex(of: "analysis_signature") == 9)
        #expect(V1FaceObservationRow.columns.firstIndex(of: "model_version") == 14)
        #expect(V1FaceObservationRow.columns.firstIndex(of: "embedding_dim") == 15)
        #expect(V1FaceObservationRow.columns.firstIndex(of: "created_at") == 16)

        let shuffled = Array(V1FaceObservationRow.columns.reversed())
        let raw = try #require(try db.prepare("""
            SELECT \(shuffled.joined(separator: ", ")) FROM face_observations WHERE id = ?
            """).getNamed([.int(7)]))
        #expect(raw.columns == shuffled)
        #expect(raw.values.count == 17)

        let row = try V1FaceObservationRow(named: raw)
        #expect(row.id == 7)
        #expect(row.photoId == "p1")
        #expect(row.sessionId == "s1")
        #expect(row.bboxX == 0.11)
        #expect(row.bboxY == 0.22)
        #expect(row.bboxW == 0.33)
        #expect(row.bboxH == 0.44)
        #expect(row.embedding == embedding)
        #expect(row.confidence == 0.98)
        #expect(row.analysisSignature == "sig-1")
        #expect(row.quality == 0.87)
        #expect(row.faceSizePx == 120.5)
        #expect(row.rollDegrees == 1.25)
        #expect(row.modelId == "sface")
        #expect(row.modelVersion == "1.0")
        #expect(row.embeddingDim == 512)
        #expect(row.createdAt == v1Timestamp)
    }

    // MARK: face_clusters（9 物理列 + COUNT 别名）

    @Test func faceClusterRowV1MapsByNamesWithoutThumbnailBase64() throws {
        let db = try makeRowMappingDB()
        defer { db.close() }
        try insertMappingPhotoFixture(db)

        _ = try db.prepare("""
            INSERT INTO persons (id, name, created_at, updated_at)
            VALUES ('person-1', 'Alice', ?, ?)
            """).run([.text(v1Timestamp), .text(v1Timestamp)])
        _ = try db.prepare("""
            INSERT INTO face_clusters (
              session_id, label, status, thumbnail_path, matched_person_id,
              match_confidence, created_at, updated_at
            ) VALUES ('s1', 'Alice', 'bound', '/thumbs/c1.jpg', 'person-1', 0.91, ?, ?)
            """).run([.text(v1Timestamp), .text(v1Timestamp)])
        let clusterId = db.lastInsertRowid
        for _ in 0..<2 {
            _ = try db.prepare("""
                INSERT INTO face_cluster_members (
                  cluster_id, session_id, photo_id, bbox, confidence
                ) VALUES (?, 's1', 'p1', '{}', 0.9)
                """).run([.int(clusterId)])
        }

        #expect(V1FaceClusterRow.columns.count == 10)
        #expect(!V1FaceClusterRow.columns.contains("thumbnail_base64"),
                "V1 删掉 thumbnail_base64；S5 的 SELECT 不能再读该列")
        #expect(V1FaceClusterRow.columns.firstIndex(of: "thumbnail_path") == 5,
                "旧 mapper 的 thumbnailPath=row[6] 会把 matched_person_id 当缩略图")
        #expect(V1FaceClusterRow.columns.firstIndex(of: "matched_person_id") == 6)
        #expect(V1FaceClusterRow.columns.firstIndex(of: "match_confidence") == 7)

        let shuffled = Array(V1FaceClusterRow.columns.reversed())
        let selectList = shuffled.map { column in
            column == "member_count" ? "COUNT(fcm.id) AS member_count" : "fc." + column
        }.joined(separator: ", ")
        let raw = try #require(try db.prepare("""
            SELECT \(selectList)
            FROM face_clusters fc
            LEFT JOIN face_cluster_members fcm ON fcm.cluster_id = fc.id
            WHERE fc.id = ?
            GROUP BY fc.id
            """).getNamed([.int(clusterId)]))
        #expect(raw.columns == shuffled)
        #expect(raw.values.count == 10)

        let row = try V1FaceClusterRow(named: raw)
        #expect(row.id == clusterId)
        #expect(row.sessionId == "s1")
        #expect(row.label == "Alice")
        #expect(row.memberCount == 2)
        #expect(row.status == "bound")
        #expect(row.thumbnailPath == "/thumbs/c1.jpg")
        #expect(row.matchedPersonId == "person-1")
        #expect(row.matchConfidence == 0.91)
        #expect(row.createdAt == v1Timestamp)
        #expect(row.updatedAt == v1Timestamp)
    }

    // MARK: sessions（10 物理列 + 派生 analysis_status）

    @Test func sessionRowV1MapsElevenColumnsByName() throws {
        let db = try makeRowMappingDB()
        defer { db.close() }
        try insertMappingSession(db, reloadAckedAt: "2026-01-02T00:00:00.000Z")
        _ = try db.prepare("""
            INSERT INTO analysis_jobs (
              id, type, scope_type, scope_id, dedupe_key, status, created_at, updated_at
            ) VALUES ('job-1', 'face.analyze', 'session', 's1', 'dedupe-1', 'running', ?, ?)
            """).run([.text(v1Timestamp), .text(v1Timestamp)])

        #expect(V1SessionRow.columns.count == 11,
                "V1 sessions 是 10 物理列 + 派生 analysis_status；旧 SessionRow 的 row[11] 会越界")
        #expect(V1SessionRow.columns.firstIndex(of: "analysis_status") == 3)
        #expect(V1SessionRow.columns.firstIndex(of: "source_path") == 4,
                "旧实现 sourcePath=row[6]；V1 的 6 是 reload_acked_at")
        #expect(V1SessionRow.columns.firstIndex(of: "created_at") == 9)
        #expect(V1SessionRow.columns.firstIndex(of: "updated_at") == 10)

        let analysisStatusSQL = """
            CASE
              WHEN EXISTS (
                SELECT 1 FROM analysis_jobs j
                WHERE j.scope_id = sessions.id
                  AND j.type IN ('similarity.analyze', 'face.analyze')
                  AND j.status IN ('queued', 'running', 'cancelling', 'interrupted')
              ) THEN 'running'
              ELSE 'idle'
            END AS analysis_status
            """
        let shuffled = Array(V1SessionRow.columns.reversed())
        let selectList = shuffled.map { column in
            column == "analysis_status" ? analysisStatusSQL : column
        }.joined(separator: ", ")
        let raw = try #require(try db.prepare("""
            SELECT \(selectList) FROM sessions WHERE id = ?
            """).getNamed([.text("s1")]))
        #expect(raw.columns == shuffled)
        #expect(raw.values.count == 11)

        let row = try V1SessionRow(named: raw)
        #expect(row.id == "s1")
        #expect(row.name == "Session 1")
        #expect(row.status == "review")
        #expect(row.analysisStatus == "running")
        #expect(row.sourcePath == "/src")
        #expect(row.truncatedImport == 1)
        #expect(row.reloadAckedAt == "2026-01-02T00:00:00.000Z")
        #expect(row.indexSeq == 7)
        #expect(row.photoCount == 42)
        #expect(row.createdAt == v1Timestamp)
        #expect(row.updatedAt == v1Timestamp)
    }

    // MARK: - 生产写路径冒烟（S5b / R1-06）

    /// 写侧删除 metadata/result、source_file_size/mtime、member_count/thumbnail_base64
    /// 后，PhotoRepo/FaceRepo 的 INSERT/UPDATE 必须能在 V1 库上 prepare 并跑通。
    @Test func productionWritesRunAgainstSchemaV1WithoutRemovedColumns() throws {
        let db = try makeRowMappingDB()
        defer { db.close() }

        _ = try db.prepare("""
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'Writes', ?, ?)
            """).run([.text(v1Timestamp), .text(v1Timestamp)])

        let photoRepo = PhotoRepo(connection: db)
        let added = try photoRepo.addPhotos(sessionId: "s1", filepaths: [
            PhotoAddInput(filepath: "/v/p1.jpg", width: 4000, height: 3000),
            PhotoAddInput(filepath: "/v/p2.jpg", width: 120, height: 80),
        ], "test")
        #expect(added.added == 2)
        let p1 = added.ids[0]
        let p2 = added.ids[1]

        let faceRepo = FaceRepo(connection: db)
        let observationIds = try faceRepo.replaceObservationsByPhoto(
            sessionId: "s1",
            photoId: p1,
            observations: [FaceObservationInput(
                photoId: p1, bboxX: 0, bboxY: 0, bboxW: 100, bboxH: 100,
                embedding: [0.5, -0.25, 1.0], confidence: 0.9,
                sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5,
                analysisSignature: "sig-1"
            )]
        )
        #expect(observationIds.count == 1)

        // 复用拷贝曾从观察行读/写 source_file_size/mtime，V1 只认 face_analysis_state。
        _ = try db.prepare("""
            INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at)
            VALUES ('af1', '/v/p1.jpg', 'p1.jpg', ?, ?)
            """).run([.text(v1Timestamp), .text(v1Timestamp)])
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'af1' WHERE id IN (?, ?)")
            .run([.text(p1), .text(p2)])
        try faceRepo.upsertAnalysisState(
            sessionId: "s1", photoId: p1,
            sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5,
            analysisSignature: "sig-1"
        )
        let reused = try faceRepo.reuseObservationsForAssetFile(
            sessionId: "s1", photoId: p2,
            sourceFileSize: 1234, sourceFileMtimeMs: 1_700_000_000_123.5,
            analysisSignature: "sig-1"
        )
        #expect(reused == ReuseResult(reused: true, faceCount: 1))

        // saveClusters 曾写 member_count/thumbnail_base64；V1 两列都不存在。
        let clusterIds = try faceRepo.saveClusters(sessionId: "s1", clusters: [
            FaceClusterInput(label: "A", members: [
                FaceClusterMemberInput(
                    photoId: p1, photoPath: "/v/p1.jpg", bbox: [0, 0, 100, 100],
                    confidence: 0.9, observationId: observationIds[0]
                ),
            ]),
        ])
        let cluster = try #require(try faceRepo.getClusters("s1").first)
        #expect(cluster.memberCount == 1)

        // 派生失效曾重算 member_count；V1 只删派生行，不再写计数缓存。
        try faceRepo.invalidateDerivedResults(sessionId: "s1", photoIds: [p1])
        #expect(try faceRepo.getClusters("s1").first?.memberCount == 1)

        // 移除成员曾 UPDATE member_count；无绑定时簇行删除。
        let memberId = try #require(
            try faceRepo.getClusters("s1", includeMembers: true).first?.members?.first?.id
        )
        #expect(try faceRepo.removeMemberFromCluster(clusterId: clusterIds[0], memberId: memberId))
        #expect(try faceRepo.getClusters("s1").isEmpty)
    }
}
