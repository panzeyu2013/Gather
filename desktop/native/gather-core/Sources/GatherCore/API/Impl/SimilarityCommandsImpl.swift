// API/Impl/SimilarityCommandsImpl.swift
// R5 命令层接线：similarity 域实现（批次 B5）。
// 逻辑来源：宿主路由层 sim.* 分支；错误码字符串/门控/返回形状/缺省逐字保留：
// - analyze：threshold / minGroupSize 缺省走设置快照（默认 10 / 2）→ 参数校验 →
//   建 similarity.analyze 作业（dedupeKey / checkpoint 逐字沿用旧分支）→ 等结果；
// - cancel_analysis：取消该会话分析作业与运行时占用；两侧错误照旧吞掉、返回空
//   （旧分支后台异步取消并立即 ok(true)；本实现等待两步完成，契约不变）；
// - recluster：缺省设置解析 + 校验后同步重聚类；
// - result：同步查询；无结果返回 nil（旧响应 ok(null)）；
// - preview_writeback：assignments 归一化（trim / 去重 / 丢弃空串；空列表与空
//   关键词分别按旧码拒绝）→ 取分析结果（无结果按是否带阈值分别抛
//   SIM_ANALYSIS_MISSING / SIM_THRESHOLD_NO_RESULTS）→ 关键词计划 → 写回预览
//   落库 → 返回 WritebackPreview；
// - writeback（破坏性）：confirmed 门控（WRITEBACK_CONFIRM_REQUIRED）→ itemIds
//   非空（SIM_PREVIEW_REQUIRED）→ 阈值存在性（SIM_THRESHOLD_NO_RESULTS）→
//   pending 条目与 itemIds 一致（SIM_PREVIEW_STALE）→ 执行写回；
// - writeback_items：该会话模块 outbox 投影（旧 getItems 无状态过滤）；
// - retry_failed_writeback（破坏性）：confirmed 门控后重试 failed 行；
// - confirm_sync：协调器确认 + 写回条目转 synced；
// - cleanup（破坏性）：confirmed 门控后清理已确认同步的行。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// similarity 域命令实现：注入相似度运行时、作业运行器、写回服务与设置快照。
public actor SimilarityCommandsImpl: SimilarityCommands {
    private let similarity: SimilarityRuntime
    private let jobs: JobRunner
    private let writeback: WritebackService
    private let settings: SettingsSnapshot

    public init(
        similarity: SimilarityRuntime,
        jobs: JobRunner,
        writeback: WritebackService,
        settings: SettingsSnapshot
    ) {
        self.similarity = similarity
        self.jobs = jobs
        self.writeback = writeback
        self.settings = settings
    }

    // MARK: - analyze

    /// 旧命令：`sim.analyze`。校验用缺省走设置项；dedupeKey / checkpoint 只认
    /// 显式入参（缺省 → "default" / null，与旧分支逐字一致）。
    public func analyze(_ params: SimAnalyzeParams) async throws {
        let threshold = params.threshold
        let minGroupSize = params.minGroupSize
        try SimilarityValidation.validate(
            threshold: threshold ?? settings.number(
                SimilarityValidation.defaultThresholdKey,
                default: SimilarityValidation.fallbackThreshold),
            minGroupSize: minGroupSize.map(Double.init) ?? settings.number(
                SimilarityValidation.defaultMinGroupSizeKey,
                default: SimilarityValidation.fallbackMinGroupSize)
        )
        let groupingMode = params.groupingMode ?? .global
        let job = try await jobs.create(JobCreateParams(
            type: .similarityAnalyze,
            scopeType: "session",
            scopeId: params.sessionId,
            dedupeKey: "similarity.analyze:\(params.sessionId):\(threshold.map { String(Double($0)) } ?? "default"):\(minGroupSize.map { String(Double($0)) } ?? "default"):\(groupingMode.rawValue)",
            checkpoint: [
                "threshold": threshold.map { .number($0) } ?? .null,
                "minGroupSize": minGroupSize.map { .number(Double($0)) } ?? .null,
                "groupingMode": .string(groupingMode.rawValue),
            ]
        ))
        _ = try await jobs.waitForResult(jobId: job.id) as Any?
    }

    // MARK: - cancel_analysis

    /// 旧命令：`sim.cancel_analysis`。取消作业作用域 + 运行时占用（只有本模块确
    /// 有在飞分析时才写会话状态），失败静默（旧响应恒 true，本协议返回空）。
    public func cancelAnalysis(_ params: SimCancelAnalysisParams) async throws {
        _ = try? await jobs.cancelScope(type: .similarityAnalyze, scopeId: params.sessionId)
        try? await similarity.cancel(sessionId: params.sessionId, markStatus: false)
    }

    // MARK: - recluster

    /// 旧命令：`sim.recluster`。缺省走设置项，先校验后同步重聚类并返回结果。
    public func recluster(_ params: SimReclusterParams) async throws -> SimilarityResult {
        let threshold = params.threshold ?? settings.number(
            SimilarityValidation.defaultThresholdKey,
            default: SimilarityValidation.fallbackThreshold)
        let minGroupSize = params.minGroupSize.map(Double.init) ?? settings.number(
            SimilarityValidation.defaultMinGroupSizeKey,
            default: SimilarityValidation.fallbackMinGroupSize)
        let groupingMode = params.groupingMode ?? .global
        try SimilarityValidation.validate(threshold: threshold, minGroupSize: minGroupSize)
        return try await similarity.recluster(
            sessionId: params.sessionId,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode
        )
    }

    // MARK: - result

    /// 旧命令：`sim.result`。threshold 缺省取最近档（Double → Int 与旧分支一致）。
    public func result(_ params: SimResultParams) async throws -> SimilarityResult? {
        try await similarity.getResult(
            sessionId: params.sessionId,
            threshold: params.threshold.map { Int($0) }
        )
    }

    // MARK: - preview_writeback

    /// 旧命令：`sim.preview_writeback`。assignments 归一化 → 取结果 → 关键词计划
    /// → 预览落库（pending 行）→ WritebackPreview。
    public func previewWriteback(_ params: SimPreviewWritebackParams) async throws -> WritebackPreview {
        let assignments = try Self.normalizedAssignments(params.assignments)
        let threshold = params.threshold.map { Int($0) }
        guard let result = try await similarity.getResult(
            sessionId: params.sessionId, threshold: threshold) else {
            throw threshold == nil
                ? SimilarityCommandsError.analysisMissing
                : SimilarityCommandsError.thresholdNoResults
        }
        let plan = try buildSimilarityKeywordPlan(
            groups: result.groups,
            assignments: assignments.map { (groupId: $0.groupId, keywords: $0.keywords) }
        )
        let preview = try await writeback.preview(sessionId: params.sessionId, module: "similarity")
        let selectedItems = preview.items
            .filter { plan.keywordsBySidecar[$0.xmpPath] != nil }
            .map { item -> WritebackItem in
                var merged = item
                merged.keywords = Self.orderedUnion(
                    item.keywords,
                    plan.keywordsBySidecar[item.xmpPath] ?? []
                )
                return merged
            }
        try await writeback.persistKeywords(items: selectedItems)
        return WritebackPreview(
            items: selectedItems,
            totalCount: selectedItems.count,
            affectedPhotos: plan.affectedPaths.count
        )
    }

    // MARK: - writeback

    /// 旧命令：`sim.writeback`（破坏性）。确认门控 → itemIds 非空 → 阈值存在性
    /// → pending 条目集合一致 → 执行。
    @discardableResult
    public func writeback(_ params: SimWritebackParams) async throws -> WritebackResult {
        guard params.confirmed else {
            throw SimilarityCommandsError.writebackConfirmRequired
        }
        let threshold = params.threshold.map { Int($0) }
        guard !params.itemIds.isEmpty else {
            throw SimilarityCommandsError.previewRequired
        }
        let idSet = Set(params.itemIds)
        if let threshold,
           !(try await similarity.hasResult(sessionId: params.sessionId, threshold: threshold)) {
            throw SimilarityCommandsError.thresholdNoResults
        }
        let pendingItems = try await writeback.getItems(
            sessionId: params.sessionId, module: "similarity", status: "pending")
            .filter { item in item.id.map { idSet.contains($0) } ?? false }
        guard pendingItems.count == idSet.count else {
            throw SimilarityCommandsError.previewStale
        }
        return try await writeback.execute(
            sessionId: params.sessionId, module: "similarity", items: pendingItems)
    }

    // MARK: - writeback_items

    /// 旧命令：`sim.writeback_items`。全部状态按模块投影。
    public func writebackItems(_ params: SimWritebackItemsParams) async throws -> [WritebackItem] {
        try await writeback.getItems(sessionId: params.sessionId, module: "similarity")
    }

    // MARK: - retry_failed_writeback

    /// 旧命令：`sim.retry_failed_writeback`（破坏性）。confirmed 门控后重试。
    @discardableResult
    public func retryFailedWriteback(
        _ params: SimRetryFailedWritebackParams
    ) async throws -> WritebackResult {
        guard params.confirmed else {
            throw SimilarityCommandsError.retryConfirmRequired
        }
        return try await writeback.retryFailed(sessionId: params.sessionId, module: "similarity")
    }

    // MARK: - confirm_sync

    /// 旧命令：`sim.confirm_sync`。失败项为空时由协调器确认并转 synced；
    /// 旧响应恒 true，本协议返回空。
    public func confirmSync(_ params: SimConfirmSyncParams) async throws {
        try await writeback.confirmSync(sessionId: params.sessionId, module: "similarity")
    }

    // MARK: - cleanup

    /// 旧命令：`sim.cleanup`（破坏性）。confirmed 门控后清理已确认同步的条目。
    @discardableResult
    public func cleanup(_ params: SimCleanupParams) async throws -> CleanupResult {
        guard params.confirmed else {
            throw SimilarityCommandsError.cleanupConfirmRequired
        }
        return try await writeback.cleanup(sessionId: params.sessionId, module: "similarity")
    }

    // MARK: - assignments 归一化

    /// 旧 assignments 校验逐字搬移：空列表 / 空关键词分别拒绝；非对象与
    /// 非字符串元素在类型化 DTO 层已不表达。trim 与去重保持原顺序。
    private static func normalizedAssignments(
        _ assignments: [SimilarityKeywordAssignment]
    ) throws -> [SimilarityKeywordAssignment] {
        guard !assignments.isEmpty else {
            throw SimilarityCommandsError.writebackEmpty
        }
        return try assignments.map { assignment in
            var seen = Set<String>()
            let keywords = assignment.keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !keywords.isEmpty else {
                throw SimilarityCommandsError.writebackInvalidItem
            }
            return SimilarityKeywordAssignment(groupId: assignment.groupId, keywords: keywords)
        }
    }

    /// TS `[...new Set([...a, ...b])]`（预览关键词合并，与旧分支同形）。
    private static func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in a + b where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

/// similarity 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum SimilarityCommandsError: Error, Equatable {
    /// 旧响应 error 串：`SIM_WRITEBACK_EMPTY`。
    case writebackEmpty
    /// 旧响应 error 串：`SIM_WRITEBACK_INVALID_ITEM`。
    case writebackInvalidItem
    /// 旧响应 error 串：`SIM_ANALYSIS_MISSING`。
    case analysisMissing
    /// 旧响应 error 串：`SIM_THRESHOLD_NO_RESULTS`。
    case thresholdNoResults
    /// 旧响应 error 串：`SIM_PREVIEW_REQUIRED`。
    case previewRequired
    /// 旧响应 error 串：`SIM_PREVIEW_STALE`。
    case previewStale
    /// 旧响应 error 串：`WRITEBACK_CONFIRM_REQUIRED`。
    case writebackConfirmRequired
    /// 旧响应 error 串：`WRITEBACK_RETRY_CONFIRM_REQUIRED`。
    case retryConfirmRequired
    /// 旧响应 error 串：`WRITEBACK_CLEANUP_CONFIRM_REQUIRED`。
    case cleanupConfirmRequired
}

