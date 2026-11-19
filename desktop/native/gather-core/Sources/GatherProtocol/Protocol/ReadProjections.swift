// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ReadProjections.swift
// Wave 5 / M10：只读行投影 DTO（从 GatherPersistence 上移）。
//
// 背景（D2：行类型穿端口）：三个热点行类型原本定义在 GatherPersistence，
// 端口 / Application / UI 签名直接引用数据库层类型。M10 把它们的只读投影上移：
// 字段、Equatable / Sendable 与注释逐字保留；DB 映射（init(row: DBRow)、列序解码）
// 留在 Persistence 的扩展里（同模块可见性不变）。
//
// D2 下一批（同一只读投影口径）：MetadataCacheRow / DeliveryItemRow / FaceClusterRow 上移；
// FaceClusterRow 的 members / binding 字段依赖 FaceClusterMemberRow / FaceBindingData，
// 二者随之一起上移（字段解码同样留在 Persistence 扩展里）。
//
// 约束：
// - 本文件只放只读投影，不含任何 DB 解码；DBRow 仍归 Persistence，禁止上移。
// - 字段只读（public let）；跨模块构造走显式 public init（隐式 memberwise init 为 internal）。
//   例外：FaceClusterRow 的 members / binding 是运行时装配的展示字段，原样保留 public var。

import Foundation

/// culling_decisions 表行（列序 = TableColumns.cullingDecisions，见 Schema.swift）。
public struct CullingDecisionRow {
    public let id: Int64
    public let sessionId: String
    public let photoId: String
    public let groupId: String
    public let decision: String
    /// 镜像列：不是真相源，禁止读取（唯一真相源为 photo_metadata_cache.rating）。
    public let rating: Int64
    /// 镜像列：不是真相源，禁止读取（唯一真相源为 photo_metadata_cache.label）。
    public let colorLabel: String
    public let decisionSource: String
    public let revision: Int64
    public let createdAt: String
    public let updatedAt: String

