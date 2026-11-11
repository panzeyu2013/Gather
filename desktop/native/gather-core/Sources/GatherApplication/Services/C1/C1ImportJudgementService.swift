// desktop/native/gather-core/Sources/GatherApplication/Services/C1/C1ImportJudgementService.swift
// Wave2 / task-11（对照 docs/reviews/2026-11-10-competitive-gap/30-c1-bridge.md G3）：
// 把「从 C1 读到的变体级判断」映射成 Gather 的初始挑片决策与关键词索引。
//
// 边界（与 30 册 §4.4 的"不做/不承诺"一致）：
// - 不解析 C1 catalog DB / .cos，也不写 C1：输入只有 CaptureOneBridge 的只读脚本结果；
// - 只写 Gather 自己的表：photo_metadata_cache（rating/label/keywords）、
//   culling_decisions（decision_source = imported）、photo_keywords/keywords（层级索引）；
// - 绝不自动写 XMP：判断数据留在 Gather 内，写盘仍由用户显式"写回 XMP"触发。
//
// 时序约束（为什么必须等 metadata.scan 终态再写）：
// 导入会入队 metadata.scan → MetadataExtractionService 用整行 upsert 覆盖
// photo_metadata_cache；XMP/sidecar 里没有 rating 时它会写回 0 / 空关键词。若我们在
// 扫描前写 C1 判断，扫描会把它清掉（且扫描的缓存指纹会认为行"已过期"重抽）。
// 因此默认入口 applyAfterIndexing 先等本会话 metadata.scan 到终态再落库；
// 等待有上限（默认 10 分钟），超时/取消也会落库并记入报告（判断不丢，只是可能被
// 仍在跑的扫描覆盖，报告里看得见）。
import Foundation
import GatherPersistence
import GatherProtocol

// MARK: - 映射（唯一真相：报告里逐条列出）

/// C1 → Gather 的判断映射表。
///
/// 三条规则都写死在代码里并有用例守护，报告（C1ImportJudgementReport）只报计数。
public enum C1ImportJudgementMapping {
    /// C1 `color tag` 整数 → Gather 色标。
    ///
    /// C1 16.7 sdef 只声明 `color tag` 是 integer（CaptureOne.sdef:1096），没有枚举；
    /// 本机 C1 的色标集合（COLocalizedStrings：None/Red/Orange/Yellow/Green/Blue/
    /// Pink/Purple）与 Gather `CaptureOneColorLabel` 的声明序一致，映射按该顺序：
    /// 0=None、1=Red、2=Orange、3=Yellow、4=Green、5=Blue、6=Pink、7=Purple。
    /// 越界值返回 nil：不猜、不写，调用方计入 unmappedColorTags（真机核对点）。
    public static func mapColorTag(_ raw: Int) -> CaptureOneColorLabel? {
        // 单一事实源在 Protocol/C1.swift 的 C1ColorTagMapping（G3 读 + G4 写共用；
        // 双向映射必须同表，否则读回来的色标写回去可能变形）。
        C1ColorTagMapping.label(for: raw)
    }

    /// C1 `pick` → Gather pickState：true → keep，false → unreviewed。
    ///
    /// 为什么不把 false 映射成 reject：C1 16.7 sdef 的 variant 只有 `pick` 布尔
    /// （CaptureOne.sdef:1084），没有 reject 位；把"未挑中"当淘汰会把整批未评级的
    /// 照片误标成淘汰。淘汰判定（G4 的 pick/reject 往返）不在本波。
    public static func mapPick(_ pick: Bool) -> PickState {
        pick ? .picked : .unreviewed
    }

    /// C1 decision 字符串（culling_decisions.decision）→ 同 mapPick 的口径。
    public static func decisionValue(_ pick: Bool) -> CullingDecisionValue {
        pick ? .keep : .pending
    }

