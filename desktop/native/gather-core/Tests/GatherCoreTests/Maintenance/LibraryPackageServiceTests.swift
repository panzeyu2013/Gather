// desktop/native/gather-core/Tests/GatherCoreTests/Maintenance/LibraryPackageServiceTests.swift
// Wave3（task-24）：目录包导出/导入与外部 XMP 迁移的行为测试。
//
// 覆盖：
// 1. 包 JSON 编解码往返（格式稳定）；
// 2. 导出 → 导入：相对路径按 newRoot 重绑定、评分/关键词/集合成员保留；
// 3. 冲突策略 keepLocal / keepImported / coexist 的计数与落库差异；
// 4. 外部 sidecar 迁移的两阶段评估（只补空字段；overwrite 才覆盖；计数口径）。
//
// 夹具：makeTestDB()（内存库 + 当前 schema）+ GatherTestSupport 的临时目录/文件。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

// MARK: - XMP 端口替身

private struct StubXMPProvider: XMPProvider {
    var attributes: MetadataWriteAttributes

    func readKeywords(photoPath: String) async throws -> [String] {
        attributes.keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        attributes
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    func fileExists(_ path: String) -> Bool { true }

    func removeFile(_ path: String) async throws {}
}

// MARK: - 套件

@Suite("Wave3 目录包与外部迁移（task-24）")
struct LibraryPackageServiceTests {

    @Test("目录包 JSON 编解码往返（字段不丢）")
    func packageCodecRoundTrip() throws {
        let package = LibraryPackage(
            exportedAt: "2026-11-11T00:00:00.000Z",
            session: LibraryPackageSession(
                id: "s1", name: "客户 A", sourcePath: "/Volumes/A", createdAt: "2026-01-01"),
            collections: [
                LibraryPackageCollection(id: "c1", name: "精选", sortOrder: 0, photoIds: ["p1"]),
            ],
            photos: [
                LibraryPackagePhoto(
                    photoId: "p1",
                    relativePath: "2026/05/a.cr3",
                    filename: "a.cr3",
                    checksum: "abc",
                    fileSize: 100,
                    fileMtimeMs: 1234.5,
                    status: "ready",
                    rating: 5,
                    label: "Red",
                    decision: "keep",
                    keywords: ["日落", "海边"],
                    descriptiveJSON: "{}"
                ),
                LibraryPackagePhoto(photoId: "p2", relativePath: "b.cr3", filename: "b.cr3"),
            ]
        )
        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(LibraryPackage.self, from: data)
        #expect(decoded == package)
        #expect(decoded.formatVersion == 1)
    }

