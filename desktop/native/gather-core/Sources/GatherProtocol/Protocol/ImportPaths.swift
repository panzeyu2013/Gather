// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ImportPaths.swift
// R7：从 GatherApplication/Services/SessionService.swift 下沉的导入路径规则。
//
// 这两个函数是 UI（Dashboard 的 C1 导入）与 Application（SessionService）共用的
// 纯规则；下沉后 UI 直调，不再经 ImportPathRules 端口/registry/Host 适配器。
import Foundation

/// 文件列表的公共父目录；空列表或根目录返回空串。仅用于给会话取名。
public func commonParentDirectory(filepaths: [String]) -> String {
    if filepaths.isEmpty { return "" }
    let directories = filepaths.map { TSPath.dirname(ScanPath.canonical($0)) }
    var candidate = directories[0]
    if directories.count > 1 {
        for directory in directories.dropFirst() {
            while candidate != TSPath.dirname(candidate),
                  !ScanPath.isWithin(candidate: directory, root: candidate) {
                candidate = TSPath.dirname(candidate)
            }
        }
    }
    if ScanPath.isForbiddenRoot(candidate) { return "" }
    return candidate
}

/// trim + 去空 + 归一化 + 去重（归一化走 ScanPath，与索引器同一口径）。
public func normalizeImportFilepaths(_ filepaths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for fp in filepaths {
        let trimmed = fp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let normalized = ScanPath.canonical(trimmed)
        if seen.insert(normalized).inserted { result.append(normalized) }
    }
    return result
}
