// desktop/native/gather-core/Tests/GatherCoreTests/FileOps/PhotoFileOpsServiceTests.swift
// Wave5（Batch4 / task-19）：批量重命名 + 移动到文件夹的行为测试（服务层）。
//
// 覆盖：
// 1. 模板 token 校验（未知/未闭合/宽度）与路径安全（改名不是移动）；
// 2. 预览：token 渲染、扩展名保留、targetExists / duplicateTarget / missingSource /
//    notInSession 四类冲突；
// 3. 重命名执行：磁盘改名 + 同名 xmp 一起改 + photos.filepath 更新；冲突策略
//    skip / coexist / replace；撞名不覆盖同批照片；
// 4. 组回滚：共享 sidecar 的兄弟组里任一成员失败 → 整组文件与库路径回滚，
//    失败逐项上报（不静默半成功）；
// 5. 移动：库内路径 + sidecar 一起走；RAW/JPEG 配对一起移动只留一份 sidecar；
//    兄弟留在原地的移动只复制 sidecar；非法目标目录显式拒绝。
//
// 边界：用真实临时目录（FileManager 不注入），relocate 闭包可注入以模拟宿主事务失败。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

private enum FileOpsTestError: Error { case relocationFailed }

/// 夹具：内存库 + 真实临时目录 + 可注入 relocate 的服务。
private struct FileOpsFixture {
    let db: DBConnection
    let root: String
    let service: PhotoFileOpsService
    let sessionId = "s1"

    init(relocate: PhotoFileOpsService.Relocate? = nil) throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        self.db = db
        self.root = try makeTempDir(prefix: "gather-fileops")
        self.service = PhotoFileOpsService(
            photoRepo: PhotoRepo(connection: db),
            relocate: relocate,
            captureMetadata: { _ in
                PhotoCaptureMetadata(
                    date: Date(timeIntervalSince1970: 1_700_000_000),
                    cameraModel: "TestCam")
            })
    }

    /// 写真实文件 + 登记 photos 行；返回绝对路径。
    @discardableResult
    func addPhoto(
        _ id: String, name: String, checksum: String = "", directory: String? = nil
    ) throws -> String {
        let target = directory ?? root
        let path = try writeTempFile(in: target, name: name, content: Data("photo-\(name)".utf8))
        try insertPhoto(db, id: id, sessionId: sessionId, filepath: path, checksum: checksum)
        return path
    }

    func addSidecar(for path: String) throws -> String {
        let sidecar = TSPath.xmpSidecarPath(path)
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecar))
        return sidecar
    }

    func storedPath(_ photoId: String) throws -> String? {
        try PhotoRepo(connection: db).getLookupByIds([photoId]).first?.filepath
    }

    func item(_ preview: PhotoRenamePreview, _ photoId: String) throws -> PhotoRenamePreviewItem {
        try #require(preview.items.first { $0.photoId == photoId })
    }
}

@Suite("Wave5 批量重命名 token / 预览（task-19）")
struct PhotoFileOpsRenamePreviewTests {
    @Test("模板 token 校验：未知 token、{seq:} 空宽度、未闭合 { 都算非法")
    func validatesTemplateTokens() {
        #expect(PhotoFileOpsService.invalidTokens(in: "{yyyy}{MM}{dd}_{orig}_{seq:4}.{ext}").isEmpty)
        #expect(PhotoFileOpsService.invalidTokens(in: "{bogus}") == ["{bogus}"])
        #expect(PhotoFileOpsService.invalidTokens(in: "{seq:}") == ["{seq:}"])
        #expect(PhotoFileOpsService.invalidTokens(in: "{YYYY}") == ["{YYYY}"], "token 区分大小写")
        #expect(PhotoFileOpsService.invalidTokens(in: "{yyyy") == ["{yyyy"], "未闭合也要拦")
        #expect(PhotoFileOpsService.invalidTokens(in: "{camera}-{seq:2}").isEmpty)
    }

