// desktop/native/gather-core/Sources/GatherProtocol/Protocol/PhotoFileTypes.swift
// 图片文件扩展名分类的**唯一真相源**（Cut 3a / module-split-map E-01、CL-17）。
//
// 为什么在 Protocol：RAWDecoder（Cut 3 后属 GatherAnalysis）的 RAW 判定原先读
// AssetRepo.rawExtensions（GatherPersistence）——拆 target 后 GatherAnalysis 无法
// import GatherPersistence，且给 Analysis 加 Persistence 依赖会让算法层反向依赖
// 数据库，拆分失去意义。本文件是零依赖纯数据（仅 Foundation），两边都合法。
//
// 原定义位置：AssetRepo（Database/Repositories/AssetRepo.swift）的
// rawExtensions / bitmapExtensions / renderedExtensions / rawPairingExtensions。
// AssetRepo 的同名静态属性保留为转发（签名不变），PhotoRepo 的排序别名与
// rawVariantSQL 继续引用同一份清单——全仓不再有第二张字面量表。

import Foundation

/// 扩展名分类（全部带前导点、小写）。
public enum PhotoFileTypes {
    /// 相机 RAW —— media_type 分类、RAW+JPEG 配对候选、相似度逻辑资产折叠
    /// （PhotoAssets）与图库/挑片的代表行规则（PhotoRepo）全部引用本清单。
    /// 覆盖 TS 两份来源的并集（logical-photo-assets RAW_EXTENSIONS ∪ 配对分类）；
    /// 旧实现三份清单漂移，.x3f/.iiq 这类扩展名在相似度与图库会选出不同代表行。
    public static let rawExtensions: Set<String> = [
        ".nef", ".nrw", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf",
        ".rw2", ".pef", ".srw", ".srf", ".x3f", ".3fr", ".fff", ".mef",
        ".mos", ".iiq", ".eip", ".erf", ".kdc", ".mrw",
    ]

    /// 位图（含相机直出 JPEG/HEIC）。
    public static let bitmapExtensions: Set<String> = [".jpg", ".jpeg", ".heic", ".heif", ".png", ".webp"]

    /// 渲染位图。
    public static let renderedExtensions: Set<String> = [".tif", ".tiff", ".psd"]

    /// 可作为 RAW 配对侧的扩展名：相机 JPEG/HEIC + 渲染 TIFF。
    public static let rawPairingExtensions: Set<String> = [".jpg", ".jpeg", ".heic", ".heif", ".tif", ".tiff"]

    /// RAW 清单的稳定排序形态（Set → Array）。SQL 文本由它拼出，
    /// 顺序必须稳定（便于语句缓存）：PhotoRepo.rawVariantSQL 与代表行排序依赖。
    public static let sortedRawExtensions: [String] = rawExtensions.sorted()

    /// 是否为相机 RAW。
    ///
    /// 入参**形态归一化在内部完成**：去首尾空白、去前导点、lowercased，再查表。
    /// 因此 `nef`、`.nef`、`.NEF`、` cr2 ` 都返回 true —— 调用方不需要在
    /// 点位约定上做二次判断（历史上 RAWDecoder 传无点 ext、AssetRepo 传带点
    /// extension，两种形态并存；规范化收口在这里，避免两边各写一套）。
    public static func isRAW(_ ext: String) -> Bool {
        var normalized = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        guard !normalized.isEmpty else { return false }
        return rawExtensions.contains(".\(normalized)")
    }
}
