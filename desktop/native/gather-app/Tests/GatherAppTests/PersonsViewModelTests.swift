// desktop/native/gather-app/Tests/GatherAppTests/PersonsViewModelTests.swift
// 审查 A 回归 + Cut 1 / B7b：PersonsViewModel 走 any PersonAPI。
//
// 覆盖：
// - 错误漏斗：非 GatherError（BridgeError/SessionServiceError/APIError）
//   行为不变；API 边界新抛出的 GatherError 由 APIErrorPresentation 认码；
// - 选择收敛：列表刷新后不保留被删人物的详情；用户选择不被覆盖；
// - 8 个 API 方法：list/get/create/update/delete/merge/removePhoto/searchPhotos；
// - delete/merge/removePhoto：未确认不发请求，确认后只构造 Confirmed(.userDialog)。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

// MARK: - Stub PersonAPI

private final class StubPersonAPI: PersonAPI, @unchecked Sendable {
    var persons: [PersonData] = []
    var details: [String: PersonDetailData] = [:]
    var listError: Error?
    var getError: Error?
    var createError: Error?
    var updateError: Error?
    var deleteError: Error?
    var mergeError: Error?
    var removePhotoError: Error?
    var searchError: Error?

    var createResult = PersonCreateResult(id: "p-new")
    var searchResult = PersonPhotosResult(photos: [], total: 0)

    var listCalls = 0
    var getCalls: [String] = []
    var createInputs: [PersonCreateParams] = []
    var updateInputs: [PersonUpdateParams] = []
    var deleteInputs: [Confirmed<PersonDeleteInput>] = []
    var mergeInputs: [Confirmed<PersonMergeInput>] = []
    var removePhotoInputs: [Confirmed<PersonRemovePhotoInput>] = []
    var searchInputs: [PersonSearchPhotosParams] = []

    /// 写操作成功后的假数据库变化（由测试开关控制），让随后的 list/get 看到新状态。
    /// 不用闭包回调：测试闭包在 @MainActor 上下文形成，被 nonisolated 的 API
    /// 方法调用时 Swift 6 会触发 executor 断言。
    var createAppendsPerson = false
    var updateRewritesDetail = false
    var deleteMutatesStore = false
    var mergeMutatesStore = false
    var removePhotoMutatesDetail = false

    func list() async throws -> [PersonData] {
        listCalls += 1
        if let listError { throw listError }
        return persons
    }

    func get(_ personId: String) async throws -> PersonDetailData {
        getCalls.append(personId)
        if let getError { throw getError }
        if let detail = details[personId] { return detail }
        throw GatherError(code: .PERSON_NOT_FOUND)
    }

    func create(_ input: PersonCreateParams) async throws -> PersonCreateResult {
        createInputs.append(input)
        if let createError { throw createError }
        if createAppendsPerson {
            persons.append(makePerson(createResult.id, name: input.name))
            details[createResult.id] = makeDetail(createResult.id, name: input.name)
        }
        return createResult
    }

    func update(_ input: PersonUpdateParams) async throws {
        updateInputs.append(input)
        if let updateError { throw updateError }
        if updateRewritesDetail, let name = input.name {
            details[input.personId] = makeDetail(input.personId, name: name)
        }
    }

    func delete(_ input: Confirmed<PersonDeleteInput>) async throws {
        deleteInputs.append(input)
        if let deleteError { throw deleteError }
        if deleteMutatesStore {
            persons.removeAll { $0.id == input.value.personId }
            details[input.value.personId] = nil
        }
    }

    func merge(_ input: Confirmed<PersonMergeInput>) async throws {
        mergeInputs.append(input)
        if let mergeError { throw mergeError }
        if mergeMutatesStore {
            persons.removeAll { $0.id == input.value.sourceId }
            details[input.value.sourceId] = nil
        }
    }

    func removePhoto(_ input: Confirmed<PersonRemovePhotoInput>) async throws {
        removePhotoInputs.append(input)
        if let removePhotoError { throw removePhotoError }
        if removePhotoMutatesDetail, let detail = details[input.value.personId] {
            details[input.value.personId] = PersonDetailData(
                id: detail.id, name: detail.name, keywords: detail.keywords,
                thumbnailBase64: detail.thumbnailBase64,
                thumbnailPath: detail.thumbnailPath,
                notes: detail.notes, matchThreshold: detail.matchThreshold,
                photoCount: detail.photoCount,
                sessionCount: detail.sessionCount,
                createdAt: detail.createdAt, updatedAt: detail.updatedAt,
                photos: detail.photos.filter { $0.photoId != input.value.photoId },
                totalPhotoCount: max(0, detail.totalPhotoCount - 1)
            )
        }
    }

