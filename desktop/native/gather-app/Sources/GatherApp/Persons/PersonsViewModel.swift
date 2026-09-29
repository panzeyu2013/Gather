// desktop/native/gather-app/Sources/GatherApp/Persons/PersonsViewModel.swift
// Phase 3.5：人脸库原生页面的数据层。

import Foundation
import GatherCore

public protocol PersonsDataProvider {
    func list() throws -> [PersonData]
    func get(_ personId: String) throws -> PersonDetailData
    func create(name: String) throws -> String
    func update(personId: String, name: String, notes: String) throws
    /// 破坏性：`confirmed` 由用户确认弹窗决定（person.delete 命令层校验）。
    func delete(personId: String, confirmed: Bool) throws
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

    public func delete(personId: String, confirmed: Bool) throws {
        _ = try router.execute("person.delete", params: [
            "personId": .string(personId),
            "confirmed": .bool(confirmed),
        ])
    }
}

@MainActor
@Observable
public final class PersonsViewModel {
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
            persons = try provider.list()
            phase = .loaded
            if let selectedId = selected?.id, persons.contains(where: { $0.id == selectedId }) {
                select(selectedId)
            } else if selected == nil, let first = persons.first {
                select(first.id)
            }
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    public func select(_ personId: String) {
        do {
            selected = try provider.get(personId)
            actionError = nil
        } catch {
            actionError = Self.message(error)
        }
    }

    @discardableResult
    public func create(name: String) async -> Bool {
        do {
            let id = try provider.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            try await reloadAndSelect(id)
            publishChange()
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
            try provider.update(personId: personId, name: name, notes: notes)
            try await reloadAndSelect(personId)
            publishChange()
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    /// 删除人物（破坏性命令 person.delete）：`confirmed` 只能由确认弹窗传入
    /// true（旧实现恒 true 已删除）；未确认时不发命令。
    @discardableResult
    public func deleteSelected(confirmed: Bool) async -> Bool {
        guard confirmed else {
            actionError = GatherLocalization.l("未确认，已取消删除人物")
            return false
        }
        guard let personId = selected?.id else { return false }
        do {
            try provider.delete(personId: personId, confirmed: confirmed)
            selected = nil
            try await reloadAndSelect(nil)
            publishChange()
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    /// 写路径广播的发布者标识：本页监听器据此跳过自触发重查。
    public static let changeOrigin = "persons"

    /// 写路径统一广播：常驻页（人脸库/人脸绑定侧）监听 .persons 后按域刷新。
    private func publishChange() {
        GatherEventCenter.postDomainChange(.persons, origin: Self.changeOrigin)
    }

    private func reloadAndSelect(_ personId: String?) async throws {
        persons = try provider.list()
        if let personId, persons.contains(where: { $0.id == personId }) {
            selected = try provider.get(personId)
            actionError = nil
        } else if let first = persons.first {
            // 主列表成功但详情加载失败时写入 actionError，不静默置 nil。
            do {
                selected = try provider.get(first.id)
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

    /// 统一错误漏斗：带错误码者经 errorText 翻译；原始诊断只进日志、不上屏
    /// （非错误码按当前界面语言回退通用文案）。旧实现走 NSError 桥接，会丢
    /// NativeCommandError/BridgeError 的码值（如 person.get 的 PERSON_NOT_FOUND）。
    private static func message(_ error: Error) -> String {
        GatherLogger.log("persons error diagnostic: \(error)", level: .warn)
        return NativeCommandClient.userFacingMessage(for: error)
    }
}
