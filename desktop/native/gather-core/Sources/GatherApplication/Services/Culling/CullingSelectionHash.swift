// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingSelectionHash.swift
// P1-7：选择集身份。排序后拼接 + SHA-256；selection 与 updateSelection 共用。
import Foundation
import GatherPersistence

enum CullingSelectionHash {
    static func make(ids: [String]) -> String {
        // 长度前缀避免拼接歧义：["a\nb"] 与 ["a", "b"] 不得同哈希。
        let payload = ids.sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "\n")
        return SHA256.hash(Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