    @Test("模板路径安全：包含 / \\ 或 : 的模板整批拒绝（改名不是移动）")
    func rejectsUnsafeTemplates() async throws {
        let fx = try FileOpsFixture()
        try fx.addPhoto("p1", name: "a.jpg")
        #expect(PhotoFileOpsService.isPathSafeTemplate("{yyyy}/{MM}/{orig}.{ext}") == false)
        let preview = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "{yyyy}/{orig}.{ext}"))
        #expect(preview.invalidTokens.contains("<路径分隔符>"))
        await #expect(throws: GatherError.self) {
            _ = try await fx.service.renamePhotos(PhotoRenameInput(
                sessionId: fx.sessionId, photoIds: ["p1"], template: "{yyyy}/{orig}.{ext}"))
        }
    }

    @Test("预览：按 token 渲染、保留原扩展名、序号按输入顺序")
    func rendersTokensAndKeepsExtension() async throws {
        let fx = try FileOpsFixture()
        try fx.addPhoto("p1", name: "a.jpg")
        try fx.addPhoto("p2", name: "b.CR3")
        let preview = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1", "p2"],
            template: "{orig}-{camera}-{seq:4}.{ext}"))
        #expect(preview.invalidTokens.isEmpty)
        #expect(preview.conflicts == 0)
        #expect(preview.renameable == 2)
        #expect(try fx.item(preview, "p1").newFilename == "a-TestCam-0001.jpg")
        #expect(try fx.item(preview, "p2").newFilename == "b-TestCam-0002.CR3")
    }

    @Test("模板没写 {ext}：自动保留原扩展名；写了不同扩展名 → invalidToken")
    func keepsOrRejectsExtension() async throws {
        let fx = try FileOpsFixture()
        try fx.addPhoto("p1", name: "a.jpg")
        let kept = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "{orig}_new"))
        #expect(try fx.item(kept, "p1").newFilename == "a_new.jpg")
        let rejected = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "{orig}.png"))
        #expect(try fx.item(rejected, "p1").conflict == .invalidToken)
    }

    @Test("预览冲突分类：targetExists / duplicateTarget / missingSource / 不属于工作区")
    func classifiesConflicts() async throws {
        let fx = try FileOpsFixture()
        try fx.addPhoto("p1", name: "a.jpg")
        let p2 = try fx.addPhoto("p2", name: "b.jpg")
        // 目标已存在（磁盘上的其它文件）。
        _ = try writeTempFile(in: fx.root, name: "a-hit.jpg")
        let targetExists = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "{orig}-hit.{ext}"))
        #expect(try fx.item(targetExists, "p1").conflict == .targetExists)
        // 同批撞目标：模板缺区分项。
        let duplicates = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1", "p2"], template: "{camera}.{ext}"))
        #expect(try fx.item(duplicates, "p1").conflict == .duplicateTarget)
        #expect(try fx.item(duplicates, "p2").conflict == .duplicateTarget)
        // 源文件被删。
        try FileManager.default.removeItem(atPath: p2)
        let missing = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1", "p2"], template: "{orig}.{ext}"))
        #expect(try fx.item(missing, "p2").conflict == .missingSource)
        // 跨会话 photoId。
        let other = try await fx.service.previewRename(PhotoRenamePreviewInput(
            sessionId: "other", photoIds: ["p1"], template: "{orig}.{ext}"))
        #expect(other.items.first?.conflict == .notInSession)
    }

    @Test("空模板 / 超过单批上限：显式 INVALID_PARAM（不静默改默认值）")
    func rejectsEmptyOrOversizedBatch() async throws {
        let fx = try FileOpsFixture()
        try fx.addPhoto("p1", name: "a.jpg")
        await #expect(throws: GatherError.self) {
            _ = try await fx.service.previewRename(PhotoRenamePreviewInput(
                sessionId: fx.sessionId, photoIds: ["p1"], template: "   "))
        }
        let tooMany = (0...PhotoFileOpsService.maxItems).map { "p\($0)" }
        await #expect(throws: GatherError.self) {
            _ = try await fx.service.movePhotos(PhotoMoveInput(
                sessionId: fx.sessionId, photoIds: tooMany, destinationRoot: fx.root))
        }
    }
}

