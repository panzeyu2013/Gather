// desktop/native/gather-core/Sources/GatherPersistence/Ports/DuplicateRepository.swift
// WP3b-3：Duplicate 域端口（扫描读 / 分组重建写 / photos.status 三写者 / 组与成员读取）。
//
// DuplicateService 此前持裸 DBConnection 执行 25 条 prepare + 4 个事务。这里把 SQL
// 全部下沉到 DuplicateRepo（扫描读写、重建、决策回填、photos.status）与
// DuplicateGroupQuery（getGroups/buildResult 的组/成员读模型）；Application 只保留
// 阶段编排（stat / sha256 / 视觉 hash / 聚类）与业务规则（决策继承、keep_one 打分）。
//
// 事务边界仍由 TransactionRunner 提供（嵌套退化为 SAVEPOINT，语义与旧
// connection.transaction 一致）；similarity_hashes 的读写复用 SimilarityHashRepository。
// 4 处 SELECT *（组两组、成员一组、成员 JOIN photos 一组）的 SQL 文本与列序
// 原样保留（select-star baseline 仍为 Sources 6）。
import Foundation

/// 扫描阶段 photos 投影（checksum 复用判定）。
public struct DuplicateScanPhoto: Equatable, Sendable {
    public let id: String
    public let filepath: String
    public let checksum: String
    public let checksumFileSize: Int64
    public let checksumFileMtimeMs: Double

    public init(
        id: String,
        filepath: String,
        checksum: String,
        checksumFileSize: Int64,
        checksumFileMtimeMs: Double
    ) {
        self.id = id
        self.filepath = filepath
        self.checksum = checksum
        self.checksumFileSize = checksumFileSize
        self.checksumFileMtimeMs = checksumFileMtimeMs
    }
}

/// checksum 回写行（scan 落库）。
public struct DuplicateChecksumWrite: Equatable, Sendable {
    public let photoId: String
    public let checksum: String
    public let fileSize: Int64
    public let fileMtimeMs: Double

    public init(photoId: String, checksum: String, fileSize: Int64, fileMtimeMs: Double) {
        self.photoId = photoId
        self.checksum = checksum
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

/// 精确重复聚合行（checksum + 该 checksum 下的照片 id 序列）。
public struct DuplicateExactGroup: Equatable, Sendable {
    public let checksum: String
    public let photoIds: [String]

    public init(checksum: String, photoIds: [String]) {
        self.checksum = checksum
        self.photoIds = photoIds
    }
}

/// 视觉 hash 行（similarity_hashes JOIN photos，按 photo_id 排序）。
public struct DuplicateVisualHashRow: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String

    public init(photoId: String, hashHex: String) {
        self.photoId = photoId
        self.hashHex = hashHex
    }
}

/// 既有成员决策（稳定身份 = photo_id；重扫时继承）。
public struct DuplicateMemberDecision: Equatable, Sendable {
    public let isKept: Bool
    public let resolution: String?

    public init(isKept: Bool, resolution: String?) {
        self.isKept = isKept
        self.resolution = resolution
    }
}

/// 组插入行（重建事务）。
public struct DuplicateGroupInsert: Equatable, Sendable {
    public let sessionId: String
    public let groupType: String
    public let checksum: String?
    public let hashHex: String?
    public let memberCount: Int
    public let createdAt: String

    public init(
        sessionId: String,
        groupType: String,
        checksum: String?,
        hashHex: String?,
        memberCount: Int,
        createdAt: String
    ) {
        self.sessionId = sessionId
        self.groupType = groupType
        self.checksum = checksum
        self.hashHex = hashHex
        self.memberCount = memberCount
        self.createdAt = createdAt
    }
}

/// 成员插入行（重建事务；groupId 由 insertGroups 返回后回填）。
public struct DuplicateMemberInsert: Equatable, Sendable {
    public let groupId: Int
    public let photoId: String
    public let sessionId: String
    public let isKept: Bool
    public let fileSize: Int64?
    public let fileMtime: String?
    public let resolution: String?

    public init(
        groupId: Int,
        photoId: String,
        sessionId: String,
        isKept: Bool,
        fileSize: Int64?,
        fileMtime: String?,
        resolution: String?
    ) {
        self.groupId = groupId
        self.photoId = photoId
        self.sessionId = sessionId
        self.isKept = isKept
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.resolution = resolution
    }
}

/// duplicate_groups 行（列序 = SELECT * / 表物理列序 0-7）。
public struct DuplicateGroupRow: Equatable, Sendable {
    public let id: Int
    public let sessionId: String
    public let groupType: String
    public let checksum: String?
    public let hashHex: String?
    public let memberCount: Int
    public let resolution: String?
    public let createdAt: String

    public init(row: DBRow) {
        id = Int(row[0].intValue ?? 0)
        sessionId = row[1].textValue ?? ""
        groupType = row[2].textValue ?? ""
        checksum = row[3].textValue
        hashHex = row[4].textValue
        memberCount = Int(row[5].intValue ?? 0)
        resolution = row[6].textValue
        createdAt = row[7].textValue ?? ""
    }
}

/// duplicate_group_members 行（列序 = SELECT * / 表物理列序 0-7）。
public struct DuplicateMemberRow: Equatable, Sendable {
    public let id: Int
    public let groupId: Int
    public let photoId: String
    public let sessionId: String
    public let isKept: Bool
    public let fileSize: Int64?
    public let fileMtime: String?
    public let resolution: String?

