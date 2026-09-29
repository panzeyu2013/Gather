// desktop/native/gather-app/Tests/GatherAppTests/SettingsCatalogTests.swift
// 设置目录一致性（防呆不变量）：
//   ① 设置界面引用的键必须存在于 SettingsService 的默认值表——set() 会按该表校验，
//      少一个键意味着一整条 UI 静默写不进去（本轮真实踩到过：算法参数先进了服务层，
//      没进默认表，用户改了不生效）；
//   ② 滑杆的 defaultValue 必须与默认表一致——两处漂移会让"重置为默认"写错值。

import Testing
import GatherCore
@testable import GatherApp

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
}
