// Tests/GatherCoreTests/Store/CullingQueryStoreTests.swift
// W2b Store 读模型测试：CullingQueryStore（分页/计数唯一 SQL 所有者）覆盖设计
// §5.3 的 8 个用例语义；另覆盖 5 个新增 Store 方法（4 个批量读 + 1 个 CAS 写入）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/CullingQueryStore (W2b)")
struct CullingQueryStoreTests {
    // MARK: - Fixtures

    private func makeHarness() async throws -> (db: SQLiteDatabase, store: SQLiteCullingQueryStore, sessionId: String) {
        let database = try await makeMigratedStore(path: storeTempPath("culling-query"))
        try await insertSession(database, "s1")
        return (database, SQLiteCullingQueryStore(database: database), "s1")
    }

    /// photos 行插入（可带资产配对；rowid 由调用顺序决定）。
    @discardableResult
    private func insertQueryPhoto(
        _ db: SQLiteDatabase,
        id: String,
        filename: String,
        sessionId: String = "s1",
        assetId: String? = nil,
        assetFileId: String? = nil
    ) async throws -> Int64 {
        try await db.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
              result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?, 100, 100,
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [
                .text(id), .text(sessionId), .text("/shoot/\(filename)"), .text(filename),
                assetId.map { .text($0) } ?? .null,
                assetFileId.map { .text($0) } ?? .null,
            ]
        )
        return try await db.scalarInt("SELECT rowid FROM photos WHERE id = ?", [.text(id)]) ?? 0
    }

    /// RAW/JPEG 变体对：JPEG 先插（rowid 小），RAW 后插（首选行由扩展名优先级决定）。
    private func insertVariantPair(_ db: SQLiteDatabase, assetId: String, sessionId: String = "s1") async throws {
        try await insertAsset(db, id: assetId)
        try await insertAssetFile(db, id: "\(assetId)-jpg", normalizedPath: "/shoot/\(assetId).jpg")
        try await insertAssetFile(db, id: "\(assetId)-raw", normalizedPath: "/shoot/\(assetId).NEF")
        try await insertQueryPhoto(
            db, id: "\(assetId)-jpg", filename: "\(assetId).jpg",
            sessionId: sessionId, assetId: assetId, assetFileId: "\(assetId)-jpg"
        )
        try await insertQueryPhoto(
            db, id: "\(assetId)-raw", filename: "\(assetId).NEF",
            sessionId: sessionId, assetId: assetId, assetFileId: "\(assetId)-raw"
        )
    }

    private func insertDecision(
        _ db: SQLiteDatabase,
        photoId: String,
        sessionId: String = "s1",
        decision: String = "pending",
        rating: Int64 = 0,
        colorLabel: String = "None",
        revision: Int64 = 0
    ) async throws {
        try await db.run(
            """
            INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating,
              color_label, decision_source, revision, created_at, updated_at)
            VALUES (?, ?, 'ungrouped', ?, ?, ?, 'manual', ?,
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [
                .text(sessionId), .text(photoId), .text(decision), .int(rating),
                .text(colorLabel), .int(revision),
            ]
        )
    }

    /// 逐页走完 scope 的组（limit 2），断言无跨页重复组；返回组 id 序列。
    private func walkGroups(
        _ store: any CullingQueryStore,
        scope: CullingQueryScope,
        sessionId: String = "s1"
    ) async throws -> [String] {
        var walked: [String] = []
        var cursor: Int64?
        var seen = Set<String>()
        for _ in 0..<50 {
            let page = try await store.assetGroupPage(
                CullingPageQuery(sessionId: sessionId, scope: scope, afterRowId: cursor, limit: 2)
            )
            for group in page.groups {
                #expect(seen.insert(group.groupId).inserted, "组 \(group.groupId) 跨页重复")
                walked.append(group.groupId)
            }
            guard let next = page.cursor else { break }
            cursor = next
        }
        return walked
    }

    // MARK: - 过滤规格映射（与 CullingAssembler.specs(from:) 的共享契约）

    @Test("CullingFilterSpec(filters:)：CullingFilters 各维度与质量三态映射")
    func filterSpecFromFilters() {
        let spec = CullingFilterSpec(filters: CullingFilters(
            ratings: [3, 5],
            pickStates: [.picked],
            colorLabels: [.red],
            unreviewedOnly: true,
            qualityStatus: .unanalysed,
            metadataConflictOnly: true
        ))
        #expect(spec.unreviewed)
        #expect(spec.pickStates == [.picked])
        #expect(spec.ratings == [3, 5])
        #expect(spec.colorLabels == [.red])
        #expect(spec.quality == .absent, "unanalysed → absent（json_valid 守卫）")

        let empty = CullingFilterSpec(filters: CullingFilters())
        #expect(!empty.unreviewed)
        #expect(empty.pickStates.isEmpty)
        #expect(empty.ratings.isEmpty)
        #expect(empty.colorLabels.isEmpty)
        #expect(empty.quality == nil)
    }

    // MARK: - §5.3 用例 1：变体不跨页

    @Test("变体不跨页：limit=1 逐页走完，每页含整组行且 cursor 来自组查询")
    func variantsNeverSplitAcrossPages() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertVariantPair(db, assetId: "asset-1") // rowid 1 = jpg, rowid 2 = raw
        try await insertQueryPhoto(db, id: "single1", filename: "B001.jpg") // rowid 3
        try await insertQueryPhoto(db, id: "single2", filename: "C001.jpg") // rowid 4

        let first = try await store.assetGroupPage(
            CullingPageQuery(sessionId: "s1", scope: .all, limit: 1)
        )
        #expect(first.groups.map(\.groupId) == ["asset-1"])
        #expect(first.rows.map(\.id) == ["asset-1-jpg", "asset-1-raw"], "整组变体同页")
        #expect(first.cursor == 1, "cursor = 组首 rowid（JPEG 先插入）")

        let second = try await store.assetGroupPage(
            CullingPageQuery(sessionId: "s1", scope: .all, afterRowId: first.cursor, limit: 1)
        )
        #expect(second.groups.map(\.groupId) == ["single1"])
        #expect(second.rows.map(\.id) == ["single1"])
        #expect(second.cursor == 3)

        let third = try await store.assetGroupPage(
            CullingPageQuery(sessionId: "s1", scope: .all, afterRowId: second.cursor, limit: 1)
        )
        #expect(third.groups.map(\.groupId) == ["single2"])
        #expect(third.cursor == 4)

        let fourth = try await store.assetGroupPage(
            CullingPageQuery(sessionId: "s1", scope: .all, afterRowId: third.cursor, limit: 1)
        )
        #expect(fourth.rows.isEmpty)
        #expect(fourth.cursor == nil, "空页无 cursor（不产生死循环游标）")

        #expect(try await walkGroups(store, scope: .all) == ["asset-1", "single1", "single2"])
        #expect(try await store.countAssetGroups(CullingPageQuery(sessionId: "s1", scope: .all)) == 3)
    }

    // MARK: - §5.3 用例 2：RAW 命中时整资产进页

    @Test("filtered：首选 RAW 命中时整资产（含 JPEG 变体）进页")
    func filteredRawMatchKeepsWholeAsset() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertVariantPair(db, assetId: "asset-1")
        try await insertDecision(db, photoId: "asset-1-raw", decision: "keep")

        let query = CullingPageQuery(
            sessionId: "s1",
            scope: .filtered([CullingFilterSpec(pickStates: [.picked])])
        )
        let page = try await store.assetGroupPage(query)
        #expect(page.groups.map(\.groupId) == ["asset-1"])
        #expect(page.rows.map(\.id) == ["asset-1-jpg", "asset-1-raw"], "JPEG 变体随组进页")
        #expect(
            page.cursor == 2,
            "cursor 取组查询的 first_rowid（首选 RAW 的 MIN(rowid)=2），不从已加载行的最小 rowid 1 重新推导"
        )
        #expect(try await store.countAssetGroups(query) == 1)
    }

    // MARK: - §5.3 用例 3：仅 JPEG 命中时排除资产

    @Test("filtered：仅 JPEG 变体命中时资产被排除（判定只看首选行）")
    func filteredJpegOnlyMatchExcludesAsset() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertVariantPair(db, assetId: "asset-1") // jpg rowid 1, raw rowid 2（首选）
        try await insertQueryPhoto(db, id: "single", filename: "B001.jpg") // rowid 3
        try await insertDecision(db, photoId: "asset-1-jpg", decision: "keep")
        try await insertDecision(db, photoId: "single", decision: "keep")

        let query = CullingPageQuery(
            sessionId: "s1",
            scope: .filtered([CullingFilterSpec(pickStates: [.picked])])
        )
        let page = try await store.assetGroupPage(query)
        #expect(page.groups.map(\.groupId) == ["single"], "JPEG 命中不构成资产命中")
        #expect(page.rows.map(\.id) == ["single"], "被排除的资产一行都不返回")
        #expect(page.cursor == 3)
        #expect(try await store.countAssetGroups(query) == 1)
    }

    // MARK: - §5.3 用例 4：similarity 分组下推

    @Test("similarityGroup：谓词下推只取该组成员，变体随资产组整组进页")
    func similarityGroupPushdown() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertQueryPhoto(db, id: "p1", filename: "p1.jpg")
        try await insertQueryPhoto(db, id: "p2", filename: "p2.jpg")
        try await insertVariantPair(db, assetId: "asset-1")
        let similarityStore = SQLiteSimilarityStore(database: db)
        let resultId = try await similarityStore.replaceResult(
            sessionId: "s1",
            groupsJson: #"{"groups":[]}"#,
            statsJson: #"{"totalGroups":1}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "p1", groupIndex: 0),
                SimilarityMembership(photoId: "p2", groupIndex: 0),
                SimilarityMembership(photoId: "asset-1-raw", groupIndex: 0),
            ]
        )
        let scope = CullingQueryScope.similarityGroup(resultId: Int(resultId), groupIndex: 0)
        #expect(CullingQueryScope.similarityGroup(groupId: "\(resultId):0") == scope, "组 id 可解析")

        let query = CullingPageQuery(sessionId: "s1", scope: scope)
        let page = try await store.assetGroupPage(query)
        #expect(page.groups.map(\.groupId) == ["p1", "p2", "asset-1"])
        #expect(
            page.rows.map(\.id) == ["p1", "p2", "asset-1-jpg", "asset-1-raw"],
            "非成员变体随所在资产组整组进页"
        )
        #expect(try await store.countAssetGroups(query) == 3)
    }

    // MARK: - §5.3 用例 5：不可解析组回退

    @Test("不可解析相似度组 id：解析为 nil（无 SQL 谓词，调用方回退 JS 映射）")
    func unparseableSimilarityGroupFallsBack() async throws {
        #expect(CullingQueryScope.similarityGroup(groupId: "stale-group-id") == nil)
        #expect(CullingQueryScope.similarityGroup(groupId: "") == nil)
        #expect(CullingQueryScope.similarityGroup(groupId: "12") == nil, "缺冒号")
        #expect(CullingQueryScope.similarityGroup(groupId: "12:") == nil, "groupIndex 非整数")
        #expect(CullingQueryScope.similarityGroup(groupId: ":3") == nil, "resultId 非整数")
        #expect(CullingQueryScope.similarityGroup(groupId: "1:2:3") == nil, "取最后冒号后 resultId 非整数")
        #expect(
            CullingQueryScope.similarityGroup(groupId: "12:3") == .similarityGroup(resultId: 12, groupIndex: 3)
        )
        #expect(CullingQueryScope.similarityGroup(groupId: "12:3")?.groupId == "12:3")
        #expect(CullingQueryScope.all.groupId == nil)
    }

    // MARK: - §5.3 用例 6：排除 precomputed

    @Test("similarityLatest：预计算阈值层被 stats_json 谓词排除")
    func similarityLatestExcludesPrecomputedTiers() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertQueryPhoto(db, id: "p1", filename: "p1.jpg")
        try await insertQueryPhoto(db, id: "p2", filename: "p2.jpg")
        let similarityStore = SQLiteSimilarityStore(database: db)
        _ = try await similarityStore.replaceResult(
            sessionId: "s1",
            groupsJson: #"{"groups":[]}"#,
            statsJson: #"{"totalGroups":1}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "p1", groupIndex: 0),
                SimilarityMembership(photoId: "p2", groupIndex: 0),
            ]
        )
        // 阈值层后插：裸 MAX(id) 会选中它；latest 谓词必须回退到主分析行成员。
        _ = try await similarityStore.replaceResultForThreshold(
            sessionId: "s1",
            groupsJson: #"{"groups":[]}"#,
            statsJson: #"{"totalGroups":1,"precomputed":true}"#,
            threshold: 6,
            minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p2", groupIndex: 0)]
        )

        let query = CullingPageQuery(sessionId: "s1", scope: .similarityLatest)
        let page = try await store.assetGroupPage(query)
        #expect(page.rows.map(\.id) == ["p1", "p2"], "只认主分析行成员")
        #expect(try await store.countAssetGroups(query) == 2)
    }

    // MARK: - §5.3 用例 7：质量 JSON 守卫

    @Test("quality：损坏 result_json 被 json_valid 守卫跳过，不与缺失/失败混淆")
    func qualityFilterToleratesCorruptJSON() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertAssetFile(db, id: "af-bad", normalizedPath: "/shoot/bad.jpg")
        try await insertAssetFile(db, id: "af-good", normalizedPath: "/shoot/good.jpg")
        try await insertAssetFile(db, id: "af-mixed", normalizedPath: "/shoot/mixed.jpg")
        for id in ["bad", "good", "mixed"] {
            try await insertQueryPhoto(db, id: id, filename: "\(id).jpg", assetFileId: "af-\(id)")
        }
        func analysis(
            _ photoId: String,
            _ fingerprint: String,
            _ resultJSON: String,
            _ updatedAt: String
        ) async throws {
            try await db.run(
                """
                INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
                  input_fingerprint, created_at, updated_at)
                VALUES (?, ?, 'technical_quality', ?, ?, '2026-01-01T00:00:00.000Z', ?)
                """,
                [
                    .text(photoId), .text("af-\(photoId)"), .text(resultJSON),
                    .text(fingerprint), .text(updatedAt),
                ]
            )
        }
        try await analysis("bad", "f-bad", "not json", "2026-01-03T00:00:00.000Z")
        try await analysis("mixed", "f-mixed-new", "not json", "2026-01-03T00:00:00.000Z")
        try await analysis(
            "mixed", "f-mixed-old", #"{"status":"succeeded","qualityScore":0.8}"#,
            "2026-01-01T00:00:00.000Z"
        )
        try await analysis(
            "good", "f-good", #"{"status":"succeeded","qualityScore":0.9}"#,
            "2026-01-01T00:00:00.000Z"
        )

        func query(_ quality: CullingQualityPredicate) -> CullingPageQuery {
            CullingPageQuery(sessionId: "s1", scope: .filtered([CullingFilterSpec(quality: quality)]))
        }

        let succeeded = try await store.assetGroupPage(query(.succeeded))
        #expect(Set(succeeded.rows.map(\.id)) == ["good", "mixed"], "损坏最新行被跳过，回退到合法旧行")
        #expect(try await store.countAssetGroups(query(.succeeded)) == 2)

        let failed = try await store.assetGroupPage(query(.failed))
        #expect(failed.rows.isEmpty, "损坏行不算 failed，查询不抛错")
        #expect(try await store.countAssetGroups(query(.failed)) == 0)

        let absent = try await store.assetGroupPage(query(.absent))
        #expect(absent.rows.map(\.id) == ["bad"], "只有损坏行的照片视为未分析")
        #expect(try await store.countAssetGroups(query(.absent)) == 1)
    }

    // MARK: - §5.3 用例 8：count 与 page 一致

    @Test("count 与 page 同源：四种 scope 逐页走完的组数与 countAssetGroups 一致")
    func countMatchesPageAcrossScopes() async throws {
        let (db, store, _) = try await makeHarness()
        try await insertVariantPair(db, assetId: "asset-1") // rowid 1/2
        try await insertQueryPhoto(db, id: "b", filename: "B.jpg") // rowid 3
        try await insertQueryPhoto(db, id: "c", filename: "C.jpg") // rowid 4
        try await insertQueryPhoto(db, id: "d", filename: "D.jpg") // rowid 5
        try await insertDecision(db, photoId: "asset-1-raw", decision: "keep", rating: 5)
        try await insertDecision(db, photoId: "b", decision: "keep", rating: 3)
        try await insertDecision(db, photoId: "c", decision: "reject", rating: 0)

        let similarityStore = SQLiteSimilarityStore(database: db)
        let resultId = try await similarityStore.replaceResult(
            sessionId: "s1",
            groupsJson: #"{"groups":[]}"#,
            statsJson: #"{"totalGroups":1}"#,
            threshold: 10,
            minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "b", groupIndex: 0),
                SimilarityMembership(photoId: "d", groupIndex: 0),
            ]
        )

        let cases: [(String, CullingQueryScope, [String])] = [
            ("all", .all, ["asset-1", "b", "c", "d"]),
            ("filtered pickStates", .filtered([CullingFilterSpec(pickStates: [.picked])]), ["asset-1", "b"]),
            ("filtered ratings", .filtered([CullingFilterSpec(ratings: [5])]), ["asset-1"]),
            ("filtered unreviewed", .filtered([CullingFilterSpec(unreviewed: true)]), ["d"]),
            ("similarityGroup", .similarityGroup(resultId: Int(resultId), groupIndex: 0), ["b", "d"]),
            ("similarityLatest", .similarityLatest, ["b", "d"]),
        ]
        for (label, scope, expected) in cases {
            let walked = try await walkGroups(store, scope: scope)
            #expect(walked == expected, "\(label) 组序列")
            let count = try await store.countAssetGroups(CullingPageQuery(sessionId: "s1", scope: scope))
            #expect(count == walked.count, "\(label) count 与 page 一致")
        }
    }

    // MARK: - 新增 Store 方法

    @Test("FaceStore.observationsLite：轻投影按 id 序返回 bbox 与签名，空参数返回 []")
    func faceObservationsLite() async throws {
        let (db, _, _) = try await makeHarness()
        let faceStore = SQLiteFaceStore(database: db)
        try await insertQueryPhoto(db, id: "p1", filename: "p1.jpg")
        try await insertQueryPhoto(db, id: "p2", filename: "p2.jpg")
        try await insertSession(db, "s2")
        try await insertQueryPhoto(db, id: "p3", filename: "p3.jpg", sessionId: "s2")

        func observation(
            _ photoId: String,
            _ sessionId: String,
            _ x: Double,
            _ signature: String
        ) async throws {
            try await db.run(
                """
                INSERT INTO face_observations (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
                  embedding, confidence, analysis_signature)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0.9, ?)
                """,
                [
                    .text(photoId), .text(sessionId), .real(x), .real(0), .real(1), .real(1),
                    .blob(Data([0, 0, 0, 0])), .text(signature),
                ]
            )
        }
        try await observation("p1", "s1", 0.1, #"{"previewMaxDimension":2048}"#)
        try await observation("p1", "s1", 0.2, "")
        try await observation("p2", "s1", 0.3, "")
        try await observation("p3", "s2", 0.4, "")

        #expect(try await faceStore.observationsLite(sessionId: "s1", photoIds: []).isEmpty)
        let rows = try await faceStore.observationsLite(sessionId: "s1", photoIds: ["p1", "p2", "p3"])
        #expect(rows.map(\.photoId) == ["p1", "p1", "p2"], "按 id 序且不外泄其他会话")
        #expect(rows[0].bbox == [0.1, 0, 1, 1])
        #expect(rows[1].bbox == [0.2, 0, 1, 1])
        #expect(rows[0].analysisSignature == #"{"previewMaxDimension":2048}"#)

        let subset = try await faceStore.observationsLite(sessionId: "s1", photoIds: ["p2"])
        #expect(subset.map(\.photoId) == ["p2"])
    }

    @Test("PersonStore.personNamesByPhoto：按名排序返回照片-姓名行，空参数返回 []")
    func personNamesByPhoto() async throws {
        let (db, _, _) = try await makeHarness()
        let personStore = SQLitePersonStore(database: db)
        try await insertQueryPhoto(db, id: "p1", filename: "p1.jpg")
        try await insertQueryPhoto(db, id: "p2", filename: "p2.jpg")
        for (id, name) in [("person-a", "Alice"), ("person-b", "Bob")] {
            try await db.run(
                "INSERT INTO persons (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
                [
                    .text(id), .text(name),
                    .text("2026-01-01T00:00:00.000Z"), .text("2026-01-01T00:00:00.000Z"),
                ]
            )
        }
        func link(_ personId: String, _ photoId: String) async throws {
            try await db.run(
                """
                INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
                VALUES (?, ?, 's1', '[]', 0.9, '2026-01-01T00:00:00.000Z')
                """,
                [.text(personId), .text(photoId)]
            )
        }
        try await link("person-b", "p1")
        try await link("person-a", "p1")
        try await link("person-a", "p2")

        #expect(try await personStore.personNamesByPhoto(sessionId: "s1", photoIds: []).isEmpty)
        let rows = try await personStore.personNamesByPhoto(sessionId: "s1", photoIds: ["p1", "p2"])
        #expect(Set(rows.map { "\($0.photoId):\($0.name)" }) == ["p1:Alice", "p1:Bob", "p2:Alice"])
        #expect(rows.map(\.name) == rows.map(\.name).sorted(), "ORDER BY p.name")
    }

    @Test("JobStore.technicalQualityRows：按 updated_at DESC 返回质量行，空参数返回 []")
    func technicalQualityRows() async throws {
        let (db, _, _) = try await makeHarness()
        let jobStore = SQLiteJobStore(database: db)
        try await insertAssetFile(db, id: "af-1", normalizedPath: "/shoot/q1.jpg")
        try await insertAssetFile(db, id: "af-2", normalizedPath: "/shoot/q2.jpg")
        try await insertQueryPhoto(db, id: "q1", filename: "q1.jpg", assetFileId: "af-1")
        try await insertQueryPhoto(db, id: "q2", filename: "q2.jpg", assetFileId: "af-2")
        func analysis(
            _ photoId: String,
            _ fileId: String,
            _ fingerprint: String,
            _ json: String,
            _ updatedAt: String
        ) async throws {
            try await db.run(
                """
                INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
                  input_fingerprint, created_at, updated_at)
                VALUES (?, ?, 'technical_quality', ?, ?, '2026-01-01T00:00:00.000Z', ?)
                """,
                [.text(photoId), .text(fileId), .text(json), .text(fingerprint), .text(updatedAt)]
            )
        }
        try await analysis("q1", "af-1", "old", #"{"status":"failed"}"#, "2026-01-01T00:00:00.000Z")
        try await analysis("q1", "af-1", "new", #"{"status":"succeeded"}"#, "2026-01-03T00:00:00.000Z")
        try await analysis("q2", "af-2", "only", #"{"status":"succeeded"}"#, "2026-01-02T00:00:00.000Z")
        try await db.run(
            """
            INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
              input_fingerprint, created_at, updated_at)
            VALUES ('q2', 'af-2', 'face_detection', '{}', 'f',
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )

        #expect(try await jobStore.technicalQualityRows(photoIds: []).isEmpty)
        let rows = try await jobStore.technicalQualityRows(photoIds: ["q1", "q2"])
        #expect(rows.count == 3)
        #expect(rows[0].requestedPhotoId == "q1")
        #expect(rows[0].resultJSON == #"{"status":"succeeded"}"#, "新行在前")
        #expect(rows.filter { $0.requestedPhotoId == "q2" }.count == 1, "非技术质量类型不进入结果")
    }

    @Test("MetadataStore.ratingLabels：批量 rating/label 轻投影，空参数返回 []")
    func ratingLabels() async throws {
        let (db, _, _) = try await makeHarness()
        let metadataStore = SQLiteMetadataStore(database: db)
        try await insertQueryPhoto(db, id: "p1", filename: "p1.jpg")
        try await insertQueryPhoto(db, id: "p2", filename: "p2.jpg")
        try await metadataStore.updateRating(photoId: "p1", rating: 4)
        try await metadataStore.updateLabel(photoId: "p2", label: "Red")

        #expect(try await metadataStore.ratingLabels(photoIds: []).isEmpty)
        let rows = try await metadataStore.ratingLabels(photoIds: ["p1", "p2", "missing"])
        #expect(rows.count == 2)
        let byPhoto = Dictionary(uniqueKeysWithValues: rows.map { ($0.photoId, $0) })
        #expect(byPhoto["p1"]?.rating == 4)
        #expect(byPhoto["p2"]?.label == "Red")
    }

    @Test("CullingStore.applyDecisionStates：单事务 CAS，冲突整批回滚并返回 false")
    func applyDecisionStatesCAS() async throws {
        let (db, _, _) = try await makeHarness()
        let cullingStore = SQLiteCullingStore(database: db)
        try await insertQueryPhoto(db, id: "p1", filename: "p1.jpg")
        try await insertQueryPhoto(db, id: "p2", filename: "p2.jpg")
        try await insertDecision(db, photoId: "p1", decision: "pending", revision: 2)
        try await insertDecision(db, photoId: "p2", decision: "pending", revision: 7)

        func write(_ photoId: String, decision: String, revision: Int64) -> CullingDecisionWrite {
            CullingDecisionWrite(
                sessionId: "s1",
                photoId: photoId,
                groupId: "group-1",
                state: CullingDecisionState(
                    decision: decision, rating: 5, colorLabel: "Red", revision: revision
                )
            )
        }

        // 成功：revision 2 → 3。
        #expect(try await cullingStore.applyDecisionStates(
            sessionId: "s1", writes: [write("p1", decision: "keep", revision: 3)], expectedRevision: 2
        ) == true)
        var row = try await db.queryOne("SELECT * FROM culling_decisions WHERE photo_id = 'p1'")
        #expect(row?.text("decision") == "keep")
        #expect(row?.int("rating") == 5)
        #expect(row?.text("color_label") == "Red")
        #expect(row?.int("revision") == 3)

        // 过期 revision：返回 false 且行不变。
        #expect(try await cullingStore.applyDecisionStates(
            sessionId: "s1", writes: [write("p1", decision: "reject", revision: 4)], expectedRevision: 2
        ) == false)
        row = try await db.queryOne("SELECT * FROM culling_decisions WHERE photo_id = 'p1'")
        #expect(row?.text("decision") == "keep")
        #expect(row?.int("revision") == 3)

        // 批量中途冲突：p1 命中、p2 revision 不匹配 → 整批回滚（p1 也不落库）。
        #expect(try await cullingStore.applyDecisionStates(
            sessionId: "s1",
            writes: [write("p1", decision: "reject", revision: 4), write("p2", decision: "keep", revision: 8)],
            expectedRevision: 3
        ) == false)
        row = try await db.queryOne("SELECT * FROM culling_decisions WHERE photo_id = 'p1'")
        #expect(row?.text("decision") == "keep" && row?.int("revision") == 3, "中途冲突整批回滚")
        #expect(try await db.queryOne("SELECT * FROM culling_decisions WHERE photo_id = 'p2'")?.int("revision") == 7)

        // 首次决策（无行，expectedRevision 0）允许 INSERT。
        try await insertQueryPhoto(db, id: "p3", filename: "p3.jpg")
        #expect(try await cullingStore.applyDecisionStates(
            sessionId: "s1", writes: [write("p3", decision: "keep", revision: 1)], expectedRevision: 0
        ) == true)
        #expect(try await db.queryOne("SELECT * FROM culling_decisions WHERE photo_id = 'p3'")?.int("revision") == 1)

        // 空写入 → true；跨会话写入 → false 且不落库。
        #expect(try await cullingStore.applyDecisionStates(sessionId: "s1", writes: [], expectedRevision: 5) == true)
        let foreign = CullingDecisionWrite(
            sessionId: "s2",
            photoId: "p3",
            groupId: "group-1",
            state: CullingDecisionState(decision: "reject", rating: 0, colorLabel: "None", revision: 2)
        )
        #expect(try await cullingStore.applyDecisionStates(
            sessionId: "s1", writes: [foreign], expectedRevision: 1
        ) == false)
        #expect(try await db.queryOne("SELECT * FROM culling_decisions WHERE photo_id = 'p3'")?.text("decision") == "keep")
    }
}
