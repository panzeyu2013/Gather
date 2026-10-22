// desktop/native/gather-app/Sources/GatherHost/ImportPathRulesAdapter.swift
// Cut 3 / 3b-3（E-19 相邻）：gather-core 的导入路径纯函数 → GatherUI 端口。
//
// 只做模块限定转发，不复制逻辑：
//   · GatherDomain.normalizeImportFilepaths / commonParentDirectory
//     （Sources/GatherDomain/Services/SessionService.swift）
//   · GatherPersistence.TSPath.basename（RepositorySupport.swift）
import GatherDomain
import GatherPersistence
import GatherUI

public struct HostImportPathRules: ImportPathRules {
    public init() {}

    public func normalizedImportFilepaths(_ filepaths: [String]) -> [String] {
        normalizeImportFilepaths(filepaths)
    }

    public func importCommonParentDirectory(filepaths: [String]) -> String {
        commonParentDirectory(filepaths: filepaths)
    }

    public func basename(_ path: String) -> String {
        TSPath.basename(path)
    }
}
