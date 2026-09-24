// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Duplicate/DuplicateAssemblerTests.swift
// W2c：DuplicateAssembler 纯函数测试（无数据库：行值类型 + 直接断言）。
//
// 语义对照旧 Services/DuplicateServiceTests.swift:541-615 的 resolve 用例
// （keep_one 评分/同分/mtime 决出）与旧 makeGroup/buildResult 的装配行为。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 夹具（不触碰数据库）

private func makeGroupRecord(
    id: Int,
    groupType: String = "exact",
    checksum: String? = nil,
    hashHex: String? = nil,
    memberCount: Int,
    resolution: String? = nil,
    createdAt: String = "2026-01-01T00:00:00.000Z"
) -> DuplicateGroupRecord {
    DuplicateGroupRecord(
        id: id,
        sessionId: "session",
        groupType: groupType,
        checksum: checksum,
        hashHex: hashHex,
        memberCount: memberCount,
        resolution: resolution,
        createdAt: createdAt
    )
}

private func makeMember(
    id: Int,
    groupId: Int,
    photoId: String,
    isKept: Bool = true,
    fileSize: Int64? = nil,
    fileMtime: String? = nil,
    resolution: String? = nil,
    filepath: String? = nil,
    filename: String? = nil
) -> DuplicateAssembler.MemberRow {
    DuplicateAssembler.MemberRow(
        id: id,
        groupId: groupId,
        photoId: photoId,
        isKept: isKept,
        fileSize: fileSize,
        fileMtime: fileMtime,
        resolution: resolution,
        filepath: filepath ?? "/photos/\(photoId).jpg",
        filename: filename ?? "\(photoId).jpg"
    )
}

@Suite("DuplicateAssembler 纯函数（W2c）")
struct DuplicateAssemblerTests {
    // MARK: 组装配

    @Test("exact/visual 组装配：类型/校验和/hash/成员字段逐字映射")
    func assemblesExactAndVisualGroups() {
        let records = [
            makeGroupRecord(id: 3, groupType: "exact", checksum: "sum-1", memberCount: 2),
            makeGroupRecord(id: 7, groupType: "visual", hashHex: "hash-1", memberCount: 2, resolution: "keep_one"),
        ]
        let members: [Int: [DuplicateAssembler.MemberRow]] = [
            3: [
                makeMember(id: 1, groupId: 3, photoId: "a", fileSize: 100, fileMtime: "2026-01-01T00:00:00.000Z"),
                makeMember(id: 2, groupId: 3, photoId: "b", isKept: false, fileSize: 200,
                           fileMtime: "2026-01-02T00:00:00.000Z", resolution: "keep_one"),
            ],
            7: [
                makeMember(id: 5, groupId: 7, photoId: "c", filepath: "/vault/c.png", filename: "c.png"),
                makeMember(id: 6, groupId: 7, photoId: "d"),
            ],
        ]

        let groups = DuplicateAssembler.groups(records: records, members: members)

        #expect(groups.count == 2)
        #expect(groups.map(\.id) == [3, 7])
        #expect(groups.map(\.groupType) == [.exact, .visual])
        #expect(groups[0].checksum == "sum-1")
        #expect(groups[0].hashHex == nil)
        #expect(groups[1].checksum == nil)
        #expect(groups[1].hashHex == "hash-1")
        #expect(groups[1].resolution == "keep_one")

        let first = groups[0].members
        #expect(first.map(\.id) == [1, 2])
        #expect(first.map(\.photoId) == ["a", "b"])
        #expect(first.map(\.isKept) == [true, false])
        #expect(first.map(\.fileSize) == [100, 200])
        #expect(first.map(\.fileMtime) == ["2026-01-01T00:00:00.000Z", "2026-01-02T00:00:00.000Z"])
        #expect(first.map(\.resolution) == [nil, "keep_one"])
        #expect(first.map(\.filepath) == ["/photos/a.jpg", "/photos/b.jpg"])
        #expect(first.map(\.filename) == ["a.jpg", "b.jpg"])
        #expect(groups[1].members.map(\.filepath) == ["/vault/c.png", "/photos/d.jpg"])
    }

    @Test("memberCount 取组行而非成员数组长度（旧 makeGroup 语义）")
    func memberCountComesFromRecord() {
        let record = makeGroupRecord(id: 1, memberCount: 42)
        let group = DuplicateAssembler.group(
            record: record,
            members: [makeMember(id: 1, groupId: 1, photoId: "a")]
        )
        #expect(group.memberCount == 42)
        #expect(group.members.count == 1)
    }

    @Test("缺失成员 map 条目 → 空成员数组（组仍保留）")
    func missingMembersMapToEmptyArray() {
        let record = makeGroupRecord(id: 9, groupType: "visual", hashHex: "h", memberCount: 2)
        let group = DuplicateAssembler.group(record: record, members: [])
        #expect(group.members.isEmpty)
        #expect(group.memberCount == 2)
    }

    @Test("groupType 非 exact 一律 .visual（旧实现三元表达式）")
    func nonExactGroupTypeIsVisual() {
        for raw in ["visual", "", "EXACT", "weird"] {
            let record = makeGroupRecord(id: 1, groupType: raw, memberCount: 1)
            let group = DuplicateAssembler.group(record: record, members: [])
            #expect(group.groupType == .visual)
        }
    }

