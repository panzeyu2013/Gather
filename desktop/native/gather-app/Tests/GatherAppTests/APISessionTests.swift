// desktop/native/gather-app/Tests/GatherAppTests/APISessionTests.swift
// Cut 1 / B1：LiveSessionAPI / LiveJobAPI / LiveSettingsAPI 行为测试。
//
// 覆盖：会话 CRUD + 目录/文件导入、status；设置读写/重置/语言；任务
// list/cancel/retry/clearCompleted/start（事件流过滤 + finish）；以及 D-012
// 要求的显式参数错误路径。全部用内存 SQLite + 临时目录，不碰用户数据。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

/// 三个 Live API 的共享测试装配（内存库 + 真实服务）。
private struct APIFixture {
    let db: DBConnection
    let sessionAPI: LiveSessionAPI
    let jobAPI: LiveJobAPI
    let settingsAPI: LiveSettingsAPI
    let jobService: JobService
    let jobRepo: AnalysisJobRepo
    let settingsService: SettingsService

    init() throws {
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let faceRepo = FaceRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let sessionService = SessionService(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            faceRepo: faceRepo,
            connection: db,
            // 文件导入路径需要尺寸读取接缝；测试用固定 100×100。
            dimensionsProvider: { _ in (width: 100, height: 100) }
        )
        let workspaceStatusService = WorkspaceStatusService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: photoRepo
        )
        self.db = db
        self.jobService = jobService
        self.jobRepo = AnalysisJobRepo(connection: db)
        self.settingsService = settingsService
        self.sessionAPI = LiveSessionAPI(
            sessionService: sessionService,
            workspaceStatusService: workspaceStatusService,
            jobService: jobService
        )
        self.jobAPI = LiveJobAPI(jobService: jobService)
        self.settingsAPI = LiveSettingsAPI(settingsService: settingsService)
    }
}

private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gather-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTempFile(in directory: URL, name: String) throws -> String {
    let url = directory.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url.path
}

private func gatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

@Suite("B1 Live API")
struct APISessionTests {
    // MARK: - Session

