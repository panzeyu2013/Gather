// desktop/native/gather-core/Sources/GatherCore/Services/PhotoAssets.swift
// TS 源: desktop/src/main/services/assets/logical-photo-assets.ts（Phase 3.2 移植）
// 逻辑照片资产：分析与浏览操作的是逻辑资产而非每个物理 RAW/JPEG 变体。
// 保持导入顺序，组内优先 RAW 成员。
import Foundation

/// 逻辑资产折叠（TS: collapsePhotoAssets）。
public enum PhotoAssets {
    /// TS: RAW_EXTENSIONS（logical-photo-assets.ts）。
    public static let rawExtensions: Set<String> = [
        ".nef", ".nrw", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf",
        ".rw2", ".pef", ".srw", ".srf", ".x3f", ".3fr", ".fff", ".mef",
        ".mos", ".iiq", ".eip", ".erf", ".kdc", ".mrw",
    ]

    /// TS: extension(filename) —— 最后一段点号起的子串转小写；无点号返回空串。
    public static func extensionName(of filename: String) -> String {
        guard let index = filename.lastIndex(of: ".") else { return "" }
        return String(filename[index...]).lowercased()
    }

    /// 每组合并：key = asset_id ?? "photo:<id>"，组内优先 RAW 变体，否则首项。
    /// 保留 photos 的导入顺序（各组按首次出现顺序）。
    public static func collapse<T: PhotoAssetCandidate>(_ photos: [T]) -> [T] {
        var groups: [String: [T]] = [:]
        var order: [String] = []
        for photo in photos {
            let key = photo.assetId ?? "photo:\(photo.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(photo)
        }
        return order.compactMap { key in
            guard let variants = groups[key] else { return nil }
            return variants.first(where: { rawExtensions.contains(extensionName(of: $0.filename)) })
                ?? variants.first
        }
    }
}

/// TS: PhotoAssetCandidate —— 只需 id/asset_id/filename 的轻投影结构。
public protocol PhotoAssetCandidate {
    var id: String { get }
    var assetId: String? { get }
    var filename: String { get }
}

extension PhotoProjectionRow: PhotoAssetCandidate {}
