// desktop/native/gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift
// MetadataAPI 的 Live 实现（18 个方法：7 个历史命令面 + 只读详情 + 模板 8 个
// + triage 写回 2 个）。
//
// 对应命令（7 条历史）：metadata.conflicts / orphans / resolve_conflict /
// resolve_orphan，以及 K0 的 preview / apply_keywords / retry_keyword_writeback；
// P1 的 metadata/templates/triage 入口是类型化新增，没有历史命令。
//
// 依赖（2b-2 起不再持有 MetadataSyncCoordinator；P1-2 起写路径收口）：
// - metadataService：关键词预览/应用/重试（缓存指纹、可写字段白名单、sidecar 分组串行）；
// - deliveryRepo：**只读**查询（conflictDeliveries / items / orphanDeliveries /
//   get / metadataSummary），本文件不再调用它的任何写方法；
// - stateWriter：交付状态与交付项写入的唯一入口（acceptExternalState /
//   reopenConflict / retryOrphan / deleteOrphanDelivery /
//   persistAcceptedRemoteFields）；
// - xmp：冲突的 remote 值读取与孤儿 restore/remove 的文件阶段（旧协调器的同一
//   两个动作，收窄为只读属性 + 三文件操作）。
//
// 校验归属：
// - resolveConflict / resolveOrphan / applyKeywords / retryKeywordWriteback
//   的 choices 非空、未知字段、action 枚举在输入类型收敛（G5/G6）；本实现不
//   重复解析 JSON；
// - 只接收 sessionId 的 conflicts 在这里补"非空白 + 长度上限"校验（对齐
//   LiveAPIInput.requireSessionId），失败统一 GatherError.invalidParameter；
// - 破坏性入口只接收 Confirmed<T>（resolveConflict / resolveOrphan /
//   applyKeywords / retryKeywordWriteback），类型层面保证"没有确认弹窗就写不出
//   调用点"，实现不自行补确认、也不再解析 Bool（D-011）。
//
// 冲突/孤儿的领域判定（D-089 / 2b-2）：
// - 冲突是**交付级**事实：deliveries.status = conflict 且该交付经
//   delivery_sessions 关联到会话。可裁决字段从 delivery_items 派生
//   （rating/label 取自 attributes_json，keywords 取自 keywords 列；无任何可
//   推导字段时退回三个可写字段——旧协调器"无字段级差异也必须给出可裁决项"
//   的同一语义）；remote 值实时读盘（读不到按空属性处理，不伪造冲突）。
// - 裁决写交付：接受远程的字段从本地投影删除（keywords 改为盘上词表），
//   仍有保留字段 → 交付 revision + 1 回到 pending 并重排项（执行器重写本地值）；
//   全部接受 → 以盘上内容为新基线，只走 conflict → writing → written（保留
//   backup_path，cleanup 仍能恢复原文件）。**绝不在这里翻 synced**：synced 是
//   “全部 delivery_sessions 已确认”的跨会话结论，只能由 DeliveryRepo.confirm
//   在事务内判定（P1-10）。裁决只代表本会话接受远程，不代表其它会话已确认。
// - 孤儿 = 没有任何 delivery_sessions 关联的交付（旧 getOrphans 的同一判据）；
//   keep 删行、restore 先回滚文件再删行、retry 只把 failed/pending 重新入队。
//
// 状态写归属（P1-2）：resolveConflict / resolveOrphan 的每一步状态迁移都经
// DeliveryStateWriter 的语义入口，本文件不再出现 mergeInput / markWriting /
// markWritten / markItem / resetConfirmations / deleteOrphanDelivery /
// updateItemAttributes / updateItemKeywords；单步迁移在 GatherDelivery 内仍是
// internal，Host 拼不出绕过 writer 的写序列。冲突裁决“绝不翻 synced”的结论仍由
// DeliveryRepo.confirm 的跨会话门禁保证（见上一条）。
//
// 错误映射：领域码一律以 GatherError 直出（XMP_CONFLICT_NOT_FOUND /
// XMP_CHOICE_MISSING / XMP_ORPHAN_NOT_FOUND / ...），不再依赖旧协调器的
// MetadataSyncError（2b-3 删除旧链路时本文件无需再改）。MetadataServiceError
// 与 DeliveryRepoError 没有协议码，保留原错误（D-030：非域错误不伪造业务码）。
// DBError.message 若本身就是错误码同样还原为 GatherError。

