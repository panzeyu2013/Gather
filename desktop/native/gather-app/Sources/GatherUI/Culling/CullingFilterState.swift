// desktop/native/gather-app/Sources/GatherUI/Culling/CullingFilterState.swift
// 挑片页的筛选/范围/目标索引值类型（#6 S1c：从 CullingViewModel 里提到顶层）。
//
// 这些是纯值：筛选条件、范围模式、关键词目标索引。提到顶层后，筛选逻辑与
// VM 解耦（此前是嵌套类型，任何使用都要写长限定名）。
import Foundation
import GatherProtocol

struct KeywordTargetIndex {
    let key: String
    let union: [String]
    let counts: [String: Int]
}

public struct FilterState: Equatable {
    public var unreviewedOnly = false
    public var pickState: PickState?
    public var rating: Int?
    public var colorLabel: CaptureOneColorLabel?
    public var qualityStatus: CullingFilterQualityStatus?
    public var metadataConflictOnly = false
    /// P0/T0：按建议 verdict 过滤（仅 .filtered scope 生效）。
    public var triageVerdicts: [TriageVerdict]?

    public init() {}

    public var isActive: Bool {
        unreviewedOnly || pickState != nil || rating != nil || colorLabel != nil
            || qualityStatus != nil || metadataConflictOnly
            || (triageVerdicts?.isEmpty == false)
    }
}

public enum ScopeMode: String, CaseIterable, Equatable {
    case all
    case filtered
    case similarityGroup

    /// Cut 4 / 4b-2a：只存 key，渲染期由 View 的 l10n 解析（切语言即换文案）。
    var title: LocalizedText {
        switch self {
        case .all: return LocalizedText("全部照片")
        case .filtered: return LocalizedText("按筛选")
        case .similarityGroup: return LocalizedText("相似度分组")
        }
    }
}