    @Test("session：目录创建 / list / get / status / update / delete")
    func sessionCRUDAndWorkspaceStatus() async throws {
        let fixture = try APIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let created = try await fixture.sessionAPI.create(
            SessionCreateInput(name: "目录会话", sourcePath: directory.path)
        )
        #expect(created.session.name == "目录会话")
        #expect(created.session.sourcePath == ScanPath.canonical(directory.path))
        #expect(created.added == 0)
        #expect(created.failedFiles.isEmpty)

        // P1-1：目录分支必须与 filepaths 分支对称入队 metadata.scan（目录全树
        // 作用域，checkpoint 不携带 requestedPaths），否则调用方永远得不到索引。
        let createdJobs = try await fixture.jobAPI.list(JobListFilter())
        let directoryScan = try #require(createdJobs.first {
            $0.type == .metadataScan && $0.scopeId == created.session.id
        })
        // R1 P1-3：目录分支的 request 必须与协议层工厂逐字段一致（单源）。
        #expect(directoryScan.dedupeKey == JobCreateParams.metadataScanDedupeKey(sessionId: created.session.id))
        #expect(directoryScan.checkpoint == JobCreateParams.metadataScanCheckpoint(requestedPaths: nil))
        #expect(
            directoryScan.checkpoint[JobCreateParams.metadataScanRequestedPathsKey] == nil,
            "目录导入 = 目录全树作用域，checkpoint 不得携带 requestedPaths"
        )

        let listed = try await fixture.sessionAPI.list()
        #expect(listed.map(\.id) == [created.session.id])

        let fetched = try await fixture.sessionAPI.get(created.session.id)
        #expect(fetched.id == created.session.id)

        let status = try await fixture.sessionAPI.status(created.session.id)
        #expect(status.sessionId == created.session.id)

        let updated = try await fixture.sessionAPI.update(
            SessionUpdateParams(sessionId: created.session.id, name: "改名")
        )
        #expect(updated.name == "改名")

        try await fixture.sessionAPI.delete(
            Confirmed(try SessionDeleteInput(sessionIds: [created.session.id]))
        )
        let missing = await gatherError { try await fixture.sessionAPI.get(created.session.id) }
        #expect(missing?.code == .SESSION_NOT_FOUND)

        // 空会话分支（无 sourcePath / 无 filepaths）只建会话，不入队索引。
        let empty = try await fixture.sessionAPI.create(SessionCreateInput(name: "空会话"))
        let jobsAfterEmpty = try await fixture.jobAPI.list(JobListFilter())
        #expect(!jobsAfterEmpty.contains {
            $0.type == .metadataScan && $0.scopeId == empty.session.id
        }, "空会话不得入队 metadata.scan")
    }

    @Test("session：filepaths 分支建会话 + 加照片 + metadata.scan(requestedPaths)")
    func sessionCreateWithFilepaths() async throws {
        let fixture = try APIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try makeTempFile(in: directory, name: "a.jpg")
        let b = try makeTempFile(in: directory, name: "b.jpg")

        let result = try await fixture.sessionAPI.create(
            SessionCreateInput(
                name: "文件导入",
                source: "local",
                sourcePath: directory.path,
                filepaths: [a, b]
            )
        )
        #expect(result.added == 2)
        #expect(result.skipped == 0)
        #expect(result.session.photoCount == 2)
        #expect(result.session.sourcePath == ScanPath.canonical(directory.path))

        let jobs = try await fixture.jobAPI.list(JobListFilter())
        let scan = try #require(jobs.first {
            $0.type == .metadataScan && $0.scopeId == result.session.id
        })
        // R1 P1-3：filepaths 分支同样必须等于工厂产出（checkpoint 数组逐位一致）。
        #expect(scan.dedupeKey == JobCreateParams.metadataScanDedupeKey(sessionId: result.session.id))
        #expect(
            scan.checkpoint == JobCreateParams.metadataScanCheckpoint(
                requestedPaths: normalizeImportFilepaths([a, b]))
        )
        let requested = scan.checkpoint[JobCreateParams.metadataScanRequestedPathsKey]?
            .arrayElements?.compactMap(\.stringValue) ?? []
        #expect(requested == normalizeImportFilepaths([a, b]))
    }

    @Test("session：目录准入（禁根 / 非目录）显式失败；metadata.scan 入队失败回滚")
    func sessionDirectoryAdmissionAndJobRollback() async throws {
        let fixture = try APIFixture()
        let fileDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: fileDirectory) }
        let file = try makeTempFile(in: fileDirectory, name: "photo.jpg")

        let root = await gatherError {
            try await fixture.sessionAPI.create(
                SessionCreateInput(name: "根目录", sourcePath: "/")
            )
        }
        #expect(root?.code == .SESSION_SOURCE_ROOT_FORBIDDEN)

        let notDirectory = await gatherError {
            try await fixture.sessionAPI.create(
                SessionCreateInput(name: "文件", sourcePath: file)
            )
        }
        #expect(notDirectory?.code == .SESSION_SOURCE_NOT_DIR)

        // 入队失败：目录分支必须回滚刚创建的会话（与 filepaths 分支同一补偿），
        // 不得留下永远不被索引的半成品。BEFORE INSERT 触发器强制 job 入队失败。
        _ = try fixture.db.prepare("""
            CREATE TRIGGER gather_test_reject_scan_job
            BEFORE INSERT ON analysis_jobs
            BEGIN
              SELECT RAISE(ABORT, 'forced metadata.scan insert failure');
            END
            """).run([])
        var thrown: Error?
        do {
            _ = try await fixture.sessionAPI.create(
                SessionCreateInput(name: "回滚目录", sourcePath: fileDirectory.path)
            )
            Issue.record("metadata.scan 入队失败必须抛错")
        } catch {
            thrown = error
        }
        let dbError = try #require(thrown as? DBError)
        guard case .message(let message) = dbError else {
            Issue.record("预期 DBError.message")
            return
        }
        #expect(message.contains("forced metadata.scan insert failure"))
        #expect(try await fixture.sessionAPI.list().isEmpty, "入队失败必须回滚新会话")
    }

    @Test("session：参数错误显式抛 INVALID_PARAM（D-012）")
    func sessionParameterErrors() async throws {
        let fixture = try APIFixture()

        let blankName = await gatherError {
            try await fixture.sessionAPI.create(SessionCreateInput(name: "   "))
        }
        #expect(blankName?.code == .INVALID_PARAM)
        #expect(blankName?.params["field"] == "name")

        let blankId = await gatherError { try await fixture.sessionAPI.get("   ") }
        #expect(blankId?.code == .INVALID_PARAM)
        #expect(blankId?.params["field"] == "sessionId")

        let blankUpdateName = await gatherError {
            try await fixture.sessionAPI.update(
                SessionUpdateParams(sessionId: "s1", name: "\n\t")
            )
        }
        #expect(blankUpdateName?.code == .INVALID_PARAM)
        #expect(blankUpdateName?.params["field"] == "name")

        do {
            _ = try SessionDeleteInput(sessionIds: [])
            Issue.record("空 sessionIds 必须抛错")
        } catch let error as GatherError {
            #expect(error.code == .SESSION_IDS_REQUIRED)
        }
    }

    // MARK: - Settings

    @Test("settings：all / get / set / reset")
    func settingsCRUDAndReset() async throws {
        let fixture = try APIFixture()
        let all = try await fixture.settingsAPI.all()
        #expect(all["thumbnail_size"] == "1024")

        try await fixture.settingsAPI.set(
            try SettingsSetInput(key: "thumbnail_size", value: "512")
        )
        let changed = try await fixture.settingsAPI.get(try SettingsKey("thumbnail_size"))
        #expect(changed == "512")

        let reset = try await fixture.settingsAPI.reset()
        #expect(reset["thumbnail_size"] == "1024")
        let afterReset = try await fixture.settingsAPI.get(try SettingsKey("thumbnail_size"))
        #expect(afterReset == "1024")
    }

    @Test("settings：key/value 边界与未知 key 显式失败")
    func settingsParameterErrors() async throws {
        let fixture = try APIFixture()

        do {
            _ = try SettingsKey(String(repeating: "k", count: 257))
            Issue.record("超长 key 必须抛错")
        } catch let error as GatherError {
            #expect(error.code == .INVALID_PARAM)
            #expect(error.params["field"] == "key")
        }

        do {
            _ = try SettingsValue(String(repeating: "v", count: 4097))
            Issue.record("超长 value 必须抛错")
        } catch let error as GatherError {
            #expect(error.code == .INVALID_PARAM)
            #expect(error.params["field"] == "value")
        }

        let unknown = await gatherError {
            try await fixture.settingsAPI.set(
                try SettingsSetInput(key: "no_such_setting", value: "x")
            )
        }
        #expect(unknown?.code == .INVALID_PARAM)
        #expect(unknown?.params["field"] == "key")
    }

    @Test("settings：setLanguage 持久化 + 广播 languageChanged")
    @MainActor
    func settingsSetLanguage() async throws {
        let fixture = try APIFixture()
        // Swift Testing 跨套件并行：不在 await 窗口里把进程级语言切成另一个值
        //（会让并行套件的中文断言读到临时值）。目标语言在锁内取当前值，只验证
        // API 的持久化 + 广播两件事；进程级全局的同步已归 LanguageStore 认领
        // 通知（Cut 4 / 4b-1，见 LanguageStoreTests.adoptsExternalNotification），
        // API 不再自己写全局。因此本用例**不断言** GatherLocalization.appLanguage：
        // 它是进程级全局，其它套件随时可能在自己的锁内临时切换，跨 await 断言
        // 必然竞态（R7 P0-2）。
        let target: InterfaceLanguage = AppLanguageLock.withStableCopy {
            GatherLocalization.appLanguage == "en" ? .en : .zhCN
        }
        let observed = LockedBox<(language: String?, count: Int)>((nil, 0))
        let token = NotificationCenter.default.addObserver(
            forName: GatherAppNotification.languageChanged, object: nil, queue: nil
        ) { notification in
            // 进程级通知是全局的：只统计本次目标语言的广播（并行套件可能也会
            // 触发 languageChanged），避免把别人的事件算进来。
            guard (notification.object as? String) == target.rawValue else { return }
            observed.lock.withLock {
                observed.language = notification.object as? String
                observed.count += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let applied = try await fixture.settingsAPI.setLanguage(target)
        #expect(applied == target)
        #expect(observed.lock.withLock { observed.language } == target.rawValue)
        #expect(observed.lock.withLock { observed.count } >= 1)
        #expect(try await fixture.settingsAPI.get(try SettingsKey("ui_language")) == target.rawValue)
    }

    @Test("settings：mlStatus 形状与旧 buildMLStatus 对齐")
    func settingsMLStatus() async throws {
        let fixture = try APIFixture()
        try await fixture.settingsAPI.set(
            try SettingsSetInput(key: "face_compute_units", value: "cpu")
        )
        let status = try await fixture.settingsAPI.mlStatus()
        #expect(status.platform == "darwin")
        #expect(status.provider == "cpu")
        #expect(status.isAuto == false)
        #expect(status.autoBackend == "coreml")
        #expect(status.detectorModel.path == "Apple Vision")
        #expect(status.encoderModel.exists)
        #expect(!status.modelResourcesDir.isEmpty)
    }

    // MARK: - Job

    @Test("jobs：list / cancel / retry / clearCompleted")
    func jobLifecycle() async throws {
        let fixture = try APIFixture()
        let job = try fixture.jobService.create(JobCreateParams(
            type: .thumbnailBuild,
            scopeType: "session",
            scopeId: "s1",
            dedupeKey: "thumbnail.build:s1"
        ))
        let listed = try await fixture.jobAPI.list(JobListFilter(includeCheckpoint: false))
        #expect(listed.contains { $0.id == job.id })

        #expect(try await fixture.jobAPI.cancel(job.id))
        #expect(try fixture.jobRepo.get(job.id)?.status == .cancelled)
        #expect(try await fixture.jobAPI.retry(job.id))
        #expect(try fixture.jobRepo.get(job.id)?.status == .queued)

        let done = try fixture.jobService.create(JobCreateParams(
            type: .thumbnailBuild,
            scopeType: "session",
            scopeId: "s1",
            dedupeKey: "thumbnail.build:s1:done"
        ))
        #expect(try fixture.jobRepo.claim(id: done.id, leaseOwner: fixture.jobService.leaseOwner))
        #expect(try fixture.jobRepo.finish(
            id: done.id,
            leaseOwner: fixture.jobService.leaseOwner,
            status: .succeeded
        ))
        let cleared = try await fixture.jobAPI.clearCompleted(Confirmed(ClearCompletedInput()))
        #expect(cleared == 1)
        #expect(try fixture.jobRepo.get(done.id) == nil)
        // metadata.scan / export.execute 是阶段证据：清理必须保留。
        let evidence = try fixture.jobService.create(JobCreateParams(
            type: .metadataScan,
            scopeType: "session",
            scopeId: "s1",
            dedupeKey: "metadata.scan:s1"
        ))
        #expect(try fixture.jobRepo.claim(id: evidence.id, leaseOwner: fixture.jobService.leaseOwner))
        #expect(try fixture.jobRepo.finish(
            id: evidence.id,
            leaseOwner: fixture.jobService.leaseOwner,
            status: .succeeded
        ))
        _ = try await fixture.jobAPI.clearCompleted(Confirmed(ClearCompletedInput()))
        #expect(try fixture.jobRepo.get(evidence.id) != nil)
    }

    @Test("jobs：start 的事件流只收本 job，终态后 finish")
    @MainActor
    func jobStartStreamsFilteredEvents() async throws {
        let fixture = try APIFixture()
        let handle = try await fixture.jobAPI.start(JobCreateParams(
            type: .metadataScan,
            scopeType: "session",
            scopeId: "s1",
            dedupeKey: "metadata.scan:stream"
        ))
        let job = try #require(try fixture.jobRepo.get(handle.id))

        var other = job
        other.id = "other-job"
        NotificationCenter.default.post(
            name: GatherEventCenter.jobProgress,
            object: GatherJobEvent(
                job: other,
                update: JobProgressUpdate(current: 9, total: 9)
            )
        )

        var running = job
        running.status = .running
        NotificationCenter.default.post(
            name: GatherEventCenter.jobProgress,
            object: GatherJobEvent(
                job: running,
                update: JobProgressUpdate(current: 1, total: 2)
            )
        )

        var finished = job
        finished.status = .succeeded
        let terminalEvent = GatherJobEvent(
            job: finished,
            update: JobProgressUpdate(current: 2, total: 2)
        )
        // 真实 GatherEventCenter 终态帧同时发到两条通知：progress 观察者必须跳过，
        // 只由 terminal 观察者 yield finished（否则同一帧被消费两次）。
        NotificationCenter.default.post(name: GatherEventCenter.jobProgress, object: terminalEvent)
        NotificationCenter.default.post(name: GatherEventCenter.jobTerminal, object: terminalEvent)

        var events: [JobEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        #expect(events.count == 2)
        guard case .progress(let update) = events.first else {
            Issue.record("第一帧必须是 progress")
            return
        }
        #expect(update.current == 1)
        guard case .finished(let terminalJob) = events.last else {
            Issue.record("终态必须是 finished")
            return
        }
        #expect(terminalJob.id == handle.id)
        #expect(terminalJob.status == .succeeded)
    }

    @Test("jobs：start/cancel 的参数错误显式失败（D-012）")
    func jobParameterErrors() async throws {
        let fixture = try APIFixture()

        let blankScope = await gatherError {
            try await fixture.jobAPI.start(JobCreateParams(
                type: .metadataScan,
                scopeType: "session",
                scopeId: "  ",
                dedupeKey: "metadata.scan:x"
            ))
        }
        #expect(blankScope?.code == .INVALID_PARAM)
        #expect(blankScope?.params["field"] == "scopeId")

        let blankCancel = await gatherError { try await fixture.jobAPI.cancel("\n") }
        #expect(blankCancel?.code == .INVALID_PARAM)
        #expect(blankCancel?.params["field"] == "jobId")
    }

    // MARK: - R1 P1-2：sessionAPI.addPhotos 的 Live 行为

    @Test("addPhotos：追加导入返回 added/skipped/total，重复路径跳过，未知会话报 SESSION_NOT_FOUND")
    func addPhotosAppendsAndSkipsDuplicates() async throws {
        let fixture = try APIFixture()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try makeTempFile(in: directory, name: "a.jpg")
        let b = try makeTempFile(in: directory, name: "b.jpg")
        let c = try makeTempFile(in: directory, name: "c.jpg")

        let created = try await fixture.sessionAPI.create(
            SessionCreateInput(name: "追加照片")
        )
        #expect(created.added == 0)
        #expect(created.session.photoCount == 0)

        let first = try await fixture.sessionAPI.addPhotos(
            SessionAddPhotosInput(
                sessionId: created.session.id,
                filepaths: [a, b],
                source: "import"
            )
        )
        #expect(first.added == 2)
        #expect(first.skipped == 0)
        #expect(first.total == 2)
        #expect(first.failedFiles.isEmpty)

        // 同一路径再次导入：唯一索引命中 → skipped，不重复建行。
        let second = try await fixture.sessionAPI.addPhotos(
            SessionAddPhotosInput(
                sessionId: created.session.id,
                filepaths: [a, c],
                source: "import"
            )
        )
        #expect(second.added == 1)
        #expect(second.skipped == 1)
        #expect(second.total == 3)

        let fetched = try await fixture.sessionAPI.get(created.session.id)
        #expect(fetched.photoCount == 3)
        #expect(fetched.status == .photosLoaded)

        let missing = await gatherError {
            try await fixture.sessionAPI.addPhotos(
                SessionAddPhotosInput(sessionId: "no-such-session", filepaths: [a])
            )
        }
        #expect(missing?.code == .SESSION_NOT_FOUND)
    }
}
