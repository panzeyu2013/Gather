// desktop/native/gather-core/Sources/GatherPersistence/Database/SHA256.swift
// 纯 Swift SHA-256（FIPS 180-4）。Linux 无 CryptoKit，零依赖实现。
//
// 与 FileHasher 的分工（Cut 3a / E-02、Cut 5 / 5d-2 更名）：
//   - macOS：FileHasher.sha256File 走 CryptoKit 4MB 分块流式（内存与文件大小无关）；
//   - Linux：FileHasher.sha256File 回退到本文件的 SHA256.hash(Data)（整块）；
//   两条路径同算法、同输出（FileHasherTests 的分块注入用例守护）。
// 生产调用：FileHasher、DuplicateService、ExportService、NavigationService、
// MetadataFingerprint、PhotoAssetResolver。
//
// 原 ImageCache 磁盘缩略图缓存（含 SerialChain、元数据 SQLite 持久化与淘汰）
// 已按架构审计裁决删除（生产零实例化，唯一使用者是其专属测试）；本文件因此
// 由 `ImageCache.swift` 更名为 `SHA256.swift`，只保留在用的哈希工具。

import Foundation

/// 纯 Swift SHA-256（FIPS 180-4）。Linux 无 CryptoKit 时 `FileHasher.sha256File`
/// 的回退实现，零依赖，对应 TS crypto.createHash('sha256')。
/// 返回 32 字节原始摘要；hex 编码由调用方负责（FileHasher 输出小写 hex）。
public struct SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0)
        }
        msg.append(contentsOf: bitLength.bigEndianBytes)

        var w = [UInt32](repeating: 0, count: 64)
        for blockStart in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let base = blockStart + i * 4
                w[i] = UInt32(msg[base]) << 24
                    | UInt32(msg[base + 1]) << 16
                    | UInt32(msg[base + 2]) << 8
                    | UInt32(msg[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ sum1 &+ ch &+ k[i] &+ w[i]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
            h[5] &+= f
            h[6] &+= g
            h[7] &+= hh
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for value in h {
            out.append(UInt8((value >> 24) & 0xff))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(value & 0xff))
        }
        return out
    }

    private static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xff), UInt8((self >> 48) & 0xff), UInt8((self >> 40) & 0xff), UInt8((self >> 32) & 0xff),
            UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff),
        ]
    }
}
