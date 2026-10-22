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
        language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
        backend = values["face_compute_units"] ?? "auto"
        edits = values
        seedSliderValues()
        reconcileDownloadPhaseWithModelStatus()
        errorMessage = nil
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

    /// 恢复默认（破坏性：模型路径、推理后端、缓存、写回参数等全部设置重置）。
    /// `confirmed` 只能由确认弹窗传入 true；未确认不发命令。
    public func reset(confirmed: Bool) {
        guard confirmed else {
            notice = LocalizedText("未确认，已取消恢复默认设置")
            return
        }
        Task {
            do {
                let values = try await settingsAPI.reset()
                self.applyResetSettings(values)
                self.modelStatus = try? await settingsAPI.mlStatus()
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }

    private func applyResetSettings(_ values: [String: String]) {
        self.values = values
        language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
        backend = values["face_compute_units"] ?? "auto"
        edits = values
        seedSliderValues()
        notice = LocalizedText("设置已恢复默认值")
        // 不广播 .settings：设置写入无常驻页消费者（各页在重新可见/加载时
        // 自行读取最新设置值），发布只会留下无人订阅的死事件。
    }

    /// 取消破坏性动作：可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: String) {
        notice = LocalizedText.cancel(action)
        errorMessage = nil
    }
}
