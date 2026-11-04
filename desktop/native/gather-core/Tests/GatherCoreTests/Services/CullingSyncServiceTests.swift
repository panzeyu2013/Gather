// desktop/native/gather-core/Tests/GatherCoreTests/Services/CullingSyncServiceTests.swift
// 同步服务（写回/确认/清理）的用例（#6 S7：从 CullingServiceTests 整段迁入）。
//
// 搬迁原则：断言逐字不改，只把接收者从门面换成 sync（harness.sync）——
// 覆盖量不变，变的是文件归属，与服务边界一致。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherDelivery
@testable import GatherApplication
@testable import GatherMetadataIO
import GatherTestSupport

@Suite("CullingService 写回协作")
struct CullingWritebackTests {
    @Test("writeback 未确认抛 WRITEBACK_CONFIRM_REQUIRED")
    func writebackRequiresConfirm() async throws {
        let harness = try makeCullingHarness()
        await #expect(throws: CullingServiceError.writebackConfirmRequired) {
            _ = try await harness.sync.writeback(
                sessionId: "session", target: .keyword, confirmed: false
            )
        }
        #expect(harness.writeback.previewCalls.isEmpty)
    }

    @Test("writeback 无决策抛 CULLING_NO_DECISIONS")
    func writebackNoDecisions() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")

        await #expect(throws: CullingServiceError.noDecisions) {
            _ = try await harness.sync.writeback(
                sessionId: "session", target: .keyword, confirmed: true
            )
        }
    }

    @Test("writeback keyword：preview 按决策 id 过滤、关键词合并、persist 与 execute 接同一批项")
    func writebackKeywordFlow() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        try addDecision(harness.db, photoId: "p2", decision: "reject")
        // fake preview 返回两项（含一项不在决策集的，必须被过滤）。
        harness.writeback.previewItems = [
            WritebackItem(
                id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: ["existing"],
                attributes: WritebackAttributes(keywords: ["culling:keep"]),
                xmpPath: "/shoot/p1.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
            WritebackItem(
                id: 2, photoId: "p2", photoPath: "/shoot/p2.jpg", sessionId: "session",
                module: "culling", keywords: [],
                xmpPath: "/shoot/p2.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
            WritebackItem(
                id: 3, photoId: "p3", photoPath: "/shoot/p3.jpg", sessionId: "session",
                module: "culling", keywords: [],
                xmpPath: "/shoot/p3.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
        ]

        _ = try await harness.sync.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        // preview 只携带决策集内的照片 id。
        let previewCall = try #require(harness.writeback.previewCalls.first)
        #expect(previewCall.module == "culling")
        #expect(previewCall.photoIds == ["p1", "p2"])
        // p1 的关键词被合并（保留已有 + 计划关键词），p2 无既有关键词。
        let persisted = try #require(harness.writeback.persistCalls.first)
        #expect(persisted.map(\.photoId) == ["p1", "p2"])
        let p1 = persisted[0]
        #expect(p1.attributes?.keywords == ["existing", "culling:keep"])
        let p2 = persisted[1]
        #expect(p2.attributes?.keywords == ["culling:reject"])
        // execute 接同一批项。
        #expect(harness.writeback.executeCalls.first?.module == "culling")
        #expect(harness.writeback.executeCalls.first?.items.map(\.photoId) == ["p1", "p2"])
    }

    /// TS 合并用的是 [...new Set([...item.keywords, ...attributes.keywords])]：
    /// 既有词与计划词重复时只能保留一次，且保持既有顺序。
    /// 变异「去掉 merged.contains 去重」可杀。
    @Test("writeback keyword 合并去重：既有词与计划词重复只保留一次")
    func writebackKeywordMergeDeduplicates() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        harness.writeback.previewItems = [
            WritebackItem(
                id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: ["culling:keep", "other"],
                attributes: nil,
                xmpPath: "/shoot/p1.xmp", backupPath: "", xmpStatus: "pending",
                errorMessage: "", attemptCount: 0, lastAttemptAt: ""
            ),
        ]

        _ = try await harness.sync.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        let persisted = try #require(harness.writeback.persistCalls.first)
        #expect(persisted.first?.attributes?.keywords == ["culling:keep", "other"],
                "既有词与计划词重复时必须去重且保持既有顺序")
    }

    @Test("writeback rating/color_label 计划：写唯一真相源（cache）的值，不是 keep→5 派生常量")
    func writebackRatingAndLabelPlans() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addDecision(harness.db, photoId: "p1", decision: "keep", rating: 1)
        try addDecision(harness.db, photoId: "p2", decision: "reject", rating: 5)
        try harness.cacheRepo.updateRating(photoId: "p1", rating: 3)
        try harness.cacheRepo.updateRating(photoId: "p2", rating: 0)
        try harness.cacheRepo.updateLabel(photoId: "p1", label: "Blue")
        try harness.cacheRepo.updateLabel(photoId: "p2", label: "None")
        // pending 决策不进计划。
        try addPhoto(harness.db, id: "p3")
        try addDecision(harness.db, photoId: "p3", decision: "pending")
        harness.writeback.previewItems = [
            WritebackItem(id: 1, photoId: "p1", photoPath: "/shoot/p1.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p1.xmp", backupPath: "",
                xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""),
            WritebackItem(id: 2, photoId: "p2", photoPath: "/shoot/p2.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p2.xmp", backupPath: "",
                xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""),
            WritebackItem(id: 3, photoId: "p3", photoPath: "/shoot/p3.jpg", sessionId: "session",
                module: "culling", keywords: [], xmpPath: "/shoot/p3.xmp", backupPath: "",
                xmpStatus: "pending", errorMessage: "", attemptCount: 0, lastAttemptAt: ""),
        ]

        _ = try await harness.sync.writeback(sessionId: "session", target: .rating, confirmed: true)
        let rated = try #require(harness.writeback.persistCalls.first)
        #expect(rated.map(\.photoId) == ["p1", "p2"])
        // p1 用户设 3 星（决策行镜像写着 1）→ 写回必须写 3；keep→5 的派生常量会
        // 在 execute 落盘后反过来污染真相源。
        #expect(rated[0].attributes?.rating == 3)
        #expect(rated[1].attributes?.rating == 0)

        _ = try await harness.sync.writeback(sessionId: "session", target: .colorLabel, confirmed: true)
        let labeled = harness.writeback.persistCalls[1]
        #expect(labeled[0].attributes?.label == "Blue")
        // 写盘标签语义：None → 空串（清空色标）。
        #expect(labeled[1].attributes?.label == "")
    }


    @Test("finalizeSync 未确认抛 CULLING_FINALIZE_CONFIRM_REQUIRED；retryFailedWriteback 未确认抛 WRITEBACK_RETRY_CONFIRM_REQUIRED")
    func finalizeAndRetryConfirmations() async throws {
        let harness = try makeCullingHarness()
        await #expect(throws: CullingServiceError.finalizeConfirmRequired) {
            _ = try await harness.sync.finalizeSync(sessionId: "session", confirmed: false)
        }
        await #expect(throws: CullingServiceError.writebackRetryConfirmRequired) {
            _ = try await harness.sync.retryFailedWriteback(sessionId: "session", confirmed: false)
        }
        try ackReload(harness.db)
        _ = try await harness.sync.finalizeSync(sessionId: "session", confirmed: true)
        _ = try await harness.sync.retryFailedWriteback(sessionId: "session", confirmed: true)
        #expect(harness.writeback.retryFailedCalls.map(\.module) == ["culling"])
        // S5c-2b-1：finalize 已切 DeliveryCoordinator（dropWithoutRestore），
        // 旧 metadataSync.finalizeSession 不再被调用。
    }

    @Test("syncStatus 委托协调器 getSummary")
    func syncStatusDelegates() throws {
        let harness = try makeCullingHarness()
        let summary = try harness.sync.syncStatus(sessionId: "session")
        #expect(summary.sessionId == "session")
    }
}

