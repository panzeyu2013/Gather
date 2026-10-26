// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/DiagnosticsCollector.swift
// P0 / B0：诊断包（manifest/tables/jobs/settings/logs/README → zip），默认脱敏。
//
// SQL 已下沉到 GatherPersistence.DiagnosticsQuery；本文件只消费结果。
// 所有 best-effort 清理/属性操作走 BestEffort，失败有日志、不静默吞错。
import Foundation
import GatherProtocol
import GatherPersistence

public struct DiagnosticsCollector {
    private let database: Database?
    private let diagnostics: DiagnosticsQuery?
    private let settings: SettingsService
    private let appDir: URL
    private let logDirectory: URL
    private let maxBundleBytes: Int64
    private let logBudgetBytes: Int

    public init(
        database: Database?,
        settings: SettingsService,
        appDir: URL,
        maxBundleBytes: Int64 = 20 * 1024 * 1024,
        logBudgetBytes: Int = 15 * 1024 * 1024
    ) {
        self.database = database
        self.diagnostics = database.map { DiagnosticsQuery(connection: $0.connection) }
        self.settings = settings
        self.appDir = appDir
        self.logDirectory = appDir.appendingPathComponent("Logs", isDirectory: true)
        self.maxBundleBytes = maxBundleBytes
        self.logBudgetBytes = logBudgetBytes
    }

