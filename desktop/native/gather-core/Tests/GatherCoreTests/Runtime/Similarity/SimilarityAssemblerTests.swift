// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Similarity/SimilarityAssemblerTests.swift
// W2c 步骤 2：SimilarityAssembler 纯函数测试（无数据库：最小输入 + 直接断言）。
//
// 语义对照旧 Services/SimilarityServiceTests.swift（W2c 完成后随之删除）的
// getResult 装配 3 用例：
// - assemblesGroupsFromMembers（成员表权威、垃圾 groups_json 不被解析、资产折叠）
// - legacyGroupsJsonPath（无成员旧行逐字解析 groups_json）
// - resolvesThresholdTiers（主档 / 预计算档 stats 的 threshold + precomputed 标记）
// 加上旧 buildStoredResult 的落库载荷断言（JSON 语义解析，不依赖键序）与
// 搬移后补充的边界守护（紧凑占位、快照外 photoId、稀疏组序号、畸形 JSON 抛错）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 最小夹具（不触碰数据库）

private func projection(
    _ id: String,
    filepath: String? = nil,
    filename: String? = nil,
    assetId: String? = nil,
    assetFileId: String? = nil
) -> PhotoProjection {
    let path = filepath ?? "/shoot/\(id).jpg"
    return PhotoProjection(
        id: id, sessionId: "session", filepath: path,
        filename: filename ?? (path as NSString).lastPathComponent,
        checksum: "checksum-\(id)", checksumFileSize: 0, checksumFileMtimeMs: 0,
        status: "pending", assetId: assetId, assetFileId: assetFileId,
        width: 100, height: 100,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func member(_ groupIndex: Int, _ photoId: String, _ filepath: String) -> SimilarityMember {
    SimilarityMember(groupIndex: groupIndex, photoId: photoId, filepath: filepath)
}

private struct GroupsPayload: Decodable {
    let groups: [SimilarityGroup]
    let ungrouped: [SimilarityImage]?
}

private struct StatsPayload: Decodable {
    let totalGroups: Int?
    let totalUngrouped: Int?
    let threshold: Double?
    let minGroupSize: Int?
    let groupingMode: SimilarityGroupingMode?
    let precomputed: Bool?
}

private func decodeGroups(_ json: String) throws -> GroupsPayload {
    try JSONDecoder().decode(GroupsPayload.self, from: Data(json.utf8))
}

private func decodeStats(_ json: String) throws -> StatsPayload {
    try JSONDecoder().decode(StatsPayload.self, from: Data(json.utf8))
}

@Suite("SimilarityAssembler")
struct SimilarityAssemblerTests {

    // MARK: buildStoredResult → build

    @Test("build mirrors buildStoredResult: group ids, representatives, payloads, memberships")
    func buildMirrorsBuildStoredResult() throws {
        let built = try SimilarityAssembler.build(
            rawGroups: [["p1", "p2"], ["p3"]],
            rawUngrouped: ["u1"],
            pathMap: [
                "p1": "/shoot/p1.jpg", "p2": "/shoot/p2.jpg",
                "p3": "/shoot/p3.jpg", "u1": "/shoot/u1.jpg",
            ],
            threshold: 10, minGroupSize: 2, groupingMode: .global, precomputed: false
        )

        #expect(built.result.groups == [
            SimilarityGroup(id: 1, label: "Group 1", count: 2, images: [
                SimilarityImage(path: "/shoot/p1.jpg", representative: true),
                SimilarityImage(path: "/shoot/p2.jpg", representative: false),
            ]),
            SimilarityGroup(id: 2, label: "Group 2", count: 1, images: [
                SimilarityImage(path: "/shoot/p3.jpg", representative: true),
            ]),
        ])
        #expect(built.result.ungrouped == [SimilarityImage(path: "/shoot/u1.jpg")])
        #expect(built.result.stats.totalGroups == 2)
        #expect(built.result.stats.totalUngrouped == 1)
        #expect(built.result.stats.threshold == 10)
        #expect(built.result.stats.minGroupSize == 2)
        #expect(built.result.stats.groupingMode == .global)
        #expect(built.memberships == [
            SimilarityMembership(photoId: "p1", groupIndex: 0),
            SimilarityMembership(photoId: "p2", groupIndex: 0),
            SimilarityMembership(photoId: "p3", groupIndex: 1),
        ])

        // 落库载荷按 JSON 语义解析（键序无关）。
        let groupsPayload = try decodeGroups(built.groupsJson)
        #expect(groupsPayload.groups == built.result.groups)
        #expect(groupsPayload.ungrouped == built.result.ungrouped)
        let statsPayload = try decodeStats(built.statsJson)
        #expect(statsPayload.totalGroups == 2)
        #expect(statsPayload.totalUngrouped == 1)
        #expect(statsPayload.threshold == 10)
        #expect(statsPayload.minGroupSize == 2)
        #expect(statsPayload.groupingMode == .global)
        #expect(statsPayload.precomputed == nil)
        #expect(try SimilarityAssembler.parseStats(built.statsJson).precomputed == false)
    }

    @Test("build writes the compact groups_json placeholder for precomputed tiers")
    func buildCompactGroupsJsonForPrecomputedTiers() throws {
        let built = try SimilarityAssembler.build(
            rawGroups: [["p1"]], rawUngrouped: [],
            pathMap: ["p1": "/shoot/p1.jpg"],
            threshold: 6, minGroupSize: 2, groupingMode: .global,
            precomputed: true, compactGroupsJson: true
        )

        #expect(built.groupsJson == #"{"groups":[],"ungrouped":[]}"#)
        let stats = try SimilarityAssembler.parseStats(built.statsJson)
        #expect(stats.threshold == 6)
        #expect(stats.precomputed == true)
        // 结果对象仍携带真实分组（供调用方直接返回），仅落库载荷紧凑。
        #expect(built.result.groups.map(\.id) == [1])
    }

    @Test("build degrades a photoId outside the snapshot to an empty path")
    func buildUsesEmptyPathForUnknownPhotoId() throws {
        // 设计 §5 待裁决项 2 的现状语义（旧实现 pathMap[photoId] ?? ""）；
        // 若裁决改抛错，只改 build 的一处解析。
        let built = try SimilarityAssembler.build(
            rawGroups: [["ghost"]], rawUngrouped: ["ghost2"],
            pathMap: [:], threshold: 10, minGroupSize: 2,
            groupingMode: .global, precomputed: false
        )
        #expect(built.result.groups[0].images.map(\.path) == [""])
        #expect(built.result.ungrouped.map(\.path) == [""])
    }

    // MARK: getResult 装配（旧 assemblesGroupsFromMembers / legacyGroupsJsonPath）

    @Test("groups(fromMembers:) mirrors the member-table assembly")
    func groupsFromMembersMirrorsGetResult() {
        let groups = SimilarityAssembler.groups(fromMembers: [
            member(0, "p1", "/shoot/p1.jpg"),
            member(0, "a.raw", "/shoot/a.RAW"),
            member(1, "s", "/shoot/s.jpg"),
        ])

        #expect(groups == [
            SimilarityGroup(id: 1, label: "Group 1", count: 2, images: [
                SimilarityImage(path: "/shoot/p1.jpg", representative: true),
                SimilarityImage(path: "/shoot/a.RAW", representative: false),
            ]),
            SimilarityGroup(id: 2, label: "Group 2", count: 1, images: [
                SimilarityImage(path: "/shoot/s.jpg", representative: true),
            ]),
        ])
    }

    @Test("groups(fromMembers:) keeps first-seen order for sparse indexes and handles empty")
    func groupsFromMembersSparseIndexes() {
        let groups = SimilarityAssembler.groups(fromMembers: [
            member(5, "x", "/shoot/x.jpg"),
            member(5, "y", "/shoot/y.jpg"),
            member(2, "z", "/shoot/z.jpg"),
        ])
        #expect(groups.map(\.id) == [6, 3])
        #expect(groups.map(\.count) == [2, 1])
        #expect(groups[1].label == "Group 3")
        #expect(SimilarityAssembler.groups(fromMembers: []).isEmpty)
    }

    @Test("assembleResult assembles groups from the members table without parsing groups_json")
    func assembleResultUsesMembersTableAndCollapsesAssets() throws {
        // 垃圾 groups_json 证明成员表路径从不解析 groups_json（旧用例逐字保留）。
        let result = try SimilarityAssembler.assembleResult(
            statsJson: #"{"totalGroups":2,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            groupsJson: "NOT VALID JSON",
            members: [
                member(0, "p1", "/shoot/p1.jpg"),
                member(0, "a.raw", "/shoot/a.RAW"),
                member(1, "s", "/shoot/s.jpg"),
            ],
            photos: [
                projection("p1", filepath: "/shoot/p1.jpg"),
                projection("a.raw", filepath: "/shoot/a.RAW", filename: "a.RAW", assetId: "asset-a"),
                projection("a.jpg", filepath: "/shoot/a.jpg", filename: "a.jpg", assetId: "asset-a"),
                projection("s", filepath: "/shoot/s.jpg"),
                projection("c.raw", filepath: "/shoot/c.RAW", filename: "c.RAW", assetId: "asset-c"),
                projection("c.jpg", filepath: "/shoot/c.jpg", filename: "c.jpg", assetId: "asset-c"),
            ]
        )

        #expect(result.groups.map(\.id) == [1, 2])
        #expect(result.groups[0].images.map(\.path) == ["/shoot/p1.jpg", "/shoot/a.RAW"])
        #expect(result.groups[1].images.map(\.path) == ["/shoot/s.jpg"])
        // Ungrouped 镜像 analyze：折叠资产（RAW 优先）减成员表，asset-c 的 JPEG
        // 变体被排除。
        #expect(result.ungrouped == [SimilarityImage(path: "/shoot/c.RAW")])
        #expect(result.stats.totalGroups == 2)
        #expect(result.stats.totalUngrouped == 1)
        #expect(result.stats.threshold == 10)
        #expect(result.stats.minGroupSize == 2)
        #expect(result.stats.groupingMode == .global)
        #expect(result.stats.precomputed == false)
    }

    @Test("assembleResult keeps the legacy groups_json path for rows without members")
    func assembleResultFallsBackToLegacyGroupsJson() throws {
        let result = try SimilarityAssembler.assembleResult(
            statsJson: #"{"totalGroups":1,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"sequential"}"#,
            groupsJson: #"""
            {"groups":[{"id":1,"label":"Group 1","count":2,"images":[
              {"path":"/shoot/p1.jpg","representative":true},
              {"path":"/shoot/legacy.jpg","representative":false}]}],
             "ungrouped":[{"path":"/shoot/alone.jpg"}]}
            """#,
            members: nil,
            photos: []
        )

        #expect(result.groups[0].images == [
            SimilarityImage(path: "/shoot/p1.jpg", representative: true),
            SimilarityImage(path: "/shoot/legacy.jpg", representative: false),
        ])
        #expect(result.ungrouped == [SimilarityImage(path: "/shoot/alone.jpg")])
        #expect(result.stats.groupingMode == .sequential)
        #expect(result.stats.precomputed == false)
    }

    @Test("legacy groups_json without ungrouped decodes to an empty list")
    func legacyGroupsJsonWithoutUngrouped() throws {
        let result = try SimilarityAssembler.assembleResult(
            statsJson: "{}",
            groupsJson: #"{"groups":[{"id":1,"label":"Group 1","count":1,"images":[{"path":"/shoot/p1.jpg","representative":true}]}]}"#,
            members: nil,
            photos: []
        )
        #expect(result.ungrouped.isEmpty)
        #expect(result.groups.count == 1)
    }

    @Test("assembleResult resolves threshold tiers without regressing the default row")
    func assembleResultResolvesThresholdTiers() throws {
        let photos = [
            projection("p1", filepath: "/shoot/p1.jpg"),
            projection("p2", filepath: "/shoot/p2.jpg"),
        ]
        let main = try SimilarityAssembler.assembleResult(
            statsJson: #"{"totalGroups":1,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"global"}"#,
            groupsJson: #"{"groups":[]}"#,
            members: [member(0, "p1", "/shoot/p1.jpg")],
            photos: photos
        )
        #expect(main.stats.threshold == 10)
        #expect(main.stats.precomputed == false)
        #expect(main.groups[0].images.map(\.path) == ["/shoot/p1.jpg"])

        let tier = try SimilarityAssembler.assembleResult(
            statsJson: #"{"totalGroups":1,"totalUngrouped":1,"threshold":6,"minGroupSize":2,"groupingMode":"global","precomputed":true}"#,
            groupsJson: #"{"groups":[]}"#,
            members: [member(0, "p2", "/shoot/p2.jpg")],
            photos: photos
        )
        #expect(tier.stats.threshold == 6)
        #expect(tier.stats.precomputed == true)
        #expect(tier.groups[0].images.map(\.path) == ["/shoot/p2.jpg"])
    }

    // MARK: 载荷解析边界

    @Test("parseStats applies TS partial defaults")
    func parseStatsDefaults() throws {
        let empty = try SimilarityAssembler.parseStats("{}")
        #expect(empty.totalGroups == 0)
        #expect(empty.totalUngrouped == 0)
        #expect(empty.threshold == 0)
        #expect(empty.minGroupSize == 2)
        #expect(empty.groupingMode == .global)
        #expect(empty.precomputed == false)

        let markerOnly = try SimilarityAssembler.parseStats(#"{"precomputed":true}"#)
        #expect(markerOnly.totalGroups == 0)
        #expect(markerOnly.precomputed == true)

        let explicitFalse = try SimilarityAssembler.parseStats(#"{"precomputed":false,"threshold":4}"#)
        #expect(explicitFalse.precomputed == false)
        #expect(explicitFalse.threshold == 4)
    }

    @Test("parseStats throws on corrupt stored stats like TS JSON.parse")
    func parseStatsThrowsOnCorruptJson() {
        #expect(throws: (any Error).self) {
            try SimilarityAssembler.parseStats("NOT VALID JSON")
        }
    }

    @Test("decodeLegacyGroups throws on corrupt groups_json like TS JSON.parse")
    func decodeLegacyGroupsThrowsOnCorruptJson() {
        let stats = SimilarityResultStats(
            totalGroups: 0, totalUngrouped: 0, threshold: 0,
            minGroupSize: 2, groupingMode: .global
        )
        #expect(throws: (any Error).self) {
            try SimilarityAssembler.decodeLegacyGroups("NOT VALID JSON", stats: stats)
        }
        // groups 键缺失同样抛错（载荷必需）。
        #expect(throws: (any Error).self) {
            try SimilarityAssembler.decodeLegacyGroups("{}", stats: stats)
        }
    }

    @Test("assembleResult parses stats before choosing the members path")
    func assembleResultThrowsOnCorruptStatsFirst() {
        // 旧 getResult 先 parseStoredStats 再查成员表：畸形 stats 即使成员表存在也抛错。
        #expect(throws: (any Error).self) {
            try SimilarityAssembler.assembleResult(
                statsJson: "NOT VALID JSON",
                groupsJson: #"{"groups":[]}"#,
                members: [member(0, "p1", "/shoot/p1.jpg")],
                photos: []
            )
        }
    }
}
