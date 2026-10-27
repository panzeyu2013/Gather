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