    public init(row: DBRow) {
        id = Int(row[0].intValue ?? 0)
        groupId = Int(row[1].intValue ?? 0)
        photoId = row[2].textValue ?? ""
        sessionId = row[3].textValue ?? ""
        isKept = (row[4].intValue ?? 0) != 0
        fileSize = row[5].intValue
        fileMtime = row[6].textValue
        resolution = row[7].textValue
    }
}

/// 成员 + photos 投影（getGroups/buildResult 的成员读取）。
public struct DuplicateGroupMemberDetail: Equatable, Sendable {
    public let member: DuplicateMemberRow
    public let filepath: String
    public let filename: String

    public init(row: DBRow) {
        member = DuplicateMemberRow(row: row)
        filepath = row[8].textValue ?? ""
        filename = row[9].textValue ?? ""
    }
}

/// 成员决策状态（syncGroupResolutions 派生组级 resolution）。
public struct DuplicateMemberState: Equatable, Sendable {
    public let isKept: Bool
    public let resolution: String?

    public init(isKept: Bool, resolution: String?) {
        self.isKept = isKept
        self.resolution = resolution
    }
}

/// 组级 resolution 写行（组成员全部已决时派生）。
public struct DuplicateGroupResolutionWrite: Equatable, Sendable {
    public let groupId: Int
    public let resolution: String

    public init(groupId: Int, resolution: String) {
        self.groupId = groupId
        self.resolution = resolution
    }
}

/// 单成员保留位写行（keep_one 打分结果）。
public struct DuplicateMemberKeptWrite: Equatable, Sendable {
    public let memberId: Int
    public let isKept: Bool

    public init(memberId: Int, isKept: Bool) {
        self.memberId = memberId
        self.isKept = isKept
    }
}

/// 扫描/重建/决策/照片状态写路径。
public protocol DuplicateRepository {
    // 扫描读
    func getScanPhotos(sessionId: String) throws -> [DuplicateScanPhoto]
    func getExactGroups(sessionId: String) throws -> [DuplicateExactGroup]
    func getOrderedVisualHashes(sessionId: String) throws -> [DuplicateVisualHashRow]
    /// TS: PRAGMA group_concat_limit = 0（GROUP_CONCAT 不截断）。
    func enableUnlimitedGroupConcat() throws
    // 扫描写
    func updateChecksums(_ rows: [DuplicateChecksumWrite]) throws
    // 重建事务
    func getMemberDecisions(sessionId: String) throws -> [String: DuplicateMemberDecision]
    func deleteGroupsAndMembers(sessionId: String) throws
    func insertGroups(_ groups: [DuplicateGroupInsert]) throws -> [Int]
    func insertMembers(_ members: [DuplicateMemberInsert]) throws
    func setGroupResolutions(_ rows: [DuplicateGroupResolutionWrite]) throws
    // resolve 命令
    func setMembersKeptAll(_ memberIds: [Int], resolution: String) throws
    func setMemberKept(_ rows: [DuplicateMemberKeptWrite], resolution: String) throws
    func setMemberResolutionIfUnset(memberId: Int, isKept: Bool, resolution: String) throws
    func getMemberPhotoId(memberId: Int) throws -> String?
    // photos.status 三写者
    func markDiscarded(_ photoIds: [String]) throws
    func restoreOrphanedRemoved(_ photoIds: [String]) throws
    func recomputePhotoStatuses(_ photoIds: [String]) throws
}

/// 组/成员读模型（getGroups/buildResult/resolveGroup 的 SELECT）。
public protocol DuplicateGroupReading {
    /// SELECT * FROM duplicate_groups（列序 0-7）WHERE session_id = ? ORDER BY group_type, id
    func getGroups(sessionId: String) throws -> [DuplicateGroupRow]
    /// SELECT * FROM duplicate_groups（列序 0-7）WHERE id IN (...) ORDER BY id
    func getGroups(ids: [Int]) throws -> [DuplicateGroupRow]
    /// SELECT * FROM duplicate_group_members（列序 0-7）WHERE group_id = ?（无 ORDER BY，与旧实现逐字一致）
    func getMembers(groupId: Int) throws -> [DuplicateMemberRow]
    /// 同上，但 JOIN photos 排除已归档成员（resolveGroup 的决策输入）。
    func getVisibleMembers(groupId: Int) throws -> [DuplicateMemberRow]
    /// SELECT dgm.*, p.filepath, p.filename ... ORDER BY dgm.id（列序 0-7 + 8/9）
    func getMembers(groupIds: [Int]) throws -> [Int: [DuplicateGroupMemberDetail]]
    /// SELECT is_kept, resolution ... ORDER BY id（组级 resolution 派生）。
    func getMemberStates(groupId: Int) throws -> [DuplicateMemberState]
    /// 同上，但只返回可见成员（组级 resolution 派生不阻塞在归档件上）。
    func getVisibleMemberStates(groupId: Int) throws -> [DuplicateMemberState]
}

extension DuplicateRepo: DuplicateRepository {}
extension DuplicateGroupQuery: DuplicateGroupReading {}
