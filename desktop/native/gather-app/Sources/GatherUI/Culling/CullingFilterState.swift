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

// MARK: - B3 / 浏览状态恢复：FilterState ↔ 存档纯值

extension FilterState {
    /// 从存档恢复筛选：非法 raw / 越界 rating 逐项丢弃，不整份失败
    /// （存档损坏时用户宁可少一个筛选条件，也不能进不了页）。
    init(restored saved: CullingViewFilters) {
        self.init()
        unreviewedOnly = saved.unreviewedOnly
        pickState = saved.pickState.flatMap(PickState.init(rawValue:))
        if let rating = saved.rating, (0...5).contains(rating) {
            self.rating = rating
        }
        colorLabel = saved.colorLabel.flatMap(CaptureOneColorLabel.init(rawValue:))
        qualityStatus = saved.qualityStatus.flatMap(CullingFilterQualityStatus.init(rawValue:))
        metadataConflictOnly = saved.metadataConflictOnly
        let verdicts = saved.triageVerdicts?.compactMap(TriageVerdict.init(rawValue:))
        triageVerdicts = (verdicts?.isEmpty == false) ? verdicts : nil
    }

    /// 落盘投影：只存 raw 字符串，避免把 UI 枚举写进存档格式。
    var savedViewFilters: CullingViewFilters {
        var saved = CullingViewFilters()
        saved.unreviewedOnly = unreviewedOnly
        saved.pickState = pickState?.rawValue
        saved.rating = rating
        saved.colorLabel = colorLabel?.rawValue
        saved.qualityStatus = qualityStatus?.rawValue
        saved.metadataConflictOnly = metadataConflictOnly
        saved.triageVerdicts = triageVerdicts?.map(\.rawValue)
        return saved
    }
}
