// desktop/native/gather-core/Sources/GatherApplication/Services/Face/FaceReviewEngine.swift
// P0 / F0：复核队列的纯函数（cohesion / flags / suspect）。
//
// 口径见 docs/design/p0/f0-face-split.md §6.4：
// - 合格样本：observation 存在、向量非空、quality >= minQuality、model 与簇众数一致；
// - n>=4 用质心 cosine；n<=3 用两两最小值；n=1 不标 suspect；
// - lowQuality/unresolved/incompatible 不参与质心，也不标 suspect；
// - smallFace 仍参与判据并展示。
import Foundation
import GatherPersistence
import GatherProtocol

enum FaceReviewEngine {
    struct Thresholds: Sendable, Equatable {
        var cohesionFloor: Double = 0.35
        var madMultiplier: Double = 2.5
        var minQuality: Double = 0.35
        var minFaceSize: Double = 48

        static let defaults = Thresholds()
    }

    struct ClusterInput: Sendable {
        let clusterId: Int64
        let label: String
        let members: [FaceReviewMemberRow]
    }

    struct Output: Sendable {
        let items: [FaceReviewItem]
        let summaries: [FaceReviewClusterSummary]
    }

    static func evaluate(_ clusters: [ClusterInput], thresholds: Thresholds) -> Output {
        var items: [FaceReviewItem] = []
        var summaries: [FaceReviewClusterSummary] = []

        for cluster in clusters {
            let members = cluster.members
            guard !members.isEmpty else { continue }

            let mode = modelMode(members, minQuality: thresholds.minQuality)
            // 嵌入维度众数：混入一条截断/异维 blob 不能把整簇打成 suspect。
            let dimension = dominantDimension(members)
            var eligible: [(member: FaceReviewMemberRow, vector: [Float])] = []
            for member in members {
                guard member.observationId != nil, !member.embedding.isEmpty else { continue }
                guard member.quality >= thresholds.minQuality else { continue }
                guard modelMatches(member, mode: mode) else { continue }
                guard let dimension, member.embedding.count == dimension else { continue }
                eligible.append((member, normalize(member.embedding)))
            }

            let centroid = eligible.count >= 4 ? centroid(of: eligible.map(\.vector)) : nil
            var cohesionByMember: [Int64: Double] = [:]
            for entry in eligible {
                if let centroid {
                    cohesionByMember[entry.member.memberId] = cosine(entry.vector, centroid)
                } else if eligible.count == 1 {
                    cohesionByMember[entry.member.memberId] = 1
                } else {
                    // 质心不可用（维度不一致等）时退回两两最小值，避免全员 -1。
                    cohesionByMember[entry.member.memberId] = eligible
                        .filter { $0.member.memberId != entry.member.memberId }
                        .map { cosine(entry.vector, $0.vector) }
                        .min() ?? 0
                }
            }

            let eligibleCohesions = cohesionByMember.values.sorted()
            let median = medianValue(eligibleCohesions) ?? 0
            let mad = medianValue(eligibleCohesions.map { abs($0 - median) }) ?? 0
            let relativeFloor = median - thresholds.madMultiplier * mad
            let suspectFloor = eligible.count >= 5
                ? max(thresholds.cohesionFloor, relativeFloor)
                : thresholds.cohesionFloor

            var clusterItems: [FaceReviewItem] = []
            var suspectCount = 0
            var reviewCount = 0
            for member in members {
                var flags: [FaceReviewFlag] = []
                let resolved = member.observationId != nil && !member.embedding.isEmpty
                if !resolved {
                    // 未解析行不叠 lowQuality：LEFT JOIN 的缺省 0 不是真实质量结论。
                    flags.append(.unresolvedObservation)
                } else {
                    if member.quality < thresholds.minQuality { flags.append(.lowQuality) }
                    let dimensionMismatch = dimension.map { member.embedding.count != $0 } ?? false
                    // 只有“簇内存在可比较模型”时，空 modelId 才算不兼容；
                    // 全部旧行为空时 mode 为 nil，不能把整簇标记为不兼容。
                    let modelMismatch = (mode != nil && member.modelId.isEmpty)
                        || !modelMatches(member, mode: mode)
                    if modelMismatch || dimensionMismatch {
                        flags.append(.incompatibleModel)
                    }
                }
                if resolved, member.faceSizePx < thresholds.minFaceSize { flags.append(.smallFace) }

                let cohesion = resolved ? (cohesionByMember[member.memberId] ?? -1) : -1
                if resolved,
                   member.quality >= thresholds.minQuality,
                   modelMatches(member, mode: mode),
                   !flags.contains(.incompatibleModel),
                   eligible.count >= 2,
                   cohesion < suspectFloor {
                    flags.insert(.suspect, at: 0)
                    suspectCount += 1
                }

                if !flags.isEmpty { reviewCount += 1 }
                let filename = (member.photoPath as NSString).lastPathComponent
                clusterItems.append(FaceReviewItem(
                    clusterId: Int(member.clusterId),
                    clusterLabel: member.clusterLabel,
                    memberId: Int(member.memberId),
                    photoId: member.photoId,
                    photoPath: member.photoPath,
                    filename: filename,
                    bbox: member.bbox,
                    confidence: member.confidence,
                    quality: member.quality,
                    faceSizePx: member.faceSizePx,
                    cohesion: resolved ? cohesion : -1,
                    flags: flags
                ))
            }

            clusterItems.sort { lhs, rhs in
                let lSuspect = lhs.flags.contains(.suspect)
                let rSuspect = rhs.flags.contains(.suspect)
                if lSuspect != rSuspect { return lSuspect }
                if !lhs.flags.isEmpty != !rhs.flags.isEmpty { return !lhs.flags.isEmpty }
                if lhs.cohesion != rhs.cohesion { return lhs.cohesion < rhs.cohesion }
                return lhs.memberId < rhs.memberId
            }
            items.append(contentsOf: clusterItems)

            summaries.append(FaceReviewClusterSummary(
                clusterId: Int(cluster.clusterId),
                label: cluster.label,
                size: members.count,
                suspectCount: suspectCount,
                reviewCount: reviewCount,
                cohesion: eligibleCohesions.isEmpty ? nil : rounded(median)
            ))
        }

        summaries.sort {
            if $0.reviewCount != $1.reviewCount { return $0.reviewCount > $1.reviewCount }
            return $0.clusterId < $1.clusterId
        }
        return Output(items: items, summaries: summaries)
    }

