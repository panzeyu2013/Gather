// desktop/native/gather-app/Sources/GatherApp/Persons/PersonsViewModel.swift
// Phase 3.5：人脸库原生页面的数据层。

import Foundation
import GatherCore

public protocol PersonsDataProvider {
    func list() throws -> [PersonData]
    func get(_ personId: String) throws -> PersonDetailData
    func create(name: String) throws -> String
    func update(personId: String, name: String, notes: String) throws
    func delete(personId: String) throws
}

public final class LivePersonsDataProvider: PersonsDataProvider {
    private let router: SessionCommandRouter

    public init(router: SessionCommandRouter) {
        self.router = router
    }

    public func list() throws -> [PersonData] {
        try router.execute("person.list", params: [:]).decoded(as: [PersonData].self)
    }

    public func get(_ personId: String) throws -> PersonDetailData {
        try router.execute("person.get", params: ["personId": .string(personId)]).decoded(as: PersonDetailData.self)
    }

    public func create(name: String) throws -> String {
        let response = try router.execute("person.create", params: ["name": .string(name)])
        guard let id = response.objectValue?["id"]?.stringValue else {
            throw RouterCommandError(message: "PERSON_CREATE_EMPTY_RESPONSE")
        }
        return id
    }

    public func update(personId: String, name: String, notes: String) throws {
        _ = try router.execute("person.update", params: [
            "personId": .string(personId),
            "name": .string(name),
            "notes": .string(notes),
        ])
    }

    public func delete(personId: String) throws {
        _ = try router.execute("person.delete", params: [
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

    public func load() async {
        phase = .loading
        do {
            persons = try provider.list()
            phase = .loaded
            if let selectedId = selected?.id, persons.contains(where: { $0.id == selectedId }) {
                try? select(selectedId)
            } else if selected == nil, let first = persons.first {
                try? select(first.id)
            }
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    public func select(_ personId: String) throws {
        selected = try provider.get(personId)
        actionError = nil
    }

    @discardableResult
    public func create(name: String) async -> Bool {
        do {
            let id = try provider.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            try await reloadAndSelect(id)
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    public func saveSelected(name: String, notes: String) async {
        guard let personId = selected?.id else { return }
        do {
            try provider.update(personId: personId, name: name, notes: notes)
            try await reloadAndSelect(personId)
        } catch {
            actionError = Self.message(error)
        }
    }

    public func deleteSelected() async {
        guard let personId = selected?.id else { return }
        do {
            try provider.delete(personId: personId)
            selected = nil
            try await reloadAndSelect(nil)
        } catch {
            actionError = Self.message(error)
        }
    }

    private func reloadAndSelect(_ personId: String?) async throws {
        persons = try provider.list()
        if let personId, persons.contains(where: { $0.id == personId }) {
            selected = try provider.get(personId)
        } else {
            selected = persons.first.flatMap { try? provider.get($0.id) }
        }
        phase = .loaded
        actionError = nil
    }

    private static func message(_ error: Error) -> String {
        if let routerError = error as? RouterCommandError { return routerError.message }
        return (error as NSError).localizedDescription
    }
}
