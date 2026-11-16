// desktop/native/gather-core/Sources/GatherApplication/Services/Semantic/SemanticKeywordService.swift
// Wave2 / task-14：把 photo_semantics 的 Vision 标签落成**可检索的关键词**
//（场景标签闭环：采集 → 写回 → facet / 语义检索 / 图库筛选）。
//
// 设计约束（与 50-ai-culling.md Top3 ② 对齐）：
// - 映射是**确定性纯函数**（labelSet → keyword_path 集合），因此：
//   预览、写回、撤销三处算出的集合天然一致，不需要额外存批次明细；
// - 幂等：写回前用 photo_keywords 的现有路径做差集，同一张重复跑不会重复加词；
// - 撤销 = 移除 root 子树下的关键词（`remove: true`），只动这一棵子树，
//   不碰人工/人脸/相似度来源的关键词；
// - 写盘仍然走既有的关键词交付链（MetadataService.applyKeywordDelta：
//   预检 → 入队 → flush → 回读回填 cache），本服务不直接碰 XMP。
import Foundation
import GatherProtocol
import GatherPersistence

public enum SemanticKeywordError: Error, Equatable, CustomStringConvertible, Sendable {
    /// 传入的 photoIds 里有不属于该会话/不存在的照片（跨会话会写错 sidecar，必须拒绝）。
    case unknownPhotoIds
    case invalidRoot(String)

    public var description: String {
        switch self {
        case .unknownPhotoIds: "SEMANTIC_KEYWORD_UNKNOWN_PHOTO"
        case .invalidRoot(let root): "SEMANTIC_KEYWORD_INVALID_ROOT(\(root))"
        }
    }

    /// API 边界复用既有错误码（不新增码表项）。
    public var code: GatherErrorCode {
        .INVALID_PARAM
    }
}

// 不声明 Sendable：PhotoSemanticsStore 端口本身不是 Sendable（与 SemanticIndex 同款），
// 宿主 LivePhotoAPI 已是 @unchecked Sendable（同一条组合根约定），这里不新增逃逸口。
public struct SemanticKeywordService {
    private let semantics: any PhotoSemanticsStore
    private let metadata: MetadataService
    private let keywords: KeywordRepo
    private let indexSync: KeywordIndexSync
    private let photoRepo: any PhotoRepository

    public init(
        semantics: any PhotoSemanticsStore,
        metadata: MetadataService,
        keywords: KeywordRepo,
        indexSync: KeywordIndexSync,
        photoRepo: any PhotoRepository
    ) {
        self.semantics = semantics
        self.metadata = metadata
        self.keywords = keywords
        self.indexSync = indexSync
        self.photoRepo = photoRepo
    }

    // MARK: - 纯映射（测试直接驱动）

