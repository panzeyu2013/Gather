// desktop/native/gather-core/Sources/GatherApplication/Services/Similarity/SimilarityService+Hashes.swift
// P1-4 收口：SimilarityService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：hash 复用（按 asset_file_id 分块）、邻域阈值档预计算、存储载荷构建/解析。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension SimilarityService {

    /// TS: reuseSimilarityHashes —— 按 asset_file_id 分块批量读，消除逐照片 N+1；
    /// 目标照片与来源照片同资产文件且 size/mtime 一致时复用来源 hash。
    public static func reuseSimilarityHashes(
        hashes: any SimilarityHashRepository,
        transactions: any TransactionRunner,
        sessionId: String,
        photos: [PhotoProjectionRow],
        sourceStats: [String: (size: Int, mtimeMs: Double)],
        existingHashMap: inout [String: String]
    ) throws -> Int {
        var assetFileByPhoto: [String: String] = [:]
        var assetFileIds: [String] = []
        var seenAssetFiles = Set<String>()
        for row in try hashes.getPhotoAssetFileIds(sessionId: sessionId) {
            assetFileByPhoto[row.photoId] = row.assetFileId
            if seenAssetFiles.insert(row.assetFileId).inserted { assetFileIds.append(row.assetFileId) }
        }

        // 每个资产文件分块一次批量读：与任何目标照片共享资产文件的全部相似 hash。
        var rowsByAssetFile: [String: [SimilarityHashCandidate]] = [:]
        for chunkStart in stride(from: 0, to: assetFileIds.count, by: reuseHashChunkSize) {
            let chunk = Array(assetFileIds[chunkStart..<min(chunkStart + reuseHashChunkSize, assetFileIds.count)])
            for candidate in try hashes.getReuseCandidates(assetFileIds: chunk) {
                rowsByAssetFile[candidate.assetFileId, default: []].append(candidate)
            }
        }

        // 复用判定仍是应用规则；落库只交 Repo（一次 UPSERT，同一事务）。
        var reused = 0
        var writes: [SimilarityHashWrite] = []
        try transactions.transaction {
            for photo in photos {
                if existingHashMap[photo.id] != nil { continue }
                guard let sourceStat = sourceStats[photo.id],
                      let assetFileId = assetFileByPhoto[photo.id],
                      let candidates = rowsByAssetFile[assetFileId] else { continue }
                var source: SimilarityHashCandidate?
                for candidate in candidates {
                    if candidate.photoId == photo.id { continue }
                    if candidate.fileSize != sourceStat.size { continue }
                    if abs(candidate.fileMtimeMs - sourceStat.mtimeMs) >= 1 { continue }
                    if source == nil || candidate.id > source!.id { source = candidate }
                }
                guard let source else { continue }
                writes.append(SimilarityHashWrite(
                    sessionId: sessionId, photoId: photo.id, hashHex: source.hashHex,
                    fileSize: sourceStat.size, fileMtimeMs: sourceStat.mtimeMs
                ))
                existingHashMap[photo.id] = source.hashHex
                reused += 1
            }
            try hashes.upsert(writes)
        }
        return reused
    }

    /// TS: buildStoredResult。
    func buildStoredResult(
        rawGroups: [[String]],
        rawUngrouped: [String],
        pathMap: [String: String],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        precomputed: Bool,
        compactGroupsJson: Bool = false
    ) -> StoredResultPayload {
        let groups: [SimilarityGroup] = rawGroups.enumerated().map { idx, memberIds in
            SimilarityGroup(
                id: idx + 1,
                label: "Group \(idx + 1)",
                count: memberIds.count,
                images: memberIds.enumerated().map { i, photoId in
                    SimilarityImage(path: pathMap[photoId] ?? "", representative: i == 0)
                }
            )
        }
        let ungrouped: [SimilarityImage] = rawUngrouped.map { photoId in
            SimilarityImage(path: pathMap[photoId] ?? "")
        }

        // 预计算邻域档永不读 groups_json：getLatest 排除之、culling 从成员表
        // 解析、getResult 也从成员表重建。逐档 stringify 多 MB payload 纯属
        // 浪费，档位行存紧凑占位（schema 要求非空串）。
        let groupsJson: String
        if compactGroupsJson {
            groupsJson = "{\"groups\":[],\"ungrouped\":[]}"
        } else {
            let payload = StoredGroupsJSON(groups: groups, ungrouped: ungrouped)
            groupsJson = String(data: (try? JSONEncoder().encode(payload)) ?? Data(), encoding: .utf8) ?? "{}"
        }
        let statsJson = String(
            data: (try? JSONEncoder().encode(StoredStatsPayload(
                totalGroups: groups.count,
                totalUngrouped: ungrouped.count,
                threshold: Double(threshold),
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: precomputed ? true : nil
            ))) ?? Data(),
            encoding: .utf8
        ) ?? "{}"

        return StoredResultPayload(
            result: SimilarityResult(
                groups: groups,
                ungrouped: ungrouped,
                stats: SimilarityResultStats(
                    totalGroups: groups.count,
                    totalUngrouped: ungrouped.count,
                    threshold: Double(threshold),
                    minGroupSize: minGroupSize,
                    groupingMode: groupingMode
                )
            ),
            groupsJson: groupsJson,
            statsJson: statsJson,
            memberships: rawGroups.enumerated().flatMap { groupIndex, photoIds in
                photoIds.map { (photoId: $0, groupIndex: groupIndex) }
            }
        )
    }

    /// 邻域阈值档：一次 pairwise 距离遍历服务全部档位（距离与阈值无关，
    /// 只判定不同），4 档预计算不再逐档重复 O(n²)。
    func precomputeNeighborTiers(
        sessionId: String,
        entries: [HashEntry],
        pathMap: [String: String],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        signal: JobAbortSignal?,
        onProgress: ProgressHandler?
    ) async throws {
        if signal?.aborted ?? false { return }

        var savedTiers = Set<Int>([threshold])
        var candidates: [Int] = []
        for step in Self.neighborTierSteps {
            let tier = max(0, min(30, threshold + step))
            if !savedTiers.contains(tier) {
                savedTiers.insert(tier)
                candidates.append(tier)
            }
        }
        if candidates.isEmpty { return }

        let results = try multiClusterProvider(
            entries, candidates, minGroupSize, HashGroupingMode(groupingMode),
            { current, total in onProgress?(current, total, "similarity.thresholds") }
        )
        for (index, tier) in candidates.enumerated() {
            if signal?.aborted ?? false { return }
            let built = buildStoredResult(
                rawGroups: results[index].groups,
                rawUngrouped: results[index].ungrouped,
                pathMap: pathMap,
                threshold: tier,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode,
                precomputed: true,
                compactGroupsJson: true
            )
            _ = try similarityResultRepo.replaceForThreshold(
                sessionId: sessionId,
                groupsJson: built.groupsJson,
                statsJson: built.statsJson,
                threshold: tier,
                minGroupSize: minGroupSize,
                memberships: built.memberships
            )
        }
    }

    /// TS: getResult 的 stats 解析（Partial + 默认值；畸形 JSON 抛错对齐
    /// TS JSON.parse，不静默降级为全默认）。
    func parseStoredStats(_ statsJson: String) throws -> SimilarityResultStats {
        guard let data = statsJson.data(using: .utf8) else {
            throw SimilarityServiceError.noResults
        }
        let stored = try JSONDecoder().decode(StoredStatsPayload.self, from: data)
        return SimilarityResultStats(
            totalGroups: stored.totalGroups ?? 0,
            totalUngrouped: stored.totalUngrouped ?? 0,
            threshold: stored.threshold ?? 0,
            minGroupSize: stored.minGroupSize ?? 2,
            groupingMode: stored.groupingMode ?? .global,
            precomputed: stored.precomputed == true
        )
    }
}

// MARK: - 载荷类型

/// buildStoredResult 产物：相似度结果 + 落库载荷（结果与成员表）。
struct StoredResultPayload {
    let result: SimilarityResult
    let groupsJson: String
    let statsJson: String
    let memberships: [(photoId: String, groupIndex: Int)]
}

/// TS: groups_json 载荷。
struct StoredGroupsJSON: Codable {
    let groups: [SimilarityGroup]
    let ungrouped: [SimilarityImage]?
}

/// TS: stats_json 载荷（解析用，全可选；编码用全必填 + precomputed 可选）。
private struct StoredStatsPayload: Codable {
    let totalGroups: Int?
    let totalUngrouped: Int?
    let threshold: Double?
    let minGroupSize: Int?
    let groupingMode: SimilarityGroupingMode?
    let precomputed: Bool?
}
