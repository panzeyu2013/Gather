// desktop/native/gather-core/Sources/GatherProtocol/API/MaintenanceAPI.swift
// P0 / B0：维护域（第 17 协议，4 个方法）。
// Wave3（task-24）：扩最小迁移入口（目录包导出/导入 + 外部 sidecar 元数据迁移）。
import Foundation

public protocol MaintenanceAPI: Sendable {
    func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord
    func listBackups() async throws -> MaintenanceInventory
    func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt
    func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult

    // MARK: - Wave3（task-24）：目录迁移

    /// 把一个工作区导出为可移植目录包（JSON + manifest；**不打包原图**，只引用相对路径）。
    func exportLibraryPackage(_ input: LibraryExportInput) async throws -> LibraryExportResult
    /// 导入目录包并合并进现有库（photoId / checksum 去重；冲突策略显式）。
    func importLibraryPackage(
        _ input: Confirmed<LibraryImportInput>
    ) async throws -> LibraryImportReport
    /// 从 sidecar/XMP 迁移 rating/label/keywords（不解析 .lrcat/.cos），产出迁移报告。
    func migrateExternalMetadata(
        _ input: Confirmed<ExternalMigrationInput>
    ) async throws -> ExternalMigrationReport
}
// MARK: - Wave3（task-24）：目录包 DTO
//
// 为什么 DTO 放在本文件：任务只授权维护域的协议文件（不新增 Protocol 文件），
// 而包格式是维护域契约的一部分（导出/导入共用同一份类型，避免两处漂移）。

/// 导出请求（只读；不写照片、不写 XMP）。
public struct LibraryExportInput: Codable, Equatable, Sendable {
    public var sessionId: String
    /// 目标目录或 `.gatherlib.json` 文件路径；目录时用「<工作区名>.gatherlib.json」。
    public var destinationPath: String
    /// 已淘汰移出工作区（archived_at 非空）的照片默认不进包。
    public var includeArchived: Bool

    public init(sessionId: String, destinationPath: String, includeArchived: Bool = false) {
        self.sessionId = sessionId
        self.destinationPath = destinationPath
        self.includeArchived = includeArchived
    }
}

public struct LibraryExportResult: Codable, Equatable, Sendable {
    public var packagePath: String
    public var photoCount: Int
    public var collectionCount: Int
    public var skippedArchivedCount: Int

    public init(
        packagePath: String,
        photoCount: Int,
        collectionCount: Int,
        skippedArchivedCount: Int = 0
    ) {
        self.packagePath = packagePath
        self.photoCount = photoCount
        self.collectionCount = collectionCount
        self.skippedArchivedCount = skippedArchivedCount
    }
}

/// 导入时对「库里已经有同一张照片」的处置口径。
///
/// - keepLocal：保留本地（导入包里的这条被丢弃）；
/// - keepImported：保留导入（用包里的路径/评分/关键词覆盖同一 photoId 的本地记录）；
/// - coexist：并存（新增一条照片行，评分/关键词各归各的）。
public enum LibraryConflictPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case keepLocal = "keep_local"
    case keepImported = "keep_imported"
    case coexist
}

/// 导入请求（破坏性：写库；调用点必须经 Confirmed 收口）。
public struct LibraryImportInput: Codable, Equatable, Sendable {
    public var packagePath: String
    /// 包内相对路径的新根（迁移到新磁盘/新目录时用；空串 = 用包内记录的原路径）。
    public var newRoot: String
    /// 新工作区名；空串 = 用包内工作区名（重名时自动加后缀）。
    public var sessionName: String
    public var conflictPolicy: LibraryConflictPolicy
    public var importRatings: Bool
    public var importKeywords: Bool

    public init(
        packagePath: String,
        newRoot: String,
        sessionName: String = "",
        conflictPolicy: LibraryConflictPolicy = .keepLocal,
        importRatings: Bool = true,
        importKeywords: Bool = true
    ) {
        self.packagePath = packagePath
        self.newRoot = newRoot
        self.sessionName = sessionName
        self.conflictPolicy = conflictPolicy
        self.importRatings = importRatings
        self.importKeywords = importKeywords
    }
}

