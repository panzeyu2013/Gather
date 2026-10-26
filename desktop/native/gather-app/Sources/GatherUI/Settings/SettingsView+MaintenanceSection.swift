// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView+MaintenanceSection.swift
// P0 / B0：设置页“数据与恢复”分区（备份/恢复/诊断）。
//
// 只经 MaintenanceAPI 触发；恢复是跨进程操作：确认 -> 写 journal -> 提示退出，
// 下次启动在 Database.open 前 swap，旧库保留为 pre-restore。
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GatherProtocol

extension SettingsView {
    @ViewBuilder
    var maintenanceSection: some View {
        if viewModel.maintenanceAvailable {
            MaintenanceSettingsSection(viewModel: viewModel, l10n: l10n)
        }
    }
}

private struct MaintenanceSettingsSection: View {
    let viewModel: SettingsViewModel
    let l10n: L10n

    @State private var pendingRestore: BackupRecord?
    @State private var showRestartAlert = false

    private var backups: [BackupRecord] { viewModel.maintenanceBackups }
    private var busy: Bool { viewModel.maintenanceBusy }

    var body: some View {
        Group {
            if let last = viewModel.maintenanceInventory?.lastRestore {
                Section(l10n("上次恢复结果")) {
                    if last.result == .applied {
                        Text(l10n("恢复已完成"))
                            .gatherText(.secondary)
                    } else {
                        Text(l10n.format(
                            "恢复结果：%@",
                            last.message.flatMap { $0.isEmpty ? nil : $0 }
                                ?? last.errorCode.map { code in
                                    let text = l10n.errorText(code)
                                    return text.contains("%@") ? l10n("恢复失败") : text
                                }
                                ?? last.result.rawValue))
                            .gatherText(.secondary)
                    }
                }
            }
            if let receipt = viewModel.restoreReceipt {
                Section(l10n("待完成恢复")) {
                    Text(l10n.format(
                        "恢复已准备：%@", receipt.backupFileName))
                        .gatherText(.body)
                    Text(l10n("退出并重新打开 Gather 以完成恢复。旧库会保留为 pre-restore 副本。"))
                        .gatherText(.secondary)
                    HStack(spacing: GatherMetrics.Space.m) {
                        Button(l10n("退出 Gather")) { NSApp.terminate(nil) }
                        Button(l10n("取消待恢复")) {
                            Task { await viewModel.cancelPendingRestore() }
                        }
                        .disabled(busy)
                    }
                }
            }

            Section(l10n("数据与恢复")) {
                LabeledContent(l10n("备份目录")) {
                    HStack(spacing: GatherMetrics.Space.s) {
                        Text(directoryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button(l10n("更改备份目录…")) { chooseBackupDirectory() }
                            .disabled(busy)
                        Button(l10n("打开备份目录")) { openBackupDirectory() }
                            .disabled(viewModel.maintenanceBackupDirectory.isEmpty)
                    }
                }

                LabeledContent(l10n("上次备份")) {
                    Text(lastBackupText)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: GatherMetrics.Space.m) {
                    Button(l10n("立即备份")) {
                        Task { await viewModel.backupNow() }
                    }
                    .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }

                Picker(l10n("自动备份"), selection: Binding(
                    get: { viewModel.backupAutoMode },
                    set: { mode in Task { await viewModel.saveBackupAuto(mode) } }
                )) {
                    Text(l10n("关闭自动备份")).tag("off")
                    Text(l10n("每次启动")).tag("launch")
                    Text(l10n("每日")).tag("daily")
                }
                .disabled(busy)

                Text(l10n("自动备份在下次启动时按设置生效。"))
                    .gatherText(.secondary)

                Picker(l10n("保留份数"), selection: Binding(
                    get: { viewModel.backupRetention },
                    set: { count in Task { await viewModel.saveBackupRetention(count) } }
                )) {
                    ForEach(1...20, id: \.self) { count in
                        Text(l10n.format("%lld 份", count)).tag(count)
                    }
                }
                .disabled(busy)

                if viewModel.maintenanceInventory?.autoPaused == true {
                    Label(l10n("自动备份已暂停（连续失败）。手动备份仍可用。"), systemImage: "pause.circle")
                        .gatherText(.secondary, color: GatherTheme.warning)
                }
                if let error = viewModel.maintenanceError {
                    Label(l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                          systemImage: "exclamationmark.triangle.fill")
                        .gatherText(.secondary, color: GatherTheme.error)
                }
                if let notice = viewModel.maintenanceNotice {
                    Label(l10n.resolve(notice), systemImage: "checkmark.circle.fill")
                        .gatherText(.secondary, color: GatherTheme.success)
                }
            }

            Section(l10n("备份列表")) {
                if backups.isEmpty {
                    Text(l10n("暂无备份"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backups) { record in
                        HStack(spacing: GatherMetrics.Space.m) {
                            Image(systemName: record.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(record.verified ? GatherTheme.success : GatherTheme.warning)
                                .accessibilityLabel(record.verified ? l10n("已校验") : l10n("未校验"))
                            VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                                Text(record.fileName)
                                    .gatherText(.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(detailText(record))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(l10n("恢复")) { pendingRestore = record }
                                .disabled(busy)
                        }
                    }
                }
                Text(l10n("恢复只在下次启动时执行；当前数据库会保留为 pre-restore 副本。"))
                    .gatherText(.secondary)
            }

            Section(l10n("诊断")) {
                Toggle(l10n("诊断包含文件路径"), isOn: Binding(
                    get: { viewModel.diagnosticsIncludePaths },
                    set: { include in Task { await viewModel.saveDiagnosticsIncludePaths(include) } }
                ))
                .disabled(busy)

                Button(l10n("导出诊断包…")) { exportDiagnostics() }
                    .disabled(busy)

                if let result = viewModel.lastDiagnostics {
                    Text(l10n.format("诊断包已导出：%@", result.path))
                        .gatherText(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text(l10n("诊断包包含日志与库统计，默认不含绝对路径；上限 20 MB。"))
                    .gatherText(.secondary)
            }
        }
        .confirmationDialog(
            l10n("从备份恢复？"),
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { record in
            Button(l10n("恢复并退出"), role: .destructive) {
                pendingRestore = nil
                Task {
                    if await viewModel.restoreBackup(record) {
                        showRestartAlert = true
                    }
                }
            }
            Button(l10n("取消"), role: .cancel) { pendingRestore = nil }
        } message: { record in
            Text(l10n.format(
                "将用「%@」覆盖当前数据库。退出 Gather 后重新打开完成恢复；旧库会保留为 pre-restore 副本。",
                record.fileName
            ))
        }
        .alert(l10n("恢复已准备"), isPresented: $showRestartAlert) {
            Button(l10n("退出 Gather")) { NSApp.terminate(nil) }
            Button(l10n("稍后再说"), role: .cancel) {}
        } message: {
            Text(l10n("退出并重新打开 Gather 以完成恢复。旧库会保留为 pre-restore 副本。"))
        }
    }

    // MARK: - 文案/格式化

    private var directoryText: String {
        let path = viewModel.maintenanceBackupDirectory
        return path.isEmpty ? l10n("默认（应用支持目录/Backups）") : path
    }

    private var lastBackupText: String {
        guard let record = viewModel.maintenanceLastBackup else { return l10n("暂无备份") }
        return "\(dateText(record.createdAt)) · \(sizeText(record.sizeBytes))"
    }

    private func detailText(_ record: BackupRecord) -> String {
        let trigger: String
        switch record.trigger {
        case .manual: trigger = l10n("手动")
        case .autoLaunch: trigger = l10n("启动自动")
        case .autoDaily: trigger = l10n("每日自动")
        case .unknown: trigger = l10n("未知")
        }
        return "\(dateText(record.createdAt)) · \(sizeText(record.sizeBytes)) · v\(record.schemaVersion) · \(trigger)"
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func dateText(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: iso)
        }()
        if let date {
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        }
        return iso
    }

    // MARK: - 面板

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = l10n("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.saveBackupDirectory(url.path) }
    }

    private func openBackupDirectory() {
        let path = viewModel.maintenanceBackupDirectory
        guard !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Gather-Diagnostics-\(Self.stamp()).zip"
        panel.prompt = l10n("导出")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportDiagnostics(to: url) }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
