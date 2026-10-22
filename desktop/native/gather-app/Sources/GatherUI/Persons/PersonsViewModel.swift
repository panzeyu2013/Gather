// desktop/native/gather-app/Sources/GatherUI/Persons/PersonsViewModel.swift
// Phase 3.5：人脸库原生页面的数据层。
//
// Cut 1 / B7b：页面数据层从「同步 provider + 字符串命令」迁移到
// AppServices.person（any PersonAPI，8 个 async 方法）：
// - list/get/create/update/delete 走类型化 API；返回值/错误统一 GatherError；
// - merge/removePhoto 是破坏性入口，只接受确认弹窗传出的 confirmed，
//   在 VM 内构造 Confirmed(..., source: .userDialog)，未确认不发请求；
// - searchPhotos 保留为详情栅格的按工作区/分页查询入口（当前首屏仍用 get
//   返回的 photos，分页 UI 尚未接线，测试覆盖参数透传与错误漏斗）。
//
// 选择是异步的：PersonAPI.get 是 async，List(selection:) 的 setter 不能等待，
// 因此 select 改为 async，并用 selectionGeneration 丢弃过期结果（快速点击 /
// 删除后刷新与在途 get 竞态时，旧详情不得覆盖新状态）。
//
// Cut 1 / B8.2d：legacy PersonsDataProvider / LivePersonsDataProvider 已删除。
// GatherApp 不再构造 provider、RootView 不再接收 personsProvider 参数，人物域
// 只剩 AppServices.person（any PersonAPI）这一条生产路径。

import Foundation
import Observation
import GatherProtocol

// MARK: - ViewModel

@MainActor
@Observable
public final class PersonsViewModel {
    private let person: any PersonAPI
    private(set) public var phase: LoadPhase = .loading
    private(set) public var persons: [PersonData] = []
    private(set) public var selected: PersonDetailData?
    public var searchText = ""
    private(set) public var actionError: CommandError?

    /// 详情请求代次：只有最后一次发起的 get 可以写 selected/actionError。
    /// 不进 Observation（选择代次变化不应触发界面重算）。
    @ObservationIgnored private var selectionGeneration = 0

