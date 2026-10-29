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
        /// 状态锁：只保护 minimumLevel / output / formatter 的读写（快操作）。
        let lock = NSRecursiveLock()
        /// 输出锁：只串行化 sink 调用，保证行不交错。
        ///
        /// 为什么与 `lock` 分开（2026-10-29 CI 假死复盘）：旧实现把 `output(...)` 放在
        /// `lock` 里调用，sink 一旦变慢（CI 的 stdout 是带背压的管道）就**持锁阻塞**，
        /// 之后任何打日志或读 level 的线程全部排队，整个进程 21 分钟零输出。
        /// 现在锁内只做快照，sink 在锁外调用。
        ///
        /// 锁序固定为 outputLock → lock（capture 先持 outputLock 再改 output/level），
        /// 而 `log()` 先释放 lock 才取 outputLock，因此不构成环。
        /// 必须是**递归**锁：捕获测试持锁后会调用被测代码，后者可能直接 `log()`（同线程重入）。
        let outputLock = NSRecursiveLock()
        var minimumLevel: LogLevel = .info
        var output: (String) -> Void = { print($0) }
        let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    static let state = State()

    /// 全局可变状态的互斥锁。测试通过 @testable 访问（只用于读写 output/level）。
    static var stateLock: NSRecursiveLock { state.lock }

    /// 输出串行化锁。capture 期间持有它，才能保证「其它线程的日志不会插进捕获结果」；
    /// 只有它会在 sink 调用期间被持有，因此慢 sink 最多拖住正在写的那一个调用者。
    static var outputLock: NSRecursiveLock { state.outputLock }

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
        // 锁内只做快照：读 level / 生成时间戳 / 取 sink 引用。
        state.lock.lock()
        guard level >= state.minimumLevel else {
            state.lock.unlock()
            return
        }
        let timestamp = state.timestampFormatter.string(from: Date())
        let sink = state.output
        state.lock.unlock()

        // sink 在状态锁外调用：慢 sink（CI 管道 stdout、慢盘）不再阻塞状态读写。
        state.outputLock.lock()
        defer { state.outputLock.unlock() }
        sink("[\(timestamp)] [\(level)] \(message)")
    }
}
