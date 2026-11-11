// desktop/native/gather-core/Tests/GatherCoreTests/Maintenance/LibraryPackageServiceTests.swift
// Wave3（task-24）：目录包导出/导入与外部 XMP 迁移的行为测试。
//
// 覆盖：
// 1. 包 JSON 编解码往返（格式稳定）；
// 2. 导出 → 导入：相对路径按 newRoot 重绑定、评分/关键词/集合成员保留；
// 3. 冲突策略 keepLocal / keepImported / coexist 的计数与落库差异；
// 4. 外部 sidecar 迁移的两阶段评估（只补空字段；overwrite 才覆盖；计数口径）。
//
// Wave5（Batch3 / task-20）：包格式 v2 组织资产段 —— 导出/导入 round-trip（堆栈/智能相册/
// 保存查询/人物绑定/重复组留档）、v1 旧包缺段兼容、photoId 映射失败的 skipped 计数、
// 同名资产冲突策略、导入后 metadata.scan 入队（注入记录器）。
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

    @Test("目录包 JSON 编解码往返（含组织资产段，formatVersion 2）")
    func packageCodecRoundTrip() throws {
        let criteria = FilterGroup(logic: .and, conditions: [
            .rule(FilterRule(
                field: FilterFields.collection, operator: .eq, value: .string("c1"))),
        ])
        let criteriaJSON = LibraryPackageService.encodeFilterGroup(criteria)
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
            ],
            stacks: [LibraryPackageStack(
                id: "st1", name: "连拍", coverPhotoId: "p1", photoIds: ["p1", "p2"])],
            smartAlbums: [LibraryPackageSmartAlbum(
                id: "sa1", name: "精选智能", description: "按集合",
                criteriaJSON: criteriaJSON, sortBy: "date_taken", sortOrder: "desc", icon: "⭐️")],
            savedSearches: [LibraryPackageSavedSearch(
                id: "ss1", name: "全局精选", criteriaJSON: criteriaJSON, isGlobal: true)],
            personBindings: [LibraryPackagePersonBinding(
                photoId: "p1", personId: "pe1", personName: "新娘", confidence: 0.9)],
            duplicateGroups: [LibraryPackageDuplicateGroup(
                groupType: "exact",
                checksum: "abc",
                members: [
                    LibraryPackageDuplicateMember(photoId: "p1", isKept: true),
                    LibraryPackageDuplicateMember(
                        photoId: "p2", isKept: false, resolution: "keep_one"),
                ])],
        )
        let data = try JSONEncoder().encode(package)
        let decoded = try JSONDecoder().decode(LibraryPackage.self, from: data)
        #expect(decoded == package)
        #expect(decoded.formatVersion == 2)
        #expect(decoded.stacks == package.stacks)
        #expect(decoded.personBindings == package.personBindings)
        #expect(decoded.duplicateGroups == package.duplicateGroups)
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

    @Test("XMP 迁移：越界 rating(-1/6) 跳过并计数，不触发约束回滚")
    func externalMigrationSkipsInvalidRatings() async throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let dir = try makeTempDir(prefix: "gather-invalid-rating")
        let photo = try writeTempFile(in: dir, name: "a.cr3", content: Data("a".utf8))
        _ = try writeTempFile(in: dir, name: "a.xmp", content: Data("<x/>".utf8))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: photo, checksum: "c1")
        let candidates = try LibraryPackageStore(connection: db)
            .migrationCandidates(sessionId: "s1")

        let negative = ExternalMetadataMigrationService(xmp: StubXMPProvider(
            attributes: MetadataWriteAttributes(rating: -1)))
        let negativeEval = await negative.evaluate(
            candidates: candidates, overwriteExisting: false)
        #expect(negativeEval.report.skippedInvalidRating == 1)
        #expect(negativeEval.updates.isEmpty, "越界 rating 不进入写入队列")
        // apply 空更新也不抛错（旧实现在此会 CHECK 失败并回滚整批）。
        try db.transaction {
            try ExternalMetadataMigrationService.apply(
                updates: negativeEval.updates, connection: db)
        }

        let tooHigh = ExternalMetadataMigrationService(xmp: StubXMPProvider(
            attributes: MetadataWriteAttributes(rating: 6)))
        let highEval = await tooHigh.evaluate(
            candidates: candidates, overwriteExisting: false)
        #expect(highEval.report.skippedInvalidRating == 1)
        #expect(highEval.updates.isEmpty)
    }

    @Test("ExternalMigrationReport 旧 JSON 缺 skippedInvalidRating 仍可解码")
    func migrationReportDecodesLegacyJSON() throws {
        let json = """
            {"scanned":2,"sidecarsFound":1,"applied":1,"conflicts":0,
             "missingRating":1,"missingLabel":1,"missingKeywords":1,"failed":[]}
            """
        let report = try JSONDecoder().decode(
            ExternalMigrationReport.self, from: Data(json.utf8))
        #expect(report.scanned == 2)
        #expect(report.skippedInvalidRating == 0)
    }

    @Test("库包非业务错误映射为 libraryPackage/INVALID_PARAM")
    func libraryPackageFailureMapping() {
        let mapped = MaintenanceService.libraryPackageFailure(
            NSError(domain: "LibraryPackageTest", code: 42))
        guard let gather = mapped as? GatherError else {
            Issue.record("应映射为 GatherError")
            return
        }
        #expect(gather.code == .INVALID_PARAM)
        #expect(gather.params["field"] == "libraryPackage")
    }
}

