// desktop/native/gather-core/Sources/GatherDelivery/Writeback/MetadataMutationService.swift
// 变更入队服务（S5c-2b-3b-2b-2：outbox → 统一交付模型）。
//
// 唯一写路径的入口：queuePhotoValues 只写 deliveries / delivery_items（先落库），
// 本文件绝不直接触碰 XMP 侧车；刷盘由交付执行器（WritebackService）或
// DeliveryCoordinator 在 preview/execute/retry/cleanup 时消费 pending 项。
//
// 与旧实现的差异（D-089 / S5c-2b-3b-2b-2）：
// - 持久化从 metadata_outbox.patch_json 改为 delivery_items：
//   rating/label → attributes_json（可写字段白名单与契约层 MetadataField 同源）；
//   keywords → keywords 列（完整期望词表；append 写 keywords_mode=merge，
//   replace/remove 写 keywords_mode=replace，执行器按 mode 决定并集还是权威覆盖）。
// - 每次入队是一次「新输入」：交付行 revision + 1 并回到 pending（旧 mergePatch
//   的同一语义；旧 revision 的写盘 CAS 因此不会覆盖新输入），**基线保持不变**
//   （真实基线由执行器写盘后回读落库）。
// - 开行 + 合并 item + 链接会话是**一个** DeliveryRepo 事务（P1-3）：任一步失败
//   整体回滚，revision 不推进、不留无 item 的 pending 或孤儿 item。
// - 会话链接写 delivery_sessions（conflicts 按会话反查交付的唯一依据）。
// - 排程：交付模型没有去抖计时器——交付行/项停在 pending 就是排程状态，
//   由执行器按需消费；schedule 参数只为调用方签名不变而保留（两种取值落库一致）。
//
// 串行化：queueKeywordDelta 的"读当前文件 → 合并 delta → 入队"必须按 xmpPath 串行，
// 旧实现用「字典存 Task + AnyObject 身份比较」判定尾结点（身份恒 false →
// 条目永不回收、错误沿链传播）。新实现改为 actor PathSerialChain + 单调 token：
//   - token 判定尾结点，条目在最后一回合结束时回收（无无界增长）；
//   - 每回合错误只回给本回合调用方，不再污染后续独立变更；
//   - 路径一律经 TSPath.normalize 归一化（与 DeliveryRepo 的落库键同一口径）。

import Foundation
import GatherProtocol
import GatherPersistence

/// TS: metadata-mutation.service.ts 抛出的错误码。
public enum MetadataMutationError: Error, Equatable, CustomStringConvertible {
    case empty // METADATA_MUTATION_EMPTY
    case unsupportedField(String) // METADATA_MUTATION_UNSUPPORTED_FIELD

    public var description: String {
        switch self {
        case .empty: "METADATA_MUTATION_EMPTY"
        case .unsupportedField(let field): "METADATA_MUTATION_UNSUPPORTED_FIELD: " + field
        }
    }
}

/// WritebackService / MetadataService 依赖的变更服务最小面。
public protocol MetadataMutationPort: Sendable {
    /// TS: queuePhotoValues（schedule 默认 true）。
    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult

    /// K0：按 delta（added/removed）入队；返回 nil 表示无变化。
    func queueKeywordDelta(
        sessionId: String,
        photoId: String,
        added: [String],
        removed: [String],
        owned: [String: Set<MetadataMutationSource>],
        existingKeywords: [String]?
    ) async throws -> MetadataMutationResult?
}

public extension MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource
    ) throws -> MetadataMutationResult {
        try queuePhotoValues(
            sessionId: sessionId, photoId: photoId, values: values, source: source, schedule: true)
    }

    /// 默认实现：旧测试替身不支持 delta 时显式失败，绝不静默丢词。
    func queueKeywordDelta(
        sessionId: String,
        photoId: String,
        added: [String],
        removed: [String],
        owned: [String: Set<MetadataMutationSource>],
        existingKeywords: [String]? = nil
    ) async throws -> MetadataMutationResult? {
        throw MetadataMutationError.unsupportedField("keywords_delta")
    }
}

