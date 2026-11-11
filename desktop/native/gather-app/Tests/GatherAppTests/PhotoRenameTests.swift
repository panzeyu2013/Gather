// desktop/native/gather-app/Tests/GatherAppTests/PhotoRenameTests.swift
// Wave5（Batch4 / task-19）：批量重命名 / 移动到文件夹的 UI 纯逻辑 + Live 接线测试。
//
// 覆盖：
// 1. 冲突策略 / 冲突分类的中文文案映射；
// 2. 重命名 sheet 的执行门禁（PhotoRenameSheet.canSubmit 纯函数）；
// 3. LivePhotoAPI 三个新方法经组合根接线走通（真实 PhotoFileOpsService +
//    AssetRepo 事务化 relocate）：预览 → Confirmed 改名 → 磁盘/库路径/sidecar 一致；
// 4. 移动：目标目录 + 域事件前置条件（路径更新进库）。
//
// 夹具：内存 SQLite + 真实临时目录；破坏性入口一律显式 Confirmed<T>（D-011）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

// MARK: - 夹具

/// 直接组装 LivePhotoAPI（与 FeatureAPIs.makePhoto 同形；fileOps 走 init 默认实现）。
private struct PhotoFileOpsAPIFixture {
    let db: DBConnection
    let api: LivePhotoAPI
    let sessionId = "s1"
    let root: String

    init() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let faceRepo = FaceRepo(connection: db)
        let personRepo = PersonRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        self.db = db
        self.root = try makeTempDir(prefix: "gather-photo-rename")
        self.api = LivePhotoAPI(
            photoRepo: photoRepo,
            assetRepo: AssetRepo(connection: db),
            faceKwService: FaceKwService(
                photoRepo: photoRepo,
                sessionRepo: sessionRepo,
                faceRepo: faceRepo,
                personRepo: personRepo,
                connection: db),
            filterEngine: FilterEngine(connection: db),
            imagePreloadService: ImagePreloadService(),
            settingsService: settingsService,
            jobAPI: LiveJobAPI(jobService: jobService))
    }

    /// 登记会话 + 真实文件（可带同名 xmp）。
    func addSessionAndPhoto(
        id: String = "p1", name: String = "IMG_1.CR3", withSidecar: Bool = false
    ) throws -> String {
        try insertSession(db, sessionId)
        let path = try writeTempFile(in: root, name: name, content: Data("photo".utf8))
        try insertPhoto(db, id: id, sessionId: sessionId, filepath: path)
        _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = ?")
            .run([.text(root), .text(sessionId)])
        if withSidecar {
            try Data("<xmp/>".utf8).write(to: URL(fileURLWithPath: TSPath.xmpSidecarPath(path)))
        }
        return path
    }

    func storedPath(_ photoId: String) throws -> String? {
        try PhotoRepo(connection: db).getLookupByIds([photoId]).first?.filepath
    }
}

// MARK: - 文案 / 纯逻辑

@Suite("Wave5 批量重命名 UI 文案与门禁（task-19）")
struct PhotoRenameUIPureLogicTests {
    private var l10n: L10n { L10n(language: .zhCN) }

    @Test("冲突策略文案：skip / replace / coexist 各自可读")
    func policyLabels() {
        #expect(photoFilePolicyLabel(.skip, l10n: l10n) == "跳过冲突项")
        #expect(photoFilePolicyLabel(.replace, l10n: l10n) == "覆盖目标（先备份）")
        #expect(photoFilePolicyLabel(.coexist, l10n: l10n) == "自动加序号")
    }

    @Test("冲突分类文案：六种分类都有中文（不暴露裸枚举）")
    func conflictLabels() {
        for conflict in PhotoRenameConflict.allCases {
            let label = photoRenameConflictLabel(conflict, l10n: l10n)
            #expect(!label.isEmpty)
            #expect(label != conflict.rawValue, "不得回落裸枚举值")
        }
    }

