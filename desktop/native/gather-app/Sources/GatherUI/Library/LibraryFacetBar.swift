// desktop/native/gather-app/Sources/GatherUI/Library/LibraryFacetBar.swift
// P1 / C：Library 的 facet 栏（相机 / 镜头 / ISO / 年份 / 色标 / 关键词）。
// Wave2 / task-14：新增场景（scene）与人物（person）两维——scene 的桶值写进
// LibraryFilterState.scene（keyword_path 子树），person 复用既有"人物"文本字段。
//
// P1 下一波 §3.7.2：真正的实现已移到共享的 Filtering/FacetBar.swift（Gallery 复用同一份）；
// 本文件保留为**薄适配器**——init 签名（groups/filter/l10n/onCommit）与行为逐字不变，
// 因此 LibraryView+Filters 的调用点不需要修改。
//
// 适配语义：Library 的筛选状态是强类型字段（camera/lens/iso/year/label/keyword 字符串），
// keyword 维在 Library 侧映射到既有的"关键词文本"字段（扁平 contains 匹配），
// 不做层级下钻（Gallery 才用 keyword_path 下钻）。
import SwiftUI
import GatherProtocol

struct LibraryFacetBar: View {
    let groups: [PhotoFacetGroup]
    @Binding var filter: LibraryFilterState
    let l10n: L10n
    let onCommit: () -> Void

    var body: some View {
        FacetBar(
            groups: groups,
            selected: selectedValues,
            l10n: l10n,
            keywordNode: nil,
            onSelect: { dimension, value in
                set(dimension, value)
                onCommit()
            }
        )
    }

    private var selectedValues: [String: String] {
        [
            "camera": filter.camera,
            "lens": filter.lens,
            "iso": filter.iso,
            "year": filter.year,
            "label": filter.label,
            "keyword": filter.keyword,
            // Wave2 / task-14：scene 走 keyword_path 子树（不是扁平 keyword 文本），
            // person 复用图库既有的"人物"字段（contains 规则）。
            "scene": filter.scene,
            "person": filter.person,
        ]
    }

    private func set(_ dimension: String, _ value: String) {
        switch dimension {
        case "camera": filter.camera = value
        case "lens": filter.lens = value
        case "iso": filter.iso = value
        case "year": filter.year = value
        case "label": filter.label = value
        case "keyword": filter.keyword = value
        case "scene": filter.scene = value
        case "person": filter.person = value
        default: break
        }
    }
}
