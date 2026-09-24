import Foundation

/// TS: safeObject —— JSON 文本解析为对象，损坏或非对象一律退化为空对象
/// （与 Services/MetadataSyncCoordinator 的 safeObject 逐字同语义）。
private func metadataWriterSafeObject(_ value: String) -> JSONValue {
    guard let parsed = try? JSONValue.parse(value) else { return .object([:]) }
    if case .object = parsed { return parsed }
    return .object([:])
}

/// mwsum / W4-3a：getSummary —— 轻投影 + 分组计数（outboxCounts 为主、逐行过滤兜底），
/// 语义对齐 Services/MetadataSyncCoordinator.getSummary。
/// mwstate / W4-3b：getSessionState —— outbox 分组计数 + reload-ack 只读聚合。
/// W4-3d/W4-6：元数据提取 provider 集合（EXIF 解析 / 尺寸兜底 / 内嵌 XMP 读）。
/// nil = 宿主未接线：读路径遇未缓存 id 时显式标记 capability=unsupported，
/// 绝不静默返回空或不完整结果。W4-6 provider 一等注入时迁入 MetadataProviderContract.swift。
public struct MetadataProviderSet: Sendable {
    public let exif: (any ExifProvider)?
    public let dimensions: (any ImageDimensionsProvider)?
    public let embeddedReader: (any EmbeddedXMPReader)?

    public init(
        exif: (any ExifProvider)? = nil,
        dimensions: (any ImageDimensionsProvider)? = nil,
        embeddedReader: (any EmbeddedXMPReader)? = nil
    ) {
        self.exif = exif
        self.dimensions = dimensions
        self.embeddedReader = embeddedReader
    }

    /// 至少一条提取路径已接线；全 nil 等价于未接线（capability=unsupported）。
    public var isWired: Bool {
        exif != nil || dimensions != nil || embeddedReader != nil
    }
}

/// W4-3d：getMetadata 的显式能力标记错误。
/// providerSet 未接线时，未缓存 id 无法提取 —— 抛本错误并携带已命中缓存，
/// 绝不静默返回空字典或只含部分行的字典。
public enum MetadataWriterError: Error, Equatable, CustomStringConvertible {
    /// capability=unsupported：无任何提取 provider。
    case providerUnsupported(cached: [String: MetadataTags], missingPhotoIds: [String])
    /// provider 已接线，但提取所需的 photo 路径端口与批量 upsert 属写面
    /// （W4-4/W4-6）；读面不伪造提取结果，同样显式上抛。
    case extractionDeferred(cached: [String: MetadataTags], missingPhotoIds: [String])
    /// mww4 / W4-4 ①：waitForIdle 超时（路径未结算到 idle）；
    /// mwwshut：shutdown 超时（activeWrites/readyQueue 未在窗口内双空）。
    case scheduleTimeout(xmpPath: String, timeoutMs: Int)

    /// 已命中的缓存行（显式标记时一并带回，调用方不丢失可用数据）。
    public var cached: [String: MetadataTags] {
        switch self {
        case .providerUnsupported(let cached, _): cached
        case .extractionDeferred(let cached, _): cached
        case .scheduleTimeout: [:]
        }
    }

    /// 未命中的 photoId（保持请求顺序，含重复项，与旧实现一致）。
    public var missingPhotoIds: [String] {
        switch self {
        case .providerUnsupported(_, let missing): missing
        case .extractionDeferred(_, let missing): missing
        case .scheduleTimeout: []
        }
    }

    public var description: String {
        switch self {
        case .providerUnsupported: "METADATA_PROVIDER_UNSUPPORTED"
        case .extractionDeferred: "METADATA_EXTRACTION_DEFERRED"
        case .scheduleTimeout: "METADATA_SCHEDULE_TIMEOUT"
        }
    }
}

