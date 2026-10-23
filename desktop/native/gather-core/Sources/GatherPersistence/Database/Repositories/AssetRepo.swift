// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo.swift
// TS 源: desktop/src/main/db/repositories/asset.repo.ts
// 偏差：TS 侧 node:path/node:fs 语义用 TSPath/tsStat/tsExists 复刻；预编译语句不再
// 在构造期 hoist，改为方法内 prepare（DB 层无自动缓存，语义等价、测试可读性优先）。
// 拆分：facade/存储留本文件；实现见 AssetRepo+Scan/Relink/Query/Cleanup.swift（纯移动）。
// 跨文件访问级：仅 connection、retargetPhotosPath 由 private 放宽为 internal。

import Foundation
import GatherProtocol

/// 资产仓库（TS AssetRepository）。
public final class AssetRepo {
    let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 资产文件换路径后同步 photos 的「路径投影」列（唯一实现）。
    /// 三处调用（relinkRoot / relinkMovedFile / ensurePhoto）原本各抄一份逐字相同的
    /// SQL；文件名恒为该路径的 basename，状态回到 pending 触发重新索引。
    func retargetPhotosPath(assetFileId: String, path: String, timestamp: String) throws {
        _ = try connection.prepare("""
            UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
            WHERE asset_file_id = ?
          """).run([
            .text(path), .text(TSPath.basename(path)), .text(timestamp), .text(assetFileId),
          ])
    }

    // ─────────────────────────── 私有：扩展名分类 ───────────────────────────

    // 扩展名分类的**唯一真相源**已上移到 Protocol/PhotoFileTypes（Cut 3a / E-01）：
    // RAWDecoder（Analysis）也要用同一张表，表留在 Persistence 会让算法层反向依赖
    // 数据库。以下保留同名转发（签名不变，调用方不动），字面量只存在于 PhotoFileTypes。
    // 语义同旧实现：media_type / member_role / 配对候选查询三处共用一份清单。

    /// 相机 RAW（转发；定义见 PhotoFileTypes.rawExtensions）。
    public static let rawExtensions: Set<String> = PhotoFileTypes.rawExtensions
    /// 位图（含相机直出 JPEG/HEIC）。
    static let bitmapExtensions: Set<String> = PhotoFileTypes.bitmapExtensions
    /// 渲染位图。
    static let renderedExtensions: Set<String> = PhotoFileTypes.renderedExtensions
    /// 可作为 RAW 配对侧的扩展名：相机 JPEG/HEIC + 渲染 TIFF。
    static let rawPairingExtensions: Set<String> = PhotoFileTypes.rawPairingExtensions
}
