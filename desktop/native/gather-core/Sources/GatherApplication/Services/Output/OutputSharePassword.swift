// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputSharePassword.swift
// Wave3：校样页口令的纯逻辑（PBKDF2-HMAC-SHA256）。
//
// 明确边界：口令门是**纯前端门槛**（proof.js 用 WebCrypto 同参数校验），
// 只用于"防止链接被随手翻阅"，页面内容并未加密；share.json 里只放
// algorithm/salt/iterations/hash，绝不放明文。算法参数必须与 proof.js 保持一致：
//   PBKDF2-HMAC-SHA256, iterations = 100000（可调但写入 manifest）, salt = 16 bytes,
//   dkLen = 32 bytes, hash 以小写 hex 表示。
import CryptoKit
import Foundation
import GatherProtocol

public enum OutputSharePassword {
    /// 与 proof.js 共享的算法标识（manifest.passwordAlgorithm）。
    public static let algorithm = "pbkdf2-sha256"
    public static let defaultIterations = 100_000
    public static let saltByteCount = 16
    public static let keyByteCount = 32

    /// 派生结果（manifest 里的口令字段）。
    public struct Derived: Equatable, Sendable {
        public var algorithm: String
        public var saltHex: String
        public var iterations: Int
        public var hashHex: String

        public init(algorithm: String, saltHex: String, iterations: Int, hashHex: String) {
            self.algorithm = algorithm
            self.saltHex = saltHex
            self.iterations = iterations
            self.hashHex = hashHex
        }
    }

    /// 随机盐（16 字节；SystemRandomNumberGenerator）。
    public static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        for index in 0..<bytes.count {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    /// 派生口令（salt 默认随机；iterations 默认 100000）。
    public static func derive(
        password: String,
        salt: Data = makeSalt(),
        iterations: Int = defaultIterations
    ) -> Derived {
        let safeIterations = min(max(iterations, 1), 1_000_000)
        let hash = pbkdf2SHA256(
            password: password, salt: salt, iterations: safeIterations, keyByteCount: keyByteCount)
        return Derived(
            algorithm: algorithm, saltHex: hex(salt),
            iterations: safeIterations, hashHex: hex(hash))
    }

    /// 校验口令（纯逻辑，单测与宿主/调试可用；proof.js 是同一算法的 JS 版）。
    public static func verify(password: String, derived: Derived) -> Bool {
        guard derived.algorithm == algorithm,
              let salt = data(fromHex: derived.saltHex) else { return false }
        let candidate = derive(
            password: password, salt: salt, iterations: derived.iterations)
        return constantTimeEquals(candidate.hashHex, derived.hashHex)
    }

    /// PBKDF2-HMAC-SHA256（RFC 8018）。Key 不足一轮时也走同一条 HMAC 链。
    public static func pbkdf2SHA256(
        password: String,
        salt: Data,
        iterations: Int,
        keyByteCount: Int = keyByteCount
    ) -> Data {
        precondition(iterations >= 1, "iterations must be >= 1")
        precondition(keyByteCount >= 1, "keyByteCount must be >= 1")
        let key = SymmetricKey(data: Data(password.utf8))
        var output = Data()
        var blockIndex: UInt32 = 1
        while output.count < keyByteCount {
            var block = salt
            block.append(UInt8((blockIndex >> 24) & 0xFF))
            block.append(UInt8((blockIndex >> 16) & 0xFF))
            block.append(UInt8((blockIndex >> 8) & 0xFF))
            block.append(UInt8(blockIndex & 0xFF))
            var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
            var mixed = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for index in 0..<mixed.count { mixed[index] ^= u[index] }
                }
            }
            output.append(mixed)
            blockIndex += 1
        }
        return output.prefix(keyByteCount)
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func data(fromHex text: String) -> Data? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let end = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<left.count { diff |= left[index] ^ right[index] }
        return diff == 0
    }
}
