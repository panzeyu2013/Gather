// desktop/native/gather-app/Sources/GatherHost/Embedded/MetadataWriteRouter.swift
// 写目标路由：把 XMPProvider 的调用按 MetadataTargetPolicy 分派到侧车或 JPEG 内嵌。
//
// 存在的意义：交付队列（deliveries/delivery_items/WritebackService）已经把"目标"
// 当成一个可指纹、可备份、可恢复的文件；路由只决定这个文件是谁，其余机制不动。
//
// 备份语义：
// - 侧车：原样委托（复制 .xmp）。
// - 内嵌：只备份 SOI…SOS 头部（几 KB–几百 KB），restore = 旧头部 + 当前 scan。
//   backup() 生成的路径会挂到 pending，write() 复用它（避免两份备份/孤儿文件）。
import Foundation
import os
import GatherApplication
import GatherProtocol

enum MetadataWriteRouterError: Error, Equatable, CustomStringConvertible {
    case embeddedWriteFailed(String)

    var code: String { "EMBEDDED_WRITE_FAILED" }

    var description: String {
        switch self {
        case .embeddedWriteFailed(let reason):
            "EMBEDDED_WRITE_FAILED: " + reason
        }
    }
}

final class MetadataWriteRouter: XMPProvider {
    /// 唯一可变状态收进 OSAllocatedUnfairLock（本身 Sendable），因此本类天然 Sendable，
    /// 不需要 @unchecked。
    private let sidecar: SidecarXMPProvider
    private let modeProvider: @Sendable () -> String
    private let pendingBackups = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    init(sidecar: SidecarXMPProvider = SidecarXMPProvider(),
         modeProvider: @escaping @Sendable () -> String = { "sidecar" }) {
        self.sidecar = sidecar
        self.modeProvider = modeProvider
    }

    // MARK: - 目标解析

    func target(for photoPath: String) -> MetadataTarget {
        let resolvedSidecar = SidecarXMPProvider.resolveSidecarPath(photoPath)
        let hasSidecar = FileManager.default.fileExists(atPath: resolvedSidecar)
        var kind = MetadataTargetPolicy.resolve(
            photoPath: photoPath,
            mode: modeProvider(),
            sidecarExists: hasSidecar,
            isJPEG: MetadataTargetPolicy.isJPEG(photoPath))
        // RAW+JPEG 同资产：RAW 只能走侧车；JPEG 兄弟必须跟随侧车，
        // 否则同一资产会同时存在内嵌与侧车两个真相源。
        // 只在 auto 模式下做这个覆盖：用户显式选 embedded 时尊重选择。
        if kind == .embedded, modeProvider() == "auto", Self.rawSiblingExists(for: photoPath) {
            kind = .sidecar
        }
        return MetadataTarget(
            photoPath: photoPath,
            kind: kind,
            writePath: kind == .sidecar ? resolvedSidecar : photoPath)
    }