@Suite("Wave5 批量重命名执行（task-19）")
struct PhotoFileOpsRenameExecuteTests {
    @Test("改名：磁盘文件名 + 同名 XMP 一起改，photos.filepath 同步")
    func renamesFileAndSidecar() async throws {
        let fx = try FileOpsFixture()
        let oldPath = try fx.addPhoto("p1", name: "IMG_0001.CR3")
        let sidecar = try fx.addSidecar(for: oldPath)
        let result = try await fx.service.renamePhotos(PhotoRenameInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "{camera}_{seq:3}.{ext}"))
        #expect(result.failed.isEmpty)
        #expect(result.renamed == 1)
        let newPath = try #require(result.newPaths["p1"])
        #expect((newPath as NSString).lastPathComponent == "TestCam_001.CR3")
        #expect(FileManager.default.fileExists(atPath: newPath))
        #expect(!FileManager.default.fileExists(atPath: oldPath))
        #expect(!FileManager.default.fileExists(atPath: sidecar), "旧 sidecar 不得留在原目录")
        #expect(FileManager.default.fileExists(atPath: TSPath.xmpSidecarPath(newPath)))
        #expect(try fx.storedPath("p1") == newPath)
    }

    @Test("冲突策略 skip / coexist / replace：不静默覆盖")
    func appliesConflictPolicies() async throws {
        let fx = try FileOpsFixture()
        _ = try fx.addPhoto("p1", name: "a.jpg")
        let blocker = try writeTempFile(in: fx.root, name: "a-x.jpg", content: Data("x".utf8))
        let template = "{orig}-x.{ext}"

        let skipped = try await fx.service.renamePhotos(PhotoRenameInput(
            sessionId: fx.sessionId, photoIds: ["p1"],
            template: template, conflictPolicy: .skip))
        #expect(skipped.skipped == 1)
        #expect(skipped.renamed == 0)
        #expect(try fx.storedPath("p1") == fx.root + "/a.jpg", "skip 不动库路径")

        let coexisted = try await fx.service.renamePhotos(PhotoRenameInput(
            sessionId: fx.sessionId, photoIds: ["p1"],
            template: template, conflictPolicy: .coexist))
        #expect(coexisted.renamed == 1)
        let coexistedPath = try #require(coexisted.newPaths["p1"])
        #expect((coexistedPath as NSString).lastPathComponent == "a-x-2.jpg")
        #expect(FileManager.default.fileExists(atPath: blocker), "既有文件不被覆盖")
    }

    @Test("replace：先备份既有目标，成功后删除备份；不覆盖同批照片")
    func replacesWithBackup() async throws {
        let fx = try FileOpsFixture()
        _ = try fx.addPhoto("p1", name: "a.jpg")
        _ = try writeTempFile(in: fx.root, name: "a-x.jpg", content: Data("old".utf8))
        let result = try await fx.service.renamePhotos(PhotoRenameInput(
            sessionId: fx.sessionId, photoIds: ["p1"],
            template: "{orig}-x.{ext}", conflictPolicy: .replace))
        #expect(result.renamed == 1)
        let target = fx.root + "/a-x.jpg"
        #expect(FileManager.default.fileExists(atPath: target))
        let backups = try FileManager.default.contentsOfDirectory(atPath: fx.root)
            .filter { $0.contains(".gather-replaced-") }
        #expect(backups.isEmpty, "成功后不留替换备份")
    }

    @Test("共享 sidecar 的兄弟组：任一成员回滚 → 整组文件与库路径回滚")
    func rollsBackSharedSidecarGroup() async throws {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        let root = try makeTempDir(prefix: "gather-fileops-rollback")
        let repo = PhotoRepo(connection: db)
        var relocations: [String] = []
        let service = PhotoFileOpsService(
            photoRepo: repo,
            relocate: { photoId, oldPath, newPath, _ in
                relocations.append(photoId)
                if photoId == "p2" { throw FileOpsTestError.relocationFailed }
                try repo.updateFilepath(photoId: photoId, filepath: newPath)
            },
            captureMetadata: { _ in PhotoCaptureMetadata(cameraModel: "TestCam") })
        let raw = try writeTempFile(in: root, name: "a.CR3", content: Data("raw".utf8))
        let jpeg = try writeTempFile(in: root, name: "a.jpg", content: Data("jpg".utf8))
        let sidecar = TSPath.xmpSidecarPath(raw)
        try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: sidecar))
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: raw)
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: jpeg)

        let result = try await service.renamePhotos(PhotoRenameInput(
            sessionId: "s1", photoIds: ["p1", "p2"], template: "{orig}-{seq:2}.{ext}"))
        #expect(result.renamed == 0)
        #expect(result.failed.count == 2)
        // 文件层面整组回滚：旧文件与旧 sidecar 都在，没有半截新名。
        #expect(FileManager.default.fileExists(atPath: raw))
        #expect(FileManager.default.fileExists(atPath: jpeg))
        #expect(FileManager.default.fileExists(atPath: sidecar))
        let entries = try FileManager.default.contentsOfDirectory(atPath: root)
        #expect(!entries.contains { $0.contains("-01.") || $0.contains("-02.") })
        // 库路径：已提交的 p1 也回滚到旧路径。
        let paths = try repo.getLookupByIds(["p1", "p2"])
        #expect(paths.first { $0.id == "p1" }?.filepath == raw)
        #expect(paths.first { $0.id == "p2" }?.filepath == jpeg)
        #expect(relocations.contains("p1") && relocations.contains("p2"))
    }

    @Test("渲染结果与原路径相同：记 skipped（不是失败）")
    func identicalTargetIsSkipped() async throws {
        let fx = try FileOpsFixture()
        _ = try fx.addPhoto("p1", name: "a.jpg")
        let result = try await fx.service.renamePhotos(PhotoRenameInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "{orig}.{ext}"))
        #expect(result.renamed == 0)
        #expect(result.skipped == 1)
        #expect(result.failed.isEmpty)
    }
}

