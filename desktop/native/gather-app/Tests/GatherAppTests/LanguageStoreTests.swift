// desktop/native/gather-app/Tests/GatherAppTests/LanguageStoreTests.swift
// Cut 4 / 4a-0：语言唯一写入口的切换/通知/订阅语义。
//
// 所有用例都注入独立 NotificationCenter，避免向进程级 .default 广播
// languageChanged（会让其它套件的旧订阅方跟着动）。写进程全局 appLanguage 的
// 用例统一包在 AppLanguageLock.withCopy 内（退出恢复原语言）。
import Foundation
import Testing
@testable import GatherUI

@Suite("LanguageStore 语言写入口", .serialized)
@MainActor
struct LanguageStoreTests {
    private struct NoticeState {
        var languages: [String] = []
    }

    /// 记录 languageChanged 广播（含 userInfo 语言值）。
    private func observe(_ center: NotificationCenter) -> (token: NSObjectProtocol, box: LockedBox<NoticeState>) {
        let box = LockedBox(NoticeState())
        let token = center.addObserver(
            forName: GatherAppNotification.languageChanged,
            object: nil,
            queue: nil
        ) { note in
            let language = note.userInfo?[LanguageStore.notificationLanguageKey] as? String ?? "nil"
            box.lock.withLock { box.languages.append(language) }
        }
        return (token, box)
    }

    private func postedLanguages(_ box: LockedBox<NoticeState>) -> [String] {
        var languages: [String] = []
        box.lock.withLock { languages = box.languages }
        return languages
    }

    @Test("init：显式语言优先，l10n 立即按该语言查表")
    func explicitInitialLanguage() {
        let store = LanguageStore(language: .en, notificationCenter: NotificationCenter())
        #expect(store.language == .en)
        #expect(store.changeCount == 0)
        #expect(store.l10n("工作区不存在") == "Workspace not found")
        #expect(store.l10n.errorText("SESSION_NOT_FOUND") == "Workspace not found")
    }

    @Test("init：未指定语言时沿用进程当前语言")
    func initialLanguageDefaultsToProcess() {
        AppLanguageLock.withCopy("en") {
            let store = LanguageStore(language: nil, notificationCenter: NotificationCenter())
            #expect(store.language == .en)
        }
    }

    @Test("set：真实切换才计数，同步旧全局，l10n 随之切换")
    func setCountsRealChanges() {
        AppLanguageLock.withCopy("zh-CN") {
            let store = LanguageStore(language: .zhCN, notificationCenter: NotificationCenter())
            #expect(store.set(.en))
            #expect(store.language == .en)
            #expect(store.changeCount == 1)
            #expect(GatherLocalization.appLanguage == "en")
            #expect(store.l10n("工作区不存在") == "Workspace not found")

            // 同值 no-op：不计数、不写
            #expect(!store.set(.en))
            #expect(store.changeCount == 1)

            #expect(store.set(.zhCN))
            #expect(store.changeCount == 2)
            #expect(GatherLocalization.appLanguage == "zh-CN")
            #expect(store.l10n("工作区不存在") == "工作区不存在")
        }
    }

    @Test("set(rawLanguage:)：只接受 zh-CN/en，非法值不改状态")
    func setRawLanguageValidation() {
        AppLanguageLock.withCopy("zh-CN") {
            let store = LanguageStore(language: .zhCN, notificationCenter: NotificationCenter())
            #expect(store.set(rawLanguage: "en") == .en)
            #expect(store.language == .en)
            #expect(store.changeCount == 1)

            #expect(store.set(rawLanguage: "fr") == nil)
            #expect(store.language == .en)
            #expect(store.changeCount == 1)

            #expect(LanguageStore.isSupported(rawLanguage: "zh-Hans"))
            #expect(LanguageStore.isSupported(rawLanguage: "en-US"))
            #expect(!LanguageStore.isSupported(rawLanguage: "de"))
            #expect(!LanguageStore.isSupported(rawLanguage: ""))
        }
    }

    @Test("set：广播 languageChanged，userInfo 携带新语言；同值不重复广播")
    func setPostsNotification() {
        AppLanguageLock.withCopy("zh-CN") {
            let center = NotificationCenter()
            let store = LanguageStore(language: .zhCN, notificationCenter: center)
            let observer = observe(center)
            defer { center.removeObserver(observer.token) }

            store.set(.en)
            #expect(postedLanguages(observer.box) == ["en"])

            store.set(.en)
            #expect(postedLanguages(observer.box) == ["en"])

            store.set(.zhCN)
            #expect(postedLanguages(observer.box) == ["en", "zh-CN"])
        }
    }

    @Test("订阅：外部广播被采纳（计数 + 同步全局），且不回环二次广播")
    func adoptsExternalNotification() {
        AppLanguageLock.withCopy("zh-CN") {
            let center = NotificationCenter()
            let store = LanguageStore(language: .zhCN, notificationCenter: center)
            let observer = observe(center)
            defer { center.removeObserver(observer.token) }

            center.post(
                name: GatherAppNotification.languageChanged,
                object: nil,
                userInfo: [LanguageStore.notificationLanguageKey: "en"]
            )

            #expect(store.language == .en)
            #expect(store.changeCount == 1)
            #expect(GatherLocalization.appLanguage == "en")
            // 只有外部那一条广播；store 采纳后不再二次广播
            #expect(postedLanguages(observer.box) == ["en"])

            // 非法载荷不改变状态
            center.post(
                name: GatherAppNotification.languageChanged,
                object: nil,
                userInfo: [LanguageStore.notificationLanguageKey: "fr"]
            )
            #expect(store.language == .en)
            #expect(store.changeCount == 1)
        }
    }

    @Test("seed：冷启动播种写全局但不广播；同值 no-op")
    func seedAppliesWithoutBroadcast() {
        AppLanguageLock.withCopy("zh-CN") {
            let center = NotificationCenter()
            let store = LanguageStore(language: .zhCN, notificationCenter: center)
            let observer = observe(center)
            defer { center.removeObserver(observer.token) }

            store.seed(.en)
            #expect(store.language == .en)
            #expect(GatherLocalization.appLanguage == "en")
            // 启动阶段没有订阅方：不投递 languageChanged（不触发 AppDelegate 重装菜单）。
            #expect(postedLanguages(observer.box).isEmpty)

            store.seed(.en)
            #expect(store.changeCount == 1)
        }
    }
}
