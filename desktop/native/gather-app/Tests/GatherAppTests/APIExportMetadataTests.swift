// desktop/native/gather-app/Tests/GatherAppTests/APIExportMetadataTests.swift
// Cut 1 / B6a：LiveExportAPI（4 方法）与 LiveMetadataAPI（7 方法）的行为测试。
//
// 覆盖：
// - export：preview 走 ExportService.outputPlan 且不创建 job；缺省 options 与
//   相对目标目录的错误码（EXPORT_PARAMS_INVALID / EXPORT_DIR_ABSOLUTE_REQUIRED）；
//   execute 的 JobService 建单（dedupeKey/checkpoint 与旧命令面 逐字一致）、
//   活跃 job 去重、不同交付指纹生成不同任务；cancel 的 job scope 取消；
//   report 的 md/csv 形状；
// - metadata：get 的缓存命中与缺失 ID 过滤；set/batchSet 的 Confirmed<T> 边界
//   与写入；conflicts 的交付派生字段投影与 resolveConflict 的 use_remote 结清 /
//   keep_local 重排；orphans 与 resolveOrphan 的 keep/restore/retry；
//   参数错误与无记录错误；
// - P0-1 第二入口：resolveOrphan(restore) 的复核→restore→事后复核持有
//   组合根注入的同一个 XMPFileLock，与 writeback 并发时旧备份不覆盖新内容且不嵌套自锁。
//
// 夹具用内存 SQLite + 真实 ExportService / MetadataService / DeliveryRepo /
// JobService；exportExecute 执行器用 stub 替换（真实导出需要文件复制与转码，
// 本批只断言 API 边界的 job 形状与取消语义）。
// S5c-2b-3b-2b-2：冲突/孤儿夹具直接种 deliveries/delivery_items（不再构造
// MetadataSyncCoordinator，旧 metadata_outbox 表也不参与断言）。
// XMP 端口用内存假件，不触碰磁盘侧车。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

// MARK: - 通用辅助

private enum APIExportMetadataFixtureError: Error {
    case jobNotCreated
    case photoMissing
}

