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

/// 展示用 formatter/解析器缓存：**DateFormatter / ISO8601DateFormatter /
/// ByteCountFormatter**（C-8/C-1 + perf-ui 性能修复，输出与旧实现逐字节一致）。
///
/// 教训（第二轮自查）：曾尝试改成 `Date.FormatStyle`——解析路径等价（实测 0 差异），
/// 但**展示**路径 zh 下 `time: .shortened` 输出 "9:46"，旧实现是 "09:46"（缺前导零）
/// ⇒ 展示回归。这里保留 DateFormatter 语义，只缓存实例（构造 55µs/次 → 复用）。
final class DisplayDateFormatters: @unchecked Sendable {
    static let shared = DisplayDateFormatters()

    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]
    /// 文件大小 formatter（task-10：类方法每次调用都新建实例）。
    /// 只有 locale 变化时才重建，其它配置与
    /// `ByteCountFormatter.string(fromByteCount:countStyle: .file)` 完全一致。
    private var byteCountFormatter: ByteCountFormatter?
    private var byteCountFormatterLocaleID = ""
    /// 展示层 ISO-8601 解析器（构造昂贵，进程内复用）。
    ///
    /// formatOptions 与旧实现逐字节一致：一个 `[.withInternetDateTime]`，
    /// 另一个再加 `.withFractionalSeconds`。与 formatter 缓存共用同一把锁：
    /// `formatter(key:)` 的 make 闭包不会回调解析方法，不存在重入。
    private let internetDateTimeFormatter: ISO8601DateFormatter
    private let fractionalSecondsFormatter: ISO8601DateFormatter

    private init() {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        internetDateTimeFormatter = plain
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalSecondsFormatter = fractional
    }

    /// 取/建缓存 formatter 并在**持锁状态**下执行 body。
    ///
    /// 评审 R2-A4 / R5-03 同型：DateFormatter 非线程安全，旧写法"取到实例就释放锁、
    /// 再在锁外 string(from:)" 在并行测试或后台渲染下可并发使用同一实例（未定义行为）。
    /// 格式化本身是 O(µs)，持锁的串行代价可忽略；与 fileSize/ISO 解析的持锁口径统一。
    private func withFormatter<T>(key: String, make: () -> DateFormatter, _ body: (DateFormatter) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let existing = cache[key] {
            formatter = existing
        } else {
            formatter = make()
            cache[key] = formatter
        }
        return body(formatter)
    }

    /// Dashboard：dateStyle .medium + timeStyle .short（跟随应用语言）。
    ///
    /// 评审 R3-T03：缓存键补上 calendar/timeZone（旧实现每次新建会跟随系统设置；
    /// 只按 locale 缓存会把改过时区后的输出停在旧环境）。
    func mediumShort(_ date: Date, locale: Locale) -> String {
        withFormatter(key: environmentKey("mediumShort", locale: locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        } body: { formatter in
            formatter.string(from: date)
        }
    }

    /// ISO-8601 解析；等价于旧实现的 `ISO8601DateFormatter()` + `[.withInternetDateTime]`。
    func internetDateTime(_ iso: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return internetDateTimeFormatter.date(from: iso)
    }

    /// 同上，再加 `.withFractionalSeconds`（旧实现"先带小数秒、再回退不带"的第一步）。
    func internetDateTimeWithFractionalSeconds(_ iso: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractionalSecondsFormatter.date(from: iso)
    }

    /// 固定 pattern 的展示格式化（导出命名预览、C1 状态胶囊时间）。
    ///
    /// 旧实现每次调用新建 DateFormatter，隐式环境（locale / calendar / timeZone）
    /// 在**调用时**取当前系统值；缓存键同样带上三者，运行中改系统设置会命中新
    /// 实例，输出不会停在旧环境（与旧实现一致，不引入展示差异）。
    func pattern(_ date: Date, format: String, locale: Locale) -> String {
        withFormatter(key: environmentKey("pattern|\(format)", locale: locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.dateFormat = format
            return f
        } body: { formatter in
            formatter.string(from: date)
        }
    }

    /// `setLocalizedDateFormatFromTemplate` 的缓存版（Persons 详情 yMd 短模板）。
    func localizedTemplate(_ date: Date, template: String, locale: Locale) -> String {
        withFormatter(key: environmentKey("template|\(template)", locale: locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        } body: { formatter in
            formatter.string(from: date)
        }
    }

    /// dateStyle `.short` + timeStyle `.short`（WebDAV 发布历史；旧实现不设 locale）。
    func shortShort(_ date: Date, locale: Locale) -> String {
        withFormatter(key: environmentKey("shortShort", locale: locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .short
            f.timeStyle = .short
            return f
        } body: { formatter in
            formatter.string(from: date)
        }
    }

    /// 文件大小展示：等价于旧调用的
    /// `ByteCountFormatter.string(fromByteCount:countStyle: .file)`（逐字节一致）。
    /// 持锁格式化（ByteCountFormatter 的并发安全没有 DateFormatter 那样的公开承诺）。
    func fileSize(_ bytes: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        let localeID = Locale.current.identifier
        if let byteCountFormatter, byteCountFormatterLocaleID == localeID {
            return byteCountFormatter.string(fromByteCount: bytes)
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        byteCountFormatter = formatter
        byteCountFormatterLocaleID = localeID
        return formatter.string(fromByteCount: bytes)
    }

    /// ISO-8601 输出：等价于旧实现的
    /// `ISO8601DateFormatter()` + `[.withInternetDateTime]`（WebDAV 到期时间）。
    func internetDateTimeString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return internetDateTimeFormatter.string(from: date)
    }

    /// 固定 UTC + `en_US_POSIX` 的墙上时间解析（EXIF DateTimeOriginal 的批量偏移）。
    /// 与旧实现同 locale/timeZone/dateFormat；持锁保证跨线程（测试并行）安全。
    func parseFixedUTC(_ string: String, format: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fixedUTCFormatter(format: format).date(from: string)
    }

    /// `parseFixedUTC` 的格式化方向；同样是固定 UTC + `en_US_POSIX`。
    func formatFixedUTC(_ date: Date, format: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fixedUTCFormatter(format: format).string(from: date)
    }

    /// 调用方必须已持有 `lock`（避免与其它 formatter 读取/创建并发）。
    private func fixedUTCFormatter(format: String) -> DateFormatter {
        let key = "fixedUTC|\(format)"
        if let existing = cache[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        cache[key] = formatter
        return formatter
    }

    /// 缓存键里的隐式环境：旧实现每次新建 ⇒ locale / calendar / timeZone 取调用时值。
    private func environmentKey(_ base: String, locale: Locale) -> String {
        "\(base)|\(locale.identifier)|\(Calendar.current.identifier)|\(TimeZone.current.identifier)"
    }
}