    public init(person: any PersonAPI) {
        self.person = person
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
            persons = try await person.list()
            phase = .loaded
            if let selectedId = selected?.id, persons.contains(where: { $0.id == selectedId }) {
                await select(selectedId)
            } else if let first = persons.first {
                // B4（9-30 审查）：这里覆盖「未选中」与「选中的人物已不存在」
                //（例如另一个窗口把它删了）两种情况。旧实现只处理 selected == nil，
                // 被删人物的详情会一直留在右栏，后续保存/删除会拿失效 ID 发命令。
                await select(first.id)
            } else {
                // 列表已空（人物被别处删光）：清空选择，不留旧详情。
                selected = nil
            }
        } catch {
            // 4a-3b-2a：首屏失败只存错误载体，文案在渲染期解析。
            phase = .failed(CommandError(error))
        }
    }

    /// 读取人物详情。异步 + 代次守卫：先发起的请求晚返回时不得覆盖新选择。
    public func select(_ personId: String) async {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        do {
            let detail = try await person.get(personId)
            guard generation == selectionGeneration else { return }
            selected = detail
            actionError = nil
        } catch {
            guard generation == selectionGeneration else { return }
            actionError = CommandError(error)
        }
    }

    @discardableResult
    public func create(name: String) async -> Bool {
        do {
            let result = try await person.create(
                PersonCreateParams(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            )
            try await reloadAndSelect(result.id)
            publishChange()
            return true
        } catch {
            actionError = CommandError(error)
            return false
        }
    }

    @discardableResult
    public func saveSelected(name: String, notes: String) async -> Bool {
        guard let personId = selected?.id else { return false }
        do {
            try await person.update(
                PersonUpdateParams(personId: personId, name: name, notes: notes)
            )
            try await reloadAndSelect(personId)
            publishChange()
            return true
        } catch {
            actionError = CommandError(error)
            return false
        }
    }

    /// 删除人物（破坏性命令 person.delete）：`confirmed` 只能由确认弹窗传入
    /// true（旧实现恒 true 已删除）；未确认时不发命令。
    @discardableResult
    public func deleteSelected(confirmed: Bool) async -> Bool {
        guard confirmed else {
            actionError = CommandError.localized("未确认，已取消删除人物")
            return false
        }
        guard let personId = selected?.id else { return false }
        do {
            let input = try PersonDeleteInput(personId: personId)
            try await person.delete(Confirmed(input, source: .userDialog))
            selected = nil
            try await reloadAndSelect(nil)
            publishChange()
            return true
        } catch {
            actionError = CommandError(error)
            return false
        }
    }

    /// 合并人物（破坏性命令 person.merge）：源人物合并进目标人物后，源人物从
    /// 人脸库消失。确认来源固定 .userDialog —— 调用方只能在确认弹窗后传 true。
    @discardableResult
    public func merge(sourceId: String, targetId: String, confirmed: Bool) async -> Bool {
        guard confirmed else {
            actionError = CommandError(code: GatherErrorCode.PERSON_MERGE_CONFIRM_REQUIRED.rawValue)
            return false
        }
        do {
            let input = try PersonMergeInput(sourceId: sourceId, targetId: targetId)
            try await person.merge(Confirmed(input, source: .userDialog))
            // 合并后源人物已不存在：选中目标人物并整页刷新（列表计数/缩略图都会变）。
            try await reloadAndSelect(targetId)
            publishChange()
            return true
        } catch {
            actionError = CommandError(error)
            return false
        }
    }

    /// 从人物移除一张关联照片（破坏性命令 person.remove_photo）：只断开人脸绑定，
    /// 不删除照片文件。确认来源固定 .userDialog。
    @discardableResult
    public func removePhoto(personId: String, photoId: String, confirmed: Bool) async -> Bool {
        guard confirmed else {
            actionError = CommandError(code: GatherErrorCode.PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED.rawValue)
            return false
        }
        do {
            let input = try PersonRemovePhotoInput(personId: personId, photoId: photoId)
            try await person.removePhoto(Confirmed(input, source: .userDialog))
            if selected?.id == personId {
                try await reloadAndSelect(personId)
            } else {
                // 移除的不是当前详情：只刷新列表计数，不改变用户选择。
                persons = try await person.list()
                phase = .loaded
            }
            publishChange()
            return true
        } catch {
            actionError = CommandError(error)
            return false
        }
    }

    /// 按人物检索照片（person.search_photos）：详情栅格的分页 / 按工作区过滤
    /// 查询入口。失败写入 actionError（与其余写路径同一漏斗）并返回 nil。
    @discardableResult
    public func searchPhotos(
        personId: String,
        sessionIds: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async -> PersonPhotosResult? {
        do {
            return try await person.searchPhotos(
                PersonSearchPhotosParams(
                    personId: personId,
                    sessionIds: sessionIds,
                    limit: limit,
                    offset: offset
                )
            )
        } catch {
            actionError = CommandError(error)
            return nil
        }
    }

    /// 写路径广播的发布者标识：本页监听器据此跳过自触发重查。
    public static let changeOrigin = "persons"

    /// 写路径统一广播：常驻页（人脸库/人脸绑定侧）监听 .persons 后按域刷新。
    private func publishChange() {
        GatherEventCenter.postDomainChange(.persons, origin: Self.changeOrigin)
    }

    private func reloadAndSelect(_ personId: String?) async throws {
        // 刷新提交后，任何在途的 select 结果都已过期。
        selectionGeneration &+= 1
        persons = try await person.list()
        if let personId, persons.contains(where: { $0.id == personId }) {
            selected = try await person.get(personId)
            actionError = nil
        } else if let first = persons.first {
            // 主列表成功但详情加载失败时写入 actionError，不静默置 nil。
            do {
                selected = try await person.get(first.id)
                actionError = nil
            } catch {
                selected = nil
                actionError = CommandError(error)
            }
        } else {
            selected = nil
            actionError = nil
        }
        phase = .loaded
    }

}