private func waitForJob(
    _ jobService: JobService,
    type: AnalysisJobType,
    timeout: TimeInterval = 2
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try jobService.list(includeCheckpoint: false).contains(where: { $0.type == type }) {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw APIExportMetadataFixtureError.jobNotCreated
}

private func gatherError<T>(_ body: () throws -> T) -> GatherError? {
    do {
        _ = try body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

private func asyncGatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

private func asyncError<T>(_ body: () async throws -> T) async -> Error? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

// MARK: - Export 夹具

private struct ExportAPIFixture {
    let db: DBConnection
    let sessionId: String
    let tempRoot: URL
    let exportService: ExportService
    let jobService: JobService
    let api: LiveExportAPI
    let photoIds: [String]
    let options: ExportOptions

    init(photoCount: Int = 2, jobGate: AsyncGate? = nil, pattern: String = "{original}") throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "B6a", source: "test")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-b6a-export-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let destinationDir = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var inputs: [PhotoAddInput] = []
        for index in 1...photoCount {
            let url = sourceDir.appendingPathComponent("IMG_\(index).jpg")
            try Data("photo-\(index)".utf8).write(to: url)
            inputs.append(PhotoAddInput(filepath: url.path, width: 100, height: 80))
        }
        let photoRepo = PhotoRepo(connection: db)
        let ids = try photoRepo.addPhotos(
            sessionId: session.id,
            filepaths: inputs,
            "test"
        ).ids

        let exportService = ExportService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            connection: db
        )
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let stubResult = ExportResult(
            totalFiles: photoCount,
            exported: photoCount,
            failed: 0,
            skipped: 0,
            errors: []
        )
        jobService.registerExecutor(type: .exportExecute) { _, _ in
            if let jobGate { await jobGate.wait() }
            return stubResult
        }
        jobService.start()

        self.db = db
        self.sessionId = session.id
        self.tempRoot = root
        self.exportService = exportService
        self.jobService = jobService
        self.api = LiveExportAPI(exportService: exportService, jobService: jobService)
        self.photoIds = ids
        self.options = ExportOptions(
            scope: .session,
            format: .original,
            naming: ExportNaming(pattern: pattern),
            includeXmp: false,
            destination: destinationDir.path
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

// MARK: - Export 用例

@Suite("APIExport Live")
struct APIExportTests {
    @Test("preview：走 outputPlan，返回逐项输出名，且不创建 job")
    func previewUsesOutputPlanWithoutCreatingJob() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }

        let preview = try await fixture.api.preview(
            ExportInput(sessionId: fixture.sessionId, options: fixture.options)
        )

        #expect(preview.photoCount == 2)
        #expect(preview.totalFiles == 2)
        #expect(preview.files.map(\.outputName) == ["IMG_1.jpg", "IMG_2.jpg"])
        #expect(try fixture.jobService.list().isEmpty)
    }

    @Test("preview：缺省 options 保留旧命令面 的 EXPORT_PARAMS_INVALID")
    func previewRejectsMissingOptions() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }

        let error = await asyncGatherError {
            try await fixture.api.preview(ExportInput(sessionId: fixture.sessionId))
        }
        #expect(error?.code == .EXPORT_PARAMS_INVALID)
        #expect(error?.params["field"] == "options")
        #expect(try fixture.jobService.list().isEmpty)
    }

    @Test("preview：相对目标目录由 ExportService 拒绝并收敛为 GatherError")
    func previewRejectsRelativeDestination() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }
        var options = fixture.options
        options.destination = "relative/output"

        let error = await asyncGatherError {
            try await fixture.api.preview(
                ExportInput(sessionId: fixture.sessionId, options: options)
            )
        }
        #expect(error?.code == .EXPORT_DIR_ABSOLUTE_REQUIRED)
    }

    @Test("execute：建 exportExecute job，dedupeKey/checkpoint 与旧命令面 一致")
    func executeCreatesJobWithFingerprint() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }
        let fingerprint = try fixture.exportService.deliveryFingerprint(
            sessionId: fixture.sessionId,
            options: fixture.options
        )

        let result = try await fixture.api.execute(
            Confirmed(
                try ExportInput(sessionId: fixture.sessionId, options: fixture.options),
                source: .test
            )
        )

        #expect(result.exported == 2)
        let job = try #require(
            try fixture.jobService.list().first { $0.type == .exportExecute }
        )
        #expect(job.scopeId == fixture.sessionId)
        #expect(job.dedupeKey == "export.execute:\(fixture.sessionId):\(fingerprint)")
        #expect(job.checkpoint["deliveryFingerprint"]?.stringValue == fingerprint)
        #expect(job.checkpoint["options"] == (try JSONValue(from: fixture.options)))
        #expect(job.status == .succeeded)
    }

    @Test("execute：相同指纹的活跃 job 复用，只建一条 job")
    func executeDedupesActiveJob() async throws {
        let gate = AsyncGate()
        let fixture = try ExportAPIFixture(jobGate: gate)
        defer {
            gate.release()
            fixture.cleanup()
        }
        let input = try ExportInput(sessionId: fixture.sessionId, options: fixture.options)
        let api = fixture.api

        let first = Task { try await api.execute(Confirmed(input, source: .test)) }
        try await waitForJob(fixture.jobService, type: .exportExecute)
        let second = Task { try await api.execute(Confirmed(input, source: .test)) }
        // 给第二个 Task 进入 jobService.create（拿到同一活跃 job）并阻塞在
        // waitForResult 的机会；门未放行前第一个 job 不会终态。
        try await Task.sleep(for: .milliseconds(500))
        gate.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(firstResult == secondResult)
        #expect(try fixture.jobService.list().filter { $0.type == .exportExecute }.count == 1)
    }

    @Test("execute：交付参数变化 → 新指纹 → 新建 job")
    func executeDifferentOptionsCreateNewJob() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }
        var otherOptions = fixture.options
        otherOptions.naming.pattern = "alt-{original}"

        let firstFingerprint = try fixture.exportService.deliveryFingerprint(
            sessionId: fixture.sessionId,
            options: fixture.options
        )
        let secondFingerprint = try fixture.exportService.deliveryFingerprint(
            sessionId: fixture.sessionId,
            options: otherOptions
        )
        #expect(firstFingerprint != secondFingerprint)

        _ = try await fixture.api.execute(
            Confirmed(
                try ExportInput(sessionId: fixture.sessionId, options: fixture.options),
                source: .test
            )
        )
        _ = try await fixture.api.execute(
            Confirmed(
                try ExportInput(sessionId: fixture.sessionId, options: otherOptions),
                source: .test
            )
        )

        let jobs = try fixture.jobService.list().filter { $0.type == .exportExecute }
        #expect(jobs.count == 2)
        #expect(Set(jobs.map(\.dedupeKey)).count == 2)
    }

    @Test("execute：缺省 options 拒绝，且不创建 job")
    func executeRejectsMissingOptions() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }

        let error = await asyncGatherError {
            try await fixture.api.execute(
                Confirmed(ExportInput(sessionId: fixture.sessionId), source: .test)
            )
        }
        #expect(error?.code == .EXPORT_PARAMS_INVALID)
        #expect(try fixture.jobService.list().isEmpty)
    }

    @Test("cancel：取消同会话 exportExecute job 与 ExportService 会话位")
    func cancelsActiveExportJob() async throws {
        let gate = AsyncGate()
        let fixture = try ExportAPIFixture(jobGate: gate)
        defer {
            gate.release()
            fixture.cleanup()
        }
        let input = try ExportInput(sessionId: fixture.sessionId, options: fixture.options)
        let api = fixture.api
        let running = Task { try await api.execute(Confirmed(input, source: .test)) }
        try await waitForJob(fixture.jobService, type: .exportExecute)

        let cancelled = try await api.cancel(fixture.sessionId)

        #expect(cancelled)
        let job = try #require(
            try fixture.jobService.list().first { $0.type == .exportExecute }
        )
        #expect(job.status == .cancelling || job.status == .cancelled)
        gate.release()
        _ = try? await running.value
    }

    @Test("cancel：空白 sessionId 抛 INVALID_PARAM")
    func cancelRejectsBlankSession() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }

        let error = await asyncGatherError {
            try await fixture.api.cancel("  ")
        }
        #expect(error?.code == .INVALID_PARAM)
        #expect(error?.params["field"] == "sessionId")
    }

    @Test("report：session_summary 的 md/csv 形状与格式映射")
    func reportGeneratesRequestedFormat() async throws {
        let fixture = try ExportAPIFixture()
        defer { fixture.cleanup() }

        let markdown = try await fixture.api.report(
            ExportReportInput(sessionId: fixture.sessionId, format: .md)
        )
        #expect(markdown.format == .md)
        #expect(markdown.content.contains("# Session summary"))
        #expect(markdown.content.contains("IMG_1.jpg"))

        let csv = try await fixture.api.report(
            ExportReportInput(sessionId: fixture.sessionId)
        )
        #expect(csv.format == .csv)
        #expect(csv.content.hasPrefix("filename,filepath,status"))
        #expect(try fixture.jobService.list().isEmpty)
    }
}

// MARK: - Metadata 端口替身

