// desktop/native/gather-app/Tests/GatherAppTests/PersonsViewModelTests.swift
// 审查 A 回归：PersonsViewModel 的错误漏斗必须翻译码值。
// 旧实现把 NativeCommandError/BridgeError 交给 (error as NSError).localizedDescription，
// 这两类不满足 LocalizedError → 桥接后退化为 "The operation couldn't be completed…"，
// 于是真实可达的 BridgeError.notFound("PERSON_NOT_FOUND")（router person.get 缺行）
// 被显示成通用文案。
import Foundation
import Testing
@testable import GatherApp
@testable import GatherCore

private final class StubPersonsProvider: PersonsDataProvider {
    var listError: Error?
    var getError: Error?
    /// B4 回归用：可控的人物列表与详情。
    var persons: [PersonData] = []
    var details: [String: PersonDetailData] = [:]

    func list() throws -> [PersonData] {
        if let listError { throw listError }
        return persons
    }

    func get(_ personId: String) throws -> PersonDetailData {
        if let getError { throw getError }
        if let detail = details[personId] { return detail }
        throw NativeCommandError.failed("NOT_A_CODE")
    }

    func create(name: String) throws -> String {
        throw NativeCommandError.failed("NOT_A_CODE")
    }

    func update(personId: String, name: String, notes: String) throws {
        throw NativeCommandError.failed("NOT_A_CODE")
    }

    func delete(personId: String, confirmed: Bool) throws {
        throw NativeCommandError.failed("NOT_A_CODE")
    }
}

@MainActor
@Suite("PersonsViewModel 错误漏斗（审查 A 回归）")
struct PersonsViewModelTests {
    /// router person.get 缺行的真实构造：BridgeError.notFound("PERSON_NOT_FOUND")。
    @Test func loadFailureTranslatesBridgeErrorCode() async {
        let stub = StubPersonsProvider()
        stub.listError = BridgeError.notFound("PERSON_NOT_FOUND")
        let viewModel = PersonsViewModel(provider: stub)
        await viewModel.load()
        // 文案断言与切语言的套件互斥（appLanguage 是进程级全局量）。
        AppLanguageLock.withStableCopy {
            let generic = GatherLocalization.errorText("NOT_A_CODE")
            #expect(viewModel.phase == .failed(GatherLocalization.errorText("PERSON_NOT_FOUND")))
            #expect(viewModel.phase != .failed(generic))
        }
    }

    /// SessionServiceError 不满足 LocalizedError，必须经 gatherCode 翻译。
    @Test func loadFailureTranslatesSessionServiceError() async {
        let stub = StubPersonsProvider()
        stub.listError = SessionServiceError.sourceRootForbidden
        let viewModel = PersonsViewModel(provider: stub)
        await viewModel.load()
        AppLanguageLock.withStableCopy {
            #expect(viewModel.phase == .failed(GatherLocalization.errorText("SESSION_SOURCE_ROOT_FORBIDDEN")))
        }
    }

    /// 参数化码（单冒号）经漏斗后参数不丢。
    @Test func selectFailureKeepsParameterizedCode() {
        let stub = StubPersonsProvider()
        let raw = "XMP_CONFIRM_OTHER_SESSION_PENDING: s1"
        stub.getError = NativeCommandError.failed(raw)
        let viewModel = PersonsViewModel(provider: stub)
        AppLanguageLock.withStableCopy {
            viewModel.select("p1")
            let expected = GatherLocalization.errorText(raw)
            #expect(viewModel.actionError == expected)
            #expect(expected.contains("s1"))
        }
    }

    /// 未知码仍不猜：回退通用文案（不得把原始诊断直显）。
    @Test func unknownCodeFallsBackToGeneric() async {
        let stub = StubPersonsProvider()
        stub.listError = NativeCommandError.failed("PERSONS_PROSE_DIAGNOSTIC")
        let viewModel = PersonsViewModel(provider: stub)
        await viewModel.load()
        AppLanguageLock.withStableCopy {
            #expect(viewModel.phase == .failed(GatherLocalization.errorText("NOT_A_CODE")))
        }
    }

    // MARK: 9-30 审查 B4：选择必须随列表收敛

    private func person(_ id: String, name: String) -> PersonData {
        PersonData(
            id: id, name: name, keywords: [], notes: "", matchThreshold: 0.5,
            photoCount: 0, sessionCount: 0,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    private func detail(_ id: String, name: String) -> PersonDetailData {
        PersonDetailData(
            id: id, name: name, keywords: [], notes: "", matchThreshold: 0.5,
            photoCount: 0, sessionCount: 0,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
            photos: [], totalPhotoCount: 0
        )
    }

    @Test("B4：选中的人物被别处删除后，重新加载必须清空选择而不是留着旧详情")
    func reloadClearsSelectionForDeletedPerson() async {
        let stub = StubPersonsProvider()
        stub.persons = [person("p1", name: "A")]
        stub.details = ["p1": detail("p1", name: "A")]
        let viewModel = PersonsViewModel(provider: stub)
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
        let stub = StubPersonsProvider()
        stub.persons = [person("p1", name: "A"), person("p2", name: "B")]
        stub.details = ["p1": detail("p1", name: "A"), "p2": detail("p2", name: "B")]
        let viewModel = PersonsViewModel(provider: stub)
        await viewModel.load()
        viewModel.select("p2")
        await viewModel.load()
        #expect(viewModel.selected?.id == "p2", "重新加载不得把用户选的人物换成第一个")
    }
}
