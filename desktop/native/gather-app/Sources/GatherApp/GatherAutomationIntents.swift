// desktop/native/gather-app/Sources/GatherApp/GatherAutomationIntents.swift
// Wave3 / task-21：Shortcuts / App Intents 动作面（4 个动作，全部复用既有 typed API）。
//
// 设计边界：
// - 本文件只声明 AppIntent + 参数 + dialog，不碰业务规则；所有能力经
//   GatherAutomationRuntimeRegistry.current（GatherHost 安装）转调 SessionAPI /
//   ExportAPI / CullingAPI；
// - 参数一律用 String（路径/ID/枚举名），Shortcuts 侧不引入文件/数值桥接，
//   避免两套值类型转换；多路径用换行分隔（见 createWorkspaceAndImport 文档）；
// - 应用未完成启动时 runtime 为 nil：显式抛 GatherAutomationError.runtimeUnavailable，
//   Shortcuts 会把 errorDescription 展示给用户，而不是静默失败；
// - 不引入脚本解释器，也不接受 shell 命令（导出后钩子另有设置项，不在 intents 面）。
import AppIntents
import Foundation
import GatherHost

// MARK: - 新建工作区并导入

struct CreateWorkspaceAndImportIntent: AppIntent {
    static var title: LocalizedStringResource { "新建工作区并导入" }
    static var description: IntentDescription? {
        "把给定的照片/文件夹路径建为 Gather 工作区并开始索引（多个路径用换行分隔）。"
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "路径", description: "绝对路径；多个用换行分隔（文件或目录均可）")
    var paths: String

    @Parameter(title: "工作区名称", description: "留空 = 自动命名")
    var name: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runtime = GatherAutomationRuntimeRegistry.current else {
            throw GatherAutomationError.runtimeUnavailable
        }
        let filepaths = paths
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !filepaths.isEmpty else { throw GatherAutomationError.noFiles }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = try await runtime.createWorkspaceAndImport(
            trimmedName.isEmpty ? nil : trimmedName, filepaths)
        return .result(dialog: IntentDialog(stringLiteral:
            "已创建工作区（\(sessionId)），共 \(filepaths.count) 个路径。"))
    }
}

// MARK: - 按工作区导出

struct ExportWorkspaceIntent: AppIntent {
    static var title: LocalizedStringResource { "按工作区导出" }
    static var description: IntentDescription? {
        "按工作区把整批照片导出到指定目录（format: jpeg / tiff / original）。"
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "工作区 ID")
    var sessionId: String

    @Parameter(title: "输出目录", description: "绝对路径（目录必须已存在或可由导出创建）")
    var destination: String

    @Parameter(title: "格式", description: "jpeg、tiff 或 original")
    var format: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runtime = GatherAutomationRuntimeRegistry.current else {
            throw GatherAutomationError.runtimeUnavailable
        }
        let result = try await runtime.exportSession(
            sessionId, destination, format.lowercased(), nil, nil)
        return .result(dialog: IntentDialog(stringLiteral:
            "导出完成：成功 \(result.exported) 张，失败 \(result.failed) 张，跳过 \(result.skipped) 张。"))
    }
}

// MARK: - 按工作区写回元数据

struct WritebackWorkspaceMetadataIntent: AppIntent {
    static var title: LocalizedStringResource { "按工作区写回元数据" }
    static var description: IntentDescription? {
        "把工作区的挑片结果写回 XMP（target: rating / color_label / keyword）。"
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "工作区 ID")
    var sessionId: String

    @Parameter(title: "目标", description: "rating、color_label 或 keyword")
    var target: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runtime = GatherAutomationRuntimeRegistry.current else {
            throw GatherAutomationError.runtimeUnavailable
        }
        let result = try await runtime.writebackMetadata(sessionId, target.lowercased())
        return .result(dialog: IntentDialog(stringLiteral:
            "写回完成：成功 \(result.written) 项，失败 \(result.failed) 项，跳过 \(result.skipped) 项。"))
    }
}

// MARK: - 查询工作区状态

struct WorkspaceStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "查询工作区状态" }
    static var description: IntentDescription? {
        "只读查询工作区的照片数与 XMP 写回队列（pending/written/failed/conflict）。"
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "工作区 ID")
    var sessionId: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runtime = GatherAutomationRuntimeRegistry.current else {
            throw GatherAutomationError.runtimeUnavailable
        }
        let status = try await runtime.sessionStatus(sessionId)
        let reload = status.reloadAckedAt == nil ? "未确认重载" : "已确认重载"
        return .result(dialog: IntentDialog(stringLiteral:
            "\(status.name)：\(status.photoCount) 张照片；待写 \(status.pendingXmp)，已写 \(status.writtenXmp)，失败 \(status.failedXmp)，冲突 \(status.conflictXmp)；\(reload)。"))
    }
}

// MARK: - Shortcuts 短语

struct GatherAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateWorkspaceAndImportIntent(),
            phrases: ["用 \(.applicationName) 新建工作区"],
            shortTitle: "新建工作区",
            systemImageName: "folder.badge.plus")
        AppShortcut(
            intent: ExportWorkspaceIntent(),
            phrases: ["用 \(.applicationName) 导出工作区"],
            shortTitle: "导出工作区",
            systemImageName: "square.and.arrow.up")
        AppShortcut(
            intent: WritebackWorkspaceMetadataIntent(),
            phrases: ["用 \(.applicationName) 写回元数据"],
            shortTitle: "写回元数据",
            systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(
            intent: WorkspaceStatusIntent(),
            phrases: ["用 \(.applicationName) 查询工作区状态"],
            shortTitle: "工作区状态",
            systemImageName: "info.circle")
    }
}
