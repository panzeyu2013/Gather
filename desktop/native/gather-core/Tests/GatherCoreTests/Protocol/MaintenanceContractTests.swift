// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/MaintenanceContractTests.swift
// P0 / B0：Maintenance（第 17 协议）的 Codable 形状与输入校验契约。
//
// 目的：新协议此前没有契约测试，Codable key 改名、字段增删或 throwing init 被
// 合成解码绕过都不会有测试失败。这里钉死 JSON key 集合与解码校验。
import Foundation
import Testing
@testable import GatherProtocol

@Suite("B0 Maintenance 契约")
struct MaintenanceContractTests {
    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test("BackupRecord / Inventory / Receipt / Outcome 的 JSON key 冻结")
    func payloadKeysAreFrozen() throws {
        let record = BackupRecord(
            fileName: "Gather-Backup-1.sqlite", createdAt: "t", sizeBytes: 1,
            schemaVersion: 3, tableCount: 45, trigger: .manual,
            verified: true, sha256: "abc")
        #expect(try keys(record) == [
            "fileName", "createdAt", "sizeBytes", "schemaVersion",
            "tableCount", "trigger", "verified", "sha256",
        ])
        let outcome = RestoreOutcome(
            at: "t", backupFileName: "f", result: .applied, errorCode: "RESTORE_FAILED")
        #expect(try keys(outcome) == ["at", "backupFileName", "result", "errorCode"])
        let inventory = MaintenanceInventory(
            backupDir: "/b", backups: [record], lastRestore: outcome, autoPaused: false)
        #expect(try keys(inventory) == ["backupDir", "backups", "lastRestore", "autoPaused"])
        let receipt = RestoreReceipt(
            backupFileName: "f", schemaVersion: 3, requiresRestart: true,
            journalPath: "/j", verifiedAt: "t")
        #expect(try keys(receipt) == [
            "backupFileName", "schemaVersion", "requiresRestart", "journalPath", "verifiedAt",
        ])
    }

    @Test("BackupTrigger / RestoreResult rawValue 冻结")
    func enumRawValuesAreFrozen() {
        #expect(BackupTrigger.allCases.map(\.rawValue) == [
            "manual", "auto_launch", "auto_daily", "unknown",
        ])
        #expect(RestoreResult.applied.rawValue == "applied")
        #expect(RestoreResult.failed.rawValue == "failed")
        #expect(RestoreResult.rolledBack.rawValue == "rolledBack")
    }

    @Test("解码必须经过 throwing init：路径穿越 / 非 zip / 非手动触发都被拒")
    func decodingValidatesInput() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                RestoreBackupInput.self, from: Data(#"{"fileName":"../escape.sqlite"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                RestoreBackupInput.self, from: Data(#"{"fileName":"a/b.sqlite"}"#.utf8))
        }
        let ok = try? JSONDecoder().decode(
            RestoreBackupInput.self, from: Data(#"{"fileName":"Gather-Backup-1.sqlite"}"#.utf8))
        #expect(ok?.fileName == "Gather-Backup-1.sqlite")

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                DiagnosticsExportInput.self,
                from: Data(#"{"destinationPath":"relative.zip"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                MaintenanceBackupInput.self, from: Data(#"{"trigger":"auto_daily"}"#.utf8))
        }
    }

    @Test("MaintenanceError 的 code 全部映射到冻结错误码")
    func errorCodesAreContractual() {
        let all: [MaintenanceError] = [
            .backupBusy, .backupVerifyFailed("x"), .backupInsufficientSpace(needed: 1, available: 0),
            .backupPermissionDenied("x"), .backupFailed("x"), .restoreBusy,
            .restoreVerifyFailed("x"), .restoreVersionUnsupported(backup: 2, current: 3),
            .restoreInsufficientSpace(needed: 1, available: 0), .restorePermissionDenied("x"),
            .restoreFailed("x"), .diagnosticsExportFailed("x"),
        ]
        let codes = Set(all.map(\.code))
        #expect(codes.count == 12)
        for code in codes {
            #expect(GatherErrorCode(rawValue: code) != nil, "未登记的错误码：\(code)")
        }
    }
}
