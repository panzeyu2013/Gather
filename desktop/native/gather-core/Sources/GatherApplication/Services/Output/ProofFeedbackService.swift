// desktop/native/gather-core/Sources/GatherApplication/Services/Output/ProofFeedbackService.swift
// P1 下一波：客户校样反馈 v2 的导入与落库。
//
// 一次导入做四件事（顺序固定，失败面逐段隔离）：
// 1. 解析 selection.json（v1/v2）→ 条目；
// 2. 原始反馈**全量落库**（client_proof_feedback；未知 id 不落库但计入 skipped）；
// 3. 应用：picks → CullingService.applyImportedPicks（source=imported，有人工保护）；
//          rating/label → MetadataMutationService 入队（冲突不覆盖本地）；
//          comment → 只落库（不写 XMP，不覆盖 dc:description）；
// 4. 记 applied_at（幂等：同一 batch 第二次导入 0 变更）。
//
// 幂等键 = batch_id = selection.json 内容 SHA-256 前 12 位：同一份文件重复导入
// 直接短路（alreadyImported=true），改了一个字的文件则是新 batch。
//
// P1-5：短路条件不是"batch 存在"而是"batch 存在**且本次要应用的行都已 applied_at
// 非空**"。原实现只看 batchExists，而落库在第 2 步、应用在第 3 步——中间抛错会留下
// applied_at='' 的行，重试被短路成 0 变更，客户勾选/评分永久丢失。现在这种"半成品
// batch"走补偿重放（只对未 applied 的行重做第 2/3 步），并用日志区分重放与首导。
//
// 冲突判定：本地值 != 客户值 且 本地 updated_at > submittedAt → 冲突，保留本地并
// 逐条上报（UI 给"用客户值"）。本地没有缓存行 = 没有本地真相 → 直接采用。
//
// 端口化：picks / metadata 都是协议，生产实现是 CullingService / MetadataMutationService，
// 测试可以直接断言"入队了什么值"，不需要真库。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

/// 勾选应用端口（生产 = CullingService）。
public protocol ProofPickApplying: AnyObject {
    /// - Returns: (真正应用的 photoIds, 单张失败数)。人工保护导致的跳过不计入两者。
    func applyImportedPicks(
        sessionId: String, photoIds: [String]
    ) throws -> (appliedPhotoIds: [String], failed: Int)
}

/// 评分/色标入队端口（生产 = MetadataMutationService）。
public protocol ProofMetadataQueueing: AnyObject {
    /// 入队评分/色标；nil 表示本次不改该字段。返回是否真的入队。
    @discardableResult
    func queueRatingLabel(
        sessionId: String, photoId: String, rating: Int?, label: String?
    ) throws -> Bool
}

/// 生产实现：CullingService.applyImportedPicks。
public final class CullingProofPickApplier: ProofPickApplying {
    private let service: CullingService

    public init(service: CullingService) {
        self.service = service
    }

    public func applyImportedPicks(
        sessionId: String, photoIds: [String]
    ) throws -> (appliedPhotoIds: [String], failed: Int) {
        let outcome = try service.applyImportedPicks(
            sessionId: sessionId, photoIds: photoIds)
        return (outcome.appliedPhotoIds, outcome.failed)
    }
}

/// 生产实现：MetadataMutationService（评分/色标进 metadata 交付项，执行器刷盘）。
///
/// 注意：MetadataMutationSource 目前没有 .imported 分支（Metadata.swift 不在本波
/// 文件清单），而 MetadataMutationService.enqueue 也不落 source 列——"客户导入"这一
/// 事实由 client_proof_feedback.applied_at 记账。父 agent 若补上 .imported，只需把
/// init 的 source 参数改成 .imported，本文件其他部分不用动。
public final class MetadataMutationProofQueue: ProofMetadataQueueing {
    private let mutations: any MetadataMutationPort
    private let source: MetadataMutationSource

    public init(
        mutations: any MetadataMutationPort,
        source: MetadataMutationSource = .culling
    ) {
        self.mutations = mutations
        self.source = source
    }

