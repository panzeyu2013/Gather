// desktop/native/gather-core/Sources/GatherProtocol/API/Core/Validation.swift
// Cut 1 / 阶段 1A：输入类型共享的校验原语（内部实现，不对外暴露）。
//
// 职责：把 Router 的 requiredString/validatedString/requiredNumber/clampedLimit
// 等校验收敛成显式失败（D-012）：
// - 非有限数值、Int 截断、未知枚举、非法数组元素一律抛 GatherError，
//   不复刻 optionalNumber 的静默 nil / groupingMode 的静默 global。
// 校验归属：仅输入类型 init / init(from:) 使用；API 实现不得再重复解析 JSON。

import Foundation

enum APIValidation {
    /// 非空白字符串：trim 后非空，长度上限内。返回 trim 后的值。
    static func nonBlank(_ value: String, field: String, maxLength: Int = 4096) throws -> String {
        try bounded(value, field: field, maxLength: maxLength, allowEmpty: false)
    }

    /// 长度受限字符串；allowEmpty=false 时 trim 并拒绝空白。
    static func bounded(
        _ value: String,
        field: String,
        maxLength: Int,
        allowEmpty: Bool
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        if allowEmpty { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return trimmed
    }

    /// 非空数组 + 可选数量上限。
    static func nonEmpty<T>(_ values: [T], field: String, maxCount: Int? = nil) throws -> [T] {
        guard !values.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must be a non-empty array")
        }
        if let maxCount, values.count > maxCount {
            throw GatherError.invalidParameter(
                field: field,
                reason: "count must be at most \(maxCount)"
            )
        }
        return values
    }

    /// 照片/文件路径：非空且 <= 4096（与旧 requirePhotoPath 的长度边界一致）。
    static func path(_ value: String, field: String = "path") throws -> String {
        guard !value.isEmpty, value.count <= 4096 else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "path must be non-empty and at most 4096 characters"
            )
        }
        return value
    }

    /// 有限数值（拒绝 NaN / ±∞）。
    static func finite(_ value: Double, field: String) throws -> Double {
        guard value.isFinite else {
            throw GatherError.invalidParameter(field: field, reason: "must be a finite number")
        }
        return value
    }

    /// Double -> Int：必须是给定区间内的整数（拒绝小数/NaN/∞/越界，不做截断）。
    static func integer(_ value: Double, field: String, in range: ClosedRange<Int>) throws -> Int {
        guard value.isFinite, value.rounded() == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound)
        else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "must be an integer in \(range.lowerBound)...\(range.upperBound)"
            )
        }
        return Int(value)
    }

    static func integerInRange(_ value: Int, field: String, _ range: ClosedRange<Int>) throws -> Int {
        guard range.contains(value) else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "must be an integer in \(range.lowerBound)...\(range.upperBound)"
            )
        }
        return value
    }

    static func nonNegative(_ value: Int, field: String) throws -> Int {
        guard value >= 0 else {
            throw GatherError.invalidParameter(field: field, reason: "must be non-negative")
        }
        return value
    }

    static func positive(_ value: Int, field: String) throws -> Int {
        guard value >= 1 else {
            throw GatherError.invalidParameter(field: field, reason: "must be positive")
        }
        return value
    }
}
