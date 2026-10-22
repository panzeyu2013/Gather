// desktop/native/gather-app/Sources/GatherUI/Duplicates/DuplicatesViewModel.swift
// Cut 4 / 4c-2g：从 DuplicatesView.swift 第 126-442 行整段移出（页面视图模型）。
// 纯搬移：状态默认值、动作、取消判定、本地 patch、推荐算法与 L10n key 逐字未动。
// PendingGroupResolution / PendingMemberDecision / VisualPreset 随行（原 21-122 行）。
import SwiftUI
import GatherProtocol

private let groupPageSize = 100

/// 待确认的重复组处置：影响范围（保留/丢弃的数量与文件）在弹窗 message 中呈现。
///
/// internal（4b-2j）：文案用例直接构造本类型断言 zh/en 渲染，不再借进程全局语言。
struct PendingGroupResolution: Identifiable {
    let group: DuplicateGroup
    let resolution: DupResolution
    /// 推荐保留文件名：由视图层（MainActor）预计算后带入，文件级确认上下文
    /// 不直接调用 DuplicatesViewModel 的隔离静态方法。
    let recommendedFilename: String?

    var id: String { "\(group.id)-\(resolution.rawValue)" }

    /// Cut 4 / 4b-2j：只存 key（+ 参数），弹窗渲染期由页面语言的 L10n 解析；
    /// 模型内不再读进程级语言（切语言后重新渲染即换文案）。
    var confirmLabel: LocalizedText {
        resolution == .keepOne ? LocalizedText("保留最佳，丢弃其余") : LocalizedText("全部保留")
    }

    /// 保留最佳/全部保留都只改数据库标记（不删文件、可再改回），不使用红色破坏性语义。
    var confirmRole: ButtonRole? { nil }

    /// 影响范围在渲染期拼装：参数保持原始值（组号/数量/文件名），不预先本地化。
    func scopeText(with l10n: L10n) -> String {
        let total = group.memberCount
        switch resolution {
        case .keepOne:
            let kept = recommendedFilename ?? l10n("推荐照片")
            return l10n.format(
                "组 #%lld 共 %lld 张：仅保留推荐「%@」，其余 %lld 张标记为丢弃；被丢弃的照片会在导出时被排除，不会删除文件。",
                group.id, total, kept, max(0, total - 1)
            )
        case .keepAll:
            return l10n.format(
                "组 #%lld 共 %lld 张全部标记为保留，不再从导出中排除任何成员。",
                group.id, total
            )
        }
    }

    var cancelCopy: LocalizedText {
        resolution == .keepOne
            ? LocalizedText("保留最佳（组 #%lld）", params: ["\(group.id)"])
            : LocalizedText("全部保留（组 #%lld）", params: ["\(group.id)"])
    }
}

/// 待确认的成员保留状态：目标状态由点击时的意图决定，不在命令层翻转。
///
/// internal（4b-2j）：文案用例直接构造本类型断言 zh/en 渲染。
struct PendingMemberDecision: Identifiable {
    let member: DuplicateGroupMember
    let isKept: Bool

    var id: String { "\(member.id)-\(isKept)" }

    /// Cut 4 / 4b-2j：同 PendingGroupResolution，key/参数在弹窗渲染期解析。
    var confirmLabel: LocalizedText {
        isKept ? LocalizedText("保留此照片") : LocalizedText("丢弃此照片")
    }

    /// 保留/丢弃都只改数据库标记（不删文件、可反向操作），不使用红色破坏性语义。
    var confirmRole: ButtonRole? { nil }

    func scopeText(with l10n: L10n) -> String {
        isKept
            ? l10n.format(
                "将「%@」（%@）改回保留，重新参与导出。",
                member.filename, member.filepath
            )
            : l10n.format(
                "将「%@」（%@）标记为丢弃；该照片会从重复组中排除并在导出时被跳过，不会删除文件。",
                member.filename, member.filepath
            )
    }

    var cancelCopy: LocalizedText {
        isKept
            ? LocalizedText("保留「%@」", params: [member.filename])
            : LocalizedText("丢弃「%@」", params: [member.filename])
    }
}

