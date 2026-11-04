// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataText.swift
// JSONValue → 文本的两个自由函数（#6 S3：从 MetadataService 文件尾移出，供抽取服务共用）。
//
// 保持 internal：它们只在本模块内使用，进 GatherProtocol 会涨公开面。
import Foundation
import GatherProtocol


/// TS: `value ? String(value) : undefined`（exif 段标量字符串化）。
func stringValue(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    if let string = value.stringValue { return string }
    if let number = value.numberValue { return keywordString(number) }
    return nil
}

/// TS: `String(item)` —— JS Number 字符串化语义：整数值不带小数点（7 → "7"，-0 → "0"），
/// NaN/±Infinity 同 JS 命名；非整数保留 Double 字符串形式（7.5 → "7.5"）。
/// 关键词归一化（normalizeKeywordList）与 EXIF 标量字符串化（stringValue）共用同一口径。
func keywordString(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
    if let integer = Int64(exactly: number) { return String(integer) }
    return String(number)
}
