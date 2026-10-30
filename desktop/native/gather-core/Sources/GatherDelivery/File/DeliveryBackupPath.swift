// desktop/native/gather-core/Sources/GatherDelivery/File/DeliveryBackupPath.swift
// P2-12（交付安全）：backup_path 的统一校验。
//
// 威胁模型：deliveries.backup_path 是 DB 行，cleanup/finalize/replay 会把它交给
// 文件端口做 restore/remove。若 DB 被手工篡改/迁移残留一条恶意路径，旧实现可以
// 删除或覆盖任意可写文件。本文件把「可被文件阶段信任的备份路径」收敛成一个
// 判定：
// 1. 必须与 xmpPath 同目录（同一受控 sidecar 目录；仓库的备份约定是
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
    /// xmp_path 自身不安全（空/相对/含 NUL/含 .. 组件）。
    case unsafeXMPPath(String)
    /// xmp_path 不在 photo_path 的同目录（sidecar 必须与照片同目录）。
    case xmpNotSiblingOfPhoto(String)

    var code: String {
        switch self {
        case .emptyXMPPath: return "XMP_BACKUP_PATH_EMPTY_XMP"
        case .traversal: return "XMP_BACKUP_PATH_TRAVERSAL"
        case .notSibling: return "XMP_BACKUP_PATH_NOT_SIBLING"
        case .unexpectedName: return "XMP_BACKUP_PATH_UNEXPECTED_NAME"
        case .symbolicLink: return "XMP_BACKUP_PATH_SYMLINK"
        case .notRegularFile: return "XMP_BACKUP_PATH_NOT_REGULAR_FILE"
        case .unsafeXMPPath: return "XMP_PATH_UNSAFE"
        case .xmpNotSiblingOfPhoto: return "XMP_PATH_NOT_SIBLING_OF_PHOTO"
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
             .notRegularFile(let path),
             .unsafeXMPPath(let path),
             .xmpNotSiblingOfPhoto(let path):
            return "\(code): \(path)"
        }
    }

    var errorDescription: String? { description }
}

/// backup_path 的唯一校验入口（DeliveryFilePhase / 文件端口共用）。
public enum DeliveryBackupPath {
    /// 受控备份名标记：**删除守卫的唯一来源**（DeliveryTypes 与宿主 router 共用）。
    ///
    /// 放在 GatherDelivery 而不是 GatherProtocol：这是交付层的内部约定，不属于冻结的
    /// IPC 公开面（protocol-surface 门禁只看 GatherProtocol）。
    ///
    /// 原实现还列了 `.gather-archived-`：全仓没有任何生产者（宿主 XMPProvider.backup
    /// 只生成 .gather-backup-，内嵌会话只生成 .gather-header-），把它留在"允许删除"
    /// 白名单里只会扩大误删面，已删除（P1-4）。将来真要落地归档，必须同时给出
    /// 生产者 + 锚定式判定（见 anchoredXMPPath），不能只加一个标记字符串。
    public static let controlledMarkers = [
        ".gather-backup-", ".gather-header-",
    ]

    /// 是否属于"受控备份 / 归档名"。
    ///
    /// **只看最后一段路径**：以前对整串 `contains`，目录名里出现 `.gather-backup-`
    /// 就能让该目录下的任意文件（内嵌模式下甚至是原片）通过最后一道删除守卫。
    /// 备份/归档名一定把标记放在文件名里，所以限制到 lastPathComponent 既够用也更安全。
    ///
    /// 这是**允许删除**的白名单，不是路径合法性校验——后者仍走 `validate`。
    public static func isControlledName(_ path: String) -> Bool {
        let name = ((path as NSString).lastPathComponent).lowercased()
        return controlledMarkers.contains { name.contains($0) }
    }

