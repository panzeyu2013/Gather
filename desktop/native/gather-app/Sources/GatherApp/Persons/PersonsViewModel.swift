// desktop/native/gather-app/Sources/GatherApp/Persons/PersonsViewModel.swift
// Phase 3.5：人脸库原生页面的数据层。

import Foundation
import GatherCore

public protocol PersonsDataProvider {
    func list() async throws -> [PersonData]
    func get(_ personId: String) async throws -> PersonDetailData
    func create(name: String) async throws -> String
    func update(personId: String, name: String, notes: String) async throws
    func delete(personId: String) async throws
}

public final class LivePersonsDataProvider: PersonsDataProvider {
    private let router: SessionCommandRouter
    private let client: NativeCommandClient

    public init(router: SessionCommandRouter) {
        self.router = router
        self.client = NativeCommandClient(router: router)
    }

    public func list() async throws -> [PersonData] {
        try await client.executeAsync("person.list", params: [:]).decoded(as: [PersonData].self)
    }

    public func get(_ personId: String) async throws -> PersonDetailData {
        try await client.executeAsync("person.get", params: ["personId": .string(personId)])
            .decoded(as: PersonDetailData.self)
    }

    public func create(name: String) async throws -> String {
        let response = try await client.executeAsync("person.create", params: ["name": .string(name)])
        guard let id = response.objectValue?["id"]?.stringValue else {
            throw RouterCommandError(message: "PERSON_CREATE_EMPTY_RESPONSE")
        }
        return id
    }

    public func update(personId: String, name: String, notes: String) async throws {
        _ = try await client.executeAsync("person.update", params: [
            "personId": .string(personId),
            "name": .string(name),
            "notes": .string(notes),
        ])
    }

    public func delete(personId: String) async throws {
        _ = try await client.executeAsync("person.delete", params: [
            "personId": .string(personId),
            "confirmed": .bool(true),
        ])
    }
}

@MainActor
@Observable
public final class PersonsViewModel {
    public enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private let provider: PersonsDataProvider
    private(set) public var phase: LoadPhase = .loading
    private(set) public var persons: [PersonData] = []
    private(set) public var selected: PersonDetailData?
    public var searchText = ""
    private(set) public var actionError: String?

    public init(provider: PersonsDataProvider) {
        self.provider = provider
    }

    public var filteredPersons: [PersonData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return persons }
        return persons.filter { $0.name.lowercased().contains(query) }
    }

    /// 打开新建 sheet 或新动作前清空上次的错误横幅。
    public func clearActionError() {
        actionError = nil
    }

    public func load() async {
        phase = .loading
        do {
            persons = try await provider.list()
            phase = .loaded
            if let selectedId = selected?.id, persons.contains(where: { $0.id == selectedId }) {
                await select(selectedId)
            } else if selected == nil, let first = persons.first {
                await select(first.id)
            }
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    public func select(_ personId: String) async {
        do {
            selected = try await provider.get(personId)
            actionError = nil
        } catch {
            actionError = Self.message(error)
        }
    }

    @discardableResult
    public func create(name: String) async -> Bool {
        do {
            let id = try await provider.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            try await reloadAndSelect(id)
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    /// 清空当前选中回到列表占位（对齐旧版 PersonDetail 顶部「← 返回」）。
    public func deselect() {
        selected = nil
        actionError = nil
    }

    @discardableResult
    public func saveSelected(name: String, notes: String) async -> Bool {
        guard let personId = selected?.id else { return false }
        do {
            try await provider.update(personId: personId, name: name, notes: notes)
            try await reloadAndSelect(personId)
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    @discardableResult
    public func deleteSelected() async -> Bool {
        guard let personId = selected?.id else { return false }
        do {
            try await provider.delete(personId: personId)
            selected = nil
            try await reloadAndSelect(nil)
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    private func reloadAndSelect(_ personId: String?) async throws {
        persons = try await provider.list()
        if let personId, persons.contains(where: { $0.id == personId }) {
            selected = try await provider.get(personId)
            actionError = nil
        } else if let first = persons.first {
            // 主列表成功但详情加载失败时写入 actionError，不静默置 nil。
            do {
                selected = try await provider.get(first.id)
                actionError = nil
            } catch {
                selected = nil
                actionError = Self.message(error)
            }
        } else {
            selected = nil
            actionError = nil
        }
        phase = .loaded
    }

    /// 对齐 TS translateError（utils/errors.ts）：错误码翻译为中文文案，
    /// 未知错误码回退通用文案，其余原样展示。
    private static func message(_ error: Error) -> String {
        GatherLocalization.message(for: error)
    }
}