import Foundation
import CryptoKit
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

public final class LiveMetadataAPI: MetadataAPI {
    private let metadataService: MetadataService
    /// 只读查询入口（写路径见 stateWriter，P1-2）。
    private let deliveryRepo: DeliveryRepo
    /// #2：冲突/孤儿处置的用例层（读盘 + 文件锁 + 状态迁移 + 投影）。
    private let disposition: MetadataDispositionService
    private let xmp: any XMPProvider
    /// 与 DeliveryCoordinator / WritebackService 共用的按 xmpPath 文件锁
    /// （组合根构造唯一实例并注入三者）：孤儿 restore/remove 与
    /// cleanup/replay/writeback 串行。
    /// internal（非 private）：组合根契约测试要断言与 coordinator/writeback 同一实例。
    /// #2 起处置服务持有同一实例（这里保留转发字段：组合根契约测试与
    /// AppCompositionTests 直接读它，且它与 coordinator/writeback 必须是同一个）。
    let fileLock: XMPFileLock
    /// P1 / B2：模板与批次（settings 单键 JSON；进程内唯一实例）。
    private let templateStore: MetadataTemplateStore
    private let batchStore: MetadataApplyBatchStore
    private let templateService: MetadataTemplateService
    /// P1 下一波 §3.1：写回生命周期（状态 / 自动确认 / module 作用域结束 / 备份统计）。
    ///
    /// 可选：未接线时三个生命周期方法退回协议默认实现的行为（空状态 + INVALID_PARAM），
    /// 既有构造点（测试 / 预览）不必同时升级。组合根接线见 FeatureAPIs.makeMetadata。
    private let metadataDelivery: MetadataDeliveryService?
    /// P1：设置页“立即清理/备份统计”。
    private let retention: MetadataRetentionService?
    /// Wave2 task-13：关键词库（词库树/补全/改名/合并/同义词）。可选：
    /// 测试/预览构造点不传时词库方法走协议默认实现（显式 INVALID_PARAM）。
    private let keywordLibrary: KeywordLibraryService?

    /// Sendable 由协议继承显式声明：类为 final，所有依赖都是构造后不再变更的
    /// Sendable let（Repo 只持连接、stateWriter 由 deliveryRepo 派生、
    /// XMPProvider 由宿主实现保证），故无需 @unchecked。
    public init(
        metadataService: MetadataService,
        deliveryRepo: DeliveryRepo,
        xmp: any XMPProvider,
        fileLock: XMPFileLock,
        settingsService: SettingsService,
        metadataDelivery: MetadataDeliveryService? = nil,
        retention: MetadataRetentionService? = nil,
        keywordLibrary: KeywordLibraryService? = nil
    ) {
        self.metadataService = metadataService
        self.deliveryRepo = deliveryRepo
        self.xmp = xmp
        self.fileLock = fileLock
        // #2：处置服务由适配器就地装配（依赖与原来完全同源），
        // 因此 FeatureAPIs 与所有测试构造点的参数**零改动**。
        self.disposition = MetadataDispositionService(
            deliveries: deliveryRepo,
            writer: DeliveryStateWriter(repo: deliveryRepo),
            xmp: xmp,
            fileLock: fileLock)
        self.templateStore = MetadataTemplateStore(settings: settingsService)
        self.batchStore = MetadataApplyBatchStore(settings: settingsService)
        self.templateService = MetadataTemplateService(
            templates: templateStore,
            batches: batchStore,
            metadata: metadataService
        )
        self.metadataDelivery = metadataDelivery
        self.retention = retention
        self.keywordLibrary = keywordLibrary
    }

