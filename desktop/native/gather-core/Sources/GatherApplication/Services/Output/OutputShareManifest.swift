// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputShareManifest.swift
// Wave3：分享清单（share.json）的唯一写入实现，WebDAV 与 S3 两个通道共用。
//
// 兼容：字段只增不改——version 仍为 1，旧 proof.js 读到未知字段会忽略；
// 没有口令时**不写**口令字段（旧分享包字节不变）。
// 安全：只写口令派生结果（algorithm/salt/iterations/hash），绝不写明文；
// 也不写 accessKey/secret（凭据只在 Keychain）。
import Foundation
import GatherProtocol

public enum OutputShareManifest {
    /// share.json 的 JSON 字节（sortedKeys + prettyPrinted：与旧输出逐字兼容）。
    public static func json(
        share: OutputShareOptions,
        itemCount: Int,
        createdAt: String? = nil
    ) -> Data {
        var payload: [String: JSONValue] = [:]
        payload["version"] = .number(1)
        payload["createdAt"] = .string(createdAt ?? Self.iso8601Now())
        payload["itemCount"] = .number(Double(itemCount))
        payload["allowDownload"] = .bool(share.allowDownload)
        payload["remoteSubfolder"] = .string(share.remoteSubfolder)
        if let expiresAt = share.expiresAt, !expiresAt.isEmpty {
            payload["expiresAt"] = .string(expiresAt)
        }
        // 口令门：只存派生结果的盐/迭代次数/哈希；明文永不落盘。
        if let password = share.password, !password.isEmpty {
            let derived = OutputSharePassword.derive(password: password)
            payload["passwordAlgorithm"] = .string(derived.algorithm)
            payload["passwordSalt"] = .string(derived.saltHex)
            payload["passwordIterations"] = .number(Double(derived.iterations))
            payload["passwordHash"] = .string(derived.hashHex)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(payload)
        } catch {
            // 编码失败（理论上不会）时退回最小合法 JSON，保证发布流程可继续。
            return Data("{\"version\":1,\"itemCount\":\(itemCount)}".utf8)
        }
    }

    public static func iso8601Now(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