// MARK: - 确认/清理接 DeliveryCoordinator（Cut 2 / S5c-2a）

/// S5c-2a 的验收面：culling confirm/cleanup 已切交付模型（module = .culling），
/// 而 finalize/writeback 仍在旧链路。用真实 coordinator + 真实 SQLite，只把
/// 文件/指纹换成内存替身，验证：单事务确认、跨会话门禁、外改冲突、失败可重试、
/// 模块过滤，以及「会话写回态由交付聚合派生」（不写已删的 sessions 列）。
@Suite("CullingService 确认/清理（S5c-2a 交付模型）")
struct CullingDeliverySyncTests {
    @Test("confirmSync：单事务把 culling 交付/items 翻 synced，会话态由聚合派生")
    func confirmSyncUsesCoordinator() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1")
        try ackReload(harness.db)

        try await harness.sync.confirmSync(sessionId: "session")

        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.synced.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.map(\.status) == [DeliveryItemStatus.synced.rawValue])
        // 旧两路（metadataSync.confirmSync / writeback.confirmSync）不再被调用。
        // 评审：旧断言 #expect(writeback.confirmSyncCalls.isEmpty) 在协议收窄后已恒真（类型层面
        // 就没有这两个方法）。改成断言真实结果：确认后交付行进入 synced。
        #expect(try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
            .allSatisfy { $0.status == DeliveryItemStatus.synced.rawValue })
        // D-021：会话级写回状态不落库，由交付聚合派生（confirm 后 → done）。
        #expect(try DeliverySummaryQuery(connection: harness.db)
            .summary(sessionId: "session", module: .culling).writebackStatus == .done)
    }

    @Test("confirmSync：failed 交付阻断确认 → XMP_CONFIRM_INCOMPLETE，confirmed_at 不落地")
    func confirmSyncGateMapsToLegacyCode() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        // 失败态只能从 writing 进入（written -> failed 不在状态转移表内）。
        let repo = harness.deliveryRepo
        _ = try repo.createOrGet(xmpPath: "/shoot/p1.xmp", photoPath: "/shoot/p1.jpg", revision: 1)
        _ = try repo.markWriting(xmpPath: "/shoot/p1.xmp", revision: 1)
        _ = try repo.markFailedForTesting(xmpPath: "/shoot/p1.xmp", revision: 1, errorMessage: "boom")
        _ = try repo.upsertItem(xmpPath: "/shoot/p1.xmp", photoId: "p1", module: .culling, status: .failed)
        _ = try repo.linkSession(xmpPath: "/shoot/p1.xmp", sessionId: "session")

        await #expect(throws: DeliveryError.confirmIncomplete) {
            try await harness.sync.confirmSync(sessionId: "session")
        }
        let links = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 'session'"
        ).query()
        #expect(links.allSatisfy { ($0[0].textValue ?? "").isEmpty })
    }

    @Test("confirmSync：跨会话未确认 → XMP_CONFIRM_OTHER_SESSION_PENDING（本会话先落地，交付留 written）")
    func confirmSyncReportsOtherSessionBlocker() async throws {
        let harness = try makeCullingHarness()
        try insertSession(harness.db, "other")
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1", otherSessionId: "other")
        try ackReload(harness.db)

        await #expect(throws: DeliveryError.otherSessionNotConfirmed(sessionId: "other")) {
            try await harness.sync.confirmSync(sessionId: "session")
        }

        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        let own = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 'session'"
        ).query()
        #expect((own[0][0].textValue ?? "").isEmpty == false)
    }

    @Test("cleanup：恢复备份后删交付行；旧两路清理不再调用")
    func cleanupUsesCoordinator() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        _ = try seedWrittenDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")
        try ackReload(harness.db)
        try await harness.sync.confirmSync(sessionId: "session")

        let result = try await harness.sync.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 1)
        #expect(result.errors.isEmpty)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        // 文件阶段：备份内容恢复回 sidecar（restore 幂等覆盖）。
        #expect(harness.deliveryFiles.restoreTargets == ["/shoot/p1.xmp"])
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
        // 同上：清理走交付适配器，旧端口的调用计数恒空、断言无信息量。改为断言行已删除。
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        // 交付行删完后聚合回到 idle（不依赖已删的 sessions.writeback_status）。
        #expect(try DeliverySummaryQuery(connection: harness.db)
            .summary(sessionId: "session", module: .culling).writebackStatus == .idle)
    }

    @Test("cleanup：外部修改 → 标 conflict、不恢复、不删行，错误按旧码回填")
    func cleanupDetectsExternalEdit() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        _ = try seedWrittenDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test",
            baseFingerprint: "fp-baseline"
        )
        try ackReload(harness.db)
        try await harness.sync.confirmSync(sessionId: "session")
        harness.deliveryFingerprint.current = "fp-edited"

        let result = try await harness.sync.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.hasPrefix("XMP_EXTERNALLY_MODIFIED:") == true)
        #expect(result.errors.first?.contains("/shoot/p1.xmp") == true)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.conflict.rawValue)
        #expect(harness.deliveryFiles.restoreTargets.isEmpty)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == nil)
    }

    @Test("cleanup：文件阶段失败保留 intent 且交付仍在；修好后 replay 重试成功")
    func cleanupFailureIsRetryable() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setRestoreFailure(FakeDeliveryFileError.restoreFailed)
        _ = try seedWrittenDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")
        try ackReload(harness.db)
        try await harness.sync.confirmSync(sessionId: "session")

        let failed = try await harness.sync.cleanup(sessionId: "session", confirmed: true)
        #expect(failed.deletedCount == 0)
        #expect(failed.errors.contains { $0.hasPrefix("XMP_CLEANUP_FILE_FAILED") })
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
        // prepared intent 仍在（下次 replay 重做文件，幂等）。
        #expect(try harness.deliveryIntents.pending().prepared.count == 1)
        // cleanup 不重试未完成 intent（由 replay 统一处理）。
        let repeated = try await harness.sync.cleanup(sessionId: "session", confirmed: true)
        #expect(repeated.deletedCount == 0)
        #expect(repeated.errors.contains { $0.hasPrefix("XMP_CLEANUP_INTENT_PENDING") })

        harness.deliveryFiles.clearRestoreFailure()
        let replay = try await harness.deliveryCoordinator.replay()
        #expect(replay.appliedCount == 1)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(try harness.deliveryIntents.pending().prepared.isEmpty)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
    }

    @Test("cleanup：module=.culling 只清本模块交付（face-keyword 已确认交付不动）")
    func cleanupIsModuleScoped() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1", module: .faceKeyword)
        try ackReload(harness.db)
        _ = try harness.deliveryCoordinator.confirm(sessionId: "session", module: .faceKeyword)

        let result = try await harness.sync.cleanup(sessionId: "session", confirmed: true)

        #expect(result.deletedCount == 0)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") != nil)
    }

    @Test("cleanup 未确认抛 WRITEBACK_CLEANUP_CONFIRM_REQUIRED（Confirmed 语义不变）")
    func cleanupRequiresConfirm() async throws {
        let harness = try makeCullingHarness()
        await #expect(throws: CullingServiceError.writebackCleanupConfirmRequired) {
            _ = try await harness.sync.cleanup(sessionId: "session", confirmed: false)
        }
    }

    @Test("默认文件端口：restore 覆盖写回 sidecar、removeFile 幂等、缺备份报错")
    func fileSystemPortRestoresSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-delivery-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("IMG_1.jpg").path
        let sidecar = TSPath.xmpSidecarPath(photo)
        let backup = directory.appendingPathComponent("IMG_1.xmp.gather-backup-test").path
        try "edited".write(toFile: sidecar, atomically: true, encoding: .utf8)
        try "original".write(toFile: backup, atomically: true, encoding: .utf8)

        let port = FileSystemDeliveryFilePort()
        try await port.restore(photoPath: photo, backupPath: backup)
        #expect(try String(contentsOfFile: sidecar, encoding: .utf8) == "original")
        // restore 不消费备份（幂等，删行失败可原样重试）。
        #expect(port.fileExists(backup))

        try await port.removeFile(sidecar)
        #expect(port.fileExists(sidecar) == false)
        try await port.removeFile(sidecar)
        #expect(port.fileExists(sidecar) == false)

        let missing = backup + "-missing"
        await #expect(throws: DeliveryCoordinatorError.backupMissing(xmpPath: missing)) {
            try await port.restore(photoPath: photo, backupPath: missing)
        }
    }
}