/// 并发用例的放行闸（AsyncGate 未标 Sendable，不能捕获进 @Sendable 的
/// XMPProvider.onRestore 钩子；实现与 Support/AsyncGate 相同，仅本文件使用）。
private final class MetadataTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if released { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// 线程安全布尔探针（并发用例断言文件阶段是否进入/排队）。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 异步条件轮询（锁 actor 的 waiterCount 等）；有界失败上限，满足即返回。
private func waitUntilAsyncCondition(
    timeout: TimeInterval = 3,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        if Task.isCancelled { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// 一次性触发标记（注入钩子防重入）。
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}

/// 可编程 XMP 假件：remote 属性/存在的文件可注入；恢复/删除/写盘只记录。
private final class MetadataTestXMPProvider: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttributes = MetadataWriteAttributes()
    private var existingPaths: Set<String> = []
    private var storedRestores: [(photoPath: String, backupPath: String)] = []
    private var storedRemovals: [String] = []
    private var storedWrites: [MetadataWriteAttributes] = []
    /// 按 photoPath 建模的盘上内容（并发用例用；缺省回退到 attributes）。
    private var storedContent: [String: MetadataWriteAttributes] = [:]
    /// backupPath → 备份内容；restore 时写回 photoPath（模拟真实旧备份）。
    private var storedBackupContent: [String: MetadataWriteAttributes] = [:]
    /// restore 内的慢文件阶段钩子（并发用例在锁内停住）。
    private var storedRestoreHook: (@Sendable () async -> Void)?
    /// 文件阶段顺序日志（"restore" / "write" / "remove"）。
    private var storedPhaseLog: [String] = []
    /// 文件阶段前的确定性注入钩子：模拟 restore 的 await 窗口里出现新输入。
    private var storedFileExistsHook: (@Sendable (String) -> Void)?

    var attributes: MetadataWriteAttributes {
        get { lock.withLock { storedAttributes } }
        set { lock.withLock { storedAttributes = newValue } }
    }

    var existingFiles: Set<String> {
        get { lock.withLock { existingPaths } }
        set { lock.withLock { existingPaths = newValue } }
    }

    var restoreCalls: [(photoPath: String, backupPath: String)] { lock.withLock { storedRestores } }
    var removeCalls: [String] { lock.withLock { storedRemovals } }
    var writeCalls: [MetadataWriteAttributes] { lock.withLock { storedWrites } }
    var phaseLog: [String] { lock.withLock { storedPhaseLog } }

    /// 盘上内容（photoPath → 属性）；未注入的路径回退到全局 attributes。
    var content: [String: MetadataWriteAttributes] {
        get { lock.withLock { storedContent } }
        set { lock.withLock { storedContent = newValue } }
    }

    /// 备份内容（backupPath → 属性）：restore 时写回 photoPath。
    var backupContent: [String: MetadataWriteAttributes] {
        get { lock.withLock { storedBackupContent } }
        set { lock.withLock { storedBackupContent = newValue } }
    }

    var onRestore: (@Sendable () async -> Void)? {
        get { lock.withLock { storedRestoreHook } }
        set { lock.withLock { storedRestoreHook = newValue } }
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        lock.withLock { storedContent[photoPath] ?? storedAttributes }.keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        lock.withLock { storedContent[photoPath] ?? storedAttributes }
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        lock.withLock {
            storedWrites.append(attributes)
            storedContent[photoPath] = attributes
            storedPhaseLog.append("write")
        }
    }

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {
        lock.withLock { storedRestores.append((photoPath, backupPath)) }
        // 钩子在锁外执行（慢 restore 持有 XMPFileLock，但不能嵌套本假件的锁）。
        let hook = lock.withLock { storedRestoreHook }
        await hook?()
        lock.withLock {
            if let backup = storedBackupContent[backupPath] {
                storedContent[photoPath] = backup
            }
            storedPhaseLog.append("restore")
        }
    }

    var onFileExists: (@Sendable (String) -> Void)? {
        get { lock.withLock { storedFileExistsHook } }
        set { lock.withLock { storedFileExistsHook = newValue } }
    }

    func fileExists(_ path: String) -> Bool {
        // 钩子在锁外执行（它可能回调 deliveryRepo，不能与本假件的锁嵌套）。
        let hook = lock.withLock { storedFileExistsHook }
        hook?(path)
        return lock.withLock { existingPaths.contains(path) }
    }

    func removeFile(_ path: String) async throws {
        lock.withLock {
            storedRemovals.append(path)
            storedPhaseLog.append("remove")
        }
    }
}

/// MetadataService 所需的 mutation 端口；只测读取路径，不记录写入。
private struct MetadataTestMutationPort: MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending"
        )
    }
}

// MARK: - Metadata 夹具

private struct MetadataAPIFixture {
    let db: DBConnection
    let sessionId: String
    let tempRoot: URL
    let photoIds: [String]
    let photoPaths: [String]
    let deliveryRepo: DeliveryRepo
    let xmp: MetadataTestXMPProvider
    let api: LiveMetadataAPI

