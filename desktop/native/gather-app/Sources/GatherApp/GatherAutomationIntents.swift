// desktop/native/gather-app/Sources/GatherApp/GatherAutomationIntents.swift
// Wave3 / task-21：Shortcuts / App Intents 动作面（4 个动作）+ Wave5 batch5 的 2 个
// 「脚本能用 Gather」动作（查询照片 / 写评级·色标·保留），全部复用既有 typed API。
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

// MARK: - Wave5 batch5：查询照片（只读）

/// 按工作区查询照片：返回匹配总数、ID 列表与前几个文件名。
///
/// 参数校验不在这里重复实现：GatherAutomationPhotoQuery（GatherHost）是 URL scheme 与
/// Shortcuts 共用的唯一归一化入口（sessionId/关键词/星级/limit 的合法值集合只有一份）。
struct QueryPhotosIntent: AppIntent {
    static var title: LocalizedStringResource { "查询照片" }
    static var description: IntentDescription? {
        "只读查询工作区里的照片：可按关键词与最低星级过滤，返回数量、照片 ID 与前几个文件名。"
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "工作区 ID")
    var sessionId: String

    @Parameter(title: "关键词", description: "留空 = 不按关键词过滤")
    var keyword: String?

    @Parameter(title: "最低星级", description: "0…5；留空 = 不按星级过滤")
    var minRating: String?

    @Parameter(title: "上限", description: "最多返回多少张（1…500，留空 = 100）")
    var limit: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runtime = GatherAutomationRuntimeRegistry.current else {
            throw GatherAutomationError.runtimeUnavailable
        }
        let query = try GatherAutomationPhotoQuery.parse(
            sessionId: sessionId,
            keyword: keyword ?? "",
            minRating: minRating ?? "",
            limit: limit ?? "")
        let result = try await runtime.queryPhotos(query)
        let samples = result.samples
            .map { "\($0.photoId)（\($0.filename)）" }
            .joined(separator: "、")
        let suffix = samples.isEmpty ? "" : "；示例：\(samples)"
        return .result(dialog: IntentDialog(stringLiteral:
            "匹配 \(result.total) 张，返回 \(result.photoIds.count) 张\(suffix)。"))
    }
}

// MARK: - Wave5 batch5：写评级/色标/保留

/// 按照片 ID 批量写判断（rating / 色标 / keep·reject）。
///
/// 非破坏性：只写挑片判断（与挑片页的星级/色标/保留同一套 CullingAPI），
/// 不删除、不移动、不改文件名。参数校验同样复用 GatherAutomationDecisionPatch.parse。
struct RatePhotosIntent: AppIntent {
    static var title: LocalizedStringResource { "设置照片评级/标记" }
    static var description: IntentDescription? {
        "按照片 ID 批量设置星级、色标与保留/淘汰；留空的字段不改。"
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "工作区 ID")
    var sessionId: String

    @Parameter(title: "照片 ID", description: "多个用换行分隔")
    var photoIds: String

    @Parameter(title: "星级", description: "0…5；留空 = 不改")
    var rating: String?

    @Parameter(title: "色标", description: "none/red/orange/yellow/green/blue/pink/purple；留空 = 不改")
    var label: String?

    @Parameter(title: "保留/淘汰", description: "keep 或 reject；留空 = 不改")
    var pick: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let runtime = GatherAutomationRuntimeRegistry.current else {
            throw GatherAutomationError.runtimeUnavailable
        }
        let ids = photoIds
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw GatherAutomationError.noPhotoIds }
        let patch = try GatherAutomationDecisionPatch.parse(
            rating: rating ?? "", label: label ?? "", pick: pick ?? "")
        let summary = try await runtime.applyDecisions(sessionId, ids, patch)
        return .result(dialog: IntentDialog(stringLiteral:
            "已更新 \(summary.written) 张照片的判断（跳过 \(summary.skipped) 张）。"))
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
        // Wave5 batch5：自动化第二层（查询 + 写判断），保持上面 4 个旧动作不变。
        AppShortcut(
            intent: QueryPhotosIntent(),
            phrases: ["用 \(.applicationName) 查询照片"],
            shortTitle: "查询照片",
            systemImageName: "magnifyingglass")
        AppShortcut(
            intent: RatePhotosIntent(),
            phrases: ["用 \(.applicationName) 设置照片评级"],
            shortTitle: "设置评级",
            systemImageName: "star")
    }
}
