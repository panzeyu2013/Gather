// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataKeywordWriter.swift
// 关键词预览 / delta / 重试（#6 S5：从 MetadataService 切出的最后一刀）。
//
// 硬约束（原实现注释逐条写过原因，搬移时一条未改）：
// - applyKeywordDelta 必须**先全量预检**（keywordPreview），阻断即整体抛错、一行都不入队；
// - 预检通过后**必须 flush**，即便本次没有新入队（上一次的队列可能还没写）；
// - 单一会话约束：applyKeywordDelta 只接受同一会话的照片，而属性写回是按会话多次
//   flush——这是**有意不对称**，不许"统一"；
// - retryKeywordWriteback 优先用 retryFlush，回落到 flushPending。
//
// 命名说明：字段带 Store 后缀（xmpStore / cacheStore），因为被搬来的方法体里有
// 同名局部（let xmp = ...、let cache = ...），裸名会互相遮蔽。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

public struct MetadataKeywordWriter: Sendable {
    private let photoRepo: any PhotoRepository
    private let xmpStore: any XMPProvider
    private let cacheStore: any MetadataRepository
    private let mutations: any MetadataMutationPort
    private let flushPending: MetadataQueueFlush?
    private let retryFlush: MetadataQueueFlush?
    private let origins: MetadataKeywordOriginRepo?
    private let assetResolver: PhotoAssetResolver?

    public init(
        photoRepo: any PhotoRepository,
        xmp: any XMPProvider,
        cache: any MetadataRepository,
        mutations: any MetadataMutationPort,
        flushPending: MetadataQueueFlush?,
        retryFlush: MetadataQueueFlush?,
        origins: MetadataKeywordOriginRepo?,
        assetResolver: PhotoAssetResolver?
    ) {
        self.photoRepo = photoRepo
        self.xmpStore = xmp
        self.cacheStore = cache
        self.mutations = mutations
        self.flushPending = flushPending
        self.retryFlush = retryFlush
        self.origins = origins
        self.assetResolver = assetResolver
    }

    public func sessionId(forPhotoIds photoIds: [String]) throws -> String? {
        try photoRepo.getLookupByIds(photoIds).first?.sessionId
    }

    /// 预览/应用共用的结果：预览面 + 结构化阻断（不靠字符串解析 errorMessage）。
    private struct KeywordPreviewOutcome {
        let preview: WritebackPreview
        let blockedKeyword: String?
        let blockedSource: MetadataMutationSource?
        let readFailedPath: String?
        /// xmpPath → fold(keyword) → 生成来源；apply 直接复用，避免二次查库。
        let ownedByXmp: [String: [String: Set<MetadataMutationSource>]]
    }

    /// 只读预览：不 create/reopen/upsert 任何 delivery 行；预览与 apply 共用 planner。
    public func previewKeywords(
        photoIds: [String],
        added: [String],
        removed: [String],
        conflictedXmpPaths: Set<String> = []
    ) async throws -> WritebackPreview {
        try await keywordPreview(
            photoIds: photoIds,
            added: added,
            removed: removed,
            conflictedXmpPaths: conflictedXmpPaths
        ).preview
    }

