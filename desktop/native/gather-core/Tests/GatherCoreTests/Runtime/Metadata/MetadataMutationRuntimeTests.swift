// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Metadata/MetadataMutationRuntimeTests.swift
// MetadataMutationRuntime 直测：Runtime 层 actor 的公开行为（此前仅由构建与
// 域 filter 间接覆盖）。覆盖：
// 1) queuePhotoValues：值直写 outbox（patch 原样 + source 注入）与 dirty 字段
//    过滤；无 rating/label/keywords 的 values 抛 METADATA_MUTATION_EMPTY 且不入队。
// 2) queueMutation 同 xmpPath 串行链：前一回合结束（end）前，后一回合不得进入
//    readAttributes（门控假件 + 进入/结束序号精确断言）；不同 xmpPath 不互相阻塞。
// 3) append/remove/replace 关键词合并语义：outbox pending 关键词优先于磁盘当前值；
//    无 pending 时磁盘值为基线（trim + 首现序去重）。
// 4) 回合内抛错（读失败 / 合并失败）向调用方传播；链释放后后续回合继续执行
//    （不永久卡死），且能看到此前成功回合留下的 pending。
//
// 替身说明：
// - WritebackStore：actor 替身（actor 隔离满足 Sendable，无 @unchecked 标注）。
//   outboxEntry / mergeOutboxPatch 为内存实现（浅合并语义对齐 SQLiteWritebackStore），
//   可注入合并失败；其余协议方法 fatalError —— Runtime 直测不应触达，触达即以
//   崩溃暴露回归，而不是静默通过。
// - XMPProvider：actor 替身，记录 readAttributes 进入/结束序号，支持按路径门控
//   挂起与按次数注入读取失败。
// - PhotoAssetResolver 是 final class（无协议端口，生产文件不可改），故按仓库标准
//   基座 makeMigratedStoreDatabase 建迁移库（仓库统一用唯一临时文件库，未开
//   :memory: 共享路径）并播入 photos 行，使 resolve 返回确定路径。
// - MetadataSyncRuntime 是 actor：构造后立即 shutdown() 停在 stopped 态，
//   queuePhotoValues(schedule: true) 的 schedule 成为 no-op（enqueueSchedule 见
//   stopped 即返回），避免后台基线/写回任务污染对 readAttributes 顺序的观测；
//   测试观测面只剩串行链本身。

import Foundation
import Testing
@testable import GatherCore

private let mutationSessionId = "s-mutation"
private let mutationFirstPhotoPath = "/v/first.cr3"
private let mutationSecondPhotoPath = "/v/second.cr3"

// MARK: - WritebackStore 替身

