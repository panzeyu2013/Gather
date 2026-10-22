// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+Download.swift
// Cut 4 / 4c-2d：模型下载流水线（下载 → 解压 → 落位）的 VM 侧进度与错误文案
//（原 SettingsView.swift 702-757 行）。纯搬移，阶段语义不变。
import Foundation
import GatherProtocol

extension SettingsViewModel {

    // MARK: - 模型下载（旧版 model-downloader.ts 的 Swift 移植）

    public var isDownloading: Bool {
        if case .downloading = downloadPhase { return true }
        return false
    }

    public func startModelDownload() async {
        guard !isDownloading else { return }
        errorMessage = nil
        let configured = (values["model_download_url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: configured.isEmpty ? ModelInstaller.packageURL : configured) else {
            downloadPhase = .error
            errorMessage = CommandError.localized("模型下载地址无效")
            return
        }
        guard let modelsDir = modelStatus?.modelResourcesDir, !modelsDir.isEmpty else {
            downloadPhase = .error
            errorMessage = CommandError.localized("模型目录不可用")
            return
        }
        downloadPhase = .downloading(filename: "buffalo_l.zip", percent: 0, step: .downloading)
        do {
            try await ModelInstaller.install(url: url, modelsDir: modelsDir) { step, filename, percent in
                self.downloadPhase = .downloading(filename: filename, percent: percent, step: step)
            }
            downloadPhase = .done
            modelStatus = try? await settingsAPI.mlStatus()
            reconcileDownloadPhaseWithModelStatus()
        } catch {
            downloadPhase = .error
            // Cut 4 / 4b-2g：安装错误是 LocalizedText（key + 参数），按注入的
            // LanguageStore 解析——不再经 NSError 把旧语言字符串带进模板。
            let l10n = languageStore.l10n
            let raw: String
            if let install = error as? ModelInstaller.InstallError {
                raw = l10n.resolve(install.text)
            } else {
                // 诊断不直显：非错误码走 errorText 通用回退（与全局错误漏斗一致）。
                let nsError = error as NSError
                let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String
                    ?? nsError.localizedDescription
                raw = l10n.errorText(description)
            }
            errorMessage = CommandError.localized(
                "模型下载失败：%@",
                params: [raw]
            )
        }
    }

    /// 跨文件：+Loading 的 applyLoadedSettings 也会调用（读取模型状态后收敛当前阶段）。
    func reconcileDownloadPhaseWithModelStatus() {
        guard downloadPhase == .done, let model = modelStatus,
              !(model.detectorModel.exists && model.encoderModel.exists) else { return }
        downloadPhase = .idle
    }
}
