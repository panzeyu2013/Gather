// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/RepositorySupport.swift
// 仓库层共享支撑（1.2）：TS 侧 node:crypto / node:path / node:fs / JSON 语义的最小复刻，
// 供各 Repo 复用，保证行为与 TS 一一对应。

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// TS `new Date().toISOString()`：UTC 毫秒 ISO8601，固定 3 位毫秒。
public func isoString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: date)
}

public func nowISOString() -> String {
    isoString(Date())
}

/// TS `crypto.randomUUID()`：小写 UUID。
public func newUUIDString() -> String {
    UUID().uuidString.lowercased()
}

/// TS `Date.parse(isoString)`：解析失败返回 nil。
public func tsDateParse(_ string: String) -> Double? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date.timeIntervalSince1970 * 1000 }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: string) { return date.timeIntervalSince1970 * 1000 }
    return nil
}

/// 任意 JSON 值（Protocol/Core.swift 的 JSONValue，键与 TS `JSON.stringify` 一致，
/// 不做 key 转换）。此处补充仓库层需要的便捷方法。
extension JSONValue {
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var arrayValue: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { $0.stringValue }
    }

    /// TS `JSON.stringify`。
    public static func stringify(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// TS `JSON.parse`（解析失败抛出）。
    public static func parse(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }

    /// Int64 → 数字（现有 case 为 .number(Double)，双端无损）。
    public static func int(_ value: Int64) -> JSONValue {
        .number(Double(value))
    }

    /// Double → 数字。
    public static func real(_ value: Double) -> JSONValue {
        .number(value)
    }
}

/// TS `node:path` 语义的最小复刻（仅本层用到的子集）。
public enum TSPath {
    public static var separator: String { "/" }

    /// TS `path.resolve(...)`：转为绝对路径并标准化。
    /// standardizingPath 会展开前导 `~`（Node path.resolve 不展开，视为字面
    /// 文件名），故先以 NUL 占位保护、标准化后还原。
    /// 注：拼接用字符串 + "/" 而非 NSString.appendingPathComponent——
    /// macOS Foundation 对含 NUL 的字符串调用 appendingPathComponent 会
    /// 返回 nil 并隐式解包崩溃（Linux corelibs 不触发）；字符串拼接 +
    /// standardizingPath 的规范化结果等价（重复斜杠/./.. 均被折叠）。
    public static func resolve(_ path: String) -> String {
        var work = path
        let hadTilde = work.hasPrefix("~")
        if hadTilde { work = "\u{0}" + String(work.dropFirst()) }
        let ns = work as NSString
        let result: String
        if ns.isAbsolutePath {
            result = ns.standardizingPath
        } else {
            let joined = FileManager.default.currentDirectoryPath + "/" + work
            result = (joined as NSString).standardizingPath
        }
        if hadTilde {
            return result.replacingOccurrences(of: "\u{0}", with: "~")
        }
        return result
    }

    /// TS `path.normalize(...)`。
    public static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// TS `path.dirname(...)`。
    public static func dirname(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// TS `path.basename(...)`。
    public static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// TS `path.extname(...)`：含点（".jpg"），无扩展名时为空串。
    public static func extname(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext
    }

    /// TS `path.join(...)`。
    public static func join(_ components: String...) -> String { join(components) }

    public static func join(_ components: [String]) -> String {
        var result = ""
        for component in components {
            if component.isEmpty { continue }
            if result.isEmpty {
                result = component
            } else if component.hasPrefix("/") {
                if result.hasSuffix("/") { result += String(component.dropFirst()) }
                else { result += component }
            } else if result.hasSuffix("/") {
                result += component
            } else {
                result += "/" + component
            }
        }
        return result
    }

    /// TS `path.relative(from, to)`。
    public static func relative(_ from: String, to: String) -> String {
        let fromComponents = (resolve(from) as NSString).pathComponents
        let toComponents = (resolve(to) as NSString).pathComponents
        var common = 0
        while common < fromComponents.count, common < toComponents.count,
              fromComponents[common] == toComponents[common] {
            common += 1
        }
        var result: [String] = []
        for _ in common..<fromComponents.count { result.append("..") }
        result.append(contentsOf: toComponents[common...])
        if result.isEmpty { return "" }
        return result.joined(separator: "/")
    }

    /// TS `path.isAbsolute(...)`。
    public static func isAbsolute(_ path: String) -> Bool {
        (path as NSString).isAbsolutePath
    }

    /// TS `path.parse(x).root`。
    public static func root(_ path: String) -> String {
        (path as NSString).isAbsolutePath ? "/" : ""
    }

    /// TS `path.parse(x).name`（无扩展名的文件名）。
    public static func stem(_ path: String) -> String {
        ((path as NSString).deletingPathExtension as NSString).lastPathComponent
    }

    /// TS `path.join(parsed.dir, \`${parsed.name}.xmp\`)`（xmp-sidecar-writer 语义）。
    public static func xmpSidecarPath(_ photoPath: String) -> String {
        join([dirname(photoPath), stem(photoPath) + ".xmp"])
    }
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

