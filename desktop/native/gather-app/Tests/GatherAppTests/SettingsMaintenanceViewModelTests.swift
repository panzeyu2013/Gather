// desktop/native/gather-app/Tests/GatherAppTests/SettingsMaintenanceViewModelTests.swift
// P0 / B0：设置页“数据与恢复”VM 语义。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

private final class StubMaintenanceAPI: MaintenanceAPI, @unchecked Sendable {
    var inventory: MaintenanceInventory
    var backupRecord: BackupRecord
    var receipt: RestoreReceipt
    var diagnostics: DiagnosticsExportResult
    var error: (any Error)?
    var backupInputs: [MaintenanceBackupInput] = []
    var restoreInputs: [RestoreBackupInput] = []
    var diagnosticsInputs: [DiagnosticsExportInput] = []
    var listCalls = 0

    init() {
        let record = BackupRecord(
            fileName: "Gather-Backup-20261025-010000.sqlite",
            createdAt: "2026-10-25T01:00:00.000Z",
            sizeBytes: 2_048,
            schemaVersion: 3,
            tableCount: 45,
            trigger: .manual,
            verified: true,
            sha256: "abc"
        )
        inventory = MaintenanceInventory(
            backupDir: "/tmp/Gather/Backups",
            backups: [record],
            lastRestore: nil,
            autoPaused: false
        )
        backupRecord = record
        receipt = RestoreReceipt(
            backupFileName: record.fileName,
            schemaVersion: 3,
            requiresRestart: true,
            journalPath: "/tmp/Gather/restore-pending.json",
            verifiedAt: "2026-10-25T01:01:00.000Z"
        )
        diagnostics = DiagnosticsExportResult(
            path: "/tmp/Gather-Diagnostics.zip",
            sizeBytes: 1024,
            logFileCount: 3,
            redactedPaths: true
        )
    }

    func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord {
        if let error { throw error }
        backupInputs.append(input)
        return backupRecord
    }

    func listBackups() async throws -> MaintenanceInventory {
        if let error { throw error }
        listCalls += 1
        return inventory
    }

    func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt {
        if let error { throw error }
        restoreInputs.append(input.value)
        return receipt
    }

    func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult {
        if let error { throw error }
        diagnosticsInputs.append(input)
        return diagnostics
    }
}

@Suite("settings 维护 VM")
@MainActor
struct SettingsMaintenanceViewModelTests {
    private func makeVM(
        maintenance: (any MaintenanceAPI)?,
        values: [String: String] = ["backup_auto": "off", "diagnostics_include_paths": "0"],
        cancelPendingRestore: (() async -> Bool)? = nil
    ) -> (SettingsViewModel, B8SettingsAPIStub) {
        let settings = B8SettingsAPIStub(values: values)
        let viewModel = SettingsViewModel(
            session: B8SessionAPIStub(),
            settings: settings,
            culling: B8CullingAPIStub(),
            captureOne: CaptureOneBridge(),
            languageStore: LanguageStore(language: .zhCN, notificationCenter: NotificationCenter()),
            maintenance: maintenance,
            cancelPendingRestore: cancelPendingRestore
        )
        return (viewModel, settings)
    }

    @Test("加载备份清单")
    func loadInventory() async {
        let api = StubMaintenanceAPI()
        let (viewModel, _) = makeVM(maintenance: api)

        await viewModel.loadMaintenance()

        #expect(viewModel.maintenanceAvailable)
        #expect(viewModel.maintenanceBackups.count == 1)
        #expect(viewModel.maintenanceBackupDirectory == "/tmp/Gather/Backups")
        #expect(viewModel.maintenanceError == nil)
    }

    @Test("保留份数 clamp 1...20 并写入设置")
    func saveBackupRetention() async {
        let (viewModel, settings) = makeVM(
            maintenance: StubMaintenanceAPI(),
            values: ["backup_auto": "off", "backup_retention": "5"])
        #expect(viewModel.backupRetention == 5)
        await viewModel.saveBackupRetention(50)
        #expect(viewModel.values["backup_retention"] == "20")
        #expect(settings.setInputs.last?.key.value == "backup_retention")
        #expect(settings.setInputs.last?.value.value == "20")
    }

    @Test("取消待恢复：成功清空 receipt 并提示")
    func cancelPendingRestore() async {
        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag()
        let (viewModel, _) = makeVM(
            maintenance: StubMaintenanceAPI(),
            cancelPendingRestore: {
                flag.value = true
                return true
            })
        viewModel.restoreReceipt = StubMaintenanceAPI().receipt
        await viewModel.cancelPendingRestore()
        #expect(flag.value)
        #expect(viewModel.restoreReceipt == nil)
        #expect(viewModel.maintenanceNotice != nil)
    }

    @Test("立即备份成功后刷新清单并提示")
    func backupNow() async {
        let api = StubMaintenanceAPI()
        let (viewModel, _) = makeVM(maintenance: api)

        await viewModel.backupNow()

        #expect(api.backupInputs.count == 1)
        #expect(viewModel.maintenanceNotice?.key == "备份已完成：%@")
        #expect(viewModel.maintenanceError == nil)
        #expect(api.listCalls >= 1)
    }

    @Test("恢复返回 requiresRestart 的 receipt")
    func restorePrepared() async {
        let api = StubMaintenanceAPI()
        let (viewModel, _) = makeVM(maintenance: api)

        let ok = await viewModel.restoreBackup(api.backupRecord)

        #expect(ok)
        #expect(api.restoreInputs.first?.fileName == api.backupRecord.fileName)
        #expect(viewModel.restoreReceipt?.requiresRestart == true)
        #expect(viewModel.maintenanceError == nil)
    }

    @Test("诊断导出携带 includePaths 设置")
    func exportDiagnostics() async {
        let api = StubMaintenanceAPI()
        let (viewModel, _) = makeVM(
            maintenance: api,
            values: ["backup_auto": "off", "diagnostics_include_paths": "1"]
        )
        // 生产路径由设置页 .task 的 load() 回填 values；单测直接落值。
        viewModel.values["diagnostics_include_paths"] = "1"

        await viewModel.exportDiagnostics(to: URL(fileURLWithPath: "/tmp/diagnostics.zip"))

        #expect(api.diagnosticsInputs.first?.includePaths == true)
        #expect(viewModel.lastDiagnostics?.path == "/tmp/Gather-Diagnostics.zip")
        #expect(viewModel.maintenanceError == nil)
    }

    @Test("自动备份设置写入 settings API")
    func saveBackupAuto() async {
        let (viewModel, settings) = makeVM(maintenance: StubMaintenanceAPI())

        await viewModel.saveBackupAuto("daily")

        #expect(settings.setInputs.contains {
            $0.key.value == "backup_auto" && $0.value.value == "daily"
        })
        #expect(viewModel.values["backup_auto"] == "daily")
    }

    @Test("MaintenanceAPI 为 nil 时分区隐藏且动作 no-op")
    func nilMaintenance() async {
        let (viewModel, _) = makeVM(maintenance: nil)

        #expect(!viewModel.maintenanceAvailable)
        await viewModel.loadMaintenance()
        await viewModel.backupNow()
        #expect(viewModel.maintenanceInventory == nil)
        #expect(viewModel.maintenanceError == nil)
    }

    @Test("备份失败映射为错误")
    func backupFailure() async {
        let api = StubMaintenanceAPI()
        api.error = GatherError(code: .BACKUP_BUSY)
        let (viewModel, _) = makeVM(maintenance: api)

        await viewModel.backupNow()

        #expect(viewModel.maintenanceError != nil)
        #expect(viewModel.maintenanceNotice == nil)
    }
}