public actor MetadataWriter {

    /// 注入依赖；协议组合可测（测试可传抛错替身）。
    public struct Dependencies: Sendable {
        public let writebackStore: any WritebackStore
        public let metadataStore: any MetadataStore
        /// 外部事实 E（sessions.reload_acked_at）只读端口：safeToCleanup 的唯一门。
        /// 缺省 nil = 未接线，getSessionState 按「未确认」保守处理。
        public let sessionStore: (any SessionStore)?
        /// sidecar 读取端口（getConflicts 每冲突行读一次）；缺省 nil = 未接线，
        /// 有冲突行时抛 conflictDetailsUnavailable，绝不伪造「无字段冲突」。
        public let xmpProvider: (any XMPProvider)?
        /// W4-3d：提取 provider 集合；缺省 nil = 无 provider。
        /// getMetadata 遇未缓存 id 时显式标记 capability=unsupported，绝不静默返回。
        public let providerSet: MetadataProviderSet?

        public init(
            writebackStore: any WritebackStore,
            metadataStore: any MetadataStore,
            sessionStore: (any SessionStore)? = nil,
            xmpProvider: (any XMPProvider)? = nil,
            providerSet: MetadataProviderSet? = nil
        ) {
            self.writebackStore = writebackStore
            self.metadataStore = metadataStore
            self.sessionStore = sessionStore
            self.xmpProvider = xmpProvider
            self.providerSet = providerSet
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - mww4 / W4-4 ① 写面去抖排程骨架

    /// 每个 xmpPath 一条排程条目：ticket 标识「最新一次 schedule」；
    /// generation 单调 +1（只增不减，测试用它断言合流次数）；
    /// 旧 ticket 的延迟任务醒来后发现 ticket 已被替换即自行退出。
    private struct ScheduleEntry: Sendable {
        var ticket: UUID
        var generation: UInt64
        var phase: Phase

        enum Phase: Sendable {
            case idle
            case debouncing
            case queued
            case inFlight
        }
    }

    private var entries: [String: ScheduleEntry] = [:]

    /// mww6a / W4-4 ②：就绪 FIFO 队列（入队时按路径去重，顺序即入队先后）。
    private var readyQueue: [String] = []

    /// mww6a / W4-4 ②：在飞写及其 ticket；结束清空仅当 ticket 匹配。
    private var activeWrites: [String: UUID] = [:]

    /// mww6c：同路径 mutation 串行链 —— 每个 xmpPath 一条 Task 尾，
    /// 新 mutation 挂到链尾，前一条未结算完绝不并发进入写面。
    /// mwwshut：尾项携带 ticket，完成后按 ticket 精确释放，
    /// 已完成的前序 task 不再随字典存活（避免链尾字典无界增长）。
    private struct MutationTail {
        let ticket: UUID
        let task: Task<Void, Never>
    }

    private var mutationTails: [String: MutationTail] = [:]

    /// mwwshut / W4-4：关停标记。schedule 的入队 Task 是独立的，
    /// 关停后仍可能落到 actor 上；标记为真后入队一律拒绝，保证 shutdown
    /// 返回后没有任务再触碰 Store（与旧管线 stopped 标记同语义）。
    private var isShutDown = false

    /// mwwshut：有界关停的汇合点 —— activeWrites 与 readyQueue 双空时唤醒；
    /// 超时由 expireQuiescenceWaiter 结算（continuation，绝不轮询）。
    private struct QuiescenceWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var quiescenceWaiters: [QuiescenceWaiter] = []

    /// mwwshut 测试接缝（internal）：nil = 生产真实写回落点（performWriteback）。
    /// 测试用它把一笔写钉在 in-flight，验证 shutdown 的等待与超时。
    private var writeBody: (@Sendable (String) async -> Void)?

    func setWriteBodyForTesting(_ body: @escaping @Sendable (String) async -> Void) {
        writeBody = body
    }

    /// 写体执行（actor 内）：存储属性不跨 actor 边界，跨边界只经本方法。
    /// 未注入测试写体时执行生产真实写回。
    private func performWriteBody(xmpPath: String) async {
        guard let writeBody else {
            await performWriteback(xmpPath: xmpPath)
            return
        }
        await writeBody(xmpPath)
    }

    /// w4write / W4-4：真实写回落点 —— 只用既有 Store 与 XMP 端口消费一笔排程：
    /// outboxEntry 读行 → claimOutbox CAS 认领（旧 revision/非 pending·failed 即弃）→
    /// 批量失效会话 reload-ack（数据丢失守卫）→ backup + writeAttributes + readAttributes
    /// → markOutboxWritten；任一步失败一律 markOutboxStatus(failed)，绝不把行留在 writing。
    /// 冲突检测/基线快照/退避重试属后续写面步骤，本落点不伪造这些语义。
    private func performWriteback(xmpPath: String) async {
        let store = dependencies.writebackStore
        guard let row = try? await store.outboxEntry(xmpPath: xmpPath),
              ["pending", "writing", "failed"].contains(row.status) else { return }
        guard (try? await store.claimOutbox(
            xmpPath: xmpPath, expectedRevision: row.revision)) == true else { return }
        if let sessionStore = dependencies.sessionStore {
            _ = try? await sessionStore.clearReloadAckedAtForXmpPaths([xmpPath])
        }
        guard let xmp = dependencies.xmpProvider else {
            try? await store.markOutboxStatus(
                xmpPath: xmpPath, status: "failed",
                errorMessage: "XMP_PROVIDER_UNSUPPORTED")
            return
        }
        do {
            let backupPath: String
            if row.backupPath.isEmpty {
                backupPath = try await xmp.backup(photoPath: row.photoPath)
                try await store.setOutboxBackupPath(xmpPath: xmpPath, backupPath: backupPath)
            } else {
                backupPath = row.backupPath
            }
            let patch = metadataWriterSafeObject(row.patchJSON)
            try await xmp.writeAttributes(photoPath: row.photoPath, attributes: MetadataWriteAttributes(
                keywords: patch["keywords"]?.arrayValue,
                rating: patch["rating"]?.numberValue,
                label: patch["label"]?.stringValue
            ))
            let persisted = try await xmp.readAttributes(photoPath: row.photoPath)
            let fingerprint = (try? await MetadataFingerprint.contentFingerprint(xmpPath)) ?? ""
            try await store.markOutboxWritten(
                xmpPath: xmpPath,
                revision: row.revision,
                fingerprint: fingerprint,
                baseValues: persisted.asJSONValue,
                backupPath: backupPath
            )
        } catch {
            try? await store.markOutboxStatus(
                xmpPath: xmpPath, status: "failed", errorMessage: String(describing: error))
        }
    }

    /// 默认去抖窗口（毫秒）：同路径高频写回在窗口内合并为一次。
    /// 取旧管线 MetadataSyncCoordinator.defaultWriteDebounceMs = 500（TS 设置
    /// metadata_write_debounce_ms 同值）；设置注入留待写面后续步骤。
    static let defaultDebounceDelayMs = 500

    /// 异步入队（非阻塞）：立即返回，实际登记在 actor 上串行执行。
    public nonisolated func schedule(xmpPath: String) {
        schedule(xmpPath: xmpPath, delayMs: nil)
    }

    /// delayMs = nil 用默认去抖窗口；0/负数表示不等待、下一跳立刻入队。
    public nonisolated func schedule(xmpPath: String, delayMs: Int?) {
        Task { await self.enqueue(xmpPath: xmpPath, delayMs: delayMs) }
    }

    /// generation 单调 +1；同路径重复调用只保留最新 ticket —— 旧 ticket 到点即弃。
    private func enqueue(xmpPath: String, delayMs: Int?) async {
        // mwwshut：关停后入队一律拒绝（入队 Task 可能晚于关停落到 actor），
        // 保证 shutdown 返回后没有任务再触碰 Store。
        guard !isShutDown else { return }
        let generation = (entries[xmpPath]?.generation ?? 0) + 1
        let ticket = UUID()
        entries[xmpPath] = ScheduleEntry(
            ticket: ticket, generation: generation, phase: .debouncing)
        // generation +1 立即结算阈值等待者：同路径 100 次 schedule 在此汇合。
        resumeGenerationWaiters(xmpPath: xmpPath, generation: generation)
        let delay = delayMs ?? Self.defaultDebounceDelayMs
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        guard entries[xmpPath]?.ticket == ticket else { return }
        entries[xmpPath]?.phase = .queued
        // mww6a / W4-4 ②：就绪入队（同路径已在队列中则不重复入队）。
        if !readyQueue.contains(xmpPath) { readyQueue.append(xmpPath) }
        // mwwshut：就绪队列消费 —— 入队后由 drainReadyQueue 按 FIFO 启动写面；
        // 本方法不再等待本笔写完成，结算与唤醒统一落在 finishWrite。
        drainReadyQueue()
    }

    /// mwwshut / W4-4 ②：就绪队列消费 —— FIFO 取出可启动路径并进入写面。
    /// 过期条目（ticket 已被新一轮 schedule 替换、条目已删除）直接丢弃；
    /// 上一笔仍在飞的路径本轮跳过，待 finishWrite 释放 activeWrites 后再消费。
    private func drainReadyQueue() {
        while let next = firstStartableReady() {
            readyQueue.removeAll { $0 == next.xmpPath }
            startWrite(xmpPath: next.xmpPath, ticket: next.ticket)
        }
    }

    /// 就绪队列中首个可启动条目；先丢弃过期/已启动条目（原地删除，保持 FIFO 相对顺序）。
    private func firstStartableReady() -> (xmpPath: String, ticket: UUID)? {
        readyQueue.removeAll { xmpPath in
            guard let entry = entries[xmpPath] else { return true }
            return entry.phase != .queued
        }
        for xmpPath in readyQueue {
            guard let entry = entries[xmpPath] else { continue }
            if activeWrites[xmpPath] == nil { return (xmpPath, entry.ticket) }
        }
        return nil
    }

    /// mwwshut：启动一笔写 —— 挂到同路径串行链尾（前一条未结算完绝不并发进入写面）；
    /// 任务体先执行写体（测试注入写体或生产真实写回），
    /// 完成后统一走 finishWrite（结算 + 消费队列 + 释放链尾）。
    private func startWrite(xmpPath: String, ticket: UUID) {
        entries[xmpPath]?.phase = .inFlight
        // mww6a / W4-4 ②：登记在飞写 ticket。
        activeWrites[xmpPath] = ticket
        let previous = mutationTails[xmpPath]?.task
        let task: Task<Void, Never> = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performWriteBody(xmpPath: xmpPath)
            await self.finishWrite(xmpPath: xmpPath, ticket: ticket)
        }
        mutationTails[xmpPath] = MutationTail(ticket: ticket, task: task)
    }

    /// mwwshut：一笔写的统一完成点 —— 结算相位/在飞登记 → 继续消费队列 → 释放链尾
    /// （释放后触发关停汇合点，保证「结算处 resume」）。
    private func finishWrite(xmpPath: String, ticket: UUID) {
        settle(xmpPath: xmpPath, ticket: ticket)
        drainReadyQueue()
        releaseMutationTail(xmpPath: xmpPath, ticket: ticket)
    }

    /// mwwshut：按 ticket 精确释放本路径链尾 —— 仅当本路径已无在飞写且无排队时置 nil，
    /// 已完成 task 不随字典长期存活（round 160 遗留项）；释放后结算关停等待者。
    private func releaseMutationTail(xmpPath: String, ticket: UUID) {
        guard mutationTails[xmpPath]?.ticket == ticket else { return }
        guard activeWrites[xmpPath] == nil, !readyQueue.contains(xmpPath) else { return }
        mutationTails[xmpPath] = nil
        signalQuiescenceIfIdle()
    }

    // MARK: - 等待原语（continuation 唤醒，绝不轮询）

    /// 等待登记：minGeneration == nil 表示等到 idle；否则等到 generation 阈值。
    private struct Waiter {
        let id: UUID
        let minGeneration: UInt64?
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [String: [Waiter]] = [:]

    /// 等待指定路径结算到 idle；超时抛 MetadataWriterError.scheduleTimeout。
    /// 挂起 continuation，由 settle 精确唤醒，超时由 expireWaiter 结算，绝不 sleep 轮询。
    /// 从未排程（无条目）视为本已空闲，立即返回。
    public func waitForIdle(xmpPath: String, timeoutMs: Int = 5_000) async throws {
        guard let entry = entries[xmpPath], entry.phase != .idle else { return }
        try await awaitSatisfied(
            xmpPath: xmpPath,
            minGeneration: nil,
            timeoutMs: timeoutMs
        ) { _ in
            guard let current = self.entries[xmpPath] else { return true }
            return current.phase == .idle
        }
    }

    /// 测试汇合原语（internal）：等到 generation 至少达到 minGeneration。
    /// 非阻塞 schedule 把入队 Task 交给全局执行器，调用方需要确定性汇合点；
    /// 唤醒同样走 continuation（enqueue 每次 +1 时结算），不轮询。
    func waitForGeneration(
        xmpPath: String, minGeneration: UInt64, timeoutMs: Int = 5_000
    ) async throws {
        try await awaitSatisfied(
            xmpPath: xmpPath,
            minGeneration: minGeneration,
            timeoutMs: timeoutMs
        ) { generation in
            generation >= minGeneration
        }
    }

    /// 统一等待入口：先判一次谓词，再登记 continuation 与超时兜底任务。
    private func awaitSatisfied(
        xmpPath: String,
        minGeneration: UInt64?,
        timeoutMs: Int,
        isSatisfied: (UInt64) -> Bool
    ) async throws {
        if isSatisfied(entries[xmpPath]?.generation ?? 0) { return }
        guard timeoutMs > 0 else {
            throw MetadataWriterError.scheduleTimeout(xmpPath: xmpPath, timeoutMs: timeoutMs)
        }
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[xmpPath, default: []].append(
                    Waiter(id: waiterId, minGeneration: minGeneration, continuation: continuation))
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    await self?.expireWaiter(
                        xmpPath: xmpPath, waiterId: waiterId, timeoutMs: timeoutMs)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(xmpPath: xmpPath, waiterId: waiterId)
            }
        }
    }

    /// 当前 ticket 完成整个生命周期：inFlight → idle，并唤醒 idle 等待者。
    private func settle(xmpPath: String, ticket: UUID) {
        // mwwshut：在飞登记的清理不随 ticket 守卫短路 —— 被新一轮 schedule
        // 替换的旧写若不清理，会永久挡住就绪队列里新一笔的启动。
        if activeWrites[xmpPath] == ticket { activeWrites[xmpPath] = nil }
        guard entries[xmpPath]?.ticket == ticket else { return }
        let generation = entries[xmpPath]?.generation ?? 0
        // mwwd：结算即消费就绪队列（本路径本次结算出队）。
        readyQueue.removeAll { $0 == xmpPath }
        entries[xmpPath]?.phase = .idle
        resumeWaiters(xmpPath: xmpPath, generation: generation, includeIdle: true)
    }

    /// generation +1 后结算阈值等待者（同路径重复调用的确定性汇合点）。
    private func resumeGenerationWaiters(xmpPath: String, generation: UInt64) {
        resumeWaiters(xmpPath: xmpPath, generation: generation, includeIdle: false)
    }

    /// 结算命中等待者；continuation 命中即移除，恰好 resume 一次。
    private func resumeWaiters(xmpPath: String, generation: UInt64, includeIdle: Bool) {
        guard let list = waiters[xmpPath] else { return }
        var pending: [Waiter] = []
        var resumable: [Waiter] = []
        for waiter in list {
            if let threshold = waiter.minGeneration {
                if generation >= threshold { resumable.append(waiter) } else { pending.append(waiter) }
            } else if includeIdle {
                resumable.append(waiter)
            } else {
                pending.append(waiter)
            }
        }
        waiters[xmpPath] = pending.isEmpty ? nil : pending
        for waiter in resumable { waiter.continuation.resume() }
    }

    private func removeWaiter(xmpPath: String, waiterId: UUID) -> Waiter? {
        guard var list = waiters[xmpPath],
              let index = list.firstIndex(where: { $0.id == waiterId }) else { return nil }
        let removed = list.remove(at: index)
        waiters[xmpPath] = list.isEmpty ? nil : list
        return removed
    }

    private func expireWaiter(xmpPath: String, waiterId: UUID, timeoutMs: Int) {
        guard let waiter = removeWaiter(xmpPath: xmpPath, waiterId: waiterId) else { return }
        waiter.continuation.resume(
            throwing: MetadataWriterError.scheduleTimeout(xmpPath: xmpPath, timeoutMs: timeoutMs))
    }

    private func cancelWaiter(xmpPath: String, waiterId: UUID) {
        guard let waiter = removeWaiter(xmpPath: xmpPath, waiterId: waiterId) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 测试只读访问器（internal）：排程条目快照，按路径排序，不暴露私有类型。
    func scheduleSnapshot() -> [(xmpPath: String, generation: UInt64, phase: String)] {
        entries
            .map { ($0.key, $0.value.generation, String(describing: $0.value.phase)) }
            .sorted { $0.0 < $1.0 }
    }

    /// mww6a / W4-4 ② 测试只读访问器（internal）：就绪队列顺序 + 在飞写 ticket 快照。
    func writeStateSnapshot() -> (ready: [String], active: [String: UUID]) {
        (ready: readyQueue, active: activeWrites)
    }

    /// mwwshut 测试只读访问器（internal）：链尾释放后应回到 0。
    func mutationTailCount() -> Int {
        mutationTails.count
    }

    /// mwwshut / W4-4：有界关停。
    /// ①置关停标记，拒绝后续入队（入队 Task 可能晚于关停落到 actor）；
    /// ②在 timeoutMs 内等待 activeWrites 与 readyQueue 双空（continuation 汇合，
    ///   结算处 resume，绝不轮询）；超时抛 MetadataWriterError.scheduleTimeout；
    /// ③成功或超时都清空排程/就绪/在飞/链尾，保证返回后没有任务再触碰 Store。
    public func shutdown(timeoutMs: Int = 5_000) async throws {
        isShutDown = true
        do {
            try await awaitQuiescence(timeoutMs: timeoutMs)
        } catch {
            // 超时：取消未完成任务并强制清场，避免链尾与等待者悬挂。
            for tail in mutationTails.values { tail.task.cancel() }
            clearShutdownState()
            throw error
        }
        clearShutdownState()
    }

    /// mwstart / W4-4：重启入口。shutdown 为终止态（置 isShutDown，enqueue 一律拒绝），
    /// 关停后需 start 才能再次排程；start 会丢弃关停前残留状态
    /// （排程条目/就绪队列/在飞写/串行链尾；清后 generation 从 1 重新计数），
    /// 语义为调用方在 start 后重新 schedule，不注入新依赖（依赖仍由 init 注入）。
    /// w4wire / W4：崩溃遗留回收 —— 上次进程中断时停留在 status='writing' 的行
    /// 是未结算的在飞写，start 时经 WritebackStore.recoverInterruptedOutbox()
    /// 一律回退为 'pending'（与 Services/MetadataSyncCoordinator.start 同语义），
    /// 使新排程可重新认领这些行；绝不把 writing 残留当作已写入而丢工作。
    /// recoverInterruptedOutbox 为 async，而 start 保持既有同步签名（调用方无需
    /// 等待即可继续 schedule），故用 Task 包装为 best-effort：回收失败只丢弃该次
    /// 回收（try? 吞错），不阻断 start、不改变 start 的返回语义与调用点。
    public func start() {
        isShutDown = false
        entries.removeAll()
        readyQueue.removeAll()
        activeWrites.removeAll()
        mutationTails.removeAll()
        let writebackStore = dependencies.writebackStore
        Task { try? await writebackStore.recoverInterruptedOutbox() }
    }

    /// 静默判据：无在飞写且无排队的就绪路径。
    private var isQuiescent: Bool {
        activeWrites.isEmpty && readyQueue.isEmpty
    }

    /// 等待 activeWrites 与 readyQueue 双空；已空立即返回，否则登记 continuation +
    /// 超时兜底任务（超时抛 scheduleTimeout，携带当前待结算路径便于定位）。
    private func awaitQuiescence(timeoutMs: Int) async throws {
        if isQuiescent { return }
        guard timeoutMs > 0 else {
            throw MetadataWriterError.scheduleTimeout(
                xmpPath: firstPendingXmpPath(), timeoutMs: timeoutMs)
        }
        let waiterId = UUID()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            quiescenceWaiters.append(QuiescenceWaiter(id: waiterId, continuation: continuation))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                await self?.expireQuiescenceWaiter(id: waiterId, timeoutMs: timeoutMs)
            }
        }
    }

    /// 待结算路径（错误定位用）：就绪队列头优先，其次任一在飞写。
    private func firstPendingXmpPath() -> String {
        readyQueue.first ?? activeWrites.keys.sorted().first ?? ""
    }

    private func expireQuiescenceWaiter(id: UUID, timeoutMs: Int) {
        guard let index = quiescenceWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = quiescenceWaiters.remove(at: index)
        waiter.continuation.resume(
            throwing: MetadataWriterError.scheduleTimeout(
                xmpPath: firstPendingXmpPath(), timeoutMs: timeoutMs))
    }

    /// 结算处汇合：双空且有关停等待者时恰好 resume 一次。
    private func signalQuiescenceIfIdle() {
        guard isQuiescent, !quiescenceWaiters.isEmpty else { return }
        let pending = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in pending { waiter.continuation.resume() }
    }

    /// 关停清场：排程/就绪/在飞/链尾一次清空，并结算登记中的等待者，绝不悬挂。
    private func clearShutdownState() {
        entries.removeAll()
        readyQueue.removeAll()
        activeWrites.removeAll()
        mutationTails.removeAll()
        signalQuiescenceIfIdle()
        retireWaitersAfterShutdown()
    }

    /// 关停收尾：登记中的等待者不再有结果 —— idle 等待按满足唤醒，
    /// generation 等待按取消唤醒。
    private func retireWaitersAfterShutdown() {
        let pending = waiters
        waiters.removeAll()
        for list in pending.values {
            for waiter in list {
                if waiter.minGeneration == nil {
                    waiter.continuation.resume()
                } else {
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// TS: getMetadata（W4-3d 读路径）—— 缓存轻投影 → 全命中返回 / 有未命中显式标记。
    /// 与 Services/MetadataService.getMetadata 的有意差异（留后续步骤）：
    /// ① 指纹失效检查需要 photo 文件路径端口（MetadataWriter 尚未接线，W4-6 补齐）；
    /// ② 未命中分支的 EXIF/sharp 提取与 upsertMetadataBatch 属写面（W4-4/W4-6），
    ///    本步只做读路径；未命中绝不静默吞掉，而是抛 MetadataWriterError 显式标记。
    public func getMetadata(photoIds: [String]) async throws -> [String: MetadataTags] {
        guard !photoIds.isEmpty else { return [:] }
        let cached = try await dependencies.metadataStore.metadataBatchLite(photoIds: photoIds)
        let missingPhotoIds = photoIds.filter { cached[$0] == nil }
        guard !missingPhotoIds.isEmpty else { return cached }
        if dependencies.providerSet?.isWired == true {
            throw MetadataWriterError.extractionDeferred(
                cached: cached, missingPhotoIds: missingPhotoIds)
        }
        throw MetadataWriterError.providerUnsupported(
            cached: cached, missingPhotoIds: missingPhotoIds)
    }

    /// TS: getSummary —— 轻投影 + 分组计数（countBySession 为主，逐行过滤兜底）。
    public func getSummary(sessionId: String) async throws -> MetadataSyncSummary {
        let rows = try await dependencies.writebackStore.outboxSummaries(sessionId: sessionId)
        let items: [MetadataSyncItem] = rows.map { row in
            MetadataSyncItem(
                xmpPath: row.xmpPath,
                revision: Int(row.revision),
                persistedRevision: Int(row.persistedRevision),
                status: MetadataSyncStatus(rawValue: row.status) ?? .pending,
                attemptCount: Int(row.attemptCount),
                errorMessage: row.errorMessage,
                updatedAt: row.updatedAt
            )
        }
        let counts = try await dependencies.writebackStore.outboxCounts(sessionId: sessionId)
        func count(_ status: String) -> Int {
            if let c = counts[status] { return Int(c) }
            return items.filter { $0.status.rawValue == status }.count
        }
        return MetadataSyncSummary(
            sessionId: sessionId,
            pending: count("pending"),
            writing: count("writing"),
            written: count("written"),
            failed: count("failed"),
            conflict: count("conflict"),
            synced: count("synced"),
            items: items
        )
    }

    /// TS: listOrphans —— 孤儿写回行全量投影（语义对齐 Services/MetadataSyncCoordinator.listOrphans：
    /// 读全部孤儿行，逐行映射为 MetadataOrphan；任何排序/过滤都交给 Store 查询）。
    public func listOrphans() async throws -> [MetadataOrphan] {
        try await dependencies.writebackStore.orphanOutbox().map { row in
            MetadataOrphan(
                xmpPath: row.xmpPath,
                photoPath: row.photoPath,
                status: row.status,
                revision: Int(row.revision),
                errorMessage: row.errorMessage,
                updatedAt: row.updatedAt
            )
        }
    }

    /// sidecar 读取的并发上限：与旧写入管线 MetadataSyncCoordinator.maxConcurrency 一致。
    /// 迁移期取本地常量，避免 Metadata/ 反向依赖 Services/。
    private static let sidecarReadConcurrency = 2

    /// TS: getConflicts —— 每个冲突行读一次磁盘上的 sidecar，并发与写入管线一致（上限 2）。
    /// 语义逐条对齐 Services/MetadataSyncCoordinator.getConflicts：
    /// 仅取 status == "conflict" 的行；base=baseValuesJSON、local=patchJSON、
    /// dirtyFields 损坏时按空列表处理；字段冲突由 MetadataConflictFields.fieldConflicts 判定。
    public func getConflicts(sessionId: String) async throws -> [MetadataConflict] {
        let rows = try await dependencies.writebackStore.outboxEntries(sessionId: sessionId)
            .filter { $0.status == "conflict" }
        // 空集无需 sidecar：保持与旧实现一致的 []，不因端口未接线而失败。
        guard !rows.isEmpty else { return [] }
        guard let xmp = dependencies.xmpProvider else {
            throw MetadataSyncError.conflictDetailsUnavailable
        }
        return try await ConcurrentMap.run(rows, concurrency: Self.sidecarReadConcurrency) { row in
            let current = try await xmp.readAttributes(photoPath: row.photoPath)
            let base = metadataWriterSafeObject(row.baseValuesJSON)
            let local = metadataWriterSafeObject(row.patchJSON)
            let dirtyFields = MetadataConflictFields.parseDirtyFields(row.dirtyFields)
            let fields = MetadataConflictFields.fieldConflicts(
                base: base, local: local, current: current, dirtyFields: dirtyFields
            )
            return MetadataConflict(
                xmpPath: row.xmpPath,
                photoPath: row.photoPath,
                revision: Int(row.revision),
                fields: fields
            )
        }
    }

    /// TS: getSessionState —— outbox 计数 + 宿主 reload-ack 的确定性聚合（纯函数 aggregateSessionState）。
    public func getSessionState(sessionId: String) async throws -> CaptureOneSessionState {
        let rawCounts = try await dependencies.writebackStore.outboxCounts(sessionId: sessionId)
        var counts: [String: Int] = [:]
        for (status, value) in rawCounts {
            counts[status] = Int(value)
        }
        // 缺省端口 = 无 ack 事实：保守按未确认处理，绝不凭猜测放行 safeToCleanup。
        let reloadAckedAt = try await dependencies.sessionStore?.reloadAckedAt(sessionId: sessionId)
        return aggregateSessionState(counts: counts, reloadAckedAt: reloadAckedAt)
    }
}
