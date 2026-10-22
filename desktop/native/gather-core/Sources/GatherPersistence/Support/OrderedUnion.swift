// desktop/native/gather-core/Sources/GatherPersistence/Support/OrderedUnion.swift
// 有序并集的唯一实现（B05-1）。
//
// 合并背景：合并前 LiveSimilarityAPI（GatherHost）、FaceKwService+Writeback
// （GatherApplication）、WritebackService（GatherDelivery）各自持有一份私有
// orderedUnion：前两份逐字等价（Set 去重）；第三份用 `merged.contains` 判重，
// 语义相同但 O(n²)。本文件是唯一实现，三个调用点删除副本后直接调用，语义逐点不变。
//
// 不变量：等价于 TS `[...new Set([...a, ...b])]`——先左后右、按首次出现保序、
// 空数组也返回空数组；不修改入参。
/// 保序并集：左数组在前，右数组中的新元素按首次出现顺序追加。
public func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in lhs + rhs where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}