    /// 从受控备份名反推 `<xmp>` 并校验二者关系（锚定式孤儿判定，P1-4）。
    ///
    /// 原实现（MetadataRetentionService 的孤儿回收）只问"文件名里是否含标记"
    /// （isControlledName）：扫描根是用户照片目录的第一层，于是任何 >24h、DB 无引用、
    /// 名字里碰巧含 `.gather-backup-` 的常规文件都会被删。这里改成正向对齐的锚定式：
    /// 把名字按标记切成 (base, 后缀)，base 当候选 `<xmp>`，再复用 `validate` 的全部
    /// 关系校验（同目录 + `base + marker` 前缀锚定 + 符号链接 / 非常规文件拒绝）。
    ///
    /// - Parameter directory: 待判定文件所在目录（孤儿扫描只扫会话根第一层，目录已知）。
    /// - Returns: 归一化后的 `<xmp>`；nil = 这个名字不可能是受控备份（调用方只能跳过）。
    public static func anchoredXMPPath(
        forBackupName name: String,
        inDirectory directory: String
    ) -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"),
              !directory.isEmpty else { return nil }
        let backupPath = (directory as NSString).appendingPathComponent(name)
        for marker in controlledMarkers {
            // 取**最后一次**出现：uuid 段不含标记；base 里出现同名字符串时以前缀为准
            // （validate 会再确认 `base + marker` 是 backupName 的前缀）。
            guard let range = name.range(
                of: marker, options: [.backwards, .caseInsensitive]),
                range.upperBound < name.endIndex else { continue }
            let base = String(name[..<range.lowerBound])
            guard !base.isEmpty else { continue }
            let candidate = (directory as NSString).appendingPathComponent(base)
            do {
                _ = try validate(xmpPath: candidate, backupPath: backupPath)
            } catch {
                // 关系不成立（不是这份 xmp 的备份）：试下一个标记，最终 nil。
                continue
            }
            return TSPath.normalize(candidate)
        }
        return nil
    }

    /// 内嵌写回的照片拷贝型临时文件标记（C6）。
    ///
    /// `JPEGMetadataWriter.temporaryPath` 生成 `.<photo>.gather-embedded-<uuid>`：
    /// 整份照片（新头部 + 扫描段）的临时副本，正常路径由 replaceItemAt 消费，只有
    /// 崩溃/断电才会留在照片目录里。它与备份**不是**一类东西（不能 restore，也不对应
    /// 任何 deliveries.backup_path），因此刻意不进 `controlledMarkers`：只由孤儿回收
    /// 按"基础文件名仍在 + 年龄"判定后删除。
    public static let embeddedTempMarker = ".gather-embedded-"

    /// 从 `.<photo>.gather-embedded-<uuid>` 反推 `<photo>`；nil = 不是这类临时文件。
    public static func embeddedTempBaseName(_ name: String) -> String? {
        guard name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        guard let range = name.range(
            of: embeddedTempMarker, options: [.backwards, .caseInsensitive]),
            range.upperBound < name.endIndex else { return nil }
        let base = String(name[name.index(after: name.startIndex)..<range.lowerBound])
        guard !base.isEmpty else { return nil }
        return base
    }

    /// 是否可回收的内嵌临时文件：名字形态对得上，且**同目录的原照片仍在**
    /// （照片本体还在才证明它是这份照片的拷贝副本，而不是用户自造的怪名字）。
    public static func isRecoverableEmbeddedTemp(
        name: String,
        inDirectory directory: String
    ) -> Bool {
        guard let base = embeddedTempBaseName(name), !directory.isEmpty else { return false }
        let photoPath = (directory as NSString).appendingPathComponent(base)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: photoPath, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

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

        // 两种受控备份名：sidecar <xmp>.gather-backup-<uuid>；
        // 内嵌 JPEG <photo>.gather-header-<uuid>（此时 xmp_path 就是照片路径）。
        let baseName = (normalizedXMP as NSString).lastPathComponent
        let backupName = (normalizedBackup as NSString).lastPathComponent
            .precomposedStringWithCanonicalMapping
        let matchesControlledName = [".gather-backup-", ".gather-header-"].contains { marker in
            let prefix = (baseName + marker).precomposedStringWithCanonicalMapping
            return backupName.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
                && backupName.count > prefix.count
        }
        guard matchesControlledName else {
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

/// xmp_path 的唯一安全校验入口（复审 P2）。
///
/// 与 backup_path 的威胁模型相同：delivery_intents.xmp_path 是 DB 列，
/// cleanup/replay 会据此 remove/restore。旧实现只校验 backup_path，xmp_path
/// 零校验（相对路径/.. /NUL 都直接交给文件端口）。这里要求：
/// 1. 绝对路径、无 NUL、无 .. 组件；
/// 2. 与 photo_path 同目录（sidecar 约定），两侧都过 TSPath.normalize 后比较。
public enum DeliveryXMPPath {
    public static func requireSafeSidecar(xmpPath: String, photoPath: String) throws {
        guard !xmpPath.isEmpty, !xmpPath.contains("\0"), xmpPath.hasPrefix("/"),
              !xmpPath.components(separatedBy: "/").contains("..") else {
            throw DeliveryBackupPathError.unsafeXMPPath(xmpPath)
        }
        guard !photoPath.isEmpty, !photoPath.contains("\0"), photoPath.hasPrefix("/"),
              !photoPath.components(separatedBy: "/").contains("..") else {
            throw DeliveryBackupPathError.unsafeXMPPath(xmpPath)
        }
        let xmpDirectory = (TSPath.normalize(xmpPath) as NSString).deletingLastPathComponent
        let photoDirectory = (TSPath.normalize(photoPath) as NSString).deletingLastPathComponent
        guard !xmpDirectory.isEmpty, !photoDirectory.isEmpty,
              xmpDirectory.precomposedStringWithCanonicalMapping
                  .caseInsensitiveCompare(photoDirectory.precomposedStringWithCanonicalMapping) == .orderedSame else {
            throw DeliveryBackupPathError.xmpNotSiblingOfPhoto(xmpPath)
        }
    }
}
