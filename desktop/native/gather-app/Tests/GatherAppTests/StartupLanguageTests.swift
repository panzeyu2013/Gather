// desktop/native/gather-app/Tests/GatherAppTests/StartupLanguageTests.swift
// Cut 1 / B8.2d：冷启动语言的读取路径。
//
// 迁移前：GatherApp.bootstrap 调旧命令面的 applyStoredInterfaceLanguage()
//（内部读 SettingsService）；迁移后：SettingsAPI.get("ui_language") 是唯一入口。
// 这里只测读取语义（键名 / 空值回退），不切换进程级 appLanguage，避免与并行
// 套件的中文文案断言互相干扰（见 Tests/Support/AppLanguageLock.swift）。
import Testing
@testable import GatherUI
@testable import GatherHost

@Suite("启动语言")
@MainActor
struct StartupLanguageTests {
    @Test("启动语言经 SettingsAPI.get(ui_language) 读取")
    func startupLanguageReadsStoredValue() async {
        let settings = B8SettingsAPIStub(values: ["ui_language": "en"])
        let language = await AppBootstrap.storedInterfaceLanguage(using: settings)
        #expect(language == "en")
        // 键名契约：只能读 ui_language（设置页 setLanguage 写的是同一个键）。
        #expect(settings.getKeys.map(\.value) == ["ui_language"])
        // Cut 4 / 4b-2g：存储值经**显式 L10n** 解析，不依赖系统语言。
        #expect(language.map { L10n(rawLanguage: $0)("设置") } == "Settings")
    }

    @Test("ui_language 未设置或为空时保持系统语言检测")
    func startupLanguageFallsBackToSystemDetection() async {
        let unset = await AppBootstrap.storedInterfaceLanguage(using: B8SettingsAPIStub())
        #expect(unset == nil)
        let empty = await AppBootstrap.storedInterfaceLanguage(
            using: B8SettingsAPIStub(values: ["ui_language": ""])
        )
        #expect(empty == nil)
    }

    @Test("存储的 en → 显式 L10n 即刻出英文（启动播种后不看系统语言）")
    func storedEnglishMapsToExplicitL10n() async {
        let stored = await AppBootstrap.storedInterfaceLanguage(
            using: B8SettingsAPIStub(values: ["ui_language": "en"])
        )
        let l10n = L10n(rawLanguage: stored ?? "")
        #expect(l10n.language == .en)
        #expect(l10n("设置") == "Settings")
        #expect(l10n("界面语言") == "Interface Language")
        // 未识别/空值回退默认本地化语言（与 Package defaultLocalization 一致）。
        #expect(L10n(rawLanguage: "").language == .zhCN)
        #expect(L10n(rawLanguage: "fr").language == .zhCN)
    }
}
