// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Relocation.swift
// P1：交付行/重建 intent 的路径迁移属于 delivery 写 owner；AssetRepo 不再直接
// UPDATE deliveries。调用方必须在自己的事务内调用（同一连接，自动加入事务）。

import Foundation
import GatherProtocol

extension DeliveryRepo {
    /// 把 oldXmpPath 的交付行（若有）迁到 newXmpPath，并同步 delivery_intents.xmp_path
    /// 与 payload JSON 中的 xmp/photo 字符串。返回是否实际迁移了一条交付。
    public func relocatePaths(
        oldXmpPath: String,
        newXmpPath: String,
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws -> Bool {
        let oldXmp = TSPath.normalize(oldXmpPath)
        let newXmp = TSPath.normalize(newXmpPath)
        guard oldXmp != newXmp else { return false }
        guard let existing = try connection.prepare(
            "SELECT status, backup_path FROM deliveries WHERE xmp_path = ?"
        ).get([.text(oldXmp)]) else {
            // 没有 deliveries 行时也要迁 intents：delivery_intents.xmp_path 刻意无 FK
            // （父行删除后仍需存活以便回放），避免行内记的路径与文件真实位置分叉。
            // 注意这不会让回放成功：回放先命中 alreadyGone 收尾；卡住回放的是
            // payload 里的 backup_path（备份留在旧目录，不再与 xmp 同目录）。
            try relocateIntents(
                oldXmp: oldXmp, newXmp: newXmp,
                oldPhotoPath: oldPhotoPath, newPhotoPath: newPhotoPath, timestamp: timestamp)
            return false
        }
        let status = existing[0].textValue ?? ""
        if status == "writing" { throw PersistenceError(code: .ASSET_RELINK_XMP_BUSY) }
        let target = try connection.prepare(
            "SELECT 1 FROM deliveries WHERE xmp_path = ?"
        ).get([.text(newXmp)])
        if target != nil { throw PersistenceError(code: .ASSET_RELINK_OUTBOX_CONFLICT) }

        // 备份路径也是「xmp 的同目录兄弟」契约（DeliveryBackupPath 要求同目录 + 新名前缀）：
        // 只改 xmp_path 会让 cleanup/finalize 在回放时判 notSibling/unexpectedName 并终态丢弃。
        // 备份文件本身由调用方（RejectedMover）按同一规则搬走。
        let newBackup = Self.rewriteBackupPath(
            existing[1].textValue ?? "", oldXmp: oldXmp, newXmp: newXmp)
        _ = try connection.prepare("""
            UPDATE deliveries
            SET xmp_path = ?, photo_path = ?, backup_path = ?, updated_at = ?
            WHERE xmp_path = ?
          """).run([
            .text(newXmp), .text(newPhotoPath), .text(newBackup), .text(timestamp),
            .text(oldXmp),
        ])

        try relocateIntents(
            oldXmp: oldXmp, newXmp: newXmp,
            oldPhotoPath: oldPhotoPath, newPhotoPath: newPhotoPath, timestamp: timestamp)
        return true
    }

    /// delivery_intents 的路径迁移（与交付行是否存在无关；无 FK 兜底回放）。
    private func relocateIntents(
        oldXmp: String,
        newXmp: String,
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws {
        let intents = try connection.prepare(
            "SELECT id, payload_json FROM delivery_intents WHERE xmp_path = ?"
        ).query([.text(oldXmp)])
        for row in intents {
            guard let id = row[0].intValue else { continue }
            let raw = row[1].textValue ?? ""
            let rewritten = Self.rewriteIntentPayload(
                raw, oldXmp: oldXmp, newXmp: newXmp,
                oldPhoto: oldPhotoPath, newPhoto: newPhotoPath)
            _ = try connection.prepare("""
                UPDATE delivery_intents
                SET xmp_path = ?, payload_json = ?, updated_at = ?
                WHERE id = ?
              """).run([
                .text(newXmp), .text(rewritten), .text(timestamp), .int(id),
            ])
        }
    }

    /// 备份路径随 xmp 改名/换目录：只有「旧 xmp 的同目录兄弟 + 旧名的后缀前缀」才改成
    /// 「新 xmp 的同目录 + 新名的后缀前缀」；其它（空/已清理/非受控）原样保留，
    /// 绝不把任意路径改写成看起来合法的备份路径。
    static func rewriteBackupPath(_ backupPath: String, oldXmp: String, newXmp: String) -> String {
        XMPBackupNaming.relocated(
            backupPath: backupPath, oldXMPPath: oldXmp, newXMPPath: newXmp)
    }

    /// 只替换 JSON 中与旧路径完全相等的字符串；解析失败时保留原 payload，
    /// 但仍迁移 xmp_path（由调用方/replay 的 alreadyGone 兜底）。
    private static func rewriteIntentPayload(
        _ raw: String, oldXmp: String, newXmp: String,
        oldPhoto: String, newPhoto: String
    ) -> String {
        guard let data = raw.data(using: .utf8) else { return raw }
        var object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return raw
        }
        func rewrite(_ value: Any) -> Any {
            if let string = value as? String {
                if TSPath.normalize(string) == oldXmp { return newXmp }
                if TSPath.normalize(string) == TSPath.normalize(oldPhoto) { return newPhoto }
                // payload 里的 backupPath 不是 xmp 本身：按「同目录兄弟 + 新名前缀」重写。
                return Self.rewriteBackupPath(string, oldXmp: oldXmp, newXmp: newXmp)
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            if let dict = value as? [String: Any] {
                return dict.mapValues(rewrite)
            }
            return value
        }
        object = rewrite(object)
        do {
            let encoded = try JSONSerialization.data(withJSONObject: object)
            return String(data: encoded, encoding: .utf8) ?? raw
        } catch {
            return raw
        }
    }
}
