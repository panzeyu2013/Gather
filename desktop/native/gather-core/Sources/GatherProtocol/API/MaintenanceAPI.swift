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
    // Wave5（Batch3 / task-20）：组织资产分项计数（UI 据此说明"带走了哪些组织信息"）。
    public var stackCount: Int
    public var smartAlbumCount: Int
    public var savedSearchCount: Int
    public var personBindingCount: Int
    public var duplicateGroupCount: Int

    public init(
        packagePath: String,
        photoCount: Int,
        collectionCount: Int,
        skippedArchivedCount: Int = 0,
        stackCount: Int = 0,
        smartAlbumCount: Int = 0,
        savedSearchCount: Int = 0,
        personBindingCount: Int = 0,
        duplicateGroupCount: Int = 0
    ) {
        self.packagePath = packagePath
        self.photoCount = photoCount
        self.collectionCount = collectionCount
        self.skippedArchivedCount = skippedArchivedCount
        self.stackCount = stackCount
        self.smartAlbumCount = smartAlbumCount
        self.savedSearchCount = savedSearchCount
        self.personBindingCount = personBindingCount
        self.duplicateGroupCount = duplicateGroupCount
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

    // MARK: - Wave5（Batch3 / task-20）：组织资产分项计数

    /// 重建的堆栈数（成员全部映射失败/为空的堆栈计入 skippedStacks）。
    public var importedStacks: Int
    /// 新建或按冲突策略更新的智能相册数。
    public var importedSmartAlbums: Int
    /// 导入的保存查询数（包内全局查询按新工作区作用域落地或按冲突策略处理）。
    public var importedSavedSearches: Int
    /// 重建的人物-照片绑定数（identity 按包内 personId → 同名身份 → 新建三级解析）。
    public var importedPersonBindings: Int
    /// 组织资产里引用不到目标 photoId / 无法解析的条目数（如堆栈成员、人物绑定）。
    public var skippedUnmappedItems: Int
    /// 包内的智能相册/保存查询因 criteria 无法解码而跳过数。
    public var skippedBrokenCriteria: Int
    /// 包内的堆栈因成员为空而跳过数。
    public var skippedStacks: Int
    /// 智能相册按冲突策略保留本地（未导入）数。
    public var skippedSmartAlbums: Int
    /// 保存查询按冲突策略保留本地（未导入）数。
    public var skippedSavedSearches: Int
    /// 重复组段：**不导入**（派生数据，重扫会重建）；这里记录包内条数供报告标注。
    public var skippedDuplicateGroups: Int
    /// 导入后入队的 metadata.scan job id（nil = 未入队：路径未变化且无待索引照片，
    /// 或入队失败——失败只记日志，不让导入失败）。
    public var scanJobId: String?

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
        pendingCount: Int = 0,
        importedStacks: Int = 0,
        importedSmartAlbums: Int = 0,
        importedSavedSearches: Int = 0,
        importedPersonBindings: Int = 0,
        skippedUnmappedItems: Int = 0,
        skippedBrokenCriteria: Int = 0,
        skippedStacks: Int = 0,
        skippedSmartAlbums: Int = 0,
        skippedSavedSearches: Int = 0,
        skippedDuplicateGroups: Int = 0,
        scanJobId: String? = nil
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
        self.importedStacks = importedStacks
        self.importedSmartAlbums = importedSmartAlbums
        self.importedSavedSearches = importedSavedSearches
        self.importedPersonBindings = importedPersonBindings
        self.skippedUnmappedItems = skippedUnmappedItems
        self.skippedBrokenCriteria = skippedBrokenCriteria
        self.skippedStacks = skippedStacks
        self.skippedSmartAlbums = skippedSmartAlbums
        self.skippedSavedSearches = skippedSavedSearches
        self.skippedDuplicateGroups = skippedDuplicateGroups
        self.scanJobId = scanJobId
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
// - formatVersion = 2（Wave5 / Batch3）：新增组织资产段 stacks / smartAlbums /
//   savedSearches / personBindings / duplicateGroups。**旧包（v1）仍可导入**：
//   新增段用 decodeIfPresent 缺失即空（见 init(from:)），不因升级包格式 fail；
// - 读到比当前更高的版本仍显式失败（不静默丢新字段）。

public struct LibraryPackage: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var app: String
    public var exportedAt: String
    public var session: LibraryPackageSession
    public var collections: [LibraryPackageCollection]
    public var photos: [LibraryPackagePhoto]
    // MARK: - Wave5（Batch3 / task-20）：组织资产（v2 新增；v1 包解码为空数组）
    /// 堆栈：包内成员 photoId（有序）+ 名称 + 封面（封面不可移植时 nil，导入取首成员）。
    public var stacks: [LibraryPackageStack]
    /// 智能相册（库级资产，不带 sessionId）：criteria 以 JSON 文本原样搬运。
    public var smartAlbums: [LibraryPackageSmartAlbum]
    /// 保存查询（name + criteria JSON + 作用域标记）。
    public var savedSearches: [LibraryPackageSavedSearch]
    /// 人物-照片绑定：可移植部分只有 person 名 + photoId（face cluster id 不可移植）。
    public var personBindings: [LibraryPackagePersonBinding]
    /// 重复组：仅导出留档（成员 + 用户裁决）；导入不重建（派生数据，重扫会重建）。
    public var duplicateGroups: [LibraryPackageDuplicateGroup]

    public init(
        formatVersion: Int = 2,
        app: String = "Gather",
        exportedAt: String,
        session: LibraryPackageSession,
        collections: [LibraryPackageCollection] = [],
        photos: [LibraryPackagePhoto],
        stacks: [LibraryPackageStack] = [],
        smartAlbums: [LibraryPackageSmartAlbum] = [],
        savedSearches: [LibraryPackageSavedSearch] = [],
        personBindings: [LibraryPackagePersonBinding] = [],
        duplicateGroups: [LibraryPackageDuplicateGroup] = []
    ) {
        self.formatVersion = formatVersion
        self.app = app
        self.exportedAt = exportedAt
        self.session = session
        self.collections = collections
        self.photos = photos
        self.stacks = stacks
        self.smartAlbums = smartAlbums
        self.savedSearches = savedSearches
        self.personBindings = personBindings
        self.duplicateGroups = duplicateGroups
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, app, exportedAt, session, collections, photos
        case stacks, smartAlbums, savedSearches, personBindings, duplicateGroups
    }

    /// **旧包兼容**：v1 包没有组织资产段。缺失键一律按空处理（不 fail），
    /// 并把缺失的 formatVersion 当 1 读（v1 包一定写了它，这里只是防御）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        app = try container.decodeIfPresent(String.self, forKey: .app) ?? "Gather"
        exportedAt = try container.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
        session = try container.decode(LibraryPackageSession.self, forKey: .session)
        collections = try container.decodeIfPresent(
            [LibraryPackageCollection].self, forKey: .collections) ?? []
        photos = try container.decodeIfPresent(
            [LibraryPackagePhoto].self, forKey: .photos) ?? []
        stacks = try container.decodeIfPresent(
            [LibraryPackageStack].self, forKey: .stacks) ?? []
        smartAlbums = try container.decodeIfPresent(
            [LibraryPackageSmartAlbum].self, forKey: .smartAlbums) ?? []
        savedSearches = try container.decodeIfPresent(
            [LibraryPackageSavedSearch].self, forKey: .savedSearches) ?? []
        personBindings = try container.decodeIfPresent(
            [LibraryPackagePersonBinding].self, forKey: .personBindings) ?? []
        duplicateGroups = try container.decodeIfPresent(
            [LibraryPackageDuplicateGroup].self, forKey: .duplicateGroups) ?? []
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

// MARK: - Wave5（Batch3 / task-20）：包内组织资产段（formatVersion 2）

/// 一个照片堆栈（组织资产）。
///
/// **折叠状态不可导出**：Gather 的折叠是纯视图态（没有持久列），包只带
/// 「这个堆栈存在 / 叫什么 / 有哪些成员 / 封面是谁」。
/// 封面与成员都只写入**本包里存在**的 photoId；导入时成员按 photoId→checksum
/// 两级映射重绑，映射不到的成员计入 skippedUnmappedItems。
public struct LibraryPackageStack: Codable, Equatable, Sendable {
    /// 导出侧 stack id（导入会重建，不复用；仅用于报告/排错关联）。
    public var id: String
    public var name: String
    /// 封面 photoId（不在包内成员里时置 nil；导入取首个成员）。
    public var coverPhotoId: String?
    /// 有序成员 photoId（= photo_stack_members.position 升序）。
    public var photoIds: [String]

    public init(id: String, name: String, coverPhotoId: String? = nil, photoIds: [String] = []) {
        self.id = id
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.photoIds = photoIds
    }
}

/// 一个智能相册（库级组织资产）。
///
/// criteria 用**原始 JSON 文本**搬运（与 IPTC 同一策略：跨版本不丢字段）；导入时
/// 尝试解码成 FilterGroup 并重映射 collection/stack 规则的容器 id（导入后 id 会变），
/// 解码失败则跳过并计入 skippedBrokenCriteria。
public struct LibraryPackageSmartAlbum: Codable, Equatable, Sendable {
    /// 导出侧 smart_album id（导入重建，不复用）。
    public var id: String
    public var name: String
    public var description: String
    /// FilterGroup JSON 文本（空/非法 → 导入跳过）。
    public var criteriaJSON: String
    public var sortBy: String
    public var sortOrder: String
    public var icon: String

    public init(
        id: String,
        name: String,
        description: String = "",
        criteriaJSON: String = "{}",
        sortBy: String = "date_taken",
        sortOrder: String = "desc",
        icon: String = "📁"
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.criteriaJSON = criteriaJSON
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.icon = icon
    }
}

/// 一条保存查询（Gallery 筛选条保存的 criteria）。
public struct LibraryPackageSavedSearch: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// FilterGroup JSON 文本（空/非法 → 导入跳过）。
    public var criteriaJSON: String
    /// true = 全局查询（saved_searches.session_id IS NULL）；false = 本工作区作用域。
    public var isGlobal: Bool

    public init(id: String, name: String, criteriaJSON: String = "{}", isGlobal: Bool = false) {
        self.id = id
        self.name = name
        self.criteriaJSON = criteriaJSON
        self.isGlobal = isGlobal
    }
}