@Suite("Wave5 移动到文件夹（task-19）")
struct PhotoFileOpsMoveTests {
    @Test("移动：照片 + 同名 XMP 到目标目录，photos.filepath 同步")
    func movesPhotoAndSidecar() async throws {
        let fx = try FileOpsFixture()
        let oldPath = try fx.addPhoto("p1", name: "IMG_1.CR3")
        _ = try fx.addSidecar(for: oldPath)
        let destination = try makeTempDir(prefix: "gather-fileops-dst")
        let result = try await fx.service.movePhotos(PhotoMoveInput(
            sessionId: fx.sessionId, photoIds: ["p1"], destinationRoot: destination))
        #expect(result.failed.isEmpty)
        #expect(result.moved == 1)
        let newPath = try #require(result.newPaths["p1"])
        #expect(newPath == destination + "/IMG_1.CR3")
        #expect(!FileManager.default.fileExists(atPath: oldPath))
        #expect(FileManager.default.fileExists(atPath: newPath))
        #expect(FileManager.default.fileExists(atPath: destination + "/IMG_1.xmp"))
        #expect(!FileManager.default.fileExists(atPath: oldPath + ".xmp"))
        #expect(try fx.storedPath("p1") == newPath)
    }

    @Test("RAW/JPEG 配对一起移动：只留一份 sidecar")
    func movesPairWithSingleSidecar() async throws {
        let fx = try FileOpsFixture()
        let raw = try fx.addPhoto("p1", name: "a.CR3")
        _ = try fx.addPhoto("p2", name: "a.jpg")
        _ = try fx.addSidecar(for: raw)
        let destination = try makeTempDir(prefix: "gather-fileops-pair")
        let result = try await fx.service.movePhotos(PhotoMoveInput(
            sessionId: fx.sessionId, photoIds: ["p1", "p2"], destinationRoot: destination))
        #expect(result.moved == 2)
        #expect(result.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination + "/a.CR3"))
        #expect(FileManager.default.fileExists(atPath: destination + "/a.jpg"))
        #expect(FileManager.default.fileExists(atPath: destination + "/a.xmp"))
        #expect(!FileManager.default.fileExists(atPath: raw + ".xmp"), "旧 sidecar 应被搬走")
    }