public struct LibraryImportReport: Codable, Equatable, Sendable {
    public var sessionId: String
    public var importedPhotos: Int
    public var importedRatings: Int
    public var importedKeywords: Int
    public var importedCollections: Int
    public var dedupedByPhotoID: Int
    public var dedupedByChecksum: Int
    public var conflictsKeptLocal: Int
    public var conflictsKeptImported: Int
    public var coexisted: Int
    /// 重绑定后找不到源文件的照片（仍登记，等待重新索引/离线态）。
    public var missingFiles: [String]
    /// 包内集合 id → 新库集合 id。
    public var collectionIDMap: [String: String]
    /// 导入后处于 pending、等待下一次索引扫描的照片数（= missingFiles 中实际登记的行数）。
    public var pendingCount: Int

    public init(
        sessionId: String,
        importedPhotos: Int = 0,
        importedRatings: Int = 0,
        importedKeywords: Int = 0,
        importedCollections: Int = 0,
        dedupedByPhotoID: Int = 0,
        dedupedByChecksum: Int = 0,
        conflictsKeptLocal: Int = 0,
        conflictsKeptImported: Int = 0,
        coexisted: Int = 0,
        missingFiles: [String] = [],
        collectionIDMap: [String: String] = [:],
        pendingCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.importedPhotos = importedPhotos
        self.importedRatings = importedRatings
        self.importedKeywords = importedKeywords
        self.importedCollections = importedCollections
        self.dedupedByPhotoID = dedupedByPhotoID
        self.dedupedByChecksum = dedupedByChecksum
        self.conflictsKeptLocal = conflictsKeptLocal
        self.conflictsKeptImported = conflictsKeptImported
        self.coexisted = coexisted
        self.missingFiles = missingFiles
        self.collectionIDMap = collectionIDMap
        self.pendingCount = pendingCount
    }
}

/// 外部软件迁移请求：扫描某工作区已登记照片旁边的 sidecar/XMP。
public struct ExternalMigrationInput: Codable, Equatable, Sendable {
    public var sessionId: String
    /// false（默认）= XMP 只在本地为空时补写；true = 用 XMP 覆盖本地已有值。
    public var overwriteExisting: Bool

    public init(sessionId: String, overwriteExisting: Bool = false) {
        self.sessionId = sessionId
        self.overwriteExisting = overwriteExisting
    }
}

public struct ExternalMigrationReport: Codable, Equatable, Sendable {
    public var scanned: Int
    public var sidecarsFound: Int
    public var applied: Int
    /// 本地已有值与 XMP 不一致且未覆盖的张数（判定为"冲突，保留本地"）。
    public var conflicts: Int
    public var missingRating: Int
    public var missingLabel: Int
    public var missingKeywords: Int
    /// 读取失败的路径（sidecar 损坏 / 权限）。
    public var failed: [String]
    /// D2：XMP rating 越界（如 Lightroom 的 -1 / 6）被跳过的张数。
    /// 旧 JSON 没有该键 → 解码为 0（见 init(from:)）。
    public var skippedInvalidRating: Int

    private enum CodingKeys: String, CodingKey {
        case scanned, sidecarsFound, applied, conflicts
        case missingRating, missingLabel, missingKeywords, failed
        case skippedInvalidRating
    }

    public init(
        scanned: Int = 0,
        sidecarsFound: Int = 0,
        applied: Int = 0,
        conflicts: Int = 0,
        missingRating: Int = 0,
        missingLabel: Int = 0,
        missingKeywords: Int = 0,
        failed: [String] = [],
        skippedInvalidRating: Int = 0
    ) {
        self.scanned = scanned
        self.sidecarsFound = sidecarsFound
        self.applied = applied
        self.conflicts = conflicts
        self.missingRating = missingRating
        self.missingLabel = missingLabel
        self.missingKeywords = missingKeywords
        self.failed = failed
        self.skippedInvalidRating = skippedInvalidRating
    }

    /// 兼容旧 JSON：没有 skippedInvalidRating 键按 0 处理（不因新增统计字段
    /// 让旧迁移报告/测试夹具解码失败）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanned = try container.decode(Int.self, forKey: .scanned)
        sidecarsFound = try container.decode(Int.self, forKey: .sidecarsFound)
        applied = try container.decode(Int.self, forKey: .applied)
        conflicts = try container.decode(Int.self, forKey: .conflicts)
        missingRating = try container.decode(Int.self, forKey: .missingRating)
        missingLabel = try container.decode(Int.self, forKey: .missingLabel)
        missingKeywords = try container.decode(Int.self, forKey: .missingKeywords)
        failed = try container.decode([String].self, forKey: .failed)
        skippedInvalidRating = try container.decodeIfPresent(
            Int.self, forKey: .skippedInvalidRating) ?? 0
    }
}