    /// 同 basename 的 RAW 兄弟（大小写不敏感）。只查盘上是否存在，不做资产库推断。
    static func rawSiblingExists(for photoPath: String) -> Bool {
        let url = URL(fileURLWithPath: photoPath)
        let stem = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        let rawExtensions = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw", "iiq", "3fr", "erf", "mef"]
        return rawExtensions.contains { ext in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(stem + "." + ext).path)
                || FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(stem + "." + ext.uppercased()).path)
        }
    }

    // MARK: - XMPProvider

    func readKeywords(photoPath: String) async throws -> [String] {
        switch target(for: photoPath).kind {
        case .sidecar:
            return try await sidecar.readKeywords(photoPath: photoPath)
        case .embedded:
            let attributes = try await readEmbedded(photoPath: photoPath)
            return attributes.keywords ?? []
        }
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        switch target(for: photoPath).kind {
        case .sidecar:
            return try await sidecar.readAttributes(photoPath: photoPath)
        case .embedded:
            return try await readEmbedded(photoPath: photoPath)
        }
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        let target = target(for: photoPath)
        switch target.kind {
        case .sidecar:
            try await sidecar.writeAttributes(photoPath: photoPath, attributes: attributes)
        case .embedded:
            let pendingBackup = takePendingBackup(for: photoPath)
            // 自建备份（调用方没先 backup()）不会进任何 deliveries 行：
            // 失败/成功都立刻删除，避免原片旁堆积 .gather-header-* 孤儿。
            let ownsBackup = pendingBackup == nil
            let backupPath = pendingBackup
                ?? photoPath + ".gather-header-" + UUID().uuidString.lowercased()
            do {
                _ = try await JPEGMetadataWriter.write(
                    photoPath: photoPath, attributes: attributes, headerBackupPath: backupPath)
            } catch {
                if ownsBackup {
                    do {
                        try FileManager.default.removeItem(atPath: backupPath)
                    } catch {
                        GatherLogger.log("embedded self-backup cleanup failed", level: .debug)
                    }
                }
                throw MetadataWriteRouterError.embeddedWriteFailed(String(describing: error))
            }
            if ownsBackup {
                do {
                    try FileManager.default.removeItem(atPath: backupPath)
                } catch {
                    GatherLogger.log("embedded self-backup cleanup failed", level: .debug)
                }
            }
        }
    }

    func backup(photoPath: String) async throws -> String {
        let target = target(for: photoPath)
        switch target.kind {
        case .sidecar:
            return try await sidecar.backup(photoPath: photoPath)
        case .embedded:
            guard FileManager.default.fileExists(atPath: photoPath) else { return "" }
            let backupPath = photoPath + ".gather-header-" + UUID().uuidString.lowercased()
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: photoPath))
                let document = try JPEGDocument(data: data)
                let header = data.prefix(data.count - document.scan.count)
                try Data(header).write(to: URL(fileURLWithPath: backupPath))
            } catch {
                throw MetadataWriteRouterError.embeddedWriteFailed(
                    "header backup failed: " + String(describing: error))
            }
            storePendingBackup(backupPath, for: photoPath)
            return backupPath
        }
    }

    func restore(photoPath: String, backupPath: String) async throws {
        // 恢复即消费：不清掉 pending 条目的话，之后一次不带 backup() 的写入会复用
        // 这个已经用过的路径（成功后也不删）→ 原片旁堆积 .gather-header-* 孤儿。
        _ = takePendingBackup(for: photoPath)
        guard !backupPath.isEmpty else { return }
        // 备份名的 kind 标记优先于“当下的写目标”：备份创建后侧车可能才出现，
        // 按当下 target 分派会把 .gather-header- 备份当成侧车内容拷进 .xmp。
        let isHeaderBackup = backupPath.contains(".gather-header-")
        let isSidecarBackup = backupPath.contains(".gather-backup-")
        if isHeaderBackup && !isSidecarBackup {
            do {
                try JPEGMetadataWriter.restore(photoPath: photoPath, headerBackupPath: backupPath)
            } catch {
                throw MetadataWriteRouterError.embeddedWriteFailed(
                    "restore failed: " + String(describing: error))
            }
            return
        }
        if isSidecarBackup {
            try await sidecar.restore(photoPath: photoPath, backupPath: backupPath)
            return
        }
        // 无标记（旧行）才退回按当前目标类型。
        if target(for: photoPath).kind == .sidecar {
            try await sidecar.restore(photoPath: photoPath, backupPath: backupPath)
            return
        }
        do {
            try JPEGMetadataWriter.restore(photoPath: photoPath, headerBackupPath: backupPath)
        } catch {
            throw MetadataWriteRouterError.embeddedWriteFailed(
                "restore failed: " + String(describing: error))
        }
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func removeFile(_ path: String) async throws {
        try await sidecar.removeFile(path)
    }

    // MARK: - 内嵌读（内嵌 + 侧车逐字段合并，侧车优先）

    private func readEmbedded(photoPath: String) async throws -> MetadataWriteAttributes {
        let parsed = try await ImageIOExifProvider().parse(filePath: photoPath, isJpeg: true)
        let embedded = parsed.flatMap(MetadataService.embeddedAttributesFromParse)
            ?? MetadataWriteAttributes()
        // 内嵌目标也允许存在外部 .xmp（策略上不会走到这里，但直接调用 readAttributes
        // 时仍要给出有效值）。合并规则与 MetadataService 一致：侧车逐字段覆盖。
        let sidecarPath = SidecarXMPProvider.resolveSidecarPath(photoPath)
        guard FileManager.default.fileExists(atPath: sidecarPath) else { return embedded }
        let overlay: MetadataWriteAttributes
        do {
            overlay = try await sidecar.readAttributes(photoPath: photoPath)
        } catch {
            GatherLogger.log(
                "router sidecar overlay read failed (path token=\(TSPath.basename(photoPath))): \(error)",
                level: .debug)
            return embedded
        }
        return MetadataWriteRouter.merge(embedded, overlay)
    }

    static func merge(
        _ base: MetadataWriteAttributes,
        _ overlay: MetadataWriteAttributes
    ) -> MetadataWriteAttributes {
        MetadataWriteAttributes(
            keywords: overlay.keywords ?? base.keywords,
            rating: overlay.rating ?? base.rating,
            label: overlay.label ?? base.label,
            dateTaken: overlay.dateTaken ?? base.dateTaken,
            latitude: overlay.latitude ?? base.latitude,
            longitude: overlay.longitude ?? base.longitude,
            descriptive: descriptiveMerge(base.descriptive, overlay.descriptive),
            triageSignal: overlay.triageSignal ?? base.triageSignal,
            keywordsMode: overlay.keywordsMode ?? base.keywordsMode,
            replaceContact: overlay.replaceContact ?? base.replaceContact)
    }

    private static func descriptiveMerge(
        _ base: DescriptiveMetadata?,
        _ overlay: DescriptiveMetadata?
    ) -> DescriptiveMetadata? {
        switch (base, overlay) {
        case (nil, nil): return nil
        case (let base?, nil): return base
        case (nil, let overlay?): return overlay
        case (let base?, let overlay?): return base.applying(overlay)
        }
    }

    // MARK: - pending 备份表

    private func storePendingBackup(_ backupPath: String, for photoPath: String) {
        pendingBackups.withLock { $0[photoPath] = backupPath }
    }

    private func takePendingBackup(for photoPath: String) -> String? {
        pendingBackups.withLock { $0.removeValue(forKey: photoPath) }
    }
}
