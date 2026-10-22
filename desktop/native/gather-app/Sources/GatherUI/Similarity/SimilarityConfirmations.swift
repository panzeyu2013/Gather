// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityConfirmations.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出四个待确认上下文（原 21-87 行，
// private -> internal，供壳与写回面板共用）。纯搬移：影响范围文案模板、
// 可选示例路径与固定指引的组合方式逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 破坏性动作确认上下文（sim.writeback / sim.retry_failed_writeback / sim.cleanup）

/// 写回确认：影响范围 = 组数 / 照片数 / 关键词 / XMP 项与示例路径。
struct PendingSimilarityWriteback: Identifiable {
    let groupCount: Int
    let affectedPhotos: Int
    let itemCount: Int
    let keywords: [String]
    let samplePath: String?

    var id: String { "writeback-\(itemCount)-\(affectedPhotos)" }

    /// Cut 4 / 4b-2c：三段在渲染期组合（模板 + 可选示例 + 固定指引），
    /// 不再用 += 拼接已本地化的字符串。
    func scopeText(with l10n: L10n) -> String {
        var parts = [
            l10n.format(
                "将 %lld 个相似组、%lld 张照片的关键词「%@」合并写入 XMP（共 %lld 个文件，新建或更新），不修改原图。",
                groupCount, affectedPhotos, keywords.joined(separator: "、"), itemCount
            )
        ]
        if let samplePath, !samplePath.isEmpty {
            parts.append(l10n.format("例如：%@。", samplePath))
        }
        parts.append(l10n("取消不会写入任何文件。"))
        return parts.joined()
    }
}

/// 重试失败项确认：范围 = 失败项数量与路径。
struct PendingSimilarityRetry: Identifiable {
    let paths: [String]

    var id: String { "retry-\(paths.count)-\(paths.first ?? "")" }

    func scopeText(with l10n: L10n) -> String {
        let sample = paths.prefix(3).joined(separator: l10n("、"))
        let more = paths.count > 3 ? l10n(" 等") : ""
        return l10n.format(
            "将重试写入 %lld 个失败项：%@%@。取消不会重写任何文件。",
            paths.count, sample, more
        )
    }
}

/// 清理确认：范围 = 本次已写入的 XMP 项数。
struct PendingSimilarityCleanup: Identifiable {
    let writtenCount: Int

    var id: String { "cleanup-\(writtenCount)" }

    func scopeText(with l10n: L10n) -> String {
        l10n.format(
            "将恢复或移除本次相似度写回生成的 %lld 个临时 XMP sidecar 文件；只应在 Capture One 已加载元数据并确认同步后执行。取消不会改动任何文件。",
            writtenCount
        )
    }
}

/// 确认同步：用户在弹窗中声明 Capture One 已完成 Load Metadata。
struct PendingSimilarityConfirmSync: Identifiable {
    var id: String { "confirm-sync" }

    func scopeText(with l10n: L10n) -> String {
        l10n("确认后 Gather 认为 Capture One 已读取 XMP 临时变更，之后才可执行清理。若尚未在 Capture One 中执行「加载元数据」，请取消。")
    }
}
