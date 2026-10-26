// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/MaintenanceService.swift
// P0 / B0：备份 / 恢复（跨进程 journal）/ 诊断导出。不建表，不修改 XMP/照片。
import Foundation
import GatherProtocol
import GatherPersistence

public struct MaintenanceStateFile: Codable, Sendable, Equatable {
    public var autoPaused: Bool
    public var consecutiveFailures: Int
    public var lastRestore: RestoreOutcome?

    public init(autoPaused: Bool = false, consecutiveFailures: Int = 0, lastRestore: RestoreOutcome? = nil) {
        self.autoPaused = autoPaused
        self.consecutiveFailures = consecutiveFailures
        self.lastRestore = lastRestore
    }

    private enum CodingKeys: String, CodingKey {
        case autoPaused, consecutiveFailures, lastRestore
    }

    /// RestoreSupport 在“首次恢复失败”时只写 lastRestore；其余字段必须可缺省，
    /// 否则整份 state 解码失败，设置页就看不到恢复结果。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoPaused = try container.decodeIfPresent(Bool.self, forKey: .autoPaused) ?? false
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        lastRestore = try container.decodeIfPresent(RestoreOutcome.self, forKey: .lastRestore)
    }
}

public actor MaintenanceService {
    private let database: Database?
    private let settings: SettingsService
    private let appDir: URL
    private let backupStore: BackupStore
    private let stateURL: URL
    private let isOtherInstanceRunning: @Sendable () -> Bool
    private var isBackingUp = false
    /// 内存镜像：状态文件写失败（磁盘满）时自动暂停仍必须生效。
    private var memoryAutoPaused = false
    private var memoryConsecutiveFailures = 0
    private var restoreLock: RestoreLock?
    private var scheduler: DispatchSourceTimer?
    private let schedulerQueue = DispatchQueue(label: "gather.maintenance.scheduler")

    public init(
        database: Database?,
        settings: SettingsService,
        appDir: URL,
        isOtherInstanceRunning: @escaping @Sendable () -> Bool = { false }
    ) {
        self.database = database
        self.settings = settings
        self.appDir = appDir
        self.backupStore = BackupStore(directory: appDir.appendingPathComponent("Backups", isDirectory: true))
        self.stateURL = appDir.appendingPathComponent("maintenance-state.json")
        self.isOtherInstanceRunning = isOtherInstanceRunning
    }

    private func beginBackup() -> Bool {
        if isBackingUp { return false }
        isBackingUp = true
        return true
    }

    private func endBackup() {
        isBackingUp = false
    }

    private func backupBusy() -> Bool {
        isBackingUp
    }

    // MARK: - 备份

    public func backup(trigger: BackupTrigger = .manual) async throws -> BackupRecord {
        do {
            return try await backupImpl(trigger: trigger)
        } catch let error as MaintenanceError {
            // busy/restoreBusy 不是备份失败（用户连点/恢复占用），不计入自动暂停。
            switch error {
            case .backupBusy, .restoreBusy:
                throw error
            default:
                recordBackupFailure()
                throw error
            }
        } catch {
            recordBackupFailure()
            throw error
        }
    }

    /// 连续 3 次失败自动暂停；覆盖权限/空间/第二连接/checkpoint/VACUUM 等前置失败，
    /// 不再只有 VACUUM 之后的 catch 计数。
    private func recordBackupFailure() {
        memoryConsecutiveFailures += 1
        if memoryConsecutiveFailures >= 3 { memoryAutoPaused = true }
        updateState { state in
            state.consecutiveFailures += 1
            if state.consecutiveFailures >= 3 { state.autoPaused = true }
        }
    }

    private func backupImpl(trigger: BackupTrigger) async throws -> BackupRecord {
        guard let database else {
            throw MaintenanceError.backupFailed("数据库不可用")
        }
        guard beginBackup() else {
            throw MaintenanceError.backupBusy
        }
        defer { endBackup() }

        let dbPath = database.path
        guard !RestoreCoordinator.hasPending(dbPath: dbPath) else {
            throw MaintenanceError.restoreBusy
        }
        // 多实例：同一 appDir 只允许一个备份进程，避免争同一 partial/最终名。
        let backupLock: BackupLock
        do {
            backupLock = try BackupLock.acquire(at: appDir)
        } catch {
            throw MaintenanceError.backupBusy
        }
        defer { backupLock.release() }
        // 拿锁后重查：restore 可能在“查 journal”和“拿锁”之间写入 journal。
        guard !RestoreCoordinator.hasPending(dbPath: dbPath) else {
            throw MaintenanceError.restoreBusy
        }
        let directory = try resolvedBackupDirectory()
        let store = BackupStore(directory: directory)
        do {
            try store.ensureDirectory()
            store.removeStalePartials()
            // 目录可能早已存在且是 0755；在写入任何库内容前先收紧到 0700。
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try Self.probeWritable(directory: directory)
        } catch {
            throw MaintenanceError.backupPermissionDenied("无法写备份目录：\(error)")
        }
        let dbSize = BestEffort.value("backup db size", default: 0) {
            try FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64 ?? 0
        }
        let needed = Int64(Double(dbSize) * 1.15) + 64 * 1024 * 1024
        let available = Self.availableBytes(at: directory)
        guard available >= needed else {
            throw MaintenanceError.backupInsufficientSpace(needed: needed, available: available)
        }

        let urls = store.newURLs(now: Date())
        let connection: DBConnection
        do {
            connection = try DBConnection(path: dbPath)
        } catch {
            throw MaintenanceError.backupFailed("第二连接打开失败：\(error)")
        }
        defer { connection.close() }

        // 用第二连接 checkpoint：主连接被 UI 读/写持锁时，TRUNCATE 会卡住主线程。
        BestEffort.attempt("backup wal checkpoint") {
            _ = try connection.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        let escaped = urls.partial.path.replacingOccurrences(of: "'", with: "''")
        var attempt = 0
        while true {
            // 每次重试前清掉残留：VACUUM INTO 目标已存在必然失败，会掩盖真实原因。
            BestEffort.attempt("remove stale partial backup") {
                try FileManager.default.removeItem(atPath: urls.partial.path)
            }
            do {
                try connection.exec("VACUUM INTO '\(escaped)';")
                break
            } catch {
                attempt += 1
                if attempt >= 3 {
                    BestEffort.attempt("remove partial backup") {
                        try FileManager.default.removeItem(at: urls.partial)
                    }
                    let message = "\(error)"
                    let lowered = message.lowercased()
                    // sqlite3_errmsg 的文案是 "database is locked" / "disk is full"，
                    // 不是 SQLITE_BUSY/SQLITE_FULL 常量名。
                    if lowered.contains("locked") || lowered.contains("busy") {
                        throw MaintenanceError.backupBusy
                    }
                    if lowered.contains("full") || lowered.contains("no space") {
                        throw MaintenanceError.backupInsufficientSpace(needed: needed, available: available)
                    }
                    throw MaintenanceError.backupFailed("VACUUM INTO 失败：\(message)")
                }
                await BestEffort.sleep(seconds: 1)
            }
        }

        do {
            // VACUUM INTO 产物在 rename 前就可能被读取；先收紧到 0600 再校验。
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: urls.partial.path)
            } catch {
                throw MaintenanceError.backupPermissionDenied("无法设置备份权限：\(error)")
            }
            let verification = try BackupVerifier.verify(path: urls.partial.path)
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let record = BackupRecord(
                fileName: urls.final.lastPathComponent,
                createdAt: createdAt,
                sizeBytes: verification.sizeBytes,
                schemaVersion: verification.schemaVersion,
                tableCount: verification.tableCount,
                trigger: trigger,
                verified: true,
                sha256: verification.sha256
            )
            BestEffort.attempt("remove previous backup") {
                try FileManager.default.removeItem(at: urls.final)
            }
            try FileManager.default.moveItem(atPath: urls.partial.path, toPath: urls.final.path)
            // 库内含照片路径与人脸向量：权限设置失败必须让备份失败，而不是留 0644。
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: urls.final.path)
            } catch {
                throw MaintenanceError.backupPermissionDenied("无法设置备份权限：\(error)")
            }
            // sidecar 最后写：前面的任何失败都不会留下“有 sidecar、没库”的孤儿。
            do {
                let sidecar = BackupSidecar(record: record, appVersion: Self.appVersion)
                let data = try JSONEncoder().encode(sidecar)
                try data.write(to: urls.sidecar, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: urls.sidecar.path)
            } catch {
                throw MaintenanceError.backupFailed("写入备份描述失败：\(error)")
            }
            // 待执行恢复引用的备份永不淘汰（b0 §6）。
            let protected: Set<String>
            do {
                protected = Set(try RestoreCoordinator.pendingBackupFileName(dbPath: dbPath)
                    .map { [$0] } ?? [])
            } catch {
                GatherLogger.log(
                    "read pending restore backup name failed: \(error)", level: .warn)
                protected = []
            }
            BestEffort.attempt("prune backups") {
                try store.prune(keeping: retentionLimit(), protecting: protected)
            }
            BestEffort.attempt("chmod backup directory") {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            memoryConsecutiveFailures = 0
            memoryAutoPaused = false
            updateState { state in
                state.consecutiveFailures = 0
                state.autoPaused = false
            }
            return record
        } catch {
            BestEffort.attempt("cleanup partial backup") {
                try FileManager.default.removeItem(at: urls.partial)
            }
            BestEffort.attempt("cleanup backup sidecar") {
                try FileManager.default.removeItem(at: urls.sidecar)
            }
            // 本次已 rename 成功但后续（chmod/sidecar/prune）失败：删掉 final，
            // 避免列表里出现“未校验/无 sidecar”的孤儿备份。
            BestEffort.attempt("cleanup failed backup") {
                try FileManager.default.removeItem(at: urls.final)
            }
            if let maintenance = error as? MaintenanceError { throw maintenance }
            throw MaintenanceError.backupVerifyFailed("\(error)")
        }
    }

    public func listBackups() throws -> MaintenanceInventory {
        let directory = try resolvedBackupDirectory()
        let store = BackupStore(directory: directory)
        let state = readState()
        return MaintenanceInventory(
            backupDir: directory.path,
            backups: BestEffort.value("list backups", default: [BackupRecord]()) {
                try store.list()
            },
            lastRestore: state.lastRestore,
            autoPaused: state.autoPaused || memoryAutoPaused
        )
    }

    // MARK: - 恢复

    /// 取消尚未在启动时执行的恢复；只允许 prepared/opened journal。
    public func cancelPendingRestore() throws {
        guard let database else { throw MaintenanceError.restoreFailed("数据库不可用") }
        if let existing = restoreLock {
            do {
                try RestoreCoordinator.cancelPending(dbPath: database.path)
            } catch {
                // 不可取消（oldMoved/newInstalled）也不能永久占锁；
                // 释放后由 UI 提示并交给下次启动恢复/回滚。
                existing.release()
                restoreLock = nil
                throw error
            }
            existing.release()
            restoreLock = nil
            return
        }
        let lock: RestoreLock
        do {
            lock = try RestoreLock.acquire(at: appDir)
        } catch {
            throw MaintenanceError.restoreBusy
        }
        defer { lock.release() }
        try RestoreCoordinator.cancelPending(dbPath: database.path)
    }

    public func restore(_ input: RestoreBackupInput) async throws -> RestoreReceipt {
        guard let database else { throw MaintenanceError.restoreFailed("数据库不可用") }
        if isOtherInstanceRunning() { throw MaintenanceError.restoreBusy }
        guard !RestoreCoordinator.hasPending(dbPath: database.path) else {
            throw MaintenanceError.restoreBusy
        }
        if backupBusy() { throw MaintenanceError.restoreBusy }
        // 与备份共用同一把目录锁：避免 backup 刚通过 journal 检查、restore 又写 journal 的竞态。
        var backupGuard: BackupLock?
        do {
            backupGuard = try BackupLock.acquire(at: appDir)
        } catch {
            throw MaintenanceError.restoreBusy
        }
        defer { backupGuard?.release() }

        let directory = try resolvedBackupDirectory()
        guard input.fileName.hasPrefix("Gather-Backup-"), input.fileName.hasSuffix(".sqlite") else {
            throw MaintenanceError.restoreVerifyFailed("不在托管备份目录")
        }
        let backupURL = directory.appendingPathComponent(input.fileName)
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw MaintenanceError.restoreVerifyFailed("备份不存在")
        }
        let verification: BackupVerification
        do {
            verification = try BackupVerifier.verify(path: backupURL.path)
        } catch let error as MaintenanceError {
            if case .restoreVersionUnsupported = error { throw error }
            throw MaintenanceError.restoreVerifyFailed("\(error)")
        } catch {
            throw MaintenanceError.restoreVerifyFailed("\(error)")
        }
        let available = Self.availableBytes(at: URL(fileURLWithPath: database.path).deletingLastPathComponent())
        let needed = verification.sizeBytes + 128 * 1024 * 1024
        guard available >= needed else {
            throw MaintenanceError.restoreInsufficientSpace(needed: needed, available: available)
        }
        // 恢复要移动主库并写 journal：目录不可写时必须报权限码，而不是走到 swap 才失败。
        do {
            try Self.probeWritable(
                directory: URL(fileURLWithPath: database.path).deletingLastPathComponent())
        } catch {
            throw MaintenanceError.restorePermissionDenied("数据目录不可写：\(error)")
        }

        let lockObject: RestoreLock
        do {
            lockObject = try RestoreLock.acquire(at: appDir)
        } catch {
            throw MaintenanceError.restoreBusy
        }
        let stamp = Self.timestamp()
        let dbPath = database.path
        let journal = RestoreJournal(
            state: .prepared,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            backupFileName: input.fileName,
            backupPath: backupURL.path,
            backupSHA256: verification.sha256,
            backupSchemaVersion: verification.schemaVersion,
            dbPath: dbPath,
            preRestorePath: dbPath + ".pre-restore-\(stamp)",
            stagingPath: dbPath + ".restore-\(UUID().uuidString).tmp",
            backupDir: directory.path
        )
        do {
            let data = try JSONEncoder().encode(journal)
            try data.write(to: URL(fileURLWithPath: RestoreCoordinator.journalPath(dbPath: dbPath)), options: .atomic)
        } catch {
            lockObject.release()
            throw MaintenanceError.restoreFailed("写入恢复 journal 失败：\(error)")
        }
        // journal 已落盘：backup 现在会被 hasPending 拦截，可释放目录锁。
        backupGuard?.release()
        backupGuard = nil
        restoreLock = lockObject
        return RestoreReceipt(
            backupFileName: input.fileName,
            schemaVersion: verification.schemaVersion,
            requiresRestart: true,
            journalPath: RestoreCoordinator.journalPath(dbPath: dbPath),
            verifiedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - 诊断

    public func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult {
        let includePaths = input.includePaths
            ?? (settings.get("diagnostics_include_paths", defaultValue: "0") == "1")
        let collector = DiagnosticsCollector(database: database, settings: settings, appDir: appDir)
        do {
            return try collector.collect(
                destination: URL(fileURLWithPath: input.destinationPath),
                includePaths: includePaths
            )
        } catch {
            if let maintenance = error as? MaintenanceError { throw maintenance }
            throw MaintenanceError.diagnosticsExportFailed("\(error)")
        }
    }

    // MARK: - 调度

    public func startScheduler() {
        let mode = settings.get("backup_auto", defaultValue: "off")
        scheduler?.cancel()
        scheduler = nil
        switch mode {
        case "launch":
            // 启动模式：每次启动一次，不沿用 daily 的 24h 守卫，也不重复。
            let timer = DispatchSource.makeTimerSource(queue: schedulerQueue)
            timer.schedule(deadline: .now() + 60)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Task {
                    await BestEffort.run("auto backup launch") {
                        try await self.autoBackupIfDue(launch: true)
                    }
                    await self.stopScheduler()
                }
            }
            scheduler = timer
            timer.resume()
        case "daily":
            let timer = DispatchSource.makeTimerSource(queue: schedulerQueue)
            timer.schedule(deadline: .now() + 60, repeating: 6 * 3600)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Task {
                    await BestEffort.run("auto backup daily") {
                        try await self.autoBackupIfDue(launch: false)
                    }
                }
            }
            scheduler = timer
            timer.resume()
        default:
            break
        }
    }

    public func stopScheduler() {
        scheduler?.cancel()
        scheduler = nil
    }

    public func waitForBackup(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !backupBusy() { return }
            await BestEffort.pause(milliseconds: 100)
        }
    }

    private func autoBackupIfDue(launch: Bool) async throws {
        let state = readState()
        guard !memoryAutoPaused, !state.autoPaused else { return }
        guard !RestoreCoordinator.hasPending(dbPath: database?.path ?? "") else { return }
        if launch {
            _ = try await backup(trigger: .autoLaunch)
            return
        }
        let records = BestEffort.value("list backups for scheduler", default: [BackupRecord]()) {
            try listBackups().backups
        }
        if let latest = records.first,
           let date = ISO8601DateFormatter().date(from: latest.createdAt),
           Date().timeIntervalSince(date) < 24 * 3600 {
            return
        }
        _ = try await backup(trigger: .autoDaily)
    }

    // MARK: - 工具

    private func resolvedBackupDirectory() throws -> URL {
        let raw = settings.get("backup_dir", defaultValue: "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return backupStore.directory }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw MaintenanceError.backupPermissionDenied("备份目录必须是绝对路径")
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func retentionLimit() -> Int {
        Int(settings.get("backup_retention", defaultValue: "5")) ?? 5
    }

    private func readState() -> MaintenanceStateFile {
        guard let data = BestEffort.optional("read maintenance state", {
                try Data(contentsOf: stateURL)
              }),
              let state = BestEffort.optional("decode maintenance state", {
                try JSONDecoder().decode(MaintenanceStateFile.self, from: data)
              })
        else { return MaintenanceStateFile() }
        return state
    }

    private func updateState(_ mutate: (inout MaintenanceStateFile) -> Void) {
        var state = readState()
        mutate(&state)
        if let data = BestEffort.optional("encode maintenance state", {
            try JSONEncoder().encode(state)
        }) {
            BestEffort.attempt("write maintenance state") {
                try data.write(to: stateURL, options: .atomic)
            }
        }
    }

    /// 写探针：只读目录在 VACUUM INTO 时才失败，错误会落成 BACKUP_FAILED 而非权限码。
    private static func probeWritable(directory: URL) throws {
        let probe = directory.appendingPathComponent(".gather-write-probe-\(UUID().uuidString)")
        try Data([0]).write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
    }

    private static func availableBytes(at url: URL) -> Int64 {
        BestEffort.value("available bytes", default: 0) {
            try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
