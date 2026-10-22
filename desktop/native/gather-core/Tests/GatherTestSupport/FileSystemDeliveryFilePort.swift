// desktop/native/gather-core/Tests/GatherTestSupport/FileSystemDeliveryFilePort.swift
// P2-6：仅文件系统的 DeliveryFilePort 从 GatherDelivery 生产面移入测试支持。
//
// 生产默认注入 XMPDeliveryFilePort（经 XMPProvider 原子替换 + 大小写侧车解析）；
// 该替身只被 DeliveryCoordinator 的测试接线与 CullingService 文件端口测试使用，
// 因此不再作为 GatherDelivery 的 public API。
//
// 恢复 = 备份覆盖写回 photo.xmp（幂等），删除 = unlink。

import Foundation
import GatherPersistence
import GatherDelivery

/// 仅文件系统的 DeliveryFilePort（测试替身；生产 0 引用）。
public struct FileSystemDeliveryFilePort: DeliveryFilePort {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func restore(photoPath: String, backupPath: String) async throws {
        let target = TSPath.xmpSidecarPath(photoPath)
        // P2-12：与 XMPDeliveryFilePort 同一校验；只使用归一化后的备份路径。
        let validatedBackup = try DeliveryBackupPath.validate(
            xmpPath: target, backupPath: backupPath)
        guard FileManager.default.fileExists(atPath: validatedBackup) else {
            throw DeliveryCoordinatorError.backupMissing(xmpPath: backupPath)
        }
        // 先拷到同目录临时文件，再替换目标：中途失败不会把原侧车删空
        //（与 SidecarXMPProvider.install 的覆盖写语义一致）。
        let tempPath = target + ".restore-" + UUID().uuidString.lowercased()
        try FileManager.default.copyItem(atPath: validatedBackup, toPath: tempPath)
        do {
            if FileManager.default.fileExists(atPath: target) {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: target),
                    withItemAt: URL(fileURLWithPath: tempPath)
                )
            } else {
                try FileManager.default.moveItem(atPath: tempPath, toPath: target)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    public func removeFile(_ path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
