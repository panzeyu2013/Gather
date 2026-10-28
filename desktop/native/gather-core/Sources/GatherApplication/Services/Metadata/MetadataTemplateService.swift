// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataTemplateService.swift
// P1 / B2：模板套用执行 + 撤销（preview 由 Round 3/5 的两层提供，本文件是 confirm 与 undo）。
//
// 写路径：所有侧车写入都经 MetadataService.applyMetadataAttributes → 交付队列
// （备份 / 冲突检测 / reload-ack / 审计），本文件不直接调用 XMPProvider.writeAttributes。
// 事务边界：逐张独立入队；一张失败不影响其它张。批次记录只在**有实际写入**时落库，
// 记录的是"改动前的值 + 本次触碰的字段"，撤销按 before 反向写（原本不存在的字段清空）。
import Foundation
import GatherProtocol
import GatherPersistence

public enum MetadataTemplateServiceError: Error, Equatable, CustomStringConvertible {
    case templateNotFound(String)
    case batchNotFound(String)
    case batchAlreadyUndone(String)
    case batchTypeMismatch(String)

    public var description: String {
        switch self {
        case .templateNotFound(let id): "模板不存在：\(id)"
        case .batchNotFound(let id): "批次不存在：\(id)"
        case .batchAlreadyUndone(let id): "批次已撤销：\(id)"
        case .batchTypeMismatch(let id): "批次类型不匹配：\(id)"
        }
    }
}

public struct MetadataApplyFailure: Equatable, Sendable {
    public var photoId: String
    public var message: String
    public init(photoId: String, message: String) {
        self.photoId = photoId
        self.message = message
    }
}

public struct MetadataApplyResult: Equatable, Sendable {
    public var batchId: String
    public var written: [String]
    public var skipped: [String]
    public var conflicts: [String]
    public var failed: [MetadataApplyFailure]
    public init(batchId: String, written: [String], skipped: [String], conflicts: [String], failed: [MetadataApplyFailure]) {
        self.batchId = batchId
        self.written = written
        self.skipped = skipped
        self.conflicts = conflicts
        self.failed = failed
    }
}

public extension MetadataPhotoImpact {
    /// 本次会被写/清的字段（撤销时必须逐个还原，含原本不存在的字段）。
    var touchedFields: [DescriptiveField] {
        fields.filter { $0.action == .write || $0.action == .clear }.map(\.field)
    }

    /// 把计划翻译成"要写盘的 attributes"：只包含 write/clear 的字段；
    /// 没有任何动作时返回 nil（不产生空写）。
    func writeAttributes(template: DescriptiveMetadata) -> MetadataWriteAttributes? {
        var toWrite = DescriptiveMetadata()
        for impact in fields where impact.action == .write || impact.action == .clear {
            switch impact.action {
            case .write:
                if let value = template.value(for: impact.field) { toWrite.set(value, for: impact.field) }
            case .clear:
                toWrite.clear(impact.field)
            default:
                break
            }
        }
        guard !toWrite.isEmpty else { return nil }
        return MetadataWriteAttributes(descriptive: toWrite)
    }

    /// 改动前的值（撤销输入）：只包含即将被改动的字段。
    var beforeSnapshot: DescriptiveMetadata {
        var before = DescriptiveMetadata()
        for impact in fields where impact.action == .write || impact.action == .clear {
            // 撤销基线取盘上值：overwrite 策略下外部改动不能被"撤销"成缓存旧值。
            if let value = impact.disk ?? impact.current { before.set(value, for: impact.field) }
        }
        return before
    }
}

public final class MetadataTemplateService: Sendable {
    private let templates: MetadataTemplateStore
    private let batches: MetadataApplyBatchStore
    private let metadata: MetadataService
    private let xmp: any XMPProvider

    public init(
        templates: MetadataTemplateStore,
        batches: MetadataApplyBatchStore,
        metadata: MetadataService,
        xmp: any XMPProvider
    ) {
        self.templates = templates
        self.batches = batches
        self.metadata = metadata
        self.xmp = xmp
    }

