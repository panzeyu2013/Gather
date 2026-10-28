// desktop/native/gather-core/Sources/GatherApplication/Services/Triage/TriageWritebackService.swift
// P1 / E：把 triage 写回计划落成**可移植信号**（逐张独立提交，经交付队列）。
//
// 写入三件套：
// - rating（只写空值，人工决策不动）；
// - 可选关键词（Gather|AI|Keep / Reject，会进客户交付物）；
// - 私有命名空间 gather:Triage = keep/reject（其它工具可读、可审计、可撤销）。
//
// 撤销：按批次记录还原 rating/关键词，并清空私有命名空间（不误删其它字段）。
import Foundation
import GatherProtocol
import GatherPersistence

public struct TriageWritebackFailure: Equatable, Sendable {
    public var photoId: String
    public var message: String
    public init(photoId: String, message: String) {
        self.photoId = photoId
        self.message = message
    }
}

public struct TriageWritebackOutcome: Equatable, Sendable {
    public var written: [String]
    public var skipped: [String]
    public var failed: [TriageWritebackFailure]
    public init(written: [String], skipped: [String], failed: [TriageWritebackFailure]) {
        self.written = written
        self.skipped = skipped
        self.failed = failed
    }
}

public final class TriageWritebackService: Sendable {
    /// 批次存储里 triage 批次的模板标识（避免多处魔法串漂移）。
    public static let batchTemplateID = "triage"
    private let xmp: any XMPProvider
    private let metadata: MetadataService
    /// nil = 不记批次（此时不提供撤销）。
    private let batches: MetadataApplyBatchStore?

    public init(xmp: any XMPProvider, metadata: MetadataService, batches: MetadataApplyBatchStore? = nil) {
        self.xmp = xmp
        self.metadata = metadata
        self.batches = batches
    }

    /// 逐张独立提交：一张失败不影响其它张；无写入动作的决策记为 skipped。
    public func apply(
        _ decisions: [TriageWritebackDecision],
        batchId: String = UUID().uuidString,
        now: String = ""
    ) async -> TriageWritebackOutcome {
        var skipped: [String] = []
        var inputs: [(photoId: String, attributes: MetadataWriteAttributes)] = []
        var snapshots: [String: MetadataApplySnapshot] = [:]
        var failed: [TriageWritebackFailure] = []

        enum DecisionOutcome: Sendable {
            case input(String, MetadataWriteAttributes, MetadataApplySnapshot)
            case failure(TriageWritebackFailure)
        }
        // 读盘是主成本：有界并发；写盘仍逐张走交付队列。
        var outcomes: [DecisionOutcome] = []
        do {
            outcomes = try await batchAsync(decisions, concurrency: 8) { decision -> DecisionOutcome in
            do {
                let detail = try self.metadata.photoDetail(photoId: decision.photoId)
                let current = (try? await self.xmp.readAttributes(photoPath: detail.filepath))
                    ?? MetadataWriteAttributes()
                var attributes = MetadataWriteAttributes()
                if let rating = decision.rating { attributes.rating = Double(rating) }
                if let keyword = decision.keyword {
                    var keywords = current.keywords ?? []
                    // 按 fold 去重（与 undo 的"写回前已存在"判定同一口径）：盘上已有
                    // 大小写/空白变体时不再追加规范词，否则 undo 会因"已存在"跳过删除、
                    // 把这个变体残留下来。
                    let folded = KeywordNormalizer.fold(keyword)
                    if !keywords.contains(where: { KeywordNormalizer.fold($0) == folded }) {
                        keywords.append(keyword)
                    }
                    attributes.keywords = keywords
                    // 并集语义：不得覆盖 culling 尚未落盘的 delta 意图。
                    attributes.keywordsMode = "merge"
                }
                // 信号始终写：即使 rating 因人工决策被跳过，也要记录"这条建议存在"。
                attributes.triageSignal = decision.namespaceValue
                let snapshot = MetadataApplySnapshot(
                    photoId: decision.photoId,
                    filepath: detail.filepath,
                    before: DescriptiveMetadata(),
                    // 撤销基线取盘上现值（缓存可能落后）。
                    beforeRating: decision.rating == nil
                        ? nil : Int(current.rating ?? Double(detail.exif.rating)),
                    beforeKeywords: decision.keyword == nil ? nil : (current.keywords ?? []),
                    appliedKeyword: decision.keyword
                )
                return .input(decision.photoId, attributes, snapshot)
            } catch {
                return .failure(TriageWritebackFailure(
                    photoId: decision.photoId, message: String(describing: error)))
                }
            }
        } catch {
            failed.append(contentsOf: decisions.map {
                TriageWritebackFailure(photoId: $0.photoId, message: String(describing: error))
            })
        }
        for outcome in outcomes {
            switch outcome {
            case .input(let photoId, let attributes, let snapshot):
                inputs.append((photoId, attributes))
                snapshots[photoId] = snapshot
            case .failure(let failure):
                failed.append(failure)
            }
        }

        // 先落批次快照再写盘：写盘成功而记录失败会让"可撤销"永久落空（旧实现用
        // try? 吞掉，结果照样报 written）。反过来的最坏情况只是留下一个"撤销时
        // 没有实际改动"的空批次——撤销本身是幂等无操作，代价远小于不可撤销。
        if let batches, !inputs.isEmpty {
            do {
                try batches.record(MetadataApplyBatch(
                    id: batchId, templateId: Self.batchTemplateID,
                    templateName: Self.batchTemplateID,
                    appliedAt: now,
                    snapshots: inputs.compactMap { snapshots[$0.photoId] }))
            } catch {
                // 保留前面累积的读取/读盘失败：它们既不在 written 也不该被这次早退吞掉。
                return TriageWritebackOutcome(
                    written: [],
                    skipped: skipped,
                    failed: failed + inputs.map {
                        TriageWritebackFailure(
                            photoId: $0.photoId,
                            message: "批次记录失败，未写盘：\(error)")
                    })
            }
        }
        var written: [String] = []
        if !inputs.isEmpty {
            do {
                let outcome = try await metadata.applyMetadataAttributes(inputs, source: .manual)
                written = outcome.written
                skipped.append(contentsOf: outcome.skipped)
                failed.append(contentsOf: outcome.failed.map {
                    TriageWritebackFailure(photoId: $0.photoId, message: $0.message)
                })
            } catch {
                failed.append(contentsOf: inputs.map {
                    TriageWritebackFailure(photoId: $0.photoId, message: String(describing: error))
                })
            }
        }
        if written.isEmpty, !failed.isEmpty, let batches {
            // 整批一张都没写成：批次快照没有对应落盘，留着只会给 UI 一个"可撤销的
            // 假入口"（撤销会写回/清信号，反而制造改动）。标记已撤销。
            do {
                try batches.markUndone(id: batchId)
            } catch {
                GatherLogger.log(
                    "triage batch markUndone after empty write failed (batch=\(batchId)): \(error)",
                    level: .warn)
            }
        }
        return TriageWritebackOutcome(written: written, skipped: skipped, failed: failed)
    }