    /// Vision 标签 → 规范化关键词段。规则要让"同一标签两次编码结果一致"：
    /// 小写、下划线换空格、压缩空白、去首尾、截断、丢弃空串。
    public static func normalizeLabel(_ raw: String) -> String? {
        let lowered = raw.lowercased().replacingOccurrences(of: "_", with: " ")
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 关键词里不允许出现层级分隔符（`|`），否则一段标签会被拆成两级。
        let sanitized = trimmed.replacingOccurrences(of: "|", with: " ")
        guard !sanitized.isEmpty else { return nil }
        if sanitized.count <= SemanticKeywordPath.maxLabelLength { return sanitized }
        return String(sanitized.prefix(SemanticKeywordPath.maxLabelLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// 标签集合 → 完整 keyword_path（含 root），按置信度降序取前 N、去重、稳定排序。
    ///
    /// 路径段固定为 Vision 英文标签（可逆映射）；中文显示名只在 UI
    /// （SemanticLabelCatalog），**不写入**路径/XMP。
    public static func keywordPaths(
        labels: [SemanticLabel],
        root: String = SemanticKeywordPath.scene,
        maxPerPhoto: Int = SemanticKeywordPath.maxLabelsPerPhoto
    ) -> [String] {
        let root = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return [] }
        let limit = max(0, maxPerPhoto)
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var paths: [String] = []
        // SemanticLabel 的 Comparable 是「置信度降序、同名升序」，直接排序即稳定。
        for label in labels.sorted() {
            guard let segment = normalizeLabel(label.label) else { continue }
            let key = segment.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            paths.append("\(root)|\(segment)")
            if paths.count >= limit { break }
        }
        return paths
    }

    /// 该路径是否在 root 子树内（root 自身也算）。
    public static func isUnder(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "|")
    }

    // MARK: - 预览

    public func plan(_ input: SemanticKeywordPlanInput) throws -> SemanticKeywordPlan {
        let root = try validatedRoot(input.root)
        let scope = try resolvePhotos(sessionId: input.sessionId, photoIds: input.photoIds)
        guard !scope.isEmpty else {
            return SemanticKeywordPlan(
                sessionId: input.sessionId, root: root, items: [],
                photosWithLabels: 0, photosWithoutLabels: 0, totalAdditions: 0,
                unavailableReason: "会话中没有照片")
        }
        let rows = try semantics.loadRows(sessionId: input.sessionId, photoIds: scope)
        let labelsByPhoto = Dictionary(
            rows.map { ($0.photoId, SemanticIndex.decodeLabels($0.labelsJson)) },
            uniquingKeysWith: { first, _ in first })
        return try Self.buildPlan(
            sessionId: input.sessionId,
            root: root,
            scope: scope,
            labelsByPhoto: labelsByPhoto,
            currentPaths: { try keywords.photoKeywordPaths(photoId: $0) },
            maxLabelsPerPhoto: input.maxLabelsPerPhoto,
            maxItems: input.maxItems,
            semanticsAvailable: !rows.isEmpty)
    }

    /// 纯计划计算（无 I/O 依赖，测试直接驱动）：`currentPaths` 给出现有关键词路径，
    /// 计划里只留"还缺的"——这就是"同一张重复跑不重复加词"的幂等来源。
    public static func buildPlan(
        sessionId: String,
        root: String,
        scope: [String],
        labelsByPhoto: [String: [SemanticLabel]],
        currentPaths: (String) throws -> [String],
        maxLabelsPerPhoto: Int,
        maxItems: Int = 0,
        semanticsAvailable: Bool
    ) rethrows -> SemanticKeywordPlan {
        var items: [SemanticKeywordPlanItem] = []
        var withLabels = 0
        var withoutLabels = 0
        var additions = 0
        for photoId in scope {
            let labels = labelsByPhoto[photoId] ?? []
            let desired = keywordPaths(
                labels: labels, root: root, maxPerPhoto: maxLabelsPerPhoto)
            if desired.isEmpty {
                withoutLabels += 1
                continue
            }
            withLabels += 1
            let current = Set(try currentPaths(photoId))
            let missing = desired.filter { !current.contains($0) }
            additions += missing.count
            items.append(SemanticKeywordPlanItem(
                photoId: photoId, keywords: missing, alreadyPresent: missing.isEmpty))
        }
        // Wave4b：明细可截断（UI 预览只取前 N 张，避免 2 万条 IPC 大对象）；
        // 计数（totalAdditions/photosWithLabels）永远按全量算，截断只影响 items。
        let limit = max(0, maxItems)
        let truncated = limit > 0 && items.count > limit
        let visibleItems = truncated ? Array(items.prefix(limit)) : items
        return SemanticKeywordPlan(
            sessionId: sessionId, root: root, items: visibleItems,
            photosWithLabels: withLabels, photosWithoutLabels: withoutLabels,
            totalAdditions: additions,
            itemsTruncated: truncated,
            unavailableReason: semanticsAvailable
                ? nil
                : "语义索引未建立（先在设置里开启语义索引并跑一次质量分析）")
    }

    // MARK: - 写回 / 撤销

    public func apply(_ input: SemanticKeywordApplyInput) async throws -> SemanticKeywordApplyResult {
        let root = try validatedRoot(input.root)
        let scope = try resolvePhotos(sessionId: input.sessionId, photoIds: input.photoIds)
        let batchId = UUID().uuidString
        if input.remove {
            return try await remove(scope: scope, sessionId: input.sessionId, root: root, batchId: batchId)
        }
        let plan = try plan(SemanticKeywordPlanInput(
            sessionId: input.sessionId,
            photoIds: scope,
            root: root,
            maxLabelsPerPhoto: input.maxLabelsPerPhoto))
        // 同关键词集合的照片合并成一次交付（写盘按 sidecar 分组，逐张调用会重复 flush）。
        var groups: [String: [String]] = [:]
        for item in plan.items where !item.keywords.isEmpty {
            let key = item.keywords.joined(separator: "\u{1F}")
            groups[key, default: []].append(item.photoId)
        }
        var applied = 0
        var added = 0
        var failed: [String] = []
        // E2：这批**实际写到**的照片，随结果返回给 UI 作为撤销 scope（真批级撤销）。
        var appliedPhotoIds: [String] = []
        for (key, photoIds) in groups {
            let keywordList = key.split(separator: "\u{1F}").map(String.init)
            do {
                _ = try await metadata.applyKeywordDelta(
                    photoIds: photoIds, added: keywordList, removed: [])
                for photoId in photoIds {
                    // 写盘后回填索引（cache 已回读）；失败只影响 facet 的即时性，
                    // 不把整批标失败（下一次质量分析/回填会收敛）。
                    _ = try? indexSync.syncFromCache(photoId: photoId)
                }
                applied += photoIds.count
                added += keywordList.count * photoIds.count
                appliedPhotoIds.append(contentsOf: photoIds)
            } catch {
                failed.append(contentsOf: photoIds)
            }
        }
        let skipped = max(0, scope.count - applied - failed.count)
        return SemanticKeywordApplyResult(
            sessionId: input.sessionId,
            appliedPhotos: applied,
            appliedPhotoIds: appliedPhotoIds.sorted(),
            skippedPhotos: skipped,
            keywordsAdded: added,
            keywordsRemoved: 0,
            batchId: batchId,
            failedPhotoIds: failed.sorted())
    }

    private func remove(
        scope: [String], sessionId: String, root: String, batchId: String
    ) async throws -> SemanticKeywordApplyResult {
        var applied = 0
        var removed = 0
        var failed: [String] = []
        var appliedPhotoIds: [String] = []
        // 按"要移除的路径集合"分组：同集合照片合并成一次交付（与 apply 对称），
        // 避免大会话 undo 逐张预检 + flush（P2）。
        var groups: [String: [String]] = [:]
        for photoId in scope {
            let owned = try keywords.photoKeywordPaths(photoId: photoId)
                .filter { Self.isUnder($0, root: root) }
            guard !owned.isEmpty else { continue }
            let key = owned.joined(separator: "\u{1F}")
            groups[key, default: []].append(photoId)
        }
        for (key, photoIds) in groups {
            let removedPaths = key.split(separator: "\u{1F}").map(String.init)
            do {
                _ = try await metadata.applyKeywordDelta(
                    photoIds: photoIds, added: [], removed: removedPaths)
                for photoId in photoIds {
                    _ = try? indexSync.syncFromCache(photoId: photoId)
                }
                applied += photoIds.count
                removed += removedPaths.count * photoIds.count
                appliedPhotoIds.append(contentsOf: photoIds)
            } catch {
                failed.append(contentsOf: photoIds)
            }
        }
        return SemanticKeywordApplyResult(
            sessionId: sessionId,
            appliedPhotos: applied,
            appliedPhotoIds: appliedPhotoIds.sorted(),
            skippedPhotos: max(0, scope.count - applied - failed.count),
            keywordsAdded: 0,
            keywordsRemoved: removed,
            batchId: batchId,
            failedPhotoIds: failed.sorted())
    }

    // MARK: - 内部

    private func validatedRoot(_ raw: String) throws -> String {
        let root = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 根不能为空、不能以分隔符开头/结尾（"AI|场景|" 会造出空段路径）。
        guard !root.isEmpty, !root.hasPrefix("|"), !root.hasSuffix("|"),
              !root.contains("||") else {
            throw SemanticKeywordError.invalidRoot(raw)
        }
        return root
    }

    /// 解析作用域照片：nil = 会话全部可见照片；非 nil = 校验都在同一会话。
    private func resolvePhotos(sessionId: String, photoIds: [String]?) throws -> [String] {
        let all = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .filter { $0.status != "missing" }
            .map(\.id)
        guard let photoIds else { return all }
        let requested = Set(photoIds)
        guard !requested.isEmpty else { return [] }
        let scoped = all.filter { requested.contains($0) }
        guard scoped.count == requested.count else {
            // 跨会话/不存在的 id 都在这里拒绝：写错 sidecar 比不写更糟。
            throw SemanticKeywordError.unknownPhotoIds
        }
        return scoped
    }
}
