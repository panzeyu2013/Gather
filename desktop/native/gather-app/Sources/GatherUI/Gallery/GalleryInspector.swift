// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryInspector.swift
// Cut 4 / 4c-2c：右侧检查器（筛选 / 显示）与三个选项控件，原 GalleryView.swift
// 96-104、277-323、344-395 行逐字搬移；macOS 14 .inspector 系统 API 形态不变。
import SwiftUI

extension GalleryView {
    /// TS: DENSITY_OPTIONS（行高密度）。计算属性：static let 只求值一次，
    /// 语言切换后会残留旧语言文案。
    private var densityOptions: [(value: Double, label: String)] {
        [
            (160, l10n("小图")),
            (220, l10n("中图")),
            (300, l10n("大图")),
        ]
    }

    /// TS: FILTER_OPTIONS —— 原生下拉（可访问名是真标签，不再是当前值）。
    /// 检查器分区「筛选」的行：走出工具栏后标签恢复可见（移除 .labelsHidden），
    /// 可访问名与提示原样保留。
    private var filterPicker: some View {
        Picker(l10n("筛选"), selection: $viewModel.filter) {
            Text(l10n("全部")).tag(GalleryFilter.all)
            Text(l10n("有人脸")).tag(GalleryFilter.hasFace)
            Text(l10n("无人脸")).tag(GalleryFilter.noFace)
            // D10：离线照片的可见筛选（控制中心「N 张照片离线」直达这里）。
            Text(l10n("离线")).tag(GalleryFilter.offline)
        }
        .pickerStyle(.menu)
        .help(l10n("筛选"))
        .accessibilityLabel(l10n("筛选"))
        .onChange(of: viewModel.filter) { _, _ in viewModel.filterOrVariantChanged() }
    }

    /// TS: DENSITY_OPTIONS —— 原生下拉（检查器分区「显示」的行）。
    private var densityPicker: some View {
        Picker(l10n("网格尺寸"), selection: $density) {
            ForEach(densityOptions, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .help(l10n("网格尺寸"))
        .accessibilityLabel(l10n("网格尺寸"))
    }

    /// TS Gallery.tsx:274-280 —— 变体展开开关。
    /// 旧版手绘「primarySoft 底 + 主色描边 + aria-pressed」→ 原生 Toggle；
    /// 检查器行用系统勾选样式（.button 图标胶囊只适合工具栏，标签不可读）。
    private var variantsToggle: some View {
        Toggle(isOn: $viewModel.expandVariants) {
            Label(l10n("展开所有变体"), systemImage: "rectangle.stack")
        }
        .help(
            viewModel.expandVariants
                ? l10n("折叠 RAW/JPEG")
                : l10n("展开所有变体")
        )
        .accessibilityLabel(l10n("展开所有变体"))
        .accessibilityValue(
            viewModel.expandVariants ? l10n("已展开") : l10n("已折叠")
        )
        .onChange(of: viewModel.expandVariants) { _, _ in viewModel.filterOrVariantChanged() }
    }

    // MARK: - 右侧检查器（浏览/筛选选项：筛选 / 显示）

    /// Bridge 右栏 / Capture One 工具页范式：内容区只留网格，浏览与筛选选项
    /// 进检查器。macOS 14 起 .inspector 是系统 API——工具栏右侧的显示/隐藏
    /// 按钮与列宽记忆都由系统提供，本页不自绘开关。
    ///
    /// 仅收拢页面已有状态的两组选项：
    /// - 筛选：viewModel.filter（全部 / 有人脸 / 无人脸）；
    /// - 显示：网格尺寸 density + 展开所有变体 viewModel.expandVariants。
    ///
    /// 评分与色标：GalleryViewModel 未暴露 rating/colorLabel 过滤状态
    ///（photo.list_page 行本身不含评分/色标字段，见本文件「写路径广播」注），
    /// 无可绑定模型 → 不设该分区（约束：不新增 ViewModel API）。
    var inspector: some View {
        // 约束循环修复（F01）：grouped Form 挂在 .inspector 上会在 AppKit 的
        // 约束更新阶段抛 NSGenericException（"more Update Constraints in Window
        // passes than there are views"）——LibraryView.libraryInspector 已记录
        // 同一崩溃栈并改为此形态，本页原先漏改。检查器只放「选项/管理」，
        // ScrollView + 卡片分组同样贴切。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorSection(l10n("筛选")) {
                    filterPicker
                }
                inspectorSection(l10n("显示")) {
                    VStack(alignment: .leading, spacing: 10) {
                        densityPicker
                        variantsToggle
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        // 同 CullingView：理想列宽会计入最小宽度，收窄以避免窄窗口下的约束循环。
        .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
    }

    /// 检查器里的一组选项：标题 + 内容，套系统分组容器（与 LibraryView.supportCard 同形）。
    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard(cornerRadius: GatherTheme.Radius.panel)
    }
}
