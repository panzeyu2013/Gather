// desktop/native/gather-app/Sources/GatherUI/Metadata/C1PendingJudgementNotice.swift
// Wave4c / task-48（A2 半修）：C1 判断 pending 重放的可见状态 + 手动重试入口。
//
// 为什么放 MetadataSyncBar：C1 判断落库属于元数据/交付链路；状态条已有同步态的
// 可见面，把"N 项待重试"放这里，用户不需要回挑片页。Host 侧 AppBootstrap 通过
// `C1PendingJudgementStore.shared.onRetry` 注入重试动作（actor 里真正执行 apply）。
import SwiftUI
import Observation
import GatherProtocol

/// pending 重放计数的 UI 投影（Host 写、MetadataSyncBar 读）。
///
/// 只在进程内：pending 判断不写库（task-48 明确不改 schema）；重启后丢失，
/// 用户可重新从 C1 导入判断。
@MainActor
@Observable
public final class C1PendingJudgementStore {
    public static let shared = C1PendingJudgementStore()

    /// sessionId → 待重试的合并照片数（0/缺省 = 无）。
    public private(set) var counts: [String: Int] = [:]
    /// Host 注入的重试动作（nil = 未接线：按钮隐藏但不影响计数展示）。
    public var onRetry: (@MainActor (String) async -> Void)?

    public init() {}

    public func setCount(sessionId: String, count: Int) {
        if count > 0 {
            counts[sessionId] = count
        } else {
            counts.removeValue(forKey: sessionId)
        }
    }

    public func count(sessionId: String) -> Int { counts[sessionId] ?? 0 }

    public func reset() {
        counts.removeAll()
        onRetry = nil
    }

    public func retry(sessionId: String) async {
        await onRetry?(sessionId)
    }
}

/// 状态条里的一行："有 N 项 C1 判断待重试" + 重试同步。
struct C1PendingJudgementNotice: View {
    let sessionId: String
    @State private var store = C1PendingJudgementStore.shared
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        let count = store.count(sessionId: sessionId)
        if count > 0 {
            HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.xs) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.warning)
                    .accessibilityHidden(true)
                Text(l10n.format(
                    "有 %lld 项 C1 判断待重试（扫描未成功，写入可能被覆盖）",
                    count))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: GatherMetrics.Space.xs)
                if store.onRetry != nil {
                    Button(l10n("重试同步")) {
                        Task { await store.retry(sessionId: sessionId) }
                    }
                    .gatherButton(.secondary, size: .small)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
