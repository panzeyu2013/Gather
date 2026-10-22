// desktop/native/gather-core/Sources/GatherPersistence/Database/FileHasher.swift
// 文件内容哈希（Cut 3a / module-split-map E-02）。
//
// 为什么在 Persistence：AssetRepo（GatherPersistence）的 relinkRoot 需要校验和
// 证明"移动后的文件是同一个"，原实现调 Domain 层 IndexerService 的哈希方法
// ——这是 Persistence→Domain 的反向依赖；拆 target 后 GatherPersistence 无法
// import GatherDomain，若给两者互相加依赖则 SwiftPM 直接报 cyclic dependency。
// 哈希是纯文件 IO 工具，与 Domain 语义无关，故下沉到 Persistence；Domain 侧
// 的同名静态方法保留为一行委托（deprecated 别名）。
//
// 实现从 IndexerService 原样搬移：4MB 分块流式喂 CryptoKit（内存恒定），
// Linux 无 CryptoKit 回退纯 Swift SHA256（GatherPersistence/Database/SHA256.swift），两条路径
// 输出逐字节一致（IndexerChecksumParityTests 守护）。

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 文件哈希工具（纯 IO，无 DB/无 Domain 依赖）。
public enum FileHasher {
    /// TS: sha256File —— SHA256 hex（小写）。
    ///
    /// macOS 走 CryptoKit 4MB 分块流式（F-6/B-3：旧实现整文件读入 + 纯 Swift
    /// 逐字节哈希，实测 342 MiB/s vs CryptoKit 3220 MiB/s；100MB RAW × 6 并发
    /// 瞬时分配可达 GB 级）。这里恒为 4MB 分块，内存与文件大小无关；输出与纯
    /// Swift 一次性实现逐字节一致（同算法，无需迁移）。
    public static func sha256File(_ filePath: String) throws -> String {
        let url = URL(fileURLWithPath: filePath)
        #if canImport(CryptoKit)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        var hex = String()
        hex.reserveCapacity(64)
        for byte in digest { hex += String(format: "%02x", byte) }
        return hex
        #else
        let data = try Data(contentsOf: url)
        return SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }
}
