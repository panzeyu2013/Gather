// desktop/native/gather-core/Sources/GatherPersistence/Database/MetadataFingerprint.swift
// TS 源: desktop/src/main/services/metadata/metadata-fingerprint.ts（算法逐字移植）
// 纯逻辑：指纹字符串拼接规则与 TS 完全一致（`${size}:${round(mtimeMs)}:${sha256hex}`），
// 文件读取经 tsStat / Data(contentsOf:) 直接走真实文件系统（TS 测试同款真实临时文件）。
// crypto sha256 → SHA256（FIPS 180-4 纯 Swift 实现，GatherPersistence/Database/SHA256.swift）。

import Foundation
import GatherProtocol

public enum MetadataFingerprint {
    /// TS: contentFingerprint —— 加密内容指纹，检测 XMP 文件在基线快照与写入之间
    /// 的外部修改。sha256 强制整文件读取，只用于持久写入/冲突路径，绝不用于列表渲染。
    /// 文件不存在返回 ''（ENOENT）；其它 stat/read 错误抛出。
    public static func contentFingerprint(_ filePath: String) async throws -> String {
        guard let info = tsStat(filePath) else {
            // TS: ENOENT → ''；其余 stat 错误抛出（tsStat 只吞"不存在"）。
            if !FileManager.default.fileExists(atPath: filePath) { return "" }
            throw MetadataFingerprintError.statFailed(filePath)
        }
        let content = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let digest = SHA256.hash(content)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(info.size):\(Int64(info.mtimeMs.rounded())):\(hex)"
    }

    /// 同步版本：入队时（sync 上下文）取首次写盘基线。
    public static func contentFingerprintSync(_ filePath: String) throws -> String {
        guard let info = tsStat(filePath) else {
            if !FileManager.default.fileExists(atPath: filePath) { return "" }
            throw MetadataFingerprintError.statFailed(filePath)
        }
        let content = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let digest = SHA256.hash(content)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(info.size):\(Int64(info.mtimeMs.rounded())):\(hex)"
    }

    /// TS: cacheStalenessKey —— 廉价陈旧键：源文件大小 + { 源 mtime : 侧车 mtime }。
    /// 刻意不读文件内容（缓存失效提示，非持久性守卫）。不可读返回 nil。
    public static func cacheStalenessKey(_ photoPath: String) async throws -> (size: Int, value: String)? {
        guard let sourceStat = tsStat(photoPath) else { return nil }
        var xmpMtime: Double = 0
        if let xmpStat = tsStat(TSPath.xmpSidecarPath(photoPath)) {
            xmpMtime = xmpStat.mtimeMs
        }
        return (
            size: Int(sourceStat.size),
            value: "\(Int64(sourceStat.mtimeMs.rounded())):\(Int64(xmpMtime.rounded()))"
        )
    }
}