/// delivery_items.attributes_json 里的关键词写入模式键（不改 schema）。
///
/// 旧协调器按 patch 里的关键词**权威覆盖**写盘；交付执行器默认把项里的关键词
/// 与盘上现状做并集（culling/人脸/相似度的"只增不删"语义）。手动元数据的
/// replace/remove 需要前者，因此把意图落进 attributes_json：
/// - "merge"：与盘上现状并集（append）；
/// - "replace"：以项里的 keywords 为权威列表（replace / remove / 直接给全量）。
/// 缺省（其他模块的项）按 merge 处理，行为与迁移前完全一致。
public enum MetadataKeywordWriteMode: String, Sendable, Equatable {
    case merge
    case replace
    /// K0：执行器在文件锁内按 (disk ∪ added) − removed 合并；attributes_json
    /// 额外携带 keywords_added / keywords_remove。
    case delta
}

public final class MetadataMutationService: MetadataMutationPort {
    /// attributes_json 中保存写入模式的键（不属于用户可写字段，执行器内部读取）。
    public static let keywordsModeKey = "keywords_mode"

    private let deliveryRepo: DeliveryRepo
    /// 交付状态写入的唯一入口（WP2b）：applyMetadataMutation 的复合事务仍由 Repo 执行。
    private let stateWriter: DeliveryStateWriter
    private let xmp: any XMPProvider
    private let assetResolver: PhotoAssetResolver
    private let chain = PathSerialChain()

    public init(
        deliveryRepo: DeliveryRepo,
        xmp: any XMPProvider,
        assetResolver: PhotoAssetResolver
    ) {
        self.deliveryRepo = deliveryRepo
        self.stateWriter = DeliveryStateWriter(repo: deliveryRepo)
        self.xmp = xmp
        self.assetResolver = assetResolver
    }

