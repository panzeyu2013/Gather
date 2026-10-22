// desktop/native/gather-core/Sources/GatherProtocol/Protocol/XMPProvider.swift
// WP2a（纯移动）：XMPProvider / MetadataWriteAttributes 自
// GatherDomain/Services/MetadataProviders.swift 下移到 Protocol。
//
// 为什么在 Protocol：GatherDelivery 只允许依赖 Protocol + Persistence，而
// DeliveryCoordinator / WritebackService / MetadataMutationService 都经该端口
// 读写 XMP；宿主实现（gather-app/SidecarXMPProvider）继续注入。
// 原文件的其余宿主端口（EmbeddedXMPReader / ExifProvider / ImageDimensionsProvider）
// 不属于交付依赖面，留在 GatherDomain。

/// TS: MetadataWriteAttributes —— XMP 可写属性集。
public struct MetadataWriteAttributes: Codable, Equatable, Sendable {
    public var keywords: [String]? // TS: keywords?
    public var rating: Double? // TS: rating?
    public var label: String? // TS: label?
    public var dateTaken: String? // TS: dateTaken?
    public var latitude: Double? // TS: latitude?
    public var longitude: Double? // TS: longitude?

    public init(
        keywords: [String]? = nil,
        rating: Double? = nil,
        label: String? = nil,
        dateTaken: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.keywords = keywords
        self.rating = rating
        self.label = label
        self.dateTaken = dateTaken
        self.latitude = latitude
        self.longitude = longitude
    }

    /// TS: `Object.keys(attributes).length === 0`（corrupt sidecar 守卫）。
    public var isEmpty: Bool {
        keywords == nil && rating == nil && label == nil
            && dateTaken == nil && latitude == nil && longitude == nil
    }

    /// TS: `{ ...attributes }`（仅存在的键）。
    public var asJSONValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let keywords { object["keywords"] = .array(keywords.map { .string($0) }) }
        if let rating { object["rating"] = .number(rating) }
        if let label { object["label"] = .string(label) }
        if let dateTaken { object["dateTaken"] = .string(dateTaken) }
        if let latitude { object["latitude"] = .number(latitude) }
        if let longitude { object["longitude"] = .number(longitude) }
        return .object(object)
    }

    /// 从 JSONValue（outbox base_values/patch 语义）构造。
    public init(jsonValue: JSONValue) {
        self.init(
            keywords: jsonValue["keywords"]?.arrayValue,
            rating: jsonValue["rating"]?.numberValue,
            label: jsonValue["label"]?.stringValue,
            dateTaken: jsonValue["dateTaken"]?.stringValue,
            latitude: jsonValue["latitude"]?.numberValue,
            longitude: jsonValue["longitude"]?.numberValue
        )
    }
}

/// TS: MetadataReader + MetadataWriter（XMP 侧车 writer 的最小面）。
/// 实现由 gather-app 宿主提供（exiftool/文件系统桥，3.4 页面阶段），
/// 本层所有服务只依赖该协议。
public protocol XMPProvider: Sendable {
    /// TS: MetadataReader.readKeywords —— 读取照片的 XMP 关键词（失败抛错，
    /// 调用方按 TS 语义处理：preview 里 corrupt/missing 视为空列表）。
    func readKeywords(photoPath: String) async throws -> [String]

    /// TS: MetadataReader.readAttributes —— 读取可写属性（keywords/rating/label/...）。
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes

    /// TS: MetadataWriter.writeAttributes —— 将属性写入 XMP（原子替换）。
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws

    /// TS: MetadataWriter.backup —— 写前安全备份，返回备份路径；原文件不存在时
    /// 宿主返回空串（对应 TS 侧"无原始 sidecar 时无备份"语义）。
    func backup(photoPath: String) async throws -> String

    /// TS: MetadataWriter.restore —— 从备份恢复原文件。
    func restore(photoPath: String, backupPath: String) async throws

    /// TS: `fs.existsSync(path)`（preview 的 willCreate / 协调器的 cleanup 判定）。
    func fileExists(_ path: String) -> Bool

    /// TS: `fs/promises.unlink(path)`（cleanup 删除无备份的 sidecar、orphan 处理）。
    func removeFile(_ path: String) async throws
}