    /// 撤销：rating/关键词还原为改动前；私有命名空间清空。
    public func undo(batchId: String) async throws -> TriageWritebackOutcome {
        guard let batches, let batch = batches.get(id: batchId) else {
            throw MetadataTemplateServiceError.batchNotFound(batchId)
        }
        guard !batch.undone else {
            throw MetadataTemplateServiceError.batchAlreadyUndone(batchId)
        }
        guard batch.templateId == Self.batchTemplateID else {
            throw MetadataTemplateServiceError.batchTypeMismatch(batchId)
        }
        var inputs: [(photoId: String, attributes: MetadataWriteAttributes)] = []
        var failed: [TriageWritebackFailure] = []
        var blocked = Set<String>()
        // 新批次只删"本次追加的那个关键词"：写回后用户/C1 新增的词必须保留；
        // 写回前就存在的同名关键词（上一批写回或手工添加）也不是本批的 delta，
        // 一律不删——否则撤销会把别人的词一起带走。
        for snapshot in batch.snapshots {
            guard let keyword = snapshot.appliedKeyword else { continue }
            let existedBefore = (snapshot.beforeKeywords ?? []).contains {
                KeywordNormalizer.fold($0) == KeywordNormalizer.fold(keyword)
            }
            guard !existedBefore else { continue }
            do {
                let removal = try await metadata.applyKeywordDelta(
                    photoIds: [snapshot.photoId], added: [], removed: [keyword])
                if removal.failed > 0 {
                    blocked.insert(snapshot.photoId)
                    failed.append(TriageWritebackFailure(
                        photoId: snapshot.photoId,
                        message: removal.errors.first ?? "keyword undo failed"))
                }
            } catch {
                blocked.insert(snapshot.photoId)
                failed.append(TriageWritebackFailure(
                    photoId: snapshot.photoId, message: String(describing: error)))
            }
        }
        for snapshot in batch.snapshots where !blocked.contains(snapshot.photoId) {
            var attributes = MetadataWriteAttributes()
            if let beforeRating = snapshot.beforeRating { attributes.rating = Double(beforeRating) }
            // 旧批次没有 appliedKeyword：退回 beforeKeywords 整表恢复（历史行为）。
            if snapshot.appliedKeyword == nil, let beforeKeywords = snapshot.beforeKeywords {
                attributes.keywords = beforeKeywords
            }
            attributes.triageSignal = ""
            inputs.append((snapshot.photoId, attributes))
        }
        var written: [String] = []
        if !inputs.isEmpty {
            do {
                let outcome = try await metadata.applyMetadataAttributes(inputs, source: .manual)
                written = outcome.written
                // 追加而不是覆盖：上一阶段"删关键词"的失败必须留在结果里，否则
                // 下面的 failed.isEmpty 会把这次撤销当成成功并对批次 markUndone
                // ——盘上关键词残留、批次又不可重试（undo 有 batchAlreadyUndone 守卫）。
                failed.append(contentsOf: outcome.failed.map {
                    TriageWritebackFailure(photoId: $0.photoId, message: $0.message)
                })
            } catch {
                failed.append(contentsOf: inputs.map {
                    TriageWritebackFailure(photoId: $0.photoId, message: String(describing: error))
                })
            }
        }
        if failed.isEmpty { try batches.markUndone(id: batchId) }
        return TriageWritebackOutcome(written: written, skipped: [], failed: failed)
    }
}
