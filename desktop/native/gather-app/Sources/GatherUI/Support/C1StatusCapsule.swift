// C1 状态胶囊：对齐旧版 C1StatusCapsule.tsx + workspace-view.ts deriveCapsuleView ——
// 四色调（绿/黄/红/灰）+ 状态文案 + 队列计数（pending+writing+written，旧版
// c1QueueCount 公式）+ 最近同步时间（reloadAckedAt）+ 动态 tooltip（状态详情/
// 队列/最近同步）+ 12s 轮询 + culling:sync-status 事件刷新 + 点击跳转设置页。
import SwiftUI
import AppKit
import GatherProtocol

@MainActor
@Observable
final class C1StatusService {
    static let shared = C1StatusService()

    struct SessionState {
        var syncStatus: MetadataSyncSummary?
        /// 最近一次 Capture One 已加载元数据的确认时间（session.reload_acked_at），
        /// 由 CullingAPI.syncStatus 的 CullingSyncStatus 回填；无数据时为 nil（旧版同步时间缺失）。
        var reloadedAt: String?
        var failedToLoad = false
    }

    private(set) var statuses: [String: SessionState] = [:]
    /// 订阅引用计数（第二轮验证）：外壳按目的地**条件构建**页面，同一会话可能同时
    /// 有多个宿主（多窗口/转场重叠）。用计数而不是 Set —— 否则先消失的那个宿主会
    /// 把仍在显示的宿主的订阅一起退掉（胶囊停更）。
    private var activeSessions: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var culling: (any CullingAPI)?
    /// 每个会话的刷新代号：syncStatus 已是 async，轮询/事件/手动刷新可能重叠，
    /// 只允许最新一次请求落地（旧实现同步执行天然串行）。
    private var refreshGenerations: [String: Int] = [:]
    private var eventObserver: NSObjectProtocol?
    private var domainObserver: NSObjectProtocol?

