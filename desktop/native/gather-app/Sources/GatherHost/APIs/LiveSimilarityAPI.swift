// desktop/native/gather-app/Sources/GatherHost/APIs/LiveSimilarityAPI.swift
// Cut 1 / B4a：SimilarityAPI 的 Live 实现（10 个方法）。
//
// 对应命令（10 条）：sim.result / analyze / recluster / cancel_analysis /
// preview_writeback / writeback_items / writeback / confirm_sync /
// retry_failed_writeback / cleanup。
//
// 校验归属：
// - 输入类型已完成 sessionId/threshold(0...64)/minGroupSize(>=2)/groupingMode
//   枚举/assignments 归一化/itemIds 非空的校验（D-012、G3、G9 的显式失败）；
// - 本实现只补“裸 sessionId”的非空白 + 长度上限（对齐 LiveCullingAPI）；
// - 3 个破坏性入口只收 Confirmed<T>（writeback / retryFailedWriteback /
//   cleanup），内部不解析 Bool（D-011）；“是否有结果 / 预览是否过期”是交付
//   状态校验，留在本实现（SIM_THRESHOLD_NO_RESULTS / SIM_PREVIEW_STALE）；
// - 阈值/组大小缺省值仍读设置（default_threshold / default_min_group_size），
//   与旧命令面 的解析顺序一致；读到脏值时先经 validateSimilarityParameters
//   显式失败，不把非法设置带进 job。
//
// 任务语义（沿用旧命令面的 sim.* 分支）：
// - analyze / recluster 都建 .similarityAnalyze job（executor 按
//   checkpoint.operation 分派；两者共用会话占用槽，互斥由服务保证），
//   dedupeKey 与 checkpoint 逐字保留；recluster 完成后按解析后的阈值读回
//   SimilarityResult（旧命令的响应形状），analyze 保持 Bool 返回（O5 的返回
//   统一留到 Cut 1 后续评估）；
// - cancelAnalysis：jobService.cancelScope(.similarityAnalyze) + 服务层 abort
//   （job 信号也会链接到占用槽，两条路径都保留）；
// - previewWriteback：getResult → buildSimilarityKeywordPlan → 模块 preview →
//   只保留命中 sidecar 的项并按顺序合并关键词 → persistKeywords（旧命令面 的
//   buildSimilarityKeywordPreview 逐字复刻）；
// - writeback：threshold 指定时先查 hasResult；再按 itemIds 过滤 pending 行，
//   数量不符即 SIM_PREVIEW_STALE；最后 execute。
//
// 边界（Cut 2 / S5c-2b-3b-1）：preview / persistKeywords / writebackItems /
// writeback / retry / confirm / cleanup 全部经 SimilarityService 新接缝进入交付
// 执行器；本文件不再持有 WritebackService，也不解析落库 module 常量。

import Foundation
import CryptoKit
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

public final class LiveSimilarityAPI: SimilarityAPI, @unchecked Sendable {
    private let similarityService: SimilarityService
    private let jobService: JobService
    private let settingsService: SettingsService

    /// @unchecked Sendable 依据：三个依赖都是构造后不再变更的 let；
    /// SimilarityService 的占用槽由 NSLock 保护，其写回/交付端口由注入的执行器
    /// 保证线程安全，JobService/SettingsService 的可变状态各自由内部锁或 DB
    /// 连接串行化（同组合根约定）。
    public init(
        similarityService: SimilarityService,
        jobService: JobService,
        settingsService: SettingsService
    ) {
        self.similarityService = similarityService
        self.jobService = jobService
        self.settingsService = settingsService
    }

    // MARK: - 读

    public func result(_ query: SimilarityResultQuery) async throws -> SimilarityResult? {
        try map {
            try similarityService.getResult(sessionId: query.sessionId, threshold: query.threshold)
        }
    }

    // MARK: - 分析 / 重聚类 / 取消