    package init(
        id: Int64,
        sessionId: String,
        photoId: String,
        groupId: String,
        decision: String,
        rating: Int64,
        colorLabel: String,
        decisionSource: String,
        revision: Int64,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.sessionId = sessionId
        self.photoId = photoId
        self.groupId = groupId
        self.decision = decision
        self.rating = rating
        self.colorLabel = colorLabel
        self.decisionSource = decisionSource
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 轻投影：除 metadata/result 外的全部列（TS: PhotoProjectionRow）。
public struct PhotoProjectionRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let checksumFileSize: Int
    public let checksumFileMtimeMs: Double
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String
    /// P0 / A1：非 nil = 已移出工作区（文件在 _rejects）。读面按 PhotoVisibility 过滤。
    public let archivedAt: String?

    package init(
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        checksum: String,
        checksumFileSize: Int,
        checksumFileMtimeMs: Double,
        status: String,
        assetId: String?,
        assetFileId: String?,
        width: Int,
        height: Int,
        createdAt: String,
        updatedAt: String,
        archivedAt: String?,
    ) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.checksumFileSize = checksumFileSize
        self.checksumFileMtimeMs = checksumFileMtimeMs
        self.status = status
        self.assetId = assetId
        self.assetFileId = assetFileId
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

/// 分页轻投影（TS: PhotoPageRow）。PHOTO_PAGE_COLUMNS 恒为 13 列（V1 交集列）；
/// 旧 TS 的行形状还带 metadata/result/checksum 尾部可选列，V1 不再读它们
/// （Cut 2 S5b / R1-01）：行映射只认这 13 列，尾部多出的列不参与解码。
public struct PhotoPageRow: Equatable, Sendable {
    public let rowid: Int64
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let checksum: String?
    public let createdAt: String
    public let updatedAt: String

    package init(
        rowid: Int64,
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        status: String,
        assetId: String?,
        assetFileId: String?,
        width: Int,
        height: Int,
        checksum: String?,
        createdAt: String,
        updatedAt: String,
    ) {
        self.rowid = rowid
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.status = status
        self.assetId = assetId
        self.assetFileId = assetFileId
        self.width = width
        self.height = height
        self.checksum = checksum
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// photo_metadata_cache 表行（列序 = TableColumns.photoMetadataCache，见 Schema.swift）。
public struct MetadataCacheRow {
    public let id: Int64
    public let photoId: String
    public let sessionId: String
    public let dateTaken: String?
    public let cameraMake: String?
    public let cameraModel: String?
    public let lensModel: String?
    public let focalLength: Double?
    public let fNumber: Double?
    public let exposureTime: String?
    public let iso: Int64?
    public let rating: Int64
    public let label: String?
    public let gpsLatitude: Double?
    public let gpsLongitude: Double?
    public let width: Int64?
    public let height: Int64?
    public let fileSize: Int64?
    public let fileMtime: String?
    public let keywordsJSON: String
    public let cachedAt: String
    public let updatedAt: String
    /// P1 / IPTC：描述性元数据 JSON（DescriptiveMetadata 的编码）。
    public let iptcJSON: String

    package init(
        id: Int64,
        photoId: String,
        sessionId: String,
        dateTaken: String?,
        cameraMake: String?,
        cameraModel: String?,
        lensModel: String?,
        focalLength: Double?,
        fNumber: Double?,
        exposureTime: String?,
        iso: Int64?,
        rating: Int64,
        label: String?,
        gpsLatitude: Double?,
        gpsLongitude: Double?,
        width: Int64?,
        height: Int64?,
        fileSize: Int64?,
        fileMtime: String?,
        keywordsJSON: String,
        cachedAt: String,
        updatedAt: String,
        iptcJSON: String,
    ) {
        self.id = id
        self.photoId = photoId
        self.sessionId = sessionId
        self.dateTaken = dateTaken
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.iso = iso
        self.rating = rating
        self.label = label
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.keywordsJSON = keywordsJSON
        self.cachedAt = cachedAt
        self.updatedAt = updatedAt
        self.iptcJSON = iptcJSON
    }
}

/// delivery_items 表行（11 列 + JOIN 得到的 delivery.xmp_path）。
public struct DeliveryItemRow: Sendable, Equatable {
    public let id: Int64
    public let deliveryId: Int64
    public let photoId: String
    public let module: String
    public let attributesJSON: String
    public let keywords: String
    public let status: String
    public let errorMessage: String
    public let attemptCount: Int64
    public let createdAt: String
    public let updatedAt: String
    /// 派生于 deliveries.xmp_path（显式 JOIN 列，不是 delivery_items 的物理列）。
    public let xmpPath: String

    package init(
        id: Int64,
        deliveryId: Int64,
        photoId: String,
        module: String,
        attributesJSON: String,
        keywords: String,
        status: String,
        errorMessage: String,
        attemptCount: Int64,
        createdAt: String,
        updatedAt: String,
        xmpPath: String,
    ) {
        self.id = id
        self.deliveryId = deliveryId
        self.photoId = photoId
        self.module = module
        self.attributesJSON = attributesJSON
        self.keywords = keywords
        self.status = status
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.xmpPath = xmpPath
    }
}

/// face_clusters 行 + 实时成员计数 + 身份匹配建议（V1 10 个结果列）。
/// 列序: id(0), session_id(1), label(2), member_count(3), status(4),
///       thumbnail_path(5), matched_person_id(6), match_confidence(7),
///       created_at(8), updated_at(9)。
/// V1 删除了 thumbnail_base64；缩略图文件由 thumbnail_path 承载。
public struct FaceClusterRow {
    public let id: Int64
    public let sessionId: String
    public let label: String
    /// 实时 COUNT(face_cluster_members)，不是存档列。
    public let memberCount: Int64
    public let status: String
    public let thumbnailPath: String
    /// 身份链接（PersonRepo.bindRole / 跨会话匹配写入）。
    public let matchedPersonId: String?
    public let matchConfidence: Double?
    public let createdAt: String
    public let updatedAt: String
    public var members: [FaceClusterMemberRow]?
    public var binding: FaceBindingData?

    package init(
        id: Int64,
        sessionId: String,
        label: String,
        memberCount: Int64,
        status: String,
        thumbnailPath: String,
        matchedPersonId: String?,
        matchConfidence: Double?,
        createdAt: String,
        updatedAt: String,
        members: [FaceClusterMemberRow]?,
        binding: FaceBindingData?,
    ) {
        self.id = id
        self.sessionId = sessionId
        self.label = label
        self.memberCount = memberCount
        self.status = status
        self.thumbnailPath = thumbnailPath
        self.matchedPersonId = matchedPersonId
        self.matchConfidence = matchConfidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.members = members
        self.binding = binding
    }
}

/// face_cluster_members LEFT JOIN photos 的行（fm.id, fm.cluster_id, fm.session_id,
/// fm.photo_id, p.filepath AS photo_path, fm.bbox, fm.confidence, fm.observation_id）。
/// 照片行缺失时 photoPath 为空字符串（成员仍在计数与清单中，不再被 JOIN 丢掉）。
public struct FaceClusterMemberRow {
    public let id: Int64
    public let clusterId: Int64
    public let sessionId: String
    public let photoId: String
    public let photoPath: String
    public let bbox: String
    public let confidence: Double
    public let observationId: Int64?

    package init(
        id: Int64,
        clusterId: Int64,
        sessionId: String,
        photoId: String,
        photoPath: String,
        bbox: String,
        confidence: Double,
        observationId: Int64?,
    ) {
        self.id = id
        self.clusterId = clusterId
        self.sessionId = sessionId
        self.photoId = photoId
        self.photoPath = photoPath
        self.bbox = bbox
        self.confidence = confidence
        self.observationId = observationId
    }
}

/// 绑定信息（TS FaceClusterRow.binding）。
public struct FaceBindingData: Equatable, Sendable {
    public let clusterId: String
    public let roleName: String
    public let keywords: [String]

    package init(clusterId: String, roleName: String, keywords: [String]) {
        self.clusterId = clusterId
        self.roleName = roleName
        self.keywords = keywords
    }
}
