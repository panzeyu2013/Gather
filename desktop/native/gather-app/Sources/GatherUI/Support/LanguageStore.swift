// desktop/native/gather-app/Sources/GatherUI/Support/LanguageStore.swift
// Cut 4 / 4a-0 新增、4a-3a 接线：界面语言的唯一写入入口。
//
// 现状（审计 §1.6）：语言有 4 个载体、4 个重复写入点（SettingsViewModel、
// AppDelegate、RootView、GatherLocalization.appLanguage）。LanguageStore 把
// "当前语言 + 切换计数 + 通知广播/订阅 + 旧全局同步"收敛到一处；4a-3a 接线后
// SettingsViewModel.setLanguage 只调用本类的 set，持久化仍由 SettingsAPI 负责，
// RootView/Commands 的文案由本类的 l10n 驱动。
//
// 兼容策略：set/adopt 会同步写 GatherLocalization.appLanguage，使尚未迁移的
// l() 立即跟随；L10n 则完全不读该全局（渲染期显式传 language）。
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class LanguageStore {
    /// userInfo 的键（AppDelegate/RootView 等旧订阅方可以只按通知名处理）。
    /// nonisolated：init 的 Sendable 通知闭包里要读它（不可变 String，安全）。
    public nonisolated static let notificationLanguageKey = "language"

    /// 当前语言；只有 set / 通知采纳两条路径会改变它。
    public private(set) var language: L10n.Language
    /// 真实切换次数（同值 set 不计数；用于 Observation 刷新与测试断言）。
    public private(set) var changeCount = 0

    /// 渲染期使用的本地化器（每次读当前语言，不缓存字符串）。
    public var l10n: L10n { L10n(language: language) }

    @ObservationIgnored private let notificationCenter: NotificationCenter

    /// - Parameters:
    ///   - language: nil = 沿用进程当前语言（冷启动由组合根把 SettingsAPI 读到的值传入）。
    ///   - notificationCenter: 测试可注入独立中心，避免污染进程级 .default。
    public init(
        language: L10n.Language? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.language = language ?? L10n.Language(rawLanguage: GatherLocalization.appLanguage)
        self.notificationCenter = notificationCenter
        // 订阅旧写点（设置页/委托）发出的广播：外部写入后本类跟随，保证 4a-3
        // 之前"两条写路径"仍然收敛到同一个当前值。queue 为 nil（同步投递），
        // 主线程上直接更新；非主线程投递时跳回 MainActor。
        // 本类是壳层 app 生命周期单例（4a-3 装配），订阅随进程存活；
        // 令牌不需要跨 MainActor 保存（会引入非 Sendable 属性）。
        _ = notificationCenter.addObserver(
            forName: GatherAppNotification.languageChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let raw = notification.userInfo?[Self.notificationLanguageKey] as? String
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.adoptNotification(rawLanguage: raw)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.adoptNotification(rawLanguage: raw)
                }
            }
        }
    }

    // MARK: - 写入

    /// 切换语言。同值调用是 no-op（不计数、不广播）。
    /// - Returns: 是否真的发生了变化。
    @discardableResult
    public func set(_ newLanguage: L10n.Language) -> Bool {
        guard newLanguage != language else { return false }
        apply(newLanguage)
        GatherLocalization.setAppLanguage(newLanguage.rawValue)
        notificationCenter.post(
            name: GatherAppNotification.languageChanged,
            object: self,
            userInfo: [Self.notificationLanguageKey: newLanguage.rawValue]
        )
        return true
    }

    /// 冷启动播种：由组合根把持久化的 ui_language 写进来（4a-3a 接线）。
    ///
    /// 与 set 的区别：**不广播**。启动阶段还没有订阅方，且持久化早已完成；
    /// 走 set 会在冷启动多出一条 languageChanged（AppDelegate 会据此重装
    /// 标准菜单），把「设置页切换」的语义混进启动路径。
    public func seed(_ newLanguage: L10n.Language) {
        guard newLanguage != language else { return }
        apply(newLanguage)
        GatherLocalization.setAppLanguage(newLanguage.rawValue)
    }

    /// 校验并切换（settings.ui_language 的原始字符串入口）。
    /// 非法值返回 nil 且不改变当前语言（对齐 SETTINGS_LANGUAGE_INVALID 语义）。
    @discardableResult
    public func set(rawLanguage: String) -> L10n.Language? {
        guard let parsed = L10n.Language.parse(rawLanguage) else { return nil }
        set(parsed)
        return parsed
    }

    public static func isSupported(rawLanguage: String) -> Bool {
        L10n.Language.parse(rawLanguage) != nil
    }

    // MARK: - 通知

    /// 采纳外部广播：只更新自身，不再二次广播（避免回环）。
    private func adoptNotification(rawLanguage: String?) {
        let raw = rawLanguage ?? GatherLocalization.appLanguage
        guard let incoming = L10n.Language.parse(raw) else { return }
        guard incoming != language else { return }
        apply(incoming)
        if GatherLocalization.appLanguage != incoming.rawValue {
            GatherLocalization.setAppLanguage(incoming.rawValue)
        }
    }

    private func apply(_ newLanguage: L10n.Language) {
        language = newLanguage
        changeCount += 1
    }
}

// MARK: - SwiftUI 环境下发（Cut 4 / 4a-3b-2b）

/// 会话页从 environment 取语言源（RootView / SessionPageHost 注入）。
///
/// 为什么是 Optional：页面/预览/布局测试可能脱离 RootView 单独构造。生产树
/// 由外壳显式注入，页面用 languageStore?.l10n ?? L10n(language: .zhCN) 兜底；
/// 这个兜底是**固定值**，不再读进程级 GatherLocalization.appLanguage
/// （4a-3b-2b 删除旧兜底，避免切语言时页面读到过期全局值）。
public struct LanguageStoreEnvironmentKey: EnvironmentKey {
    public static var defaultValue: LanguageStore? { nil }
}

public extension EnvironmentValues {
    /// 当前界面语言的唯一读取源（@Observable：读 l10n 会建立 Observation 依赖）。
    var languageStore: LanguageStore? {
        get { self[LanguageStoreEnvironmentKey.self] }
        set { self[LanguageStoreEnvironmentKey.self] = newValue }
    }
}
