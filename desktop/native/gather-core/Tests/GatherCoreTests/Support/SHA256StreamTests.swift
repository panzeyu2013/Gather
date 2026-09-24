// desktop/native/gather-core/Tests/GatherCoreTests/Support/SHA256StreamTests.swift
// W2a：SHA256.stream(file:chunkSize:) 流式哈希测试。
// 覆盖：权威向量（空/abc/hello world/百万 a）、与一次性 hash(Data) 逐字节一致、
// chunkSize=1、各 64 字节分块边界（55/56/57/63/64/65/…）、恰好整除与单块读取、
// chunkSize 大于文件、默认分块、>8 MiB 大文件、非正 chunkSize 归一化、缺文件抛错。

import Testing
import Foundation
@testable import GatherCore

// MARK: - 支撑

/// 临时目录作用域（每个用例独立 UUID，结束即删）。
private func withTempDir<T>(_ body: (String) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-sha256-stream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir.path)
}

private func writeFile(_ dir: String, _ name: String, _ data: Data) throws -> String {
    let path = dir + "/" + name
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

private func oneShotHex(_ data: Data) -> String {
    SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
}

/// 确定性伪随机内容（xorshift64*），用于大文件的跨块内容与分块边界。
private func deterministicBytes(count: Int) -> Data {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        bytes.append(UInt8(truncatingIfNeeded: state &* 0x2545_F491_4F6C_DD1D))
    }
    return Data(bytes)
}

struct SHA256StreamTests {

    @Test func knownVectorsMatch() throws {
        try withTempDir { dir in
            let empty = try writeFile(dir, "empty.bin", Data())
            let emptyDigest = try SHA256.stream(file: empty)
            #expect(emptyDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

            let abc = try writeFile(dir, "abc.bin", Data("abc".utf8))
            let abcDigest = try SHA256.stream(file: abc)
            #expect(abcDigest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

            let hello = try writeFile(dir, "hello.bin", Data("hello world".utf8))
            let helloDigest = try SHA256.stream(file: hello, chunkSize: 1)
            #expect(helloDigest == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")

            // 权威向量：1,000,000 个 a（shasum -a 256 对拍）。
            let millionA = try writeFile(dir, "million-a.bin", Data(repeating: 0x61, count: 1_000_000))
            let millionDigest = try SHA256.stream(file: millionA, chunkSize: 4096)
            #expect(millionDigest == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        }
    }

    @Test func matchesOneShotHashAcrossBlockBoundaries() throws {
        try withTempDir { dir in
            let sizes = [0, 1, 2, 3, 54, 55, 56, 57, 58, 63, 64, 65, 66, 119, 120, 121, 127, 128, 129, 191, 192, 193, 1000, 4096]
            for size in sizes {
                let data = deterministicBytes(count: size)
                let path = try writeFile(dir, "size-\(size).bin", data)
                let streamed = try SHA256.stream(file: path, chunkSize: 1)
                let expected = oneShotHex(data)
                #expect(streamed == expected, "size=\(size) chunkSize=1 应与一次性哈希一致")
            }
        }
    }

    @Test func chunkSizeDoesNotAffectDigest() throws {
        try withTempDir { dir in
            let data = deterministicBytes(count: 1000)
            let path = try writeFile(dir, "chunking.bin", data)
            let expected = oneShotHex(data)
            for chunkSize in [1, 2, 7, 55, 56, 57, 63, 64, 65, 127, 128, 129, 250, 500, 999, 1000, 1001, 4096, 1 << 20] {
                let digest = try SHA256.stream(file: path, chunkSize: chunkSize)
                #expect(digest == expected, "chunkSize=\(chunkSize) 不应影响摘要")
            }
            // 路径重载与 URL 重载同源。
            let byPath = try SHA256.stream(file: path, chunkSize: 7)
            let byURL = try SHA256.stream(file: URL(fileURLWithPath: path), chunkSize: 7)
            #expect(byPath == expected)
            #expect(byURL == expected)
        }
    }

    @Test func exactDivisibleChunksAndSingleChunkMatchOneShot() throws {
        try withTempDir { dir in
            // 192 = 64 * 3：恰好整除块边界，收尾无残余数据块。
            let data = deterministicBytes(count: 192)
            let path = try writeFile(dir, "divisible.bin", data)
            let expected = oneShotHex(data)
            for chunkSize in [32, 64, 96, 192] {
                let digest = try SHA256.stream(file: path, chunkSize: chunkSize)
                #expect(digest == expected, "chunkSize=\(chunkSize)（恰好整除）应与一次性一致")
            }
            // chunkSize > 文件大小：单次读取 + finalize。
            let oversized = try SHA256.stream(file: path, chunkSize: 10_000)
            #expect(oversized == expected)
        }
    }

    @Test func nonPositiveChunkSizeClampsToOneByte() throws {
        try withTempDir { dir in
            let data = deterministicBytes(count: 130)
            let path = try writeFile(dir, "clamp.bin", data)
            let expected = oneShotHex(data)
            let one = try SHA256.stream(file: path, chunkSize: 1)
            let zero = try SHA256.stream(file: path, chunkSize: 0)
            let negative = try SHA256.stream(file: path, chunkSize: -9)
            #expect(one == expected)
            #expect(zero == expected)
            #expect(negative == expected)
        }
    }

    @Test func largeFileOverEightMegabytesMatchesOneShot() throws {
        try withTempDir { dir in
            let size = 8 * 1024 * 1024 + 123
            let data = deterministicBytes(count: size)
            let path = try writeFile(dir, "large.bin", data)
            let expected = oneShotHex(data)
            for chunkSize in [63, 64 * 1024] {
                let digest = try SHA256.stream(file: path, chunkSize: chunkSize)
                #expect(digest == expected, "8MB+ 文件 chunkSize=\(chunkSize) 应与一次性哈希一致")
            }
            // 默认分块（1 MiB）路径。
            let defaultDigest = try SHA256.stream(file: path)
            #expect(defaultDigest == expected, "默认分块应与一次性哈希一致")
        }
    }

    @Test func missingFileThrows() {
        let missing = "/tmp/gather-sha256-stream-missing-\(UUID().uuidString).bin"
        #expect(throws: (any Error).self) {
            _ = try SHA256.stream(file: missing)
        }
    }
}
