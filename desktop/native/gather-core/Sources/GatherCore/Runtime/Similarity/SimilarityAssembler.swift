// desktop/native/gather-core/Sources/GatherCore/Runtime/Similarity/SimilarityAssembler.swift
// W2c 步骤 2：Similarity 结果装配（纯函数）。
//
// 来源：Services/SimilarityService.swift 的
// - buildStoredResult（782-847 行）→ build
// - getResult 的成员表装配（536-566 行）→ groups(fromMembers:) / ungrouped /
//   assembleResult
// - parseStoredStats（901-916 行）→ parseStats
// - getResult 的旧行 groups_json 解析（524-534 行）→ decodeLegacyGroups
//
// 语义注记（设计 §1.1 语义修正 ⑥ / ⑦，本文件落实）：
// - encode 失败改抛错：groups_json / stats_json 的 JSONEncoder().encode 不再
//   try? 吞错（旧实现失败时静默落 "{}"），失败即抛 EncodingError。
// - getResult 一致装配：成员表路径组序 = 成员 rowid 序（首成员为代表），
//   ungrouped = 逻辑资产折叠（RAW 优先）减成员表，顺序跟随投影导入序；旧行
//   （无成员表）才解析 groups_json，与旧实现逐字一致。
// - 快照外 photoId：pathMap 缺失退化为空串（设计 §5 待裁决项 2 的现状语义；
//   裁决后若改抛错，只需改 build 的 path 解析一处）。
//
// 边界：无 IO、无 SQL、无 Store 依赖。仅依赖纯折叠助手 PhotoAssets.collapse
// （Runtime/Support/PhotoAssets.swift，同为无状态纯函数）与 Protocol 层 DTO。

import Foundation

/// TS: buildStoredResult 的返回值（结果 + 落库载荷 + 成员映射）。
public struct SimilarityBuiltResult: Equatable, Sendable {
    public let result: SimilarityResult
    public let groupsJson: String
    public let statsJson: String
    public let memberships: [SimilarityMembership]

    public init(
        result: SimilarityResult,
        groupsJson: String,
        statsJson: String,
        memberships: [SimilarityMembership]
    ) {
        self.result = result
        self.groupsJson = groupsJson
        self.statsJson = statsJson
        self.memberships = memberships
    }
}

/// TS: similarity.service.ts 的纯装配面（Store 读取与编排在 Runtime actor）。
public enum SimilarityAssembler {
    /// 预计算邻域档的紧凑 groups_json 占位（schema 要求非空串）。预计算档永不读
    /// groups_json：getLatest 排除之、culling 从成员表解析、getResult 也从成员表
    /// 重建；逐档 stringify 多 MB payload 纯属浪费。文案与旧 buildStoredResult
    /// 的 compactGroupsJson 分支逐字一致。
    public static let compactGroupsJSON = #"{"groups":[],"ungrouped":[]}"#

    // MARK: - buildStoredResult