    @Test("兄弟留在原地：移动只复制 sidecar，旧 xmp 保留给兄弟")
    func copiesSidecarWhenSiblingRemains() async throws {
        let fx = try FileOpsFixture()
        let raw = try fx.addPhoto("p1", name: "a.CR3")
        _ = try fx.addPhoto("p2", name: "a.jpg")
        let sidecar = try fx.addSidecar(for: raw)
        let destination = try makeTempDir(prefix: "gather-fileops-sibling")
        let result = try await fx.service.movePhotos(PhotoMoveInput(
            sessionId: fx.sessionId, photoIds: ["p1"], destinationRoot: destination))
        #expect(result.moved == 1)
        #expect(FileManager.default.fileExists(atPath: sidecar), "兄弟仍要读旧 xmp")
        #expect(FileManager.default.fileExists(atPath: destination + "/a.xmp"))
    }

    @Test("目标目录校验：相对路径 / 禁根 / 不存在都显式 INVALID_PARAM")
    func validatesDestination() async throws {
        let fx = try FileOpsFixture()
        _ = try fx.addPhoto("p1", name: "a.jpg")
        for bad in ["relative/dir", "/", fx.root + "/not-exists"] {
            await #expect(throws: GatherError.self) {
                _ = try await fx.service.movePhotos(PhotoMoveInput(
                    sessionId: fx.sessionId, photoIds: ["p1"], destinationRoot: bad))
            }
        }
    }


    @Test("同批内部撞名（不同源目录同名）：失败项，不互相覆盖")
    func rejectsBatchInternalMoveCollision() async throws {
        let fx = try FileOpsFixture()
        let sub = (fx.root as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(
            atPath: sub, withIntermediateDirectories: true)
        _ = try fx.addPhoto("p1", name: "a.jpg")
        _ = try fx.addPhoto("p2", name: "a.jpg", directory: sub)
        let destination = try makeTempDir(prefix: "gather-fileops-batch")
        let result = try await fx.service.movePhotos(PhotoMoveInput(
            sessionId: fx.sessionId, photoIds: ["p1", "p2"],
            destinationRoot: destination, conflictPolicy: .replace))
        #expect(result.failed.count == 1, "第二条必须失败，不能被 replace 覆盖")
        #expect(result.moved == 1)
        #expect(FileManager.default.fileExists(atPath: destination + "/a.jpg"))
    }

    @Test("replace 目标带 sidecar：一起备份，成功后不残留")
    func replacesTargetSidecarWithBackup() async throws {
        let fx = try FileOpsFixture()
        _ = try fx.addPhoto("p1", name: "a.jpg")
        let target = try writeTempFile(in: fx.root, name: "a-x.jpg", content: Data("old".utf8))
        try Data("<old/>".utf8).write(to: URL(fileURLWithPath: TSPath.xmpSidecarPath(target)))
        let result = try await fx.service.renamePhotos(PhotoRenameInput(
            sessionId: fx.sessionId, photoIds: ["p1"],
            template: "{orig}-x.{ext}", conflictPolicy: .replace))
        #expect(result.renamed == 1)
        #expect(FileManager.default.fileExists(atPath: target))
        let entries = try FileManager.default.contentsOfDirectory(atPath: fx.root)
        #expect(!entries.contains { $0.contains(".gather-replaced-") }, "成功后不留备份")
    }

    @Test("移动到同名文件已存在的目录：skip 不动、coexist 加序号")
    func resolvesMoveConflicts() async throws {
        let fx = try FileOpsFixture()
        _ = try fx.addPhoto("p1", name: "a.jpg")
        let destination = try makeTempDir(prefix: "gather-fileops-conflict")
        _ = try writeTempFile(in: destination, name: "a.jpg", content: Data("x".utf8))
        let skipped = try await fx.service.movePhotos(PhotoMoveInput(
            sessionId: fx.sessionId, photoIds: ["p1"],
            destinationRoot: destination, conflictPolicy: .skip))
        #expect(skipped.skipped == 1)
        #expect(skipped.moved == 0)
        #expect(FileManager.default.fileExists(atPath: fx.root + "/a.jpg"))

        let coexisted = try await fx.service.movePhotos(PhotoMoveInput(
            sessionId: fx.sessionId, photoIds: ["p1"],
            destinationRoot: destination, conflictPolicy: .coexist))
        #expect(coexisted.moved == 1)
        let coexistedPath = try #require(coexisted.newPaths["p1"])
        #expect((coexistedPath as NSString).lastPathComponent == "a-2.jpg")
    }
}
