// API/Impl/FilterCommandsImpl.swift
// R5 命令层接线：filter 域实现（批次 B5）。
// 逻辑来源：宿主路由层 filter.photos / filter.photos_global / filter.suggest 分支；
// 过滤与计数全部复用 FilterEngine（Services/ 保留项），错误类型与返回形状不变：
// - photos：criteria/sortBy/sortOrder 由 DTO 承载；limit 钳制 1...500、offset ≥ 0
//   （旧分发层语义）。协议以扁平 Int 承接 limit/offset，故"缺省 100"由调用方
//   （宿主适配层）在缺参时补齐，本实现只保留上下界钳制；
// - photos_global：返回 (photos, total) 元组（旧响应 {photos, total} 的投影）；
//   limit 缺省 100 / 上限 500、offset 缺省 0，与旧分发层钳制一致；
// - suggest：keyword 缺省空串（DTO 非可选，宿主适配层补缺省后传入）；<2 字符
//   由引擎返回空列表，不做额外校验。
// 行投影：FilteredPhotoData → Protocol/Session.swift 的 PhotoData；metadata/result
// 的 JSON 字符串解析为对象（解析失败回退空对象，逐字对齐旧 parseJSONObject）；
// width/height 取引擎行值（引擎 SELECT 未含该列，实际恒 0）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// filter 域命令实现：注入过滤引擎（SQL 生成 + 查询 + 计数）。
public actor FilterCommandsImpl: FilterCommands {
    /// 旧分发层钳制上限（filter.ipc.ts：limit 1..500）。
    public static let maxLimit = 500
    /// 旧分发层缺省 limit（filter.ipc.ts）。
    public static let defaultLimit = 100

    private let engine: FilterEngine

    public init(engine: FilterEngine) {
        self.engine = engine
    }

    /// 旧命令：`filter.photos`。行投影为 PhotoData；limit/offset 按旧分发层钳制。
    public func photos(
        _ params: FilterPhotosParams,
        limit: Int,
        offset: Int
    ) async throws -> [PhotoData] {
        let rows = try await engine.filterPhotos(
            sessionId: params.sessionId,
            criteria: params.criteria,
            sortBy: params.sortBy,
            sortOrder: params.sortOrder,
            limit: Self.clampLimit(limit),
            offset: Self.clampOffset(offset)
        )
        return rows.map(Self.photoData)
    }

    /// 旧命令：`filter.photos_global`。跨会话全局过滤 + 总数（旧 {photos, total}）。
    public func photosGlobal(_ params: FilterPhotosGlobalParams) async throws
        -> (photos: [GlobalPhotoResult], total: Int) {
        let photos = try await engine.filterGlobally(
            criteria: params.criteria,
            limit: Self.clampLimit(params.limit ?? Self.defaultLimit),
            offset: Self.clampOffset(params.offset ?? 0),
            sessionId: params.sessionId
        )
        let total = try await engine.countGlobally(
            criteria: params.criteria, sessionId: params.sessionId)
        return (photos, total)
    }

    /// 旧命令：`filter.suggest`。字段取值建议（引擎内 <2 字符返回空）。
    public func suggest(_ params: FilterSuggestParams) async throws -> [FilterSuggestion] {
        try await engine.suggest(params.sessionId, keyword: params.keyword)
    }

    // MARK: - 旧分发层钳制 / 行投影

    /// 旧 clampedLimit：floor 后钳制 1...500（参数已为 Int，floor 为恒等）。
    private static func clampLimit(_ limit: Int) -> Int {
        Swift.max(1, Swift.min(maxLimit, limit))
    }

    /// 旧 clampedOffset：floor 后钳制 ≥ 0（参数已为 Int，floor 为恒等）。
    private static func clampOffset(_ offset: Int) -> Int {
        Swift.max(0, offset)
    }

    /// 旧 filterPhotoDataJSON 的行投影。
    private static func photoData(_ photo: FilteredPhotoData) -> PhotoData {
        PhotoData(
            id: photo.id,
            sessionId: photo.sessionId,
            filepath: photo.filepath,
            filename: photo.filename,
            checksum: photo.checksum,
            hasExistingXmp: photo.hasExistingXmp,
            faceCount: photo.faceCount,
            width: photo.width,
            height: photo.height,
            metadata: parseJSONObject(photo.metadata),
            result: parseJSONObject(photo.result),
            status: photo.status,
            createdAt: photo.createdAt,
            updatedAt: photo.updatedAt
        )
    }

    /// 旧 parseJSONObject：字符串解析为对象，失败或非对象回退 {}。
    private static func parseJSONObject(_ json: String) -> [String: JSONValue] {
        guard let parsed = try? JSONValue.parse(json), case .object(let object) = parsed else {
            return [:]
        }
        return object
    }
}
