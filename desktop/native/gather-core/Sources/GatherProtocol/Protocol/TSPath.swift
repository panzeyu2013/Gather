// desktop/native/gather-core/Sources/GatherProtocol/Protocol/TSPath.swift
// R7：从 GatherPersistence/Repositories/RepositorySupport.swift 迁入 Protocol。
//
// 原因：导入路径归一化（normalizeImportFilepaths）与 UI 取名（basename）都要用
// 同一套 node:path 语义；Protocol 是 GatherUI 的唯一依赖，迁入后 UI 不再需要
// 「ImportPathRules 端口 + Host 适配器 + 进程级 registry」三跳。
//
// 实现逐字来自 RepositorySupport.swift（纯 Foundation，无业务语义）。
import Foundation

/// TS `node:path` 语义的最小复刻（仅本仓用到的子集）。
public enum TSPath {
    public static var separator: String { "/" }

    /// TS `path.resolve(...)`：转为绝对路径并标准化。
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

    /// TS `path.join(parsed.dir, name + ".xmp")`（xmp-sidecar-writer 语义）。
    public static func xmpSidecarPath(_ photoPath: String) -> String {
        join([dirname(photoPath), stem(photoPath) + ".xmp"])
    }
}
