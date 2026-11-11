// desktop/native/gather-app/Sources/GatherUI/ControlCenter/MigrationCenterCard.swift
// Wave3（task-24）：控制中心「迁移与目录包」入口。
//
// 三个动作（都经 MaintenanceAPI，UI 只做选择/确认/展示）：
//   1) 导出目录包：NSSavePanel 选文件 → LibraryExportResult（含路径，可直接在 Finder 显示）；
//   2) 导入目录包：选包 + 选新根目录 + 冲突策略 → 确认后 Confirmed 收口；
//   3) 从 XMP 迁移：确认后扫描当前工作区照片旁边的 sidecar，产出计数报告。
//
// 破坏性动作（导入写库 / 迁移写库）走 confirmationDialog，Confirmed 只从确认分支构造；
// 成功后由 VM 发 .library 域事件（发布点登记在 SessionControlViewModel.swift）。
//
// 迁移能力经环境端口注入（与 CurationServices 同一模式）；未注入时卡片显式提示未接线，
// 而不是画一个点了没反应的按钮。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 环境端口

/// 迁移能力包（environment 注入；maintenance 为 nil = 未接线）。
public struct MigrationServices: Sendable {
    public var maintenance: (any MaintenanceAPI)?

    public init(maintenance: (any MaintenanceAPI)? = nil) {
        self.maintenance = maintenance
    }

    public static let unavailable = MigrationServices()
}

private struct MigrationServicesKey: EnvironmentKey {
    static let defaultValue = MigrationServices.unavailable
}

public extension EnvironmentValues {
    var migrationServices: MigrationServices {
        get { self[MigrationServicesKey.self] }
        set { self[MigrationServicesKey.self] = newValue }
    }
}

// MARK: - 待确认的导入草稿

private struct PendingPackageImport: Identifiable {
    let id = UUID()
    let packagePath: String
    let newRoot: String
}

// MARK: - 卡片

struct MigrationCenterCard: View {
    let sessionId: String
    /// 成功后广播库变更（发布点必须是登记过的文件：SessionControlViewModel.swift）。
    let notifyLibraryChanged: () -> Void

