// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataApplyBatchStore.swift
// P1 / B3：模板套用批次（undo 的唯一输入）。
//
// 每条批次记录"哪些照片、套了哪个模板、每张改动前的值"，撤销时按 before 反向写。
// 只保留最近 N 条（undo 是交互功能，不是审计日志）；超限按时间淘汰最旧。
import Foundation
import GatherProtocol
import GatherPersistence

/// 单张照片在批次里的"改动前"快照（只记被模板触碰的字段）。
public struct MetadataApplySnapshot: Codable, Equatable, Sendable {
    public var photoId: String
    public var filepath: String
    /// 只包含本次会写/清的字段及其原值（nil = 原本就没有该字段）。
    public var before: DescriptiveMetadata
    /// 本次触碰的字段（含原本不存在、撤销时必须清空的字段）。
    /// 可选：兼容加入该维度之前写入的历史批次。
    public var touchedFields: [DescriptiveField]?
    /// P1 / E：triage 写回改动前的星级（nil = 该批次没动 rating）。
    public var beforeRating: Int?
    /// P1 / E：triage 写回改动前的关键词表（nil = 该批次没动关键词）。
    public var beforeKeywords: [String]?
    /// P1：本次实际追加的关键词；撤销只删这一个，保留之后新增的词。
    public var appliedKeyword: String?


    public init(
        photoId: String,
        filepath: String,
        before: DescriptiveMetadata,
        touchedFields: [DescriptiveField]? = nil,
        beforeRating: Int? = nil,
        beforeKeywords: [String]? = nil,
        appliedKeyword: String? = nil
    ) {
        self.photoId = photoId
        self.filepath = filepath
        self.before = before
        self.touchedFields = touchedFields
        self.beforeRating = beforeRating
        self.beforeKeywords = beforeKeywords
        self.appliedKeyword = appliedKeyword
    }
}

public struct MetadataApplyBatch: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var templateId: String
    public var templateName: String
    public var appliedAt: String
    public var snapshots: [MetadataApplySnapshot]
    /// 已在撤销后置 true（批次不复用，避免重复回滚）。
    public var undone: Bool

    public init(id: String, templateId: String, templateName: String, appliedAt: String,
                snapshots: [MetadataApplySnapshot], undone: Bool = false) {
        self.id = id
        self.templateId = templateId
        self.templateName = templateName
        self.appliedAt = appliedAt
        self.snapshots = snapshots
        self.undone = undone
    }
}

public final class MetadataApplyBatchStore: @unchecked Sendable {
    public static let settingsKey = "metadata.applyBatches"
    /// 解析失败时的原文留证键（只保留最近一份，见 preserveCorruptPayloadLocked）。
    public static let corruptKey = "metadata.applyBatches.corrupt"
    /// 保留最近批次数：足够"手滑撤销"，又不让 settings 无限膨胀。
    public static let retention = 20
    private let settings: SettingsService
    private let lock = NSLock()

    public init(settings: SettingsService) {
        self.settings = settings
    }

    /// 新的在前（面板只显示最近几条）。
    public func list() -> [MetadataApplyBatch] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func latest() -> MetadataApplyBatch? {
        list().first { !$0.undone }
    }

    public func get(id: String) -> MetadataApplyBatch? {
        list().first { $0.id == id }
    }

    @discardableResult
    public func record(_ batch: MetadataApplyBatch) throws -> MetadataApplyBatch {
        lock.lock()
        defer { lock.unlock() }
        var batches = loadLocked()
        batches.removeAll { $0.id == batch.id }
        batches.insert(batch, at: 0)
        if batches.count > Self.retention {
            batches = Array(batches.prefix(Self.retention))
        }
        try persistLocked(batches)
        return batch
    }

    public func markUndone(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var batches = loadLocked()
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        batches[index].undone = true
        try persistLocked(batches)
    }

    private func loadLocked() -> [MetadataApplyBatch] {
        let raw = settings.get(Self.settingsKey, defaultValue: "") ?? ""
        guard !raw.isEmpty else { return [] }
        do {
            let value = try JSONValue.parse(raw)
            return try value.decode([MetadataApplyBatch].self)
        } catch {
            // 历史损坏不能静默消失：把原文转存到 corrupt 键留证，再按"无历史"继续。
            // 否则下一次 record 会用新批次整体覆盖，损坏原因再也查不到。
            preserveCorruptPayloadLocked(raw)
            return []
        }
    }

    /// 解析失败的原文只保留最近一份（避免单键无限增长）。
    private func preserveCorruptPayloadLocked(_ raw: String) {
        guard (settings.get(Self.corruptKey, defaultValue: "") ?? "") != raw else { return }
        _ = try? settings.set(Self.corruptKey, value: raw)
    }

    private func persistLocked(_ batches: [MetadataApplyBatch]) throws {
        let json = try JSONValue.stringify(JSONValue(encoding: batches))
        try settings.set(Self.settingsKey, value: json)
    }
}
