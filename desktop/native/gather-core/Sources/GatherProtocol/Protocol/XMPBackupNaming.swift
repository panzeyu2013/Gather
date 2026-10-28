// desktop/native/gather-core/Sources/GatherProtocol/Protocol/XMPBackupNaming.swift
// P1 / P2-12：XMP sidecar 备份命名的唯一实现（生成端 / 校验端 / 路径迁移共用）。
//
// 契约（与 DeliveryBackupPath 的历史实现一致）：
// - 备份与 sidecar 同目录；
// - 名字 = "<xmp basename>.gather-backup-<非空后缀>"；
// - 比较一律 precomposed + caseInsensitive：DB 里的 xmp_path 常是归一化小写
//   （IMG_1.xmp），盘上备份由 XMPProvider.backup 按真实大小写生成
//   （IMG_1.XMP.gather-backup-...），逐字节比较会漏掉这类文件。
import Foundation

public enum XMPBackupNaming {
    public static let marker = ".gather-backup-"

    /// 备份名 = sidecar 完整文件名 + marker + 后缀（生成端使用）。
    public static func make(xmpPath: String, suffix: String) -> String {
        xmpPath + marker + suffix
    }

    /// 从备份文件名取后缀；不是该 xmp 的受控备份名时返回 nil（大小写/Unicode 不敏感）。
    public static func suffix(ofBackupFile name: String, forXMPPath xmpPath: String) -> String? {
        let base = (xmpPath as NSString).lastPathComponent
        let foldedName = fold(name)
        let foldedPrefix = fold(base + marker)
        guard foldedName.hasPrefix(foldedPrefix) else { return nil }
        let prefixLength = (base as NSString).length + (marker as NSString).length
        guard (name as NSString).length > prefixLength else { return nil }
        let suffix = (name as NSString).substring(from: prefixLength)
        return suffix.isEmpty ? nil : suffix
    }

    /// 备份路径随 xmp 改名/换目录：只有「旧 xmp 的同目录兄弟 + 受控命名」才改写，
    /// 其它（空 / 已清理 / 非受控）原样返回——绝不把任意路径改写成看似合法的新路径。
    public static func relocated(backupPath: String, oldXMPPath: String, newXMPPath: String) -> String {
        guard !backupPath.isEmpty else { return backupPath }
        let backupDir = (backupPath as NSString).deletingLastPathComponent
        let oldDir = (oldXMPPath as NSString).deletingLastPathComponent
        guard fold(backupDir) == fold(oldDir) else { return backupPath }
        guard let suffix = suffix(
            ofBackupFile: (backupPath as NSString).lastPathComponent, forXMPPath: oldXMPPath)
        else { return backupPath }
        let newDir = (newXMPPath as NSString).deletingLastPathComponent
        let newBase = (newXMPPath as NSString).lastPathComponent
        return TSPath.join(newDir, newBase + marker + suffix)
    }

    /// precomposed + caseInsensitive 的统一口径。
    public static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}