/// 内存 outbox 替身：记录 mergeOutboxPatch 调用、按路径保存 pending 行、可注入合并失败。
private actor MutationFakeWritebackStore: WritebackStore {
    struct InjectedFailure: Error, Equatable {
        let reason: String
    }

    struct MergeCall: Sendable, Equatable {
        let xmpPath: String
        let sessionId: String
        let photoPath: String
        let patch: JSONValue
        let dirtyFields: [String]
    }

    private(set) var merges: [MergeCall] = []
    private var entries: [String: OutboxRecord] = [:]
    private var revisions: [String: Int64] = [:]
    private var pendingMergeFailures = 0

    /// 让接下来 count 次 mergeOutboxPatch 抛错（模拟回合内合并失败）。
    func failNextMerges(_ count: Int) {
        pendingMergeFailures = count
    }

    func outboxEntry(xmpPath: String) async throws -> OutboxRecord? {
        entries[xmpPath]
    }

    func mergeOutboxPatch(
        xmpPath: String,
        sessionId: String,
        photoPath: String,
        patch: JSONValue,
        dirtyFields: [String]
    ) async throws -> OutboxRecord {
        if pendingMergeFailures > 0 {
            pendingMergeFailures -= 1
            throw InjectedFailure(reason: "merge")
        }
        merges.append(MergeCall(
            xmpPath: xmpPath,
            sessionId: sessionId,
            photoPath: photoPath,
            patch: patch,
            dirtyFields: dirtyFields
        ))
        // 与 SQLiteWritebackStore.mergeOutboxPatch 一致的浅合并：overlay 覆盖 base。
        var mergedPatch = patch
        if let existing = entries[xmpPath],
           let base = try? JSONValue.parse(existing.patchJSON),
           case .object(let baseObject) = base,
           case .object(let overlay) = patch {
            var merged = baseObject
            for (key, value) in overlay { merged[key] = value }
            mergedPatch = .object(merged)
        }
        var mergedDirty: [String] = []
        if let existing = entries[xmpPath],
           let storedDirty = try? JSONValue.parse(existing.dirtyFields),
           let fields = storedDirty.arrayElements {
            for field in fields.compactMap(\.stringValue) where !mergedDirty.contains(field) {
                mergedDirty.append(field)
            }
        }
        for field in dirtyFields where !mergedDirty.contains(field) {
            mergedDirty.append(field)
        }
        let revision = (revisions[xmpPath] ?? 0) + 1
        revisions[xmpPath] = revision
        let record = OutboxRecord(
            xmpPath: xmpPath,
            ownerSessionId: sessionId,
            createdBySessionId: sessionId,
            photoPath: photoPath,
            patchJSON: (try? JSONValue.stringify(mergedPatch)) ?? "{}",
            dirtyFields: (try? JSONValue.stringify(.array(mergedDirty.map { .string($0) }))) ?? "[]",
            sourceModule: patch["source"]?.stringValue ?? "manual",
            revision: revision,
            persistedRevision: 0,
            baseFingerprint: "",
            baseValuesJSON: "{}",
            backupPath: "",
            status: "pending",
            attemptCount: 0,
            errorMessage: "",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        entries[xmpPath] = record
        return record
    }

    // Runtime 只经 outboxEntry / mergeOutboxPatch 触达 store；其余端口以 fatalError
    // 标记（协调器在 harness 内已 shutdown，不会调用）。
    func outboxEntries(sessionId: String) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxEntries(sessionId: String, xmpPaths: [String]) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxEntries(xmpPaths: [String]) async throws -> [OutboxRecord] { fatalError("unused") }
    func outboxSummaries(sessionId: String) async throws -> [OutboxSummary] { fatalError("unused") }
    func outboxSessionIds(xmpPath: String) async throws -> [String] { fatalError("unused") }
    func outboxCounts(sessionId: String) async throws -> [String: Int64] { fatalError("unused") }
    func hasActiveOtherModule(sessionId: String, module: String) async throws -> Bool { fatalError("unused") }
    func recoverableOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func recoverableActiveOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func orphanOutbox() async throws -> [OutboxRecord] { fatalError("unused") }
    func mergeOutboxPatches(_ requests: [OutboxMergeRequest]) async throws -> [OutboxRecord] { fatalError("unused") }
    func claimOutbox(xmpPath: String, expectedRevision: Int64) async throws -> Bool { fatalError("unused") }
    func markOutboxWritten(
        xmpPath: String,
        revision: Int64,
        fingerprint: String,
        baseValues: JSONValue,
        backupPath: String
    ) async throws { fatalError("unused") }
    func markOutboxStatus(xmpPath: String, status: String, errorMessage: String) async throws { fatalError("unused") }
    func markOutboxStatus(
        xmpPath: String,
        expectedRevision: Int,
        status: OutboxStatus,
        errorMessage: String?
    ) async throws -> Bool { fatalError("unused") }
    func resetOutboxForRetry(xmpPath: String) async throws { fatalError("unused") }
    func setOutboxBackupPath(xmpPath: String, backupPath: String) async throws { fatalError("unused") }
    func initializeOutboxBaseline(xmpPath: String, baselineFingerprint: String, baselineValues: JSONValue) async throws { fatalError("unused") }
    @discardableResult func recoverInterruptedOutbox() async throws -> Int { fatalError("unused") }
    func resolveOutboxConflict(
        xmpPath: String,
        patch: JSONValue,
        dirtyFields: [String],
        baselineFingerprint: String,
        baselineValues: JSONValue,
        acceptRemote: Bool
    ) async throws { fatalError("unused") }
    func markSessionSynced(sessionId: String, sourceModule: String) async throws { fatalError("unused") }
    func deleteOutbox(xmpPath: String) async throws { fatalError("unused") }
    func clearOutboxBackupPath(xmpPath: String, backupPath: String) async throws { fatalError("unused") }
    func deleteOutboxByRevision(xmpPath: String, revision: Int64) async throws { fatalError("unused") }
    func discardModulePending(sessionId: String, sourceModule: String) async throws { fatalError("unused") }
    func saveWritebackItems(sessionId: String, module: String, items: [WritebackItemInput]) async throws { fatalError("unused") }
    func writebackItems(sessionId: String, module: String?, status: String?) async throws -> [WritebackItemRecord] { fatalError("unused") }
    func writebackItem(itemId: Int64) async throws -> WritebackItemRecord? { fatalError("unused") }
    func updateWritebackStatus(itemId: Int64, status: String, error: String?) async throws { fatalError("unused") }
    func failedWritebackCount(sessionId: String, module: String?) async throws -> Int { fatalError("unused") }
    func deleteWritebackItems(sessionId: String, module: String?) async throws { fatalError("unused") }
    func deleteWritebackItems(sessionId: String, module: String, ids: [Int64]) async throws { fatalError("unused") }
    func updateWritebackBackupPath(itemId: Int64, path: String) async throws { fatalError("unused") }
    func updateWritebackAttributes(itemId: Int64, attributes: [String: JSONValue]) async throws { fatalError("unused") }
    func updateWritebackKeywords(itemId: Int64, keywords: [String]) async throws { fatalError("unused") }
    func updateWritebackAttributes(_ updates: [WritebackAttributesUpdate]) async throws { fatalError("unused") }
    func updateWritebackKeywords(_ updates: [WritebackKeywordsUpdate]) async throws { fatalError("unused") }
    func markWritebackWrittenAsSynced(sessionId: String, module: String) async throws { fatalError("unused") }
    func updateWritebackStatusByXmpPath(sessionId: String, module: String, xmpPath: String, status: String) async throws { fatalError("unused") }
    func hasActiveWriteback(xmpPath: String) async throws -> Bool { fatalError("unused") }
    @discardableResult func discardWritebackPending(xmpPath: String) async throws -> Int { fatalError("unused") }
    @discardableResult func reconcileWritebackProjection(
        sessionId: String,
        module: String,
        snapshot: [String: OutboxStatus]
    ) async throws -> Int { fatalError("unused") }
    @discardableResult func applyAcceptedRemoteValues(
        sessionId: String,
        xmpPath: String,
        rating: Int?,
        label: String?,
        keywords: [String]?
    ) async throws -> Int { fatalError("unused") }
}

// MARK: - XMPProvider 替身

/// 可观测顺序的 XMP 假件：log 记录每次 readAttributes 的 "start:n" / "end:n"
/// （失败注入为 "fail:n"）；gatedPaths 上的读取挂起直到 openGate()。
private actor MutationOrderedXMPProvider: XMPProvider {
    struct ReadFailure: Error, Equatable {}

    private let attributesByPhotoPath: [String: MetadataWriteAttributes]
    private let gatedPaths: Set<String>
    private var failuresRemaining: [String: Int]
    private var gateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sequence = 0
    private(set) var log: [String] = []

    init(
        attributesByPhotoPath: [String: MetadataWriteAttributes] = [:],
        gatedPaths: Set<String> = [],
        failingReads: [String: Int] = [:]
    ) {
        self.attributesByPhotoPath = attributesByPhotoPath
        self.gatedPaths = gatedPaths
        self.failuresRemaining = failingReads
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        sequence += 1
        let current = sequence
        log.append("start:\(current)")
        if let remaining = failuresRemaining[photoPath], remaining > 0 {
            failuresRemaining[photoPath] = remaining - 1
            log.append("fail:\(current)")
            throw ReadFailure()
        }
        if gatedPaths.contains(photoPath), !gateOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        log.append("end:\(current)")
        return attributesByPhotoPath[photoPath] ?? MetadataWriteAttributes()
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        try await readAttributes(photoPath: photoPath).keywords ?? []
    }

    func openGate() {
        gateOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws { fatalError("unused") }
    func backup(photoPath: String) async throws -> String { fatalError("unused") }
    func restore(photoPath: String, backupPath: String) async throws { fatalError("unused") }
    nonisolated func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws { fatalError("unused") }
}

// MARK: - harness

private struct MutationRuntimeHarness {
    let runtime: MetadataMutationRuntime
    let store: MutationFakeWritebackStore
    let xmp: MutationOrderedXMPProvider
    let database: SQLiteDatabase
    let databasePath: String

    var firstXmpPath: String { TSPath.xmpSidecarPath(mutationFirstPhotoPath) }
    var secondXmpPath: String { TSPath.xmpSidecarPath(mutationSecondPhotoPath) }

    func cleanUp() {
        removeStoreFiles(databasePath)
    }
}

private func makeMutationRuntimeHarness(
    attributesByPhotoPath: [String: MetadataWriteAttributes] = [:],
    gatedPaths: Set<String> = [],
    failingReads: [String: Int] = [:]
) async throws -> MutationRuntimeHarness {
    let (database, databasePath) = try await makeMigratedStoreDatabase(label: "metadata-mutation-runtime")
    try await insertSession(database, mutationSessionId)
    try await insertPhoto(database, id: "p1", sessionId: mutationSessionId, filepath: mutationFirstPhotoPath)
    try await insertPhoto(database, id: "p2", sessionId: mutationSessionId, filepath: mutationSecondPhotoPath)

    let store = MutationFakeWritebackStore()
    let xmp = MutationOrderedXMPProvider(
        attributesByPhotoPath: attributesByPhotoPath,
        gatedPaths: gatedPaths,
        failingReads: failingReads
    )
    let coordinator = MetadataSyncRuntime(
        writebackStore: store,
        xmp: xmp,
        sessionStore: try SQLiteSessionStore(database: database)
    )
    // 立即停机：Runtime 内 queuePhotoValues(schedule: true) 的排程成为 no-op。
    await coordinator.shutdown()

    let runtime = MetadataMutationRuntime(dependencies: .init(
        writebackStore: store,
        xmp: xmp,
        sync: coordinator,
        assetResolver: PhotoAssetResolver(database: database)
    ))
    return MutationRuntimeHarness(
        runtime: runtime,
        store: store,
        xmp: xmp,
        database: database,
        databasePath: databasePath
    )
}

// MARK: - 断言辅助

private func appendPatch(_ values: [String]) -> MetadataPatch {
    MetadataPatch(keywords: MetadataKeywordsPatch(op: .append, values: values))
}

private func removePatch(_ values: [String]) -> MetadataPatch {
    MetadataPatch(keywords: MetadataKeywordsPatch(op: .remove, values: values))
}

private func replacePatch(_ values: [String]) -> MetadataPatch {
    MetadataPatch(keywords: MetadataKeywordsPatch(op: .replace, values: values))
}

private func mergedKeywords(_ merge: MutationFakeWritebackStore.MergeCall?) -> [String]? {
    merge?.patch["keywords"]?.arrayElements?.compactMap(\.stringValue)
}

/// 轮询等待条件成立（避免固定 sleep 掩盖调度延迟）。
private func waitUntil(
    timeoutMs: Int = 3_000,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

// MARK: - 测试

@Suite("Runtime/MetadataMutationRuntime")
struct MetadataMutationRuntimeTests {

    // MARK: a) queuePhotoValues 值直写 + dirty 过滤

    @Test func queuePhotoValuesWritesValuesVerbatimAndFiltersDirtyFields() async throws {
        let harness = try await makeMutationRuntimeHarness()
        defer { harness.cleanUp() }

        let result = try await harness.runtime.queuePhotoValues(
            sessionId: mutationSessionId,
            photoId: "p1",
            values: [
                "rating": .number(4),
                "label": .string(""),
                "keywords": .array([.string("a")]),
                "caption": .string("not-a-dirty-field"),
            ],
            source: .culling,
            schedule: false
        )

        #expect(result.photoId == "p1")
        #expect(result.xmpPath == harness.firstXmpPath)
        #expect(result.revision == 1)
        #expect(result.status == "pending")
        #expect(Set(result.dirtyFields) == [.rating, .label, .keywords])

        let merges = await harness.store.merges
        #expect(merges.count == 1)
        let merge = try #require(merges.first)
        #expect(merge.xmpPath == harness.firstXmpPath)
        #expect(merge.photoPath == mutationFirstPhotoPath)
        #expect(merge.sessionId == mutationSessionId)
        // 值直写：非 dirty 的 caption 也进 patch；source 追加为字符串。
        #expect(merge.patch == .object([
            "rating": .number(4),
            "label": .string(""),
            "keywords": .array([.string("a")]),
            "caption": .string("not-a-dirty-field"),
            "source": .string("culling"),
        ]))
        #expect(Set(merge.dirtyFields) == ["rating", "label", "keywords"])
    }

    @Test func queuePhotoValuesWithoutDirtyFieldsThrowsEmptyAndDoesNotEnqueue() async throws {
        let harness = try await makeMutationRuntimeHarness()
        defer { harness.cleanUp() }

        await #expect(throws: MetadataMutationError.empty) {
            _ = try await harness.runtime.queuePhotoValues(
                sessionId: mutationSessionId,
                photoId: "p1",
                values: ["caption": .string("c"), "source": .string("manual")],
                source: .manual,
                schedule: false
            )
        }
        #expect(await harness.store.merges.isEmpty)

        // 部分命中：只有 rating 记 dirty，其余值照旧直写。
        let result = try await harness.runtime.queuePhotoValues(
            sessionId: mutationSessionId,
            photoId: "p1",
            values: ["rating": .number(3), "caption": .string("c")],
            source: .manual,
            schedule: false
        )
        #expect(result.dirtyFields == [.rating])

        let merges = await harness.store.merges
        let merge = try #require(merges.last)
        #expect(merge.patch == .object([
            "rating": .number(3),
            "caption": .string("c"),
            "source": .string("manual"),
        ]))
        #expect(merge.dirtyFields == ["rating"])
    }

    // MARK: b) 同一 xmpPath 严格按到达顺序串行

    @Test func sameXmpPathQueueMutationRunsStrictlyInArrivalOrder() async throws {
        let harness = try await makeMutationRuntimeHarness(
            attributesByPhotoPath: [
                mutationFirstPhotoPath: MetadataWriteAttributes(keywords: ["k0"]),
            ],
            gatedPaths: [mutationFirstPhotoPath]
        )
        defer { harness.cleanUp() }

        let first = Task {
            try await harness.runtime.queueMutation(
                sessionId: mutationSessionId,
                photoId: "p1",
                patch: appendPatch(["one"]),
                source: .manual
            )
        }
        #expect(await waitUntil { await harness.xmp.log.count == 1 }, "第一回合应进入 readAttributes 并被门控挂起")

        let second = Task {
            try await harness.runtime.queueMutation(
                sessionId: mutationSessionId,
                photoId: "p1",
                patch: appendPatch(["two"]),
                source: .manual
            )
        }
        // 门未开：第二回合不得进入 readAttributes（串行链核心断言）。
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await harness.xmp.log == ["start:1"])
        #expect(await harness.store.merges.isEmpty)

        await harness.xmp.openGate()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(await harness.xmp.log == ["start:1", "end:1", "start:2", "end:2"])
        #expect(firstResult.revision == 1)
        #expect(secondResult.revision == 2)
        #expect(firstResult.dirtyFields == [.keywords])
        #expect(secondResult.dirtyFields == [.keywords])

        let merges = await harness.store.merges
        #expect(mergedKeywords(merges.first) == ["k0", "one"])
        #expect(mergedKeywords(merges.last) == ["k0", "one", "two"], "第二回合应读到第一回合的 pending 关键词")
    }

    @Test func differentXmpPathsAreNotBlockedByAGatedTurn() async throws {
        let harness = try await makeMutationRuntimeHarness(
            attributesByPhotoPath: [
                mutationFirstPhotoPath: MetadataWriteAttributes(keywords: ["a"]),
                mutationSecondPhotoPath: MetadataWriteAttributes(keywords: ["b"]),
            ],
            gatedPaths: [mutationFirstPhotoPath]
        )
        defer { harness.cleanUp() }

        let blocked = Task {
            try await harness.runtime.queueMutation(
                sessionId: mutationSessionId,
                photoId: "p1",
                patch: appendPatch(["x"]),
                source: .manual
            )
        }
        #expect(await waitUntil { await harness.xmp.log.count == 1 }, "p1 回合应被门控挂起")

        let other = Task {
            try await harness.runtime.queueMutation(
                sessionId: mutationSessionId,
                photoId: "p2",
                patch: appendPatch(["y"]),
                source: .manual
            )
        }
        // p2 不等待被挂起的 p1 回合：门未开即可完成入队。
        let otherFinished = await waitUntil { await harness.store.merges.count == 1 }
        #expect(otherFinished, "不同 xmpPath 不应串行于被挂起的回合")

        await harness.xmp.openGate()
        _ = try await blocked.value
        _ = try await other.value

        #expect(await harness.xmp.log == ["start:1", "start:2", "end:2", "end:1"])
        let merges = await harness.store.merges
        #expect(mergedKeywords(merges.first)?.first == "b")
        #expect(mergedKeywords(merges.last) == ["a", "x"])
    }

    // MARK: c) append / remove / replace 合并语义（pending 优先）

    @Test func keywordMergeOpsUsePendingOutboxValuesBeforeDiskValues() async throws {
        let harness = try await makeMutationRuntimeHarness(attributesByPhotoPath: [
            mutationFirstPhotoPath: MetadataWriteAttributes(keywords: ["disk"]),
            mutationSecondPhotoPath: MetadataWriteAttributes(keywords: [" y ", "x", "y", ""]),
        ])
        defer { harness.cleanUp() }

        // replace：values 规范化后直写。
        _ = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: replacePatch(["pending"]), source: .manual
        )
        // append：pending（["pending"]）优先于磁盘 ["disk"]；trim + 首现序去重。
        _ = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: appendPatch(["new", " pending "]), source: .manual
        )
        // remove：从 pending 合并结果中剔除。
        _ = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: removePatch(["pending"]), source: .manual
        )
        // replace：完全覆盖。
        _ = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: replacePatch(["x", "y"]), source: .manual
        )
        // 无 pending 的路径：磁盘值为基线。
        _ = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p2",
            patch: appendPatch(["z"]), source: .manual
        )

        let merges = await harness.store.merges
        #expect(merges.count == 5)
        #expect(mergedKeywords(merges[0]) == ["pending"])
        #expect(mergedKeywords(merges[1]) == ["pending", "new"], "pending 关键词优先于磁盘值 ['disk']")
        #expect(mergedKeywords(merges[1])?.contains("disk") == false)
        #expect(mergedKeywords(merges[2]) == ["new"])
        #expect(mergedKeywords(merges[3]) == ["x", "y"])
        #expect(mergedKeywords(merges[4]) == ["y", "x", "z"], "无 pending 时磁盘关键词 trim + 首现序去重")
        #expect(merges.allSatisfy { $0.dirtyFields == ["keywords"] })
        #expect(merges[4].xmpPath == harness.secondXmpPath)
    }

    // MARK: d) 抛错传播 + 链不永久卡死

    @Test func failedMutationTurnPropagatesErrorAndChainContinues() async throws {
        let harness = try await makeMutationRuntimeHarness(
            attributesByPhotoPath: [
                mutationFirstPhotoPath: MetadataWriteAttributes(keywords: ["k"]),
            ],
            failingReads: [mutationFirstPhotoPath: 1]
        )
        defer { harness.cleanUp() }

        // 读失败：错误传播给调用方，且未入队。
        await #expect(throws: MutationOrderedXMPProvider.ReadFailure.self) {
            _ = try await harness.runtime.queueMutation(
                sessionId: mutationSessionId, photoId: "p1",
                patch: appendPatch(["first"]), source: .manual
            )
        }
        #expect(await harness.store.merges.isEmpty)

        // 链未卡死：下一回合继续执行（pending 为空 → 磁盘 ["k"] 为基线）。
        let second = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: appendPatch(["second"]), source: .manual
        )
        #expect(second.revision == 1)

        // 合并失败：同样传播给调用方。
        await harness.store.failNextMerges(1)
        await #expect(throws: MutationFakeWritebackStore.InjectedFailure.self) {
            _ = try await harness.runtime.queueMutation(
                sessionId: mutationSessionId, photoId: "p1",
                patch: appendPatch(["third"]), source: .manual
            )
        }

        // 链继续：第四回合成功，并看到第二回合留下的 pending。
        let fourth = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: appendPatch(["fourth"]), source: .manual
        )
        #expect(fourth.revision == 2)
        #expect(fourth.status == "pending")

        let merges = await harness.store.merges
        #expect(merges.count == 2)
        #expect(mergedKeywords(merges.first) == ["k", "second"])
        #expect(mergedKeywords(merges.last) == ["k", "second", "fourth"])
        #expect(await harness.xmp.log == [
            "start:1", "fail:1",
            "start:2", "end:2",
            "start:3", "end:3",
            "start:4", "end:4",
        ])
    }

    // MARK: 附带：queueMutation 的字段映射与契约校验前置

    @Test func queueMutationMapsNoneLabelToEmptyStringAndRejectsEmptyPatchBeforeIO() async throws {
        let harness = try await makeMutationRuntimeHarness(attributesByPhotoPath: [
            mutationFirstPhotoPath: MetadataWriteAttributes(keywords: ["k"]),
        ])
        defer { harness.cleanUp() }

        // 空 patch 在 resolve / 读文件之前即被契约层拒绝（无副作用）。
        await #expect(throws: MetadataContractError.patchEmpty) {
            _ = try await harness.runtime.queueMutation(
                sessionId: mutationSessionId, photoId: "p1",
                patch: MetadataPatch(), source: .manual
            )
        }
        #expect(await harness.xmp.log.isEmpty)
        #expect(await harness.store.merges.isEmpty)

        let result = try await harness.runtime.queueMutation(
            sessionId: mutationSessionId, photoId: "p1",
            patch: MetadataPatch(
                rating: MetadataRatingPatch(value: 4),
                label: MetadataLabelPatch(value: "None")
            ),
            source: .culling
        )
        #expect(Set(result.dirtyFields) == [.rating, .label])

        let merges = await harness.store.merges
        let merge = try #require(merges.first)
        #expect(merge.patch["rating"] == .number(4))
        #expect(merge.patch["label"] == .string(""), "'None' 写盘语义为空串")
        #expect(merge.patch["source"] == .string("culling"))
    }
}
