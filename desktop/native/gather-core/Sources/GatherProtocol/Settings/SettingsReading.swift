// desktop/native/gather-core/Sources/GatherProtocol/Settings/SettingsReading.swift
// 设置读取端口（#9 / SettingsPort）。
//
// 为什么需要：设置曾经以 21 个闭包（getNumber/getString/getSetting）注入到服务里，
// 每个闭包自带默认值、各自折叠类型，读取语义在 5 个模块里各写一遍。本端口把
// 「读一个键」收敛成一个原语，其余类型折叠变成协议扩展的共享实现——
// 语义（未命中回默认值、NaN/inf 回落、非有限值不 trap）只写一次。
//
// 为什么同步：调用点在同步上下文里（DB.open 的 PRAGMA、轮询循环、命令栈），
// 设置读取是内存字典命中，加 async 会把 73 个读取点全部改成 await 并逼着
// 同步调用栈重排——收益为零。
//
// 为什么 Sendable：DBConnection（@unchecked Sendable）、MetadataDeliveryService
// （struct）、MaintenanceService（actor）都要把它作为存字段持有。
import Foundation

/// 设置读取端口：只回答「库里存了什么」，不折叠默认值、不转换类型。
///
/// nil 表示键未设置（或键根本不是已注册键）；调用方经下面的扩展折叠类型。
public protocol SettingsReading: Sendable {
    func storedValue(for key: SettingsKey) -> String?
}

public extension SettingsReading {
    /// 字符串读取：未设置 → 键自带默认值（不是空串）。
    func string(_ key: SettingsKey) -> String {
        storedValue(for: key) ?? key.defaultValue
    }

    /// 数值读取：未设置 / 解析失败 / 非有限（inf、1e999）→ 默认值。
    ///
    /// 非有限值必须回落：Swift 的 Int(Double.infinity) 是 trap 而不是抛错，
    /// 一个手改的 1e999 就能让分析链路崩溃（对抗验证 V2 实测 SIGTRAP）。
    func double(_ key: SettingsKey) -> Double {
        guard let raw = storedValue(for: key), let parsed = Double(raw), parsed.isFinite else {
            return Double(key.defaultValue) ?? 0
        }
        return parsed
    }

    /// 整数读取：先走 double 的安全语义，再经 safeInt 夹到 Int 边界（不 trap）。
    func int(_ key: SettingsKey) -> Int {
        double(key).safeInt(fallback: Int(key.defaultValue) ?? 0)
    }

    /// 布尔读取：兼容两种历史方言（"1"/"0" 与 "true"/"false"）。
    ///
    /// 两种方言是存量事实（triage_* 用 "1"，lazy_checksum 用 "true"），
    /// 归一化属于独立决策（会翻存量库的语义），所以这里取并集而不是二选一。
    func bool(_ key: SettingsKey) -> Bool {
        let raw = (storedValue(for: key) ?? key.defaultValue).lowercased()
        return raw == "1" || raw == "true"
    }
}

/// 闭包适配器：测试与过渡期需要「一行 lambda 就是一个端口」。
///
/// 生产装配应该用真正的实现（SettingsService / DatabaseSettingsReader）；
/// 保留它是因为 36 个测试注入点逐个改会造成无谓的迁移噪音。
public struct ClosureSettingsReader: SettingsReading {
    private let read: @Sendable (SettingsKey) -> String?

    public init(_ read: @escaping @Sendable (SettingsKey) -> String?) {
        self.read = read
    }

    public func storedValue(for key: SettingsKey) -> String? { read(key) }
}
