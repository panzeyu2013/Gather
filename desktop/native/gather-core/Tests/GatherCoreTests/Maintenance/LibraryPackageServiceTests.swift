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
        let expectedBound = ((newRoot as NSString).standardizingPath as NSString)
            .appendingPathComponent("a.jpg")
        #expect(bound?[0].textValue == expectedBound)
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
        // P0 修复后 keepImported 走窄 UPDATE（不再整行 upsert）：先给既有照片建 cache
        // 行，才能验证回绑后 session_id 仍属于原会话、且列没有被写成 NULL。
        try MetadataCacheRepo(connection: db).upsert(
            photoId: "p1", sessionId: "s1",
            data: MetadataCacheInput(sessionId: "s1", rating: 3))

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
        let expectedRebind = ((otherRoot as NSString).standardizingPath as NSString)
            .appendingPathComponent("a.jpg")
        #expect(rebound?[0].textValue == expectedRebind)
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

    // MARK: - Review P0/P1 回归（task-31）：回绑不洗缓存 + 包路径不可信

    private struct KeepImportedFixture {
        let db: DBConnection
        let packagePath: String
        let targetRoot: String
    }

    /// 既有照片（cache 有 EXIF/rating/label/keywords/IPTC）导出成包，再把包里
    /// 迁移字段改成不同值，用于验证回绑时"只更新迁移列、EXIF 不动"。
    private func makeKeepImportedFixture(packageRating: Int = 4) throws -> KeepImportedFixture {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let dir = try makeTempDir(prefix: "gather-pkg-src")
        let file = try writeTempFile(in: dir, name: "a.jpg", content: Data("a".utf8))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: file, checksum: "c1")
        _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
            .run([.text(dir), .text("s1")])
        try MetadataCacheRepo(connection: db).upsert(
            photoId: "p1", sessionId: "s1",
            data: MetadataCacheInput(
                sessionId: "s1",
                dateTaken: "2024:05:01 10:00:00",
                cameraMake: "Fujifilm",
                cameraModel: "X-T5",
                lensModel: "33mm F1.4",
                focalLength: 33,
                fNumber: 1.4,
                exposureTime: "1/250",
                iso: 400,
                rating: 5,
                label: "Red",
                gpsLatitude: 31.2,
                gpsLongitude: 121.5,
                width: 6000,
                height: 4000,
                fileSize: 123,
                fileMtime: "2024-05-01T00:00:00Z",
                keywords: ["旧词"],
                descriptive: DescriptiveMetadata(title: "旧标题")))
        let service = LibraryPackageService(connection: db)
        let exported = try service.exportPackage(
            LibraryExportInput(sessionId: "s1", destinationPath: dir))
        let targetRoot = try makeTempDir(prefix: "gather-pkg-dst")
        _ = try writeTempFile(in: targetRoot, name: "a.jpg", content: Data("a".utf8))

        // 改包里迁移字段（模拟另一台机器上的新评分/色标/关键词/IPTC）。
        let data = try Data(contentsOf: URL(fileURLWithPath: exported.packagePath))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var photos = object["photos"] as? [[String: Any]],
              !photos.isEmpty else {
            throw GatherError.invalidParameter(field: "package", reason: "fixture package invalid")
        }
        photos[0]["rating"] = packageRating
        photos[0]["label"] = "Green"
        photos[0]["keywords"] = ["新词"]
        let descriptiveJSON = try JSONEncoder().encode(DescriptiveMetadata(title: "新标题"))
        photos[0]["descriptiveJSON"] = String(decoding: descriptiveJSON, as: UTF8.self)
        object["photos"] = photos
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let modifiedPath = (dir as NSString).appendingPathComponent("modified.gatherlib.json")
        try mutated.write(to: URL(fileURLWithPath: modifiedPath), options: .atomic)
        return KeepImportedFixture(db: db, packagePath: modifiedPath, targetRoot: targetRoot)
    }

    @Test("keepImported 回绑既有照片：只更新迁移字段，EXIF/指纹列保持不变")
    func keepImportedPreservesExistingCacheEXIF() throws {
        let fx = try makeKeepImportedFixture()
        let report = try LibraryPackageService(connection: fx.db).importPackage(
            LibraryImportInput(
                packagePath: fx.packagePath,
                newRoot: fx.targetRoot,
                sessionName: "keepImported",
                conflictPolicy: .keepImported))
        #expect(report.conflictsKeptImported == 1)
        let cache = try #require(
            try MetadataCacheRepo(connection: fx.db).get("p1"))
        #expect(cache.sessionId == "s1")
        // EXIF/指纹：目录包不带这些字段，回绑绝不能清空。
        #expect(cache.dateTaken == "2024:05:01 10:00:00")
        #expect(cache.cameraMake == "Fujifilm")
        #expect(cache.cameraModel == "X-T5")
        #expect(cache.lensModel == "33mm F1.4")
        #expect(cache.gpsLatitude == 31.2)
        #expect(cache.gpsLongitude == 121.5)
        #expect(cache.width == 6000)
        #expect(cache.height == 4000)
        #expect(cache.fileSize == 123)
        // 迁移字段：包里有值才写。
        #expect(cache.rating == 4)
        #expect(cache.label == "Green")
        #expect(cache.keywords == ["新词"])
        #expect(cache.descriptive.title == "新标题")
    }

    @Test("keepImported：importRatings/importKeywords=false 不覆盖既有评级与关键词")
    func keepImportedHonorsImportFlags() throws {
        let fx = try makeKeepImportedFixture()
        let report = try LibraryPackageService(connection: fx.db).importPackage(
            LibraryImportInput(
                packagePath: fx.packagePath,
                newRoot: fx.targetRoot,
                sessionName: "keepImportedFlags",
                conflictPolicy: .keepImported,
                importRatings: false,
                importKeywords: false))
        #expect(report.conflictsKeptImported == 1)
        #expect(report.importedRatings == 0)
        #expect(report.importedKeywords == 0)
        let cache = try #require(
            try MetadataCacheRepo(connection: fx.db).get("p1"))
        #expect(cache.rating == 5, "未勾选 rating 时不得用空值覆盖既有评级")
        #expect(cache.keywords == ["旧词"], "未勾选 keywords 时不得清空既有词")
        #expect(cache.dateTaken == "2024:05:01 10:00:00")
        #expect(cache.cameraModel == "X-T5")
    }

    @Test("keepImported：包里 rating=0 不覆盖既有评级（>0 才写）")
    func keepImportedDoesNotWriteZeroRating() throws {
        let fx = try makeKeepImportedFixture(packageRating: 0)
        _ = try LibraryPackageService(connection: fx.db).importPackage(
            LibraryImportInput(
                packagePath: fx.packagePath,
                newRoot: fx.targetRoot,
                sessionName: "keepImportedZeroRating",
                conflictPolicy: .keepImported))
        let cache = try #require(
            try MetadataCacheRepo(connection: fx.db).get("p1"))
        #expect(cache.rating == 5, "包里的 0 不是有效评级，不得覆盖既有 5 星")
        #expect(cache.keywords == ["新词"], "其它迁移字段仍按包内有值写入")
        #expect(cache.dateTaken == "2024:05:01 10:00:00")
    }

    @Test("relativePath：拒绝绝对路径与 .. 段，合法路径仍落在 root 内")
    func rejectsUnsafeRelativePaths() throws {
        let root = try makeTempDir(prefix: "gather-pkg-root")
        #expect(throws: GatherError.self) {
            _ = try LibraryPackageService.absolutePath(
                relativePath: "../evil.jpg", newRoot: root)
        }
        #expect(throws: GatherError.self) {
            _ = try LibraryPackageService.absolutePath(
                relativePath: "/etc/passwd", newRoot: root)
        }
        #expect(throws: GatherError.self) {
            _ = try LibraryPackageService.absolutePath(
                relativePath: "a/../../evil.jpg", newRoot: root)
        }
        let resolved = try LibraryPackageService.absolutePath(
            relativePath: "sub/a.jpg", newRoot: root)
        let standardizedRoot = (root as NSString).standardizingPath
        #expect(resolved.hasPrefix(standardizedRoot + "/"))
        #expect(resolved.hasSuffix("/sub/a.jpg"))
    }

    @Test("newRoot 为空：用包内 session.sourcePath 解析绝对路径")
    func emptyNewRootUsesPackageSourcePath() throws {
        let sourceDB = try makeTestDB()
        try insertSession(sourceDB, "s1")
        let dir = try makeTempDir(prefix: "gather-pkg-source-root")
        let file = try writeTempFile(in: dir, name: "a.jpg", content: Data("a".utf8))
        try insertPhoto(sourceDB, id: "p1", sessionId: "s1", filepath: file, checksum: "c1")
        _ = try sourceDB.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
            .run([.text(dir), .text("s1")])
        let exported = try LibraryPackageService(connection: sourceDB).exportPackage(
            LibraryExportInput(sessionId: "s1", destinationPath: dir))

        let targetDB = try makeTestDB()
        let report = try LibraryPackageService(connection: targetDB).importPackage(
            LibraryImportInput(packagePath: exported.packagePath, newRoot: ""))
        #expect(report.importedPhotos == 1)
        let row = try targetDB.prepare("""
            SELECT p.filepath, s.source_path
            FROM photos p JOIN sessions s ON p.session_id = s.id
            WHERE p.id = 'p1'
            """).get([])
        let expectedPath = ((dir as NSString).standardizingPath as NSString)
            .appendingPathComponent("a.jpg")
        #expect(row?[0].textValue == expectedPath)
        #expect(row?[1].textValue == dir, "空 newRoot 的工作区源根也应回退到包内 sourcePath")
    }
}
