// desktop/native/gather-core/Tests/GatherCoreTests/Maintenance/BackupPerfTests.swift
// P0 / B0：2GB 备份性能门（默认跳过；GATHER_BACKUP_PERF=1 运行）。
// 只测备份服务（VACUUM INTO + 校验 + SHA-256 + sidecar），不测恢复/诊断。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

private let backupPerfEnabled = ProcessInfo.processInfo.environment["GATHER_BACKUP_PERF"] == "1"

@Suite("B0 2GB 备份性能")
struct BackupPerfTests {
    // skip-owner: p0-perf
    // 到期：2027-06-30
    // 原因：2GB 备份是发布前性能门，默认套件跳过，避免日常写入 2GB 临时库。
    // 手动条件：GATHER_BACKUP_PERF=1 swift test --filter BackupPerf
    @Test(.enabled(if: backupPerfEnabled))
    func twoGigabyteBackupWithinBudget() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-b0-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("gather.sqlite")
        let database = try Database.open(at: dbURL.path)
        defer { database.close() }
        _ = try database.connection.prepare("""
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s', 'perf', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """).run([])

        let photo = try database.connection.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
            VALUES (?, 's', ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """)
        let cache = try database.connection.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, keywords, cached_at, updated_at)
            VALUES (?, 's', zeroblob(100000), '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """)
        try database.connection.exec("BEGIN")
        for index in 0..<20_000 {
            let id = String(format: "p%05d", index)
            _ = try photo.run([.text(id), .text("/s/\(id).jpg"), .text("\(id).jpg")])
            _ = try cache.run([.text(id)])
        }
        try database.connection.exec("COMMIT")
        _ = try database.connection.exec("PRAGMA wal_checkpoint(TRUNCATE);")

        let attributes = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        #expect(bytes > 1_900_000_000, "测试库未达到 2GB：\(bytes)")

        let settings = SettingsService(repo: SettingsRepo(connection: database.connection))
        let service = MaintenanceService(database: database, settings: settings, appDir: dir)
        let started = DispatchTime.now().uptimeNanoseconds
        let record = try await service.backup(trigger: .manual)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        print("PERF backup size=\(bytes) backupBytes=\(record.sizeBytes) elapsed=\(String(format: "%.2f", elapsed))s")
        #expect(record.verified)
        #expect(elapsed < 30, "2GB 备份超过 30s：\(elapsed)s")
    }
}
