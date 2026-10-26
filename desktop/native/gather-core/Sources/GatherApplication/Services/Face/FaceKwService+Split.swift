// desktop/native/gather-core/Sources/GatherApplication/Services/Face/FaceKwService+Split.swift
// P0 / F0：未绑定簇拆分、合并后的约束联动。
//
// v1 只允许未绑定簇拆分（绑定真相 = role_bindings）；拆分写一条 separate 约束，
// 全量重聚类后由 applyClusterConstraints 保持；merge 删除跨两侧的 separate 并
// 写 together，使“拆分→合并”可逆。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol

extension FaceKwService {

    /// 拆分所选成员到新簇。仅未绑定簇；不写 person 投影、不写 XMP。
    public func splitCluster(
        sessionId: String,
        clusterId: Int64,
        memberIds: [Int64]
    ) throws -> FaceSplitResult {
        if controller(for: sessionId) != nil {
            throw FaceKwServiceError.analysisRunning
        }
        guard let clusterSessionId = try faceRepo.getClusterSessionId(clusterId) else {
            throw FaceKwServiceError.clusterNotFound
        }
        guard clusterSessionId == sessionId else {
            throw FaceKwServiceError.clusterNotInSession
        }
        guard !memberIds.isEmpty else { throw FaceKwServiceError.splitEmpty }
        guard Set(memberIds).count == memberIds.count else {
            throw FaceKwServiceError.splitInvalidMember
        }
        guard try !faceRepo.isClusterBound(clusterId: clusterId) else {
            throw FaceKwServiceError.clusterBound
        }

        let members = try faceRepo.getClusterMembersFull(clusterId: clusterId)
        let memberById = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        guard memberIds.allSatisfy({ memberById[$0] != nil }) else {
            throw FaceKwServiceError.splitInvalidMember
        }
        guard memberIds.count < members.count else {
            throw FaceKwServiceError.splitKeepOne
        }
        let selected = memberIds.compactMap { memberById[$0] }
        let remainingIds = Set(members.map(\.id)).subtracting(memberIds)
        let remaining = members.filter { remainingIds.contains($0.id) }
        guard selected.allSatisfy({ $0.observationId != nil }),
              remaining.allSatisfy({ $0.observationId != nil })
        else {
            throw FaceKwServiceError.splitMemberUnresolved
        }

        let label = try nextPersonLabel(sessionId: sessionId)
        let memberKeys = constraintKeys(selected)
        let peerKeys = constraintKeys(remaining)

        return try transactions.transaction {
            guard try !faceRepo.isClusterBound(clusterId: clusterId) else {
                throw FaceKwServiceError.clusterBound
            }
            let newClusterId = try faceRepo.createCluster(sessionId: sessionId, label: label)
            let moved = try faceRepo.moveClusterMembers(
                memberIds: selected.map(\.id), toClusterId: newClusterId,
                sessionId: sessionId, expectedClusterId: clusterId)
            guard moved == selected.count else {
                throw FaceKwServiceError.splitInvalidMember
            }
            try faceRepo.markClustersUnbound(ids: [clusterId, newClusterId])
            try faceRepo.touchClusters(ids: [clusterId, newClusterId])
            _ = try faceRepo.insertConstraint(
                sessionId: sessionId, kind: .separate,
                memberKeys: memberKeys, peerKeys: peerKeys)
            try deleteTogetherConstraintsCrossing(
                sessionId: sessionId,
                left: Set(selected.map(\.photoId)),
                right: Set(remaining.map(\.photoId)))
            return FaceSplitResult(
                newClusterId: Int(newClusterId),
                movedCount: selected.count,
                remainingCount: remaining.count,
                label: label
            )
        }
    }

    /// merge 之后：删除跨两侧的 separate；未绑定合并写 together（可逆）。
    func updateConstraintsAfterMerge(
        sessionId: String,
        sourceId: Int64,
        targetId: Int64,
        sourcePhotoIds: Set<String>,
        targetPhotoIds: Set<String>
    ) throws {
        let targetMembers = try faceRepo.getClusterMembersFull(clusterId: targetId)
        let constraints = try faceRepo.getConstraints(sessionId: sessionId)
        var deleteIds: [Int64] = []
        for constraint in constraints where constraint.kind == .separate {
            let memberPhotos = Set(constraint.memberKeys.map(\.photoId))
            let peerPhotos = Set(constraint.peerKeys.map(\.photoId))
            // 只删除“一侧在 source、另一侧在 target”的约束；合并后它们在同一个簇。
            // 用任意照片相交会误删 source/target 与外部簇的约束（以及簇内约束）。
            let crosses = (!memberPhotos.isDisjoint(with: sourcePhotoIds)
                && !peerPhotos.isDisjoint(with: targetPhotoIds))
                || (!memberPhotos.isDisjoint(with: targetPhotoIds)
                    && !peerPhotos.isDisjoint(with: sourcePhotoIds))
            if crosses { deleteIds.append(constraint.id) }
        }
        try faceRepo.deleteConstraints(ids: deleteIds)
        if try faceRepo.isClusterBound(clusterId: targetId) { return }
        if try faceRepo.isClusterBound(clusterId: sourceId) { return }
        let keys = constraintKeys(targetMembers.filter { $0.observationId != nil })
        if keys.count >= 2 {
            _ = try faceRepo.insertConstraint(
                sessionId: sessionId, kind: .together,
                memberKeys: keys, peerKeys: [])
        }
    }

    // MARK: - 工具

    func nextPersonLabel(sessionId: String) throws -> String {
        let labels = try faceRepo.getClusterLabels(sessionId: sessionId)
        var maximum = 0
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Person ") else { continue }
            if let value = Int(trimmed.dropFirst("Person ".count)) {
                maximum = max(maximum, value)
            }
        }
        return "Person \(maximum + 1)"
    }

    func constraintKeys(_ members: [FaceClusterMemberRecord]) -> [FaceClusterConstraintKey] {
        members.compactMap { member in
            guard let observationId = member.observationId else { return nil }
            return FaceClusterConstraintKey(
                observationId: observationId,
                photoId: member.photoId,
                bbox: member.bbox
            )
        }
    }

    private func deleteTogetherConstraintsCrossing(
        sessionId: String,
        left: Set<String>,
        right: Set<String>
    ) throws {
        let constraints = try faceRepo.getConstraints(sessionId: sessionId)
        let ids = constraints.compactMap { constraint -> Int64? in
            guard constraint.kind == .together else { return nil }
            let photos = Set((constraint.memberKeys + constraint.peerKeys).map(\.photoId))
            // selected 内部保留；selected 与 remaining/外部簇的 together 都要删，
            // 否则下一次重聚类会把新簇重新合回去。remaining 内部/外部不受影响。
            guard !photos.isDisjoint(with: left) else { return nil }
            return photos.isSubset(of: left) ? nil : constraint.id
        }
        try faceRepo.deleteConstraints(ids: ids)
    }
}
