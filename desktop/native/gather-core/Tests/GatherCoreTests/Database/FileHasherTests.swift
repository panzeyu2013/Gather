// desktop/native/gather-core/Tests/GatherCoreTests/Database/FileHasherTests.swift
// Cut 3a（module-split-map E-02）：sha256File 的**实现**从 IndexerService（Domain）
// 下沉到 FileHasher（Persistence），AssetRepo 改调后者。本测试固定"同输入同输出"：
//   - 与纯 Swift 一次性实现（Linux 回退路径）逐字节一致；
//   - 与 CryptoKit 一次性哈希一致（证明 4MB 分块流式没有边界错误）；
//   - 跨 4MB 分块边界（-1 / 正好 / +1）；
//   - 空文件、缺失文件的错误语义（不得静默返回空串）。

import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import GatherProtocol
@testable import GatherPersistence

struct FileHasherTests {
    /// 纯 Swift 一次性实现（与 FileHasher 的 Linux 回退路径同源）。
    private func pureSwiftHex(_ bytes: [UInt8]) -> String {
        SHA256.hash(Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func cryptoKitHex(_ bytes: [UInt8]) -> String? {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    private func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-filehasher-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// 确定性伪随机内容（LCG）：避免全零文件掩盖分块拼接错误。
    private func pseudoRandomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var seed: UInt32 = 0x9E37_79B9
        for index in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8((seed >> 24) & 0xFF)
        }
        return bytes
    }

    @Test func matchesKnownSHA256Vectors() throws {
        let emptyURL = try writeTemp([])
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        #expect(try FileHasher.sha256File(emptyURL.path)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let abcURL = try writeTemp(Array("abc".utf8))
        defer { try? FileManager.default.removeItem(at: abcURL) }
        #expect(try FileHasher.sha256File(abcURL.path)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func matchesOneShotImplementationsForSmallInputs() throws {
        let inputs: [[UInt8]] = [
            [],
            Array("a".utf8),
            Array("gather cut-3a file hasher".utf8),
            Array(0...255).map { UInt8($0) },
        ]
        for (index, bytes) in inputs.enumerated() {
            let url = try writeTemp(bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            let actual = try FileHasher.sha256File(url.path)
            #expect(actual == pureSwiftHex(bytes), "case \(index)：与纯 Swift 一次性实现不一致")
            if let expected = cryptoKitHex(bytes) {
                #expect(actual == expected, "case \(index)：与 CryptoKit 一次性哈希不一致")
            }
            #expect(actual.count == 64)
            #expect(actual == actual.lowercased())
        }
    }

    @Test func streamsAcrossFourMegabyteChunkBoundaries() throws {
        let chunk = 4 * 1024 * 1024
        for count in [chunk - 1, chunk, chunk + 1] {
            let bytes = pseudoRandomBytes(count: count)
            let url = try writeTemp(bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            let actual = try FileHasher.sha256File(url.path)
            #expect(actual == pureSwiftHex(bytes), "分块边界失败：\(count) 字节")
            if let expected = cryptoKitHex(bytes) {
                #expect(actual == expected, "分块边界与 CryptoKit 不一致：\(count) 字节")
            }
        }
    }

    @Test func missingFileThrowsInsteadOfReturningEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-filehasher-missing-\(UUID().uuidString).bin")
        #expect(throws: (any Error).self) {
            _ = try FileHasher.sha256File(missing.path)
        }
    }
}