    @Environment(\.migrationServices) private var services
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var isBusy = false
    @State private var actionError: CommandError?
    @State private var exportResult: LibraryExportResult?
    @State private var importReport: LibraryImportReport?
    @State private var migrationReport: ExternalMigrationReport?
    @State private var policy: LibraryConflictPolicy = .keepLocal
    @State private var overwriteExisting = false
    @State private var pendingImport: PendingPackageImport?
    @State private var confirmMigration = false

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("迁移与目录包"))
                .font(GatherFont.sectionTitle)
            Text(l10n("目录包不含原图：换机或合并时按新根目录重绑定相对路径；XMP 迁移只读已有 sidecar。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("导出目录包…"), systemImage: "square.and.arrow.up") {
                    chooseExportDestination()
                }
                .gatherButton(.secondary)
                .disabled(isBusy || services.maintenance == nil)
                Button(l10n("导入目录包…"), systemImage: "square.and.arrow.down") {
                    chooseImportPackage()
                }
                .gatherButton(.secondary)
                .disabled(isBusy || services.maintenance == nil)
                Button(l10n("从 XMP 迁移…"), systemImage: "arrow.triangle.2.circlepath") {
                    confirmMigration = true
                }
                .gatherButton(.tertiary)
                .disabled(isBusy || services.maintenance == nil)
            }
            if services.maintenance == nil {
                Text(l10n("迁移未接线（宿主未注入 MaintenanceAPI）"))
                    .font(GatherFont.labelRegular)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            HStack(spacing: GatherMetrics.Space.m) {
                Picker(l10n("冲突处置"), selection: $policy) {
                    Text(l10n("保留本地")).tag(LibraryConflictPolicy.keepLocal)
                    Text(l10n("保留导入")).tag(LibraryConflictPolicy.keepImported)
                    Text(l10n("并存")).tag(LibraryConflictPolicy.coexist)
                }
                .labelsHidden()
                Toggle(l10n("用 XMP 覆盖本地已有评分/色标/关键词"), isOn: $overwriteExisting)
                    .toggleStyle(.checkbox)
            }
            .font(GatherFont.secondary)
            if let actionError {
                Text(l10n.format("操作失败：%@", CommandErrorText.resolve(actionError, with: l10n)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = exportResult {
                HStack(spacing: GatherMetrics.Space.s) {
                    Text(l10n.format(
                        "已导出 %lld 张照片、%lld 个集合到：%@（归档跳过 %lld 张）",
                        report.photoCount, report.collectionCount,
                        report.packagePath, report.skippedArchivedCount))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.secondaryText)
                        .textSelection(.enabled)
                    Button(l10n("在 Finder 中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: report.packagePath)])
                    }
                    .gatherButton(.tertiary, size: .small)
                }
            }
            if let report = importReport {
                Text(l10n.format(
                    "导入完成：新增 %lld 张（待索引 %lld 张），评分 %lld，关键词 %lld，集合 %lld；photoId 去重 %lld，checksum 去重 %lld；保留本地 %lld，保留导入 %lld，并存 %lld。",
                    report.importedPhotos, report.pendingCount,
                    report.importedRatings, report.importedKeywords, report.importedCollections,
                    report.dedupedByPhotoID, report.dedupedByChecksum,
                    report.conflictsKeptLocal, report.conflictsKeptImported, report.coexisted))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = migrationReport {
                Text(l10n.format(
                    "XMP 迁移完成：扫描 %lld 张，发现 sidecar %lld，写入 %lld 张；冲突 %lld 条（按字段计），缺 rating/label/keywords %lld/%lld/%lld，失败 %lld。",
                    report.scanned, report.sidecarsFound, report.applied,
                    report.conflicts, report.missingRating, report.missingLabel,
                    report.missingKeywords, report.failed.count))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .gatherCard()
        .confirmationDialog(
            l10n("确认导入目录包？"),
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }),
            titleVisibility: .visible
        ) {
            Button(l10n("开始导入"), role: .destructive) {
                if let draft = pendingImport {
                    pendingImport = nil
                    Task { await importPackage(draft) }
                }
            }
            Button(l10n("取消"), role: .cancel) { pendingImport = nil }
        } message: {
            Text(l10n("导入会新建一个工作区并写入评分/关键词/集合，不会修改原图。"))
        }
        .confirmationDialog(
            l10n("确认从 XMP 迁移？"),
            isPresented: $confirmMigration,
            titleVisibility: .visible
        ) {
            Button(l10n("开始迁移")) {
                Task { await migrateFromXMP() }
            }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(l10n("XMP 迁移会写入评分/色标/关键词；默认只补空字段。"))
        }
    }

    // MARK: - 导出

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "library.gatherlib.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await exportPackage(to: url) }
        }
    }

    private func exportPackage(to url: URL) async {
        guard let maintenance = services.maintenance else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            exportResult = try await maintenance.exportLibraryPackage(
                LibraryExportInput(sessionId: sessionId, destinationPath: url.path))
        } catch {
            actionError = CommandError(error)
        }
    }

    // MARK: - 导入

    private func chooseImportPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in chooseImportRoot(packagePath: url.path) }
        }
    }

    private func chooseImportRoot(packagePath: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = l10n("选择新根目录（迁移后的照片目录）")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                pendingImport = PendingPackageImport(
                    packagePath: packagePath, newRoot: url.path)
            }
        }
    }

    private func importPackage(_ draft: PendingPackageImport) async {
        guard let maintenance = services.maintenance else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            let input = LibraryImportInput(
                packagePath: draft.packagePath,
                newRoot: draft.newRoot,
                conflictPolicy: policy
            )
            let report = try await maintenance.importLibraryPackage(
                Confirmed(input, source: .userDialog))
            importReport = report
            // 导入整包会新增照片/集合：本函数体内直接发 library 域事件（门禁要求）。
            GatherEventCenter.postDomainChange(.library, sessionId: sessionId)
            notifyLibraryChanged()
        } catch {
            actionError = CommandError(error)
        }
    }

    // MARK: - XMP 迁移

    private func migrateFromXMP() async {
        guard let maintenance = services.maintenance else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            let input = ExternalMigrationInput(
                sessionId: sessionId, overwriteExisting: overwriteExisting)
            migrationReport = try await maintenance.migrateExternalMetadata(
                Confirmed(input, source: .userDialog))
            // XMP 迁移改的是照片元数据：直接发 metadata 域事件，让已挂载页刷新
            // （notifyLibraryChanged 发的是 library 通道；域写门禁要求本函数体内可见）。
            GatherEventCenter.postDomainChange(.metadata, sessionId: sessionId)
            notifyLibraryChanged()
        } catch {
            actionError = CommandError(error)
        }
    }
}
