// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ScanPath.swift
// R7：从 GatherPersistence/Database/ScanPath.swift 迁入 Protocol。
//
// 路径归一化是扫描/导入/Repo 共用的唯一口径；R7 起 UI 也要直接用它做导入归一化，
// 而 GatherUI 只依赖 Protocol。POSIX lstat 在 macOS/Linux 均可用。
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// lstat 缓冲：lstat 的第二个参数需要可变的 stat 缓冲区。
private func lstatBuf() -> stat {
    stat()
}

/// 全链路唯一的路径归一化函数族（扫描、导入、Repo 共用）。
///
/// 口径（三步，纯字符串、无系统调用、幂等）：
///   1. TSPath.resolve —— 词法绝对化 + 折叠 . / ..；
///   2. TSPath.normalize；
///   3. 系统前缀折叠 —— /private/var → /var、/private/tmp → /tmp。
public enum ScanPath {
    /// 全链路唯一的归一化函数（唯一名字，不设别名）。
    public static func canonical(_ path: String) -> String {
        let resolved = TSPath.normalize(TSPath.resolve(path))
        if resolved == "/private/var" || resolved.hasPrefix("/private/var/") {
            return String(resolved.dropFirst("/private".count))
        }
        if resolved == "/private/tmp" || resolved.hasPrefix("/private/tmp/") {
            return String(resolved.dropFirst("/private".count))
        }
        return resolved
    }

    /// 候选路径是否落在根之内（含根自身）。
    public static func isWithin(candidate: String, root: String) -> Bool {
        let rootComponents = pathComponents(canonical(root))
        let candidateComponents = pathComponents(canonical(candidate))
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// 词法相对路径：path 落在 root 内时返回相对部分（path == root -> ""），否则 nil。
    public static func relative(path: String, root: String) -> String? {
        let rootComponents = pathComponents(canonical(root))
        let pathComponents = pathComponents(canonical(path))
        guard pathComponents.count >= rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// lstat 判定目录：符号链接不进入递归。
    public static func isDirectory(_ path: String) -> Bool {
        var s = lstatBuf()
        return lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
    }

    /// 不可作为递归扫描根的目录：文件系统根、当前用户主目录及其祖先。
    public static func isForbiddenRoot(_ path: String) -> Bool {
        let resolved = canonical(path)
        if resolved == "/" { return true }
        let home = canonical(NSHomeDirectory())
        guard !home.isEmpty, home != "/" else { return false }
        let homeComponents = pathComponents(home)
        let resolvedComponents = pathComponents(resolved)
        guard resolvedComponents.count <= homeComponents.count else { return false }
        return Array(homeComponents.prefix(resolvedComponents.count)) == resolvedComponents
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
