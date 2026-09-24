// desktop/native/gather-core/Sources/GatherCore/Runtime/Navigation/NavigationError.swift
// W2d-3b：自 Services/NavigationService.swift 机械搬迁（错误码/描述逐字不变）。

import Foundation

public enum NavigationError: Error, CustomStringConvertible {
    case burstGapInvalid
    case sceneGapInvalid
    case groupNotFound
    case splitOutOfGroup
    case mergeMinTwo
    case mergeTypeMismatch

    public var description: String {
        switch self {
        case .burstGapInvalid: return "NAV_BURST_GAP_INVALID"
        case .sceneGapInvalid: return "NAV_SCENE_GAP_INVALID"
        case .groupNotFound: return "NAV_GROUP_NOT_FOUND"
        case .splitOutOfGroup: return "NAV_SPLIT_OUT_OF_GROUP"
        case .mergeMinTwo: return "NAV_MERGE_MIN_TWO"
        case .mergeTypeMismatch: return "NAV_MERGE_TYPE_MISMATCH"
        }
    }
}
