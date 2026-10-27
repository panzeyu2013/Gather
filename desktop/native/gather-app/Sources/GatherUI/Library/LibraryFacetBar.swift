// desktop/native/gather-app/Sources/GatherUI/Library/LibraryFacetBar.swift
// P1 / C：facet 栏（相机 / 镜头 / ISO / 年份 / 色标）。
//
// 交互模型（与 Lightroom / Bridge 一致）：
// - 同一维单选（点第二次取消），跨维取交集；
// - 计数由服务端按"排除自身维度"计算，因此选机身 A 之后镜头 facet 仍显示全部镜头；
// - 点选立即提交筛选（onCommit），不参与搜索框的防抖。
import SwiftUI
import GatherProtocol

struct LibraryFacetBar: View {
    let groups: [PhotoFacetGroup]
    @Binding var filter: LibraryFilterState
    let l10n: L10n
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleGroups, id: \.dimension) { group in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title(group.dimension))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(group.buckets, id: \.value) { bucket in
                                chip(group.dimension, bucket)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 只展示有内容的维度；每维最多 12 个桶，但**已选值必须可见**
    /// （长尾维度里排 12 名之外的选中项否则无法取消）。
    private var visibleGroups: [PhotoFacetGroup] {
        groups.filter { !$0.buckets.isEmpty }.map { group in
            var buckets = Array(group.buckets.prefix(12))
            let active = currentValue(group.dimension)
            if !active.isEmpty, !buckets.contains(where: { $0.value == active }),
               let selected = group.buckets.first(where: { $0.value == active }) {
                buckets.insert(selected, at: 0)
                if buckets.count > 13 { buckets.removeLast() }
            }
            return PhotoFacetGroup(dimension: group.dimension, buckets: buckets)
        }
    }

    private func title(_ dimension: String) -> String {
        switch dimension {
        case "camera": l10n("相机")
        case "lens": l10n("镜头")
        case "iso": l10n("ISO")
        case "year": l10n("年份")
        case "label": l10n("色标")
        default: l10n(dimension)
        }
    }

    private func chip(_ dimension: String, _ bucket: PhotoFacetBucket) -> some View {
        let isActive = currentValue(dimension) == bucket.value
        return Button {
            set(dimension, isActive ? "" : bucket.value)
            onCommit()
        } label: {
            Text("\(bucket.value) · \(bucket.count)")
                .font(.caption2)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? GatherTheme.accent.opacity(0.18) : GatherTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isActive ? GatherTheme.accent : GatherTheme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
        .help(l10n.format("按 %@ 筛选", bucket.value))
    }

    private func currentValue(_ dimension: String) -> String {
        switch dimension {
        case "camera": filter.camera
        case "lens": filter.lens
        case "iso": filter.iso
        case "year": filter.year
        case "label": filter.label
        default: ""
        }
    }

    private func set(_ dimension: String, _ value: String) {
        switch dimension {
        case "camera": filter.camera = value
        case "lens": filter.lens = value
        case "iso": filter.iso = value
        case "year": filter.year = value
        case "label": filter.label = value
        default: break
        }
    }
}
