// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+Maintenance.swift
// P0 / B0：设置页“数据与恢复”的 VM 状态与动作。
//
// 边界：只经 MaintenanceAPI 触发备份/恢复/诊断；恢复确认由 View 的 destructive
// confirm 负责，VM 只接收已确认的 BackupRecord。恢复跨进程：返回 receipt 后由
// View 提示退出应用，下次启动在 Database.open 前完成 swap。
import SwiftUI
import GatherProtocol

// MARK: - 设置键门禁

extension SettingsViewModel {
    /// 维护页直接读写的键（不走 SettingField 目录）；由 SettingsCatalogTests 纳入
    /// “UI 键 ⊆ defaults”门禁，避免又一个只存在于服务层的旋钮。
    static let maintenanceSettingKeys: [String] = [
        "backup_dir", "backup_retention", "backup_auto", "diagnostics_include_paths",
    ]
}

@MainActor
extension SettingsViewModel {
    var maintenanceAvailable: Bool { maintenanceAPI != nil }

    var maintenanceBackups: [BackupRecord] {
        maintenanceInventory?.backups ?? []
    }

    var maintenanceBackupDirectory: String {
        if let dir = maintenanceInventory?.backupDir, !dir.isEmpty { return dir }
        return values["backup_dir"] ?? ""
    }

    var maintenanceLastBackup: BackupRecord? {
        maintenanceInventory?.backups.first
    }

    var backupAutoMode: String { values["backup_auto"] ?? "off" }

    var backupRetention: Int {
        min(20, max(1, Int(values["backup_retention"] ?? "5") ?? 5))
    }

    var diagnosticsIncludePaths: Bool {
        (values["diagnostics_include_paths"] ?? "0") == "1"
    }

    // MARK: - 读取

    func loadMaintenance() async {
        guard let maintenanceAPI else { return }
        maintenanceBusy = true
        defer { maintenanceBusy = false }
        do {
            maintenanceInventory = try await maintenanceAPI.listBackups()
            maintenanceError = nil
        } catch {
            maintenanceError = CommandError(error)
        }
    }

    // MARK: - 备份

    func backupNow() async {
        guard let maintenanceAPI else { return }
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            let record = try await maintenanceAPI.backup(try MaintenanceBackupInput())
            maintenanceNotice = LocalizedText("备份已完成：%@", params: [record.fileName])
            await loadMaintenance()
        } catch {
            maintenanceError = CommandError(error)
        }
    }

    func saveBackupDirectory(_ path: String) async {
        await saveMaintenanceSetting(
            key: "backup_dir",
            value: path,
            notice: LocalizedText("备份目录已保存")
        )
        await loadMaintenance()
    }

    func saveBackupAuto(_ mode: String) async {
        guard ["off", "daily", "launch"].contains(mode) else { return }
        await saveMaintenanceSetting(
            key: "backup_auto",
            value: mode,
            notice: LocalizedText("自动备份设置已保存（下次启动生效）")
        )
    }

    func saveBackupRetention(_ count: Int) async {
        let clamped = min(20, max(1, count))
        await saveMaintenanceSetting(
            key: "backup_retention",
            value: "\(clamped)",
            notice: LocalizedText("备份保留份数已保存")
        )
    }

    // MARK: - 恢复

    /// 返回 true 表示已写入 journal、需要退出应用完成恢复。
    func restoreBackup(_ record: BackupRecord) async -> Bool {
        guard let maintenanceAPI else { return false }
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            let input = try RestoreBackupInput(fileName: record.fileName)
            let receipt = try await maintenanceAPI.restore(Confirmed(input, source: .userDialog))
            restoreReceipt = receipt
            maintenanceNotice = LocalizedText("恢复已准备，退出并重新打开 Gather 以完成。")
            await loadMaintenance()
            return true
        } catch {
            maintenanceError = CommandError(error)
            return false
        }
    }

    func cancelPendingRestore() async {
        guard let cancelRestore else { return }
        if await cancelRestore() {
            restoreReceipt = nil
            maintenanceNotice = LocalizedText("待完成恢复已取消")
            maintenanceError = nil
        } else {
            maintenanceError = CommandError.localized("取消失败：恢复已开始或状态不可取消")
        }
    }

    // MARK: - 诊断

    func saveDiagnosticsIncludePaths(_ include: Bool) async {
        await saveMaintenanceSetting(
            key: "diagnostics_include_paths",
            value: include ? "1" : "0",
            notice: LocalizedText("诊断设置已保存")
        )
    }

    func exportDiagnostics(to url: URL) async {
        guard let maintenanceAPI else { return }
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            let input = try DiagnosticsExportInput(
                destinationPath: url.path,
                includePaths: diagnosticsIncludePaths
            )
            let result = try await maintenanceAPI.exportDiagnostics(input)
            lastDiagnostics = result
            maintenanceNotice = LocalizedText("诊断包已导出：%@", params: [result.path])
        } catch {
            maintenanceError = CommandError(error)
        }
    }

    // MARK: - 设置写入

    private func saveMaintenanceSetting(key: String, value: String, notice: LocalizedText) async {
        do {
            try await settingsAPI.set(try SettingsSetInput(key: key, value: value))
            values[key] = value
            maintenanceError = nil
            maintenanceNotice = notice
        } catch {
            maintenanceError = CommandError(error)
        }
    }
}
