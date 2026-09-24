// desktop/native/gather-core/Sources/GatherCore/Metadata/MetadataConflictRules.swift
// TS 源: desktop/src/main/services/metadata/metadata-conflict-fields.ts（逐字移植，纯逻辑）
// 冲突检测：dirty-fields 解析 / 逐字段外部变更列表（冲突 UI 数据源）/ 快速布尔门控。

import Foundation

public enum MetadataConflictFields {
    /// TS: parseDirtyFields —— 损坏值产出空列表（调用方决定是否致命）。
    public static func parseDirtyFields(_ raw: String) -> [MetadataField] {
        tryParseDirtyFields(raw) ?? []
    }

    /// TS: tryParseDirtyFields —— 严格变体：存储 JSON 损坏时返回 nil，
    /// 调用方可大声失败而不是当作合法的空列表。
    public static func tryParseDirtyFields(_ raw: String) -> [MetadataField]? {
        guard let parsed = try? JSONValue.parse(raw), case .array(let items) = parsed else {
            return nil
        }
        // TS: filter(field => field === 'rating' || 'label' || 'keywords') ——
        // 未知字段被丢弃，合法数组（即使过滤后为空）返回非 nil。
        return items.compactMap { MetadataField(rawValue: $0.stringValue ?? "") }
    }

    /// TS: currentValue(field, current)。
    private static func currentValue(_ field: MetadataField, current: MetadataWriteAttributes) -> JSONValue {
        switch field {
        case .keywords:
            return .array(current.keywords?.map { .string($0) } ?? [])
        case .label:
            return .string(current.label ?? "")
        case .rating:
            return current.rating.map { .number($0) } ?? .null
        }
    }

    /// TS: baselineValue(field, base)。
    private static func baselineValue(_ field: MetadataField, base: JSONValue) -> JSONValue {
        switch field {
        case .keywords:
            let value = base["keywords"]
            return (value == nil || value == .null) ? .array([]) : value!
        case .label:
            let value = base["label"]
            return (value == nil || value == .null) ? .string("") : value!
        case .rating:
            // TS: return base.rating —— 缺失时是 undefined（JSON 序列化为 null）。
            return base["rating"] ?? .null
        }
    }

    /// TS: localValue(field, local)。
    private static func localValue(_ field: MetadataField, local: JSONValue) -> JSONValue {
        switch field {
        case .keywords:
            let value = local["keywords"]
            return (value == nil || value == .null) ? .array([]) : value!
        default:
            return local[field.rawValue] ?? .null
        }
    }

    /// TS: `JSON.stringify(a) === JSON.stringify(b)`（等价性比较；对象键序差异
    /// 在本层字段形状下不存在，JSONValue Equatable 即逐字语义）。
    private static func jsonEquals(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        lhs == rhs
    }

    /// TS: fieldConflicts —— 产生与待写变更冲突的外部改动逐字段列表（冲突 UI 驱动）。
    public static func fieldConflicts(
        base: JSONValue,
        local: JSONValue,
        current: MetadataWriteAttributes,
        dirtyFields: [MetadataField]
    ) -> [MetadataConflictField] {
        dirtyFields.compactMap { field in
            let baseline = baselineValue(field, base: base)
            let remote = currentValue(field, current: current)
            if jsonEquals(baseline, remote) { return nil }
            return MetadataConflictField(
                field: field,
                baseline: baseline,
                local: localValue(field, local: local),
                remote: remote
            )
        }
    }

    /// TS: hasFieldConflict —— 写入前快速布尔门控：任一 dirty 字段在磁盘上自
    /// 基线以来发生变更即为 true。刻意采用比 fieldConflicts 更严格的归一化
    /// （空串 == 缺失 label），避免缺失的基线 label 误报为冲突。
    public static func hasFieldConflict(
        base: JSONValue,
        current: MetadataWriteAttributes,
        dirtyFields: [MetadataField]
    ) -> Bool {
        dirtyFields.contains { field in
            switch field {
            case .rating:
                // TS: current.rating !== base.rating（JSON number 与非 number 恒不等）。
                return current.rating != base["rating"]?.numberValue
            case .label:
                return (current.label ?? "") != (base["label"]?.stringValue ?? "")
            case .keywords:
                let baseValue: JSONValue = {
                    let value = base["keywords"]
                    return (value == nil || value == .null) ? .array([]) : value!
                }()
                let currentValue = JSONValue.array(current.keywords?.map { .string($0) } ?? [])
                // TS: JSON.stringify 比较（混合元素数组也逐字比较）。
                let baseText = (try? JSONValue.stringify(baseValue)) ?? ""
                let currentText = (try? JSONValue.stringify(currentValue)) ?? ""
                return baseText != currentText
            }
        }
    }
}
