// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/SessionReloadAckRepo.swift
// P2：sessions.reload_acked_at 的读/清下沉，Delivery 不再内联 sessions SQL。

import Foundation
import GatherProtocol

public struct SessionReloadAckRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func reloadAck(sessionId: String) throws -> String? {
        try connection.prepare("SELECT reload_acked_at FROM sessions WHERE id = ?")
            .get([.text(sessionId)])?[0].textValue
    }

    /// 清掉该交付关联会话的 reload-ack；返回实际清零的会话数。
    @discardableResult
    public func clearReloadAcks(forXmpPath xmpPath: String, timestamp: String) throws -> Int {
        let path = TSPath.normalize(xmpPath)
        return try connection.transaction {
            let rows = try connection.prepare("""
                SELECT ds.session_id
                FROM delivery_sessions ds
                JOIN deliveries d ON d.id = ds.delivery_id
                WHERE d.xmp_path = ?
                """).query([.text(path)])
            var cleared = 0
            for row in rows {
                guard let sessionId = row[0].textValue, !sessionId.isEmpty else { continue }
                let changed = try connection.prepare("""
                    UPDATE sessions SET reload_acked_at = NULL, updated_at = ?
                    WHERE id = ? AND reload_acked_at IS NOT NULL
                    """).run([.text(timestamp), .text(sessionId)])
                if changed > 0 { cleared += 1 }
            }
            return cleared
        }
    }
}
