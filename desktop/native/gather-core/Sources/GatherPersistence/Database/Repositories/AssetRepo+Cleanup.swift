// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo+Cleanup.swift
// 源：AssetRepo.swift（HEAD c4aa5b5）；纯拆分（cleanup），SQL 逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 AssetRepo.swift 头部记账。

import Foundation
import GatherProtocol

extension AssetRepo {

    /// WP3b-1（SessionService 下沉）：删除会话后把无会话引用的资产标 orphan。
    /// 旧 SQL 逐字保留（status != 'orphan' + NOT EXISTS session_assets）。
    public func markOrphanedAssets() throws {
        _ = try connection.prepare("""
            UPDATE assets SET status = 'orphan', updated_at = ?
            WHERE status != 'orphan'
              AND NOT EXISTS (
                SELECT 1 FROM session_assets sa WHERE sa.asset_id = assets.id
              )
          """).run([.text(nowISOString())])
    }
}
