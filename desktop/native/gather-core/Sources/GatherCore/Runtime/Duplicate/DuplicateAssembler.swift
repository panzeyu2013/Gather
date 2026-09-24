// desktop/native/gather-core/Sources/GatherCore/Runtime/Duplicate/DuplicateAssembler.swift
// W2c：DuplicateRuntime 纯函数层（行 → DTO 装配 + keep_one 评分）。
//
// 来源与边界（Services/DuplicateService.swift 的纯逻辑下沉）：
// - groups(records:members:) / group(record:members:) 对齐 makeGroup（647-659）+
//   getGroups/fetchGroups 的装配路径（460-471 / 605-617）；
// - scanResult(exact:visual:) 对齐 buildResult（581-603）；
// - keepOneWinner(members:)/keepOneScore/keptMemberIds 对齐 resolveGroup 的
//   keep_one 评分（477-525）。
// 本文件无 IO、无 SQL、不调用任何 Store 方法；输入为 Store 行值类型或本文件的
// MemberRow（成员 JOIN photos 的形状）。

import Foundation

public enum DuplicateAssembler {
    /// duplicate_group_members JOIN photos 的成员行形状（Store.membersWithPhoto
    /// 结果；含装配 DuplicateGroupMember 需要的 filepath/filename）。
    public struct MemberRow: Equatable, Sendable {
        public let id: Int
        public let groupId: Int
        public let photoId: String
        public let isKept: Bool
        public let fileSize: Int64?
        public let fileMtime: String?
        public let resolution: String?
        public let filepath: String
        public let filename: String

        public init(
            id: Int,
            groupId: Int,
            photoId: String,
            isKept: Bool,
            fileSize: Int64? = nil,
            fileMtime: String? = nil,
            resolution: String? = nil,
            filepath: String,
            filename: String
        ) {
            self.id = id
            self.groupId = groupId
            self.photoId = photoId
            self.isKept = isKept
            self.fileSize = fileSize
            self.fileMtime = fileMtime
            self.resolution = resolution
            self.filepath = filepath
            self.filename = filename
        }

        /// 从 Store 基础成员行 + photos.filepath/filename 构造。
        public init(_ record: DuplicateGroupMemberRecord, filepath: String, filename: String) {
            self.init(
                id: record.id,
                groupId: record.groupId,
                photoId: record.photoId,
                isKept: record.isKept,
                fileSize: record.fileSize,
                fileMtime: record.fileMtime,
                resolution: record.resolution,
                filepath: filepath,
                filename: filename
            )
        }
    }

    // MARK: - 组装配（旧 makeGroup / getGroups）

    /// 单组装配：groupType == "exact" 之外一律 .visual；memberCount 取组行
    /// （与旧实现一致，不重算）；成员取给定顺序（Store 按 dgm.id 排序）。
    public static func group(
        record: DuplicateGroupRecord,
        members: [MemberRow]
    ) -> DuplicateGroup {
        DuplicateGroup(
            id: record.id,
            groupType: record.groupType == "exact" ? .exact : .visual,
            checksum: record.checksum,
            hashHex: record.hashHex,
            memberCount: record.memberCount,
            members: members.map { member in
                DuplicateGroupMember(
                    id: member.id,
                    photoId: member.photoId,
                    isKept: member.isKept,
                    fileSize: member.fileSize.map(Int.init),
                    fileMtime: member.fileMtime,
                    resolution: member.resolution,
                    filepath: member.filepath,
                    filename: member.filename
                )
            },
            resolution: record.resolution,
            createdAt: record.createdAt
        )
    }

    /// 批量装配：输入顺序即输出顺序（Store 已按 group_type, id / id 排序）。
    public static func groups(
        records: [DuplicateGroupRecord],
        members: [Int: [MemberRow]]
    ) -> [DuplicateGroup] {
        records.map { group(record: $0, members: members[$0.id] ?? []) }
    }

    /// TS: buildResult —— exact + visual 分组汇总 totalDuplicates（按 memberCount）。
    public static func scanResult(
        exact: [DuplicateGroup],
        visual: [DuplicateGroup]
    ) -> DuplicateScanResult {
        let totalDuplicates =
            exact.reduce(0) { $0 + $1.memberCount }
            + visual.reduce(0) { $0 + $1.memberCount }
        return DuplicateScanResult(
            exactGroups: exact,
            visualGroups: visual,
            totalDuplicates: totalDuplicates
        )
    }

    // MARK: - keep_one 评分（旧 resolveGroup 477-525）

    /// score = file_size * 1000 + mtimeMs。
    /// TS: new Date(m.file_mtime || 0).getTime() —— null/空串 → 0，
    /// 非空非法串 → NaN（永不中选）；file_size null → 0。
    public static func keepOneScore(fileSize: Int64?, fileMtime: String?) -> Double {
        let mtimeMs: Double
        if let fileMtime, !fileMtime.isEmpty {
            mtimeMs = tsDateParse(fileMtime) ?? .nan
        } else {
            mtimeMs = 0
        }
        return Double(fileSize ?? 0) * 1000 + mtimeMs
    }

    /// keep_one 胜者成员 id：分数最高者；空成员返回 nil；同分保留先出现者
    /// （旧实现 bestScore 从 -1 起、严格大于才替换）。NaN 分数永不中选。
    public static func keepOneWinner(members: [MemberRow]) -> Int? {
        guard let first = members.first else { return nil }
        var bestId = first.id
        var bestScore: Double = -1
        for member in members {
            let score = keepOneScore(fileSize: member.fileSize, fileMtime: member.fileMtime)
            if score > bestScore {
                bestScore = score
                bestId = member.id
            }
        }
        return bestId
    }

    /// 决议 → 保留成员 id 集合（keep_all 全保留；keep_one 仅胜者）。
    public static func keptMemberIds(
        members: [MemberRow],
        resolution: DupResolution
    ) -> Set<Int> {
        switch resolution {
        case .keepAll:
            return Set(members.map(\.id))
        case .keepOne:
            return keepOneWinner(members: members).map { [$0] } ?? []
        }
    }
}
