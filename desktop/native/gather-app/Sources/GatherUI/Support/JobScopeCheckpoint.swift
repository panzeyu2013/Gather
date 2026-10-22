// desktop/native/gather-app/Sources/GatherUI/Support/JobScopeCheckpoint.swift
// Cut 3 / 3b-3（E-19 / E-20 收敛）：metadata.scan 的扫描范围 checkpoint 契约。
//
// 键名必须与 executor（GatherHost/ExecutorRegistry 的 metadata.scan）读取的键
// 逐字一致：非空数组 = 显式集合作用域；缺省/空 = 目录全树作用域。
//
// 该纯函数原先在 GatherHost/AppImport（3b-1 从 GatherApp 抽出），但
// DashboardViewModel（GatherUI）也要构造同一 checkpoint；UI 不能 import Host，
// 因此把真相源放在 UI，Host 侧 AppImport 直接委托本类型。
import Foundation
import GatherProtocol

public enum JobScopeCheckpoint {
    /// metadata.scan checkpoint 的扫描集合键。
    public static let requestedPathsKey = "requestedPaths"

    /// requestedPaths → checkpoint 载荷（nil/空 = 目录全树作用域）。
    public static func make(requestedPaths: [String]?) -> [String: JSONValue] {
        guard let requestedPaths, !requestedPaths.isEmpty else { return [:] }
        return [requestedPathsKey: .array(requestedPaths.map { .string($0) })]
    }
}
