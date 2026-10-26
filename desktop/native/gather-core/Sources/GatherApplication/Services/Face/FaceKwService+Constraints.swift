// desktop/native/gather-core/Sources/GatherApplication/Services/Face/FaceKwService+Constraints.swift
// P0 / F0：全量聚类提交事务内应用人工约束（separate/together），
// 保证拆分在 recluster 后保持、合并后可逆。
//
// 冲突策略：绑定簇一律跳过（绝不拆用户身份投影）；separate 优先于 together；
// 最多 3 轮收敛；异常只记日志，不阻断本次分析提交。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol

struct ClusterConstraintReport: Sendable, Equatable {
    var separateApplied = 0
    var togetherApplied = 0
    var skippedBound = 0
    var skippedUnresolved = 0
    var deletedConstraints = 0
    var prunedConstraints = 0
}

extension FaceKwService {

    /// 在 commitFullClusters 的绑定迁移之后、写签名之前调用。
    @discardableResult
    func applyClusterConstraints(sessionId: String) throws -> ClusterConstraintReport {
        var report = ClusterConstraintReport()
        let constraints = try faceRepo.getConstraints(sessionId: sessionId)
        guard !constraints.isEmpty else { return report }
        var deleted = Set<Int64>()

        // 每轮只应用一条（应用后簇结构已变，必须重读）；轮数必须覆盖全部约束，
        // 不能固定 64 上限（多出的约束会静默不生效）。
        let maxRounds = max(3, constraints.count + 2)
        for _ in 0..<maxRounds {
            let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
            guard !clusters.isEmpty else { break }
            let bindingIds = Set(try faceRepo.getBindingsBySession(sessionId).map(\.clusterId))
            let allMembers = clusters.flatMap { $0.members ?? [] }
            var didChange = false

            // separate 优先：每个约束只处理一个共享簇。
            for constraint in constraints where constraint.kind == .separate {
                guard !deleted.contains(constraint.id) else { continue }
                let memberRows = resolve(constraint.memberKeys, among: allMembers)
                let peerRows = resolve(constraint.peerKeys, among: allMembers)
                let memberKeys = keys(for: memberRows)
                let peerKeys = keys(for: peerRows)
                if memberKeys.isEmpty || peerKeys.isEmpty {
                    // 一侧语义为空（成员已全部不存在）：整条删除。
                    try faceRepo.deleteConstraint(id: constraint.id)
                    deleted.insert(constraint.id)
                    report.deletedConstraints += 1
                    continue
                }
                if memberKeys != constraint.memberKeys || peerKeys != constraint.peerKeys {
                    // 剪除失效键：写回解析成功的键，下一轮按新键继续。
                    try faceRepo.updateConstraintKeys(
                        id: constraint.id, memberKeys: memberKeys, peerKeys: peerKeys)
                    report.prunedConstraints += 1
                    continue
                }
                // 约束两侧可能各自跨多个簇：必须取“同时包含两侧成员”的公共簇，
                // 不能取某一侧的最小 id 簇（否则跨簇场景会静默丢拆分）。
                let memberClusters = Set(memberRows.map(\.clusterId))
                let peerClusters = Set(peerRows.map(\.clusterId))
                guard let clusterId = memberClusters.intersection(peerClusters).min()
                else { continue }
                if bindingIds.contains(clusterId) {
                    report.skippedBound += 1
                    continue
                }
                let insideMember = memberRows.filter { $0.clusterId == clusterId }
                let insidePeer = peerRows.filter { $0.clusterId == clusterId }
                if insideMember.isEmpty || insidePeer.isEmpty { continue }

                let moveMemberSide: Bool
                if insideMember.count != insidePeer.count {
                    moveMemberSide = insideMember.count < insidePeer.count
                } else {
                    let memberMin = insideMember.compactMap(\.observationId).min() ?? Int64.max
                    let peerMin = insidePeer.compactMap(\.observationId).min() ?? Int64.max
                    moveMemberSide = memberMin > peerMin
                }
                let moving = moveMemberSide ? insideMember : insidePeer
                guard !moving.isEmpty else { continue }
                let label = try nextPersonLabel(sessionId: sessionId)
                let newClusterId = try faceRepo.createCluster(sessionId: sessionId, label: label)
                let moved = try faceRepo.moveClusterMembers(
                    memberIds: moving.map(\.id), toClusterId: newClusterId,
                    sessionId: sessionId, expectedClusterId: clusterId)
                guard moved == moving.count else {
                    // 半拆分补偿：搬回原簇并删掉空的新簇，保持“要么全拆要么不动”。
                    for member in moving {
                        BestEffort.attempt("rollback split member") {
                            _ = try faceRepo.moveClusterMembers(
                                memberIds: [member.id], toClusterId: clusterId,
                                sessionId: sessionId, expectedClusterId: newClusterId)
                        }
                    }
                    BestEffort.attempt("rollback split cluster") {
                        _ = try faceRepo.deleteEmptyUnboundClusters(ids: [newClusterId])
                    }
                    report.skippedUnresolved += 1
                    continue
                }
                try faceRepo.markClustersUnbound(ids: [clusterId, newClusterId])
                try faceRepo.touchClusters(ids: [clusterId, newClusterId])
                report.separateApplied += 1
                didChange = true
                break
            }

            if !didChange {
                for constraint in constraints where constraint.kind == .together {
                    guard !deleted.contains(constraint.id) else { continue }
                    let rows = resolve(constraint.memberKeys, among: allMembers)
                    let pruned = keys(for: rows)
                    if pruned.count < 2 {
                        // 语义不足两人：约束不再有意义。
                        try faceRepo.deleteConstraint(id: constraint.id)
                        deleted.insert(constraint.id)
                        report.deletedConstraints += 1
                        continue
                    }
                    if pruned != constraint.memberKeys {
                        try faceRepo.updateConstraintKeys(
                            id: constraint.id, memberKeys: pruned, peerKeys: constraint.peerKeys)
                        report.prunedConstraints += 1
                        continue
                    }
                    let clusterIds = Set(rows.map(\.clusterId))
                    guard clusterIds.count > 1 else { continue }
                    if !clusterIds.isDisjoint(with: bindingIds) {
                        report.skippedBound += 1
                        continue
                    }
                    guard let target = clusterIds.min() else { continue }
                    let movingMembers = rows.filter { $0.clusterId != target }
                    let mergedIds = Set(rows.map(\.id))
                    if violatesSeparate(mergedIds: mergedIds, constraints: constraints, allMembers: allMembers) {
                        continue
                    }
                    // together 的成员可能来自多个源簇：按源簇分组，逐组带守卫搬移。
                    var moved = 0
                    for (sourceClusterId, group) in Dictionary(
                        grouping: movingMembers, by: \.clusterId
                    ) {
                        moved += try faceRepo.moveClusterMembers(
                            memberIds: group.map(\.id), toClusterId: target,
                            sessionId: sessionId, expectedClusterId: sourceClusterId)
                    }
                    guard moved == movingMembers.count else {
                        for member in movingMembers {
                            BestEffort.attempt("rollback merge member") {
                                _ = try faceRepo.moveClusterMembers(
                                    memberIds: [member.id], toClusterId: member.clusterId,
                                    sessionId: sessionId, expectedClusterId: target)
                            }
                        }
                        report.skippedUnresolved += 1
                        continue
                    }
                    try faceRepo.touchClusters(ids: [target])
                    _ = try faceRepo.deleteEmptyUnboundClusters(
                        ids: clusterIds.filter { $0 != target }.map { $0 })
                    report.togetherApplied += 1
                    didChange = true
                    break
                }
            }

            if !didChange { break }
        }
        return report
    }

