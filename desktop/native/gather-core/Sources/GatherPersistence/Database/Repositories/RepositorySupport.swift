// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/RepositorySupport.swift
// 仓库层共享支撑（1.2）：TS 侧 node:crypto / node:path / node:fs / JSON 语义的最小复刻，
// 供各 Repo 复用，保证行为与 TS 一一对应。

import Foundation
import GatherProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// ISO8601 格式化/解析器的共享实例（B-12/P2-1 性能审计）。
///
/// 旧实现每次调用新建 DateFormatter：实测 **55µs/次**（复用 0.64µs，86×），
/// 而它在逐行循环里被调用（1 万张照片 2-3 次/张 ⇒ 0.3-1.5s 纯格式化）。
/// DateFormatter 非线程安全，因此统一由这把锁保护；**不改变格式语义**
/// （毫秒舍入与 ISO8601FormatStyle 不同，落库时间戳必须保持 DateFormatter）。
final class RepositoryDateFormatters: @unchecked Sendable {
    static let shared = RepositoryDateFormatters()
    private let lock = NSLock()
    private let writeFormatter: DateFormatter
    private let fractionalParser: ISO8601DateFormatter
    private let plainParser: ISO8601DateFormatter

    private init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        writeFormatter = formatter
        fractionalParser = ISO8601DateFormatter()
        fractionalParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainParser = ISO8601DateFormatter()
        plainParser.formatOptions = [.withInternetDateTime]
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return writeFormatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = fractionalParser.date(from: string) { return date }
        return plainParser.date(from: string)
    }
}

/// TS `new Date().toISOString()`：UTC 毫秒 ISO8601，固定 3 位毫秒。
public func isoString(_ date: Date) -> String {
    RepositoryDateFormatters.shared.string(from: date)
}

public func nowISOString() -> String {
    isoString(Date())
}

/// TS `crypto.randomUUID()`：小写 UUID。
public func newUUIDString() -> String {
    UUID().uuidString.lowercased()
}

/// ISO8601 时间戳解析（带毫秒优先，回退不带毫秒）的唯一实现；解析失败返回 nil。
/// 全仓只有这一处构造解析器（tsDateParse / MetadataOutboxRepo.parseTimestamp 共用）。
public func tsParseISODate(_ string: String) -> Date? {
    // B-12：复用解析器（实测 169µs → 36µs/次）；语义与原双 formatter 兜底一致。
    RepositoryDateFormatters.shared.date(from: string)
}

/// TS `Date.parse(isoString)`：解析失败返回 nil。
public func tsDateParse(_ string: String) -> Double? {
    tsParseISODate(string).map { $0.timeIntervalSince1970 * 1000 }
}

/// TS `fs.statSync(...)` 的字段子集（statSync 失败返回 nil）。
public struct TSFileStat: Equatable {
    public let size: Int64
    public let mtimeMs: Double
    public let dev: Int64
    public let ino: Int64
    public let isFile: Bool
}

/// TS `fs.statSync(path)`（不存在/失败 → nil）。
public func tsStat(_ path: String) -> TSFileStat? {
    var s = stat()
    guard stat(path, &s) == 0 else { return nil }
    #if canImport(Glibc)
    let mtimeMs = Double(s.st_mtim.tv_sec) * 1000 + Double(s.st_mtim.tv_nsec) / 1_000_000
    #else
    let mtimeMs = Double(s.st_mtimespec.tv_sec) * 1000 + Double(s.st_mtimespec.tv_nsec) / 1_000_000
    #endif
    return TSFileStat(
        size: Int64(s.st_size),
        mtimeMs: mtimeMs,
        dev: Int64(s.st_dev),
        ino: Int64(s.st_ino),
        isFile: (s.st_mode & S_IFMT) == S_IFREG
    )
}

/// TS `fs.existsSync(path)`。
public func tsExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

/// 可空值 → DBValue?（SQL 绑定用）。
public func optDB(_ v: Int64?) -> DBValue? { v.map { .int($0) } }
public func optDB(_ v: Double?) -> DBValue? { v.map { .real($0) } }
public func optDB(_ v: String?) -> DBValue? { v.map { .text($0) } }
