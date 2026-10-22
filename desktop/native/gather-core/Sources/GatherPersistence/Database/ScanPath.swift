// desktop/native/gather-core/Sources/GatherPersistence/Database/ScanPath.swift
// 全链路路径归一化（Cut 3a / refactor-decisions D-022，module-split-map E-02 残余）。
//
// 为什么在 Persistence：归一化函数同时被扫描/导入链路（Domain）与 AssetRepo、
// MetadataOutboxRepo（Persistence）使用。留在 Services 时，Persistence 引用它会
// 形成 Persistence→Domain 的反向依赖；拆 target 后 GatherPersistence 无法 import
// GatherDomain，若给两者互加依赖则 SwiftPM 直接报 cyclic dependency。归一化是
// 纯字符串工具 + POSIX lstat，与 Domain 语义无关，故整体下沉到 Persistence。
//
// 依赖：TSPath 在 Database/Repositories/RepositorySupport.swift（同模块）；
// 本文件不再引用 Services 内任何类型。实现与 public API 从
// Services/IndexerService.swift 原样搬移，行为逐字不变。

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// lstat 缓冲：`lstat` 的第二个参数需要可变的 `stat` 缓冲区。放在文件作用域
/// 构造，避免调用方类型里同名成员（IndexerService.stat 接缝）对 POSIX `stat`
/// 类型产生遮蔽；本文件内无同名成员，保留此辅助以与原实现逐字一致。
private func lstatBuf() -> stat {
    stat()
}

// MARK: - 路径归一化（单一真相源）

/// 全链路唯一的路径归一化函数族：扫描（IndexerService）与导入
/// （SessionService）两条链路共用同一口径，任何一侧都不得再自写一份
/// （历史背景：已删除的监听链路曾用 realpath，符号链接下
/// 会对同一物理文件产生两个键 → 重复导入或漏标）。
///
/// 口径（三步，纯字符串、无系统调用、幂等）：
///   1. TSPath.resolve —— 词法绝对化 + 折叠 . / ..；
///   2. TSPath.normalize；
///   3. 系统前缀折叠 —— /private/var → /var、/private/tmp → /tmp。
///
/// **为什么必须自己做第 3 步**（探针实测证据）：NSString.standardizingPath 只在
/// 路径**存在**时才解析 /private 系统符号链接。于是同一目录会出现两种拼写——
/// 注册的监听根（存在）是 /var/…，而删除事件的路径（已不存在）是 /private/var/…，
/// 包含判定因此失效（历史监听链路的删除事件即因此被丢弃）。realpath 同理：
/// 它对不存在的路径直接失败，与 TSPath.relative/dirname 混合使用时还会把
/// /private/var/folders/…/shoot-a/IMG_1 与 …/shoot-b/IMG_3 的公共父目录算成
/// /private。第 3 步把两种拼写**无条件**折叠为同一结果，与文件是否存在无关。
///
/// 真实身份解析（同一物理文件的不同位置）因此收敛在「同卷同 inode」这一层
/// （asset_files 的 volume_id + file_identity 重链接），不在路径字符串层做
/// 任意符号链接解析。
///
/// 为什么放在 Persistence 而不是 Protocol：Protocol 是纯值类型契约层（仅
/// Foundation），本类型需要 POSIX lstat；而 Persistence 的 Repo 同样要用它
/// 归一化路径（见文件头 D-022 说明）。
public enum ScanPath {
    /// 全链路唯一的归一化函数（唯一名字，不设别名）：所有 map 键、集合成员、
    /// 去重判等、落库路径一律使用它。名字强调「全链路唯一拼写」，**不代表**
    /// realpath 解析（见上方为什么不用 realpath）。
    public static func canonical(_ path: String) -> String {
        let resolved = TSPath.normalize(TSPath.resolve(path))
        // 系统符号链接前缀折叠：与「路径是否存在」无关，保证 /var 与
        // /private/var 两种拼写永远映射到同一个键。
        if resolved == "/private/var" || resolved.hasPrefix("/private/var/") {
            return String(resolved.dropFirst("/private".count))
        }
        if resolved == "/private/tmp" || resolved.hasPrefix("/private/tmp/") {
            return String(resolved.dropFirst("/private".count))
        }
        return resolved
    }

    /// 候选路径是否落在根之内（含根自身）。两侧归一化后按路径分量精确比较；
    /// 刻意不使用 TSPath.relative —— 它内部再次 standardizingPath，会对存在的
    /// 路径解析符号链接，破坏包含判定。
    public static func isWithin(candidate: String, root: String) -> Bool {
        let rootComponents = pathComponents(canonical(root))
        let candidateComponents = pathComponents(canonical(candidate))
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// 词法相对路径：path 落在 root 内时返回相对部分（path == root → ""），
    /// 否则 nil。两侧先 canonical 再按分量求差 —— 刻意不用 TSPath.relative，
    /// 它内部的 standardizingPath 会按「路径是否存在」改变拼写（见上）。
    public static func relative(path: String, root: String) -> String? {
        let rootComponents = pathComponents(canonical(root))
        let pathComponents = pathComponents(canonical(path))
        guard pathComponents.count >= rootComponents.count,
              Array(pathComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// lstat 判定目录：符号链接不进入递归（与 TS opendir.isSymbolicLink 语义一致）。
    public static func isDirectory(_ path: String) -> Bool {
        var s = lstatBuf()
        return lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
    }

    /// 不可作为递归扫描根的目录：文件系统根、当前用户主目录及其祖先。
    /// 这类目录一旦成为扫描根，「导入若干照片」就会退化为递归扫描整个卷或
    /// 主目录——历史缺陷正是由所选文件的公共父目录上溯到 home 触发的。
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

    /// 绝对路径的非空分量（"//a/b/" → ["a", "b"]）。
    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
