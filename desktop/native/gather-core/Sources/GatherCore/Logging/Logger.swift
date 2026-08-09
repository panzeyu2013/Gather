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

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func log(_ message: String, level: LogLevel) {
        guard level >= minimumLevel else { return }
        let timestamp = timestampFormatter.string(from: Date())
        output("[\(timestamp)] [\(level)] \(message)")
    }
}