extension SimilarityCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .writebackEmpty: "SIM_WRITEBACK_EMPTY"
        case .writebackInvalidItem: "SIM_WRITEBACK_INVALID_ITEM"
        case .analysisMissing: "SIM_ANALYSIS_MISSING"
        case .thresholdNoResults: "SIM_THRESHOLD_NO_RESULTS"
        case .previewRequired: "SIM_PREVIEW_REQUIRED"
        case .previewStale: "SIM_PREVIEW_STALE"
        case .writebackConfirmRequired: "WRITEBACK_CONFIRM_REQUIRED"
        case .retryConfirmRequired: "WRITEBACK_RETRY_CONFIRM_REQUIRED"
        case .cleanupConfirmRequired: "WRITEBACK_CLEANUP_CONFIRM_REQUIRED"
        }
    }
}

extension SimilarityCommandsError {
    /// 桥接层序列化用。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .writebackEmpty: .SIM_WRITEBACK_EMPTY
        case .writebackInvalidItem: .SIM_WRITEBACK_INVALID_ITEM
        case .analysisMissing: .SIM_ANALYSIS_MISSING
        case .thresholdNoResults: .SIM_THRESHOLD_NO_RESULTS
        case .previewRequired: .SIM_PREVIEW_REQUIRED
        case .previewStale: .SIM_PREVIEW_STALE
        case .writebackConfirmRequired: .WRITEBACK_CONFIRM_REQUIRED
        case .retryConfirmRequired: .WRITEBACK_RETRY_CONFIRM_REQUIRED
        case .cleanupConfirmRequired: .WRITEBACK_CLEANUP_CONFIRM_REQUIRED
        }
    }
}