    // MARK: - P1 下一波 §3.1：写回生命周期
    // 注：`backupStats` 已删除（C8）：协议声明 + 实现俱全但 GatherUI 零调用点，
    // 是"假接线"；状态条需要的备份数与体积由 `syncState` 的 backupCount/backupBytes 提供。
    public func cleanupRetention(
        _ input: Confirmed<MetadataCleanupInput>
    ) async throws -> MetadataCleanupSummary {
        guard let retention else { throw Self.lifecycleNotWired("cleanupRetention") }
        // P1-2：会话作用域。原实现只读 ignoreReloadAck，把 run(policy:) 跑成全局，
        // 于是在某个会话点"立即清理已确认备份"会确认（written→synced）并删除
        // **所有会话**的已确认交付与备份。sessionId 必填且此处校验非空白：
        // 破坏性入口不允许因为空串而静默退化成"全库清理"。
        let sessionId = try LiveAPIInput.requireSessionId(input.value.sessionId)
        let policy: MetadataRetentionPolicy = input.value.ignoreReloadAck
            ? .immediate
            : MetadataRetentionPolicy(
                retentionDays: 0, isEnabled: true, batchLimit: 200,
                ignoreReloadAck: false, includeOrphanBackups: true,
                adoptLegacyRows: false)
        let result = await retention.run(policy: policy, sessionId: sessionId)
        return MetadataCleanupSummary(
            deleted: result.deletedDeliveries,
            retained: result.retainedDeliveries,
            skipped: result.skipped,
            errors: result.errors)
    }


    /// 只读状态：metadata/template 两个模块的交付计数、备份体积与逐文件行。
    public func syncState(_ sessionId: String) async throws -> MetadataDeliveryState {
        guard let metadataDelivery else { return MetadataDeliveryState() }
        let id = try LiveAPIInput.requireSessionId(sessionId)
        do {
            return try metadataDelivery.state(sessionId: id)
        } catch {
            throw Self.lifecycleError(error)
        }
    }

    /// 确认同步（.metadata + .template）。
    public func confirmSync(_ input: Confirmed<SessionReference>) async throws -> MetadataDeliveryState {
        guard let metadataDelivery else { throw Self.lifecycleNotWired("confirmSync") }
        let id = try LiveAPIInput.requireSessionId(input.value.sessionId)
        do {
            return try await metadataDelivery.confirmAndMaybeFinalize(sessionId: id)
        } catch {
            throw Self.lifecycleError(error)
        }
    }

    /// 结束同步（只 drop，保留 XMP）；未确认项按 XMP_CONFIRM_INCOMPLETE 逐条进 notices。
    public func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataDeliveryState {
        guard let metadataDelivery else { throw Self.lifecycleNotWired("finalizeSync") }
        let id = try LiveAPIInput.requireSessionId(input.value.sessionId)
        do {
            let outcome = try await metadataDelivery.finalizeSync(sessionId: id)
            var state = outcome.state
            state.finalizedDeleted = outcome.deleted
            state.finalizedRetained = outcome.retained
            state.finalizedSkipped = outcome.skipped
            return state
        } catch {
            throw Self.lifecycleError(error)
        }
    }

    /// 生命周期错误 → GatherError（不新增错误码：INVALID_PARAM / XMP_CONFIRM_* 现有码）。
    private static func lifecycleError(_ error: Error) -> Error {
        if let delivery = error as? MetadataDeliveryError {
            switch delivery {
            case .invalidParameter(let message):
                return GatherError.invalidParameter(field: "sessionId", reason: message)
            case .confirmIncomplete(let blockers):
                return GatherError(
                    code: .XMP_CONFIRM_INCOMPLETE,
                    params: ["detail": blockers.joined(separator: ",")])
            case .reloadNotAcknowledged:
                return GatherError(code: .XMP_CONFIRM_REQUIRES_SYNC)
            }
        }
        return LiveAPIErrorMapping.translateCommon(error) ?? error
    }

    private static func lifecycleNotWired(_ method: String) -> GatherError {
        GatherError.invalidParameter(
            field: method, reason: "metadata lifecycle service not wired")
    }