    /// TS: buildStoredResult —— 原始分组（photoId 二维数组）→ DTO + 落库载荷。
    /// 组 id/label 按 1 起序号；组内首成员为代表；成员映射按组序扁平化。
    public static func build(
        rawGroups: [[String]],
        rawUngrouped: [String],
        pathMap: [String: String],
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        precomputed: Bool,
        compactGroupsJson: Bool = false
    ) throws -> SimilarityBuiltResult {
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

        let groupsJson: String
        if compactGroupsJson {
            groupsJson = compactGroupsJSON
        } else {
            let data = try JSONEncoder().encode(
                StoredGroupsPayload(groups: groups, ungrouped: ungrouped)
            )
            groupsJson = String(decoding: data, as: UTF8.self)
        }
        let statsPayload = StoredStatsPayload(
            totalGroups: groups.count,
            totalUngrouped: ungrouped.count,
            threshold: Double(threshold),
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            precomputed: precomputed ? true : nil
        )
        let statsJson = String(decoding: try JSONEncoder().encode(statsPayload), as: UTF8.self)

        let result = SimilarityResult(
            groups: groups,
            ungrouped: ungrouped,
            stats: SimilarityResultStats(
                totalGroups: groups.count,
                totalUngrouped: ungrouped.count,
                threshold: Double(threshold),
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
        )
        return SimilarityBuiltResult(
            result: result,
            groupsJson: groupsJson,
            statsJson: statsJson,
            memberships: rawGroups.enumerated().flatMap { groupIndex, photoIds in
                photoIds.map { SimilarityMembership(photoId: $0, groupIndex: groupIndex) }
            }
        )
    }

    // MARK: - getResult 装配

    /// TS: getResult 的成员表路径 —— 成员表是组结构的权威来源。成员按 rowid 序
    /// 传入（组内首成员为代表）；组 id = groupIndex + 1，label = "Group N"。
    /// groupIndex 稀疏/非单调时按首次出现序建组（与旧实现逐字一致）。
    public static func groups(fromMembers members: [SimilarityMember]) -> [SimilarityGroup] {
        var groupsByIndex: [Int: Int] = [:]
        var groups: [SimilarityGroup] = []
        for member in members {
            if let position = groupsByIndex[member.groupIndex] {
                groups[position].images.append(SimilarityImage(
                    path: member.filepath,
                    representative: groups[position].images.isEmpty
                ))
                groups[position].count += 1
            } else {
                groupsByIndex[member.groupIndex] = groups.count
                groups.append(SimilarityGroup(
                    id: member.groupIndex + 1,
                    label: "Group \(member.groupIndex + 1)",
                    count: 1,
                    images: [SimilarityImage(path: member.filepath, representative: true)]
                ))
            }
        }
        return groups
    }

    /// TS: getResult 的 ungrouped —— 成员表之外的逻辑资产：先按资产折叠
    /// （RAW 变体优先），再剔除已分组 photoId；顺序跟随投影导入序。
    public static func ungrouped(
        photos: [PhotoProjection],
        memberPhotoIds: Set<String>
    ) -> [SimilarityImage] {
        PhotoAssets.collapse(photos)
            .filter { !memberPhotoIds.contains($0.id) }
            .map { SimilarityImage(path: $0.filepath) }
    }

    /// TS: getResult 的一致装配（stats 先解析，与旧实现顺序一致：畸形 stats 即使
    /// 走成员表路径也抛错）。members == nil（成员表出现前的旧行）才解析
    /// groups_json；成员表存在时绝不触碰 groups_json。
    public static func assembleResult(
        statsJson: String,
        groupsJson: String,
        members: [SimilarityMember]?,
        photos: [PhotoProjection]
    ) throws -> SimilarityResult {
        let stats = try parseStats(statsJson)
        guard let members else {
            return try decodeLegacyGroups(groupsJson, stats: stats)
        }
        return SimilarityResult(
            groups: groups(fromMembers: members),
            ungrouped: ungrouped(photos: photos, memberPhotoIds: Set(members.map(\.photoId))),
            stats: stats
        )
    }

    // MARK: - 载荷解析

    /// TS: getResult 的 stats 解析（Partial + 默认值；畸形 JSON 抛错对齐
    /// TS JSON.parse，不静默降级为全默认）。
    public static func parseStats(_ statsJson: String) throws -> SimilarityResultStats {
        guard let data = statsJson.data(using: .utf8) else {
            throw SimilarityError.noResults
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

    /// TS: getResult 的旧行路径 —— groups_json 逐字解析（ungrouped 缺省为空），
    /// stats 由调用方先解析后透传。畸形 JSON 抛错对齐 TS JSON.parse。
    public static func decodeLegacyGroups(
        _ groupsJson: String,
        stats: SimilarityResultStats
    ) throws -> SimilarityResult {
        guard let data = groupsJson.data(using: .utf8) else {
            throw SimilarityError.noResults
        }
        let stored = try JSONDecoder().decode(StoredGroupsPayload.self, from: data)
        return SimilarityResult(
            groups: stored.groups,
            ungrouped: stored.ungrouped ?? [],
            stats: stats
        )
    }
}

// MARK: - 私有载荷类型

/// TS: groups_json 载荷（编码全必填；解析时 ungrouped 可选）。
private struct StoredGroupsPayload: Codable {
    let groups: [SimilarityGroup]
    let ungrouped: [SimilarityImage]?
}

/// TS: stats_json 载荷（解析用全可选；编码用全必填 + precomputed 可选）。
private struct StoredStatsPayload: Codable {
    let totalGroups: Int?
    let totalUngrouped: Int?
    let threshold: Double?
    let minGroupSize: Int?
    let groupingMode: SimilarityGroupingMode?
    let precomputed: Bool?
}
