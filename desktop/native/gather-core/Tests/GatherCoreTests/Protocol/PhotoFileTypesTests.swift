// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/PhotoFileTypesTests.swift
// Cut 3a（module-split-map E-01）：扩展名表从 AssetRepo（Persistence）上移到
// Protocol/PhotoFileTypes。本测试固定三件事：
//   1. 清单与搬迁前的字面量表**逐一相等**（上移不得增删/改写扩展名）；
//   2. isRAW 的归一化边界（前导点/大小写/首尾空白/空串/非 RAW）；
//   3. 排序别名稳定 —— PhotoRepo.rawVariantSQL 依赖它拼 SQL，顺序必须可缓存。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherDomain

struct PhotoFileTypesTests {
    /// 搬迁前 AssetRepo.rawExtensions 的字面量（Cut 3a 对照基线，独立抄录）。
    private static let legacyRawExtensions: Set<String> = [
        ".nef", ".nrw", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf",
        ".rw2", ".pef", ".srw", ".srf", ".x3f", ".3fr", ".fff", ".mef",
        ".mos", ".iiq", ".eip", ".erf", ".kdc", ".mrw",
    ]

    /// 搬迁前 AssetRepo.rawPairingExtensions 的字面量。
    private static let legacyRawPairingExtensions: Set<String> = [
        ".jpg", ".jpeg", ".heic", ".heif", ".tif", ".tiff",
    ]

    @Test func rawExtensionsMatchLegacyTableOneToOne() {
        #expect(PhotoFileTypes.rawExtensions == Self.legacyRawExtensions)
        // 旧调用点经转发读到的必须仍是同一份清单（签名不变、调用方不动）。
        #expect(AssetRepo.rawExtensions == Self.legacyRawExtensions)
        #expect(Set(PhotoRepo.rawExtensions) == Self.legacyRawExtensions)
        #expect(PhotoAssets.rawExtensions == Self.legacyRawExtensions)
    }

    @Test func rawPairingExtensionsMatchLegacyTable() {
        #expect(PhotoFileTypes.rawPairingExtensions == Self.legacyRawPairingExtensions)
        #expect(AssetRepo.rawPairingExtensions == Self.legacyRawPairingExtensions)
    }

    @Test func bitmapAndRenderedTablesUnchanged() {
        #expect(PhotoFileTypes.bitmapExtensions == [".jpg", ".jpeg", ".heic", ".heif", ".png", ".webp"])
        #expect(PhotoFileTypes.renderedExtensions == [".tif", ".tiff", ".psd"])
        #expect(AssetRepo.bitmapExtensions == PhotoFileTypes.bitmapExtensions)
        #expect(AssetRepo.renderedExtensions == PhotoFileTypes.renderedExtensions)
        // 三张表互不相交：AssetRepo.mediaType 的判定顺序（bitmap → raw → rendered）
        // 只有在不重叠时才是确定性分类。
        #expect(PhotoFileTypes.rawExtensions.isDisjoint(with: PhotoFileTypes.bitmapExtensions))
        #expect(PhotoFileTypes.rawExtensions.isDisjoint(with: PhotoFileTypes.renderedExtensions))
        #expect(PhotoFileTypes.bitmapExtensions.isDisjoint(with: PhotoFileTypes.renderedExtensions))
    }

    @Test func sortedRawExtensionsIsStableAndFeedsSQL() {
        #expect(PhotoFileTypes.sortedRawExtensions == Self.legacyRawExtensions.sorted())
        #expect(PhotoFileTypes.sortedRawExtensions == PhotoFileTypes.rawExtensions.sorted())
        // PhotoRepo 的排序别名必须与 Protocol 的排序结果完全一致（SQL 文本稳定）。
        #expect(PhotoRepo.rawExtensions == PhotoFileTypes.sortedRawExtensions)
        // rawVariantSQL 由同一份清单拼出：22 个扩展名 → 22 个 LIKE 子句，按字典序。
        let sql = PhotoRepo.rawVariantSQL(alias: "p2")
        #expect(sql.hasPrefix("(LOWER(p2.filename) LIKE '%.3fr'"), "首个子句应为 .3fr：\(sql)")
        #expect(sql.hasSuffix("LIKE '%.x3f')"), "末个子句应为 .x3f：\(sql)")
        #expect(sql.components(separatedBy: " OR ").count == Self.legacyRawExtensions.count)
        for ext in Self.legacyRawExtensions {
            #expect(sql.contains("LIKE '%\(ext)'"), "缺子句：\(ext)")
        }
    }

    @Test func isRAWAcceptsDottedDotlessAndCaseVariants() {
        for ext in Self.legacyRawExtensions {
            #expect(PhotoFileTypes.isRAW(ext), "带点小写：\(ext)")
            #expect(PhotoFileTypes.isRAW(ext.uppercased()), "带点大写：\(ext)")
            #expect(PhotoFileTypes.isRAW(String(ext.dropFirst())), "无点：\(ext)")
            #expect(PhotoFileTypes.isRAW(" \(ext) "), "首尾空白：\(ext)")
        }
        // 需求点名的三组形态。
        #expect(PhotoFileTypes.isRAW("nef"))
        #expect(PhotoFileTypes.isRAW(".NEF"))
        #expect(PhotoFileTypes.isRAW(" cr2 "))
    }

    @Test func isRAWRejectsNonRawAndMalformedExtensions() {
        for ext in ["", " ", ".", "..", "jpg", ".jpg", ".jpeg", ".heic",
                    ".heif", ".tif", ".tiff", ".psd", ".gif", "raw",
                    "nef.", ".nefx", "ne f", ".dngx"] {
            #expect(!PhotoFileTypes.isRAW(ext), "不应判为 RAW：\(ext)")
        }
    }
}