    // MARK: - 数学

    static func normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        for value in vector { norm += value * value }
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var ln: Float = 0
        var rn: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            ln += lhs[index] * lhs[index]
            rn += rhs[index] * rhs[index]
        }
        guard ln > 0, rn > 0 else { return -1 }
        return Double(dot / (sqrt(ln) * sqrt(rn)))
    }

    static func centroid(of vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        guard vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            for index in vector.indices { sum[index] += vector[index] }
        }
        return normalize(sum)
    }

    static func medianValue(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// 单簇内最常见的嵌入维度（只统计有观测、向量非空的行）。
    private static func dominantDimension(_ members: [FaceReviewMemberRow]) -> Int? {
        var counts: [Int: Int] = [:]
        for member in members where member.observationId != nil && !member.embedding.isEmpty {
            counts[member.embedding.count, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    private static func modelMatches(_ member: FaceReviewMemberRow, mode: (String, String)?) -> Bool {
        guard let mode else { return true }
        return member.modelId == mode.0 && member.modelVersion == mode.1
    }

    private static func modelMode(
        _ members: [FaceReviewMemberRow], minQuality: Double
    ) -> (String, String)? {
        var counts: [String: Int] = [:]
        var firstMember: [String: Int64] = [:]
        for member in members {
            // 未解析观测的空 modelId 不能参与众数；否则未解析占多数时，
            // 有效成员会被误判 incompatibleModel 并全部退出 eligible。
            guard member.observationId != nil,
                  !member.embedding.isEmpty,
                  !member.modelId.isEmpty,
                  member.quality >= minQuality
            else { continue }
            let key = member.modelId + "|" + member.modelVersion
            counts[key, default: 0] += 1
            firstMember[key] = min(firstMember[key] ?? Int64.max, member.memberId)
        }
        return counts.keys.sorted { lhs, rhs in
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            if lc != rc { return lc > rc }
            return (firstMember[lhs] ?? 0) < (firstMember[rhs] ?? 0)
        }.first.flatMap { key in
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }
}
