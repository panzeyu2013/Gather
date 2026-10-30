// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+Loading.swift
// Cut 4 / 4c-2d：数据加载 / 语言与推理后端 / 模型目录与恢复默认（原 SettingsView.swift
// 182-263、446-504 行）。纯搬移：方法体逐字复制，只有 private -> internal 的访问级
// 调整（跨文件 extension 调用）。
import SwiftUI
import AppKit
import GatherProtocol

extension SettingsViewModel {

    // MARK: - 数据加载

    public func load() {
        Task { await load(using: settingsAPI) }
    }

    private func load(using api: any SettingsAPI) async {
        do {
            let values = try await api.all()
            let status = try? await api.mlStatus()
            applyLoadedSettings(values: values, modelStatus: status)
        } catch {
            errorMessage = CommandError(error)
        }
    }

    private func applyLoadedSettings(values: [String: String], modelStatus: MLStatusData?) {
        self.values = values
        if let modelStatus { self.modelStatus = modelStatus }
        language = displayLanguage(from: values)
        backend = values["face_compute_units"] ?? "auto"
        edits = values
        seedSliderValues()
        reconcileDownloadPhaseWithModelStatus()
        errorMessage = nil
    }

    /// Picker 显示「当前生效语言」：空串（跟随系统）不能显示成“简体中文”。
    private func displayLanguage(from values: [String: String]) -> String {
        let stored = values["ui_language"] ?? ""
        return stored.isEmpty ? languageStore.language.rawValue : stored
    }

    private func seedSliderValues() {
        for slider in Self.generalSliders + Self.advancedSliders {
            sliderValues[slider.key] = sliderValue(for: slider.key, defaultValue: slider.defaultValue)
        }
    }

    public func sliderValue(for key: String, defaultValue: Double) -> Double {
        sliderValues[key] ?? Double(values[key] ?? "") ?? defaultValue
    }

    public func sliderValueText(_ slider: SliderSetting) -> String {
        let value = sliderValue(for: slider.key, defaultValue: slider.defaultValue)
        return slider.isInteger ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }

    // MARK: - 语言（settings.set_language 持久化 + 页内文案联动）

    public func setLanguage(_ value: String) {
        guard let language = InterfaceLanguage(rawValue: value) else {
            errorMessage = CommandError(code: GatherErrorCode.SETTINGS_LANGUAGE_INVALID.rawValue)
            return
        }
        Task {
            do {
                // 持久化 + 广播仍归 SettingsAPI（LiveSettingsAPI 是唯一落库入口）；
                // 本地语言状态只经 LanguageStore 写。生产路径里 API 的广播
                // 已先被 store 采纳，下面这次 set 是幂等 no-op（不会二次广播）；
                // stub/无广播实现下则由此兜底。
                let applied = try await settingsAPI.setLanguage(language)
                self.languageStore.set(L10n.Language(rawLanguage: applied.rawValue))
                self.language = applied.rawValue
                self.values["ui_language"] = applied.rawValue
                self.notice = LocalizedText("语言已保存")
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }

    // MARK: - 推理后端

    public func setBackend(_ value: String) {
        Task {
            do {
                let input = try SettingsSetInput(key: "face_compute_units", value: value)
                try await settingsAPI.set(input)
                self.backend = value
                self.values["face_compute_units"] = value
                self.modelStatus = try? await settingsAPI.mlStatus()
                self.notice = LocalizedText("推理后端已保存")
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }
    // MARK: - 目录与重置

    public func openModelDirectory() {
        guard let path = modelStatus?.modelResourcesDir, !path.isEmpty else {
            errorMessage = CommandError.localized("模型目录不可用")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func openModelPathDirectory(key: String) {
        let resolved: String?
        if key == "detector_model_path" {
            resolved = modelStatus?.detectorModel.resolvedPath
        } else {
            resolved = modelStatus?.encoderModel.resolvedPath
        }
        guard let resolved, !resolved.isEmpty else {
            errorMessage = CommandError.localized("模型路径不可用")
            return
        }
        let parent = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        NSWorkspace.shared.open(URL(fileURLWithPath: parent, isDirectory: true))
    }

    /// P1-5：读取影响面（模板/批次/配方计数）供 ResetImpactSheet 展示。
    public func previewResetImpact() async -> SettingsResetImpact? {
        do {
            return try await settingsAPI.previewReset()
        } catch {
            errorMessage = CommandError(error)
            return nil
        }
    }

    /// P1-5：分级 reset；未勾选的 scope 原样保留。
    /// 破坏性入口只接收确认分支构造的 Confirmed，VM 不自行“补”确认。
    public func reset(_ confirmed: Confirmed<SettingsResetInput>) async {
        do {
            let input = confirmed.value
            let result = try await settingsAPI.reset(confirmed)
            applyResetSettings(result.values)
            if input.resetUserContent {
                notice = LocalizedText("已恢复默认设置并清除所选用户内容")
            }
            modelStatus = try? await settingsAPI.mlStatus()
        } catch {
            errorMessage = CommandError(error)
        }
    }

    private func applyResetSettings(_ values: [String: String]) {
        self.values = values
        // 空串 = 跟随系统语言：同步到系统语言，不能硬编码成简体中文
        //（否则英文用户点一次「恢复默认」整窗立刻变中文，与“未勾选语言会保留”相反）。
        let storedLanguage = values["ui_language"] ?? ""
        if storedLanguage.isEmpty {
            // 空串 = 跟随系统。不能用 GatherLocalization.appLanguage：它已经被
            // 上一次显式切换覆盖成“当前语言”，set 同值会变成 no-op。
            _ = languageStore.set(rawLanguage: GatherLocalization.systemLanguage)
        } else {
            _ = languageStore.set(rawLanguage: storedLanguage)
        }
        language = displayLanguage(from: values)
        backend = values["face_compute_units"] ?? "auto"
        edits = values
        seedSliderValues()
        notice = LocalizedText("设置已恢复默认值")
        // P1：导出页缓存了 output.recipes；reset 删除用户内容后必须让它失效，
        // 否则下一次交付会把旧配方写回 settings。
        NotificationCenter.default.post(name: GatherAppNotification.settingsChanged, object: nil)
    }

    /// 取消破坏性动作：可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: String) {
        notice = LocalizedText.cancel(action)
        errorMessage = nil
    }
}
