// desktop/native/gather-app/Sources/GatherApp/Shell/AppShellView.swift
// R6 步骤一：UI Shell 骨架（只新建 app 侧文件；不改 Host 路由层文件，不碰 core）。
// R6 步骤二：接入选中的特性视图——左侧 Feature 列表选择，右侧按所选 case
// 渲染；设置与人脸库两个 case 指向真实视图，其余仍为占位 Text。依赖由 init
// 以可选形式注入，壳层不自行构造路由或数据层。
//
// 本步骤只建立壳层根视图骨架：按 app 目录名枚举 11 个特性，逐项输出占位
// Text，并在每项上标注 R6 后续要替换成的特性视图。业务代码一律不改；
// 现有根视图 RootView 本轮保持原样（替换点与迁移顺序见 R6 报告）。
import SwiftUI

/// 壳层根视图骨架：左侧列出 app 目录中的 11 个特性，右侧渲染所选 Case；
/// 当前仅「设置」与「人脸库」接真实视图，其余仍为占位 Text。
public struct AppShellView: View {
    /// app 目录枚举出的 11 个特性（顺序即建议的 R6 迁移顺序）。
    public enum Feature: String, CaseIterable, Identifiable, Sendable {
        // Sources/GatherApp/Dashboard -> 将替换为 DashboardView。
        case dashboard
        // Sources/GatherApp/Library -> 将替换为 LibraryView。
        case library
        // Sources/GatherApp/Gallery -> 将替换为 GalleryView。
        case gallery
        // Sources/GatherApp/Similarity -> 将替换为 SimilarityView。
        case similarity
        // Sources/GatherApp/Persons -> 将替换为 PersonsView。
        case persons
        // Settings -> 将替换为 SettingsView。
        case settings
        // ControlCenter -> 将替换为 SessionControlView（工作区页签）。
        case controlCenter
        // FaceKeywording -> 将替换为 FaceKeywordingView（工作区页签）。
        case faceKeywording
        // Duplicates -> 将替换为 DuplicatesView（工作区页签）。
        case duplicates
        // Culling -> 将替换为 CullingView（工作区页签）。
        case culling
        // Export -> 将替换为 ExportView（工作区页签）。
        case export

        public var id: String { rawValue }

        /// 特性目录名（app 目录名，与 Package.swift 的 sources 一致）。
        public var directoryName: String {
            switch self {
            case .dashboard: return "Sources/GatherApp/Dashboard"
            case .library: return "Sources/GatherApp/Library"
            case .gallery: return "Sources/GatherApp/Gallery"
            case .similarity: return "Sources/GatherApp/Similarity"
            case .persons: return "Sources/GatherApp/Persons"
            case .settings: return "Settings"
            case .controlCenter: return "ControlCenter"
            case .faceKeywording: return "FaceKeywording"
            case .duplicates: return "Duplicates"
            case .culling: return "Culling"
            case .export: return "Export"
            }
        }

        /// 将替换本占位项的现有特性视图名（骨架期仅展示，不实例化）。
        public var replacementViewName: String {
            switch self {
            case .dashboard: return "DashboardView"
            case .library: return "LibraryView"
            case .gallery: return "GalleryView"
            case .similarity: return "SimilarityView"
            case .persons: return "PersonsView"
            case .settings: return "SettingsView"
            case .controlCenter: return "SessionControlView"
            case .faceKeywording: return "FaceKeywordingView"
            case .duplicates: return "DuplicatesView"
            case .culling: return "CullingView"
            case .export: return "ExportView"
            }
        }

        /// 壳层显示名：沿用侧栏/页签既有文案，不新造术语。
        public var displayName: String {
            switch self {
            case .dashboard: return GatherLocalization.l("工作台")
            case .library: return GatherLocalization.l("全局图库")
            case .gallery: return GatherLocalization.l("浏览")
            case .similarity: return GatherLocalization.l("相似度")
            case .persons: return GatherLocalization.l("人脸库")
            case .settings: return GatherLocalization.l("设置")
            case .controlCenter: return GatherLocalization.l("控制中心")
            case .faceKeywording: return GatherLocalization.l("人脸")
            case .duplicates: return GatherLocalization.l("重复")
            case .culling: return GatherLocalization.l("挑片")
            case .export: return GatherLocalization.l("导出")
            }
        }
    }

    /// 设置页需要的命令路由（可选：未注入时该特性回退占位）。
    private let settingsRouter: CommandRouter?
    /// 人脸库需要的数据提供者（可选：未注入时该特性回退占位）。
    private let personsProvider: PersonsDataProvider?
    /// 当前选中的特性：左侧列表点击切换，右侧渲染对应视图。
    @State private var selectedFeature: Feature = .dashboard
    /// 人脸库视图模型：仅在注入数据提供者时创建，壳层不自行取数。
    @State private var personsViewModel: PersonsViewModel?

    /// 依赖经 init 以可选形式传入；两个参数都有默认值，既有调用点不受影响。
    @MainActor
    public init(settingsRouter: CommandRouter? = nil, personsProvider: PersonsDataProvider? = nil) {
        self.settingsRouter = settingsRouter
        self.personsProvider = personsProvider
        if let personsProvider {
            _personsViewModel = State(initialValue: PersonsViewModel(provider: personsProvider))
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            featureList
            Divider()
            detailView(for: selectedFeature)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480, alignment: .topLeading)
    }

    /// 左侧特性列表：点击切换当前特性，已接真实视图的项在右侧直接打开。
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gather")
                .font(.title2.weight(.semibold))
            Text(GatherLocalization.l("壳层骨架：11 个特性，已接真实视图的项可直接打开"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Feature.allCases) { feature in
                        featureRow(feature)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    private func featureRow(_ feature: Feature) -> some View {
        let isSelected = selectedFeature == feature
        return Button {
            selectedFeature = feature
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(feature.displayName)
                    .font(.body.weight(isSelected ? .semibold : .medium))
                Text(feature.directoryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(isWired(feature) ? feature.replacementViewName : "-")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 是否已接真实视图：R6 步骤二仅「设置」与「人脸库」两项。
    private func isWired(_ feature: Feature) -> Bool {
        switch feature {
        case .settings: return settingsRouter != nil
        case .persons: return personsViewModel != nil
        default: return false
        }
    }

    /// 右侧详情：private switch 只把「设置」与「人脸库」指向真实视图，
    /// 其余 case 仍为占位 Text；依赖缺失时同样回退占位，保持可编译。
    @ViewBuilder
    private func detailView(for feature: Feature) -> some View {
        switch feature {
        case .settings:
            if let settingsRouter {
                SettingsView(router: settingsRouter)
            } else {
                placeholderView(for: feature)
            }
        case .persons:
            if let personsViewModel {
                PersonsView(viewModel: personsViewModel)
            } else {
                placeholderView(for: feature)
            }
        default:
            placeholderView(for: feature)
        }
    }

    private func placeholderView(for feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.displayName)
                .font(.title3.weight(.semibold))
            Text(String(format: GatherLocalization.l("占位：待接入 %@"), feature.replacementViewName))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}
