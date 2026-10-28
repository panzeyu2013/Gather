// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataTemplateStore.swift
// P1 / B2：元数据模板的持久化（settings 单键 JSON，避免为几张模板再改 schema）。
//
// 为什么放 settings：模板数量是个位数到几十，从不参与筛选/联表；用 settings 的
// 单键 JSON 可以让"模板"与"偏好"走同一条备份/恢复链（含 maintenance 导出）。
// 代价是不能按字段查询——用不到。
import Foundation
import GatherProtocol
import GatherPersistence

/// 一个命名模板：只保存"被显式设置的字段"（nil 字段不落盘）。
public struct MetadataTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var fields: DescriptiveMetadata
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, name: String, fields: DescriptiveMetadata, createdAt: String, updatedAt: String) {
        self.id = id
        self.name = name
        self.fields = fields
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MetadataTemplateStoreError: Error, Equatable, CustomStringConvertible {
    case nameRequired
    case notFound(String)
    case duplicateName(String)

    public var description: String {
        switch self {
        case .nameRequired: "模板名不能为空"
        case .notFound(let id): "模板不存在：\(id)"
        case .duplicateName(let name): "模板名已存在：\(name)"
        }
    }
}

public final class MetadataTemplateStore: @unchecked Sendable {
    /// settings 键：唯一真相源。
    public static let settingsKey = "metadata.templates"
    /// 解析失败时的原文留证键（只保留最近一份，与 MetadataApplyBatchStore 同模式）。
    public static let corruptKey = "metadata.templates.corrupt"
    private let settings: SettingsService
    private let lock = NSLock()

    public init(settings: SettingsService) {
        self.settings = settings
    }

    public func list() -> [MetadataTemplate] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func get(id: String) -> MetadataTemplate? {
        list().first { $0.id == id }
    }

    /// 新建或更新（按 id）。同名不同 id 拒绝，避免"两个婚礼"这种无法区分的列表。
    @discardableResult
    public func save(_ template: MetadataTemplate, now: String) throws -> MetadataTemplate {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MetadataTemplateStoreError.nameRequired }
        lock.lock()
        defer { lock.unlock() }
        var templates = loadLocked()
        if templates.contains(where: { $0.id != template.id && $0.name == name }) {
            throw MetadataTemplateStoreError.duplicateName(name)
        }
        var stored = template
        stored.name = name
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            stored.createdAt = templates[index].createdAt
            stored.updatedAt = now
            templates[index] = stored
        } else {
            stored.createdAt = now
            stored.updatedAt = now
            templates.append(stored)
        }
        try persistLocked(templates)
        return stored
    }

    public func delete(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var templates = loadLocked()
        guard let index = templates.firstIndex(where: { $0.id == id }) else {
            throw MetadataTemplateStoreError.notFound(id)
        }
        templates.remove(at: index)
        try persistLocked(templates)
    }

    /// 读取模板表。
    ///
    /// P2：损坏不能静默——旧实现整体 try? 返回空表，UI 上表现为"模板全部消失"，
    /// 且下一次 save 会用新表覆盖原文，再也查不到原因。这里与批次存储同模式：
    /// 逐元素解码（坏一条只丢一条），并把原文转存到 corrupt 键留证。
    private func loadLocked() -> [MetadataTemplate] {
        let raw = settings.get(Self.settingsKey, defaultValue: "")
        guard !raw.isEmpty else { return [] }
        do {
            let value = try JSONValue.parse(raw)
            guard let elements = value.arrayElements else {
                preserveCorruptPayloadLocked(raw, reason: "not an array")
                return []
            }
            var templates: [MetadataTemplate] = []
            var dropped = 0
            for element in elements {
                do {
                    templates.append(try element.decode(MetadataTemplate.self))
                } catch {
                    dropped += 1
                }
            }
            if dropped > 0 {
                preserveCorruptPayloadLocked(
                    raw, reason: "dropped \(dropped) of \(elements.count)")
                GatherLogger.log(
                    "metadata.templates: 丢弃 \(dropped)/\(elements.count) 条损坏模板",
                    level: .warn)
            }
            return templates
        } catch {
            preserveCorruptPayloadLocked(raw, reason: "unparseable JSON")
            return []
        }
    }

    private func preserveCorruptPayloadLocked(_ raw: String, reason: String) {
        guard settings.get(Self.corruptKey, defaultValue: "") != raw else { return }
        do {
            try settings.set(Self.corruptKey, value: raw)
            GatherLogger.log("metadata.templates: 损坏数据已留证（\(reason)）", level: .warn)
        } catch {
            // 留证失败也不能阻断读取：坏数据本身已经被丢弃并记 warn。
            GatherLogger.log(
                "metadata.templates: 损坏数据留证失败（\(reason)）：\(error)", level: .warn)
        }
    }

    private func persistLocked(_ templates: [MetadataTemplate]) throws {
        let json = try JSONValue.stringify(JSONValue(encoding: templates))
        try settings.set(Self.settingsKey, value: json)
    }
}