    @Test("执行门禁：无预览 / 未接线 / 有非法 token / 无可改名项都禁用")
    func submitGate() {
        #expect(!PhotoRenameSheet.canSubmit(preview: nil, isSubmitting: false))
        let unavailable = PhotoRenamePreview(
            sessionId: "s1", unavailableReason: "未接线")
        #expect(!PhotoRenameSheet.canSubmit(preview: unavailable, isSubmitting: false))
        let brokenTemplate = PhotoRenamePreview(
            sessionId: "s1", invalidTokens: ["{bogus}"], renameable: 3)
        #expect(!PhotoRenameSheet.canSubmit(preview: brokenTemplate, isSubmitting: false))
        let nothingToDo = PhotoRenamePreview(sessionId: "s1", renameable: 0)
        #expect(!PhotoRenameSheet.canSubmit(preview: nothingToDo, isSubmitting: false))
        let ready = PhotoRenamePreview(sessionId: "s1", renameable: 2)
        #expect(PhotoRenameSheet.canSubmit(preview: ready, isSubmitting: false))
        #expect(!PhotoRenameSheet.canSubmit(preview: ready, isSubmitting: true))
    }

    @Test("延迟动作 id：同一选择集稳定、不同集合可区分")
    func pendingIdentifiers() {
        #expect(PendingPhotoRename(photoIds: ["a", "b"]).id
            == PendingPhotoRename(photoIds: ["a", "b"]).id)
        #expect(PendingPhotoMove(photoIds: ["a"]).id != PendingPhotoMove(photoIds: ["b"]).id)
    }
}

// MARK: - Live 接线

@Suite("Wave5 批量重命名/移动 Live 接线（task-19）")
struct PhotoFileOpsLiveAPITests {
    @Test("previewRename → renamePhotos：磁盘改名 + sidecar + photos.filepath 一致")
    func liveRenameThroughAPI() async throws {
        let fx = try PhotoFileOpsAPIFixture()
        let oldPath = try fx.addSessionAndPhoto(name: "IMG_1.CR3", withSidecar: true)
        let preview = try await fx.api.previewRename(PhotoRenamePreviewInput(
            sessionId: fx.sessionId, photoIds: ["p1"], template: "A_{seq:3}.{ext}"))
        #expect(preview.unavailableReason == nil)
        #expect(preview.renameable == 1)
        let result = try await fx.api.renamePhotos(Confirmed(
            PhotoRenameInput(
                sessionId: fx.sessionId, photoIds: ["p1"],
                template: "A_{seq:3}.{ext}"),
            source: .test))
        #expect(result.failed.isEmpty)
        #expect(result.renamed == 1)
        let newPath = try #require(result.newPaths["p1"])
        #expect((newPath as NSString).lastPathComponent == "A_001.CR3")
        #expect(!FileManager.default.fileExists(atPath: oldPath))
        #expect(FileManager.default.fileExists(atPath: TSPath.xmpSidecarPath(newPath)))
        #expect(try fx.storedPath("p1") == newPath)
    }

    @Test("movePhotos：照片移入目标目录并更新库路径（relocate 事务接线）")
    func liveMoveThroughAPI() async throws {
        let fx = try PhotoFileOpsAPIFixture()
        let oldPath = try fx.addSessionAndPhoto(name: "IMG_1.CR3", withSidecar: true)
        let destination = try makeTempDir(prefix: "gather-photo-move")
        let result = try await fx.api.movePhotos(Confirmed(
            PhotoMoveInput(
                sessionId: fx.sessionId, photoIds: ["p1"],
                destinationRoot: destination),
            source: .test))
        #expect(result.failed.isEmpty)
        #expect(result.moved == 1)
        let newPath = try #require(result.newPaths["p1"])
        #expect(newPath == destination + "/IMG_1.CR3")
        #expect(!FileManager.default.fileExists(atPath: oldPath))
        #expect(FileManager.default.fileExists(atPath: destination + "/IMG_1.xmp"))
        #expect(try fx.storedPath("p1") == newPath)
    }

    @Test("非法模板/非法目标经 API 边界显式报错（不静默成功）")
    func liveRejectsInvalidInputs() async throws {
        let fx = try PhotoFileOpsAPIFixture()
        _ = try fx.addSessionAndPhoto()
        await #expect(throws: GatherError.self) {
            _ = try await fx.api.renamePhotos(Confirmed(
                PhotoRenameInput(
                    sessionId: fx.sessionId, photoIds: ["p1"], template: "{bogus}.{ext}"),
                source: .test))
        }
        await #expect(throws: GatherError.self) {
            _ = try await fx.api.movePhotos(Confirmed(
                PhotoMoveInput(
                    sessionId: fx.sessionId, photoIds: ["p1"],
                    destinationRoot: "relative"),
                source: .test))
        }
    }
}
