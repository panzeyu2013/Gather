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

    func list() throws -> [PersonData] {
        if let listError { throw listError }
        return []
    }

    func get(_ personId: String) throws -> PersonDetailData {
        if let getError { throw getError }
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
}
