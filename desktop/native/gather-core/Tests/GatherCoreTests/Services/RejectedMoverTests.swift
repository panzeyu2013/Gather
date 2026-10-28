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

    @Test("目标路径已登记：不覆盖目标行，photos 仍迁移（下一轮扫描重连）")
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

        try AssetRepo(connection: db).relocatePhotoPathsAfterMove(
            photoId: photoId, oldPhotoPath: oldPath, newPhotoPath: newPath,
            timestamp: "2026-10-28T00:00:00.000Z")

        let rows = try db.prepare(
            "SELECT id, normalized_path FROM asset_files ORDER BY id").query([])
        #expect(rows.count == 2, "不得合并/删除目标行")
        #expect(rows[1][1].textValue == TSPath.normalize(newPath), "目标行原样保留")
        #expect(rows[0][1].textValue == TSPath.normalize(oldPath), "旧行不改（等待扫描重连）")
        let photoRow = try #require(try db.prepare(
            "SELECT filepath FROM photos WHERE id = ?").get([.text(photoId)]))
        #expect(photoRow[0].textValue == newPath)
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
        try db.prepare("""
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