    @Test("导出 → 导入：相对路径重绑定、评分/关键词/集合成员保留")
    func exportThenImportRebindsAndPreserves() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let dir = try makeTempDir(prefix: "gather-package")
        let fileA = try writeTempFile(in: dir, name: "a.jpg", content: Data("a".utf8))
        let fileB = try writeTempFile(in: dir, name: "b.jpg", content: Data("bb".utf8))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: fileA, checksum: "c1")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: fileB, checksum: "c2")
        _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
            .run([.text(dir), .text("s1")])
        let metadata = MetadataCacheRepo(connection: db)
        try metadata.upsert(
            photoId: "p1", sessionId: "s1",
            data: MetadataCacheInput(
                sessionId: "s1", rating: 5, label: "Red", keywords: ["日落", "海边"]))
        try metadata.upsert(
            photoId: "p2", sessionId: "s1",
            data: MetadataCacheInput(sessionId: "s1", rating: 3))
        let collections = CollectionRepo(connection: db)
        let collection = try collections.create(sessionId: "s1", name: "精选", sortOrder: nil)
        _ = try collections.appendItems(collectionId: collection.id, photoIds: ["p1", "p2"])

        let service = LibraryPackageService(connection: db)
        let exported = try service.exportPackage(
            LibraryExportInput(sessionId: "s1", destinationPath: dir))
        #expect(exported.photoCount == 2)
        #expect(exported.collectionCount == 1)

        // 模拟"另一台机器的库"：导出后把源工作区删掉（级联清 photos/pmc/集合），
        // 再导入才不会命中 photoId 去重分支（那属于 conflictPolicies 用例）。
        _ = try db.prepare("DELETE FROM sessions WHERE id = ?").run([.text("s1")])

        let newRoot = try makeTempDir(prefix: "gather-import")
        let report = try db.transaction {
            try service.importPackage(LibraryImportInput(
                packagePath: exported.packagePath,
                newRoot: newRoot,
                sessionName: "迁移后",
                conflictPolicy: .keepLocal
            ))
        }
        #expect(report.importedPhotos == 2)
        #expect(report.importedRatings == 2)
        #expect(report.importedKeywords == 1)
        #expect(report.importedCollections == 1)
        #expect(report.missingFiles.count == 2, "新根下没有文件：只登记、报告缺失")
        #expect(report.pendingCount == 2, "缺失文件以 pending 登记（等下一次索引扫描）")
        // 路径重绑定：新根 + 导出时的相对路径。
        let bound = try db.prepare(
            "SELECT filepath FROM photos WHERE id = 'p1' AND session_id = ?"
        ).get([.text(report.sessionId)])
        #expect(bound?[0].textValue == newRoot + "/a.jpg")
        // 评分/关键词随行迁移。
        let rating = try db.prepare(
            "SELECT rating FROM photo_metadata_cache WHERE photo_id = 'p1'"
        ).get([])
        #expect(rating?[0].intValue == 5)
        let keywords = try db.prepare(
            "SELECT keywords FROM photo_metadata_cache WHERE photo_id = 'p1'"
        ).get([])
        #expect((keywords?[0].textValue ?? "").contains("日落"))
        // 集合成员保留（映射到新集合 id）。
        guard let newCollection = report.collectionIDMap[collection.id] else {
            Issue.record("集合映射缺失")
            return
        }
        let members = try CollectionRepo(connection: db).memberPhotoIds(collectionId: newCollection)
        #expect(Set(members) == ["p1", "p2"])
    }

    @Test("冲突策略：keepLocal 跳过 / keepImported 回绑 / coexist 新增")
    func conflictPolicies() throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let dir = try makeTempDir(prefix: "gather-conflict")
        let file = try writeTempFile(in: dir, name: "a.jpg", content: Data("a".utf8))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: file, checksum: "c1")
        _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
            .run([.text(dir), .text("s1")])
        let service = LibraryPackageService(connection: db)
        let exported = try service.exportPackage(
            LibraryExportInput(sessionId: "s1", destinationPath: dir))

        // keepLocal：photoId 已存在 → 丢弃包内记录（不新增行）。
        let keepLocal = try service.importPackage(LibraryImportInput(
            packagePath: exported.packagePath,
            newRoot: dir,
            sessionName: "keepLocal",
            conflictPolicy: .keepLocal
        ))
        #expect(keepLocal.dedupedByPhotoID == 1)
        #expect(keepLocal.conflictsKeptLocal == 1)
        #expect(keepLocal.importedPhotos == 0)

        // keepImported：保留 id、用包内路径/校验和回绑。
        let otherRoot = try makeTempDir(prefix: "gather-rebind")
        let keepImported = try service.importPackage(LibraryImportInput(
            packagePath: exported.packagePath,
            newRoot: otherRoot,
            sessionName: "keepImported",
            conflictPolicy: .keepImported
        ))
        #expect(keepImported.conflictsKeptImported == 1)
        #expect(keepImported.importedPhotos == 1)
        let rebound = try db.prepare("SELECT filepath FROM photos WHERE id = 'p1'").get([])
        #expect(rebound?[0].textValue == otherRoot + "/a.jpg")
        // keepImported 回绑既有照片行：pmc.session_id 必须仍等于该行原会话（s1），
        // 否则按会话 join 的读面会漏掉这条元数据。
        let cacheSession = try db.prepare(
            "SELECT session_id FROM photo_metadata_cache WHERE photo_id = 'p1'").get([])
        #expect(cacheSession?[0].textValue == "s1")

        // coexist：新增一条照片行（photoId 重映射），库里两条。
        let coexist = try service.importPackage(LibraryImportInput(
            packagePath: exported.packagePath,
            newRoot: dir,
            sessionName: "coexist",
            conflictPolicy: .coexist
        ))
        #expect(coexist.coexisted == 1)
        #expect(coexist.importedPhotos == 1)
        let count = try rowCount(db, "SELECT COUNT(*) FROM photos WHERE checksum = 'c1'")
        #expect(count == 2)
    }

    @Test("外部 XMP 迁移：只补空字段，overwrite 才覆盖，冲突计数正确")
    func externalMigrationEvaluation() async throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let dir = try makeTempDir(prefix: "gather-migrate")
        let photoA = try writeTempFile(in: dir, name: "a.cr3", content: Data("a".utf8))
        let photoB = try writeTempFile(in: dir, name: "b.cr3", content: Data("b".utf8))
        // sidecar 存在才会被扫描（migrationCandidates 只给路径，sidecar 探测在 evaluate 里）。
        _ = try writeTempFile(in: dir, name: "a.xmp", content: Data("<x/>".utf8))
        _ = try writeTempFile(in: dir, name: "b.xmp", content: Data("<x/>".utf8))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: photoA, checksum: "c1")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: photoB, checksum: "c2")
        try MetadataCacheRepo(connection: db).upsert(
            photoId: "p1", sessionId: "s1",
            data: MetadataCacheInput(sessionId: "s1", rating: 2, label: "Green"))

        let candidates = try LibraryPackageStore(connection: db)
            .migrationCandidates(sessionId: "s1")
        #expect(candidates.count == 2)
        let service = ExternalMetadataMigrationService(xmp: StubXMPProvider(
            attributes: MetadataWriteAttributes(keywords: ["人物"], rating: 4, label: "Red")))
        let evaluation = await service.evaluate(candidates: candidates, overwriteExisting: false)
        #expect(evaluation.report.scanned == 2)
        #expect(evaluation.report.sidecarsFound == 2)
        // p1：rating/label 与本地不一致 → 两个冲突；keywords 本地为空 → 写入。
        // p2：三个字段本地都为空 → 全部写入。
        #expect(evaluation.report.conflicts == 2)
        #expect(evaluation.updates.count == 2)
        try db.transaction {
            try ExternalMetadataMigrationService.apply(
                updates: evaluation.updates, connection: db)
        }
        let ratingA = try db.prepare(
            "SELECT rating FROM photo_metadata_cache WHERE photo_id = 'p1'").get([])
        #expect(ratingA?[0].intValue == 2, "未覆盖：本地 rating 保留")
        let ratingB = try db.prepare(
            "SELECT rating FROM photo_metadata_cache WHERE photo_id = 'p2'").get([])
        #expect(ratingB?[0].intValue == 4, "空字段被 XMP 补写")

        // overwriteExisting=true：p1 也被覆盖。
        let overwrite = await service.evaluate(candidates: candidates, overwriteExisting: true)
        #expect(overwrite.report.conflicts == 0)
        try db.transaction {
            try ExternalMetadataMigrationService.apply(
                updates: overwrite.updates, connection: db)
        }
        let ratingA2 = try db.prepare(
            "SELECT rating FROM photo_metadata_cache WHERE photo_id = 'p1'").get([])
        #expect(ratingA2?[0].intValue == 4)
    }
}