    /// 写盘成功后自动确认（§3.1.2）。
    ///
    /// 模板/内联/triage 接口没有会话入参：按写入成功的照片反查会话，逐会话确认。
    /// 失败不改变写盘结果（写盘已成功），只记日志——状态条下一次刷新就能看到 written。
    private func autoConfirmAfterWrite(photoIds: [String]) {
        guard let metadataDelivery, !photoIds.isEmpty else { return }
        let sessions: [String]
        do {
            sessions = Set(try metadataService.getPhotosByIds(photoIds).map(\.sessionId)).sorted()
        } catch {
            GatherLogger.log(
                "metadata auto-confirm: session lookup failed (\(photoIds.count) photos)",
                level: .warn)
            return
        }
        for sessionId in sessions {
            let outcome = metadataDelivery.autoConfirmAfterWrite(sessionId: sessionId)
            switch outcome {
            case .confirmed, .nothingToDo:
                continue
            case .deferredToReloadAck, .disabled:
                GatherLogger.log(
                    "metadata auto-confirm kept written: \(outcome) "
                        + "session=\(MetadataDeliveryService.sessionToken(sessionId))",
                    level: .debug)
            case .failed(let message):
                GatherLogger.log(
                    "metadata auto-confirm failed: \(message) "
                        + "session=\(MetadataDeliveryService.sessionToken(sessionId))",
                    level: .warn)
            }
        }
    }

    // MARK: - 读取

    /// P1 / IPTC：只读元数据详情（缓存投影，不触发磁盘解析）。
    public func conflicts(_ sessionId: String) async throws -> [MetadataConflict] {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync { try await disposition.conflicts(id) }
    }

    public func orphans() async throws -> [MetadataOrphan] {
        try await mapAsync { try await disposition.orphans() }
    }

    public func resolveConflict(
        _ input: Confirmed<MetadataResolveConflictInput>
    ) async throws -> MetadataSyncSummary {
        try await mapAsync { try await disposition.resolveConflict(input) }
    }

