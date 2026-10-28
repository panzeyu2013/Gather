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

    private func loadLocked() -> [MetadataTemplate] {
        let raw = settings.get(Self.settingsKey, defaultValue: "")
        guard !raw.isEmpty,
              let value = try? JSONValue.parse(raw),
              let templates = try? value.decode([MetadataTemplate].self) else {
            return []
        }
        return templates
    }

    private func persistLocked(_ templates: [MetadataTemplate]) throws {
        let json = try JSONValue.stringify(JSONValue(encoding: templates))
        try settings.set(Self.settingsKey, value: json)
    }
}