    @discardableResult
    public func queueRatingLabel(
        sessionId: String, photoId: String, rating: Int?, label: String?
    ) throws -> Bool {
        var values: [String: JSONValue] = [:]
        if let rating { values["rating"] = .number(Double(max(0, min(5, rating)))) }
        if let label {
            // 空串 = 清空色标（与 MetadataField 三态一致的显式清空）。
            values["label"] = .string(label)
        }
        guard !values.isEmpty else { return false }
        _ = try mutations.queuePhotoValues(
            sessionId: sessionId, photoId: photoId, values: values, source: source)
        return true
    }
}

public enum ProofFeedbackServiceError: Error, Equatable, CustomStringConvertible {
    case invalidSession
    case invalidFile(String)

    /// 复用已登记码（不新增全局错误码）。
    public var code: String { GatherErrorCode.INVALID_PARAM.rawValue }

    public var description: String {
        switch self {
        case .invalidSession: code + ": sessionId 为空"
        case .invalidFile(let reason): code + ": " + reason
        }
    }

    public var gatherError: GatherError {
        switch self {
        case .invalidSession:
            GatherError(code: .INVALID_PARAM, params: ["field": "sessionId", "reason": "empty"])
        case .invalidFile(let reason):
            GatherError(code: .INVALID_PARAM, params: ["field": "selection.json", "reason": reason])
        }
    }
}

public final class ProofFeedbackService {
    /// 评分/色标是否自动应用（设置键 proof_feedback_apply_rating，默认 0 = 只落库）。
    public static let applyRatingSettingKey = "proof_feedback_apply_rating"

    private let repo: ProofFeedbackRepo
    private let picks: (any ProofPickApplying)?
    private let metadata: (any ProofMetadataQueueing)?
    private let getString: (String, String) -> String
    private let now: () -> Date

    public init(
        repo: ProofFeedbackRepo,
        picks: (any ProofPickApplying)? = nil,
        metadata: (any ProofMetadataQueueing)? = nil,
        getString: @escaping (String, String) -> String = { _, defaultValue in defaultValue },
        now: @escaping () -> Date = Date.init
    ) {
        self.repo = repo
        self.picks = picks
        self.metadata = metadata
        self.getString = getString
        self.now = now
    }

