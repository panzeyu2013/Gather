import Foundation

public enum LogLevel: Int, Comparable {
    case debug
    case info
    case warn
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum GatherLogger {
    /// 全局日志状态（等级 / 输出 sink / 时间格式器）与其互斥锁。
    ///
    /// Swift 6：顶层 `static var` 是 *nonisolated global shared mutable state*，而且
    /// `ISO8601DateFormatter` 本身不是 `Sendable`。改为「不可变引用 + 内部加锁的可变盒子」：
    /// `static let state` 只发布一次且类型为 `Sendable`，全部可变状态只在 `lock` 临界区内读写
    /// ——这就是 `@unchecked Sendable` 的依据（锁纪律无法被编译器静态验证）。
    final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var minimumLevel: LogLevel = .info
        var output: (String) -> Void = { print($0) }
        let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    static let state = State()

    /// 全局可变状态的互斥锁。测试通过 @testable 访问，在 capture 期间持有同一把锁，
    /// 保证与 log() 原子互斥（不依赖测试 runner 串行）。
    static var stateLock: NSRecursiveLock { state.lock }

    public static var minimumLevel: LogLevel {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.minimumLevel
        }
        set {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.minimumLevel = newValue
        }
    }

    public static var output: (String) -> Void {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.output
        }
        set {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.output = newValue
        }
    }

    public static func log(_ message: String, level: LogLevel) {
        let state = state
        state.lock.lock()
        defer { state.lock.unlock() }
        guard level >= state.minimumLevel else { return }
        let timestamp = state.timestampFormatter.string(from: Date())
        state.output("[\(timestamp)] [\(level)] \(message)")
    }
}
