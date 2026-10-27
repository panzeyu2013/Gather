// desktop/native/gather-core/Tests/GatherCoreTests/Maintenance/MaintenanceTests.swift
// P0 / B0：备份校验 / 恢复 journal / 诊断脱敏。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-b0-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func seedSession(_ database: Database, id: String) throws {
    _ = try database.connection.prepare("""
        INSERT INTO sessions (id, name, created_at, updated_at)
        VALUES (?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id), .text(id)])
}

@Suite("B0 备份 / 恢复")
struct MaintenanceTests {
    @Test("备份生成 sidecar，可通过只读校验，list 返回记录")
    func backupAndList() async throws {
        let dir = try makeTempDir("backup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let database = try Database.open(at: dbURL.path)
        defer { database.close() }
        try seedSession(database, id: "s-1")

        let settings = SettingsService(repo: SettingsRepo(connection: database.connection))
        let service = MaintenanceService(database: database, settings: settings, appDir: dir)
        // 模拟上次备份崩溃留下的 partial：下一次备份必须清掉。
        let stalePartial = dir.appendingPathComponent("Backups/Gather-Backup-stale.sqlite.partial")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Backups"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stalePartial)
        let record = try await service.backup(trigger: .manual)
        #expect(!FileManager.default.fileExists(atPath: stalePartial.path))

        #expect(record.verified)
        #expect(record.schemaVersion == 4)
        #expect(record.tableCount == 44)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").appendingPathComponent(record.fileName).path))
        let verification = try BackupVerifier.verify(path: dir.appendingPathComponent("Backups").appendingPathComponent(record.fileName).path)
        #expect(verification.sha256 == record.sha256)

        let inventory = try await service.listBackups()
        #expect(inventory.backups.count == 1)
        #expect(inventory.backups[0].fileName == record.fileName)
    }

    @Test("前置权限失败也计入连续失败并自动暂停")
    func permissionFailuresPauseBackups() async throws {
        let dir = try makeTempDir("pause")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Backups 被普通文件占位：ensureDirectory 失败，发生在 probe/VACUUM 之前。
        try Data("not a directory".utf8).write(to: dir.appendingPathComponent("Backups"))
        let database = try Database.open(at: dir.appendingPathComponent("gather.sqlite").path)
        defer { database.close() }
        let settings = SettingsService(repo: SettingsRepo(connection: database.connection))
        let service = MaintenanceService(database: database, settings: settings, appDir: dir)
        for _ in 0..<3 {
            await #expect(throws: MaintenanceError.self) {
                _ = try await service.backup(trigger: .manual)
            }
        }
        let inventory = try await service.listBackups()
        #expect(inventory.autoPaused, "前置校验失败也必须计入自动暂停")
    }

    @Test("损坏文件被 BackupVerifier 拒绝")
    func corruptRejected() throws {
        let dir = try makeTempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("bad.sqlite")
        try Data("not sqlite".utf8).write(to: path)
        #expect(throws: MaintenanceError.self) {
            _ = try BackupVerifier.verify(path: path.path)
        }
    }

    @Test("恢复 journal prepared → swap → finalize，旧库保留")
    func restoreApplyAndFinalize() throws {
        let dir = try makeTempDir("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backupURL = dir.appendingPathComponent("Gather-Backup-20260101-000000.sqlite")
        let backupDB = try Database.open(at: backupURL.path)
        try seedSession(backupDB, id: "from-backup")
        backupDB.close()
        let verification = try BackupVerifier.verify(path: backupURL.path)

        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let current = try Database.open(at: dbURL.path)
        try seedSession(current, id: "current")
        current.close()

        let preRestore = dbURL.path + ".pre-restore-test"
        let journal = RestoreJournal(
            state: .prepared,
            createdAt: "2026-01-01T00:00:00.000Z",
            backupFileName: backupURL.lastPathComponent,
            backupPath: backupURL.path,
            backupSHA256: verification.sha256,
            backupSchemaVersion: verification.schemaVersion,
            dbPath: dbURL.path,
            preRestorePath: preRestore,
            stagingPath: dbURL.path + ".restore-test.tmp",
            backupDir: dir.path
        )
        let journalPath = RestoreCoordinator.journalPath(dbPath: dbURL.path)
        try JSONEncoder().encode(journal).write(to: URL(fileURLWithPath: journalPath))

        let outcome = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path)
        guard case .applied = outcome else {
            Issue.record("expected applied, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: preRestore))
        let reopened = try Database.open(at: dbURL.path)
        let row = try reopened.connection.prepare("SELECT id FROM sessions").get([])
        #expect(row?[0].textValue == "from-backup")
        reopened.close()

        try RestoreCoordinator.finalizeOpened(dbPath: dbURL.path)
        #expect(!FileManager.default.fileExists(atPath: journalPath))
    }

    @Test("oldMoved 状态回滚旧库")
    func restoreRollback() throws {
        let dir = try makeTempDir("rollback")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let current = try Database.open(at: dbURL.path)
        try seedSession(current, id: "current")
        current.close()
        let preRestore = dbURL.path + ".pre-restore-test"
        try FileManager.default.moveItem(atPath: dbURL.path, toPath: preRestore)

        let journal = RestoreJournal(
            state: .oldMoved,
            createdAt: "2026-01-01T00:00:00.000Z",
            backupFileName: "Gather-Backup-x.sqlite",
            backupPath: dir.appendingPathComponent("missing.sqlite").path,
            backupSHA256: "",
            backupSchemaVersion: 3,
            dbPath: dbURL.path,
            preRestorePath: preRestore,
            stagingPath: dbURL.path + ".restore-test.tmp",
            backupDir: dir.path
        )
        try JSONEncoder().encode(journal).write(to: URL(fileURLWithPath: RestoreCoordinator.journalPath(dbPath: dbURL.path)))
        let outcome = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path)
        if case .rolledBack = outcome {} else { Issue.record("expected rolledBack") }
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
    }

    @Test("prepared 崩溃窗口：主库已搬 pre、-wal 未搬时回滚不丢 WAL")
    func restoreRollbackKeepsOrphanedWal() throws {
        let dir = try makeTempDir("rollback-wal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backupURL = dir.appendingPathComponent("Gather-Backup-20260101-000000.sqlite")
        let backupDB = try Database.open(at: backupURL.path)
        try seedSession(backupDB, id: "from-backup")
        backupDB.close()
        let verification = try BackupVerifier.verify(path: backupURL.path)

        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let current = try Database.open(at: dbURL.path)
        try seedSession(current, id: "current")
        current.close()
        let preRestore = dbURL.path + ".pre-restore-test"
        try FileManager.default.moveItem(atPath: dbURL.path, toPath: preRestore)
        // 模拟“主库已搬、WAL 未搬”的崩溃现场。
        let walPath = dbURL.path + "-wal"
        try Data("orphan-wal".utf8).write(to: URL(fileURLWithPath: walPath))

        let journal = RestoreJournal(
            state: .prepared,
            createdAt: "2026-01-01T00:00:00.000Z",
            backupFileName: backupURL.lastPathComponent,
            backupPath: backupURL.path,
            backupSHA256: verification.sha256,
            backupSchemaVersion: verification.schemaVersion,
            dbPath: dbURL.path,
            preRestorePath: preRestore,
            stagingPath: dbURL.path + ".restore-test.tmp",
            backupDir: dir.path
        )
        try JSONEncoder().encode(journal).write(
            to: URL(fileURLWithPath: RestoreCoordinator.journalPath(dbPath: dbURL.path)))

        let outcome = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path)
        if case .rolledBack = outcome {} else { Issue.record("expected rolledBack, got \(outcome)") }
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(FileManager.default.fileExists(atPath: walPath), "旧库 WAL 不能被回滚删除")
        let wal = try Data(contentsOf: URL(fileURLWithPath: walPath))
        #expect(String(data: wal, encoding: .utf8) == "orphan-wal")
    }

    @Test("恢复前校验备份 SHA：被替换的备份拒绝安装")
    func restoreRejectsChangedBackup() throws {
        let dir = try makeTempDir("sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        let backupURL = dir.appendingPathComponent("backup.sqlite")
        let backupDB = try Database.open(at: backupURL.path)
        try seedSession(backupDB, id: "from-backup")
        backupDB.close()

        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let current = try Database.open(at: dbURL.path)
        try seedSession(current, id: "current")
        current.close()

        let journal = RestoreJournal(
            state: .prepared,
            createdAt: "2026-01-01T00:00:00.000Z",
            backupFileName: backupURL.lastPathComponent,
            backupPath: backupURL.path,
            backupSHA256: "deadbeef",
            backupSchemaVersion: 3,
            dbPath: dbURL.path,
            preRestorePath: dbURL.path + ".pre-restore-test",
            stagingPath: dbURL.path + ".restore-test.tmp",
            backupDir: dir.path
        )
        try JSONEncoder().encode(journal).write(
            to: URL(fileURLWithPath: RestoreCoordinator.journalPath(dbPath: dbURL.path)))
        let outcome = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path)
        guard case .rolledBack(let failure) = outcome else {
            Issue.record("expected rolledBack"); return
        }
        #expect(failure.code == "RESTORE_BACKUP_CHANGED")
        let reopened = try Database.open(at: dbURL.path)
        defer { reopened.close() }
        let row = try reopened.connection.prepare("SELECT id FROM sessions").get([])
        #expect(row?[0].textValue == "current")
    }

    @Test("备份锁跨实例互斥，释放后可重入")
    func backupLockIsExclusive() throws {
        let dir = try makeTempDir("backup-lock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try BackupLock.acquire(at: dir)
        #expect(throws: MaintenanceError.self) {
            _ = try BackupLock.acquire(at: dir)
        }
        first.release()
        first.release() // 幂等：deinit 还会再调一次
        let second = try BackupLock.acquire(at: dir)
        second.release()
    }

    @Test("诊断包超限时丢最旧日志重新打包")
    func diagnosticsTrimsOversizedBundle() throws {
        let dir = try makeTempDir("diag-trim")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = dir.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for index in 0..<4 {
            let bytes = (0..<400_000).map { _ in UInt8.random(in: 0...255) }
            try Data(bytes).write(to: logs.appendingPathComponent("gather-\(index).log"))
        }
        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let database = try Database.open(at: dbURL.path)
        defer { database.close() }
        let settings = SettingsService(repo: SettingsRepo(connection: database.connection))
        let collector = DiagnosticsCollector(
            database: database, settings: settings, appDir: dir,
            maxBundleBytes: 1_000_000, logBudgetBytes: 4_000_000)
        let zip = dir.appendingPathComponent("diag.zip")
        let result = try collector.collect(destination: zip, includePaths: false)
        #expect(result.sizeBytes <= 1_000_000)
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    @Test("取消 prepared 恢复会删除 journal，启动不再 swap")
    func cancelPendingRestore() throws {
        let dir = try makeTempDir("cancel-restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let db = try Database.open(at: dbURL.path)
        try seedSession(db, id: "current")
        db.close()
        let staging = dbURL.path + ".restore-test.tmp"
        try Data("staging".utf8).write(to: URL(fileURLWithPath: staging))
        let journal = RestoreJournal(
            state: .prepared,
            createdAt: "2026-01-01T00:00:00.000Z",
            backupFileName: "Gather-Backup-x.sqlite",
            backupPath: dir.appendingPathComponent("backup.sqlite").path,
            backupSHA256: "abc",
            backupSchemaVersion: 3,
            dbPath: dbURL.path,
            preRestorePath: dbURL.path + ".pre-restore-test",
            stagingPath: staging,
            backupDir: dir.path)
        try JSONEncoder().encode(journal).write(
            to: URL(fileURLWithPath: RestoreCoordinator.journalPath(dbPath: dbURL.path)))
        #expect(RestoreCoordinator.hasPending(dbPath: dbURL.path))

        try RestoreCoordinator.cancelPending(dbPath: dbURL.path)
        #expect(!RestoreCoordinator.hasPending(dbPath: dbURL.path))
        #expect(!FileManager.default.fileExists(atPath: staging))
        if case .none = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path) {
        } else {
            Issue.record("cancel 后不应再 apply")
        }
    }

    @Test("诊断包默认脱敏路径")
    func diagnosticsRedacts() throws {
        let dir = try makeTempDir("diag")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = dir.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("""
            read /Users/alice/Application Support/Gather/secret.nef
            NSFilePath:/Users/alice/secret/file.nef
            """.utf8).write(to: logs.appendingPathComponent("gather.log"))

        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let database = try Database.open(at: dbURL.path)
        defer { database.close() }
        let settings = SettingsService(repo: SettingsRepo(connection: database.connection))
        try settings.set("disk_cache_dir", value: "/Users/alice/cache")

        let collector = DiagnosticsCollector(database: database, settings: settings, appDir: dir)
        let zip = dir.appendingPathComponent("diag.zip")
        let result = try collector.collect(destination: zip, includePaths: false)
        #expect(result.redactedPaths)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path, "settings.json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let content = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(!content.contains("/Users/alice"))
        #expect(content.contains("<path>"))

        // 日志里的路径含空格（Application Support）时也必须整段脱敏。
        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        logProcess.arguments = ["-p", zip.path, "logs/gather.log"]
        let logPipe = Pipe()
        logProcess.standardOutput = logPipe
        try logProcess.run()
        logProcess.waitUntilExit()
        let logContent = String(
            data: logPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(!logContent.contains("Application Support"))
        #expect(!logContent.contains("/Users/alice"))
        #expect(logContent.contains("<path>"))
    }

    @Test("恢复失败（备份不可校验）写 lastRestore，设置页可见")
    func failedRestoreWritesState() throws {
        let dir = try makeTempDir("restore-state")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let journal = RestoreJournal(
            state: .prepared,
            createdAt: "2026-01-01T00:00:00.000Z",
            backupFileName: "Gather-Backup-missing.sqlite",
            backupPath: dir.appendingPathComponent("missing.sqlite").path,
            backupSHA256: "deadbeef",
            backupSchemaVersion: 3,
            dbPath: dbURL.path,
            preRestorePath: dbURL.path + ".pre-restore-test",
            stagingPath: dbURL.path + ".restore-test.tmp",
            backupDir: dir.path
        )
        try JSONEncoder().encode(journal).write(
            to: URL(fileURLWithPath: RestoreCoordinator.journalPath(dbPath: dbURL.path)))

        let outcome = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path)
        guard case .rolledBack(let failure) = outcome else {
            Issue.record("expected rolledBack, got \(outcome)")
            return
        }
        #expect(failure.code == "RESTORE_BACKUP_INVALID")

        let stateURL = dir.appendingPathComponent("maintenance-state.json")
        let data = try Data(contentsOf: stateURL)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lastRestore = try #require(object["lastRestore"] as? [String: Any])
        #expect(lastRestore["errorCode"] as? String == "RESTORE_BACKUP_INVALID")
        #expect(lastRestore["result"] as? String == "rolledBack")
    }

    @Test("pre-restore 淘汰按套保留：主库与 sidecar 同生共死")
    func preRestorePruneKeepsWholeSets() throws {
        let dir = try makeTempDir("prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("gather.sqlite").path
        let base = (dbPath as NSString).lastPathComponent + ".pre-restore-"
        let stamps = ["20260101-000000", "20260102-000000", "20260103-000000"]
        for stamp in stamps {
            for suffix in ["", "-wal", "-shm"] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(base + stamp + suffix))
            }
        }

        RestoreCoordinator.prunePreRestore(dbPath: dbPath, keeping: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(base) }
        #expect(remaining.count == 6)
        #expect(remaining.contains(base + "20260102-000000"))
        #expect(remaining.contains(base + "20260102-000000-wal"))
        #expect(remaining.contains(base + "20260102-000000-shm"))
        #expect(remaining.contains(base + "20260103-000000"))
        #expect(!remaining.contains(base + "20260101-000000"))
    }

    @Test("只有一套恢复副本（含 sidecar）时不得被按文件数删掉主库")
    func preRestorePruneKeepsSingleSet() throws {
        let dir = try makeTempDir("prune-single")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("gather.sqlite").path
        let base = (dbPath as NSString).lastPathComponent + ".pre-restore-"
        let stamp = "20260104-000000"
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(base + stamp + suffix))
        }

        RestoreCoordinator.prunePreRestore(dbPath: dbPath, keeping: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(base) }
        #expect(remaining.count == 3)
        #expect(remaining.contains(base + stamp))
    }

    @Test("备份目录不可写时报 BACKUP_PERMISSION_DENIED，而不是 BACKUP_FAILED")
    func backupDirectoryNotWritable() async throws {
        let dir = try makeTempDir("perm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let database = try Database.open(at: dbURL.path)
        defer { database.close() }
        let settings = SettingsService(repo: SettingsRepo(connection: database.connection))
        // 把 backup_dir 指到一个普通文件：确保目录不可用。
        let notADir = dir.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: notADir)
        try settings.set("backup_dir", value: notADir.path)

        let service = MaintenanceService(database: database, settings: settings, appDir: dir)
        do {
            _ = try await service.backup(trigger: .manual)
            Issue.record("expected BACKUP_PERMISSION_DENIED")
        } catch let error as MaintenanceError {
            #expect(error.code == "BACKUP_PERMISSION_DENIED")
        }
    }
}