// MARK: - Wave5（Batch3 / task-20）：组织资产迁移

/// metadata.scan 入队记录（注入替身；LockedBox 的动态成员只能映射到具名属性）。
private struct Wave5ScanState {
    var calls: [(sessionId: String, paths: [String])] = []
}

/// 源库组织资产夹具：3 张照片 + 集合 + 堆栈 + 智能相册(集合规则) + 保存查询(会话/全局)
/// + 人物绑定 + 重复组，导出一个 v2 包。
private struct OrgAssetSourceFixture {
    let packagePath: String
    let sourceRoot: String
    let collectionId: String
    let stackId: String
    let exportResult: LibraryExportResult
}

private func makeOrgAssetSource() throws -> OrgAssetSourceFixture {
    let db = try makeTestDB()
    try insertSession(db, "s1")
    let dir = try makeTempDir(prefix: "gather-org-src")
    var paths: [String] = []
    for (index, name) in ["a.jpg", "b.jpg", "c.jpg"].enumerated() {
        paths.append(try writeTempFile(in: dir, name: name, content: Data("org-\(index)".utf8)))
    }
    for (index, path) in paths.enumerated() {
        try insertPhoto(
            db, id: "p\(index + 1)", sessionId: "s1", filepath: path, checksum: "c\(index + 1)")
    }
    _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
        .run([.text(dir), .text("s1")])
    let collections = CollectionRepo(connection: db)
    let collection = try collections.create(sessionId: "s1", name: "精选", sortOrder: nil)
    _ = try collections.appendItems(collectionId: collection.id, photoIds: ["p1", "p2"])
    let stack = try StackRepo(connection: db).create(
        sessionId: "s1", name: "连拍", coverPhotoId: "p2", photoIds: ["p1", "p2"])
    let collectionCriteria = FilterGroup(logic: .and, conditions: [
        .rule(FilterRule(
            field: FilterFields.collection, operator: .eq, value: .string(collection.id))),
    ])
    _ = try SmartAlbumRepo(connection: db).create(data: SmartAlbumCreateData(
        name: "精选智能", description: "按集合", filterCriteria: collectionCriteria,
        sortBy: "date_taken", sortOrder: "desc", icon: "⭐️"))
    let savedSearches = SavedSearchRepo(connection: db)
    let stackCriteria = FilterGroup(logic: .and, conditions: [
        .rule(FilterRule(
            field: FilterFields.stack, operator: .eq, value: .string(stack.id))),
    ])
    _ = try savedSearches.upsert(name: "本工作区栈", sessionId: "s1", criteria: stackCriteria)
    _ = try savedSearches.upsert(name: "全局精选", sessionId: nil, criteria: collectionCriteria)
    let persons = PersonRepo(connection: db)
    let personId = try persons.upsertByName(name: "新娘")
    try persons.addPhotos(personId: personId, sessionId: "s1", photos: [
        PersonPhotoInput(photoId: "p1", faceBbox: [], confidence: 0.9),
    ])
    let duplicates = DuplicateRepo(connection: db)
    let groupIds = try duplicates.insertGroups([DuplicateGroupInsert(
        sessionId: "s1", groupType: "exact", checksum: "c1", hashHex: nil,
        memberCount: 2, createdAt: "2026-01-01T00:00:00.000Z")])
    try duplicates.insertMembers([
        DuplicateMemberInsert(
            groupId: groupIds[0], photoId: "p1", sessionId: "s1",
            isKept: true, fileSize: nil, fileMtime: nil, resolution: nil),
        DuplicateMemberInsert(
            groupId: groupIds[0], photoId: "p2", sessionId: "s1",
            isKept: false, fileSize: nil, fileMtime: nil, resolution: "keep_one"),
    ])
    let exported = try LibraryPackageService(connection: db).exportPackage(
        LibraryExportInput(sessionId: "s1", destinationPath: dir))
    return OrgAssetSourceFixture(
        packagePath: exported.packagePath, sourceRoot: dir,
        collectionId: collection.id, stackId: stack.id, exportResult: exported)
}

