// C1 状态胶囊：对齐旧版 C1StatusCapsule.tsx + workspace-view.ts deriveCapsuleView ——
// 四色调（绿/黄/红/灰）+ 状态文案 + 队列计数（pending+writing+written，旧版
// c1QueueCount 公式）+ 最近同步时间（reloadAckedAt）+ 动态 tooltip（状态详情/
// 队列/最近同步）+ 12s 轮询 + culling:sync-status 事件刷新 + 点击跳转设置页。
import SwiftUI
import GatherCore

@MainActor
@Observable
final class C1StatusCapsuleViewModel {
    private let client: NativeCommandClient
    let sessionId: String

    private(set) var syncStatus: MetadataSyncSummary?
    /// 最近一次 Capture One 已加载元数据的确认时间（session.reload_acked_at），
    /// 由路由层 culling.sync_status 响应附带回填；无数据时为 nil（旧版同步时间缺失）。
    private(set) var reloadedAt: String?
    private(set) var failedToLoad = false
    private var pollTask: Task<Void, Never>?

    init(client: NativeCommandClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let value = try client.execute("culling.sync_status", params: ["sessionId": .string(sessionId)])
            syncStatus = try value.decoded(as: MetadataSyncSummary.self)
            reloadedAt = value.objectValue?["reloadAckedAt"]?.stringValue
            failedToLoad = false
        } catch {
            failedToLoad = true
        }
    }
}

/// 自包含宿主：页面仅需传入 sessionId + router，内部按需创建 ViewModel
/// （避免每个页面各自持有 @State VM 与生命周期管理）。
/// 审计 P1 修复：① sessionId 变化时重建 VM（opacity 常驻页切换会话后
/// 不再显示旧工作区状态）；② isActive=false 时停止 12s 轮询（隐藏页空转）。
struct C1StatusCapsuleHost: View {
    let sessionId: String
    let router: CommandRouter
    let onOpenSettings: () -> Void
    var isActive: Bool = true

    @State private var viewModel: C1StatusCapsuleViewModel?

    var body: some View {
        Group {
            if let viewModel {
                C1StatusCapsule(viewModel: viewModel, onOpenSettings: onOpenSettings)
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
        .onAppear {
            guard viewModel == nil else { return }
            viewModel = C1StatusCapsuleViewModel(
                client: NativeCommandClient(router: router),
                sessionId: sessionId
            )
        }
        .onChange(of: sessionId) { _, newID in
            viewModel?.stop()
            viewModel = C1StatusCapsuleViewModel(
                client: NativeCommandClient(router: router),
                sessionId: newID
            )
            if isActive {
                viewModel?.start()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                viewModel?.start()
            } else {
                viewModel?.stop()
            }
        }
    }
}

struct C1StatusCapsule: View {
    let viewModel: C1StatusCapsuleViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 6) {
                Circle()
                    .fill(capsule.tone)
                    .frame(width: 8, height: 8)
                Text(capsule.label)
                    .font(.system(size: 11))
                    .foregroundStyle(capsule.tone)
                if queue > 0 {
                    Text("\(queue)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(capsule.tone))
                }
                if let time = syncedAtText {
                    Text(time)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.gatherSurface)
            )
            .overlay(
                Capsule().strokeBorder(Color.gatherBorder, lineWidth: 1)
            )
            .help(tooltip)
        }
        .buttonStyle(.plain)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard let id = notification.object as? String, id == viewModel.sessionId else { return }
            Task { await viewModel.refresh() }
        }
    }

    /// 对齐旧版 c1QueueCount：待 C1 确认读取的行 = pending + writing + written。
    private var queue: Int {
        guard let sync = viewModel.syncStatus else { return 0 }
        return sync.pending + sync.writing + sync.written
    }

    /// 对齐旧版 deriveCapsuleView 的四色调映射：synced/safeToCleanup → 绿；
    /// disconnected/failed/conflict → 红；syncing/c1Read/connected → 黄。
    private var capsule: (tone: Color, label: String, detail: String) {
        let l: (String, String) -> String = { GatherLocalization.l($0, $1) }
        if viewModel.failedToLoad {
            return (GatherTheme.error, l("状态未知", "Status unknown"), l("无法获取同步状态", "Could not fetch sync status"))
        }
        guard let sync = viewModel.syncStatus else {
            return (.secondary, l("检测中…", "Checking…"), l("正在检测同步状态", "Checking sync state"))
        }
        if sync.conflict > 0 {
            return (GatherTheme.error, l("存在 XMP 冲突", "XMP conflict"), l("存在 XMP 冲突，请先裁决", "XMP conflicts need resolution"))
        }
        if sync.failed > 0 {
            return (GatherTheme.error, l("有写入失败项", "Write failures"), l("有写入失败项，请先重试", "Some writes failed, retry first"))
        }
        if sync.pending + sync.writing > 0 {
            return (GatherTheme.warning, l("同步中", "Syncing"), l("同步中：Gather 正在写入 XMP…", "Syncing: writing XMP…"))
        }
        if sync.written > 0 {
            return (GatherTheme.warning, l("已写入待读取", "Written, awaiting C1"), l("Gather 已写入，等待 C1 读取", "Gather has written, waiting for C1 to read"))
        }
        if sync.synced > 0 {
            return (GatherTheme.success, l("已同步可清理", "Synced, safe to clean"), l("已同步且可安全清理备份", "Synced and backups can be cleaned"))
        }
        return (GatherTheme.success, l("已同步", "Synced"), l("元数据已同步", "Metadata synced"))
    }

    private var syncedAtText: String? {
        guard let reloadedAt = viewModel.reloadedAt else { return nil }
        return formatTime(reloadedAt)
    }

    /// 动态 tooltip：状态详情 + 写回队列 + 最近同步（对齐旧版 title 三行）。
    private var tooltip: String {
        var parts = [capsule.detail]
        if queue > 0 {
            parts.append(GatherLocalization.l("写回队列：\(queue) 项", "Writeback queue: \(queue)"))
        }
        if let time = syncedAtText {
            parts.append(GatherLocalization.l("最近同步：\(time)", "Last sync: \(time)"))
        }
        return parts.joined(separator: "\n")
    }

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return String(iso.prefix(16)) }
        let output = DateFormatter()
        output.locale = GatherLocalization.appLocale
        output.dateFormat = GatherLocalization.appLanguage == "zh-CN" ? "MM/dd HH:mm" : "MM/dd/yyyy HH:mm"
        return output.string(from: date)
    }
}
