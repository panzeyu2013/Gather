// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Feedback.swift
// 源：FaceRepo.swift（HEAD c4aa5b5）；纯拆分（feedback：role_bindings 绑定 / XMP 关键词反馈），SQL 逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 FaceRepo.swift 头部记账。

import Foundation
import GatherProtocol

/// role_bindings 行（id, cluster_id, session_id, role_name, keywords）。
public struct RoleBindingRow {
    public let id: Int64
    public let clusterId: Int64
    public let sessionId: String
    public let roleName: String
    public let keywords: String

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        clusterId = row[1].intValue ?? 0
        sessionId = row[2].textValue ?? ""
        roleName = row[3].textValue ?? ""
        keywords = row[4].textValue ?? "[]"
    }
}

/// 绑定信息（TS FaceClusterRow.binding）。
public struct FaceBindingData: Equatable, Sendable {
    public let clusterId: String
    public let roleName: String
    public let keywords: [String]
}

/// getBindingsBySession 的绑定详情。
public struct FaceBindingDetail {
    public let clusterId: Int64
    public let roleName: String
    public let keywords: [String]
    public let memberPhotoIds: [String]
}

extension FaceRepo {

    // ─────────────────────────── 绑定 ───────────────────────────

    public func updateBinding(clusterId: Int64, roleName: String, keywords: [String]) throws {
        let existing = try connection.prepare("SELECT id FROM role_bindings WHERE cluster_id = ?")
            .get([.int(clusterId)])
        if existing != nil {
            _ = try connection.prepare(
                "UPDATE role_bindings SET role_name = ?, keywords = ? WHERE cluster_id = ?"
            ).run([
                .text(roleName),
                .text(try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))),
                .int(clusterId),
            ])
        } else {
            let cluster = try connection.prepare("SELECT session_id FROM face_clusters WHERE id = ?")
                .get([.int(clusterId)])
            _ = try connection.prepare(
                "INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)"
            ).run([
                .int(clusterId),
                .text(cluster?[0].textValue ?? ""),
                .text(roleName),
                .text(try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))),
            ])
        }
        _ = try connection.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?")
            .run([.int(clusterId)])
    }

    public func deleteBinding(clusterId: Int64) throws {
        _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(clusterId)])
        _ = try connection.prepare("UPDATE face_clusters SET status = 'unbound' WHERE id = ?")
            .run([.int(clusterId)])
    }

    public func getBindingsBySession(_ sessionId: String) throws -> [FaceBindingDetail] {
        let bindings = try connection.prepare("""
            SELECT rb.cluster_id, rb.role_name, rb.keywords
            FROM role_bindings rb
            WHERE rb.session_id = ?
          """).query([.text(sessionId)])
        if bindings.isEmpty { return [] }
        let clusterIds = bindings.compactMap { $0[0].intValue }
        var memberPhotoIdsByCluster: [Int64: [String]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT DISTINCT cluster_id, photo_id FROM face_cluster_members
                WHERE cluster_id IN (\(placeholders))
              """).query(chunk.map { .int($0) })
            for row in rows {
                let clusterId = row[0].intValue ?? 0
                var list = memberPhotoIdsByCluster[clusterId] ?? []
                list.append(row[1].textValue ?? "")
                memberPhotoIdsByCluster[clusterId] = list
            }
        }
        return bindings.map { row in
            FaceBindingDetail(
                clusterId: row[0].intValue ?? 0,
                roleName: row[1].textValue ?? "",
                keywords: ((try? JSONValue.parse(row[2].textValue ?? "[]")) as JSONValue?)?.arrayValue ?? [],
                memberPhotoIds: memberPhotoIdsByCluster[row[0].intValue ?? 0] ?? []
            )
        }
    }
}