    /// sim.analyze：建 job + 等待（旧命令成功即 ok(true)）。
    public func analyze(_ input: SimilarityAnalyzeInput) async throws -> Bool {
        let resolvedThreshold = input.threshold.map(Double.init)
            ?? settingsService.getNumber("default_threshold", defaultValue: 10)
        let resolvedMinGroupSize = input.minGroupSize.map(Double.init)
            ?? settingsService.getNumber("default_min_group_size", defaultValue: 2)
        try map {
            try validateSimilarityParameters(threshold: resolvedThreshold, minGroupSize: resolvedMinGroupSize)
        }
        // TS: threshold ?? 'default'（undefined 时不输出数值）；旧 Swift 侧用
        // String(Double) 落键，这里保持同一字形（"10.0"），避免换键后旧 job
        // 无法被同参数请求命中。
        let dedupeThreshold = input.threshold.map { String(Double($0)) } ?? "default"
        let dedupeMinGroupSize = input.minGroupSize.map { String(Double($0)) } ?? "default"
        let job = try map {
            try jobService.create(JobCreateParams(
                type: .similarityAnalyze,
                scopeType: "session",
                scopeId: input.sessionId,
                dedupeKey: "similarity.analyze:\(input.sessionId):"
                    + "\(dedupeThreshold):\(dedupeMinGroupSize):\(input.groupingMode.rawValue)",
                checkpoint: [
                    "threshold": input.threshold.map { .number(Double($0)) } ?? .null,
                    "minGroupSize": input.minGroupSize.map { .number(Double($0)) } ?? .null,
                    "groupingMode": .string(input.groupingMode.rawValue),
                ]
            ))
        }
        let _: Any? = try await mapAsync { try await jobService.waitForResult(jobId: job.id) }
        return true
    }

    /// sim.recluster：建 job（checkpoint.operation=recluster）→ 等到终态 →
    /// 按解析后的阈值读回真实结果；无结果返回 nil（旧命令 ok(null)）。
    public func recluster(_ input: SimilarityAnalyzeInput) async throws -> SimilarityResult? {
        let threshold = input.threshold.map(Double.init)
            ?? settingsService.getNumber("default_threshold", defaultValue: 10)
        let minGroupSize = input.minGroupSize.map(Double.init)
            ?? settingsService.getNumber("default_min_group_size", defaultValue: 2)
        try map {
            try validateSimilarityParameters(threshold: threshold, minGroupSize: minGroupSize)
        }
        let job = try map {
            try jobService.create(JobCreateParams(
                type: .similarityAnalyze,
                scopeType: "session",
                scopeId: input.sessionId,
                dedupeKey: "similarity.recluster:\(input.sessionId):\(threshold):"
                    + "\(minGroupSize):\(input.groupingMode.rawValue)",
                checkpoint: [
                    "operation": .string("recluster"),
                    "threshold": .number(threshold),
                    "minGroupSize": .number(minGroupSize),
                    "groupingMode": .string(input.groupingMode.rawValue),
                ]
            ))
        }
        let _: Any? = try await mapAsync { try await jobService.waitForResult(jobId: job.id) }
        return try map {
            try similarityService.getResult(sessionId: input.sessionId, threshold: Int(threshold))
        }
    }

    /// sim.cancel_analysis：job 批量取消 + 服务层 abort（旧命令同步返回 true）。
    public func cancelAnalysis(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        _ = try map { try jobService.cancelScope(type: .similarityAnalyze, scopeId: id) }
        try map { try similarityService.cancel(sessionId: id) }
        return true
    }

    // MARK: - 预览 / 写回

    private struct SimilarityTokenItem: Encodable {
        let id: Int?
        let xmpPath: String
        let keywords: [String]
        let attributes: WritebackAttributes?
    }

    private struct SimilarityTokenIdentity: Encodable {
        let sessionId: String
        let threshold: Int?
        let stats: SimilarityResultStats
        let groups: [String]
        let items: [SimilarityTokenItem]
    }

