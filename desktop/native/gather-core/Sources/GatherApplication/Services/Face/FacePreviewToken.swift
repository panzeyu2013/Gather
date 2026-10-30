// desktop/native/gather-core/Sources/GatherApplication/Services/Face/FacePreviewToken.swift
// P1-4：人脸写回预览身份。
//
// 只覆盖“会改变写回结果”的绑定状态：簇 id / 成员集合 / 角色名 / 关键词集合。
// 不依赖时间、UI 状态或预览条目顺序；preview 与 writeback 用同一函数复算。
import Foundation
import GatherPersistence

enum FacePreviewToken {
    static func make(sessionId: String, clusters: [FaceClusterRow]) -> String {
        let payload = clusters
            .sorted { $0.id < $1.id }
            .map { cluster in
                let role = cluster.binding?.roleName ?? ""
                let keywords = (cluster.binding?.keywords ?? []).sorted().joined(separator: "\u{1F}")
                // 成员集合必须进入指纹：等量替换成员时 memberCount 不变，但写回照片集已变。
                let members = (cluster.members ?? []).map(\.photoId).sorted().joined(separator: ",")
                return "\(cluster.id)|\(cluster.memberCount)|\(members)|\(role)|\(keywords)"
            }
            .joined(separator: "\n")
        let bytes = SHA256.hash(Data((sessionId + "\n" + payload).utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
