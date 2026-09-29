// desktop/native/gather-core/Sources/GatherCore/Services/MetadataMutationService.swift
// 变更入队服务（R4 重写）。
//
// 唯一写路径的入口：queuePhotoValues 只写 metadata_outbox（先落库），排程由
// MetadataSyncCoordinator 负责；本文件绝不直接触碰 XMP 侧车。
//
// 串行化：queueMutation 的"读当前文件 → 合并 op → 入队"必须按 xmpPath 串行，
// 旧实现用「字典存 Task + AnyObject 身份比较」判定尾结点（身份恒 false →
// 条目永不回收、错误沿链传播）。新实现改为 actor PathSerialChain + 单调 token：
//   - token 判定尾结点，条目在最后一回合结束时回收（无无界增长）；
//   - 每回合错误只回给本回合调用方，不再污染后续独立变更；
//   - 路径一律经 MetadataOutboxPath 归一化（与仓库/协调器同一口径）。

import Foundation

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
    /// TS: queueMutation。
    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult
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
}

public final class MetadataMutationService: MetadataMutationPort {
    private let outboxRepo: MetadataOutboxRepo
    private let xmp: any XMPProvider
    private let sync: MetadataSyncCoordinator
    private let assetResolver: PhotoAssetResolver
    private let chain = PathSerialChain()

    public init(
        outboxRepo: MetadataOutboxRepo,
        xmp: any XMPProvider,
        sync: MetadataSyncCoordinator,
        assetResolver: PhotoAssetResolver
    ) {
        self.outboxRepo = outboxRepo
        self.xmp = xmp
        self.sync = sync
        self.assetResolver = assetResolver
    }

    /// TS: queuePhotoValues —— 值直写合并进 outbox 并排程写回。
    /// 字段级合并由仓库保证：后者覆盖同名字段，未提及字段保留。
    public func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool = true
    ) throws -> MetadataMutationResult {
        let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        // 可写字段名集合的唯一真相源是 MetadataField（契约层枚举）；
        // filter 与 compactMap 同为「非契约字段丢弃」，保留调用方键序不变。
        let dirtyFields = values.keys
            .filter { MetadataField.writableNames.contains($0) }
            .compactMap { MetadataField(rawValue: $0) }
        if dirtyFields.isEmpty {
            throw MetadataMutationError.empty
        }
        var patch = values
        patch["source"] = .string(source.rawValue)
        let row = try outboxRepo.mergePatch(
            xmpPath: resolved.xmpPath,
            sessionId: sessionId,
            photoPath: resolved.filepath,
            patch: .object(patch),
            dirtyFields: dirtyFields.map(\.rawValue)
        )
        if schedule {
            sync.schedule(xmpPath: row.xmpPath)
        }
        return MetadataMutationResult(
            photoId: photoId,
            xmpPath: row.xmpPath,
            dirtyFields: dirtyFields,
            revision: Int(row.revision),
            status: row.status
        )
    }

    /// TS: queueMutation —— 校验 patch、读当前文件状态（pending 关键词优先），
    /// 按 op 合并后经 queuePhotoValues 入队。同一 xmp 路径严格串行。
    public func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        let normalized = try validateMetadataPatch(patch)
        let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        let xmpPath = MetadataOutboxPath.normalize(resolved.xmpPath)
        return try await chain.run(path: xmpPath) {
            let current = try await self.xmp.readAttributes(photoPath: resolved.filepath)
            let pending = self.parsePendingKeywords(try? self.outboxRepo.get(xmpPath)?.patchJSON)
            let currentKeywords = current.keywords ?? []
            let existingKeywords: [String]
            if let pending {
                existingKeywords = pending
            } else {
                existingKeywords = try normalizeKeywords(currentKeywords)
            }
            var values: [String: JSONValue] = [:]
            if let rating = normalized.rating { values["rating"] = .number(rating.value) }
            if let label = normalized.label {
                // TS: 'None' → ''（写盘标签语义）。
                values["label"] = .string(label.value == "None" ? "" : label.value)
            }
            if let keywords = normalized.keywords {
                switch keywords.op {
                case .append:
                    values["keywords"] = .array(
                        try normalizeKeywords(existingKeywords + keywords.values).map { .string($0) })
                case .remove:
                    let remove = Set(keywords.values)
                    values["keywords"] = .array(
                        existingKeywords.filter { !remove.contains($0) }.map { JSONValue.string($0) })
                case .replace:
                    values["keywords"] = .array(keywords.values.map { .string($0) })
                }
            }
            return try self.queuePhotoValues(
                sessionId: sessionId,
                photoId: photoId,
                values: values,
                source: source
            )
        }
    }

    /// TS: parsePendingKeywords —— 解析 outbox 行里的 pending 关键词（损坏返回 nil）。
    private func parsePendingKeywords(_ value: String?) -> [String]? {
        guard let value else { return nil }
        guard let parsed = try? JSONValue.parse(value), let keywords = parsed["keywords"] else { return nil }
        guard let strings = keywords.arrayElements?.compactMap({ $0.stringValue }) else { return nil }
        return try? normalizeKeywords(strings)
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
