// desktop/native/gather-app/Sources/GatherHost/APIs/LiveMaintenanceAPI.swift
// P0 / B0：MaintenanceAPI 的 Live 实现（唯一错误码映射点）。
import Foundation
import GatherProtocol
import GatherApplication

public struct LiveMaintenanceAPI: MaintenanceAPI, Sendable {
    private let service: MaintenanceService

    public init(service: MaintenanceService) {
        self.service = service
    }

    public func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord {
        do {
            return try await service.backup(trigger: input.trigger)
        } catch {
            throw Self.map(error)
        }
    }

    public func listBackups() async throws -> MaintenanceInventory {
        do {
            return try await service.listBackups()
        } catch {
            throw Self.map(error)
        }
    }

    public func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt {
        do {
            return try await service.restore(input.value)
        } catch {
            throw Self.map(error)
        }
    }

    public func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult {
        do {
            return try await service.exportDiagnostics(input)
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> Error {
        // allow: string-code — core 侧稳定码到 GatherErrorCode 的唯一映射，码值由契约测试钉住。
        guard let maintenance = error as? MaintenanceError,
              let code = GatherErrorCode(rawValue: maintenance.code)
        else { return error }
        var params: [String: String] = [:]
        switch maintenance {
        case .backupVerifyFailed(let reason), .backupPermissionDenied(let reason),
             .backupFailed(let reason), .restoreVerifyFailed(let reason),
             .restorePermissionDenied(let reason), .restoreFailed(let reason),
             .diagnosticsExportFailed(let reason):
            params["reason"] = reason
        case .backupInsufficientSpace(let needed, let available),
             .restoreInsufficientSpace(let needed, let available):
            params["needed"] = "\(needed)"
            params["available"] = "\(available)"
        case .restoreVersionUnsupported(let backup, let current):
            params["backup"] = "\(backup)"
            params["current"] = "\(current)"
        case .backupBusy, .restoreBusy:
            break
        }
        return GatherError(code: code, params: params)
    }
}
