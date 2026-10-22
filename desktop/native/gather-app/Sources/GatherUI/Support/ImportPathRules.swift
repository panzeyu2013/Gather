// desktop/native/gather-app/Sources/GatherUI/Support/ImportPathRules.swift
// Cut 3 / 3b-3（E-19 相邻）：导入路径规则端口。
//
// DashboardViewModel 的 Capture One 导入需要「归一化选中路径 + 公共父目录
// （仅取名）+ basename」；这三个纯函数的真相源在 gather-core
// （GatherDomain.normalizeImportFilepaths / commonParentDirectory、
// GatherPersistence.TSPath），GatherUI 不得 import 这两层。
//
// 端口 + 注册表的形状与 ImageDecoderRegistry 一致：GatherHost 启动时注册
// 一次，UI 只读。3b-4 记入剩余项：函数上移到 GatherProtocol 后可删除本文件。
import Foundation

/// 导入路径规则的只读能力面（实现必须是纯函数、Sendable）。
public protocol ImportPathRules: Sendable {
    /// trim + 去空 + canonical + 去重（与 GatherDomain 同名函数逐字一致）。
    func normalizedImportFilepaths(_ filepaths: [String]) -> [String]
    /// 文件列表的公共父目录；空列表/根目录返回空串（仅用于取名）。
    func importCommonParentDirectory(filepaths: [String]) -> String
    /// 路径 basename（TS path.basename）。
    func basename(_ path: String) -> String
}

/// 导入路径规则不可用（宿主未注册实现）。
public enum ImportPathRulesError: Error, Equatable, Sendable {
    case rulesUnavailable
}

/// 进程级规则注册表（与 ImageDecodingRegistry 同纪律：NSLock 串行化）。
public enum ImportPathRulesRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rules: (any ImportPathRules)?

    public static func install(_ rules: any ImportPathRules) {
        lock.lock()
        self.rules = rules
        lock.unlock()
    }

    public static func current() throws -> any ImportPathRules {
        lock.lock()
        let rules = self.rules
        lock.unlock()
        guard let rules else { throw ImportPathRulesError.rulesUnavailable }
        return rules
    }
}