// MARK: - Wave3（task-24）：默认实现

public extension MaintenanceAPI {
    /// 未实现的目录包导出：显式失败，不返回空包（空包会被 UI 当成"导出成功 0 张"）。
    func exportLibraryPackage(_ input: LibraryExportInput) async throws -> LibraryExportResult {
        throw GatherError.invalidParameter(
            field: "exportLibraryPackage",
            reason: "library package export is not implemented by this MaintenanceAPI")
    }

    func importLibraryPackage(
        _ input: Confirmed<LibraryImportInput>
    ) async throws -> LibraryImportReport {
        throw GatherError.invalidParameter(
            field: "importLibraryPackage",
            reason: "library package import is not implemented by this MaintenanceAPI")
    }

    func migrateExternalMetadata(
        _ input: Confirmed<ExternalMigrationInput>
    ) async throws -> ExternalMigrationReport {
        throw GatherError.invalidParameter(
            field: "migrateExternalMetadata",
            reason: "external metadata migration is not implemented by this MaintenanceAPI")
    }
}
// MARK: - Wave3（task-24）：目录包文件格式
//
// 设计取舍：
// - **不打包原图**：只记 relativePath（相对导出时工作区源根）与校验和；迁移到新磁盘后
//   由 newRoot 重绑定，避免包体积与版权复制问题；
// - 评分/色标/关键词/决策来自 photo_metadata_cache（rating/label/keywords）与
//   culling_decisions.decision（pick 语义）；IPTC 以 JSON 文本原样搬运，跨版本不丢字段；
// - formatVersion 只有 1；读到更高版本显式失败（不静默丢字段）。

public struct LibraryPackage: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var app: String
    public var exportedAt: String
    public var session: LibraryPackageSession
    public var collections: [LibraryPackageCollection]
    public var photos: [LibraryPackagePhoto]

    public init(
        formatVersion: Int = 1,
        app: String = "Gather",
        exportedAt: String,
        session: LibraryPackageSession,
        collections: [LibraryPackageCollection] = [],
        photos: [LibraryPackagePhoto]
    ) {
        self.formatVersion = formatVersion
        self.app = app
        self.exportedAt = exportedAt
        self.session = session
        self.collections = collections
        self.photos = photos
    }
}

public struct LibraryPackageSession: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// 导出时的工作区源根（仅作提示；导入按 newRoot 重绑定）。
    public var sourcePath: String
    public var createdAt: String

    public init(id: String, name: String, sourcePath: String = "", createdAt: String = "") {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.createdAt = createdAt
    }
}

public struct LibraryPackageCollection: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sortOrder: Int
    /// 只包含本包里存在的 photoId（归档/未导出的成员不写入）。
    public var photoIds: [String]

    public init(id: String, name: String, sortOrder: Int = 0, photoIds: [String] = []) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.photoIds = photoIds
    }
}

public struct LibraryPackagePhoto: Codable, Equatable, Sendable {
    public var photoId: String
    /// 相对导出时会话源根的路径（源根为空时退化为文件名）。
    public var relativePath: String
    public var filename: String
    public var checksum: String
    public var fileSize: Int64
    public var fileMtimeMs: Double
    public var status: String
    public var rating: Int?
    public var label: String?
    /// culling_decisions.decision（keep/reject/pending）；nil = 没有决策行。
    public var decision: String?
    public var keywords: [String]
    /// IPTC 描述性元数据 JSON 文本（'{}' 表示空）。
    public var descriptiveJSON: String

    public init(
        photoId: String,
        relativePath: String,
        filename: String,
        checksum: String = "",
        fileSize: Int64 = 0,
        fileMtimeMs: Double = 0,
        status: String = "pending",
        rating: Int? = nil,
        label: String? = nil,
        decision: String? = nil,
        keywords: [String] = [],
        descriptiveJSON: String = "{}"
    ) {
        self.photoId = photoId
        self.relativePath = relativePath
        self.filename = filename
        self.checksum = checksum
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
        self.status = status
        self.rating = rating
        self.label = label
        self.decision = decision
        self.keywords = keywords
        self.descriptiveJSON = descriptiveJSON
    }
}
