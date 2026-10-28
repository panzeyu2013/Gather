// desktop/native/gather-core/Tests/GatherCoreTests/Services/RejectedMoverTests.swift
// P1 / D：淘汰移动——照片与 XMP 侧车一起搬，登记路径同步改写。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("淘汰移动")
struct RejectedMoverTests {
    @Test("移动照片时侧车跟着走，photos.filepath 同步改到 _rejects")
    func movesPhotoAndSidecar() throws {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-reject-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionId = "s-1"
        let photoId = "p-1"
        try insertSession(db, sessionId)
        let photoPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photoPath))
        let sidecarPath = TSPath.xmpSidecarPath(photoPath)
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecarPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)

        let mover = RejectedMover(photoRepo: PhotoRepo(connection: db))
        let destination = (dir as NSString).appendingPathComponent("_rejects")
        let result = mover.move(photos: [(photoId, photoPath)], destinationRoot: destination)

        #expect(result.failed.isEmpty)
        #expect(result.moved == [photoId])
        #expect(FileManager.default.fileExists(atPath: result.newPaths[0]))
        #expect(FileManager.default.fileExists(
            atPath: (destination as NSString).appendingPathComponent("IMG_1.xmp")))
        #expect(!FileManager.default.fileExists(atPath: sidecarPath), "侧车不得留在原目录")
        let row = try db.prepare("SELECT filepath FROM photos WHERE id = ?").get([.text(photoId)])
        #expect(row?[0].textValue == result.newPaths[0])
    }

    @Test("移出提交走宿主迁移闭包；闭包失败时文件回滚")
    func relocationClosureAndRollback() throws {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-reject-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let photoPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photoPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)
        let destination = (dir as NSString).appendingPathComponent("_rejects")

        var relocated = false
        let failing = RejectedMover(photoRepo: PhotoRepo(connection: db),
                                    relocate: { _, _, _ in
            relocated = true
            throw NSError(domain: "test", code: 1)
        })
        let failed = failing.move(photos: [(photoId, photoPath)], destinationRoot: destination)
        #expect(relocated)
        #expect(failed.failed.count == 1)
        #expect(FileManager.default.fileExists(atPath: photoPath), "事务失败必须把文件移回")

        let ok = RejectedMover(photoRepo: PhotoRepo(connection: db),
                               relocate: { id, _, newPath in
            try PhotoRepo(connection: db).updateFilepath(photoId: id, filepath: newPath)
        })
        let result = ok.move(photos: [(photoId, photoPath)], destinationRoot: destination)
        #expect(result.failed.isEmpty)
        let row = try db.prepare("SELECT filepath FROM photos WHERE id = ?").get([.text(photoId)])
        #expect(row?[0].textValue == result.newPaths[0])
    }

    @Test("移出改名后 asset_files.filename/extension 同步改写（RAW/JPEG 配对键）")
    func relocationKeepsAssetFileFilenameInSync() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let oldPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: oldPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: oldPath)
        try insertAssetFile(db, id: "f-1", normalizedPath: oldPath)
        _ = try db.prepare("UPDATE photos SET asset_file_id = ? WHERE id = ?")
            .run([.text("f-1"), .text(photoId)])

        let newPath = (dir as NSString).appendingPathComponent("_rejects/IMG_1-2.CR3")
        try AssetRepo(connection: db).relocatePhotoPathsAfterMove(
            photoId: photoId, oldPhotoPath: oldPath, newPhotoPath: newPath,
            timestamp: "2026-10-28T00:00:00.000Z")

        let row = try #require(try db.prepare(
            "SELECT normalized_path, filename, extension FROM asset_files WHERE id = ?"
        ).get([.text("f-1")]))
        #expect(row[0].textValue == TSPath.normalize(newPath))
        #expect(row[1].textValue == "IMG_1-2.CR3", "配对键是 stem(filename)，改名后必须同步")
        // extension 列存带点的形态（".cr3"）：与 relinkMovedFile 的写入口径一致。
        #expect(row[2].textValue == ".cr3")
        let photoRow = try #require(try db.prepare(
            "SELECT filepath FROM photos WHERE id = ?").get([.text(photoId)]))
        #expect(photoRow[0].textValue == newPath)
    }

    @Test("目标路径已登记：整次迁移 fail-closed（不覆盖目标行、photos 不悬空）")
    func relocationTargetAlreadyRegistered() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let oldPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        let newPath = (dir as NSString).appendingPathComponent("_rejects/IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: oldPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: oldPath)
        try insertAssetFile(db, id: "f-1", normalizedPath: oldPath)
        try insertAssetFile(db, id: "f-2", normalizedPath: newPath)

        // 目标已登记 = 数据不一致：抛错让整次移出回滚（文件由 RejectedMover 移回），
        // 不能留下 photos.asset_file_id → 旧行（路径已不存在）的悬空引用。
        #expect(throws: PersistenceError.self) {
            try AssetRepo(connection: db).relocatePhotoPathsAfterMove(
                photoId: photoId, oldPhotoPath: oldPath, newPhotoPath: newPath,
                timestamp: "2026-10-28T00:00:00.000Z")
        }

        let rows = try db.prepare(
            "SELECT id, normalized_path FROM asset_files ORDER BY id").query([])
        #expect(rows.count == 2, "不得合并/删除目标行")
        #expect(rows[1][1].textValue == TSPath.normalize(newPath), "目标行原样保留")
        #expect(rows[0][1].textValue == TSPath.normalize(oldPath), "旧行不改")
        let photoRow = try #require(try db.prepare(
            "SELECT filepath FROM photos WHERE id = ?").get([.text(photoId)]))
        #expect(photoRow[0].textValue == oldPath, "事务回滚后 photos.filepath 必须停在旧路径")
    }

    @Test("移出时交付备份跟着改名换目录，deliveries.backup_path 同步改写")
    func relocationMovesDeliveryBackup() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let oldPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: oldPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: oldPath)
        let oldXmp = TSPath.xmpSidecarPath(oldPath)
        let oldBackup = oldXmp + ".gather-backup-abc"
        _ = try db.prepare("""
            INSERT INTO deliveries (xmp_path, photo_path, status, revision, base_fingerprint, base_values_json, backup_path, created_at, updated_at)
            VALUES (?, ?, 'written', 1, '', '{}', ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(oldXmp), .text(oldPath), .text(oldBackup)])

        let newPath = (dir as NSString).appendingPathComponent("_rejects/IMG_1-2.CR3")
        try AssetRepo(connection: db).relocatePhotoPathsAfterMove(
            photoId: photoId, oldPhotoPath: oldPath, newPhotoPath: newPath,
            timestamp: "2026-10-28T00:00:00.000Z")

        let newXmp = TSPath.xmpSidecarPath(newPath)
        let expectedBackup = newXmp + ".gather-backup-abc"
        let row = try #require(try db.prepare(
            "SELECT xmp_path, backup_path FROM deliveries").get([]))
        #expect(row[0].textValue == TSPath.normalize(newXmp))
        #expect(row[1].textValue == TSPath.normalize(expectedBackup),
                "备份必须改成新 xmp 的同目录兄弟名，否则回放判 invalidBackup")
    }

    @Test("没有 deliveries 行时 delivery_intents 仍随移出迁移（无 FK 兜底回放）")
    func relocationMigratesIntentsWithoutDeliveryRow() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let oldPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        let newPath = (dir as NSString).appendingPathComponent("_rejects/IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: oldPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: oldPath)
        let oldXmp = TSPath.xmpSidecarPath(oldPath)
        let newXmp = TSPath.xmpSidecarPath(newPath)
        // cleanup 删掉 deliveries 行后 intent 仍存活（刻意无 FK）：淘汰移出也必须迁它。
        _ = try db.prepare("""
            INSERT INTO delivery_intents (kind, xmp_path, phase, payload_json, error_message, created_at, updated_at)
            VALUES ('cleanup', ?, 'prepared', '{}', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(oldXmp)])

        try AssetRepo(connection: db).relocatePhotoPathsAfterMove(
            photoId: photoId, oldPhotoPath: oldPath, newPhotoPath: newPath,
            timestamp: "2026-10-28T00:00:00.000Z")

        let row = try #require(try db.prepare(
            "SELECT xmp_path FROM delivery_intents").get([]))
        #expect(row[0].textValue == TSPath.normalize(newXmp),
                "没有 deliveries 行时 intent 仍必须迁到新路径")
    }

    @Test("移出：交付备份文件跟着改名换目录（回放要求同目录兄弟）")
    func rejectedMoveCarriesBackup() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let photoPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photoPath))
        let sidecarPath = TSPath.xmpSidecarPath(photoPath)
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecarPath))
        let backupPath = sidecarPath + ".gather-backup-abc"
        try Data("<backup/>".utf8).write(to: URL(fileURLWithPath: backupPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)
        try insertAssetFile(db, id: "f-1", normalizedPath: photoPath)
        _ = try db.prepare("UPDATE photos SET asset_file_id = ? WHERE id = ?")
            .run([.text("f-1"), .text(photoId)])
        // 逼出 -2 改名：_rejects 里已有同名照片。
        let destination = (dir as NSString).appendingPathComponent("_rejects")
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(
            to: URL(fileURLWithPath: (destination as NSString).appendingPathComponent("IMG_1.CR3")))

        let mover = RejectedMover(
            photoRepo: PhotoRepo(connection: db),
            relocate: { id, old, new in
                try AssetRepo(connection: db).relocatePhotoPathsAfterMove(
                    photoId: id, oldPhotoPath: old, newPhotoPath: new,
                    timestamp: "2026-10-28T00:00:00.000Z")
            })
        let result = mover.move(photos: [(photoId, photoPath)], destinationRoot: destination)
        #expect(result.failed.isEmpty)
        let newPath = try #require(result.newPaths.first)
        #expect(newPath.hasSuffix("IMG_1-2.CR3"))
        let newXmp = TSPath.xmpSidecarPath(newPath)
        #expect(FileManager.default.fileExists(atPath: newXmp))
        #expect(FileManager.default.fileExists(atPath: newXmp + ".gather-backup-abc"),
                "备份必须改名换目录到新 xmp 旁边")
        #expect(!FileManager.default.fileExists(atPath: backupPath), "旧备份不得留在原目录")
    }

    @Test("大写 .XMP 的备份也能随之改名换目录（大小写不敏感匹配）")
    func movesUppercaseBackup() throws {
        let db = try makeTestDB()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1", photoId = "p-1"
        try insertSession(db, sessionId)
        let photoPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photoPath))
        // 盘上侧车与备份用大写扩展名（外部工具/历史数据常见）。
        let upperSidecar = (dir as NSString).appendingPathComponent("IMG_1.XMP")
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: upperSidecar))
        let upperBackup = upperSidecar + ".gather-backup-AbC"
        try Data("<backup/>".utf8).write(to: URL(fileURLWithPath: upperBackup))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)

        let destination = (dir as NSString).appendingPathComponent("_rejects")
        let mover = RejectedMover(photoRepo: PhotoRepo(connection: db))
        let result = mover.move(photos: [(photoId, photoPath)], destinationRoot: destination)
        #expect(result.failed.isEmpty)
        let newPath = try #require(result.newPaths.first)
        let newXmp = TSPath.xmpSidecarPath(newPath)
        #expect(FileManager.default.fileExists(atPath: newXmp + ".gather-backup-AbC"),
                "大写 .XMP 的备份必须按同后缀搬到新名前缀下")
        #expect(!FileManager.default.fileExists(atPath: upperBackup))
    }

    @Test("同名淘汰件已存在：加序号，绝不覆盖")
    func neverOverwritesExistingReject() throws {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-reject-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionId = "s-1"
        let photoId = "p-1"
        try insertSession(db, sessionId)
        let photoPath = (dir as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("raw".utf8).write(to: URL(fileURLWithPath: photoPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)
        let destination = (dir as NSString).appendingPathComponent("_rejects")
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let existing = (destination as NSString).appendingPathComponent("IMG_1.CR3")
        try Data("old-reject".utf8).write(to: URL(fileURLWithPath: existing))

        let mover = RejectedMover(photoRepo: PhotoRepo(connection: db))
        let result = mover.move(photos: [(photoId, photoPath)], destinationRoot: destination)
        #expect(result.failed.isEmpty)
        #expect(result.newPaths[0].hasSuffix("IMG_1-2.CR3"))
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "old-reject")
    }
}
