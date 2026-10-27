// desktop/native/gather-core/Sources/GatherProtocol/Protocol/PhotoMetadataDetail.swift
// P1 / IPTC：只读元数据面的唯一 DTO（拍摄参数 + 描述性元数据 + 文件与同步态）。
//
// 语义：
// - 数据源是 photo_metadata_cache（全应用 XMP 投影），本 DTO 不触发磁盘解析；
//   需要"从盘上刷新"由调用方走 metadata 扫描，不在读面板时隐式发生。
// - descriptive 的 nil 字段表示"未设置"，与"空串"（显式清空）不同，面板据此显示占位符。
import Foundation

/// EXIF / 文件快照（16 个已入库字段 + rating/label/keywords 投影）。
public struct PhotoExifSnapshot: Codable, Equatable, Sendable {
    public var dateTaken: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var focalLength: Double?
    public var fNumber: Double?
    public var exposureTime: String?
    public var iso: Int?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var width: Int?
    public var height: Int?
    public var fileSize: Int?
    public var fileMtime: String?
    public var rating: Int
    public var label: String?
    public var keywords: [String]

    public init(
        dateTaken: String? = nil, cameraMake: String? = nil, cameraModel: String? = nil,
        lensModel: String? = nil, focalLength: Double? = nil, fNumber: Double? = nil,
        exposureTime: String? = nil, iso: Int? = nil,
        gpsLatitude: Double? = nil, gpsLongitude: Double? = nil,
        width: Int? = nil, height: Int? = nil, fileSize: Int? = nil, fileMtime: String? = nil,
        rating: Int = 0, label: String? = nil, keywords: [String] = []
    ) {
        self.dateTaken = dateTaken
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.iso = iso
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.rating = rating
        self.label = label
        self.keywords = keywords
    }

    /// 没有任何可显示值（面板据此显示"尚未解析"）。
    public var isEmpty: Bool {
        dateTaken == nil && cameraMake == nil && cameraModel == nil && lensModel == nil
            && focalLength == nil && fNumber == nil && exposureTime == nil && iso == nil
            && gpsLatitude == nil && gpsLongitude == nil && width == nil && height == nil
            && fileSize == nil && fileMtime == nil && rating == 0 && label == nil && keywords.isEmpty
    }
}

/// 单张照片的只读元数据详情。
public struct PhotoMetadataDetail: Codable, Equatable, Sendable {
    public var photoId: String
    public var sessionId: String
    public var filepath: String
    public var filename: String
    public var xmpPath: String
    public var hasXMP: Bool
    public var exif: PhotoExifSnapshot
    public var descriptive: DescriptiveMetadata
    public var cachedAt: String
    public var updatedAt: String

    public init(
        photoId: String, sessionId: String, filepath: String, filename: String,
        xmpPath: String, hasXMP: Bool, exif: PhotoExifSnapshot,
        descriptive: DescriptiveMetadata, cachedAt: String, updatedAt: String
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.xmpPath = xmpPath
        self.hasXMP = hasXMP
        self.exif = exif
        self.descriptive = descriptive
        self.cachedAt = cachedAt
        self.updatedAt = updatedAt
    }

    /// 已填写的描述性字段数（面板标题用）。
    public var filledDescriptiveCount: Int { descriptive.nonNilFieldCount }
}