    public func resolveOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        try await mapAsync { try await disposition.resolveOrphan(input) }
    }
    public func metadata(_ photoId: String) async throws -> PhotoMetadataDetail {
        try map { try metadataService.photoDetail(photoId: photoId) }
    }

    // MARK: - P1 / E：triage 写回

    public func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async throws -> TriageWritebackResult {
        let payload = input.value
        let service = TriageWritebackService(xmp: xmp, metadata: metadataService, batches: batchStore)
        let batchId = UUID().uuidString
        // 逐张从缓存投影取当前星级：缓存是 XMP 的全应用投影，无需再读盘。
        var decisions: [TriageWritebackDecision] = []
        for item in payload.items {
            // "只写空评级"必须以盘上为准：缓存可能落后于外部软件刚写的星级。
            // 读不到盘上星级时用非 0 哨兵跳过 rating：绝不能拿缓存/0 覆盖用户星级。
            var rating = 1
            do {
                let detail = try metadataService.photoDetail(photoId: item.photoId)
                do {
                    let disk = try await metadataService.diskAttributes(photoPath: detail.filepath)
                    rating = Int(disk.rating ?? 0)
                } catch {
                    rating = 1
                }
            } catch {
                rating = 1
            }
            if let decision = TriageWritebackPlanner.plan(
                photoId: item.photoId,
                verdict: item.verdict,
                currentRating: rating,
                manuallyDecided: item.manuallyDecided,
                policy: payload.policy,
                ratingMode: payload.ratingMode
            ) {
                decisions.append(decision)
            }
        }
        let outcome = await service.apply(decisions, batchId: batchId, now: nowISOString())
        autoConfirmAfterWrite(photoIds: outcome.written)
        return TriageWritebackResult(
            batchId: batchId,
            written: outcome.written,
            skipped: outcome.skipped,
            failed: outcome.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) },
            undoAvailable: !outcome.undoable.isEmpty
        )
    }

    public func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> TriageWritebackResult {
        let service = TriageWritebackService(xmp: xmp, metadata: metadataService, batches: batchStore)
        let outcome = try await service.undo(batchId: input.value.batchId)
        return TriageWritebackResult(
            batchId: input.value.batchId,
            written: outcome.written,
            skipped: outcome.skipped,
            failed: outcome.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) },
            undoAvailable: false
        )
    }

    // MARK: - P1 / B2：元数据模板

    public func templates() async throws -> [MetadataTemplateSummary] {
        try map {
            templateStore.list().map { summary($0) }
        }
    }

    public func saveTemplate(_ input: MetadataTemplateSaveInput) async throws -> MetadataTemplateSummary {
        try map {
            let id = input.id ?? UUID().uuidString
            let saved = try templateStore.save(
                MetadataTemplate(id: id, name: input.name, fields: input.fields,
                                 createdAt: "", updatedAt: "", client: input.client),
                now: nowISOString()
            )
            return summary(saved)
        }
    }

    public func templateFields(id: String) async throws -> DescriptiveMetadata {
        try map {
            guard let template = templateStore.get(id: id) else {
                throw MetadataTemplateServiceError.templateNotFound(id)
            }
            return template.fields
        }
    }

    public func deleteTemplate(_ input: Confirmed<MetadataTemplateDeleteInput>) async throws {
        try map { try templateStore.delete(id: input.value.templateId) }
    }

    private struct TemplatePreviewIdentity: Encodable {
        let templateId: String
        let name: String
        let fields: DescriptiveMetadata
        /// Wave2 收尾 task-22：client 参与展开（{client}），必须进预览身份，
        /// 否则改客户名后旧预览令牌仍通过校验。
        let client: String?
        let photoIds: [String]
        let policy: MetadataConflictPolicy
    }

    /// 预览身份：模板内容 + 照片集 + 冲突策略；apply 时按当前状态复算。
    /// 不依赖预览条目顺序（photoIds 排序）或时间。
    private static func previewToken(
        template: MetadataTemplate,
        photoIds: [String],
        policy: MetadataConflictPolicy
    ) -> String {
        let identity = TemplatePreviewIdentity(
            templateId: template.id,
            name: template.name,
            fields: template.fields,
            client: template.client,
            photoIds: photoIds.sorted(),
            policy: policy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(identity)
        } catch {
            data = Data()
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func previewTemplate(_ input: MetadataTemplatePreviewInput) async throws -> MetadataTemplatePreviewResult {
        try await mapAsync {
            guard let template = templateStore.get(id: input.templateId) else {
                throw MetadataTemplateServiceError.templateNotFound(input.templateId)
            }
            // Wave2 收尾 task-22：变量展开/预检明细由 Application 服务统一计算，
            // host 只补 previewToken（与 apply 用同一套 planner/engine，保证同源）。
            var result = try await templateService.preview(
                templateId: input.templateId,
                photoIds: input.photoIds,
                policy: input.policy)
            result.previewToken = Self.previewToken(
                template: template, photoIds: input.photoIds, policy: input.policy)
            return result
        }
    }

    public func applyTemplate(_ input: Confirmed<MetadataTemplateApplyInput>) async throws -> MetadataTemplateApplyOutcome {
        let payload = input.value
        guard let template = templateStore.get(id: payload.templateId) else {
            throw MetadataTemplateServiceError.templateNotFound(payload.templateId)
        }
        guard let expected = payload.expectedPreviewToken,
              expected == Self.previewToken(
                template: template, photoIds: payload.photoIds, policy: payload.policy) else {
            throw GatherError(code: .METADATA_PREVIEW_STALE)
        }
        let result = try await templateService.apply(
            templateId: payload.templateId,
            photoIds: payload.photoIds,
            policy: payload.policy,
            now: nowISOString()
        )
        autoConfirmAfterWrite(photoIds: result.written)
        return MetadataTemplateApplyOutcome(
            batchId: result.batchId,
            written: result.written,
            skipped: result.skipped,
            conflicts: result.conflicts,
            failed: result.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) },
            undoAvailable: result.undoAvailable
        )
    }

    public func diskDescriptive(_ photoId: String) async throws -> DescriptiveMetadata {
        try await mapAsync {
            let detail = try metadataService.photoDetail(photoId: photoId)
            let attributes = try await metadataService.diskAttributes(photoPath: detail.filepath)
            return attributes.descriptive ?? DescriptiveMetadata()
        }
    }

    /// D3：批量直改需要的"盘上是否可信"伴生信息；sidecar 不存在时不能把
    /// 空结构当成"已知空"（导入包的照片 cache 有 IPTC 但盘上无 sidecar）。
    public func diskDescriptiveAvailability(
        photoId: String
    ) async throws -> DiskDescriptiveAvailability? {
        try await mapAsync {
            let detail = try metadataService.photoDetail(photoId: photoId)
            let attributes = try await metadataService.diskAttributes(photoPath: detail.filepath)
            let sidecar = TSPath.xmpSidecarPath(detail.filepath)
            return DiskDescriptiveAvailability(
                descriptive: attributes.descriptive ?? DescriptiveMetadata(),
                sidecarExists: FileManager.default.fileExists(atPath: sidecar))
        }
    }

    public func applyDescriptive(
        _ input: Confirmed<MetadataInlineApplyInput>
    ) async throws -> MetadataTemplateApplyOutcome {
        let payload = input.value
        let result = try await templateService.applyFields(
            fields: payload.fields,
            templateId: MetadataTemplateService.inlineBatchTemplateID,
            templateName: MetadataTemplateService.inlineBatchName,
            photoIds: payload.photoIds,
            policy: payload.policy,
            // 只有补丁本身带了 contact 才整块替换：编辑器只改文字字段时 draft 不提交
            // contactInfo，若仍置 true，executor 会用空结构清掉整块 CreatorContactInfo
            // （P0：静默删除 sidecar 联系人）。
            replaceContact: payload.fields.contactInfo != nil,
            clearedContactMembers: payload.clearedContactMembers ?? [],
            now: nowISOString()
        )
        autoConfirmAfterWrite(photoIds: result.written)
        return MetadataTemplateApplyOutcome(
            batchId: result.batchId,
            written: result.written,
            skipped: result.skipped,
            conflicts: result.conflicts,
            failed: result.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) },
            undoAvailable: result.undoAvailable
        )
    }

    public func recentBatches(limit: Int) async throws -> [MetadataBatchSummary] {
        try map {
            batchStore.list().prefix(max(0, limit)).map { batch in
                MetadataBatchSummary(
                    batchId: batch.id,
                    kind: batch.templateId == TriageWritebackService.batchTemplateID
                        ? "triage"
                        : (batch.templateId == MetadataTemplateService.inlineBatchTemplateID
                            ? "inline" : "template"),
                    name: batch.templateName,
                    appliedAt: batch.appliedAt,
                    undone: batch.undone,
                    photoCount: batch.snapshots.count
                )
            }
        }
    }

    public func undoTemplate(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> MetadataTemplateApplyOutcome {
        let result = try await templateService.undo(batchId: input.value.batchId)
        autoConfirmAfterWrite(photoIds: result.written)
        return MetadataTemplateApplyOutcome(
            batchId: result.batchId,
            written: result.written,
            skipped: result.skipped,
            conflicts: result.conflicts,
            failed: result.failed.map { MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message) },
            undoAvailable: result.undoAvailable
        )
    }

    private func summary(_ template: MetadataTemplate) -> MetadataTemplateSummary {
        MetadataTemplateSummary(
            id: template.id,
            name: template.name,
            fieldCount: template.fields.nonNilFieldCount,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt,
            client: template.client
        )
    }

    // MARK: - 冲突/孤儿处置（Confirmed<T>）

    // MARK: - 交付字段投影

    // MARK: - 孤儿恢复守卫（P0-1 第二入口）

    // MARK: - K0 关键词

    public func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview {
        try await mapAsync {
            let conflicts: Set<String>
            if let sessionId = try metadataService.sessionId(forPhotoIds: input.photoIds) {
                conflicts = Set(
                    try deliveryRepo.conflictDeliveries(sessionId: sessionId).map(\.xmpPath))
            } else {
                conflicts = []
            }
            return try await metadataService.previewKeywords(
                photoIds: input.photoIds,
                added: input.addedKeywords,
                removed: input.removedKeywords,
                conflictedXmpPaths: conflicts
            )
        }
    }

    public func applyKeywords(
        _ input: Confirmed<MetadataKeywordApplyInput>
    ) async throws -> MetadataKeywordApplyResult {
        let payload = input.value
        return try await mapAsync {
            let result = try await metadataService.applyKeywordDelta(
                photoIds: payload.photoIds,
                added: payload.addedKeywords,
                removed: payload.removedKeywords
            )
            // §3.1.2：关键词写盘成功后同样自动确认（否则行永远停在 written）。
            autoConfirmAfterWrite(photoIds: payload.photoIds)
            guard let sessionId = try metadataService.sessionId(forPhotoIds: payload.photoIds) else {
                throw GatherError.invalidParameter(field: "photoIds", reason: "photos not found")
            }
            let status = try deliveryRepo.metadataSummary(sessionId: sessionId, module: .metadata)
            return MetadataKeywordApplyResult(result: result, status: status)
        }
    }

    public func retryKeywordWriteback(
        _ input: Confirmed<SessionReference>
    ) async throws -> MetadataKeywordApplyResult {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            let result = try await metadataService.retryKeywordWriteback(sessionId: sessionId)
            // 重试后写盘成功的项需要立刻确认（会话已知，直接按会话确认）。
            if let metadataDelivery, result.written > 0 {
                _ = metadataDelivery.autoConfirmAfterWrite(sessionId: sessionId)
            }
            let status = try deliveryRepo.metadataSummary(sessionId: sessionId, module: .metadata)
            return MetadataKeywordApplyResult(result: result, status: status)
        }
    }

    // MARK: - Wave2 task-13：关键词库（受控词表）

    public func keywordLibrary(_ query: KeywordLibraryQuery) async throws -> [KeywordLibraryNode] {
        let service = try requireKeywordLibrary()
        return try map { try service.library(query) }
    }

    public func keywordSuggestions(_ query: KeywordSuggestionQuery) async throws -> [KeywordSuggestion] {
        let service = try requireKeywordLibrary()
        return try map { try service.suggestions(query) }
    }

    public func renameKeyword(_ input: Confirmed<KeywordRenameInput>) async throws -> KeywordMutationSummary {
        let service = try requireKeywordLibrary()
        return try map { try service.rename(input.value) }
    }

    public func mergeKeywords(_ input: Confirmed<KeywordMergeInput>) async throws -> KeywordMutationSummary {
        let service = try requireKeywordLibrary()
        return try map { try service.merge(input.value) }
    }

    public func deleteKeyword(_ input: Confirmed<KeywordDeleteInput>) async throws -> KeywordMutationSummary {
        let service = try requireKeywordLibrary()
        return try map { try service.delete(input.value) }
    }

    public func setKeywordSynonyms(
        _ input: Confirmed<KeywordSynonymsInput>
    ) async throws -> KeywordMutationSummary {
        let service = try requireKeywordLibrary()
        return try map { try service.setSynonyms(input.value) }
    }

    public func createKeyword(_ input: Confirmed<KeywordCreateInput>) async throws -> KeywordMutationSummary {
        let service = try requireKeywordLibrary()
        return try map { try service.create(input.value) }
    }

    private func requireKeywordLibrary() throws -> KeywordLibraryService {
        guard let keywordLibrary else {
            throw GatherError.invalidParameter(
                field: "keywordLibrary", reason: "keyword library API not wired")
        }
        return keywordLibrary
    }

    // MARK: - 校验与错误映射

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw LiveAPIErrorMapping.translateCommon(error) ?? error
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw LiveAPIErrorMapping.translateCommon(error) ?? error
        }
    }
}