    private func keywordPreview(
        photoIds: [String],
        added: [String],
        removed: [String],
        conflictedXmpPaths: Set<String>
    ) async throws -> KeywordPreviewOutcome {
        let photos = try photoRepo.getLookupByIds(photoIds)
        guard !photos.isEmpty else {
            return KeywordPreviewOutcome(
                preview: WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0),
                blockedKeyword: nil,
                blockedSource: nil,
                readFailedPath: nil,
                ownedByXmp: [:]
            )
        }
        // 未知/重复 id 不能静默忽略（否则结果条 0/0/0，用户以为写成功）。
        guard Set(photoIds).count == photoIds.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must be unique")
        }
        guard photos.count == photoIds.count else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "contains unknown photo ids")
        }
        // 预览与 apply 同一会话边界，避免“预览成功、确认后 apply 拒绝”。
        let sessionIds = Set(photos.map(\.sessionId))
        guard sessionIds.count == 1 else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "must belong to one session")
        }
        let targets = try keywordTargets(photos)
        // 生成词保护：一次批量读 origin，Swift 侧 fold 比对（大小写/NFC 差异不绕过）。
        var ownedByXmp: [String: [String: Set<MetadataMutationSource>]] = [:]
        if !removed.isEmpty, let origins {
            let removedKeys = Set(removed.map(KeywordNormalizer.fold))
            let paths = targets.map(\.xmpPath)
            for source in MetadataMutationSource.allCases where source != .manual {
                for row in try origins.activeKeywordOrigins(
                    xmpPaths: paths, source: source.rawValue
                ) {
                    let key = KeywordNormalizer.fold(row.keyword)
                    guard removedKeys.contains(key) else { continue }
                    ownedByXmp[row.xmpPath, default: [:]][key, default: []].insert(source)
                }
            }
        }

        // 500 张/共享 sidecar 时串行读 XMP 是秒级；按 8 路分块并发读，保持原顺序。
        let snapshots = await readKeywordSnapshots(targets)
        var items: [WritebackItem] = []
        var blockedKeyword: String?
        var blockedSource: MetadataMutationSource?
        var readFailedPath: String?
        for target in targets {
            let snapshot = snapshots[target.xmpPath]
            let disk = snapshot?.0 ?? []
            let readFailed = snapshot?.1 ?? true
            let cachedRow: MetadataCacheRow?
            do { cachedRow = try cacheStore.get(target.photo.id) } catch { cachedRow = nil }
            let cachedKeywords = cachedRow?.keywords ?? []
            // origin 可能比磁盘陈旧（外部已删词）：只把盘上仍存在的词视为 owned，
            // 避免 K0 误报 KEYWORD_OWNED_BY_SOURCE。
            let activeOwned = (ownedByXmp[target.xmpPath] ?? [:]).filter { key, _ in
                disk.contains { KeywordNormalizer.fold($0) == key }
            }
            let plan = KeywordPlanner.plan(
                existing: disk,
                added: added,
                removed: removed,
                owned: activeOwned
            )
            let externalChanged = (cachedRow != nil
                && KeywordNormalizer.dedupe(cachedKeywords)
                    != KeywordNormalizer.dedupe(disk))
                || conflictedXmpPaths.contains(target.xmpPath)
            let blocked = plan.blocked.first
            let status: String
            let message: String
            if readFailed {
                status = "failed"
                message = "XMP_READ_FAILED"
                if readFailedPath == nil { readFailedPath = target.filepath }
            } else if let blocked {
                status = "blocked"
                message = "KEYWORD_OWNED_BY_SOURCE:\(blocked.keyword):"
                    + (blocked.sources.first?.rawValue ?? "")
                if blockedKeyword == nil {
                    blockedKeyword = blocked.keyword
                    blockedSource = blocked.sources.first
                }
            } else {
                status = "pending"
                message = ""
            }
            let preview = WritebackItemPreview(
                dirtyFields: blocked == nil && !readFailed ? [.keywords] : [],
                before: WritebackAttributes(keywords: disk),
                after: WritebackAttributes(keywords: plan.after),
                source: "metadata",
                sharedPhotoCount: target.sharedPhotoCount,
                externalChanged: externalChanged,
                willCreate: !xmpStore.fileExists(target.xmpPath)
            )
            items.append(WritebackItem(
                photoId: target.photo.id,
                photoPath: target.filepath,
                sessionId: target.photo.sessionId,
                module: "metadata",
                keywords: plan.after,
                attributes: nil,
                xmpPath: target.xmpPath,
                backupPath: "",
                xmpStatus: status,
                errorMessage: message,
                attemptCount: 0,
                lastAttemptAt: "",
                preview: preview
            ))
        }
        let preview = WritebackPreview(
            items: items, totalCount: items.count, affectedPhotos: photoIds.count)
        return KeywordPreviewOutcome(
            preview: preview,
            blockedKeyword: blockedKeyword,
            blockedSource: blockedSource,
            readFailedPath: readFailedPath,
            ownedByXmp: ownedByXmp
        )
    }

    /// 按 sidecar 分组、每个 sidecar 一次 delta 入队，最后统一 flush 一次。
    public func applyKeywordDelta(
        photoIds: [String],
        added: [String],
        removed: [String]
    ) async throws -> WritebackResult {
        let photos = try photoRepo.getLookupByIds(photoIds)
        guard !photos.isEmpty else { return emptyKeywordResult() }
        guard Set(photoIds).count == photoIds.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must be unique")
        }
        guard photos.count == photoIds.count else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "contains unknown photo ids")
        }
        // 一次关键词 apply 只处理一个会话：跨 session 静默只 flush 最后一个会留下 pending。
        let sessionIds = Set(photos.map(\.sessionId))
        guard sessionIds.count == 1, let sid = sessionIds.first else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "must belong to one session")
        }
        // 全量预检：任一 target 因来源保护/读取失败不可写时，先整体拒绝。
        // 预览面同时提供结构化阻断信息与盘上快照，避免二次读盘/字符串解析。
        var snapshots: [String: [String]] = [:]
        var ownedByXmp: [String: [String: Set<MetadataMutationSource>]] = [:]
        if !removed.isEmpty {
            let preflight = try await keywordPreview(
                photoIds: photoIds, added: added, removed: removed, conflictedXmpPaths: [])
            for item in preflight.preview.items {
                if let before = item.preview?.before.keywords {
                    snapshots[item.photoId] = before
                }
            }
            if let keyword = preflight.blockedKeyword {
                throw GatherError(
                    code: .KEYWORD_OWNED_BY_SOURCE,
                    params: [
                        "keyword": keyword,
                        "source": preflight.blockedSource?.rawValue ?? "",
                    ])
            }
            if let path = preflight.readFailedPath {
                throw GatherError(
                    code: .XMP_DOCUMENT_READ_FAILED, params: ["path": path])
            }
            ownedByXmp = preflight.ownedByXmp
        }
        let targets = try keywordTargets(photos)
        for target in targets {
            // RAW/JPEG 共享 sidecar：每个 sidecar 只入队一次（首张照片作为 item 身份）。
            _ = try await mutations.queueKeywordDelta(
                sessionId: target.photo.sessionId,
                photoId: target.photo.id,
                added: added,
                removed: removed,
                owned: ownedByXmp[target.xmpPath] ?? [:],
                existingKeywords: snapshots[target.photo.id]
            )
        }
        // 没有新入队也必须 flush：上一次入队可能停在 pending/failed，
        // 否则第二次“确认写入”会拿 0/0 当成功并清掉草稿、丢失重试入口。
        guard let flushPending else { return emptyKeywordResult() }
        let result = try await flushPending(sid)
        // 写后回读并回填 cache（读不到保留旧 cache，不拿空值覆盖）。
        // 同一 sidecar 可能还有不在本次请求里的兄弟变体（只选 RAW 写词时 JPEG 不在
        // keywordTargets 里）；按会话投影建立 xmpPath → 全部 photoId，避免面板旧词。
        var siblingIds: [String: [String]] = [:]
        do {
            for row in try photoRepo.getBySessionProjection(sessionId: sid) {
                let xmpPath = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
                siblingIds[xmpPath, default: []].append(row.id)
            }
        } catch {
            GatherLogger.log("load session photos for keyword cache refill failed: \(error)", level: .warn)
        }
        for target in targets {
            do {
                let keywords = try await xmpStore.readKeywords(photoPath: target.filepath)
                let ids = siblingIds[target.xmpPath] ?? target.photoIds
                for photoId in ids {
                    try cacheStore.updateKeywords(photoId: photoId, keywords: keywords)
                }
            } catch {
                continue
            }
        }
        return result
    }

    public func retryKeywordWriteback(sessionId: String) async throws -> WritebackResult {
        guard let flush = retryFlush ?? flushPending else { return emptyKeywordResult() }
        return try await flush(sessionId)
    }

    private struct KeywordTarget {
        let photo: MetadataPhotoLookup
        let filepath: String
        let xmpPath: String
        let sharedPhotoCount: Int
        let photoIds: [String]
    }

    private func readKeywordSnapshots(
        _ targets: [KeywordTarget]
    ) async -> [String: ([String], Bool)] {
        var result: [String: ([String], Bool)] = [:]
        let batchSize = 8
        var start = 0
        while start < targets.count {
            let end = min(targets.count, start + batchSize)
            let chunk = Array(targets[start..<end])
            await withTaskGroup(of: (String, [String], Bool).self) { group in
                for target in chunk {
                    let xmpPath = target.xmpPath
                    let filepath = target.filepath
                    group.addTask {
                        do {
                            let keywords = try await xmpStore.readKeywords(photoPath: filepath)
                            return (xmpPath, keywords, false)
                        } catch {
                            return (xmpPath, [], true)
                        }
                    }
                }
                for await item in group {
                    result[item.0] = (item.1, item.2)
                }
            }
            start = end
        }
        return result
    }

    private func keywordTargets(_ photos: [MetadataPhotoLookup]) throws -> [KeywordTarget] {
        var resolved: [String: ResolvedPhotoAsset] = [:]
        if let assetResolver {
            let bySession = Dictionary(grouping: photos, by: \.sessionId)
            for (sessionId, rows) in bySession {
                resolved.merge(
                    try assetResolver.resolveMany(sessionId: sessionId, photoIds: rows.map(\.id))
                ) { first, _ in first }
            }
        }
        var order: [String] = []
        var first: [String: (photo: MetadataPhotoLookup, filepath: String)] = [:]
        var counts: [String: Int] = [:]
        var idsByXmp: [String: [String]] = [:]
        for photo in photos {
            let asset = resolved[photo.id]
            let filepath = asset?.filepath ?? photo.filepath
            let xmpPath = TSPath.normalize(asset?.xmpPath ?? TSPath.xmpSidecarPath(filepath))
            if first[xmpPath] == nil {
                order.append(xmpPath)
                first[xmpPath] = (photo, filepath)
            }
            counts[xmpPath, default: 0] += 1
            idsByXmp[xmpPath, default: []].append(photo.id)
        }
        return order.compactMap { xmpPath in
            guard let entry = first[xmpPath] else { return nil }
            return KeywordTarget(
                photo: entry.photo,
                filepath: entry.filepath,
                xmpPath: xmpPath,
                sharedPhotoCount: counts[xmpPath] ?? 1,
                photoIds: idsByXmp[xmpPath] ?? []
            )
        }
    }

    private func emptyKeywordResult() -> WritebackResult {
        WritebackResult(
            totalAffected: 0, written: 0, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )
    }
}