    /// batch_id = 内容哈希前 12 位（同一份文件 = 同一个 batch）。
    public static func batchId(for data: Data) -> String {
        let digest = SHA256.hash(data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    /// 导入 selection.json（v1/v2）。
    public func `import`(
        sessionId: String,
        data: Data
    ) throws -> ClientSelectionImportReport {
        let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else { throw ProofFeedbackServiceError.invalidSession }
        let parsed: ParsedClientSelection
        do {
            parsed = try ClientSelectionParser.parse(data)
        } catch let error as ClientSelectionError {
            throw error.gatherError
        }
        let batchId = Self.batchId(for: data)
        let submittedAt = parsed.submittedAt ?? ""
        // 评分/色标是否自动应用（设置关掉时只落库，不碰本地值）。提到短路之前：
        // "这条 batch 还有没有活要干"取决于这个开关。
        let applyRating = getString(Self.applyRatingSettingKey, "0") == "1" && metadata != nil

        let allIds = parsed.items.map(\.photoId)
        let known = try repo.existingPhotoIds(
            sessionId: trimmedSession, photoIds: allIds)
        let knownItems = parsed.items.filter { known.contains($0.photoId) }
        let unknownCount = parsed.items.count - knownItems.count
        let importedAt = isoString(now())

        // 幂等 + 补偿重放（P1-5）。
        //
        // 原实现只看 batchExists：落库（insertBatch）在应用之前，两步之间抛错会留下
        // applied_at='' 的行；重试被短路成"已导入/0 变更"，客户勾选与评分就永久丢失。
        //
        // 现在：只有"这条 batch 已落库，且**本次真正要应用的行**全部 applied_at 非空"
        // 才短路；否则对剩余未应用行重放。刻意不写成"全部行非空"：评分应用默认关闭
        // （proof_feedback_apply_rating=0），那些行按设计永远不会被消费，否则短路永远
        // 不可达、每次重导都是 0 变更。
        let existingRows = try repo.rows(batchId: batchId)
        let appliedIds = Set(existingRows.filter(\.isApplied).map(\.photoId))
        let isReplay: Bool
        if existingRows.isEmpty {
            isReplay = false
        } else {
            let pendingPicks = picks == nil
                ? []
                : parsed.pickedPhotoIds.filter {
                    known.contains($0) && !appliedIds.contains($0)
                }
            let pendingFeedback = applyRating
                ? knownItems.filter {
                    ($0.rating != nil || $0.label != nil) && !appliedIds.contains($0.photoId)
                }
                : []
            if pendingPicks.isEmpty, pendingFeedback.isEmpty {
                // 全部要应用的行都已经消费过：0 变更（不再入队/不再覆盖任何本地值）。
                return ClientSelectionImportReport(
                    picked: parsed.pickedPhotoIds.count,
                    applied: 0,
                    skipped: parsed.items.count,
                    failed: 0,
                    alreadyImported: true)
            }
            isReplay = true
        }
        if isReplay {
            // 与首导区分：这是"上次落库后应用没跑完"的补偿重放（批次内容相同）。
            GatherLogger.log(
                "proof feedback replay batch=\(batchId) rows=\(existingRows.count) "
                    + "applied=\(appliedIds.count)",
                level: .info)
        }

        // 1) 原始反馈全量落库（应用与否后面用 applied_at 标）。
        //    重放不再落库：(batch_id, photo_id) 是幂等键，行已经在库里。
        if !isReplay {
            let inserts = knownItems.map { item in
                ProofFeedbackInsert(
                    photoId: item.photoId,
                    pickState: Self.pickState(for: item),
                    rating: item.rating,
                    label: item.label ?? "",
                    comment: item.comment ?? "",
                    submittedAt: submittedAt)
            }
            let inserted = try repo.insertBatch(
                batchId: batchId, sessionId: trimmedSession, items: inserts,
                importedAt: importedAt)
            if inserted == 0, !inserts.isEmpty {
                // 并发导入同一个文件：另一个调用已经落库 → 本调用按"已导入"处理。
                return ClientSelectionImportReport(
                    picked: parsed.pickedPhotoIds.count,
                    applied: 0,
                    skipped: parsed.items.count,
                    failed: 0,
                    alreadyImported: true)
            }
        }

        // 2) 勾选：走既有 applyImportedPicks（人工决策保护在服务里）。
        //    已 applied 的照片不再重复应用（重放时只做剩下的）。
        let pickedIds = parsed.pickedPhotoIds.filter {
            known.contains($0) && !appliedIds.contains($0)
        }
        var pickedAppliedIds = Set<String>()
        var applied = 0
        var failed = 0
        var skipped = unknownCount
        if pickedIds.isEmpty || picks == nil {
            skipped += pickedIds.count
        } else if let picks {
            let outcome = try picks.applyImportedPicks(
                sessionId: trimmedSession, photoIds: pickedIds)
            pickedAppliedIds = Set(outcome.appliedPhotoIds)
            applied = pickedAppliedIds.count
            failed = outcome.failed
            // 人工保护导致的未应用：既不成功也不失败，但要能被数出来。
            skipped += max(0, pickedIds.count - applied - failed)
        }

        // 3) 评分/色标：设置关掉时只落库（不碰本地值；applyRating 已在函数前段算好，
        //    因为"这条 batch 还有没有活要干"要用它判断是否重放）。
        var ratingApplied = 0
        var labelApplied = 0
        var conflicts: [ProofFeedbackConflict] = []
        var queued = Set<String>()
        var comments = 0

        // 已 applied 的照片不再重复入队（重放只做剩下的）。
        let ratingItems = knownItems.filter {
            ($0.rating != nil || $0.label != nil) && !appliedIds.contains($0.photoId)
        }
        let localStates = try repo.localRatingStates(
            sessionId: trimmedSession, photoIds: ratingItems.map(\.photoId))
        let submittedDate = submittedAt.isEmpty ? nil : tsParseISODate(submittedAt)

        for item in ratingItems {
            if !applyRating || metadata == nil {
                // 只落库：计入 skipped（"评分未应用"要能被数出来，而不是静默丢弃）。
                skipped += 1
                continue
            }
            let local = localStates[item.photoId]
            if let conflict = Self.detectConflict(
                item: item, local: local, submittedAt: submittedDate) {
                conflicts.append(conflict)
                skipped += 1
                continue
            }
            do {
                let queuedOK = try metadata?.queueRatingLabel(
                    sessionId: trimmedSession, photoId: item.photoId,
                    rating: item.rating, label: item.label) ?? false
                if queuedOK {
                    if item.rating != nil { ratingApplied += 1 }
                    if item.label != nil { labelApplied += 1 }
                    queued.insert(item.photoId)
                } else {
                    skipped += 1
                }
            } catch {
                // 单张入队失败（照片不在会话/交付行冲突）只影响该张。
                failed += 1
            }
        }

        // 4) 评论：只落库，不写 XMP（insertBatch 已落）。
        for item in knownItems where !(item.comment ?? "").isEmpty {
            comments += 1
        }

        // 审计：真正被消费的行标 applied_at（真实勾选成功 + 评分/色标入队）。
        let appliedPhotoIds = Array(queued.union(pickedAppliedIds))
        if !appliedPhotoIds.isEmpty {
            _ = try repo.markApplied(
                batchId: batchId, photoIds: appliedPhotoIds, at: isoString(now()))
        }

        return ClientSelectionImportReport(
            picked: parsed.pickedPhotoIds.count,
            applied: applied,
            skipped: skipped,
            failed: failed,
            ratingApplied: ratingApplied,
            labelApplied: labelApplied,
            comments: comments,
            conflicts: conflicts,
            alreadyImported: false)
    }

    /// 检查器徽章用：该会话每条照片最近一条非空评论。
    public func comments(sessionId: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try repo.commentRows(sessionId: sessionId) where !row.comment.isEmpty {
            if result[row.photoId] == nil { result[row.photoId] = row.comment }
        }
        return result
    }

    /// 该会话已导入的批次数（UI 用：0 = 从没有客户反馈）。
    public func importedBatches(sessionId: String) throws -> Int {
        try repo.batchCount(sessionId: sessionId)
    }

    // MARK: - 纯逻辑

    static func pickState(for item: ClientFeedbackItem) -> String {
        switch item.pick {
        case .some(true): PickState.picked.rawValue
        case .some(false): PickState.rejected.rawValue
        case .none: PickState.unreviewed.rawValue
        }
    }

    /// 冲突：本地值 != 客户值 且 本地比客户提交更新。
    ///
    /// 本地没有缓存行（local == nil）= 没有本地真相 → 不算冲突。
    /// 本地 updated_at 解析失败 → 视为"不知道"，按不冲突处理。
    static func detectConflict(
        item: ClientFeedbackItem,
        local: LocalRatingState?,
        submittedAt: Date?
    ) -> ProofFeedbackConflict? {
        guard let local else { return nil }
        let ratingDiffers = item.rating.map { $0 != local.rating } ?? false
        let localLabel = local.label.isEmpty ? "" : local.label
        let labelDiffers = item.label.map { $0 != localLabel } ?? false
        guard ratingDiffers || labelDiffers else { return nil }
        let localUpdated = local.updatedAt.isEmpty ? nil : tsParseISODate(local.updatedAt)
        let localIsNewer: Bool
        switch (localUpdated, submittedAt) {
        case let (localDate?, submittedDate?): localIsNewer = localDate > submittedDate
        case (nil, nil): localIsNewer = true
        case (_?, nil): localIsNewer = true
        case (nil, _?): localIsNewer = false
        }
        guard localIsNewer else { return nil }
        return ProofFeedbackConflict(
            photoId: item.photoId,
            localRating: local.rating,
            localLabel: localLabel,
            clientRating: item.rating,
            clientLabel: item.label)
    }
}