    init(
        photoCount: Int = 2,
        xmp: MetadataTestXMPProvider = MetadataTestXMPProvider(),
        fileLock: XMPFileLock = XMPFileLock()
    ) throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "B6a metadata", source: "test")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-b6a-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var inputs: [PhotoAddInput] = []
        var paths: [String] = []
        for index in 1...photoCount {
            let url = root.appendingPathComponent("META_\(index).jpg")
            try Data("metadata-\(index)".utf8).write(to: url)
            inputs.append(PhotoAddInput(filepath: url.path, width: 100, height: 80))
            paths.append(url.path)
        }
        let photoRepo = PhotoRepo(connection: db)
        let ids = try photoRepo.addPhotos(
            sessionId: session.id,
            filepaths: inputs,
            "test"
        ).ids

        let metadataCacheRepo = MetadataCacheRepo(connection: db)
        let mutations = MetadataTestMutationPort()
        let metadataService = MetadataService(
            metadataCacheRepo: metadataCacheRepo,
            xmp: xmp,
            connection: db,
            mutations: mutations
        )
        // S5c-2b-3b-2b-2：LiveMetadataAPI 不再构造 MetadataSyncCoordinator，
        // conflicts/orphans 读交付表、restore/remote 读经 XMP 假件。
        let deliveryRepo = DeliveryRepo(connection: db)

        self.db = db
        self.sessionId = session.id
        self.tempRoot = root
        self.photoIds = ids
        self.photoPaths = paths
        self.deliveryRepo = deliveryRepo
        self.xmp = xmp
        self.api = LiveMetadataAPI(
            metadataService: metadataService,
            deliveryRepo: deliveryRepo,
            xmp: xmp,
            fileLock: fileLock,
            settingsService: SettingsService(repo: SettingsRepo(connection: db))
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func path(for photoId: String) throws -> String {
        guard let index = photoIds.firstIndex(of: photoId) else {
            throw APIExportMetadataFixtureError.photoMissing
        }
        return photoPaths[index]
    }

    /// 交付主键：与 DeliveryRepo 的落库口径一致（侧车路径 → TSPath.normalize）。
    func deliveryPath(for photoId: String) throws -> String {
        TSPath.normalize(TSPath.xmpSidecarPath(try path(for: photoId)))
    }

    /// 种入一条 conflict 交付：基线 rating = remoteRating，本地 item rating = localRating，
    /// 会话已链接（旧 outbox conflict 行 + outbox_sessions 的等价物）。
    @discardableResult
    func seedConflict(photoId: String, localRating: Int = 5, remoteRating: Int = 3) throws -> String {
        let photoPath = try path(for: photoId)
        let xmpPath = try deliveryPath(for: photoId)
        _ = try deliveryRepo.createOrGet(xmpPath: xmpPath, photoPath: photoPath)
        _ = try deliveryRepo.markWritingForTesting(xmpPath: xmpPath, revision: 0)
        _ = try deliveryRepo.markWritten(
            xmpPath: xmpPath,
            revision: 0,
            baseFingerprint: "fp-conflict",
            baseValues: .object(["rating": .number(Double(remoteRating))]),
            backupPath: ""
        )
        _ = try deliveryRepo.markSynced(xmpPath: xmpPath, revision: 0)
        _ = try deliveryRepo.markConflictForTestSupport(
            xmpPath: xmpPath, revision: 0, errorMessage: "XMP_EXTERNAL_EDIT_CONFLICT")
        // 冲突前已写盘并确认的项（cleanup 外部修改冲突的真实形态）。
        _ = try deliveryRepo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoId,
            module: .metadata,
            attributes: ["rating": .number(Double(localRating))],
            status: .synced
        )
        _ = try deliveryRepo.linkSession(xmpPath: xmpPath, sessionId: sessionId)
        return xmpPath
    }

    /// 种入一条孤儿交付（没有任何 delivery_sessions 关联）。
    @discardableResult
    func seedOrphan(
        photoId: String,
        status: DeliveryStatus = .pending,
        backupPath: String = ""
    ) throws -> String {
        let photoPath = try path(for: photoId)
        let xmpPath = try deliveryPath(for: photoId)
        _ = try deliveryRepo.createOrGet(xmpPath: xmpPath, photoPath: photoPath)
        switch status {
        case .pending:
            break
        case .failed:
            _ = try deliveryRepo.markWritingForTesting(xmpPath: xmpPath, revision: 0)
            _ = try deliveryRepo.markFailedForTestSupport(xmpPath: xmpPath, revision: 0, errorMessage: "WRITE_FAILED")
        case .synced:
            _ = try deliveryRepo.markWritingForTesting(xmpPath: xmpPath, revision: 0)
            _ = try deliveryRepo.markWritten(
                xmpPath: xmpPath, revision: 0,
                baseFingerprint: "fp-orphan", baseValues: .object([:]),
                backupPath: backupPath)
            _ = try deliveryRepo.markSynced(xmpPath: xmpPath, revision: 0)
        default:
            break
        }
        _ = try deliveryRepo.upsertItem(
            xmpPath: xmpPath,
            photoId: photoId,
            module: .metadata,
            keywords: ["orphan"],
            status: .pending
        )
        return xmpPath
    }
}

// MARK: - Metadata 用例

@Suite("APIMetadata Live")
struct APIMetadataTests {
    @Test("conflicts：字段级投影；resolveConflict(use_remote) 结清行")
    func conflictsAndResolve() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.seedConflict(photoId: photoId)
        fixture.xmp.attributes = MetadataWriteAttributes(rating: 3)

        let conflicts = try await fixture.api.conflicts(fixture.sessionId)
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(conflict.xmpPath == xmpPath)
        #expect(conflict.photoPath == (try fixture.path(for: photoId)))
        let rating = try #require(conflict.fields.first { $0.field == .rating })
        #expect(rating.baseline == .number(3))
        #expect(rating.local == .number(5))
        #expect(rating.remote == .number(3))

        let input = try MetadataResolveConflictInput(
            sessionId: fixture.sessionId,
            xmpPath: xmpPath,
            choices: [.rating: .useRemote]
        )
        let summary = try await fixture.api.resolveConflict(
            Confirmed(input, source: .test)
        )

