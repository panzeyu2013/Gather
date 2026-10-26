// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+Fields.swift
// Cut 4 / 4c-2d：分组字段保存（空值规则 / 数值 min-max 校验）/ 模型路径编辑 / 滑杆提交
//（原 SettingsView.swift 278-444 行）。纯搬移，行为不变。
import SwiftUI
import AppKit
import GatherProtocol

extension SettingsViewModel {

    // MARK: - 分组设置（含类型约束：数值 min/max 校验，非法值禁止保存）

    public func saveField(_ field: SettingField, with l10n: L10n) {
        let raw = (edits[field.key] ?? values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            // 空值规则：只有"默认值本身为空"的键才允许清空——例如
            // face_embedding_model_path 清空 = 回到内置 SFace 身份模型（合法操作），
            // 而 detector_model_path 留空没有语义，仍按无效输入拒绝。
            guard Self.defaultValueIsEmpty(field.key) else {
                errorMessage = CommandError.localized(
                    "「%@」不能为空",
                    params: [l10n(field.zhLabel)]
                )
                return
            }
            save(key: field.key, value: "", with: l10n)
            return
        }
        switch field.type {
        case .text:
            // 专用人脸模型路径：保存时只做**廉价**校验（展开 ~、解析软链、存在性、
            // 扩展名），不加载模型、不做整包哈希——256 MiB 模型在 @MainActor 上
            // 加载+哈希实测 48.4s，界面会假死（对抗审查 V1 探针 I）。
            // R5-P1-1：失败原因用 UI 的固定 key + 参数（en/zh 都有条目），
            // 渲染期按界面语言解析；"能否真正加载"由分析路径负责。
            if field.key == Self.faceEmbeddingModelSettingKey,
               let issue = Self.faceEmbeddingModelPathError(raw) {
                errorMessage = issue.commandError
                return
            }
            save(key: field.key, value: raw, with: l10n)
        case .number(let min, let max):
            guard let parsed = Double(raw), parsed.isFinite else {
                errorMessage = CommandError.localized(
                    "「%@」必须是数字",
                    params: [l10n(field.zhLabel)]
                )
                return
            }
            if let min, parsed < min {
                errorMessage = CommandError.localized(
                    "「%@」不能小于 %@",
                    params: [l10n(field.zhLabel), Self.numberText(min, with: l10n)]
                )
                return
            }
            if let max, parsed > max {
                errorMessage = CommandError.localized(
                    "「%@」不能大于 %@",
                    params: [l10n(field.zhLabel), Self.numberText(max, with: l10n)]
                )
                return
            }
            save(key: field.key, value: raw, with: l10n)
        case .select:
            break
        }
    }

    /// 专用人脸嵌入模型设置键（= core FaceEmbeddingModelFactory.modelPathSetting；
    /// E-19 相邻：UI 侧保留同值常量，避免 import GatherAnalysis）。
    public static let faceEmbeddingModelSettingKey = "face_embedding_model_path"

    /// 人脸模型路径校验的结构化结果（R5-P1-1）。
    ///
    /// 旧实现返回「含运行时路径的中文长句」，再整句当 key 交给
    /// CommandError.localized —— 英文界面必然回落中文。现在只返回固定模板
    /// key + 参数（路径/扩展名），文案在渲染期按 L10n 查表；en/zh 都有条目，
    /// 英文界面不出现中文。
    enum FaceModelPathIssue: Equatable, Sendable {
        case modelNotFound(path: String)
        case unsupportedFormat(ext: String)

        /// 固定模板（中文原文即 key；en 表有对应译文）。templateKeys
        /// 同时供 parity 的 dynamicKeys 使用（扫描器看不到 case 里的常量）。
        static let modelNotFoundKey = "人脸嵌入模型不存在：%@（支持 .mlmodel、.mlpackage 或 .mlmodelc；留空使用内置 SFace 身份模型）"
        static let unsupportedFormatKey = "不支持的人脸嵌入模型扩展名：.%@（只接受 .mlmodel / .mlpackage / .mlmodelc）"
        static let templateKeys: Set<String> = [modelNotFoundKey, unsupportedFormatKey]

        var key: String {
            switch self {
            case .modelNotFound: Self.modelNotFoundKey
            case .unsupportedFormat: Self.unsupportedFormatKey
            }
        }

        var params: [String] {
            switch self {
            case .modelNotFound(let path): [path]
            case .unsupportedFormat(let ext): [ext]
            }
        }

