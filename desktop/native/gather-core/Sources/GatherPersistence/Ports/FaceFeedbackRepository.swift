// desktop/native/gather-core/Sources/GatherPersistence/Ports/FaceFeedbackRepository.swift
// WP3b-2：身份反馈表端口（FaceKwService 的 bind/unbind/merge/removeMember/匹配前读）。
//
// 反馈行是人工确认/拒绝的事实记录，读写在同一个应用用例事务里；Application
// 只经端口访问，SQL 留在 FaceFeedbackRepo。
import Foundation

public protocol FaceFeedbackRepository {
    func list(sessionId: String) throws -> [FaceIdentityFeedback]
    func record(
        sessionId: String,
        photoId: String,
        bbox: [Double],
        personId: String?,
        confirmed: Bool,
        keywords: [String]
    ) throws
    func forgetConfirmation(
        sessionId: String,
        photoId: String,
        bbox: [Double],
        personId: String?
    ) throws
}

public extension FaceFeedbackRepository {
    /// 旧调用点的缺省（rejected 记录不带 keywords）。
    func record(
        sessionId: String,
        photoId: String,
        bbox: [Double],
        personId: String?,
        confirmed: Bool
    ) throws {
        try record(
            sessionId: sessionId, photoId: photoId, bbox: bbox,
            personId: personId, confirmed: confirmed, keywords: []
        )
    }
}

extension FaceFeedbackRepo: FaceFeedbackRepository {}
