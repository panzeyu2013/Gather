// desktop/native/gather-core/Sources/GatherDelivery/File/DeliveryTemporaryFiles.swift
// P2-15（临时文件残留）：交付文件阶段的「同目录、同 basename、超过阈值」清理。
//
// 仓库里会生成两类短命临时文件：
// - WritebackService 经 XMPProvider 写盘：<xmp>.tmp-<pid>-<uuid>；
// - cleanup restore：<xmp>.restore-<pid>-<uuid>（宿主 provider）或
//   <xmp>.restore-<uuid>（测试替身 FileSystemDeliveryFilePort，GatherTestSupport）。
// 正常路径会 remove；进程崩溃/断电后它们会留在照片目录。启动回放时对「有未完成
// intent 的 xmpPath」做一次对账清理，cleanup/finalize 成功后再对该 xmpPath 清一次。
//
// 安全边界（刻意保守）：
// - 只删 xmpPath 同目录、basename 精确前缀匹配的**常规文件**；
// - 符号链接（含断链）一律不删（避免把链接当临时文件删掉/误删目标）；
// - 只删 mtime 超过 olderThan（默认 24h）的文件：正在进行的写盘即使恰好在同一
//   目录，也不会被启动回放误删；
// - 不碰 .gather-backup-*：备份的归属必须按 deliveries.backup_path 对账，不能
//   按时间盲删（P2-15 / P1-1）。

import Foundation
import GatherPersistence

enum DeliveryTemporaryFiles {
    /// 默认只清理 24h 前的残留：给正在进行的写盘/恢复留出安全窗口。
    static let defaultStaleAge: TimeInterval = 24 * 60 * 60

    /// 删除 xmpPath 同目录下过期的 .tmp-/.restore- 常规文件。
    ///
    /// - Returns: 实际删除的完整路径（按字典序，便于测试/审计）。
    @discardableResult
    static func sweep(
        xmpPath: String,
        olderThan: TimeInterval = defaultStaleAge,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [String] {
        let normalized = TSPath.normalize(xmpPath)
        guard !normalized.isEmpty else { return [] }
        let directory = (normalized as NSString).deletingLastPathComponent
        let basename = (normalized as NSString).lastPathComponent
        guard !directory.isEmpty, !basename.isEmpty else { return [] }
        let prefixes = [basename + ".tmp-", basename + ".restore-"]
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return []
        }

        var removed: [String] = []
        for name in names.sorted() where prefixes.contains(where: { name.hasPrefix($0) }) {
            let path = (directory as NSString).appendingPathComponent(name)
            // 不跟随符号链接：destinationOfSymbolicLink 对普通文件抛错。
            if (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil { continue }
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date
            else { continue }
            guard now.timeIntervalSince(modified) >= olderThan else { continue }
            do {
                try fileManager.removeItem(atPath: path)
                removed.append(path)
            } catch {
                // 清理是尽力而为：失败不改变交付状态，下一次启动再试。
                continue
            }
        }
        return removed
    }
}