    /// 预览身份：当前结果（stats + 组员）+ 本次交付项 + 阈值。
    /// 重聚类/换组/改关键词后令牌变化；不依赖条目顺序或时间。
    private static func previewToken(
        sessionId: String,
        threshold: Int?,
        result: SimilarityResult,
        items: [WritebackItem]
    ) -> String {
        let groups = result.groups.map { group in
            "\(group.id):" + group.images.map(\.path).sorted().joined(separator: ",")
        }.sorted()
        let tokenItems = items.map { item in
            SimilarityTokenItem(
                id: item.id,
                xmpPath: item.xmpPath,
                keywords: item.keywords.sorted(),
                attributes: item.attributes)
        }.sorted { ($0.xmpPath, $0.id ?? -1) < ($1.xmpPath, $1.id ?? -1) }
        let identity = SimilarityTokenIdentity(
            sessionId: sessionId, threshold: threshold,
            stats: result.stats, groups: groups, items: tokenItems)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func previewWriteback(
        _ input: SimilarityPreviewWritebackInput
    ) async throws -> WritebackPreview {
        guard let result = try map({
            try similarityService.getResult(sessionId: input.sessionId, threshold: input.threshold)
        }) else {
            throw GatherError(code: input.threshold == nil
                ? .SIM_ANALYSIS_MISSING
                : .SIM_THRESHOLD_NO_RESULTS)
        }
        let plan = try map {
            try buildSimilarityKeywordPlan(
                groups: result.groups,
                assignments: input.assignments.map { (groupId: $0.groupId, keywords: $0.keywords) }
            )
        }
        let preview = try await mapAsync {
            try await similarityService.previewWriteback(sessionId: input.sessionId)
        }
        // 只保留命中本次 plan 的 sidecar；关键词按“现有在前、新增去重追加”的顺序合并
        // （TS orderedUnion(...)，与 buildSimilarityKeywordPlan 同序）。
        let selectedItems = preview.items
            .filter { plan.keywordsBySidecar[$0.xmpPath] != nil }
            .map { item -> WritebackItem in
                var merged = item
                merged.keywords = orderedUnion(
                    item.keywords,
                    plan.keywordsBySidecar[item.xmpPath] ?? []
                )
                return merged
            }
        try map { try similarityService.persistKeywords(items: selectedItems) }
        return WritebackPreview(
            items: selectedItems,
            totalCount: selectedItems.count,
            affectedPhotos: plan.affectedPaths.count,
            previewToken: Self.previewToken(
                sessionId: input.sessionId, threshold: input.threshold,
                result: result, items: selectedItems)
        )
    }

    public func writebackItems(_ sessionId: String) async throws -> [WritebackItem] {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map {
            try similarityService.writebackItems(sessionId: id)
        }
    }

    // MARK: - 破坏性（Confirmed<T>）

    public func writeback(
        _ input: Confirmed<SimilarityWritebackInput>
    ) async throws -> WritebackResult {
        let payload = input.value
        return try await mapAsync {
            guard let result = try similarityService.getResult(
                sessionId: payload.sessionId, threshold: payload.threshold
            ) else {
                throw GatherError(code: .SIM_THRESHOLD_NO_RESULTS)
            }
            let idSet = Set(payload.itemIds)
            let pendingItems = try similarityService
                .writebackItems(sessionId: payload.sessionId, status: "pending")
                .filter { item in item.id.map { idSet.contains($0) } ?? false }
            guard pendingItems.count == idSet.count else {
                throw GatherError(code: .SIM_PREVIEW_STALE)
            }
            // 预览后结果代/关键词变化 → 令牌不一致，禁止按旧项写盘。
            guard let expected = payload.expectedPreviewToken,
                  expected == Self.previewToken(
                    sessionId: payload.sessionId, threshold: payload.threshold,
                    result: result, items: pendingItems) else {
                throw GatherError(code: .SIM_PREVIEW_STALE)
            }
            return try await similarityService.writeback(
                sessionId: payload.sessionId,
                items: pendingItems
            )
        }
    }

    public func confirmSync(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync {
            _ = try await similarityService.confirmSync(sessionId: id)
            return true
        }
    }

    public func retryFailedWriteback(
        _ input: Confirmed<SessionReference>
    ) async throws -> WritebackResult {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            try await similarityService.retryFailedWriteback(sessionId: sessionId)
        }
    }

    public func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        let sessionId = input.value.sessionId
        return try await mapAsync {
            try await similarityService.cleanup(sessionId: sessionId)
        }
    }

    // MARK: - 校验与错误映射

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.translate(error)
        }
    }

    /// SimilarityServiceError / WritebackServiceError / WritebackPlannerError /
    /// JobServiceError / DBError → GatherError：有专用码的域错误保持码值；
    /// jobFailed 的 message 本身就是错误码时还原为 GatherError；其余原样抛出
    /// （D-030：非域错误不伪造业务码）。
    /// 域臂：Similarity / Writeback / WritebackPlanner；通用臂由 translateDomain 统一处理。
    private static func translate(_ error: Error) -> Error {
        LiveAPIErrorMapping.translateDomain(error) { domainError in
            if let similarity = domainError as? SimilarityServiceError {
                return GatherError(code: similarity.gatherCode, underlying: similarity.description)
            }
            if let writeback = domainError as? WritebackServiceError {
                // allow: string-code（WritebackServiceError 含带消息分支，R1 例外）
                if let code = GatherErrorCode(rawValue: writeback.description) {
                    return GatherError(code: code, underlying: writeback.description)
                }
                return writeback
            }
            if let planner = domainError as? WritebackPlannerError {
                return GatherError(
                    code: .WRITEBACK_GROUP_NOT_IN_SESSION,
                    underlying: planner.description
                )
            }
            return nil
        }
    }
}
