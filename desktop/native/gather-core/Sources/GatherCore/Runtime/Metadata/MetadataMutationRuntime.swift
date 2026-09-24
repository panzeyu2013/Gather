// desktop/native/gather-core/Sources/GatherCore/Runtime/Metadata/MetadataMutationRuntime.swift
// R4：Services/MetadataMutationService.swift → Runtime 层 actor（方法原样搬，
// Services 旧文件同批删除）。TS 源:
// desktop/src/main/services/metadata/metadata-mutation.service.ts（逐字移植）。
// 变更入队：queuePhotoValues（值直写）与 queueMutation（异步，读当前文件
// 状态后按 op 合并）。同一 xmp 路径的 queueMutation 经串行链严格按到达顺序执行
// （mutationQueues，对应 TS 的 promise 链）；不同路径可并行。
// 纯逻辑（patch 校验 / 关键词规范化）在 Metadata/MetadataMutationPlan.swift；
// 本文件不含 SQL 与 database 调用。

import Foundation

/// TS: metadata-mutation.service.ts 抛出的错误码。
public enum MetadataMutationError: Error, Equatable, CustomStringConvertible {
    case empty // METADATA_MUTATION_EMPTY

    public var description: String {
        switch self {
        case .empty: "METADATA_MUTATION_EMPTY"
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
    ) async throws -> MetadataMutationResult
    /// TS: queueMutation。
    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult
}

/// TS: MetadataMutationService —— Runtime 层 actor。
public actor MetadataMutationRuntime: MetadataMutationPort {
    /// 依赖集合（装配期注入；actor 只读）。
    public struct Dependencies {
        public let writebackStore: any WritebackStore
        public let xmp: any XMPProvider
        public let sync: MetadataSyncCoordinator
        public let assetResolver: PhotoAssetResolver

        public init(
            writebackStore: any WritebackStore,
            xmp: any XMPProvider,
            sync: MetadataSyncCoordinator,
            assetResolver: PhotoAssetResolver
        ) {
            self.writebackStore = writebackStore
            self.xmp = xmp
            self.sync = sync
            self.assetResolver = assetResolver
        }
    }

    /// TS: mutationQueues（Map<xmpPath, Promise>）—— 每路径串行链。
    /// 链的语义与 TS 逐字一致：`queued = previous.then(() => currentTurn)`，
    /// 链只在前一链拒绝时拒绝（错误向后续回合传播），currentTurn 永不休止
    /// （release 在 finally 里）——因此尾部任务 = 等待前一链 + 等待本回合结束信号。
    /// actor 隔离取代锁：字典读写在无 await 的同步前缀内完成。
    private struct QueueTail: Sendable {
        let id: UInt64
        let task: Task<Void, any Error>
    }

    private var mutationQueues: [String: QueueTail] = [:]
    private var nextTailId: UInt64 = 0
    private let deps: Dependencies

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// TS: queuePhotoValues —— 值直写合并进 outbox 并排程写回。
    public func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool = true
    ) async throws -> MetadataMutationResult {
        let resolved = try await deps.assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        let dirtyFields = values.keys
            .filter { ["rating", "label", "keywords"].contains($0) }
            .compactMap { MetadataField(rawValue: $0) }
        if dirtyFields.isEmpty {
            throw MetadataMutationError.empty
        }
        var patch = values
        patch["source"] = .string(source.rawValue)
        let row = try await deps.writebackStore.mergeOutboxPatch(
            xmpPath: resolved.xmpPath,
            sessionId: sessionId,
            photoPath: resolved.filepath,
            patch: .object(patch),
            dirtyFields: dirtyFields.map(\.rawValue)
        )
        if schedule {
            deps.sync.schedule(xmpPath: row.xmpPath)
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
    /// 按 op 合并后经 queuePhotoValues 入队。同一 xmp 路径串行。
    public func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        let normalized = try validateMetadataPatch(patch)
        let resolved = try await deps.assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        let xmpPath = resolved.xmpPath
        // 串行链：等待前一回合（含其错误传播，对齐 TS promise 链语义）。
        // AsyncStream 只作本回合的结束信号（tail 先等前一回合，再等本回合
        // finish）；tail 闭包仅捕获 Sendable 值（AsyncStream 为 Sendable）。
        let previous = previousTurn(xmpPath)
        let (turnDone, turnFinish) = AsyncStream<Void>.makeStream()
        let tail = Task<Void, any Error> {
            try await previous?.value
            var iterator = turnDone.makeAsyncIterator()
            _ = await iterator.next()
        }
        let tailId = registerTail(tail, for: xmpPath)
        defer {
            turnFinish.finish()
            removeTailIfCurrent(tailId, for: xmpPath)
        }
        // TS: `await previous`（前一回合抛错时本回合直接继承）。
        try await previous?.value
        let current = try await deps.xmp.readAttributes(photoPath: resolved.filepath)
        let pending = parsePendingKeywords(try? await deps.writebackStore.outboxEntry(xmpPath: xmpPath)?.patchJSON)
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
                    try normalizeKeywords(existingKeywords + keywords.values).map { .string($0) }
                )
            case .remove:
                let remove = Set(keywords.values)
                values["keywords"] = .array(
                    existingKeywords.filter { !remove.contains($0) }.map { JSONValue.string($0) }
                )
            case .replace:
                values["keywords"] = .array(keywords.values.map { .string($0) })
            }
        }
        return try await queuePhotoValues(
            sessionId: sessionId,
            photoId: photoId,
            values: values,
            source: source
        )
    }

    // MARK: - 串行链支撑（actor 隔离：字典读写在无 await 的同步前缀内完成）

    private func previousTurn(_ xmpPath: String) -> Task<Void, any Error>? {
        mutationQueues[xmpPath]?.task
    }

    /// 注册链尾并返回回合号（清理时按号比较，避免误删后继回合的链尾）。
    private func registerTail(_ task: Task<Void, any Error>, for xmpPath: String) -> UInt64 {
        nextTailId += 1
        mutationQueues[xmpPath] = QueueTail(id: nextTailId, task: task)
        return nextTailId
    }

    private func removeTailIfCurrent(_ id: UInt64, for xmpPath: String) {
        if mutationQueues[xmpPath]?.id == id {
            mutationQueues.removeValue(forKey: xmpPath)
        }
    }
}

/// TS: parsePendingKeywords —— 解析 outbox 行里的 pending 关键词（损坏返回 nil）。
private func parsePendingKeywords(_ value: String?) -> [String]? {
    guard let value else { return nil }
    guard let parsed = try? JSONValue.parse(value), let keywords = parsed["keywords"] else { return nil }
    guard let strings = keywords.arrayElements?.compactMap({ $0.stringValue }) else { return nil }
    return try? normalizeKeywords(strings)
}

