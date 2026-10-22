// desktop/native/gather-core/Sources/GatherProtocol/Protocol/FilterValue.swift
// FilterEngine 的 SQL 参数值：只暴露 Protocol 类型，避免 Application 的 public
// WhereClauseResult 泄漏 GatherPersistence.DBValue。
import Foundation

public enum FilterValue: Equatable, Sendable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
