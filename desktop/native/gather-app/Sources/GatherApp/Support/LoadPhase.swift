// desktop/native/gather-app/Sources/GatherApp/Support/LoadPhase.swift
// 四个列表/详情视图模型（Dashboard/Library/Gallery/Persons）曾各写一份逐字相同的
// 嵌套枚举；相位语义完全一致，收敛为单一类型，避免同一状态机四处漂移。
import Foundation

/// 首屏加载三态：loading → loaded / failed(用户可见文案)。
/// 空态不是一种相位：由各 VM 的数据数组（photos/persons）或派生文案
/// （GalleryViewModel.indexHeaderCopy 返回 nil 即整行不渲染）表达。
public enum LoadPhase: Equatable {
    case loading
    case loaded
    case failed(String)
}