    /// 同一张照片的多个 variant 合并成一条文件级判断。
    ///
    /// Gather 的逻辑资产是文件（RAW/JPEG 折叠），C1 的 variant 是另一维度；导入时
    /// 只能取一个代表值。合并规则（确定性、可解释）：
    /// - rating：取最大值（任一 variant 的星级高 → 该照片在 Gather 里就是高星）；
    /// - pick：任一 variant 被 picked 即为 keep（pick 是"这张要用"的强信号）；
    /// - colorTag：取第一个能映射出非 None 色标的 variant（保持脚本顺序）；
    /// - keywords：按出现顺序去重合并（大小写不做归一，KeywordCodec 负责 NFC/trim）；
    /// - 输出顺序 = 路径首次出现顺序。
    public static func merge(_ judgements: [C1VariantJudgement]) -> [MergedJudgement] {
        var order: [String] = []
        var byPath: [String: MergedJudgement] = [:]
        for judgement in judgements {
            let path = ScanPath.canonical(judgement.photoPath)
            guard !path.isEmpty else { continue }
            if var existing = byPath[path] {
                existing.rating = max(existing.rating, max(0, min(5, judgement.rating)))
                existing.pick = existing.pick || judgement.pick
                if existing.colorTag == nil,
                   let mapped = mapColorTag(judgement.colorTag), mapped != .none {
                    existing.colorTag = mapped
                }
                var seen = Set(existing.keywords)
                for keyword in judgement.keywords where seen.insert(keyword).inserted {
                    existing.keywords.append(keyword)
                }
                byPath[path] = existing
            } else {
                order.append(path)
                byPath[path] = MergedJudgement(
                    photoPath: path,
                    rating: max(0, min(5, judgement.rating)),
                    colorTag: mapColorTag(judgement.colorTag).flatMap { $0 == .none ? nil : $0 },
                    pick: judgement.pick,
                    keywords: judgement.keywords)
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// 合并后的文件级判断（内部使用；`merge` 的输出元素）。
    public struct MergedJudgement: Equatable, Sendable {
        public var photoPath: String
        public var rating: Int
        /// nil = C1 未给可映射色标（None 或越界）。
        public var colorTag: CaptureOneColorLabel?
        public var pick: Bool
        public var keywords: [String]

        public init(
            photoPath: String,
            rating: Int,
            colorTag: CaptureOneColorLabel?,
            pick: Bool,
            keywords: [String]
        ) {
            self.photoPath = photoPath
            self.rating = rating
            self.colorTag = colorTag
            self.pick = pick
            self.keywords = keywords
        }
    }
}

// MARK: - 报告

/// 一次 C1 判断导入的结果（只做计数/诊断；失败不抛给导入链路）。
public struct C1ImportJudgementReport: Equatable, Sendable {
    /// C1 有判断、且在新会话里找到对应照片的行数（同一文件多 variant 已合并为 1）。
    public var applied: Int
    /// C1 有判断、但新会话里找不到对应照片（路径不一致/导入失败）的行数。
    public var missing: Int
    /// 写入了 C1 星级（rating > 0）的照片数。
    public var ratings: Int
    /// 写入了 C1 色标的照片数。
    public var labels: Int
    /// 写成 keep 决策的照片数。
    public var keeps: Int
    /// 同步了关键词索引的照片数。
    public var keywords: Int
    /// 因已有**人工**决策而保留、不被本次导入覆盖的照片数。
    public var preservedManualDecisions: Int
    /// C1 color tag 越界、未写入的 variant 数（映射表核对点）。
    public var unmappedColorTags: Int
    /// 是否等待过 metadata.scan（false = 调用时已终态/未等）。
    public var waitedForIndexing: Bool
    /// 等待扫描是否超时（true = 判断已落库，但之后仍可能被在跑扫描覆盖）。
    public var indexingTimedOut: Bool
    /// 逐张失败原因（已按"单张失败不影响其余"隔离；只进日志/诊断）。
    public var errors: [String]

    public init(
        applied: Int = 0,
        missing: Int = 0,
        ratings: Int = 0,
        labels: Int = 0,
        keeps: Int = 0,
        keywords: Int = 0,
        preservedManualDecisions: Int = 0,
        unmappedColorTags: Int = 0,
        waitedForIndexing: Bool = false,
        indexingTimedOut: Bool = false,
        errors: [String] = []
    ) {
        self.applied = applied
        self.missing = missing
        self.ratings = ratings
        self.labels = labels
        self.keeps = keeps
        self.keywords = keywords
        self.preservedManualDecisions = preservedManualDecisions
        self.unmappedColorTags = unmappedColorTags
        self.waitedForIndexing = waitedForIndexing
        self.indexingTimedOut = indexingTimedOut
        self.errors = errors
    }

    /// 没有可应用的数据（空选中/全部找不到）——导入链路据此不再产生用户提示。
    public var isEmpty: Bool { applied == 0 && missing == 0 && errors.isEmpty }
}

// MARK: - 服务

/// C1 判断 → Gather 初始状态的落库服务（G3）。
///
/// 非 Sendable 的依据：持有 `any CullingDecisionRepository`（该端口未标 Sendable，
/// 实现 CullingDecisionRepo 也不是 Sendable）。约定**只在单个任务内构造与使用**，
/// 不跨隔离域持有；导入链路的 Task 里从 DBConnection 现造依赖，因此不需要
/// @unchecked 也不引入新的并发风险。
public struct C1ImportJudgementService {
    private let photos: any PhotoRepository
    private let cache: any MetadataRepository
    private let decisions: any CullingDecisionRepository
    private let keywordIndex: KeywordIndexSync
    private let transactions: any TransactionRunner

    public init(
        photos: any PhotoRepository,
        cache: any MetadataRepository,
        decisions: any CullingDecisionRepository,
        keywordIndex: KeywordIndexSync,
        transactions: any TransactionRunner
    ) {
        self.photos = photos
        self.cache = cache
        self.decisions = decisions
        self.keywordIndex = keywordIndex
        self.transactions = transactions
    }

    /// 导入后落库：先等本会话 metadata.scan 到终态，再写判断。
    ///
    /// - Parameters:
    ///   - scanStatus: 本会话最新 metadata.scan 的状态（nil = 还没有 job）；
    ///     生产 = `AnalysisJobRepo.latestScanJob(sessionId:)?.status`。
    ///   - pollInterval: 轮询间隔；
    ///   - timeout: 等待上限（超时也会落库：判断不能丢，报告标记 indexingTimedOut）；
    ///   - sleep: 睡眠接缝（测试注入 no-op，避免真等）。
    public func applyAfterIndexing(
        sessionId: String,
        judgements: [C1VariantJudgement],
        scanStatus: @Sendable (String) throws -> String?,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(600),
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> C1ImportJudgementReport {
        var waited = false
        var timedOut = false
        var elapsed: Duration = .zero
        while true {
            // do/catch 而不是 try?：cleanup ratchet 的 try_optional 指标只降不升（Sources 口径）。
            let status: String?
            do { status = try scanStatus(sessionId) } catch { status = nil }
            if let status, Self.isTerminalScanStatus(status) { break }
            if elapsed >= timeout {
                timedOut = true
                GatherLogger.log(
                    "c1.judgements session=\(sessionId) 等待 metadata.scan 超时（\(timeout)），"
                        + "先落库：之后仍在跑的扫描可能覆盖 rating/关键词",
                    level: .warn)
                break
            }
            do {
                try await sleep(pollInterval)
            } catch {
                // 取消（应用退出/会话关闭）：不等了，仍然落库（尽力而为）。
                break
            }
            waited = true
            elapsed += pollInterval
        }
        var report: C1ImportJudgementReport
        do {
            report = try apply(sessionId: sessionId, judgements: judgements)
        } catch {
            report = C1ImportJudgementReport(
                errors: ["C1_IMPORT_APPLY_FAILED: \(error)"])
        }
        report.waitedForIndexing = waited
        report.indexingTimedOut = timedOut
        if !report.errors.isEmpty {
            GatherLogger.log(
                "c1.judgements session=\(sessionId) errors: "
                    + report.errors.joined(separator: " | "),
                level: .warn)
        }
        return report
    }

    /// 直接落库（测试/已确认扫描完毕的场景）。逐张独立事务：单张失败进 errors，
    /// 不影响其余照片（导入不能因为一条坏数据整体失败）。
    public func apply(
        sessionId: String,
        judgements: [C1VariantJudgement]
    ) throws -> C1ImportJudgementReport {
        guard !judgements.isEmpty else { return C1ImportJudgementReport() }
        let merged = C1ImportJudgementMapping.merge(judgements)
        let rows = try photos.getBySessionProjection(sessionId: sessionId)
        var byPath: [String: PhotoProjectionRow] = [:]
        for row in rows
        where PhotoVisibility.isVisible(archivedAt: row.archivedAt) && row.status != "missing" {
            byPath[ScanPath.canonical(row.filepath)] = row
        }
        var report = C1ImportJudgementReport()
        report.unmappedColorTags = judgements.reduce(into: 0) { count, judgement in
            if C1ImportJudgementMapping.mapColorTag(judgement.colorTag) == nil { count += 1 }
        }
        for judgement in merged {
            guard let row = byPath[judgement.photoPath] else {
                report.missing += 1
                continue
            }
            do {
                let outcome = try applyOne(sessionId: sessionId, row: row, judgement: judgement)
                report.applied += 1
                if outcome.wroteRating { report.ratings += 1 }
                if outcome.wroteLabel { report.labels += 1 }
                if outcome.kept { report.keeps += 1 }
                if outcome.wroteKeywords { report.keywords += 1 }
                if outcome.preservedManualDecision { report.preservedManualDecisions += 1 }
            } catch {
                report.errors.append("\(judgement.photoPath): \(error)")
            }
        }
        return report
    }

    /// 单张落库（一个事务：缓存投影 + 决策行 + 关键词索引一起生效或一起回滚）。
    private func applyOne(
        sessionId: String,
        row: PhotoProjectionRow,
        judgement: C1ImportJudgementMapping.MergedJudgement
    ) throws -> PhotoOutcome {
        try transactions.transaction {
            // 0) 人工决策优先：整张跳过（连缓存都不碰）。理由：rating/label 的唯一真相源
            // 是 photo_metadata_cache，人工决策与其镜像在同一事务里写过；导入再写会
            // 把用户在 Gather 里改过的星级/色标覆盖回 C1 的旧值。ai/template/imported
            // 与空行都允许更新（imported 也需要允许：扫描后二次补写要能覆盖第一次）。
            let existingDecision = try decisions.getDecision(
                sessionId: sessionId, photoId: row.id)
            var outcome = PhotoOutcome()
            if existingDecision?.decisionSource == CullingDecisionSource.manual.rawValue {
                outcome.preservedManualDecision = true
                return outcome
            }

            let existingCache = try cache.get(row.id)

            // 1) 星级：只升级非零 C1 星级；0 = C1 未评级，不覆盖盘上已有的 XMP 星级。
            let finalRating = judgement.rating > 0
                ? Int64(judgement.rating)
                : Int64(existingCache?.rating ?? 0)
            if judgement.rating > 0,
               Int64(judgement.rating) != (existingCache?.rating ?? 0) {
                try cache.updateRating(photoId: row.id, rating: Int64(judgement.rating))
                outcome.wroteRating = true
            }

            // 2) 色标：只写可映射且非 None 的 C1 色标；None/越界不覆盖已有 label。
            if let label = judgement.colorTag, label != .none,
               existingCache?.label != label.rawValue {
                try cache.updateLabel(photoId: row.id, label: label.rawValue)
                outcome.wroteLabel = true
            }
            let finalLabel = judgement.colorTag?.rawValue
                ?? existingCache?.label
                ?? CaptureOneColorLabel.none.rawValue

            // 3) 关键词：C1 有词才与盘上已有词合并（并集保序）写缓存 + 层级索引。
            // C1 没词时不动缓存的既有 XMP 词（那些行由扫描链路负责索引）。
            if !judgement.keywords.isEmpty {
                let existingKeywords = existingCache?.keywords ?? []
                let mergedKeywords = Self.union(existingKeywords, judgement.keywords)
                if mergedKeywords != existingKeywords {
                    try cache.updateKeywords(photoId: row.id, keywords: mergedKeywords)
                }
                _ = try keywordIndex.sync(
                    photoId: row.id, keywords: mergedKeywords, source: .manual)
                outcome.wroteKeywords = true
            }

            // 4) 决策：只写 C1 **明确 pick** 的照片（decision=keep、source=imported）。
            //
            // 为什么不给未 pick 的照片写 pending 决策行：C1 的 pick=false 是默认值，
            // 不是"决定"；若整批都写 imported 决策，CullingDecisionSource.isHumanDecision
            // 会把这批照片当成人工已决策，AI 初审建议永远无法覆盖（真回归）。
            // 星级/色标只投影到 photo_metadata_cache（唯一真相源），不需要决策行承载。
            if judgement.pick {
                let state = CullingDecisionStateInput(
                    decision: C1ImportJudgementMapping.decisionValue(judgement.pick).rawValue,
                    rating: max(0, min(5, finalRating)),
                    colorLabel: finalLabel,
                    revision: (existingDecision?.revision ?? 0) + 1,
                    source: CullingDecisionSource.imported.rawValue)
                try decisions.upsertState(
                    sessionId: sessionId,
                    photoId: row.id,
                    groupId: existingDecision?.groupId ?? "",
                    state: state)
                outcome.kept = true
            }
            return outcome
        }
    }

    /// 单张结果（事务内累积，提交后计数）。
    private struct PhotoOutcome {
        var wroteRating = false
        var wroteLabel = false
        var wroteKeywords = false
        var kept = false
        var preservedManualDecision = false
    }

    /// 关键词并集：保留已有顺序，追加新词（去重按原样比较；NFC/trim 由 KeywordCodec 负责）。
    static func union(_ existing: [String], _ incoming: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for keyword in existing + incoming {
            let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    /// metadata.scan 的终态集合（与 AnalysisJobStatus 的终态语义一致）。
    public static func isTerminalScanStatus(_ status: String) -> Bool {
        let terminal = [
            AnalysisJobStatus.succeeded.rawValue,
            AnalysisJobStatus.failed.rawValue,
            AnalysisJobStatus.cancelled.rawValue,
            AnalysisJobStatus.interrupted.rawValue,
        ]
        return terminal.contains(status)
    }
}