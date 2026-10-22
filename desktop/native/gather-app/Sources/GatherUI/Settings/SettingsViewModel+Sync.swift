// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+Sync.swift
// Cut 4 / 4c-2d：Capture One 写回队列（culling.sync_status + 12s 轮询）与最近同步时间
//（原 SettingsView.swift 617-653、663-700 行；lastSyncDate 存储属性留在
// SettingsViewModel.swift 的类体内）。纯搬移，代次守卫与失败语义不变。
import Foundation
import GatherProtocol

extension SettingsViewModel {

    // MARK: - 写回队列（culling.sync_status + 12s 轮询）

    /// 对齐 C1HealthPanel.refreshSync：经 SessionAPI.list 取最近会话，再读
    /// CullingAPI.syncStatus；无会话时置空（UI 显示「无工作区」）。
    ///
    /// B8.2a：SessionAPI/CullingAPI 只有 async 形态，12s 轮询与写路径事件可能
    /// 重叠触发 → 用代次守卫只接受最新一轮（旧响应不得回填旧状态/旧错误标志）。
    /// 失败语义不变：list 或 syncStatus 失败只置 syncStateError，保留已显示的值。
    public func refreshSyncState() async {
        syncStateGeneration += 1
        let generation = syncStateGeneration
        do {
            let sessions = try await sessionAPI.list()
            guard generation == syncStateGeneration else { return }
            guard let session = Self.mostRecentSession(sessions) else {
                syncSessionId = nil
                syncStatus = nil
                syncReloadAckedAt = nil
                syncStateError = false
                recomputeLastSyncDate()
                return
            }
            // 与旧同步实现同序：先记目标会话，再读同步摘要。
            syncSessionId = session.id
            let status = try await cullingAPI.syncStatus(session.id)
            guard generation == syncStateGeneration else { return }
            syncStatus = status.summary
            // 旧版 C1HealthPanel 以 c1:sync-state 的 reloadAckedAt 为准；类型化
            // 响应的 reloadAckedAt 缺失时回退 items.updatedAt。
            syncReloadAckedAt = status.reloadAckedAt
            syncStateError = false
            recomputeLastSyncDate()
        } catch {
            guard generation == syncStateGeneration else { return }
            syncStateError = true
        }
    }
    /// refreshSyncState 成功后调用（含 12s 轮询与终态事件两条路径）。
    func recomputeLastSyncDate() {
        if let ack = syncReloadAckedAt, !ack.isEmpty, let date = parseISO8601Date(ack) {
            lastSyncDate = date
            return
        }
        guard let syncStatus else {
            lastSyncDate = nil
            return
        }
        var newest: Date?
        for item in syncStatus.items {
            guard let date = parseISO8601Date(item.updatedAt) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        lastSyncDate = newest
    }

    private static func mostRecentSession(_ sessions: [SessionData]) -> SessionData? {
        sessions.max { a, b in
            (parseISO8601Date(a.updatedAt) ?? .distantPast) < (parseISO8601Date(b.updatedAt) ?? .distantPast)
        }
    }

    /// 本地化时间文案（Cut 4 / 4b-2g）：语言来自**设置里的界面语言**，不是系统语言。
    ///
    /// 旧实现按 `Locale.preferredLanguages` 选 zh 分支，于是「系统中文 + 界面英文」
    /// 仍显示中文日期（真实 i18n bug）。现在与 Dashboard 同一口径：
    /// `DisplayDateFormatters.mediumShort(date, locale: l10n.locale)`，日期/时间
    /// 样式交给设置语言对应的 Locale。
    ///
    /// 行为变更（已确认）：zh 输出不变（`2026年10月22日 09:17`）；en 由
    /// `Oct 22, 2026, 09:17`（yMd HH:mm 模板）改为 en_US medium+short
    /// （`Oct 22, 2026 at 9:17 AM`，12 小时制、无前导零）。
    public static func dateText(_ date: Date, with l10n: L10n) -> String {
        // C-1（性能审计）：仍是共享缓存实例，不新建 DateFormatter。
        DisplayDateFormatters.shared.mediumShort(date, locale: l10n.locale)
    }
}
