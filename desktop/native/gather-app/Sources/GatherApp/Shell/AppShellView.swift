// desktop/native/gather-app/Sources/GatherApp/Shell/AppShellView.swift
// R6 步骤一：UI Shell 骨架（只新建 app 侧文件；不改 Host 路由层文件，不碰 core）。
//
// 本步骤只建立壳层根视图骨架：按 app 目录名枚举 11 个特性，逐项输出占位
// Text，并在每项上标注 R6 后续要替换成的特性视图。业务代码一律不改；
// 现有根视图 RootView 本轮保持原样（替换点与迁移顺序见 R6 报告）。
import SwiftUI

/// 壳层根视图骨架：纵向列出 app 目录中的 11 个特性，每项为占位 Text。
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

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gather")
                .font(.title2.weight(.semibold))
            Text(GatherLocalization.l("壳层骨架：11 个特性占位，后续替换为原生视图"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Feature.allCases) { feature in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            // 占位 Text：R6 后续替换为 feature.replacementViewName 指定的特性视图。
                            Text(feature.displayName)
                                .font(.body.weight(.medium))
                            Text(feature.directoryName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(feature.replacementViewName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480, alignment: .topLeading)
    }
}
