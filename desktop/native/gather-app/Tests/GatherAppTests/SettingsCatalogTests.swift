// desktop/native/gather-app/Tests/GatherAppTests/SettingsCatalogTests.swift
// 设置目录一致性（防呆不变量）：
//   ① 设置界面引用的键必须存在于 SettingsService 的默认值表——set() 会按该表校验，
//      少一个键意味着一整条 UI 静默写不进去（本轮真实踩到过：算法参数先进了服务层，
//      没进默认表，用户改了不生效）；
//   ② 滑杆的 defaultValue 必须与默认表一致——两处漂移会让"重置为默认"写错值。

import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
@testable import GatherUI
@testable import GatherHost

@Suite("settings catalog")
@MainActor
struct SettingsCatalogTests {
    private var uiKeys: [String] {
        SettingsViewModel.generalSliders.map(\.key)
            + SettingsViewModel.advancedSliders.map(\.key)
            + SettingsViewModel.settingGroups.flatMap { $0.fields.map(\.key) }
    }

    @Test("设置界面引用的每个键都在默认表里")
    func everyUISettingKeyIsKnown() {
        let unknown = Set(uiKeys).subtracting(SettingsService.knownSettingKeys).sorted()
        #expect(unknown.isEmpty, "设置界面引用了未知键（写入会被拒）：\(unknown)")
    }

    @Test("滑杆默认值与设置默认表逐项一致")
    func sliderDefaultsMatchSettingsDefaults() {
        let defaults = SettingsService.getDefaults()
        var mismatched: [String] = []
        for slider in SettingsViewModel.generalSliders + SettingsViewModel.advancedSliders {
            guard let raw = defaults[slider.key], let value = Double(raw) else {
                mismatched.append("\(slider.key)：默认表缺项")
                continue
            }
            if abs(value - slider.defaultValue) > 1e-9 {
                mismatched.append("\(slider.key)：默认表 \(value) ≠ 界面 \(slider.defaultValue)")
            }
        }
        #expect(mismatched.isEmpty, "滑杆默认值与默认表不一致：\(mismatched)")
    }

    @Test("算法对标新增参数都在界面里可调（不允许只存在于数据库的旋钮）")
    func algorithmParametersAreExposed() {
        let keys = Set(uiKeys)
        for expected in [
            "face_core_quality", "face_core_retry_min_samples", "face_match_margin",
            "face_embedding_model_path", "face_embedding_model_version",
        ] {
            #expect(keys.contains(expected), "算法参数 \(expected) 未在设置界面暴露")
        }
    }

    // MARK: - Cut 4 / 4b-2g：动态设置文案的 en 覆盖

    /// 设置目录里所有不经源码字面量调用的 key：分组标题、字段/滑杆标题与说明、
    /// 下拉选项。它们由渲染期 `l10n(dynamicKey)` 查表，所以 en 表必须逐条覆盖；
    /// 任何一条回落中文，en 设置页就会出现中文。
    @Test("动态设置文案（分组/字段/滑杆/选项）都有 en 译文，不回落中文")
    func dynamicSettingCopyHasEnglishTranslation() {
        let en = L10n(language: .en)
        var keys: [String] = []
        for group in SettingsViewModel.settingGroups {
            keys.append(group.titleZh)
            for field in group.fields {
                keys.append(field.zhLabel)
                if !field.zhDesc.isEmpty { keys.append(field.zhDesc) }
                if case .select(let options) = field.type {
                    keys.append(contentsOf: options.map(\.labelZh))
                }
            }
        }
        for slider in SettingsViewModel.generalSliders + SettingsViewModel.advancedSliders {
            keys.append(slider.zhLabel)
            if !slider.zhDesc.isEmpty { keys.append(slider.zhDesc) }
        }

        let untranslated = keys.filter { containsCJK(en($0)) }
        #expect(!keys.isEmpty)
        #expect(untranslated.isEmpty, "以下设置文案在 en 下仍是中文（缺表/漏翻）：\(untranslated)")
    }

    @Test("label(for:with:)：动态 key 跟随传入语言（en 不回落中文）")
    func labelLookupFollowsExplicitLanguage() {
        #expect(SettingsViewModel.label(for: "face_match_margin", with: L10n(language: .zhCN)) == "歧义判定间隔")
        #expect(SettingsViewModel.label(for: "face_match_margin", with: L10n(language: .en)) == "Ambiguity margin")
        #expect(SettingsViewModel.label(for: "face_core_quality", with: L10n(language: .en)) == "Core-point quality floor")
        #expect(SettingsViewModel.label(for: "no_such_key", with: L10n(language: .en)) == "no_such_key")
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)
                || (0x3400...0x9FFF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}