// 对齐 TS DUP_THRESHOLD_PRESETS：严格 2 / 均衡 4 / 宽松 7（Duplicates.tsx:160-166）。
public enum VisualPreset: String, CaseIterable {
    case strict
    case balanced
    case loose

    public var threshold: Int {
        switch self {
        case .strict: return 2
        case .balanced: return 4
        case .loose: return 7
        }
    }

    /// Cut 4 / 4b-2j：档位名由调用点显式传入渲染期 L10n，不再读进程全局语言。
    public func label(with l10n: L10n) -> String {
        switch self {
        case .strict: return l10n("严格")
        case .balanced: return l10n("均衡")
        case .loose: return l10n("宽松")
        }
    }
}

@MainActor
@Observable
public final class DuplicatesViewModel {
    // Cut 1 / B5b：dup.scan/groups/resolve/resolve_member 走 DuplicateAPI；
    // jobs.cancel / jobs.list 走 JobAPI（扫描进度仍订阅 JobService 事件）。
    private let duplicate: any DuplicateAPI
    private let jobs: any JobAPI
    public let sessionId: String
    private(set) public var groups: [DuplicateGroup] = []
    private(set) public var scanResult: DuplicateScanResult?
    private(set) public var isScanning = false
    private(set) public var isLoading = false
    private(set) public var errorMessage: CommandError?
    private(set) public var notice: LocalizedText?
    /// 重复扫描实时进度（JobService duplicateScan 任务事件驱动，经事件中心转发）。
    private(set) public var scanProgressCurrent = 0
    private(set) public var scanProgressTotal = 0
    private(set) public var scanProgressPhase = "duplicate.read"
    private(set) public var scanJobId: String?
    public var threshold = 4
    public var showExact = true
    /// 产出当前 scanResult 时使用的阈值（第三轮审计 C-#7）。
    /// 改阈值/预设后旧数字必须标记为过期——否则「视觉相似 N 组」是上一个档位的结论，
    /// 却摆在新档位控件旁边冒充当前设置的结果（N03 的同类）。
    private(set) public var scannedThreshold: Int?

    /// 可见性门控（Cut 4 / 4a-2c）：重复页没有后台轮询，钩子只落状态，
    /// 与其它 6 个 VM 同形，供 SessionWorkspace.setVisible 统一扇出。
    private var isVisible = true
    /// 关闭终态（SessionWorkspace.close 扇出）。
    public private(set) var isShutdown = false

    /// 当前阈值与产出结果的阈值不一致（且确有结果）→ 数字已过期。
    public var isScanResultStale: Bool {
        guard scanResult != nil, let scannedThreshold else { return false }
        return scannedThreshold != threshold
    }
    private(set) public var visibleGroupCount = groupPageSize
    private var expandedGroupIds: Set<Int> = []

    /// 生产装配（RootView）：重复域与任务域都走 AppServices 的类型化 API。
    public init(sessionId: String, duplicate: any DuplicateAPI, jobs: any JobAPI) {
        self.sessionId = sessionId
        self.duplicate = duplicate
        self.jobs = jobs
    }

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2c）

    public func setVisible(_ visible: Bool) {
        guard !isShutdown else { return }
        isVisible = visible
    }

