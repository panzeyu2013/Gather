// desktop/native/gather-core/Sources/GatherCore/Services/MetadataMutationService.swift
// TS 源: desktop/src/main/services/metadata/metadata-mutation.service.ts（逐字移植）
// 变更入队：queuePhotoValues（同步，值直写）与 queueMutation（异步，读当前文件
// 状态后按 op 合并）。同一 xmp 路径的 queueMutation 经串行链严格按到达顺序执行
// （mutationQueues，对应 TS 的 promise 链）；不同路径可并行。

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
    ) throws -> MetadataMutationResult
    /// TS: queueMutation。
    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult
}

/// TS: MetadataMutationService。
public final class MetadataMutationService: MetadataMutationPort {
    /// TS: mutationQueues（Map<xmpPath, Promise>）—— 每路径串行链。
    /// 链的语义与 TS 逐字一致：`queued = previous.then(() => currentTurn)`，
    /// 链只在前一链拒绝时拒绝（错误向后续回合传播），currentTurn 永不休止
    /// （release 在 finally 里）——因此尾部任务 = 等待前一链 + 等待本回合闸门。
    /// 身份比较：Task<Void, any Error> 无法作 ObjectIdentifier/=== 操作数
    /// （any Error 非 class 约束），故链尾任务经 box 包装 class 存储。
    private var mutationQueues: [String: TaskBox] = [:]
    private let queueLock = NSLock()

    private let outboxRepo: MetadataOutboxRepo
    private let xmp: any XMPProvider
    private let sync: MetadataSyncCoordinator
    private let assetResolver: PhotoAssetResolver

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
    public func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool = true
    ) throws -> MetadataMutationResult {
        let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        let dirtyFields = values.keys
            .filter { ["rating", "label", "keywords"].contains($0) }
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
    /// 按 op 合并后经 queuePhotoValues 入队。同一 xmp 路径串行。
    public func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        let normalized = try validateMetadataPatch(patch)
        let resolved = try assetResolver.resolve(sessionId: sessionId, photoId: photoId)
        let xmpPath = resolved.xmpPath
        // 串行链：等待前一回合（含其错误传播，对齐 TS promise 链语义）。
        let previous = previousTurn(xmpPath)
        let gate = AsyncGate()
        let tail = Task<Void, any Error> {
            try await previous?.value
            await gate.wait()
        }
        registerTail(tail, for: xmpPath)
        defer {
            gate.open()
            removeTailIfCurrent(tail, for: xmpPath)
        }
        // TS: `await previous`（前一回合抛错时本回合直接继承）。
        try await previous?.value
        let current = try await xmp.readAttributes(photoPath: resolved.filepath)
        let pending = parsePendingKeywords(try? outboxRepo.get(xmpPath)?.patchJSON)
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
        return try queuePhotoValues(
            sessionId: sessionId,
            photoId: photoId,
            values: values,
            source: source
        )
    }

    // MARK: - 串行链支撑（sync helpers，NSLock 不进 async 上下文）

    private func previousTurn(_ xmpPath: String) -> Task<Void, any Error>? {
        queueLock.lock()
        defer { queueLock.unlock() }
        return mutationQueues[xmpPath]?.task
    }

    private func registerTail(_ task: Task<Void, any Error>, for xmpPath: String) {
        queueLock.lock()
        mutationQueues[xmpPath] = TaskBox(task)
        queueLock.unlock()
    }

    private func removeTailIfCurrent(_ task: Task<Void, any Error>, for xmpPath: String) {
        queueLock.lock()
        defer { queueLock.unlock() }
        // Task<Void, any Error> 不能直接作 `===` 操作数（any Error 非 class
        // 约束），经 AnyObject 桥接比较身份。
        let tailIdentity = task as AnyObject
        guard let current = mutationQueues[xmpPath],
              current.task as AnyObject === tailIdentity else { return }
        mutationQueues.removeValue(forKey: xmpPath)
    }
}

/// TS: parsePendingKeywords —— 解析 outbox 行里的 pending 关键词（损坏返回 nil）。
private func parsePendingKeywords(_ value: String?) -> [String]? {
    guard let value else { return nil }
    guard let parsed = try? JSONValue.parse(value), let keywords = parsed["keywords"] else { return nil }
    guard let strings = keywords.arrayElements?.compactMap({ $0.stringValue }) else { return nil }
    return try? normalizeKeywords(strings)
}

/// 链尾任务的身份盒（Task<Void, any Error> 不能作 === 操作数，经 class 包装）。
private final class TaskBox: @unchecked Sendable {
    let task: Task<Void, any Error>
    init(_ task: Task<Void, any Error>) { self.task = task }
}

/// 单次放行闸门（串行链的 currentTurn 等价物）。
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if opened { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}
