// 跨页面共享的日期解析辅助。
// 合并来源：DashboardView / PersonsView 各自私有的 parseISO8601（×2）。
//
// C/P2（性能审计）：旧实现每次调用新建**两个** ISO8601DateFormatter
// （实测解析 169µs/次），而它在 body / 逐行路径上被反复调用（Dashboard 每行
// 最多 4 次、Settings 每次 body 逐项一次）。这里改用 Date.ISO8601FormatStyle
// ——值类型、Sendable、无构造开销（实测 0.24µs/次，约 700×）。
//
// 注意：**只**用于展示层解析。落库/比较用的时间戳字符串必须继续走 core 的
// tsParseISODate（DateFormatter 语义，毫秒舍入与 FormatStyle 不同）。
import Foundation

/// ISO8601 解析：先按带小数秒的互联网日期时间解析，失败回退不带小数秒的同一格式。
func parseISO8601Date(_ iso: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso) {
        return date
    }
    return try? Date.ISO8601FormatStyle().parse(iso)
}

/// 展示用日期格式化：**缓存 DateFormatter**（C-8/C-1 性能修复，但输出与旧实现
/// 逐字节一致）。
///
/// 教训（第二轮自查）：曾尝试改成 `Date.FormatStyle`——解析路径等价（实测 0 差异），
/// 但**展示**路径 zh 下 `time: .shortened` 输出 "9:46"，旧实现是 "09:46"（缺前导零）
/// ⇒ 展示回归。这里保留 DateFormatter 语义，只缓存实例（构造 55µs/次 → 复用）。
final class DisplayDateFormatters: @unchecked Sendable {
    static let shared = DisplayDateFormatters()

    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]

    private func formatter(key: String, make: () -> DateFormatter) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        let created = make()
        cache[key] = created
        return created
    }

    /// Dashboard：dateStyle .medium + timeStyle .short（跟随应用语言）。
    func mediumShort(_ date: Date, locale: Locale) -> String {
        let formatter = formatter(key: "mediumShort|\(locale.identifier)") {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }
        return formatter.string(from: date)
    }
}