        // 全部接受远程：盘上内容成为新基线，但只推进到 written（P1-10）。
        // synced 只能由 confirm 在全部关联会话确认后翻转；本夹具只有 s1 链接，
        // 因而 resolve 之后仍不是 synced。
        #expect(summary.conflict == 0)
        #expect(summary.written == 1)
        #expect(summary.synced == 0)
        #expect(try await fixture.api.conflicts(fixture.sessionId).isEmpty)
        let delivery = try #require(try fixture.deliveryRepo.get(xmpPath))
        #expect(delivery.typedStatus == .written)
        #expect(delivery.baseFingerprint != "fp-conflict")
        let item = try #require(try fixture.deliveryRepo.item(
            xmpPath: xmpPath, photoId: photoId, module: .metadata))
        #expect(item.attributes["rating"] == nil)
    }

    @Test("resolveConflict(use_remote)：s2 未确认时交付停在 written，confirm 后才允许 cleanup")
    func acceptExternalStateWaitsForEverySession() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.deliveryPath(for: photoId)

        // 共享同一侧车的第二个会话 + 它自己的照片/item（module scope 的 confirm 需要）。
        let sessionRepo = SessionRepo(connection: fixture.db)
        let s2 = try sessionRepo.create(name: "B6a metadata s2", source: "test")
        let p2URL = fixture.tempRoot.appendingPathComponent("META_S2.jpg")
        try Data("metadata-s2".utf8).write(to: p2URL)
        let p2 = try #require(try PhotoRepo(connection: fixture.db).addPhotos(
            sessionId: s2.id,
            filepaths: [PhotoAddInput(filepath: p2URL.path, width: 100, height: 80)],
            "test"
        ).ids.first)

        _ = try fixture.deliveryRepo.createOrGet(
            xmpPath: xmpPath,
            photoPath: try fixture.path(for: photoId)
        )
        _ = try fixture.deliveryRepo.linkSession(
            xmpPath: xmpPath, sessionId: fixture.sessionId)
        _ = try fixture.deliveryRepo.linkSession(xmpPath: xmpPath, sessionId: s2.id)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: photoId, module: .metadata,
            attributes: ["rating": .number(5)], status: .written)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: p2, module: .metadata, status: .written)
        _ = try fixture.deliveryRepo.markWritingForTesting(xmpPath: xmpPath, revision: 0)
        _ = try fixture.deliveryRepo.markWritten(
            xmpPath: xmpPath, revision: 0,
            baseFingerprint: "fp-conflict",
            baseValues: .object(["rating": .number(3)]),
            backupPath: "")
        _ = try fixture.deliveryRepo.markSynced(xmpPath: xmpPath, revision: 0)
        _ = try fixture.deliveryRepo.markConflictForTestSupport(
            xmpPath: xmpPath, revision: 0, errorMessage: "XMP_EXTERNAL_EDIT_CONFLICT")
        fixture.xmp.attributes = MetadataWriteAttributes(rating: 3)

        let resolveInput = try MetadataResolveConflictInput(
            sessionId: fixture.sessionId,
            xmpPath: xmpPath,
            choices: [.rating: .useRemote])
        let resolved = try await fixture.api.resolveConflict(
            Confirmed(resolveInput, source: .test))
        // 全部接受远程只把交付推进到 written；s2 的链接仍未确认。
        #expect(resolved.written == 1)
        #expect(resolved.synced == 0)
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .written)

        let coordinator = DeliveryCoordinator(
            connection: fixture.db, xmp: fixture.xmp, fileLock: XMPFileLock(), requireReloadAck: false)

        // s1 确认只落自己的链接；s2 未确认 → 交付仍 written、item 不得被翻 synced。
        let s1Confirm = try coordinator.confirm(
            sessionId: fixture.sessionId, module: .metadata)
        #expect(s1Confirm.confirmedLinks == 1)
        #expect(s1Confirm.deliveriesSynced == 0)
        #expect(s1Confirm.itemsSynced == 0)
        #expect(s1Confirm.unconfirmedSessionIds == [s2.id])
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .written)
        #expect(try fixture.deliveryRepo.item(
            xmpPath: xmpPath, photoId: photoId, module: .metadata)?.typedStatus == .written)

        // written 不是 cleanup 候选：不得动文件/DB。
        fixture.xmp.existingFiles = [xmpPath]
        let earlyCleanup = try await coordinator.cleanup(
            sessionId: fixture.sessionId, module: .metadata)
        #expect(earlyCleanup.deletedCount == 0)
        #expect(try fixture.deliveryRepo.get(xmpPath) != nil)
        #expect(fixture.xmp.removeCalls.isEmpty)
        #expect(fixture.xmp.restoreCalls.isEmpty)

        // 只有 s2 也确认后，confirm 才能翻 synced；此时 cleanup 才正常删除。
        let s2Confirm = try coordinator.confirm(sessionId: s2.id, module: .metadata)
        #expect(s2Confirm.confirmedLinks == 1)
        #expect(s2Confirm.deliveriesSynced == 1)
        #expect(s2Confirm.itemsSynced == 2)
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .synced)

        let finalCleanup = try await coordinator.cleanup(
            sessionId: fixture.sessionId, module: .metadata)
        #expect(finalCleanup.deletedCount == 1)
        #expect(fixture.xmp.removeCalls == [xmpPath])
        #expect(try fixture.deliveryRepo.get(xmpPath) == nil)
    }

    @Test("resolveConflict(use_remote)：冲突前旧确认全部失效，首个 confirm 仍等待 s2")
    func acceptExternalStateInvalidatesPreConflictConfirmations() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.deliveryPath(for: photoId)

        let sessionRepo = SessionRepo(connection: fixture.db)
        let s2 = try sessionRepo.create(name: "B6a metadata old-confirm s2", source: "test")
        let p2URL = fixture.tempRoot.appendingPathComponent("META_S2_OLD.jpg")
        try Data("metadata-s2-old".utf8).write(to: p2URL)
        let p2 = try #require(try PhotoRepo(connection: fixture.db).addPhotos(
            sessionId: s2.id,
            filepaths: [PhotoAddInput(filepath: p2URL.path, width: 100, height: 80)],
            "test"
        ).ids.first)

        _ = try fixture.deliveryRepo.createOrGet(
            xmpPath: xmpPath,
            photoPath: try fixture.path(for: photoId)
        )
        _ = try fixture.deliveryRepo.linkSession(xmpPath: xmpPath, sessionId: fixture.sessionId)
        _ = try fixture.deliveryRepo.linkSession(xmpPath: xmpPath, sessionId: s2.id)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: photoId, module: .metadata,
            attributes: ["rating": .number(5)], status: .written)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: p2, module: .metadata, status: .written)
        _ = try fixture.deliveryRepo.markWritingForTesting(xmpPath: xmpPath, revision: 0)
        _ = try fixture.deliveryRepo.markWritten(
            xmpPath: xmpPath, revision: 0,
            baseFingerprint: "fp-old",
            baseValues: .object(["rating": .number(5)]),
            backupPath: "")

        // 冲突前 s1/s2 都确认过旧内容：两行 confirmed_at 非空、delivery=synced。
        #expect(try fixture.deliveryRepo.confirm(
            scope: .session, sessionId: fixture.sessionId).deliveriesSynced == 0)
        let oldConfirmation = try fixture.deliveryRepo.confirm(
            scope: .session, sessionId: s2.id)
        #expect(oldConfirmation.confirmedLinks == 1)
        #expect(oldConfirmation.deliveriesSynced == 1)
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .synced)

        // 旧确认对应的 items 已 synced；冲突前重新写盘把它们置回 written
        //（synced 只能先回 pending 再重新 written）。
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: photoId, module: .metadata,
            attributes: ["rating": .number(5)], status: .pending)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: photoId, module: .metadata,
            attributes: ["rating": .number(5)], status: .written)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: p2, module: .metadata, status: .pending)
        _ = try fixture.deliveryRepo.upsertItem(
            xmpPath: xmpPath, photoId: p2, module: .metadata, status: .written)

        _ = try fixture.deliveryRepo.markConflictForTestSupport(
            xmpPath: xmpPath, revision: 0,
            errorMessage: "XMP_EXTERNAL_EDIT_CONFLICT")
        fixture.xmp.attributes = MetadataWriteAttributes(rating: 3)

        let resolveInput = try MetadataResolveConflictInput(
            sessionId: fixture.sessionId,
            xmpPath: xmpPath,
            choices: [.rating: .useRemote])
        let resolved = try await fixture.api.resolveConflict(
            Confirmed(resolveInput, source: .test))
        #expect(resolved.written == 1)
        #expect(resolved.synced == 0)
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .written)

        // 新基线落地时旧 confirmed_at 必须已清空（否则下面的 s1 confirm 会凭旧确认
        // 直接翻 synced）。
        let stale = try fixture.db.prepare("""
            SELECT COUNT(*) FROM delivery_sessions ds
            JOIN deliveries d ON d.id = ds.delivery_id
            WHERE d.xmp_path = ? AND ds.confirmed_at <> ''
            """).get([.text(xmpPath)])?[0].intValue ?? -1
        #expect(stale == 0, "冲突前确认必须全部失效")

        let coordinator = DeliveryCoordinator(
            connection: fixture.db, xmp: fixture.xmp, fileLock: XMPFileLock(), requireReloadAck: false)
        let s1Confirm = try coordinator.confirm(
            sessionId: fixture.sessionId, module: .metadata)
        #expect(s1Confirm.confirmedLinks == 1, "旧确认已失效，s1 这次必须真正落一条")
        #expect(s1Confirm.deliveriesSynced == 0)
        #expect(s1Confirm.itemsSynced == 0)
        #expect(s1Confirm.unconfirmedSessionIds == [s2.id])
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .written)

        let s2Confirm = try coordinator.confirm(sessionId: s2.id, module: .metadata)
        #expect(s2Confirm.confirmedLinks == 1)
        #expect(s2Confirm.deliveriesSynced == 1)
        #expect(s2Confirm.itemsSynced == 2)
        #expect(try fixture.deliveryRepo.get(xmpPath)?.typedStatus == .synced)
    }

    @Test("resolveConflict(keep_local)：交付回 pending 并重排项")
    func resolveConflictKeepLocalReopensDelivery() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.seedConflict(photoId: photoId)

        let input = try MetadataResolveConflictInput(
            sessionId: fixture.sessionId,
            xmpPath: xmpPath,
            choices: [.rating: .keepLocal]
        )
        let summary = try await fixture.api.resolveConflict(
            Confirmed(input, source: .test)
        )

        #expect(summary.conflict == 0)
        #expect(summary.pending == 1)
        let delivery = try #require(try fixture.deliveryRepo.get(xmpPath))
        #expect(delivery.typedStatus == .pending)
        #expect(delivery.revision == 1)
        // 本地输入保留（执行器下一次写盘会覆盖成 5）。
        let item = try #require(try fixture.deliveryRepo.item(
            xmpPath: xmpPath, photoId: photoId, module: .metadata))
        #expect(item.attributes["rating"] == .number(5))
        #expect(item.typedStatus == .pending)
    }

    @Test("orphans：列出孤儿；resolveOrphan(keep) 删除行")
    func orphansAndResolve() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.seedOrphan(photoId: photoId)

        let orphans = try await fixture.api.orphans()
        #expect(orphans.count == 1)
        #expect(orphans.first?.xmpPath == xmpPath)
        #expect(orphans.first?.status == DeliveryStatus.pending.rawValue)

        let input = try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .keep)
        let remaining = try await fixture.api.resolveOrphan(
            Confirmed(input, source: .test)
        )

        #expect(remaining.isEmpty)
        #expect(try await fixture.api.orphans().isEmpty)
        #expect(try fixture.deliveryRepo.get(xmpPath) == nil)
    }

    @Test("resolveOrphan(restore)：先回滚备份再删行；缺备份显式失败")
    func resolveOrphanRestore() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.deliveryPath(for: photoId)
        let backup = xmpPath + ".gather-backup-restore"
        _ = try fixture.seedOrphan(photoId: photoId, status: .synced, backupPath: backup)

        // 备份不存在：XMP_BACKUP_MISSING，且行保留（可重试）。
        let missing = await asyncGatherError {
            let input = try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .restore)
            return try await fixture.api.resolveOrphan(Confirmed(input, source: .test))
        }
        #expect(missing?.code == .XMP_BACKUP_MISSING)
        #expect(try fixture.deliveryRepo.get(xmpPath) != nil)

        fixture.xmp.existingFiles = [backup]
        let remaining = try await fixture.api.resolveOrphan(
            Confirmed(
                try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .restore),
                source: .test)
        )
        #expect(remaining.isEmpty)
        #expect(fixture.xmp.restoreCalls.count == 1)
        #expect(fixture.xmp.restoreCalls.first?.backupPath == backup)
        #expect(try fixture.deliveryRepo.get(xmpPath) == nil)
    }

    @Test("resolveOrphan(restore)：文件阶段出现新输入 → 不 restore、不删行、错误可见")
    func resolveOrphanRestoreAbortsWhenDeliveryAdvanced() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let photoPath = try fixture.path(for: photoId)
        let xmpPath = try fixture.deliveryPath(for: photoId)
        let backup = xmpPath + ".gather-backup-race"
        _ = try fixture.seedOrphan(
            photoId: photoId, status: .synced, backupPath: backup)
        fixture.xmp.existingFiles = [backup]

        // 在 restore 前的存在性检查里注入真实新输入（revision 0 → 1、status pending）。
        let repo = fixture.deliveryRepo
        let once = OnceFlag()
        fixture.xmp.onFileExists = { path in
            guard path == backup, once.fire() else { return }
            _ = try? repo.mergeInput(
                xmpPath: xmpPath,
                photoPath: photoPath,
                expectedRevision: 0,
                newRevision: 1,
                baseFingerprint: "fp-new",
                baseValues: .object([:])
            )
        }

        let error = await asyncGatherError {
            let input = try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .restore)
            return try await fixture.api.resolveOrphan(Confirmed(input, source: .test))
        }

        #expect(error?.code == .XMP_EXTERNAL_EDIT_CONFLICT)
        #expect(fixture.xmp.restoreCalls.isEmpty, "revision 已变：绝不 restore 旧备份")
        #expect(fixture.xmp.removeCalls.isEmpty)
        let row = try #require(try fixture.deliveryRepo.get(xmpPath))
        #expect(row.revision == 1)
        #expect(row.typedStatus == .pending)
        #expect(try await fixture.api.orphans().count == 1, "行必须保留，等待重试/裁决")
    }

    @Test("resolveOrphan(restore)：复核→restore→事后复核持有注入的 XMPFileLock，竞争者排队")
    func resolveOrphanRestoreHoldsSharedFileLock() async throws {
        let xmp = MetadataTestXMPProvider()
        // R5：不再有进程级 .shared；测试显式构造唯一实例并注入（与生产组合根同构）。
        let lock = XMPFileLock()
        let fixture = try MetadataAPIFixture(xmp: xmp, fileLock: lock)
        let gate = MetadataTestGate()
        defer {
            gate.release()
            fixture.cleanup()
        }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.deliveryPath(for: photoId)
        let backup = xmpPath + ".gather-backup-lock-\(UUID().uuidString)"
        _ = try fixture.seedOrphan(photoId: photoId, status: .synced, backupPath: backup)
        xmp.existingFiles = [backup]

        let entered = LockedFlag()
        xmp.onRestore = {
            entered.set()
            await gate.wait()
        }
        let api = fixture.api
        let restoreTask = Task {
            try await api.resolveOrphan(Confirmed(
                try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .restore),
                source: .test))
        }

        #expect(await waitUntilAsyncCondition { entered.isSet }, "restore 必须进入文件阶段")
        #expect(
            await lock.isActive(path: xmpPath),
            "复核→restore→事后复核期间必须持有共享锁")

        // 同一路径的其它文件阶段（cleanup/writeback 用的同一实例）必须排队。
        let competitorEntered = LockedFlag()
        let competitor = Task {
            try await lock.run(path: xmpPath) { competitorEntered.set() }
        }
        #expect(
            await waitUntilAsyncCondition {
                await lock.waiterCount(path: xmpPath) == 1
            },
            "竞争者应排在同一个共享实例上")
        #expect(!competitorEntered.isSet, "restore 未完成前不得进入（锁不可重入/不嵌套）")

        gate.release()
        let remaining = try await restoreTask.value
        try await competitor.value

        #expect(remaining.isEmpty)
        #expect(xmp.restoreCalls.count == 1)
        #expect(competitorEntered.isSet)
        #expect(!(await lock.isActive(path: xmpPath)), "锁必须完全释放")
    }

    @Test("resolveOrphan(restore) 与 writeback 并发：同锁串行，旧备份不覆盖新内容")
    func resolveOrphanRestoreRacingWritebackKeepsNewContent() async throws {
        let lock = XMPFileLock()
        let xmp = MetadataTestXMPProvider()
        let fixture = try MetadataAPIFixture(xmp: xmp, fileLock: lock)
        let gate = MetadataTestGate()
        defer {
            gate.release()
            fixture.cleanup()
        }
        let db = fixture.db
        let repo = fixture.deliveryRepo
        let api = fixture.api
        let photoId = try #require(fixture.photoIds.first)
        let photoPath = try fixture.path(for: photoId)
        let xmpPath = try fixture.deliveryPath(for: photoId)
        let backup = xmpPath + ".gather-backup-race-lock-\(UUID().uuidString)"
        _ = try fixture.seedOrphan(photoId: photoId, status: .synced, backupPath: backup)
        xmp.existingFiles = [backup]
        xmp.content = [photoPath: MetadataWriteAttributes(keywords: ["before"])]
        xmp.backupContent = [backup: MetadataWriteAttributes(keywords: ["before"])]

        let restoreEntered = LockedFlag()
        xmp.onRestore = {
            restoreEntered.set()
            await gate.wait()
        }
        let restoreTask = Task {
            try await api.resolveOrphan(Confirmed(
                try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .restore),
                source: .test))
        }
        #expect(await waitUntilAsyncCondition { restoreEntered.isSet }, "先进入慢 restore 并持锁")

        // 新输入 + 真实 writeback：preview 推进 revision 并重开交付；execute 的
        // backup/read/write 必须与 orphan restore 共用同一把锁而排队。
        let coordinator = DeliveryCoordinator(connection: db, xmp: xmp, fileLock: lock)
        let writeback = WritebackService(
            deliveryRepo: repo,
            xmp: xmp,
            photoRepo: PhotoRepo(connection: db),
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            connection: db,
            delivery: coordinator,
            fileLock: lock
        )
        let sessionId = fixture.sessionId
        let preview = try await writeback.preview(
            sessionId: sessionId,
            module: "similarity",
            photoIds: [photoId],
            keywordAdditions: [photoId: ["new"]]
        )
        #expect(preview.items.count == 1)
        let previewItems = preview.items
        let writeTask = Task {
            try await writeback.execute(
                sessionId: sessionId, module: "similarity", items: previewItems)
        }

        #expect(
            await waitUntilAsyncCondition {
                (try? repo.get(xmpPath)?.revision) == 1
            },
            "新输入必须先把孤儿交付推进到 revision 1")
        #expect(
            await waitUntilAsyncCondition {
                await lock.waiterCount(path: xmpPath) == 1
            },
            "writeback 必须排队等 orphan restore 释放锁")
        #expect(xmp.writeCalls.isEmpty, "持锁期间 writeback 不得先写盘")

        gate.release()
        let restoreError = await asyncGatherError { try await restoreTask.value }
        let writeResult = try await writeTask.value

        // orphan 的事后复核看见新输入：显式冲突、行保留、不删备份。
        #expect(restoreError?.code == .XMP_EXTERNAL_EDIT_CONFLICT)
        #expect(try repo.get(xmpPath) != nil)
        // writeback 在锁释放后写新内容：最终盘上是新值，不是旧备份。
        #expect(writeResult.written == 1)
        #expect(writeResult.failed == 0)
        #expect(xmp.phaseLog == ["restore", "write"], "旧备份先恢复、新内容后写盘，顺序不得颠倒")
        #expect(try await xmp.readAttributes(photoPath: photoPath).keywords?.contains("new") == true)
        #expect(try repo.get(xmpPath)?.typedStatus == .written)
    }

    @Test("resolveOrphan(retry)：failed → pending；conflict 要求先裁决")
    func resolveOrphanRetry() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)
        let xmpPath = try fixture.seedOrphan(photoId: photoId, status: .failed)

        _ = try await fixture.api.resolveOrphan(
            Confirmed(
                try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .retry),
                source: .test)
        )
        let delivery = try #require(try fixture.deliveryRepo.get(xmpPath))
        #expect(delivery.typedStatus == .pending)
        #expect(delivery.revision == 1)

        // 已 pending 的孤儿不可再一次 retry（旧 XMP_ORPHAN_NOT_RETRYABLE 语义）。
        _ = try fixture.deliveryRepo.markWritingForTesting(xmpPath: xmpPath, revision: 1)
        _ = try fixture.deliveryRepo.markWritten(
            xmpPath: xmpPath, revision: 1,
            baseFingerprint: "fp", baseValues: .object([:]), backupPath: "")
        _ = try fixture.deliveryRepo.markSynced(xmpPath: xmpPath, revision: 1)
        let notRetryable = await asyncGatherError {
            let input = try MetadataResolveOrphanInput(xmpPath: xmpPath, action: .retry)
            return try await fixture.api.resolveOrphan(Confirmed(input, source: .test))
        }
        #expect(notRetryable?.code == .XMP_ORPHAN_NOT_RETRYABLE)
    }

    @Test("错误路径：空白 sessionId、无冲突/孤儿记录、输入类型校验")
    func errorPaths() async throws {
        let fixture = try MetadataAPIFixture()
        defer { fixture.cleanup() }
        let photoId = try #require(fixture.photoIds.first)

        let blankSession = await asyncGatherError {
            try await fixture.api.conflicts("   ")
        }
        #expect(blankSession?.code == .INVALID_PARAM)
        #expect(blankSession?.params["field"] == "sessionId")

        let missingConflict = await asyncGatherError {
            let input = try MetadataResolveConflictInput(
                sessionId: fixture.sessionId,
                xmpPath: "/tmp/gather-b6a-missing.xmp",
                choices: [.rating: .useRemote]
            )
            return try await fixture.api.resolveConflict(Confirmed(input, source: .test))
        }
        #expect(missingConflict?.code == .XMP_CONFLICT_NOT_FOUND)

        let missingOrphan = await asyncGatherError {
            let input = try MetadataResolveOrphanInput(
                xmpPath: "/tmp/gather-b6a-missing.xmp",
                action: .keep
            )
            return try await fixture.api.resolveOrphan(Confirmed(input, source: .test))
        }
        #expect(missingOrphan?.code == .XMP_ORPHAN_NOT_FOUND)

        // 冲突裁决必须覆盖全部待裁决字段（旧 XMP_CHOICE_MISSING 语义）：
        // 该交付只有 rating 待裁决，只给 label 的选择必须被拒绝。
        let conflictPath = try fixture.seedConflict(photoId: photoId)
        let choiceMissing = await asyncGatherError {
            let input = try MetadataResolveConflictInput(
                sessionId: fixture.sessionId,
                xmpPath: conflictPath,
                choices: [.label: .useRemote]
            )
            return try await fixture.api.resolveConflict(Confirmed(input, source: .test))
        }
        #expect(choiceMissing?.code == .XMP_CHOICE_MISSING)

        #expect(
            gatherError {
                try MetadataResolveConflictInput(
                    sessionId: fixture.sessionId,
                    xmpPath: "/tmp/a.xmp",
                    choices: [:]
                )
            }?.code == .INVALID_PARAM
        )
    }
}
