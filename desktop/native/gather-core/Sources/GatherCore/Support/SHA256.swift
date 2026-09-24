// desktop/native/gather-core/Sources/GatherCore/Support/SHA256.swift
// 纯 Swift SHA-256（FIPS 180-4）——从 Database/ImageCache.swift 抽出：
// 缩略图磁盘缓存类已随 legacy 图像管线废弃，仅哈希实现仍被索引/去重/导航/指纹使用。

/// 纯 Swift SHA-256（FIPS 180-4）。Linux 无 CryptoKit，零依赖实现，
/// 供 hashKey 使用（TS `crypto.createHash('sha256')` 的对应物）。
import Foundation

public struct SHA256 {
    fileprivate static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// FIPS 180-4 初始哈希值（一次性 `hash` 与流式引擎共用；不随消息变化）。
    fileprivate static let iv: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    public static func hash(_ data: Data) -> [UInt8] {
        var h = iv
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

    fileprivate static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

// MARK: - 流式哈希（W2a：替代 Data(contentsOf:) 全量读，内存有界）

public extension SHA256 {
    /// 流式读取默认分块大小（1 MiB）。分块大小不参与摘要，只影响内存占用。
    static let defaultStreamChunkSize = 1 << 20

    /// 流式读取文件计算 SHA-256（小写 hex，64 字符），与 `hash(Data)` 结果逐字节一致。
    ///
    /// 每次最多读 `chunkSize` 字节（<= 0 按 1 处理），压缩状态常驻、不整文件入内存；
    /// 文件打开/读取错误原样抛出（不做吞错降级）。
    static func stream(file: URL, chunkSize: Int = SHA256.defaultStreamChunkSize) throws -> String {
        let engine = SHA256StreamingEngine()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = max(1, chunkSize)
        while true {
            guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { break }
            engine.update(chunk)
        }
        return engine.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `stream(file:chunkSize:)` 的路径重载（内部转 URL，测试/旧调用点可直接传路径）。
    static func stream(file: String, chunkSize: Int = SHA256.defaultStreamChunkSize) throws -> String {
        try stream(file: URL(fileURLWithPath: file), chunkSize: chunkSize)
    }
}

/// 增量 SHA-256（FIPS 180-4）压缩状态：与 `SHA256.hash` 同一 IV/常量/轮函数，
/// 仅把「整段消息」拆成 64 字节块逐步压缩，并在收尾补齐 0x80 + 64 位大端比特长度。
private final class SHA256StreamingEngine {
    private var h: [UInt32] = SHA256.iv
    private var block = [UInt8](repeating: 0, count: 64)
    private var blockFill = 0
    private var totalBytes: UInt64 = 0
    private var w = [UInt32](repeating: 0, count: 64)

    /// 追加一段字节：凑满 64 字节即压缩，未满部分留待下次。
    func update(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes &+= UInt64(data.count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let take = min(64 - blockFill, raw.count - offset)
                for i in 0..<take {
                    block[blockFill + i] = raw[offset + i]
                }
                blockFill += take
                offset += take
                if blockFill == 64 {
                    compress()
                    blockFill = 0
                }
            }
        }
    }

    /// 收尾并输出 32 字节摘要（一次性调用；调用后状态不再使用）。
    func finalize() -> [UInt8] {
        let bitLength = totalBytes &* 8
        block[blockFill] = 0x80
        blockFill += 1
        // 0x80 之后不足 8 字节长度域：先补满本块压缩，再单独补一块长度。
        if blockFill > 56 {
            while blockFill < 64 {
                block[blockFill] = 0
                blockFill += 1
            }
            compress()
            blockFill = 0
        }
        while blockFill < 56 {
            block[blockFill] = 0
            blockFill += 1
        }
        for i in 0..<8 {
            block[56 + i] = UInt8((bitLength >> (56 - 8 * i)) & 0xff)
        }
        compress()

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

    /// 压缩一个 64 字节块（与 `SHA256.hash` 的消息调度/轮函数逐行一致）。
    private func compress() {
        for i in 0..<16 {
            let base = i * 4
            w[i] = UInt32(block[base]) << 24
                | UInt32(block[base + 1]) << 16
                | UInt32(block[base + 2]) << 8
                | UInt32(block[base + 3])
        }
        for i in 16..<64 {
            let s0 = SHA256.rotateRight(w[i - 15], 7) ^ SHA256.rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = SHA256.rotateRight(w[i - 2], 17) ^ SHA256.rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let sum1 = SHA256.rotateRight(e, 6) ^ SHA256.rotateRight(e, 11) ^ SHA256.rotateRight(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ sum1 &+ ch &+ SHA256.k[i] &+ w[i]
            let sum0 = SHA256.rotateRight(a, 2) ^ SHA256.rotateRight(a, 13) ^ SHA256.rotateRight(a, 22)
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
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xff), UInt8((self >> 48) & 0xff), UInt8((self >> 40) & 0xff), UInt8((self >> 32) & 0xff),
            UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff),
        ]
    }
}
