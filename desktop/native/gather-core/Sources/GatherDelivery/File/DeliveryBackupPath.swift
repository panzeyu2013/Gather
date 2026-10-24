// desktop/native/gather-core/Sources/GatherDelivery/File/DeliveryBackupPath.swift
// P2-12（交付安全）：backup_path 的统一校验。
//
// 威胁模型：deliveries.backup_path 是 DB 行，cleanup/finalize/replay 会把它交给
// 文件端口做 restore/remove。若 DB 被手工篡改/迁移残留一条恶意路径，旧实现可以
// 删除或覆盖任意可写文件。本文件把「可被文件阶段信任的备份路径」收敛成一个
// 判定：
// 1. 必须与 xmpPath 同目录（同一受控侧车目录；仓库的备份约定是
//    <xmp>.gather-backup-<uuid>，由宿主 XMPProvider.backup 生成）；
// 2. 必须是 <xmp basename>.gather-backup-<non-empty>，拒绝任意文件名；
// 3. 原始路径不得含 .. 组件或 NUL（TSPath.normalize 会折叠 ..，因此必须在
//    归一化前检查原始串，否则 /v/sub/../x 这类 traversal 会被静默接受）；
// 4. 已存在的路径必须是常规文件；符号链接（含断链）一律拒绝。
//
// 不存在的路径不在这里报错：cleanup 需要保留旧的 XMP_BACKUP_MISSING 语义，
// finalize 的后置清理需要把「备份已不存在」视为幂等成功。调用方负责存在性。
//
// 所有检查都是 fail-closed：校验失败只能 skip/报错，绝不能继续 restore/remove。

import GatherProtocol
import Foundation
import GatherPersistence

/// backup_path 校验失败（错误串包含完整路径，供 summary/日志的「错误仍可定位」；
/// 文件阶段的 trace 只记录 code，不记录路径）。
enum DeliveryBackupPathError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// xmpPath 为空，无法确定受控目录。
    case emptyXMPPath
    /// 原始 backup_path 含 ".." 组件或 NUL。
    case traversal(String)
    /// backup_path 不在 xmpPath 的父目录。
    case notSibling(String)
    /// 文件名不是 <xmp>.gather-backup-<non-empty>。
    case unexpectedName(String)
    /// 已存在的 backup_path 是符号链接。
    case symbolicLink(String)
    /// 已存在的 backup_path 不是常规文件（目录/设备/FIFO 等）。
    case notRegularFile(String)

    var code: String {
        switch self {
        case .emptyXMPPath: return "XMP_BACKUP_PATH_EMPTY_XMP"
        case .traversal: return "XMP_BACKUP_PATH_TRAVERSAL"
        case .notSibling: return "XMP_BACKUP_PATH_NOT_SIBLING"
        case .unexpectedName: return "XMP_BACKUP_PATH_UNEXPECTED_NAME"
        case .symbolicLink: return "XMP_BACKUP_PATH_SYMLINK"
        case .notRegularFile: return "XMP_BACKUP_PATH_NOT_REGULAR_FILE"
        }
    }

    var description: String {
        switch self {
        case .emptyXMPPath:
            return code
        case .traversal(let path),
             .notSibling(let path),
             .unexpectedName(let path),
             .symbolicLink(let path),
             .notRegularFile(let path):
            return "\(code): \(path)"
        }
    }

    var errorDescription: String? { description }
}

/// backup_path 的唯一校验入口（DeliveryFilePhase / 文件端口共用）。
public enum DeliveryBackupPath {
    /// 校验并返回**归一化后**的 backup_path；调用方必须用返回值做文件操作。
    public static func validate(xmpPath: String, backupPath: String) throws -> String {
        let normalizedXMP = TSPath.normalize(xmpPath)
        guard !normalizedXMP.isEmpty else { throw DeliveryBackupPathError.emptyXMPPath }
        guard !backupPath.isEmpty else {
            throw DeliveryBackupPathError.notSibling(backupPath)
        }
        guard !backupPath.contains("\0") else {
            throw DeliveryBackupPathError.traversal(backupPath)
        }
        // 先检查原始串，再归一化：standardizingPath 会折叠 /v/sub/../x，
        // 只看归一化结果会漏掉一次真实 traversal 输入。
        let rawComponents = backupPath.components(separatedBy: "/")
        guard !rawComponents.contains("..") else {
            throw DeliveryBackupPathError.traversal(backupPath)
        }

        let normalizedBackup = TSPath.normalize(backupPath)
        let xmpDirectory = (normalizedXMP as NSString).deletingLastPathComponent
        let backupDirectory = (normalizedBackup as NSString).deletingLastPathComponent
        // 大小写 + Unicode 规范化不敏感比较：DB 的 xmp_path 可能来自 TSPath 归一化
        // （小写 .xmp），而 backup_path 由 SidecarXMPProvider 按盘上真实大小写
        // （IMG_1.XMP）生成；macOS 文件系统还允许 NFD 目录名。两者是同一文件，
        // 不能因大小写/组合形式让 cleanup/finalize 永久 fail-closed。
        let canonicalXMPDirectory = xmpDirectory.precomposedStringWithCanonicalMapping
        let canonicalBackupDirectory = backupDirectory.precomposedStringWithCanonicalMapping
        guard !canonicalXMPDirectory.isEmpty,
              canonicalBackupDirectory.caseInsensitiveCompare(canonicalXMPDirectory) == .orderedSame else {
            throw DeliveryBackupPathError.notSibling(normalizedBackup)
        }

        let expectedPrefix = ((normalizedXMP as NSString).lastPathComponent + ".gather-backup-")
            .precomposedStringWithCanonicalMapping
        let backupName = (normalizedBackup as NSString).lastPathComponent
            .precomposedStringWithCanonicalMapping
        guard backupName.range(of: expectedPrefix, options: [.caseInsensitive, .anchored]) != nil,
              backupName.count > expectedPrefix.count else {
            throw DeliveryBackupPathError.unexpectedName(normalizedBackup)
        }

        // 符号链接（含断链）优先于常规文件判定：destinationOfSymbolicLink 对普通文件抛错。
        // 显式 do/catch 而不是 try?：拒绝路径必须可读，不得被清理 ratchet 静默放过。
        let isSymlink: Bool
        do {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: normalizedBackup)
            isSymlink = true
        } catch {
            isSymlink = false
        }
        if isSymlink {
            throw DeliveryBackupPathError.symbolicLink(normalizedBackup)
        }
        let attributes: [FileAttributeKey: Any]?
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: normalizedBackup)
        } catch {
            attributes = nil
        }
        if let attributes {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw DeliveryBackupPathError.notRegularFile(normalizedBackup)
            }
        }
        // ENOENT/EACCES 不在这里判死：存在性交给文件端口，保持 backupMissing 语义。
        return normalizedBackup
    }
}