    public func collect(destination: URL, includePaths: Bool) throws -> DiagnosticsExportResult {
        let fm = FileManager.default
        let staging = appDir.appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        let logsDir = staging.appendingPathComponent("logs", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            throw MaintenanceError.diagnosticsExportFailed("创建暂存目录失败：\(error)")
        }
        defer {
            BestEffort.attempt("remove diagnostics staging") {
                try fm.removeItem(at: staging)
            }
        }

        let manifest = try makeManifest(includePaths: includePaths)
        try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))
        try writeJSON(try makeTables(), to: staging.appendingPathComponent("tables.json"))
        try writeJSON(try makeJobs(), to: staging.appendingPathComponent("jobs.json"))
        try writeJSON(makeSettings(includePaths: includePaths), to: staging.appendingPathComponent("settings.json"))

        let logFiles = try copyLogs(to: logsDir, includePaths: includePaths)
        let readme = """
        Gather diagnostics bundle
        Created: \(ISO8601DateFormatter().string(from: Date()))
        Paths included: \(includePaths ? "yes" : "no")

        This bundle contains logs, settings (redacted by default), database statistics,
        and recent job metadata. It does NOT contain photos, XMP, thumbnails, face vectors,
        or the database file itself.
        """
        try Data(readme.utf8).write(to: staging.appendingPathComponent("README.txt"), options: .atomic)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let partial = destination.appendingPathExtension("partial")
        let limit = maxBundleBytes
        var size = try makeArchive(staging: staging, destination: partial)
        // 超限时优先丢最旧日志再打包；仍超限才失败（禁止静默给超大包）。
        var attempts = 0
        while size > limit, attempts < 3 {
            let names = BestEffort.value("list trim logs", default: [String]()) {
                try fm.contentsOfDirectory(atPath: logsDir.path)
                    .filter { $0.hasSuffix(".log") }
                    .sorted()
            }
            guard !names.isEmpty else { break }
            let removeCount = max(1, names.count / 2)
            for name in names.prefix(removeCount) {
                BestEffort.attempt("remove oversized log") {
                    try fm.removeItem(at: logsDir.appendingPathComponent(name))
                }
            }
            size = try makeArchive(staging: staging, destination: partial)
            attempts += 1
        }
        guard size <= limit else {
            BestEffort.attempt("remove oversized diagnostics") {
                try fm.removeItem(at: partial)
            }
            throw MaintenanceError.diagnosticsExportFailed("诊断包超过 20MB")
        }
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                BestEffort.attempt("remove partial diagnostics") {
                    try fm.removeItem(at: partial)
                }
                throw MaintenanceError.diagnosticsExportFailed("目标路径是目录，请选择 .zip 文件")
            }
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }
        BestEffort.attempt("chmod diagnostics") {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let finalLogCount = BestEffort.value("count final logs", default: logFiles) {
            try fm.contentsOfDirectory(atPath: logsDir.path)
                .filter { $0.hasSuffix(".log") }.count
        }
        return DiagnosticsExportResult(
            path: destination.path, sizeBytes: size,
            logFileCount: finalLogCount, redactedPaths: !includePaths
        )
    }

    private func makeArchive(staging: URL, destination: URL) throws -> Int64 {
        let fm = FileManager.default
        BestEffort.attempt("remove partial diagnostics") {
            try fm.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", staging.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MaintenanceError.diagnosticsExportFailed("ditto 启动失败：\(error)")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            BestEffort.attempt("remove failed diagnostics") {
                try fm.removeItem(at: destination)
            }
            throw MaintenanceError.diagnosticsExportFailed("ditto 失败：\(message)")
        }
        let size = BestEffort.value("diagnostics size", default: 0) {
            try fm.attributesOfItem(atPath: destination.path)[.size] as? Int64 ?? 0
        }
        guard size > 0 else {
            BestEffort.attempt("remove unreadable diagnostics") {
                try fm.removeItem(at: destination)
            }
            throw MaintenanceError.diagnosticsExportFailed("无法读取诊断包大小")
        }
        return size
    }

    private func makeManifest(includePaths: Bool) throws -> [String: Any] {
        let fm = FileManager.default
        let dbPath = database?.path ?? ""
        let dbSize = BestEffort.value("diagnostics db size", default: 0) {
            try fm.attributesOfItem(atPath: dbPath)[.size] as? Int64 ?? 0
        }
        let walSize = BestEffort.value("diagnostics wal size", default: 0) {
            try fm.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int64 ?? 0
        }
        var manifest: [String: Any] = [
            "formatVersion": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": ProcessInfo.processInfo.machineHardwareName,
            "includePaths": includePaths,
            "dbSizeBytes": dbSize,
            "walSizeBytes": walSize,
            "tableCount": tableCount(),
            "schemaVersion": schemaVersion(),
            "recentJobCount": recentJobCount(),
        ]
        if includePaths {
            manifest["dbPath"] = dbPath
            manifest["appDir"] = appDir.path
        }
        return manifest
    }

    private func schemaVersion() -> Int {
        guard let diagnostics else { return 0 }
        return BestEffort.value("diagnostics schema version", default: 0) {
            try diagnostics.schemaVersion()
        }
    }

    private func recentJobCount() -> Int {
        guard let diagnostics else { return 0 }
        return BestEffort.value("diagnostics recent job count", default: 0) {
            try diagnostics.recentJobs(limit: 50).count
        }
    }

    private func tableCount() -> Int {
        guard let diagnostics else { return 0 }
        return BestEffort.value("diagnostics table count", default: 0) {
            try diagnostics.tableCount()
        }
    }

    private func makeTables() throws -> [String: Any] {
        guard let diagnostics else { return [:] }
        var result: [String: Any] = [:]
        for table in ["photos", "sessions", "face_observations", "analysis_jobs", "deliveries"] {
            result[table] = BestEffort.value("diagnostics table count \(table)", default: 0) {
                try diagnostics.tableCount(table)
            }
        }
        return result
    }

    private func makeJobs() throws -> [[String: Any]] {
        guard let diagnostics else { return [] }
        let rows = BestEffort.value("diagnostics recent jobs", default: [DiagnosticsJobRow]()) {
            try diagnostics.recentJobs(limit: 50)
        }
        return rows.map { row in
            [
                "id": row.id,
                "type": row.type,
                "status": row.status,
                "progressCurrent": row.progressCurrent,
                "progressTotal": row.progressTotal,
                "errorCode": row.errorCode ?? NSNull(),
            ]
        }
    }

    private func makeSettings(includePaths: Bool) -> [String: String] {
        var result = settings.getAll()
        if !includePaths {
            for key in result.keys where key.contains("dir") || key.contains("path") {
                result[key] = "<path>"
            }
            for key in result.keys {
                result[key] = result[key]?.redactedPath
            }
        }
        return result
    }

    private func copyLogs(to directory: URL, includePaths: Bool) throws -> Int {
        let fm = FileManager.default
        guard let names = BestEffort.optional("list diagnostics logs", {
            try fm.contentsOfDirectory(atPath: logDirectory.path)
        }) else { return 0 }
        var copied = 0
        var budget = logBudgetBytes
        for name in names.sorted(by: >) where name.hasSuffix(".log") {
            let source = logDirectory.appendingPathComponent(name)
            let size = BestEffort.value("diagnostics log size", default: 0) {
                try fm.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
            }
            // 单个超大日志跳过，继续尝试更旧但更小的日志，避免诊断包完全无日志。
            if size > budget { continue }
            var content = BestEffort.value("read diagnostics log", default: "") {
                try String(contentsOf: source, encoding: .utf8)
            }
            if !includePaths { content = content.redactingPaths }
            try Data(content.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
            budget -= size
            copied += 1
        }
        return copied
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

extension String {
    /// 默认诊断包不得出现任何用户绝对路径；只放行已知根目录前缀，
    /// 避免把日志里的 `/api/v1` 之类相对片段误伤。
    ///
    /// 路径里可以含空格（`Application Support`），因此不能按空白截断：
    /// 从已知根开始一直遮蔽到行尾/引号，宁可多遮蔽也不泄露用户目录。
    static let absolutePathPattern = #"(?<![A-Za-z0-9_])/(?:Users|Volumes|private|tmp|var|opt|mnt|home|root|Applications|Library|Network|System|cores|data|srv|run|etc)/[^"\n]*"#

    var redactedPath: String {
        replacingOccurrences(
            of: Self.absolutePathPattern, with: "<path>", options: .regularExpression)
    }
    var redactingPaths: String {
        replacingOccurrences(
            of: Self.absolutePathPattern, with: "<path>", options: .regularExpression)
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
