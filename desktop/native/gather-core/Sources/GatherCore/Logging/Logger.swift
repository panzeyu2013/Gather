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
    public static var minimumLevel: LogLevel = .info
    public static var output: (String) -> Void = { print($0) }

    // 全局可变状态（minimumLevel/output）的互斥锁。测试通过 @testable 访问，
    // 在 capture 期间持有同一把锁，保证与 log() 原子互斥（不依赖测试 runner 串行）。
    static let stateLock = NSRecursiveLock()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func log(_ message: String, level: LogLevel) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard level >= minimumLevel else { return }
        let timestamp = timestampFormatter.string(from: Date())
        output("[\(timestamp)] [\(level)] \(message)")
    }
}