    /// TS: queuePhotoValues —— 值直写合并进交付项并等待执行器刷盘。
    /// 字段级合并由 Repo.mergeItem 保证：后者覆盖同名字段，未提及字段保留。
    ///
    /// 关键词语义：调用方给的是**完整列表**（旧 patch 语义），按权威覆盖写盘；
    /// 未提供关键词时不改动现有词表与模式。
    public func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool = true
    ) throws -> MetadataMutationResult {
        // 排程语义（契约保留）：交付行回到 pending 就是排程；没有计时器。
        _ = schedule
        let requested = values[Self.keywordsModeKey]?.stringValue
            .flatMap(MetadataKeywordWriteMode.init(rawValue:))
        return try enqueue(
            sessionId: sessionId,
            photoId: photoId,
            values: values,
            keywordsMode: requested ?? .replace
        )
    }

    /// 入队的唯一实现：queuePhotoValues 与关键词 delta 只在关键词模式上不同。
    ///
    /// - values 的契约字段之外的键被丢弃（旧 filter/compactMap 的同一规则）；
    /// - 交付行先按「新输入」重开（revision + 1 → pending，基线不变）；
    /// - 项字段级合并后写 pending；随后链接会话（conflicts 按会话反查）。
    private func enqueue(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        keywordsMode: MetadataKeywordWriteMode,
        extraAttributes: [String: JSONValue] = [:]
    ) throws -> MetadataMutationResult {
        let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        // 可写字段名集合的唯一真相源是 MetadataField（契约层枚举）；
        // filter 与 compactMap 同为「非契约字段丢弃」，保留调用方键序不变。
        // P1：descriptive / triageSignal 不是独立 MetadataField，但属于可写载荷
        // （字段级粒度由 DescriptiveMetadata 承担）。
        let internalWritableKeys: Set<String> = ["triageSignal"]
        let dirtyFields = values.keys
            .filter { MetadataField.writableNames.contains($0) || internalWritableKeys.contains($0) }
            .compactMap { MetadataField(rawValue: $0) ?? ($0 == "triageSignal" ? .descriptive : nil) }
        if dirtyFields.isEmpty {
            throw MetadataMutationError.empty
        }
        let xmpPath = TSPath.normalize(resolved.xmpPath)
        var attributes: [String: JSONValue] = [:]
        if let rating = values["rating"] { attributes["rating"] = rating }
        if let label = values["label"] { attributes["label"] = label }
        if let descriptive = values["descriptive"] { attributes["descriptive"] = descriptive }
        if let triageSignal = values["triageSignal"] { attributes["triageSignal"] = triageSignal }
        if values["replace_contact"]?.boolValue == true {
            attributes["replace_contact"] = .bool(true)
        }
        let keywords = values["keywords"]?.arrayElements?.compactMap { $0.stringValue }
        if keywords != nil {
            attributes[Self.keywordsModeKey] = .string(keywordsMode.rawValue)
        } else {
            // 不带关键词的新输入必须清掉上一次 delta 的意图，否则执行器会重放
            // 旧的 keywords_added/remove（复活外部已删词、删掉外部新词）。
            attributes[Self.keywordsModeKey] = .string(MetadataKeywordWriteMode.merge.rawValue)
            attributes["keywords_added"] = .array([])
            attributes["keywords_remove"] = .array([])
        }
        for (key, value) in extraAttributes {
            attributes[key] = value
        }
        // P1-3：开行（mergeInput）+ 合并 item + 链接会话必须同一事务提交。
        // 分三步各自提交时，中间失败会留下 revision 已 +1、没有任何 item/link 的
        // 幽灵 pending（永久阻断该侧车其它模块 confirm），或 linkSession 的 FK
        // 拒绝后留下孤儿 pending item。原子入口在 DeliveryRepo 内完成，
        // 失败整体回滚（revision 不推进、无 item / delivery_sessions 行）。
        // 首次入队时记录写前指纹：执行器在 plan→write 窗口内检测外部改动。
        let knownBase = try deliveryRepo.get(xmpPath)?.baseFingerprint ?? ""
        var base = knownBase
        if base.isEmpty {
            do { base = try MetadataFingerprint.contentFingerprintSync(xmpPath) } catch {}
        }
        let delivery = try stateWriter.enqueueMetadataMutation(
            xmpPath: xmpPath,
            photoPath: resolved.filepath,
            photoId: photoId,
            sessionId: sessionId,
            attributes: attributes,
            keywords: keywords,
            baseFingerprint: base
        )
        return MetadataMutationResult(
            photoId: photoId,
            xmpPath: delivery.xmpPath,
            dirtyFields: dirtyFields,
            revision: Int(delivery.revision),
            status: delivery.status
        )
    }

    /// K0：delta 入队。同一 xmpPath 串行；读盘/项内 pending 优先；无变化返回 nil。
    public func queueKeywordDelta(
        sessionId: String,
        photoId: String,
        added: [String],
        removed: [String],
        owned: [String: Set<MetadataMutationSource>],
        existingKeywords: [String]? = nil
    ) async throws -> MetadataMutationResult? {
        let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        let xmpPath = TSPath.normalize(resolved.xmpPath)
        return try await chain.run(path: xmpPath) {
            let diskKeywords: [String]
            if let existingKeywords {
                diskKeywords = existingKeywords
            } else {
                let current = try await self.xmp.readAttributes(photoPath: resolved.filepath)
                diskKeywords = current.keywords ?? []
            }
            // item 身份按 (xmpPath, module)：同一侧车换首张照片也必须复用同一行，
            // 否则 cumulative added/removed 丢失、同侧车被写两遍；DB 错误不再吞掉。
            let pendingItem = try self.deliveryRepo.item(xmpPath: xmpPath, module: .metadata)
            // 只有“尚未落盘”的 item（pending/failed）才能代表本地基线；written/synced
            // 的 item.keywords 是上一次写盘时的旧快照，外部在 C1 里新增的词不在其中，
            // 用它做基线会把“删除外部新增词”静默吞掉（plan.changed=false）。
            let pending: [String]? = pendingItem.flatMap { item in
                guard let status = item.typedStatus,
                      status == .pending || status == .failed,
                      !item.keywordList.isEmpty
                else { return nil }
                return item.keywordList
            }
            let existing = KeywordNormalizer.unique(pending ?? diskKeywords)
            let activeOwned = owned.filter { key, _ in
                existing.contains { KeywordNormalizer.fold($0) == key }
            }
            let plan = KeywordPlanner.plan(
                existing: existing, added: added, removed: removed, owned: activeOwned)
            guard plan.blocked.isEmpty else {
                let blocked = plan.blocked[0]
                throw GatherError(
                    code: .KEYWORD_OWNED_BY_SOURCE,
                    params: [
                        "keyword": blocked.keyword,
                        "source": blocked.sources.first?.rawValue ?? "",
                    ]
                )
            }
            guard plan.changed else { return nil }
            // 只有 pending/failed 的 item 才携带"尚未落盘"的净意图；written/synced
            // 的旧 delta 已经落盘，再叠加会把外部后来删除的词复活。
            let priorAdded = pending == nil ? [] : (pendingItem?.attributes["keywords_added"]?
                .arrayElements?.compactMap(\.stringValue) ?? [])
            let priorRemoved = pending == nil ? [] : (pendingItem?.attributes["keywords_remove"]?
                .arrayElements?.compactMap(\.stringValue) ?? [])
            // 净意图以“本次 plan”为准：add→remove 要真正从 cumulativeAdded 删掉，
            // 否则盘上执行 disk∪added 时词会残留；remove→add 同理。
            let removedKeys = Set(plan.removed.map { KeywordNormalizer.fold($0) })
            let addedKeys = Set(plan.added.map { KeywordNormalizer.fold($0) })
            let cumulativeAdded = KeywordNormalizer.unique(priorAdded + plan.added)
                .filter { !removedKeys.contains(KeywordNormalizer.fold($0)) }
            let cumulativeRemoved = KeywordNormalizer.unique(priorRemoved + plan.removed)
                .filter { !addedKeys.contains(KeywordNormalizer.fold($0)) }
            return try self.enqueueKeywordDelta(
                sessionId: sessionId,
                photoId: pendingItem?.photoId ?? photoId,
                plan: plan,
                added: cumulativeAdded, removed: cumulativeRemoved)
        }
    }

    /// 专用入队：显式允许 keywords_added / keywords_remove 进 attributes_json；
    /// 普通 enqueue(values:) 会按 MetadataField.writableNames 丢弃这两个内部键。
    private func enqueueKeywordDelta(
        sessionId: String,
        photoId: String,
        plan: KeywordPlan,
        added: [String],
        removed: [String]
    ) throws -> MetadataMutationResult {
        try enqueue(
            sessionId: sessionId,
            photoId: photoId,
            values: ["keywords": .array(plan.after.map { JSONValue.string($0) })],
            keywordsMode: .delta,
            extraAttributes: [
                "keywords_added": .array(added.map { JSONValue.string($0) }),
                "keywords_remove": .array(removed.map { JSONValue.string($0) }),
            ]
        )
    }

}

/// 每路径串行链：等待前一回合完成后执行本回合；token 判定尾结点并回收条目。
actor PathSerialChain {
    private var tails: [String: Task<Void, Never>] = [:]
    private var tokens: [String: Int] = [:]
    private var nextToken = 0

    /// 在 path 上串行执行 body。前置回合的错误不传播到本回合（各自返回给各自调用方）。
    func run<T: Sendable>(
        path: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tails[path]
        nextToken += 1
        let token = nextToken
        let work = Task { () throws -> T in
            if let previous { await previous.value }
            return try await body()
        }
        let tail = Task { _ = try? await work.value }
        tails[path] = tail
        tokens[path] = token
        defer {
            if tokens[path] == token {
                tails.removeValue(forKey: path)
                tokens.removeValue(forKey: path)
            }
        }
        return try await work.value
    }
}