private func readPackageJSON(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw GatherError.invalidParameter(field: "package", reason: "fixture package invalid")
    }
    return object
}

private func writePackageJSON(_ object: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

@Suite("Wave5 目录包组织资产（stacks/smartAlbums/savedSearches/personBindings）")
struct LibraryPackageOrganizationAssetTests {
    @Test("导出：组织资产段齐全（堆栈/智能相册/保存查询/人物绑定/重复组）")
    func exportCarriesOrganizationAssets() throws {
        let fixture = try makeOrgAssetSource()
        let package = try JSONDecoder().decode(
            LibraryPackage.self,
            from: Data(contentsOf: URL(fileURLWithPath: fixture.packagePath)))
        #expect(package.formatVersion == 2)
        #expect(package.stacks.count == 1)
        #expect(package.stacks[0].photoIds == ["p1", "p2"])
        #expect(package.stacks[0].coverPhotoId == "p2")
        #expect(package.smartAlbums.count == 1)
        #expect(package.smartAlbums[0].name == "精选智能")
        #expect(package.smartAlbums[0].criteriaJSON.contains(fixture.collectionId))
        #expect(package.savedSearches.count == 2)
        #expect(package.savedSearches.contains { $0.isGlobal && $0.name == "全局精选" })
        #expect(package.savedSearches.contains { !$0.isGlobal && $0.name == "本工作区栈" })
        #expect(package.personBindings.count == 1)
        #expect(package.personBindings[0].photoId == "p1")
        #expect(package.personBindings[0].personName == "新娘")
        #expect(package.duplicateGroups.count == 1)
        #expect(package.duplicateGroups[0].members.count == 2)
    }

    @Test("导出报告：分项计数（stacks/smartAlbums/savedSearches/personBindings/duplicateGroups）")
    func exportResultCarriesSectionCounts() throws {
        let result = try makeOrgAssetSource().exportResult
        #expect(result.photoCount == 3)
        #expect(result.collectionCount == 1)
        #expect(result.stackCount == 1)
        #expect(result.smartAlbumCount == 1)
        #expect(result.savedSearchCount == 2)
        #expect(result.personBindingCount == 1)
        #expect(result.duplicateGroupCount == 1)
    }

    @Test("导入：组织资产按新 photoId 重建、容器引用重映射、重复组不导入、自动入队扫描")
    func importRebuildsOrganizationAssets() throws {
        let fixture = try makeOrgAssetSource()
        let target = try makeTestDB()
        let targetRoot = try makeTempDir(prefix: "gather-org-dst")
        _ = try writeTempFile(in: targetRoot, name: "a.jpg")
        _ = try writeTempFile(in: targetRoot, name: "b.jpg")
        let scanCalls = LockedBox(Wave5ScanState())
        let service = LibraryPackageService(connection: target, enqueueScan: { sessionId, paths in
            scanCalls.lock.withLock { scanCalls.calls.append((sessionId: sessionId, paths: paths)) }
            return "job-org"
        })
        let report = try target.transaction {
            try service.importPackage(LibraryImportInput(
                packagePath: fixture.packagePath,
                newRoot: targetRoot,
                sessionName: "组织迁移",
                conflictPolicy: .coexist))
        }
        #expect(report.importedPhotos == 3)
        #expect(report.importedStacks == 1)
        #expect(report.importedSmartAlbums == 1)
        #expect(report.importedSavedSearches == 2)
        #expect(report.importedPersonBindings == 1)
        #expect(report.skippedUnmappedItems == 0)
        #expect(report.skippedDuplicateGroups == 1)
        #expect(report.scanJobId == "job-org")
        // 堆栈：成员映射到新库 photoId（目标库为空时 id 保留）。
        let stacks = try StackRepo(connection: target).list(sessionId: report.sessionId)
        let stack = try #require(stacks.first)
        #expect(stack.name == "连拍")
        let members = try StackRepo(connection: target)
            .members(stackId: stack.id).map(\.photoId)
        #expect(Set(members) == ["p1", "p2"])
        // 智能相册：criteria 的集合引用换成新集合 id（旧 id 不再出现）。
        let albums = try SmartAlbumRepo(connection: target).list()
        let album = try #require(albums.first { $0.name == "精选智能" })
        let newCollectionId = try #require(report.collectionIDMap[fixture.collectionId])
        #expect(album.filterCriteria.contains(newCollectionId))
        #expect(!album.filterCriteria.contains(fixture.collectionId))
        // 保存查询：全局保留作用域；会话查询落新工作区，stack 规则引用新堆栈 id。
        let searches = SavedSearchRepo(connection: target)
        #expect(try searches.list(sessionId: nil).map(\.name) == ["全局精选"])
        // list(sessionId:) 按仓储语义包含全局查询 + 本会话查询；按名字取本工作区那条。
        let sessionSearches = try searches.list(sessionId: report.sessionId)
        #expect(sessionSearches.map(\.name).contains("本工作区栈"))
        let sessionSearch = try #require(sessionSearches.first { $0.name == "本工作区栈" })
        let criteriaJSON = try JSONEncoder().encode(sessionSearch.criteria)
        let criteriaText = String(decoding: criteriaJSON, as: UTF8.self)
        #expect(criteriaText.contains(stack.id))
        #expect(!criteriaText.contains(fixture.stackId))
        // 人物绑定：身份按名重建、照片映射到新库行。
        let bindings = try target.prepare("""
            SELECT pp.photo_id, pr.name
              FROM person_photos pp JOIN persons pr ON pr.id = pp.person_id
            """).query()
        #expect(bindings.count == 1)
        #expect(bindings[0][0].textValue == "p1")
        #expect(bindings[0][1].textValue == "新娘")
        // 重复组：派生数据不重建。
        #expect(try rowCount(target, "SELECT COUNT(*) FROM duplicate_groups") == 0)
        // 入队扫描：requestedPaths = 导入照片的父目录（去重）。
        let calls = scanCalls.lock.withLock { scanCalls.calls }
        #expect(calls.count == 1)
        #expect(calls[0].sessionId == report.sessionId)
        #expect(calls[0].paths == [(targetRoot as NSString).standardizingPath])
    }

    @Test("v1 旧包缺组织资产段：解码为空、导入不 fail")
    func legacyPackageWithoutOrganizationSections() throws {
        let fixture = try makeOrgAssetSource()
        var object = try readPackageJSON(fixture.packagePath)
        object["formatVersion"] = 1
        for key in ["stacks", "smartAlbums", "savedSearches", "personBindings", "duplicateGroups"] {
            object.removeValue(forKey: key)
        }
        let legacyPath = (fixture.sourceRoot as NSString)
            .appendingPathComponent("legacy-v1.gatherlib.json")
        try writePackageJSON(object, to: legacyPath)

        let decoded = try JSONDecoder().decode(
            LibraryPackage.self, from: Data(contentsOf: URL(fileURLWithPath: legacyPath)))
        #expect(decoded.formatVersion == 1)
        #expect(decoded.stacks.isEmpty)
        #expect(decoded.smartAlbums.isEmpty)
        #expect(decoded.savedSearches.isEmpty)
        #expect(decoded.personBindings.isEmpty)
        #expect(decoded.duplicateGroups.isEmpty)

        let target = try makeTestDB()
        let targetRoot = try makeTempDir(prefix: "gather-org-legacy")
        let report = try LibraryPackageService(connection: target).importPackage(
            LibraryImportInput(packagePath: legacyPath, newRoot: targetRoot, sessionName: "旧包"))
        #expect(report.importedPhotos == 3)
        #expect(report.importedStacks == 0)
        #expect(report.importedSmartAlbums == 0)
        #expect(report.importedSavedSearches == 0)
        #expect(report.importedPersonBindings == 0)
        #expect(report.skippedDuplicateGroups == 0)
    }

    @Test("组织资产引用不到 photoId：计入 skippedUnmappedItems（不静默丢）")
    func unmappedOrganizationReferencesAreCounted() throws {
        let fixture = try makeOrgAssetSource()
        var object = try readPackageJSON(fixture.packagePath)
        guard var stacks = object["stacks"] as? [[String: Any]], !stacks.isEmpty else {
            Issue.record("夹具包缺 stacks 段")
            return
        }
        stacks[0]["photoIds"] = ["p1", "ghost-photo"]
        object["stacks"] = stacks
        let ghostBindings: [[String: Any]] = [[
            "photoId": "ghost-photo",
            "personId": "ghost-person",
            "personName": "幽灵",
            "confidence": 0.1,
        ]]
        object["personBindings"] = ghostBindings
        let mutatedPath = (fixture.sourceRoot as NSString)
            .appendingPathComponent("unmapped.gatherlib.json")
        try writePackageJSON(object, to: mutatedPath)

        let target = try makeTestDB()
        let targetRoot = try makeTempDir(prefix: "gather-org-unmapped")
        let report = try LibraryPackageService(connection: target, enqueueScan: { _, _ in "job-u" })
            .importPackage(LibraryImportInput(
                packagePath: mutatedPath, newRoot: targetRoot, sessionName: "未映射"))
        #expect(report.skippedUnmappedItems == 2)
        #expect(report.importedStacks == 1)
        #expect(report.importedPersonBindings == 0)
        let importedStacks = try StackRepo(connection: target).list(sessionId: report.sessionId)
        let firstStack = try #require(importedStacks.first)
        let memberIds = try StackRepo(connection: target)
            .members(stackId: firstStack.id).map(\.photoId)
        #expect(memberIds == ["p1"])
    }

    @Test("组织资产冲突策略：同名智能相册/全局保存查询按 keepLocal/keepImported/coexist")
    func organizationConflictPolicies() throws {
        let fixture = try makeOrgAssetSource()
        let target = try makeTestDB()
        // 目标库预置同名智能相册与同名全局保存查询（模拟"本机已有同名资产"）。
        let empty = FilterGroup(logic: .and, conditions: [])
        _ = try SmartAlbumRepo(connection: target).create(data: SmartAlbumCreateData(
            name: "精选智能", filterCriteria: empty))
        _ = try SavedSearchRepo(connection: target).upsert(
            name: "全局精选", sessionId: nil, criteria: empty)
        let root = try makeTempDir(prefix: "gather-org-conflict")
        let service = LibraryPackageService(connection: target, enqueueScan: { _, _ in "job-c" })

        // keepLocal：同名资产保留本地，不覆盖。
        let keepLocal = try service.importPackage(LibraryImportInput(
            packagePath: fixture.packagePath, newRoot: root,
            sessionName: "keepLocal", conflictPolicy: .keepLocal))
        #expect(keepLocal.importedSmartAlbums == 0)
        #expect(keepLocal.skippedSmartAlbums == 1)
        #expect(keepLocal.importedSavedSearches == 1)
        #expect(keepLocal.skippedSavedSearches == 1)
        let localAlbums = try SmartAlbumRepo(connection: target).list()
        let keptAlbum = try #require(localAlbums.first { $0.name == "精选智能" })
        #expect(!keptAlbum.filterCriteria.contains(fixture.collectionId))

        // keepImported：同名智能相册的 criteria 换成包内（集合引用重映射到新 id）。
        let keepImported = try service.importPackage(LibraryImportInput(
            packagePath: fixture.packagePath, newRoot: root,
            sessionName: "keepImported", conflictPolicy: .keepImported))
        #expect(keepImported.importedSmartAlbums == 1)
        #expect(keepImported.skippedSmartAlbums == 0)
        let updatedAlbums = try SmartAlbumRepo(connection: target).list()
        let updatedAlbum = try #require(updatedAlbums.first { $0.name == "精选智能" })
        let importedCollectionId = try #require(
            keepImported.collectionIDMap[fixture.collectionId])
        #expect(updatedAlbum.filterCriteria.contains(importedCollectionId))

        // coexist：新增带后缀的智能相册，不动既有同名条目。
        let coexist = try service.importPackage(LibraryImportInput(
            packagePath: fixture.packagePath, newRoot: root,
            sessionName: "coexist", conflictPolicy: .coexist))
        #expect(coexist.importedSmartAlbums == 1)
        let coexistNames = try SmartAlbumRepo(connection: target).list().map(\.name)
        #expect(coexistNames.contains("精选智能（导入）"))
    }

    @Test("导入后自动入队 metadata.scan：路径变化入队、原地导入跳过")
    func importEnqueuesMetadataScan() throws {
        let fixture = try makeOrgAssetSource()
        // ① 迁到新盘（路径变化 + 文件缺失）→ 入队。
        let moved = try makeTestDB()
        let movedRoot = try makeTempDir(prefix: "gather-org-moved")
        let box = LockedBox(Wave5ScanState())
        let enqueued = try LibraryPackageService(connection: moved, enqueueScan: { sessionId, paths in
            box.lock.withLock { box.calls.append((sessionId: sessionId, paths: paths)) }
            return "job-moved"
        }).importPackage(LibraryImportInput(
            packagePath: fixture.packagePath, newRoot: movedRoot, sessionName: "迁到新盘"))
        #expect(enqueued.scanJobId == "job-moved")
        #expect(enqueued.pendingCount == 3)
        let calls = box.lock.withLock { box.calls }
        #expect(calls.count == 1)
        #expect(calls[0].sessionId == enqueued.sessionId)
        #expect(calls[0].paths == [(movedRoot as NSString).standardizingPath])

        // ② 原地导入（newRoot = 包内 sourcePath）且文件都在 → 不入队。
        let same = try makeTestDB()
        let sameBox = LockedBox(Wave5ScanState())
        let unchanged = try LibraryPackageService(connection: same, enqueueScan: { sessionId, paths in
            sameBox.lock.withLock { sameBox.calls.append((sessionId: sessionId, paths: paths)) }
            return "should-not-enqueue"
        }).importPackage(LibraryImportInput(
            packagePath: fixture.packagePath, newRoot: fixture.sourceRoot, sessionName: "原地"))
        #expect(unchanged.pendingCount == 0)
        #expect(unchanged.scanJobId == nil)
        #expect(sameBox.lock.withLock { sameBox.calls }.isEmpty)
    }
}