// MARK: - 资产分组分页（TS culling-asset-page.test.ts / culling-page.test.ts，
// 真实 SQLite 语义对齐）

@Suite("CullingService 写回镜像与收尾（S5c-2b-1）")
struct CullingDeliveryCut2Tests {
    @Test("writeback 镜像：delivery written + item/link + revision/base/backup 来自交付行")
    func writebackMirrorsWrittenItems() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        harness.writeback.previewItems = [
            makeWritebackItem(id: 1, photoId: "p1", keywords: ["existing"]),
        ]
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: "Written: 1, Failed: 0, Skipped: 0"
        )
        harness.writeback.getItemsResult = [
            makeWritebackItem(
                id: 1, photoId: "p1", xmpStatus: "written",
                keywords: ["existing", "culling:keep"],
                attributes: WritebackAttributes(keywords: ["existing", "culling:keep"])
            ),
        ]
        // S5c-2b-3b-2a：执行器已把备份/指纹/基线直接写进 deliveries；镜像只回读它。
        _ = try seedWrittenDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test",
            baseFingerprint: "fp-written",
            baseValues: .object(["rating": .number(3)])
        )

        let result = try await harness.sync.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        #expect(result.errors.isEmpty)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        // 镜像对新输入重开交付（revision + 1）后再落 written。
        #expect(row.revision == 2)
        #expect(row.baseFingerprint == "fp-written")
        #expect(row.backupPath == "/shoot/p1.xmp.gather-backup-test")
        #expect(row.photoPath == "/shoot/p1.jpg")
        #expect(row.baseValues.objectValue?["rating"]?.numberValue == 3)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.count == 1)
        #expect(items[0].photoId == "p1")
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
        #expect(items[0].keywordList == ["existing", "culling:keep"])
        let links = try harness.db.prepare(
            "SELECT session_id FROM delivery_sessions WHERE delivery_id = ?"
        ).query([.int(row.id)])
        #expect(links.compactMap { $0[0].textValue } == ["session"])
    }

    @Test("writeback 镜像：failed 结果 → delivery failed + item.errorMessage")
    func writebackMirrorsFailedItems() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        let failed = makeWritebackItem(
            id: 1, photoId: "p1", xmpStatus: "failed", errorMessage: "boom"
        )
        harness.writeback.previewItems = [makeWritebackItem(id: 1, photoId: "p1")]
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 0, failed: 1, skipped: 0,
            errors: ["/shoot/p1.jpg: boom"], failedItems: [failed],
            report: "Written: 0, Failed: 1, Skipped: 0"
        )
        harness.writeback.getItemsResult = [failed]

        let result = try await harness.sync.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )

        #expect(result.failed == 1)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.failed.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.failed.rawValue)
        #expect(items[0].errorMessage == "boom")
    }

    @Test("writeback 镜像幂等：重复执行不复制行，只推进 revision")
    func writebackMirrorIsIdempotent() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        try addDecision(harness.db, photoId: "p1", decision: "keep")
        harness.writeback.previewItems = [makeWritebackItem(id: 1, photoId: "p1")]
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )
        // 不提供持久化行：验证 result.written + plan item 的兜底镜像路径。
        let first = try await harness.sync.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )
        let second = try await harness.sync.writeback(
            sessionId: "session", target: .keyword, confirmed: true
        )
        #expect(first.errors.isEmpty)
        #expect(second.errors.isEmpty)
        let deliveries = try harness.db.prepare("SELECT COUNT(*) FROM deliveries").query()
        #expect(deliveries[0][0].intValue == 1)
        let items = try harness.db.prepare("SELECT COUNT(*) FROM delivery_items").query()
        #expect(items[0][0].intValue == 1)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        #expect(row.revision == 1)
    }

    @Test("retryFailedWriteback 镜像：重试后 failed → written")
    func retryFailedWritebackMirrorsWrittenItems() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        let failed = makeWritebackItem(
            id: 1, photoId: "p1", xmpStatus: "failed", errorMessage: "boom"
        )
        let written = makeWritebackItem(
            id: 1, photoId: "p1", xmpStatus: "written",
            attributes: WritebackAttributes(rating: 4)
        )
        harness.writeback.getItemsHandler = { status in
            status == "failed" ? [failed] : [written]
        }
        harness.writeback.executeResult = WritebackResult(
            totalAffected: 1, written: 1, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )

        let result = try await harness.sync.retryFailedWriteback(
            sessionId: "session", confirmed: true
        )

        #expect(result.errors.isEmpty)
        let row = try #require(try harness.deliveryRepo.get("/shoot/p1.xmp"))
        #expect(row.status == DeliveryStatus.written.rawValue)
        let items = try harness.deliveryRepo.listItems(sessionId: "session", module: .culling)
        #expect(items.count == 1)
        #expect(items[0].status == DeliveryItemStatus.written.rawValue)
        #expect(items[0].attributes["rating"]?.numberValue == 4)
    }

    @Test("syncStatus：交付聚合映射 MetadataSyncSummary，按交付去重且 item failed 升级展示态")
    func syncStatusMapsDeliverySummary() throws {
        let harness = try makeCullingHarness()
        let repo = harness.deliveryRepo
        for id in ["p1", "p2", "p3", "p4"] { try addPhoto(harness.db, id: id) }
        _ = try seedSyncedDelivery(harness, photoId: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p2")

        _ = try repo.createOrGet(xmpPath: "/shoot/p3.xmp", photoPath: "/shoot/p3.jpg", revision: 1)
        _ = try repo.markWriting(xmpPath: "/shoot/p3.xmp", revision: 1)
        _ = try repo.markFailedForTesting(xmpPath: "/shoot/p3.xmp", revision: 1, errorMessage: "boom")
        _ = try repo.upsertItem(xmpPath: "/shoot/p3.xmp", photoId: "p3", module: .culling, status: .failed)
        _ = try repo.linkSession(xmpPath: "/shoot/p3.xmp", sessionId: "session")

        _ = try repo.createOrGet(xmpPath: "/shoot/p4.xmp", photoPath: "/shoot/p4.jpg", revision: 1)
        _ = try repo.markWriting(xmpPath: "/shoot/p4.xmp", revision: 1)
        _ = try repo.markConflictForTesting(xmpPath: "/shoot/p4.xmp", revision: 1, errorMessage: "external")
        _ = try repo.upsertItem(xmpPath: "/shoot/p4.xmp", photoId: "p4", module: .culling, status: .written)
        _ = try repo.linkSession(xmpPath: "/shoot/p4.xmp", sessionId: "session")

        let summary = try harness.sync.syncStatus(sessionId: "session")
        #expect(summary.sessionId == "session")
        #expect(summary.pending == 0)
        #expect(summary.writing == 0)
        #expect(summary.written == 1)
        #expect(summary.failed == 1)
        #expect(summary.conflict == 1)
        #expect(summary.synced == 1)
        #expect(summary.items.count == 4)

        // item 失败把 written 交付升级为 failed 计数（UI/confirm 门禁可见）。
        try addPhoto(harness.db, id: "p5")
        _ = try seedWrittenDelivery(harness, photoId: "p5")
        _ = try repo.upsertItem(xmpPath: "/shoot/p5.xmp", photoId: "p5", module: .culling, status: .pending)
        _ = try repo.upsertItem(xmpPath: "/shoot/p5.xmp", photoId: "p5", module: .culling, status: .failed)
        let escalated = try harness.sync.syncStatus(sessionId: "session")
        #expect(escalated.written == 1)
        #expect(escalated.failed == 2)
        #expect(escalated.items.count == 5)
    }

    @Test("flush：回放 delivery intent，不再触发旧 outbox flushSession")
    func flushReplaysIntents() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        let row = try seedSyncedDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test"
        )
        _ = try harness.deliveryIntents.prepare(
            kind: .cleanup,
            xmpPath: "/shoot/p1.xmp",
            payload: DeliveryCleanupPayload(delivery: row, photoPath: "/shoot/p1.jpg").json
        )

        let summary = try await harness.sync.flush(sessionId: "session")

        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(summary.synced == 0)
        #expect(summary.items.isEmpty)
        #expect(try harness.deliveryIntents.pending().isEmpty)
    }

    @Test("retrySync：同样只回放 intent，不再触发旧 retrySession")
    func retrySyncReplaysIntents() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        let row = try seedSyncedDelivery(
            harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test"
        )
        _ = try harness.deliveryIntents.prepare(
            kind: .cleanup,
            xmpPath: "/shoot/p1.xmp",
            payload: DeliveryCleanupPayload(delivery: row, photoPath: "/shoot/p1.jpg").json
        )

        _ = try await harness.sync.retrySync(sessionId: "session")

        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "original")
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
    }

    @Test("finalizeSync：保留 XMP、删交付行/备份，不 restore；重复调用幂等")
    func finalizeDropsWithoutRestore() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        _ = try seedSyncedDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")

        let summary = try await harness.sync.finalizeSync(
            sessionId: "session", confirmed: true
        )

        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(try harness.deliveryRepo.listItems(sessionId: "session").isEmpty)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "gather-written")
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp.gather-backup-test") == nil)
        #expect(harness.deliveryFiles.restoreTargets.isEmpty, "finalize 不得 restore")
        #expect(summary.items.isEmpty)
        #expect(summary.synced == 0)
        let links = try harness.db.prepare("SELECT COUNT(*) FROM delivery_sessions").query()
        #expect(links[0][0].intValue == 0)

        let repeated = try await harness.sync.finalizeSync(
            sessionId: "session", confirmed: true
        )
        #expect(repeated.items.isEmpty)
        #expect(harness.deliveryFiles.removedPaths == ["/shoot/p1.xmp.gather-backup-test"])
    }

    @Test("finalize：只删 synced，conflict / written 原样保留")
    func finalizeOnlyDeletesSynced() async throws {
        let harness = try makeCullingHarness()
        let repo = harness.deliveryRepo
        try addPhoto(harness.db, id: "p1")
        try addPhoto(harness.db, id: "p2")
        try addPhoto(harness.db, id: "p3")
        _ = try seedSyncedDelivery(harness, photoId: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p2")
        _ = try repo.markConflictForTesting(
            xmpPath: "/shoot/p2.xmp", revision: 1, errorMessage: "external"
        )
        _ = try seedWrittenDelivery(harness, photoId: "p3")

        let result = try await harness.deliveryCoordinator.finalize(
            sessionId: "session", module: .culling
        )

        #expect(result.deletedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.errors.isEmpty)
        #expect(try repo.get("/shoot/p1.xmp") == nil)
        #expect(try repo.get("/shoot/p2.xmp")?.status == DeliveryStatus.conflict.rawValue)
        #expect(try repo.get("/shoot/p3.xmp")?.status == DeliveryStatus.written.rawValue)
    }

    @Test("finalize：DB 删除失败保留交付行/备份/fileDone intent，replay 重试成功；备份只在 DB 成功后删")
    func finalizeFailureIsRetryable() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        harness.deliveryFiles.setContents("/shoot/p1.xmp.gather-backup-test", "original")
        harness.deliveryFiles.setContents("/shoot/p1.xmp", "gather-written")
        _ = try seedSyncedDelivery(harness, photoId: "p1", backupPath: "/shoot/p1.xmp.gather-backup-test")
        try harness.db.exec("""
            CREATE TRIGGER fail_finalize_delivery_delete
            BEFORE DELETE ON deliveries
            BEGIN
              SELECT RAISE(ABORT, 'injected finalize delivery delete failure');
            END;
            """)

        let failed = try await harness.deliveryCoordinator.finalize(
            sessionId: "session", module: .culling
        )
        #expect(failed.deletedCount == 0)
        #expect(failed.errors.contains { $0.hasPrefix("XMP_FINALIZE_DB_FAILED") })
        // P1-1：DB 失败时备份绝不能先被删掉（否则 backup_path 悬空）。
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp.gather-backup-test") == "original")
        #expect(harness.deliveryFiles.removedPaths.isEmpty)
        #expect(try harness.deliveryIntents.pending().fileDone.count == 1)

        _ = try harness.db.exec("DROP TRIGGER fail_finalize_delivery_delete")
        let replay = try await harness.deliveryCoordinator.replay()
        #expect(replay.appliedCount == 1)
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp") == nil)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp.gather-backup-test") == nil)
        #expect(harness.deliveryFiles.contents("/shoot/p1.xmp") == "gather-written")
        #expect(harness.deliveryFiles.restoreTargets.isEmpty)
        #expect(try harness.deliveryIntents.pending().isEmpty)
    }

    @Test("reload ack 门禁：未确认时 confirm/finalize 拒绝且不落 confirmed_at/不删行")
    func reloadAckGateBlocksConfirmAndFinalize() async throws {
        let harness = try makeCullingHarness()
        try addPhoto(harness.db, id: "p1")
        _ = try seedWrittenDelivery(harness, photoId: "p1")

        await #expect(throws: DeliveryError.confirmRequiresSync) {
            try await harness.sync.confirmSync(sessionId: "session")
        }
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.written.rawValue)
        let links = try harness.db.prepare(
            "SELECT confirmed_at FROM delivery_sessions WHERE session_id = 'session'"
        ).query()
        #expect(links.allSatisfy { ($0[0].textValue ?? "").isEmpty })

        try ackReload(harness.db)
        try await harness.sync.confirmSync(sessionId: "session")
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)

        _ = try harness.db.prepare(
            "UPDATE sessions SET reload_acked_at = NULL WHERE id = 'session'"
        ).run()
        await #expect(throws: DeliveryError.confirmRequiresSync) {
            _ = try await harness.sync.finalizeSync(sessionId: "session", confirmed: true)
        }
        #expect(try harness.deliveryRepo.get("/shoot/p1.xmp")?.status == DeliveryStatus.synced.rawValue)
    }
}
// P0 / G0：20k 会话的 service 分页性能门（默认跳过；GATHER_CULLING_PERF=1）。
let cullingServicePerfEnabled =
    ProcessInfo.processInfo.environment["GATHER_CULLING_PERF"] == "1"