    /// 已解析成员 → 约束键（用于剪除失效键）；无 observation 的成员不能生成键。
    private func keys(for rows: [FaceClusterMemberRow]) -> [FaceClusterConstraintKey] {
        rows.compactMap { row in
            guard let observationId = row.observationId else { return nil }
            return FaceClusterConstraintKey(
                observationId: observationId,
                photoId: row.photoId,
                bbox: parseBbox(row.bbox)
            )
        }
    }


    // MARK: - 解析

    private func resolve(
        _ keys: [FaceClusterConstraintKey],
        among members: [FaceClusterMemberRow]
    ) -> [FaceClusterMemberRow] {
        var resolved: [FaceClusterMemberRow] = []
        for key in keys {
            if let exact = members.first(where: { $0.observationId == key.observationId }) {
                resolved.append(exact)
                continue
            }
            let candidates = members.filter { $0.photoId == key.photoId }
            let best = candidates
                .map { (member: $0, overlap: FaceIdentityPolicy.overlap(key.bbox, parseBbox($0.bbox))) }
                .max { lhs, rhs in
                    lhs.overlap == rhs.overlap ? lhs.member.id > rhs.member.id : lhs.overlap < rhs.overlap
                }
            if let best, best.overlap >= 0.5 {
                resolved.append(best.member)
            }
        }
        // 去重（同一成员被多个键命中）。
        var seen = Set<Int64>()
        return resolved.filter { seen.insert($0.id).inserted }
    }

    private func violatesSeparate(
        mergedIds: Set<Int64>,
        constraints: [FaceClusterConstraintRow],
        allMembers: [FaceClusterMemberRow]
    ) -> Bool {
        for constraint in constraints where constraint.kind == .separate {
            let lhs = Set(resolve(constraint.memberKeys, among: allMembers).map(\.id))
            let rhs = Set(resolve(constraint.peerKeys, among: allMembers).map(\.id))
            if !lhs.isDisjoint(with: mergedIds) && !rhs.isDisjoint(with: mergedIds) {
                return true
            }
        }
        return false
    }
}
