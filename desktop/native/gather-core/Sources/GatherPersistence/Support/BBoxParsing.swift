// desktop/native/gather-core/Sources/GatherPersistence/Support/BBoxParsing.swift
// 人脸检测框 JSON 解析的唯一实现（B05-2）。
//
// 合并背景：合并前 FaceRepo（GatherPersistence）与 FaceKwService+Review
// （GatherApplication）各有一份逐字相同的私有 parseBbox。本文件是唯一实现，
// 两个调用点删除副本后直接调用。
//
// 不变量：输入是 face_observations.bbox 的 JSON 文本（TS 侧 JSON.parse(m.bbox)）；
// 解析失败或顶层不是数组时返回 []，数组内非 number 元素被跳过（不抛错）。
import GatherProtocol

/// TS: JSON.parse(m.bbox) —— bbox 文本（如 `[1,2,3,4]`）→ Double 数组。
public func parseBbox(_ raw: String) -> [Double] {
    guard let value = try? JSONValue.parse(raw), case .array(let items) = value else { return [] }
    return items.compactMap {
        if case .number(let v) = $0 { return v }
        return nil
    }
}
