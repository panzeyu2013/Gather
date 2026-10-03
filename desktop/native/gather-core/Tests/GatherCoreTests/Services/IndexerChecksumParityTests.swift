// 临时对账：流式 SHA-256（CryptoKit）必须与纯 Swift 一次性实现逐字节一致。
import Foundation
import Testing
@testable import GatherCore

@Suite("checksum parity (streaming vs one-shot)")
struct IndexerChecksumParityTests {
    @Test("流式哈希与纯 Swift 一次性哈希逐字节一致（含跨 4MB 块边界）")
    func streamingMatchesOneShot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-checksum-parity-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // 5MB 伪随机内容：跨过 4MB 分块边界。
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024)
        var seed: UInt32 = 0x9E3779B9
        for index in 0..<bytes.count {
            seed = seed &* 1664525 &+ 1013904223
            bytes[index] = UInt8((seed >> 24) & 0xFF)
        }
        try Data(bytes).write(to: url)

        let streamed = try IndexerService.sha256File(url.path)
        let oneShot = SHA256.hash(Data(bytes)).map { String(format: "%02x", $0) }.joined()
        #expect(streamed == oneShot, "流式与一次性哈希必须一致")
        #expect(streamed.count == 64)
    }
}
