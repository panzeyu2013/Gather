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
        guard let status = try connection.prepare(
            "SELECT status FROM deliveries WHERE xmp_path = ?"
        ).get([.text(oldXmp)])?[0].textValue else {
            return false
        }
        if status == "writing" { throw DBError.message("ASSET_RELINK_XMP_BUSY") }
        let target = try connection.prepare(
            "SELECT 1 FROM deliveries WHERE xmp_path = ?"
        ).get([.text(newXmp)])
        if target != nil { throw DBError.message("ASSET_RELINK_OUTBOX_CONFLICT") }

        _ = try connection.prepare("""
            UPDATE deliveries
            SET xmp_path = ?, photo_path = ?, updated_at = ?
            WHERE xmp_path = ?
          """).run([
            .text(newXmp), .text(newPhotoPath), .text(timestamp), .text(oldXmp),
        ])

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
        return true
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
                return string
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
