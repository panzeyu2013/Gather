// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/ContractTestSupport.swift
// Protocol 契约测试共享 helper（P1 机械收口 + P2 参数化）：
// - jsonKeys / jsonObject：JSON 顶层键提取（键名与 TS 字段逐字对账）；
// - assertRoundTrip / assertJSONKeys：契约 DTO 的「encode → decode 值相等 + 顶层键集合冻结」模板。
//   原来每个 DTO 各写一例 roundtrip + 一例 keys，现由各契约文件合并成一个用例逐样本调用；
//   失败说明带契约类型/样本名，合并后仍能定位到具体 DTO。
//
// 行为与各本地副本逐字等价：非法 JSON / 非对象 JSON 抛 ContractTestError.invalidJSON；
// jsonKeys 是 jsonObject 的键视图（4 个文件原本就直接复用 jsonObject 做值断言）。
import Foundation
import Testing

/// 解析 JSON 对象的顶层键（契约测试断言「键名与 TS 字段逐字一致」）。
func jsonKeys(of data: Data) throws -> [String] {
    Array(try jsonObject(of: data).keys)
}

/// 解析 JSON 对象（键提取与值断言共用；非对象 JSON 显式失败）。
func jsonObject(of data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ContractTestError.invalidJSON
    }
    return object
}

enum ContractTestError: Error, CustomStringConvertible {
    case invalidJSON
    case roundTripFailed(name: String, phase: String, underlying: any Error)

    var description: String {
        switch self {
        case .invalidJSON:
            return "JSON 顶层不是对象（契约测试要求 object）"
        case let .roundTripFailed(name, phase, underlying):
            return "\(name) 契约 \(phase) 失败：\(underlying)"
        }
    }
}

// MARK: - 契约往返模板（P2 合并用例后逐样本调用）
/// 契约测试通用模板：encode → decode 值相等 + 顶层 JSON 键集合与 TS 字段名逐字一致。
/// 合并用例后逐样本调用，`name` 进失败说明，仍能定位到具体契约类型/样本。
/// keys/forbiddenKeys 承载原用例的全部键断言（保留为期望值），verify 承载值级附加断言；
/// 返回编码后的 JSON，供调用方追加嵌套键等断言。
@discardableResult
func assertRoundTrip<T: Codable & Equatable>(
    _ original: T,
    keys: [String],
    name: String? = nil,
    forbiddenKeys: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation,
    verify: ((T) throws -> Void)? = nil
) throws -> Data {
    let (data, decoded) = try roundTripContract(original, name: name, sourceLocation: sourceLocation)
    try checkContractKeys(data, keys: keys, name: name, forbiddenKeys: forbiddenKeys,
                          sourceLocation: sourceLocation)
    if let verify { try verify(decoded) }
    return data
}

/// 「仅往返」版本：不锁顶层键集合，保留调用方自己的键/值断言。
@discardableResult
func assertRoundTrip<T: Codable & Equatable>(
    _ original: T,
    name: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Data {
    try roundTripContract(original, name: name, sourceLocation: sourceLocation).data
}

/// 仅冻结顶层 JSON 键集合（不做往返断言）：用于 TS 可选字段「省略/恒存在」的形状断言；
/// keys 为精确期望键集合（nil = 只做 forbidden/required 两类附加断言，保持原用例强度）。
@discardableResult
func assertJSONKeys<T: Encodable>(
    _ value: T,
    keys: [String]? = nil,
    name: String? = nil,
    forbiddenKeys: [String] = [],
    requiredKeys: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Set<String> {
    let label = name ?? String(describing: T.self)
    let data = try encodeContractValue(value, name: label)
    return try checkContractKeys(data, keys: keys, name: label, forbiddenKeys: forbiddenKeys,
                                 requiredKeys: requiredKeys, sourceLocation: sourceLocation)
}

// MARK: - 内部实现（出错时带上契约名，合并用例后 encode/decode 抛错也能定位）

private func roundTripContract<T: Codable & Equatable>(
    _ original: T,
    name: String?,
    sourceLocation: SourceLocation
) throws -> (data: Data, decoded: T) {
    let label = name ?? String(describing: T.self)
    let data = try encodeContractValue(original, name: label)
    let decoded = try decodeContractValue(T.self, from: data, name: label)
    #expect(decoded == original, "\(label) JSON 往返必须还原原值", sourceLocation: sourceLocation)
    return (data, decoded)
}

@discardableResult
private func checkContractKeys(
    _ data: Data,
    keys: [String]?,
    name: String?,
    forbiddenKeys: [String],
    requiredKeys: [String] = [],
    sourceLocation: SourceLocation
) throws -> Set<String> {
    let label = name ?? "契约 DTO"
    let actual = Set(try contractKeys(of: data, name: label))
    if let keys {
        let expected = Set(keys)
        let missing = expected.subtracting(actual).sorted()
        let extra = actual.subtracting(expected).sorted()
        #expect(
            actual == expected,
            "\(label) JSON key 必须与 TS 字段名一致（缺: \(missing)；多: \(extra)）",
            sourceLocation: sourceLocation
        )
    }
    let leaked = forbiddenKeys.filter { actual.contains($0) }.sorted()
    #expect(leaked.isEmpty, "\(label) 不得出现键 \(leaked)", sourceLocation: sourceLocation)
    let absent = requiredKeys.filter { !actual.contains($0) }.sorted()
    #expect(absent.isEmpty, "\(label) 缺少必需键 \(absent)", sourceLocation: sourceLocation)
    return actual
}

private func encodeContractValue<T: Encodable>(_ value: T, name: String) throws -> Data {
    do {
        return try JSONEncoder().encode(value)
    } catch {
        throw ContractTestError.roundTripFailed(name: name, phase: "encode", underlying: error)
    }
}

private func decodeContractValue<T: Decodable>(_ type: T.Type, from data: Data, name: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw ContractTestError.roundTripFailed(name: name, phase: "decode", underlying: error)
    }
}

private func contractKeys(of data: Data, name: String) throws -> [String] {
    do {
        return try jsonKeys(of: data)
    } catch {
        throw ContractTestError.roundTripFailed(name: name, phase: "jsonKeys", underlying: error)
    }
}
