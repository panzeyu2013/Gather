// desktop/native/gather-core/Sources/GatherApplication/Services/Face/FaceKwService+ReviewQueue.swift
// P0 / F0：face.review 的编排（分页成员 + cohesion + 摘要）。
//
// 复核计算（embedding/cohesion）按 session/cluster/阈值缓存；缓存值带 DB revision，
// 簇/成员/约束/绑定/观测变化后 revision 不匹配即自动重算。分页仍在缓存输出上做。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol

extension FaceKwService {

    public func review(_ input: FaceReviewInput) throws -> FaceReviewPage {
        if let clusterId = input.clusterId {
            guard let sessionId = try faceRepo.getClusterSessionId(Int64(clusterId)) else {
                throw FaceKwServiceError.clusterNotFound
            }
            guard sessionId == input.sessionId else {
                throw FaceKwServiceError.clusterNotInSession
            }
        }

        let thresholds = FaceReviewEngine.Thresholds(
            cohesionFloor: getNumber("face_review_cohesion_floor", 0.35),
            madMultiplier: getNumber("face_review_relative_mad", 2.5),
            minQuality: getNumber("face_review_min_quality", 0.35),
            minFaceSize: getNumber("face_review_face_size_min", 48)
        )
        let cacheKey = Self.reviewCacheKey(
            input: input, thresholds: thresholds)
        let revision: String?
        do {
            revision = try faceRepo.reviewRevision(sessionId: input.sessionId)
        } catch {
            revision = nil
        }
        if let revision, let cached = cachedReview(key: cacheKey, revision: revision) {
            return try makePage(
                sortedItems: cached.sortedItems,
                indexByMemberId: cached.indexByMemberId,
                suspectTotal: cached.suspectTotal,
                summaries: cached.summaries,
                input: input)
        }

        let clusters = try faceRepo.getClusters(input.sessionId, includeMembers: false)
        let labelById = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0.label) })
        let clusterIds: [Int64]
        if let clusterId = input.clusterId {
            clusterIds = [Int64(clusterId)]
        } else {
            clusterIds = clusters.map(\.id)
        }
        let rows = try faceRepo.getReviewMembers(sessionId: input.sessionId, clusterIds: clusterIds)
        let grouped = Dictionary(grouping: rows, by: \.clusterId)
        let inputs = clusterIds.compactMap { id -> FaceReviewEngine.ClusterInput? in
            guard let members = grouped[id], !members.isEmpty else { return nil }
            return FaceReviewEngine.ClusterInput(
                clusterId: id,
                label: labelById[id] ?? "Person",
                members: members
            )
        }
        let output = FaceReviewEngine.evaluate(inputs, thresholds: thresholds)
        let sorted = sortedItems(output.items, includeResolved: input.includeResolved)
        let indexByMemberId = Self.indexMap(sorted)
        let suspects = sorted.filter { $0.flags.contains(.suspect) }.count
        if let revision {
            storeReview(
                key: cacheKey, revision: revision, output: output,
                sortedItems: sorted, indexByMemberId: indexByMemberId,
                suspectTotal: suspects)
        }
        return try makePage(
            sortedItems: sorted, indexByMemberId: indexByMemberId, suspectTotal: suspects,
            summaries: output.summaries, input: input)
    }

    // MARK: - 缓存

    private static func reviewCacheKey(
        input: FaceReviewInput,
        thresholds: FaceReviewEngine.Thresholds
    ) -> String {
        [
            input.sessionId,
            String(input.clusterId ?? -1),
            input.includeResolved ? "1" : "0",
            "\(thresholds.cohesionFloor)",
            "\(thresholds.madMultiplier)",
            "\(thresholds.minQuality)",
            "\(thresholds.minFaceSize)",
        ].joined(separator: "|")
    }

    private func cachedReview(
        key: String, revision: String
    ) -> ReviewCacheEntry? {
        reviewCacheLock.lock()
        defer { reviewCacheLock.unlock() }
        guard let entry = reviewCache[key], entry.revision == revision else { return nil }
        return entry
    }

    private func storeReview(
        key: String, revision: String, output: FaceReviewEngine.Output,
        sortedItems: [FaceReviewItem], indexByMemberId: [Int: Int], suspectTotal: Int
    ) {
        reviewCacheLock.lock()
        defer { reviewCacheLock.unlock() }
        // 10k 复核时 8 份全量 item 很重：大结果只保留 1 份，普通结果最多 8 份；
        // 只存排序索引和 summaries，不再重复存 raw Output。
        if sortedItems.count > 2_000 {
            reviewCache.removeAll(keepingCapacity: true)
        } else if reviewCache.count >= 8 {
            reviewCache.removeAll(keepingCapacity: true)
        }
        reviewCache[key] = ReviewCacheEntry(
            revision: revision, summaries: output.summaries,
            sortedItems: sortedItems, indexByMemberId: indexByMemberId,
            suspectTotal: suspectTotal)
    }

    private func sortedItems(
        _ items: [FaceReviewItem], includeResolved: Bool
    ) -> [FaceReviewItem] {
        var result = includeResolved ? items : items.filter { !$0.flags.isEmpty }
        result.sort { lhs, rhs in
            let lSuspect = lhs.flags.contains(.suspect)
            let rSuspect = rhs.flags.contains(.suspect)
            if lSuspect != rSuspect { return lSuspect }
            if !lhs.flags.isEmpty != !rhs.flags.isEmpty { return !lhs.flags.isEmpty }
            if lhs.cohesion != rhs.cohesion { return lhs.cohesion < rhs.cohesion }
            if lhs.memberId != rhs.memberId { return lhs.memberId < rhs.memberId }
            return lhs.clusterId < rhs.clusterId
        }
        return result
    }

    // MARK: - 分页

    private func makePage(
        sortedItems: [FaceReviewItem],
        indexByMemberId: [Int: Int],
        suspectTotal: Int,
        summaries: [FaceReviewClusterSummary],
        input: FaceReviewInput
    ) throws -> FaceReviewPage {
        let total = sortedItems.count
        var start = 0
        if let cursor = input.cursor {
            // 排序含 suspect/flag 优先级，不能退化为 cohesion/memberId 比较；
            // 找不到游标成员说明数据已变化，明确报错让 UI 从头拉。
            guard let index = indexByMemberId[cursor] else {
                throw FaceKwServiceError.reviewCursorInvalid
            }
            start = index + 1
        }
        guard start <= total else { throw FaceKwServiceError.reviewCursorInvalid }
        let remaining = sortedItems[start...]
        let pageItems = Array(remaining.prefix(input.limit))
        let nextCursor: Int? = remaining.count > input.limit ? pageItems.last?.memberId : nil
        let filteredSummaries = summaries.filter { summary in
            input.clusterId == nil || summary.clusterId == input.clusterId
        }
        return FaceReviewPage(
            items: pageItems,
            nextCursor: nextCursor,
            total: total,
            suspectTotal: suspectTotal,
            clusters: filteredSummaries
        )
    }

    private static func indexMap(_ items: [FaceReviewItem]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        map.reserveCapacity(items.count)
        for (index, item) in items.enumerated() { map[item.memberId] = index }
        return map
    }

}
