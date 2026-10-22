// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Caches.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// 会话查找/更新上下文 TTL 缓存（存储属性留在主类型体）。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    // MARK: - 更新上下文（IPC culling.update 复用）

    /// TS: getUpdateContext —— 缓存的 `updateState` 上下文；IPC 更新 handler 复用
    /// 它，点击突发不再每次重读整个会话。
    public func getUpdateContext(sessionId: String) throws -> CullingUpdateContext {
        let entry = getSessionUpdateContext(sessionId: sessionId)
        try ensureUpdateExtras(entry: entry, sessionId: sessionId)
        return CullingUpdateContext(
            photos: entry.photos,
            photoById: entry.photoById,
            photosByAssetId: entry.photosByAssetId,
            // ensureUpdateExtras 保证两者已构建；这里显式兜底而不是强解包。
            groupMap: entry.groupMap ?? [:],
            linkedByXmp: entry.linkedByXmp ?? [:]
        )
    }
    // MARK: - 会话更新上下文缓存（TS getSessionUpdateContext /
    // refreshSessionUpdateContext / ensureUpdateExtras / prune）

    /// TS: getSessionUpdateContext —— 会话照片 + id 索引，TTL 缓存。更新路径
    /// 用它让点击突发不再每次重读整个会话（轻投影跳过重 JSON 列）。
    /// 库侧存在性查询（分块 IN，避免 SQLite 变量上限）：历史重放的跳过规则与
    /// 直接调用的契约错误共用。
    func existingSessionPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String> {
        try richQuery.existingPhotoIds(sessionId: sessionId, photoIds: photoIds)
    }

    func getSessionUpdateContext(sessionId: String) -> SessionUpdateEntry {
        let now = Date()
        if let cached = sessionUpdateCache[sessionId], cached.expiresAt > now {
            return cached
        }
        let photos = loadSessionPhotos(sessionId: sessionId)
        let entry = SessionUpdateEntry(
            photos: photos,
            photoById: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
            photosByAssetId: buildPhotosByAssetIndex(photos),
            groupMap: nil,
            groupMapResultId: nil,
            linkedByXmp: nil,
            refreshed: false,
            expiresAt: now.addingTimeInterval(Self.updateTTLSeconds)
        )
        sessionUpdateCache[sessionId] = entry
        pruneSessionUpdateCache()
        return entry
    }

    /// TS: refreshSessionUpdateContext —— TTL 缓存上下文漏照片时的一次新鲜读：
    /// 索引器的增删对缓存不可见，窗口内先试一次新鲜读（新导入的照片绝不能被
    /// 拒，真删除的第二次检查仍会被拒）。组索引、xmp 联动与会话查找随照片集
    /// 一起失效，下个 ensureUpdateExtras 对新生行重建。
    func refreshSessionUpdateContext(sessionId: String, entry: SessionUpdateEntry) {
        if entry.refreshed { return }
        let photos = loadSessionPhotos(sessionId: sessionId)
        entry.photos = photos
        entry.photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        entry.photosByAssetId = buildPhotosByAssetIndex(photos)
        entry.groupMap = nil
        entry.groupMapResultId = nil
        entry.linkedByXmp = nil
        entry.refreshed = true
        // 组索引可能按旧照片集解析过（groups_json 兜底），会话查找整体重建。
        sessionLookupCache.removeValue(forKey: sessionId)
    }

    /// TS: ensureUpdateExtras —— 懒填充缓存上下文里的相似度组索引与 xmp 联动
    /// 映射。组索引按相似度结果版本键控：每次访问重查版本，结果替换即重建，
    /// 绝不再写旧结果的无主 "${oldResultId}:${i}" 组 id。xmp 联动只依赖照片集，
    /// 与其一起重建（见 refreshSessionUpdateContext）。与照片加载分离，让调用方
    /// 能在任何相似度读之前校验照片 id，O(n) 侧车扫描每条目/每版本一次而非每次
    /// 点击一次。
    func ensureUpdateExtras(entry: SessionUpdateEntry, sessionId: String) throws {
        let lookup = try getSessionLookup(sessionId: sessionId)
        // TS: `groupMap !== undefined && groupMapResultId === lookup.resultRow?.id`
        // —— 已解析且版本一致时直接复用（含空索引：无相似度结果时 groupMapResultId
        // 与 resultRow?.id 同为 nil，同样视为已解析）。
        if entry.groupMap != nil && entry.groupMapResultId == lookup.resultRow?.id {
            return
        }
        entry.groupMap = try buildPhotoGroupIndex(photos: entry.photos, sessionId: sessionId, lookup: lookup)
        entry.groupMapResultId = lookup.resultRow?.id
        var linkedByXmp: [String: [CullingPhotoRow]] = [:]
        for photo in entry.photos {
            let xmpPath = DeliveryPath.sidecar(photo.filepath)
            linkedByXmp[xmpPath, default: []].append(photo)
        }
        entry.linkedByXmp = linkedByXmp
    }

    private func pruneSessionUpdateCache() {
        let now = Date()
        sessionUpdateCache = sessionUpdateCache.filter { $0.value.expiresAt > now }
        while sessionUpdateCache.count > Self.updateCacheMax,
              let oldest = sessionUpdateCache.keys.first {
            sessionUpdateCache.removeValue(forKey: oldest)
        }
    }

    /// TS: loadSessionPhotos —— 热路径用轻投影；全行兜底保持只暴露 getBySession
    /// 的测试替身可用（TS 注释语义；Swift 侧仓库恒有投影，直接使用）。
    private func loadSessionPhotos(sessionId: String) -> [CullingPhotoRow] {
        (try? photoRepo.getBySessionProjection(sessionId: sessionId))?.map { CullingPhotoRow(row: $0) }
            ?? ((try? photoRepo.getBySession(sessionId: sessionId))?.map { CullingPhotoRow(row: $0) } ?? [])
    }

    // MARK: - 会话查找缓存（TS getSessionLookup / prune / getLatestSimilarityMap /
    // buildPhotoGroupIndex）

    /// TS: getSessionLookup —— 最新相似度结果行 + 由其派生的版本键控查询。
    /// 结果 id 即版本：替换即原子重建条目，一个结果的缓存行绝不与另一结果混杂。
    func getSessionLookup(sessionId: String) throws -> SessionLookupEntry {
        let resultRow = try similarityResultRepo.getLatest(sessionId: sessionId)
        let now = Date()
        if let cached = sessionLookupCache[sessionId],
           cached.resultRow?.id == resultRow?.id, cached.expiresAt > now {
            return cached
        }
        let similarityMap: [String: String]
        if let resultRow {
            similarityMap = try similarityResultRepo.getPhotoGroupMap(
                sessionId: sessionId, resultId: resultRow.id
            )
        } else {
            similarityMap = [:]
        }
        let entry = SessionLookupEntry(
            resultRow: resultRow,
            similarityMap: similarityMap,
            groupIndex: similarityMap.isEmpty ? [:] : similarityMap,
            groupIndexResolved: !similarityMap.isEmpty,
            analysesLoaded: false,
            qualityByPhoto: [:],
            facesByPhoto: [:],
            analysisMaxByPhoto: [:],
            peopleByPhoto: [:],
            groupCount: 0,
            groupCountResolved: false,
            expiresAt: now.addingTimeInterval(Self.lookupTTLSeconds)
        )
        sessionLookupCache[sessionId] = entry
        pruneSessionLookupCache()
        return entry
    }

    private func pruneSessionLookupCache() {
        let now = Date()
        sessionLookupCache = sessionLookupCache.filter { $0.value.expiresAt > now }
        while sessionLookupCache.count > Self.lookupCacheMax,
              let oldest = sessionLookupCache.keys.first {
            sessionLookupCache.removeValue(forKey: oldest)
        }
    }

    /// TS: getLatestSimilarityMap。
    func getLatestSimilarityMap(sessionId: String) throws -> [String: String] {
        try getSessionLookup(sessionId: sessionId).similarityMap
    }

    /// TS: buildPhotoGroupIndex —— 每张照片的组索引，每（会话, 结果版本）解析
    /// 一次并被每次更新点击复用：成员表在结果替换之间不可变，故只在版本变化时
    /// 重建。调用方可传入已解析的 lookup（见 ensureUpdateExtras），版本解析查询
    /// 每构建只跑一次。
    private func buildPhotoGroupIndex(
        photos: [CullingPhotoRow],
        sessionId: String,
        lookup: SessionLookupEntry
    ) throws -> [String: String] {
        if lookup.groupIndexResolved { return lookup.groupIndex }
        lookup.groupIndexResolved = true
        guard let resultRow = lookup.resultRow else { return lookup.groupIndex }

        // groups_json 是数据库内容；损坏或结构意外的行退化为空索引而不是让
        // updateState/batchUpdate 崩溃（TS 语义）。
        var groups: [[String: JSONValue]] = []
        if let parsed = try? JSONValue.parse(resultRow.groupsJson),
           case .object(let dict) = parsed,
           case .array(let items) = dict["groups"] {
            groups = items.compactMap {
                if case .object(let obj) = $0 { return obj }
                return nil
            }
        }
        let photoIdByPath = Dictionary(uniqueKeysWithValues: photos.map { ($0.filepath, $0.id) })
        var groupByPhotoId: [String: String] = [:]
        for (index, group) in groups.enumerated() {
            guard case .array(let images)? = group["images"] else { continue }
            for image in images {
                guard case .object(let imageObj) = image,
                      let path = imageObj["path"]?.stringValue,
                      let photoId = photoIdByPath[path] else { continue }
                groupByPhotoId[photoId] = "\(resultRow.id):\(index)"
            }
        }
        lookup.groupIndex = groupByPhotoId
        return lookup.groupIndex
    }
    /// TS: buildPhotosByAssetIndex —— asset_id → 照片索引，每次缓存更新上下文
    /// 构建一次，updateState 的按资产变体扫描（pick-state 补丁）变成 map 查找。
    /// 无 asset_id 的照片跳过：扫描只匹配共享真实 asset_id 的照片。
    private func buildPhotosByAssetIndex(
        _ photos: [CullingPhotoRow]
    ) -> [String: [CullingPhotoRow]] {
        var photosByAssetId: [String: [CullingPhotoRow]] = [:]
        for photo in photos {
            guard let assetId = photo.assetId else { continue }
            photosByAssetId[assetId, default: []].append(photo)
        }
        return photosByAssetId
    }
}