    @Test("MemberRow 桥接 Store 成员行：fileSize 缺省保持 nil")
    func memberRowBridgesStoreRecord() {
        let record = DuplicateGroupMemberRecord(
            id: 11, groupId: 4, photoId: "p", sessionId: "session",
            isKept: false, fileSize: nil, fileMtime: nil, resolution: "keep_one"
        )
        let row = DuplicateAssembler.MemberRow(record, filepath: "/vault/p.dng", filename: "p.dng")
        #expect(row.id == 11)
        #expect(row.groupId == 4)
        #expect(row.photoId == "p")
        #expect(row.isKept == false)
        #expect(row.fileSize == nil)
        #expect(row.fileMtime == nil)
        #expect(row.resolution == "keep_one")
        #expect(row.filepath == "/vault/p.dng")
        #expect(row.filename == "p.dng")
    }

    @Test("scanResult：totalDuplicates = Σ memberCount，exact/visual 保序")
    func scanResultTotalsMemberCounts() {
        let exact = [
            DuplicateAssembler.group(record: makeGroupRecord(id: 1, checksum: "a", memberCount: 2), members: []),
            DuplicateAssembler.group(record: makeGroupRecord(id: 2, checksum: "b", memberCount: 3), members: []),
        ]
        let visual = [
            DuplicateAssembler.group(record: makeGroupRecord(id: 3, groupType: "visual", hashHex: "h", memberCount: 4), members: []),
        ]

        let result = DuplicateAssembler.scanResult(exact: exact, visual: visual)

        #expect(result.exactGroups.map(\.id) == [1, 2])
        #expect(result.visualGroups.map(\.id) == [3])
        #expect(result.totalDuplicates == 9)

        let empty = DuplicateAssembler.scanResult(exact: [], visual: [])
        #expect(empty.totalDuplicates == 0)
    }

    // MARK: keep_one 评分

    @Test("keep_one：size 分量可压过 mtime 分量（旧 resolve 用例逐字对应）")
    func keepOneScoresBySizeThenMtime() {
        let members = [
            makeMember(id: 1, groupId: 1, photoId: "p1", fileSize: 100_000_000,
                       fileMtime: "2024-01-01T00:00:00.000Z"),
            makeMember(id: 2, groupId: 1, photoId: "p2", fileSize: 500,
                       fileMtime: "2025-01-01T00:00:00.000Z"),
        ]
        #expect(
            DuplicateAssembler.keepOneScore(fileSize: 100_000_000, fileMtime: "2024-01-01T00:00:00.000Z")
                > DuplicateAssembler.keepOneScore(fileSize: 500, fileMtime: "2025-01-01T00:00:00.000Z")
        )
        #expect(DuplicateAssembler.keepOneWinner(members: members) == 1)
    }

    @Test("keep_one：同 size 时较新的 mtime 胜出")
    func keepOneUsesMtimeForEqualSize() {
        let members = [
            makeMember(id: 1, groupId: 1, photoId: "a", fileSize: 1000, fileMtime: "2024-01-01T00:00:00.000Z"),
            makeMember(id: 2, groupId: 1, photoId: "b", fileSize: 1000, fileMtime: "2025-01-01T00:00:00.000Z"),
        ]
        #expect(DuplicateAssembler.keepOneWinner(members: members) == 2)
    }

    @Test("keep_one：同分保留先出现者（严格大于才替换）")
    func keepOneTieKeepsFirst() {
        let members = [
            makeMember(id: 1, groupId: 1, photoId: "a", fileSize: 1000, fileMtime: "2025-01-01T00:00:00.000Z"),
            makeMember(id: 2, groupId: 1, photoId: "b", fileSize: 1000, fileMtime: "2025-01-01T00:00:00.000Z"),
        ]
        #expect(DuplicateAssembler.keepOneWinner(members: members) == 1)
    }

    @Test("keep_one：null/空串 mtime 记 0，非法串为 NaN 永不中选")
    func keepOneNullEmptyAndInvalidMtime() {
        #expect(DuplicateAssembler.keepOneScore(fileSize: 10, fileMtime: nil) == 10_000)
        #expect(DuplicateAssembler.keepOneScore(fileSize: 10, fileMtime: "") == 10_000)
        #expect(DuplicateAssembler.keepOneScore(fileSize: nil, fileMtime: nil) == 0)
        #expect(DuplicateAssembler.keepOneScore(fileSize: 10, fileMtime: "not-a-date").isNaN)

        // 非法 mtime 的成员（即便 size 巨大）不中选；全非法时回退首个。
        let mixed = [
            makeMember(id: 1, groupId: 1, photoId: "bad", fileSize: 1_000_000_000_000, fileMtime: "not-a-date"),
            makeMember(id: 2, groupId: 1, photoId: "good", fileSize: 1, fileMtime: "2025-01-01T00:00:00.000Z"),
        ]
        #expect(DuplicateAssembler.keepOneWinner(members: mixed) == 2)

        let allInvalid = [
            makeMember(id: 1, groupId: 1, photoId: "a", fileSize: 10, fileMtime: "nope"),
            makeMember(id: 2, groupId: 1, photoId: "b", fileSize: 20, fileMtime: "nope"),
        ]
        #expect(DuplicateAssembler.keepOneWinner(members: allInvalid) == 1)
    }

    @Test("keep_one：空成员返回 nil；keep_all 全保留")
    func keepOneEmptyAndKeepAll() {
        #expect(DuplicateAssembler.keepOneWinner(members: []) == nil)
        #expect(DuplicateAssembler.keptMemberIds(members: [], resolution: .keepOne).isEmpty)

        let members = [
            makeMember(id: 1, groupId: 1, photoId: "a", fileSize: 10, fileMtime: nil),
            makeMember(id: 2, groupId: 1, photoId: "b", fileSize: 20, fileMtime: nil),
        ]
        #expect(DuplicateAssembler.keptMemberIds(members: members, resolution: .keepAll) == [1, 2])
        #expect(DuplicateAssembler.keptMemberIds(members: members, resolution: .keepOne) == [2])
    }
}
