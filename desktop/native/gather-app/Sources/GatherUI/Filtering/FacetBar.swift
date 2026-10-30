// desktop/native/gather-app/Sources/GatherUI/Filtering/FacetBar.swift
// P1 下一波 §3.7.2：facet 栏（Library 与 Gallery 共用的唯一实现）。
//
// 交互模型（与 Lightroom / Bridge 一致）：
// - 同一维单选（点第二次 = 取消），跨维取交集；
// - 计数由服务端按"排除自身维度"计算，因此选机身 A 之后镜头 facet 仍显示全部镜头；
// - 点选立即提交（onSelect），不参与搜索框的防抖；
// - keyword 维特殊：值即层级路径（"A|B"），点选 = 选中该路径 + 下钻（面板改列子级）；
//   传 keywordNode 时额外显示"↑ 上级"胶囊用于回退。
//
// 与 Library/ 旧实现的关系：本文件是原 LibraryFacetBar 的泛化版（状态改为
// [维度: 值] 字典 + 回调），LibraryFacetBar 保留为薄适配器（API 兼容）。
import SwiftUI
import GatherProtocol

struct FacetBar: View {
    /// 服务端返回的每维桶（空桶维度不显示）。
    let groups: [PhotoFacetGroup]
    /// 当前选中值（dimension → value；"" = 未选）。
    let selected: [String: String]
    let l10n: L10n
    /// keyword 维当前下钻节点（nil = 顶级）。
    let keywordNode: String?
    /// (dimension, value)；value == "" 表示清除该维。
    let onSelect: (String, String) -> Void

    /// 每维最多展示的桶数；**已选值必须可见**（长尾维度里排 12 名之外的选中项
    /// 否则无法取消）。
    private static let bucketLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.controlGap) {
            ForEach(visibleGroups, id: \.dimension) { group in
                HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
                    Text(title(group.dimension))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: GatherMetrics.Space.xs) {
                            if group.dimension == "keyword" {
                                keywordBreadcrumbChip
                            }
                            ForEach(group.buckets, id: \.value) { bucket in
                                chip(group.dimension, bucket)
                            }
                        }
                    }
                }
            }
        }
    }

    /// keyword 维的"返回上级"胶囊（只在已经下钻时出现）。
    @ViewBuilder
    private var keywordBreadcrumbChip: some View {
        if let node = keywordNode, !node.isEmpty {
            Button {
                let parent = KeywordPath(node)?.parent?.serialized ?? ""
                onSelect("keyword", parent)
            } label: {
                Label(l10n("上级"), systemImage: "arrow.up.left")
                    .font(.caption2)
                    .padding(.horizontal, GatherMetrics.Space.controlGap)
                    .padding(.vertical, GatherMetrics.Space.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(GatherTheme.surfaceMuted))
            }
            .buttonStyle(.borderless)
            .help(l10n("返回上一级关键词"))
        }
    }

    private var visibleGroups: [PhotoFacetGroup] {
        groups.filter { !$0.buckets.isEmpty }.map { group in
            var buckets = Array(group.buckets.prefix(Self.bucketLimit))
            let active = selected[group.dimension] ?? ""
            if !active.isEmpty, !buckets.contains(where: { $0.value == active }),
               let picked = group.buckets.first(where: { $0.value == active }) {
                buckets.insert(picked, at: 0)
                if buckets.count > Self.bucketLimit + 1 { buckets.removeLast() }
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
        case "keyword": l10n("关键词")
        default: l10n(dimension)
        }
    }

    private func chip(_ dimension: String, _ bucket: PhotoFacetBucket) -> some View {
        let isActive = (selected[dimension] ?? "") == bucket.value
        return Button {
            onSelect(dimension, isActive ? "" : bucket.value)
        } label: {
            Text("\(bucket.value) · \(bucket.count)")
                .font(.caption2)
                .monospacedDigit()
                .padding(.horizontal, GatherMetrics.Space.controlGap)
                .padding(.vertical, GatherMetrics.Space.xxs)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? GatherTheme.accent.opacity(0.18) : GatherTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isActive ? GatherTheme.accent : GatherTheme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
        .help(l10n.format("按 %@ 筛选", bucket.value))
    }
}