    /// 生产只使用 `shared`；测试可建隔离实例，避免单例状态在并行套件间串扰。
    init() {
        eventObserver = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.c1SyncStatus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let sessionId = notification.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activeSessions[sessionId] != nil else { return }
                await self.refresh(sessionId: sessionId)
            }
        }
        // 写路径广播（XMP/同步队列）：订阅中的会话立即重拉，胶囊不再等 12s 轮询。
        domainObserver = NotificationCenter.default.addObserver(
            forName: GatherEventCenter.domainChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = notification.object as? GatherDomainChange,
                  change.domain == .metadata else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.activeSessions.isEmpty else { return }
                if let sessionId = change.sessionId {
                    guard self.activeSessions[sessionId] != nil else { return }
                    await self.refresh(sessionId: sessionId)
                } else {
                    await self.refreshActive()
                }
            }
        }
    }

    /// 注入挑片域 API（组合根传入 `appServices.culling`）。
    ///
    /// 幂等：多个页面宿主共享同一单例，首个宿主注入后后续调用忽略；
    /// 避免页面切换时重复装配，也避免把不同实例混进同一个订阅者。
    func setCullingAPI(_ culling: any CullingAPI) {
        guard self.culling == nil else { return }
        self.culling = culling
    }

    func subscribe(sessionId: String) {
        let count = (activeSessions[sessionId] ?? 0) + 1
        activeSessions[sessionId] = count
        guard count == 1 else { return }
        Task { await refresh(sessionId: sessionId) }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshActive()
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    func unsubscribe(sessionId: String) {
        guard let count = activeSessions[sessionId] else { return }
        if count > 1 {
            activeSessions[sessionId] = count - 1
            return
        }
        activeSessions[sessionId] = nil
        // 归零时一并回收该会话的状态（旧实现 statuses 只增不减），
        // 并作废在途刷新，避免退订后又被迟到的响应写回。
        statuses[sessionId] = nil
        refreshGenerations[sessionId] = nil
        if activeSessions.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refresh(sessionId: String) async {
        guard let culling else { return }
        let generation = (refreshGenerations[sessionId] ?? 0) + 1
        refreshGenerations[sessionId] = generation
        do {
            let status = try await culling.syncStatus(sessionId)
            guard refreshGenerations[sessionId] == generation else { return }
            statuses[sessionId] = SessionState(
                syncStatus: status.summary,
                reloadedAt: status.reloadAckedAt,
                failedToLoad: false
            )
        } catch {
            guard refreshGenerations[sessionId] == generation else { return }
            // 错误静默降级（与旧路径一致）：保留上次摘要，只标记状态未知。
            statuses[sessionId, default: SessionState()].failedToLoad = true
        }
    }

    private func refreshActive() async {
        for sessionId in activeSessions.keys {
            await refresh(sessionId: sessionId)
        }
    }
}

/// 自包含宿主：页面仅需传入 sessionId + CullingAPI，内部订阅共享 C1StatusService
/// （避免每个页面各自轮询；性能审计修复：多页常驻时全局仅一条 12s 轮询任务）。
/// 审计行为保持：① sessionId 变化时切换订阅会话（opacity 常驻页切换会话后
/// 不再显示旧工作区状态）；② isActive=false 时取消订阅（隐藏页不轮询）。
struct C1StatusCapsuleHost: View {
    let sessionId: String
    /// 挑片域 API：`culling.sync_status` 的类型化入口。
    let culling: any CullingAPI
    let onOpenSettings: () -> Void
    var isActive: Bool = true
    /// 默认共享单例；测试可注入隔离实例。
    let service: C1StatusService

    init(
        sessionId: String,
        culling: any CullingAPI,
        onOpenSettings: @escaping () -> Void,
        isActive: Bool = true,
        service: C1StatusService = .shared
    ) {
        self.sessionId = sessionId
        self.culling = culling
        self.onOpenSettings = onOpenSettings
        self.isActive = isActive
        self.service = service
    }

    var body: some View {
        C1StatusCapsule(sessionId: sessionId, onOpenSettings: onOpenSettings, service: service)
            .onAppear {
                service.setCullingAPI(culling)
                if isActive {
                    service.subscribe(sessionId: sessionId)
                }
            }
            .onChange(of: sessionId) { oldID, newID in
                if isActive {
                    service.unsubscribe(sessionId: oldID)
                    service.subscribe(sessionId: newID)
                }
            }
            // D-10（性能审计）：外壳按目的地**条件构建**页面，销毁不会把 isActive
            // 变成 false ⇒ 旧实现让访问过的每个会话永久留在 12s 轮询里。
            .onDisappear {
                service.unsubscribe(sessionId: sessionId)
            }
            .onChange(of: isActive) { _, active in
                if active {
                    service.subscribe(sessionId: sessionId)
                } else {
                    service.unsubscribe(sessionId: sessionId)
                }
            }
    }
}

struct C1StatusCapsule: View {
    let sessionId: String
    let onOpenSettings: () -> Void
    let service: C1StatusService

    /// Cut 4 / 4b-1：时间 locale / 日期格式跟随当前界面语言（渲染期解析，
    /// 不再读进程级 GatherLocalization.appLocale/appLanguage）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    init(
        sessionId: String,
        onOpenSettings: @escaping () -> Void,
        service: C1StatusService = .shared
    ) {
        self.sessionId = sessionId
        self.onOpenSettings = onOpenSettings
        self.service = service
    }

    var body: some View {
        // Cut 4 / 4b-2l：模型（色调/文案/tooltip）在渲染期按当前语言解析一次。
        let visual = capsule(with: l10n)
        // 原生状态指示：语义色只出现在状态点上，文字保持系统前景色
        // （彩色文字在浅色/深色下都会跌破对比度）。胶囊自身的底色与描边
        // 已删除——它现在住在工具栏里，chrome 由系统提供。
        Button(action: onOpenSettings) {
            HStack(spacing: 6) {
                Circle()
                    .fill(visual.tone)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(visual.label)
                    .font(.callout)
                if queue > 0 {
                    Text(queue, format: .number)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let time = syncedAtText {
                    Text("·")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Text(time)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
            .help(tooltip(with: l10n))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(visual.label)
        .accessibilityValue(queue > 0 ? "\(queue)" : "")
    }

    var state: C1StatusService.SessionState? {
        service.statuses[sessionId]
    }

    /// 对齐旧版 c1QueueCount：待 C1 确认读取的行 = pending + writing + written。
    var queue: Int {
        guard let sync = state?.syncStatus else { return 0 }
        return sync.pending + sync.writing + sync.written
    }

    /// 对齐旧版 deriveCapsuleView 的四色调映射：synced/safeToCleanup → 绿；
    /// disconnected/failed/conflict → 红；syncing/c1Read/connected → 黄。
    /// textColor 为状态文字前景色：warning 态浅色下 #D4944F 对比不足，
    /// 用深棕变体（深色模式自动亮化）；error/success 直接用语义色。
    ///
    /// Cut 4 / 4b-2l：这是模型计算属性（测试直接调用），语言由调用方显式传入；
    /// 状态词与详情句全部在渲染期解析，不再读进程级 appLanguage。
    func capsule(with l10n: L10n) -> (tone: Color, textColor: Color, label: String, detail: String) {
        let warningText = Self.dynamicText(light: "#8A5A1F", dark: "#E5B27B")
        if state?.failedToLoad == true {
            return (GatherTheme.error, GatherTheme.error, l10n("状态未知"), l10n("无法获取同步状态"))
        }
        guard let sync = state?.syncStatus else {
            return (.secondary, .secondary, l10n("检测中…"), l10n("正在检测同步状态"))
        }
        if sync.conflict > 0 {
            return (GatherTheme.error, GatherTheme.error, l10n("存在 XMP 冲突"), l10n("存在 XMP 冲突，请先裁决"))
        }
        if sync.failed > 0 {
            return (GatherTheme.error, GatherTheme.error, l10n("有写入失败项"), l10n("有写入失败项，请先重试"))
        }
        if sync.pending + sync.writing > 0 {
            return (GatherTheme.warning, warningText, l10n("同步中"), l10n("同步中：Gather 正在写入 XMP…"))
        }
        if sync.written > 0 {
            return (GatherTheme.warning, warningText, l10n("已写入待读取"), l10n("Gather 已写入，等待 C1 读取"))
        }
        if sync.synced > 0 {
            return (GatherTheme.success, GatherTheme.success, l10n("已同步可清理"), l10n("已同步且可安全清理备份"))
        }
        return (GatherTheme.success, GatherTheme.success, l10n("已同步"), l10n("元数据已同步"))
    }

    var syncedAtText: String? {
        guard let reloadedAt = state?.reloadedAt else { return nil }
        return formatTime(reloadedAt)
    }

    /// 动态 tooltip：状态详情 + 写回队列 + 最近同步（对齐旧版 title 三行）。
    /// 4b-2l：模型计算属性传 L10n；带参模板走 l10n.format（%d/%@ 按实参类型配对）。
    func tooltip(with l10n: L10n) -> String {
        var parts = [capsule(with: l10n).detail]
        if state?.failedToLoad == true {
            parts.append(l10n("状态未知：自动重试中，也可前往设置检查 Capture One 连接"))
        }
        if queue > 0 {
            parts.append(l10n.plural("写回队列：%d 项", count: queue))
        }
        if let time = syncedAtText {
            parts.append(l10n.format("最近同步：%@", time))
        }
        return parts.joined(separator: "\n")
    }

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return String(iso.prefix(16)) }
        let output = DateFormatter()
        output.locale = l10n.locale
        output.dateFormat = l10n.language == .zhCN ? "MM/dd HH:mm" : "MM/dd/yyyy HH:mm"
        return output.string(from: date)
    }
    private static func dynamicText(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hexString: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString).scanHexInt64(&value)
        self.init(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