/// 一条人物-照片绑定（face cluster → 身份 → 照片 的可移植投影）。
///
/// 只导可移植部分：**person 名 + photoId**（+ 本地 personId 供同库往返）。
/// face cluster id / 人脸向量 / role_bindings 不导出（跨库不可靠映射）。
public struct LibraryPackagePersonBinding: Codable, Equatable, Sendable {
    public var photoId: String
    /// 导出侧 persons.id（同库往返可直接命中；跨库按 personName 解析）。
    public var personId: String
    public var personName: String
    public var confidence: Double

    public init(photoId: String, personId: String, personName: String, confidence: Double = 0) {
        self.photoId = photoId
        self.personId = personId
        self.personName = personName
        self.confidence = confidence
    }
}

/// 一个重复组（**仅导出留档**：导入不重建）。
///
/// 为什么导入不重建：duplicate_groups 是 duplicate.scan 的派生结果（checksum / 视觉 hash
/// 聚类），重建必须由扫描产生；包内成员身份（photoId）在目标库会重映射，强行插入
/// 会把陈旧分组伪装成扫描结果。用户的裁决（keep/resolution）随导出留档，
/// 重扫时 DuplicateRepository.getMemberDecisions 会按 photo_id 继承（同库场景）。
public struct LibraryPackageDuplicateGroup: Codable, Equatable, Sendable {
    /// exact（checksum 分组）/ visual（视觉 hash 分组）等，原样搬运。
    public var groupType: String
    public var checksum: String?
    public var hashHex: String?
    public var members: [LibraryPackageDuplicateMember]

    public init(
        groupType: String,
        checksum: String? = nil,
        hashHex: String? = nil,
        members: [LibraryPackageDuplicateMember] = []
    ) {
        self.groupType = groupType
        self.checksum = checksum
        self.hashHex = hashHex
        self.members = members
    }
}

public struct LibraryPackageDuplicateMember: Codable, Equatable, Sendable {
    public var photoId: String
    public var isKept: Bool
    public var resolution: String?

    public init(photoId: String, isKept: Bool = false, resolution: String? = nil) {
        self.photoId = photoId
        self.isKept = isKept
        self.resolution = resolution
    }
}