        var commandError: CommandError {
            CommandError.localized(key, params: params)
        }
    }

    /// 人脸嵌入模型路径的廉价校验（纯 FileManager/URL，不加载、不哈希）：
    /// 返回 nil = 可保存；否则是结构化拒绝原因（固定 key + 参数，渲染期本地化）。
    /// 规则对齐 core FaceEmbeddingModelFactory.make / CoreMLFaceEmbedder：
    /// 空/纯空白 → 合法（回到内置 Vision，由调用方空值分支处理）；
    /// 展开 ~ → 解析软链 → 文件必须存在 → 扩展名必须 .mlmodel/.mlmodelc；
    /// 目录为空（core 的 stat 指纹为空）同样按"模型不存在"拒绝。
    /// 不做的事：MLModel.compileModel / MLModel(contentsOf:) / 内容指纹哈希。
    static func faceEmbeddingModelPathError(_ raw: String) -> FaceModelPathIssue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        // R5-P1-1：不再与 core 的中文 description 拼字符串对齐——UI 用自己的
        // 固定模板（%+参数），core 的 description 仍只用于分析路径的诊断。
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .modelNotFound(path: url.path)
        }
        switch url.pathExtension {
        case "mlmodel", "mlpackage", "mlmodelc":
            break
        default:
            return .unsupportedFormat(ext: url.pathExtension)
        }
        if isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.isEmpty {
                return .modelNotFound(path: url.path)
            }
        }
        return nil
    }

    public func saveSelect(_ field: SettingField, value: String, with l10n: L10n) {
        save(key: field.key, value: value, with: l10n)
    }

    // MARK: - 模型路径编辑（保存后重查模型状态）

    public func saveModelPath(key: String, with l10n: L10n) {
        let raw = (edits[key] ?? values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || key == "face_embedding_model_path" else {
            errorMessage = CommandError.localized("模型路径不能为空")
            return
        }
        if key == Self.faceEmbeddingModelSettingKey, !raw.isEmpty,
           let issue = Self.faceEmbeddingModelPathError(raw) {
            errorMessage = issue.commandError
            return
        }
        save(key: key, value: raw, with: l10n)
    }

    // MARK: - 滑杆提交

    public func commitSlider(_ slider: SliderSetting, with l10n: L10n) {
        guard let raw = sliderValues[slider.key] else { return }
        let clamped = min(slider.max, max(slider.min, raw))
        sliderValues[slider.key] = clamped
        let formatted = slider.isInteger
            ? String(Int(clamped.rounded()))
            : String(format: "%.2f", clamped)
        save(key: slider.key, value: formatted, with: l10n)
    }

    func save(key: String, value: String, with l10n: L10n) {
        // F11：文本框改为「失焦或回车」提交后，保存会被频繁触发（用户 Tab 穿过
        // 一个没改过的字段也会触发）。值没变就什么都不做：不写库、不弹提示。
        if values[key] == value, edits[key] == value { return }
        Task {
            do {
                let input = try SettingsSetInput(key: key, value: value)
                try await settingsAPI.set(input)
                self.values[key] = value
                self.edits[key] = value
                // 提示用人类可读标签（zhLabel），不是内部键：审查发现「已保存 thumbnail_size」
                // 这类提示让用户无法确认自己改的是哪一项。
                self.notice = LocalizedText("已保存 %@", params: [Self.label(for: key, with: l10n)])
                self.errorMessage = nil
                // 门限/policy 也进指纹：变更后卡片必须重取 summary，否则会显示
                // “可应用”而点下去才报 TRIAGE_STALE。
                let triageSettingKeys: Set<String> = [
                    "triage_enabled", "triage_auto_generate", "triage_policy",
                    "triage_keep_confidence_min", "triage_reject_confidence_min",
                    "triage_min_executable_confidence",
                ]
                if triageSettingKeys.contains(key) {
                    NotificationCenter.default.post(
                        name: GatherAppNotification.settingsChanged, object: nil)
                }
                if Self.needsModelStatusRefresh(for: key) {
                    self.modelStatus = try? await settingsAPI.mlStatus()
                }
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }

    private static func needsModelStatusRefresh(for key: String) -> Bool {
        key == Self.faceEmbeddingModelSettingKey
            || key == "face_compute_units"
            || key == "face_embedding_model_version"
    }
}