    func searchPhotos(_ input: PersonSearchPhotosParams) async throws -> PersonPhotosResult {
        searchInputs.append(input)
        if let searchError { throw searchError }
        return searchResult
    }
}

// MARK: - Fixtures

private func makePerson(_ id: String, name: String) -> PersonData {
    PersonData(
        id: id, name: name, keywords: [], notes: "", matchThreshold: 0.5,
        photoCount: 0, sessionCount: 0,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeDetail(
    _ id: String,
    name: String,
    photos: [PersonPhotoItem] = []
) -> PersonDetailData {
    PersonDetailData(
        id: id, name: name, keywords: [], notes: "", matchThreshold: 0.5,
        photoCount: photos.count, sessionCount: photos.isEmpty ? 0 : 1,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
        photos: photos, totalPhotoCount: photos.count
    )
}

private func makePhoto(_ personId: String, _ photoId: String) -> PersonPhotoItem {
    PersonPhotoItem(
        photoId: photoId, sessionId: "s1", sessionName: "S1",
        filename: "\(photoId).jpg", filepath: "/tmp/\(photoId).jpg",
        faceBbox: [], confidence: 0.9
    )
}

@MainActor
@Suite("PersonsViewModel（B7b：PersonAPI 注入）")
struct PersonsViewModelTests {
    private func loadedViewModel(
        _ stub: StubPersonAPI,
        persons: [PersonData],
        details: [String: PersonDetailData]
    ) async -> PersonsViewModel {
        stub.persons = persons
        stub.details = details
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        return viewModel
    }

    // MARK: 错误漏斗（审查 A）

    /// router person.get 缺行的真实构造：BridgeError.notFound("PERSON_NOT_FOUND")。
    @Test func loadFailureTranslatesBridgeErrorCode() async throws {
        let stub = StubPersonAPI()
        stub.listError = BridgeError.notFound("PERSON_NOT_FOUND")
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        // Cut 4 / 4a-3b-2a：phase 只存码值，渲染期由 CommandErrorText 解析文案。
        let error = try #require(viewModel.phase.error)
        #expect(error.code == "PERSON_NOT_FOUND")
        let l10n = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(error, with: l10n) == l10n.errorText("PERSON_NOT_FOUND"))
        #expect(CommandErrorText.resolve(error, with: l10n) != l10n.errorText("NOT_A_CODE"))
    }

    /// SessionServiceError 不满足 LocalizedError，必须经 gatherCode 翻译。
    @Test func loadFailureTranslatesSessionServiceError() async throws {
        let stub = StubPersonAPI()
        stub.listError = SessionServiceError.sourceRootForbidden
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        let error = try #require(viewModel.phase.error)
        #expect(error.code == "SESSION_SOURCE_ROOT_FORBIDDEN")
        let l10n = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(error, with: l10n) == l10n.errorText("SESSION_SOURCE_ROOT_FORBIDDEN"))
    }

    /// B7b 新增：API 边界的 GatherError 必须被错误漏斗认码（旧 funnel 不认）。
    @Test func loadFailureTranslatesGatherError() async throws {
        let stub = StubPersonAPI()
        stub.listError = GatherError(code: .PERSON_NOT_FOUND)
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        let error = try #require(viewModel.phase.error)
        #expect(error.code == "PERSON_NOT_FOUND")
        let l10n = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(error, with: l10n) == l10n.errorText("PERSON_NOT_FOUND"))
    }

    /// 参数化码（单冒号）经漏斗后参数不丢。
    @Test func selectFailureKeepsParameterizedCode() async {
        let stub = StubPersonAPI()
        let raw = "XMP_CONFIRM_OTHER_SESSION_PENDING: s1"
        stub.getError = APIError.failed(raw)
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.select("p1")
        AppLanguageLock.withStableCopy {
            let expected = GatherLocalization.errorText(raw)
            let error = viewModel.actionError
            #expect(error?.code == raw)
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == expected)
            #expect(expected.contains("s1"))
        }
    }

    /// 未知码仍不猜：回退通用文案（不得把原始诊断直显）。
    @Test func unknownCodeFallsBackToGeneric() async throws {
        let stub = StubPersonAPI()
        stub.listError = APIError.failed("PERSONS_PROSE_DIAGNOSTIC")
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        // 未知码/英文诊断不得直显：渲染期回退通用文案（原始诊断只进 carrier）。
        let error = try #require(viewModel.phase.error)
        #expect(error.code.isEmpty)
        #expect(error.diagnostic == "PERSONS_PROSE_DIAGNOSTIC")
        let l10n = L10n(language: .zhCN)
        #expect(CommandErrorText.resolve(error, with: l10n) == l10n.errorText("NOT_A_CODE"))
        #expect(!CommandErrorText.resolve(error, with: l10n).contains("PERSONS_PROSE_DIAGNOSTIC"))
    }

    // MARK: 选择收敛（9-30 审查 B4）

    @Test("B4：选中的人物被别处删除后，重新加载必须清空选择而不是留着旧详情")
    func reloadClearsSelectionForDeletedPerson() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A")]
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        #expect(viewModel.selected?.id == "p1")

        // 另一个窗口删除了 p1，列表刷新后为空。
        stub.persons = []
        stub.details = [:]
        await viewModel.load()
        #expect(viewModel.selected == nil, "被删除的人物不得继续留在详情栏（会拿失效 ID 发命令）")
    }

    @Test("B4：选中的人物仍在列表里时保持选择")
    func reloadKeepsExistingSelection() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A"), makePerson("p2", name: "B")]
        stub.details = ["p1": makeDetail("p1", name: "A"), "p2": makeDetail("p2", name: "B")]
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        await viewModel.select("p2")
        await viewModel.load()
        #expect(viewModel.selected?.id == "p2", "重新加载不得把用户选的人物换成第一个")
    }

    @Test("B7b：select 走 PersonAPI.get")
    func selectLoadsDetailThroughAPI() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A")]
        let viewModel = PersonsViewModel(person: stub)
        await viewModel.load()
        await viewModel.select("p1")
        #expect(viewModel.selected?.id == "p1")
        #expect(stub.getCalls.contains("p1"))
    }

    // MARK: 写路径：create / update

    @Test("B7b：create 用 trim 后的姓名，成功后重新拉列表并选中新人物")
    func createSendsTrimmedNameAndSelectsCreated() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A")]
        stub.createAppendsPerson = true
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.create(name: "  New Person  ")
        #expect(ok)
        #expect(stub.createInputs.map(\.name) == ["New Person"])
        #expect(viewModel.selected?.id == "p-new")
    }

    @Test("B7b：saveSelected 走 PersonAPI.update 并刷新详情")
    func saveSelectedSendsUpdate() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A")]
        stub.updateRewritesDetail = true
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.saveSelected(name: "A2", notes: "note")
        #expect(ok)
        #expect(stub.updateInputs.count == 1)
        #expect(stub.updateInputs[0].personId == "p1")
        #expect(stub.updateInputs[0].name == "A2")
        #expect(stub.updateInputs[0].notes == "note")
        #expect(viewModel.selected?.name == "A2")
    }

    // MARK: 破坏性：delete

    @Test("B7b：delete 未确认不发请求，并保留取消文案")
    func deleteRequiresConfirmation() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A")]
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.deleteSelected(confirmed: false)
        #expect(!ok)
        #expect(stub.deleteInputs.isEmpty)
        AppLanguageLock.withStableCopy {
            let error = viewModel.actionError
            #expect(error?.origin == .localValidation)
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == GatherLocalization.l("未确认，已取消删除人物"))
        }
        #expect(viewModel.selected?.id == "p1")
    }

    @Test("B7b：delete 确认后只发 Confirmed(.userDialog)，并刷新列表/选择")
    func deleteUsesConfirmedUserDialogAndRefreshes() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A"), makePerson("p2", name: "B")]
        stub.details = ["p1": makeDetail("p1", name: "A"), "p2": makeDetail("p2", name: "B")]
        stub.deleteMutatesStore = true
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.deleteSelected(confirmed: true)
        #expect(ok)
        #expect(stub.deleteInputs.count == 1)
        #expect(stub.deleteInputs[0].source == .userDialog)
        #expect(stub.deleteInputs[0].value.personId == "p1")
        #expect(viewModel.persons.map(\.id) == ["p2"])
        #expect(viewModel.selected?.id == "p2")
    }

    // MARK: 破坏性：merge

    @Test("B7b：merge 未确认不发请求，actionError 用 PERSON_MERGE_CONFIRM_REQUIRED")
    func mergeRequiresConfirmation() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A"), makePerson("p2", name: "B")]
        stub.details = ["p1": makeDetail("p1", name: "A"), "p2": makeDetail("p2", name: "B")]
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.merge(sourceId: "p1", targetId: "p2", confirmed: false)
        #expect(!ok)
        #expect(stub.mergeInputs.isEmpty)
        AppLanguageLock.withStableCopy {
            let error = viewModel.actionError
            #expect(error?.code == "PERSON_MERGE_CONFIRM_REQUIRED")
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == GatherLocalization.errorText("PERSON_MERGE_CONFIRM_REQUIRED"))
        }
    }

    @Test("B7b：merge 确认后只发 Confirmed(.userDialog)，源消失并选中目标")
    func mergeUsesConfirmedUserDialogAndSelectsTarget() async throws {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A"), makePerson("p2", name: "B")]
        stub.details = ["p1": makeDetail("p1", name: "A"), "p2": makeDetail("p2", name: "B")]
        stub.mergeMutatesStore = true
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.merge(sourceId: "p1", targetId: "p2", confirmed: true)
        #expect(ok)
        #expect(stub.mergeInputs.count == 1)
        #expect(stub.mergeInputs[0].source == .userDialog)
        #expect(stub.mergeInputs[0].value == (try PersonMergeInput(sourceId: "p1", targetId: "p2")))
        #expect(viewModel.persons.map(\.id) == ["p2"])
        #expect(viewModel.selected?.id == "p2")
    }

    // MARK: 破坏性：removePhoto

    @Test("B7b：removePhoto 未确认不发请求，actionError 用 PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED")
    func removePhotoRequiresConfirmation() async {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A", photos: [makePhoto("p1", "ph1")])]
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.removePhoto(personId: "p1", photoId: "ph1", confirmed: false)
        #expect(!ok)
        #expect(stub.removePhotoInputs.isEmpty)
        AppLanguageLock.withStableCopy {
            let error = viewModel.actionError
            #expect(error?.code == "PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED")
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == GatherLocalization.errorText("PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED"))
        }
    }

    @Test("B7b：removePhoto 确认后只发 Confirmed(.userDialog)，详情照片/计数刷新")
    func removePhotoUsesConfirmedUserDialogAndRefreshes() async throws {
        let stub = StubPersonAPI()
        stub.persons = [makePerson("p1", name: "A")]
        stub.details = ["p1": makeDetail("p1", name: "A", photos: [makePhoto("p1", "ph1")])]
        stub.removePhotoMutatesDetail = true
        let viewModel = await loadedViewModel(stub, persons: stub.persons, details: stub.details)
        let ok = await viewModel.removePhoto(personId: "p1", photoId: "ph1", confirmed: true)
        #expect(ok)
        #expect(stub.removePhotoInputs.count == 1)
        #expect(stub.removePhotoInputs[0].source == .userDialog)
        #expect(stub.removePhotoInputs[0].value == (try PersonRemovePhotoInput(personId: "p1", photoId: "ph1")))
        #expect(viewModel.selected?.photos.isEmpty == true)
        #expect(viewModel.selected?.totalPhotoCount == 0)
    }

    // MARK: searchPhotos

    @Test("B7b：searchPhotos 透传人物/工作区/分页参数并返回结果")
    func searchPhotosPassesFilters() async {
        let stub = StubPersonAPI()
        let photo = makePhoto("p1", "ph1")
        stub.searchResult = PersonPhotosResult(photos: [photo], total: 7)
        let viewModel = PersonsViewModel(person: stub)
        let result = await viewModel.searchPhotos(
            personId: "p1",
            sessionIds: ["s1", "s2"],
            limit: 10,
            offset: 20
        )
        #expect(result?.photos == [photo])
        #expect(result?.total == 7)
        #expect(stub.searchInputs.count == 1)
        #expect(stub.searchInputs[0] == PersonSearchPhotosParams(
            personId: "p1",
            sessionIds: ["s1", "s2"],
            limit: 10,
            offset: 20
        ))
    }

    @Test("B7b：searchPhotos 失败写入 actionError 并返回 nil")
    func searchPhotosFailureFunnelsError() async {
        let stub = StubPersonAPI()
        stub.searchError = GatherError(code: .PERSON_NOT_FOUND)
        let viewModel = PersonsViewModel(person: stub)
        let result = await viewModel.searchPhotos(personId: "missing")
        AppLanguageLock.withStableCopy {
            #expect(result == nil)
            let error = viewModel.actionError
            #expect(error?.code == "PERSON_NOT_FOUND")
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == GatherLocalization.errorText("PERSON_NOT_FOUND"))
        }
    }
}