    /// 应用模板：逐张独立提交；冲突按策略跳过；返回批次 id 供撤销。
    public func apply(
        templateId: String,
        photoIds: [String],
        policy: MetadataConflictPolicy = .keepExternal,
        now: String,
        batchId: String = UUID().uuidString
    ) async throws -> MetadataApplyResult {
        guard let template = templates.get(id: templateId) else {
            throw MetadataTemplateServiceError.templateNotFound(templateId)
        }
        var seen = Set<String>()
        let uniqueIds = photoIds.filter { seen.insert($0).inserted }
        var skipped: [String] = []
        var conflicts: [String] = []
        var failed: [MetadataApplyFailure] = []
        var inputs: [(photoId: String, attributes: MetadataWriteAttributes)] = []
        var snapshots: [String: MetadataApplySnapshot] = [:]

        enum PlanOutcome: Sendable {
            case input(String, MetadataWriteAttributes, MetadataApplySnapshot, Bool)
            case skipped(String)
            case failure(MetadataApplyFailure)
        }
        // 逐张读盘是 IO 主成本：有界并发读取，写盘仍由交付队列串行保证。
        let outcomes = try await batchAsync(uniqueIds, concurrency: 8) { photoId -> PlanOutcome in
            do {
                let detail = try self.metadata.photoDetail(photoId: photoId)
                let disk = (try? await self.xmp.readAttributes(
                    photoPath: detail.filepath))?.descriptive
                let plan = MetadataTemplatePlanner.plan(
                    template: template.fields,
                    photoId: photoId,
                    current: detail.descriptive,
                    disk: disk,
                    policy: policy
                )
                guard let attributes = plan.writeAttributes(template: template.fields) else {
                    return .skipped(photoId)
                }
                let snapshot = MetadataApplySnapshot(
                    photoId: photoId,
                    filepath: detail.filepath,
                    before: plan.beforeSnapshot,
                    touchedFields: plan.touchedFields
                )
                return .input(photoId, attributes, snapshot, plan.conflictCount > 0)
            } catch {
                return .failure(MetadataApplyFailure(
                    photoId: photoId, message: String(describing: error)))
            }
        }
        for outcome in outcomes {
            switch outcome {
            case .input(let photoId, let attributes, let snapshot, let hasConflict):
                if hasConflict { conflicts.append(photoId) }
                inputs.append((photoId, attributes))
                snapshots[photoId] = snapshot
            case .skipped(let photoId):
                skipped.append(photoId)
            case .failure(let failure):
                failed.append(failure)
            }
        }

        if !inputs.isEmpty {
            // 与 triage 同口径：先记快照再写盘。record 失败就不写盘，否则"文件已改、
            // 没有任何批次可撤销"且调用方只看到一条失败。
            do {
                try batches.record(MetadataApplyBatch(
                    id: batchId, templateId: template.id, templateName: template.name,
                    appliedAt: now, snapshots: inputs.compactMap { snapshots[$0.photoId] }
                ))
            } catch {
                failed.append(contentsOf: inputs.map {
                    MetadataApplyFailure(
                        photoId: $0.photoId, message: "批次记录失败，未写盘：\(error)")
                })
                return MetadataApplyResult(
                    batchId: batchId, written: [], skipped: skipped,
                    conflicts: conflicts, failed: failed
                )
            }
            let outcome = try await metadata.applyMetadataAttributes(inputs, source: .template)
            skipped.append(contentsOf: outcome.skipped)
            failed.append(contentsOf: outcome.failed)
            // 回读校验失败也可能已写盘：按 attempted 裁剪快照；一张都没 attempted 时
            // 批次没有实际效果，标记已撤销，避免 UI 给出"可撤销"的假入口。
            let attemptedSnapshots = outcome.attempted.compactMap { snapshots[$0] }
            if attemptedSnapshots.isEmpty {
                do {
                    try batches.markUndone(id: batchId)
                } catch {
                    GatherLogger.log(
                        "template batch markUndone after empty write failed (batch=\(batchId)): \(error)",
                        level: .warn)
                }
            } else if attemptedSnapshots.count < inputs.count {
                do {
                    try batches.record(MetadataApplyBatch(
                        id: batchId, templateId: template.id, templateName: template.name,
                        appliedAt: now, snapshots: attemptedSnapshots
                    ))
                } catch {
                    GatherLogger.log(
                        "template batch trim after partial write failed (batch=\(batchId)): \(error)",
                        level: .warn)
                }
            }
            return MetadataApplyResult(
                batchId: batchId, written: outcome.written, skipped: skipped,
                conflicts: conflicts, failed: failed
            )
        }
        return MetadataApplyResult(
            batchId: batchId, written: [], skipped: skipped,
            conflicts: conflicts, failed: failed
        )
    }

    /// 撤销：按 before 反向写；已撤销的批次拒绝重复回滚。
    public func undo(batchId: String) async throws -> MetadataApplyResult {
        guard let batch = batches.get(id: batchId) else {
            throw MetadataTemplateServiceError.batchNotFound(batchId)
        }
        guard !batch.undone else {
            throw MetadataTemplateServiceError.batchAlreadyUndone(batchId)
        }
        guard batch.templateId != TriageWritebackService.batchTemplateID else {
            throw MetadataTemplateServiceError.batchTypeMismatch(batchId)
        }
        var inputs: [(photoId: String, attributes: MetadataWriteAttributes)] = []
        for snapshot in batch.snapshots {
            guard let attributes = Self.restoreAttributes(snapshot) else { continue }
            inputs.append((snapshot.photoId, attributes))
        }
        var written: [String] = []
        var failed: [MetadataApplyFailure] = []
        if !inputs.isEmpty {
            let outcome = try await metadata.applyMetadataAttributes(inputs, source: .template)
            written = outcome.written
            failed = outcome.failed
        }
        // 有失败时保留 undone = false：用户可以重试，成功的照片重写同一值幂等。
        if failed.isEmpty {
            try batches.markUndone(id: batchId)
        }
        return MetadataApplyResult(
            batchId: batchId, written: written, skipped: [], conflicts: [], failed: failed
        )
    }

    /// 撤销载荷：触碰过的字段全部还原；before 里没有的字段写空（清空）。
    static func restoreAttributes(_ snapshot: MetadataApplySnapshot) -> MetadataWriteAttributes? {
        let fields = snapshot.touchedFields ?? snapshot.before.explicitlySetFields
        guard !fields.isEmpty else { return nil }
        var restore = DescriptiveMetadata()
        for field in fields {
            if let value = snapshot.before.value(for: field) {
                restore.set(value, for: field)
            } else {
                restore.clear(field)
            }
        }
        guard !restore.isEmpty else { return nil }
        return MetadataWriteAttributes(
            descriptive: restore,
            replaceContact: fields.contains(.contactInfo))
    }
}
