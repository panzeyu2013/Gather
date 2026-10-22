// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsConfirmations.swift
// Cut 4 / 4c-2d：破坏性确认的上下文模型（模型覆盖安装 / 恢复默认设置），
// 原 SettingsView.swift 1236-1264 行。纯搬移：保留 Identifiable 与渲染期 l10n 文案；
// 由 private 改 internal（SettingsView 壳跨文件引用）。
import Foundation

/// 模型覆盖安装确认：下载解压会覆盖模型目录中的同名文件。
struct PendingModelInstall: Identifiable {
    let modelDir: String

    var id: String { "model-install-\(modelDir)" }

    /// Cut 4 / 4b-2g：确认文案在渲染/呈现期按页面 l10n 解析（结构体不持语言）。
    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将从网络下载模型包并解压到 %@；同名模型文件会被覆盖，旧文件不可恢复。取消不会下载任何内容。",
            modelDir
        )
    }
}

/// 恢复默认设置的确认上下文：影响范围 = 将被重置的设置项数量。
struct PendingSettingsReset: Identifiable {
    let keyCount: Int

    var id: String { "settings-reset-\(keyCount)" }

    /// Cut 4 / 4b-2g：确认文案在呈现期按页面 l10n 解析（结构体不持语言）。
    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将把当前 %lld 项设置恢复为默认值（模型路径、推理后端、缓存与写回参数等）；不会删除照片或 XMP 文件。取消不改变任何设置。",
            keyCount
        )
    }
}
