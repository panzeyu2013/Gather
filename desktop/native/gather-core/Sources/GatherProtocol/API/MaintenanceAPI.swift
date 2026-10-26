// desktop/native/gather-core/Sources/GatherProtocol/API/MaintenanceAPI.swift
// P0 / B0：维护域（第 17 协议，4 个方法）。
import Foundation

public protocol MaintenanceAPI: Sendable {
    func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord
    func listBackups() async throws -> MaintenanceInventory
    func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt
    func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult
}