    /// 关闭：重复页无长任务；只落终态，避免关闭后被重新置可见。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isVisible = false
    }

    // MARK: - 预设 / 阈值（对齐 TS L159-166、309-343）

    public var activePreset: VisualPreset? {
        if threshold == VisualPreset.strict.threshold { return .strict }
        if threshold == VisualPreset.balanced.threshold { return .balanced }
        if threshold == VisualPreset.loose.threshold { return .loose }
        return nil
    }

    public func selectPreset(_ preset: VisualPreset) {
        threshold = preset.threshold
    }

    // MARK: - 数据加载

    /// 分组拉取（对齐 TS loadGroups：async + loading 态）。
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await duplicate.groups(sessionId)
            errorMessage = nil
        } catch {
            errorMessage = CommandError(error)
        }
    }

    public func scan() async {
        isScanning = true
        scanProgressCurrent = 0
        scanProgressTotal = 0
        scanProgressPhase = "duplicate.read"
        scanJobId = nil
        defer { isScanning = false }
        do {
            let scannedAt = threshold
            let input = try DuplicateScanInput(
                sessionId: sessionId,
                visualThreshold: scannedAt
            )
            scanResult = try await duplicate.scan(input)
            // 记录产生这份结果的阈值：之后改阈值时数字会被标记为过期（C-#7）。
            scannedThreshold = scannedAt
            notice = LocalizedText("重复扫描完成")
            await load()
        } catch {
            // 取消是正常终态（JobCancelledError），不落红色错误条；
            // 兼容旧命令面 把取消描述成 "…cancelled…" 文案的路径。
            if Self.isCancellation(error) {
                notice = LocalizedText("重复扫描已取消")
            } else {
                errorMessage = CommandError(error)
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        // E-19 相邻：取消标记经 UI 端口判定（GatherHost 为 JobCancelledError
        // 提供 conformance），GatherUI 不 import 领域层。
        if error is any JobCancellationMarker { return true }
        // 与 FaceKeywordingViewModel 同一口径：按错误载体的码/原文判定，
        // 不再经文案漏斗（漏斗会把非码诊断统一成通用文案，判定形同虚设）。
        return CommandError(error).code.localizedCaseInsensitiveContains("cancelled")
    }

    /// jobs:progress 订阅入口（对齐 FaceKeywording/Export：JobService
    /// duplicateScan 任务的进度/终态帧）。
    public func applyJobEvent(_ event: GatherJobEvent) {
        guard event.job.type == .duplicateScan,
              event.job.scopeType == "session",
              event.job.scopeId == sessionId else { return }
        scanJobId = event.job.id
        guard !event.isTerminal else { return }
        scanProgressCurrent = event.update.current ?? event.job.progressCurrent
        scanProgressTotal = event.update.total ?? event.job.progressTotal
        scanProgressPhase = event.update.phase ?? event.update.message ?? "duplicate.read"
    }

    /// 取消扫描：优先用事件记录的 jobId，事件未到达时按会话内活跃任务兜底。
    public func cancelScan() async {
        let jobId: String
        if let recorded = scanJobId {
            jobId = recorded
        } else if let active = await activeScanJobId() {
            jobId = active
        } else {
            return
        }
        do {
            _ = try await jobs.cancel(jobId)
            notice = LocalizedText("已请求取消重复扫描")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    private func activeScanJobId() async -> String? {
        let all = (try? await jobs.list(JobListFilter(includeCheckpoint: false))) ?? []
        return all.first { job in
            job.type == .duplicateScan && job.scopeId == sessionId &&
                [.queued, .running, .cancelling].contains(job.status)
        }?.id
    }

    // MARK: - 组 / 成员操作（本地 patch，对齐 TS L201-270）
    // 组/成员处置是破坏性入口：API 只接收 Confirmed<T>，确认来源固定为用户弹窗；
    // `confirmed` 只能由视图层确认弹窗传入 true，取消路径根本不会调用这里。

    public func resolveGroup(_ group: DuplicateGroup, resolution: DupResolution, confirmed: Bool) async {
        guard confirmed else {
            errorMessage = CommandError.localized("DUP_RESOLVE_CONFIRM_REQUIRED")
            return
        }
        do {
            let input = try DuplicateResolveInput(groupId: group.id, resolution: resolution)
            _ = try await duplicate.resolve(Confirmed(input, source: .userDialog))
            errorMessage = nil
            notice = LocalizedText("已处理重复组 #%lld", params: ["\(group.id)"])
            // 处置会改变导出过滤（removed/丢弃语义），广播供常驻页按域刷新。
            GatherEventCenter.postDomainChange(.duplicates, sessionId: sessionId)
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            var updated = groups[index]
            updated.resolution = resolution.rawValue
            let keptMemberId = resolution == .keepAll ? nil : Self.recommendation(in: updated)?.id
            updated.members = updated.members.map { member in
                var patched = member
                patched.isKept = resolution == .keepAll || member.id == keptMemberId
                patched.resolution = resolution.rawValue
                return patched
            }
            groups[index] = updated
        } catch {
            // DuplicateServiceError.groupNotFound 等没有协议码：code 只带 NSError
            // 描述，渲染期回落通用文案（原始英文诊断不上屏），这里不按错误类型分支。
            errorMessage = CommandError(error)
        }
    }

    /// 成员保留状态（用户确认后的目标状态；旧实现「无参翻转」在确认前就改变
    /// 语义，已删除）。`confirmed` 由确认弹窗传入。
    public func setMemberKept(_ member: DuplicateGroupMember, isKept: Bool, confirmed: Bool) async {
        guard confirmed else {
            errorMessage = CommandError.localized("DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED")
            return
        }
        do {
            let input = try DuplicateResolveMemberInput(memberId: member.id, isKept: isKept)
            _ = try await duplicate.resolveMember(Confirmed(input, source: .userDialog))
            errorMessage = nil
            GatherEventCenter.postDomainChange(.duplicates, sessionId: sessionId)
            guard let groupIndex = groups.firstIndex(where: { $0.members.contains(where: { $0.id == member.id }) }),
                  let memberIndex = groups[groupIndex].members.firstIndex(where: { $0.id == member.id })
            else { return }
            groups[groupIndex].members[memberIndex].isKept = isKept
            groups[groupIndex].members[memberIndex].resolution = isKept
                ? DupResolution.keepAll.rawValue
                : DupResolution.keepOne.rawValue
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 取消破坏性动作：给出可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: String) {
        notice = LocalizedText.cancel(action)
        errorMessage = nil
    }

    // MARK: - 分页 / 展开折叠

    public func resetPagination() {
        visibleGroupCount = groupPageSize
        expandedGroupIds.removeAll()
    }

    public func loadMoreGroups() {
        visibleGroupCount += groupPageSize
    }

    public func isExpanded(_ groupId: Int) -> Bool {
        expandedGroupIds.contains(groupId)
    }

    public func toggleExpanded(_ groupId: Int) {
        if expandedGroupIds.contains(groupId) {
            expandedGroupIds.remove(groupId)
        } else {
            expandedGroupIds.insert(groupId)
        }
    }

    // MARK: - 派生数据

    public var filteredGroups: [DuplicateGroup] {
        showExact
            ? groups.filter { $0.groupType == .exact }
            : groups.filter { $0.groupType == .visual }
    }

    public var visibleFilteredGroups: [DuplicateGroup] {
        Array(filteredGroups.prefix(visibleGroupCount))
    }

    public var remainingGroupCount: Int {
        max(0, filteredGroups.count - visibleGroupCount)
    }

    public var exactGroupCount: Int {
        groups.filter { $0.groupType == .exact }.count
    }

    public var visualGroupCount: Int {
        groups.count - exactGroupCount
    }

    // MARK: - 推荐保留（对齐 TS Duplicates.tsx:68-75 与 duplicate.service.ts resolveGroup）
    // score = fileSize*1000 + mtime ms；最高分者为推荐保留，平手取先出现者。

    public static func recommendation(in group: DuplicateGroup) -> DuplicateGroupMember? {
        var best: DuplicateGroupMember?
        var bestScore: Int64 = -1
        for member in group.members {
            let score = memberScore(member)
            if score > bestScore {
                bestScore = score
                best = member
            }
        }
        return best
    }

    public static func memberScore(_ member: DuplicateGroupMember) -> Int64 {
        Int64(member.fileSize ?? 0) * 1000 + mtimeMilliseconds(member.fileMtime)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func mtimeMilliseconds(_ value: String?) -> Int64 {
        guard let value, !value.isEmpty else { return 0 }
        if let date = iso8601WithFractional.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        if let date = iso8601.date(from: value) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return 0
    }
}
