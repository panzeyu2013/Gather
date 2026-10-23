// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Clusters.swift
// 源：FaceRepo.swift（HEAD c4aa5b5）；纯拆分（clusters），方法体/SQL/错误逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 FaceRepo.swift 头部记账。

import Foundation
import GatherProtocol

/// face_clusters 行 + 实时成员计数 + 身份匹配建议（V1 10 个结果列）。
/// 列序: id(0), session_id(1), label(2), member_count(3), status(4),
///       thumbnail_path(5), matched_person_id(6), match_confidence(7),
///       created_at(8), updated_at(9)。
/// V1 删除了 thumbnail_base64；缩略图文件由 thumbnail_path 承载。
public struct FaceClusterRow {
    /// SELECT 与位置解码共用的唯一列清单（member_count 为 COUNT 别名，非物理列）。
    public static let columns = [
        "id", "session_id", "label", "member_count", "status", "thumbnail_path",
        "matched_person_id", "match_confidence", "created_at", "updated_at",
    ]
    public let id: Int64
    public let sessionId: String
    public let label: String
    /// 实时 COUNT(face_cluster_members)，不是存档列。
    public let memberCount: Int64
    public let status: String
    public let thumbnailPath: String
    /// 身份链接（PersonRepo.bindRole / 跨会话匹配写入）。
    public let matchedPersonId: String?
    public let matchConfidence: Double?
    public let createdAt: String
    public let updatedAt: String
    public var members: [FaceClusterMemberRow]?
    public var binding: FaceBindingData?

    public init(row: DBRow) throws {
        guard row.count >= 10 else { throw DBError.message("FaceClusterRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        sessionId = row[1].textValue ?? ""
        label = row[2].textValue ?? ""
        memberCount = row[3].intValue ?? 0
        status = row[4].textValue ?? ""
        thumbnailPath = row[5].textValue ?? ""
        matchedPersonId = row[6].textValue
        matchConfidence = row[7].doubleValue
        createdAt = row[8].textValue ?? ""
        updatedAt = row[9].textValue ?? ""
        members = nil
        binding = nil
    }
}

/// TS FaceClusterInput.members 元素。
public struct FaceClusterMemberInput {
    public let photoId: String
    public let photoPath: String
    public let bbox: [Double]
    public let confidence: Double
    public let observationId: Int64?

    public init(photoId: String, photoPath: String, bbox: [Double], confidence: Double, observationId: Int64? = nil) {
        self.photoId = photoId
        self.photoPath = photoPath
        self.bbox = bbox
        self.confidence = confidence
        self.observationId = observationId
    }
}

/// TS FaceClusterInput。
public struct FaceClusterInput {
    public let label: String
    public let members: [FaceClusterMemberInput]

    public init(label: String, members: [FaceClusterMemberInput]) {
        self.label = label
        self.members = members
    }
}

/// 簇成员的观察向量：跨会话匹配的查询集，也是 person_embeddings 的入库来源
/// （两者共用同一读取口径，避免"写入的向量"与"匹配读的向量"分叉）。
public struct ClusterMemberEmbedding {
    public let memberId: Int64
    public let photoId: String
    public let sessionId: String
    public let observationId: Int64
    public let embedding: [Float]
    public let bbox: [Double]
    public let confidence: Double
    /// v34：观察行的质量/几何/模型元数据（跨会话匹配的加权依据）。
    public let quality: Double
    public let faceSizePx: Double
    public let rollDegrees: Double
    public let modelId: String
    public let modelVersion: String
    public let embeddingDim: Int

    public init(
        memberId: Int64,
        photoId: String,
        sessionId: String,
        observationId: Int64,
        embedding: [Float],
        bbox: [Double],
        confidence: Double,
        quality: Double = 0,
        faceSizePx: Double = 0,
        rollDegrees: Double = 0,
        modelId: String = "",
        modelVersion: String = "",
        embeddingDim: Int = 0
    ) {
        self.memberId = memberId
        self.photoId = photoId
        self.sessionId = sessionId
        self.observationId = observationId
        self.embedding = embedding
        self.bbox = bbox
        self.confidence = confidence
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.rollDegrees = rollDegrees
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.embeddingDim = embeddingDim
    }
}

extension FaceRepo {

    public func getClusterSignature(_ sessionId: String) throws -> String? {
        guard let row = try connection.prepare(
            "SELECT cluster_signature FROM face_cluster_state WHERE session_id = ?"
        ).get([.text(sessionId)]) else { return nil }
        return row[0].textValue
    }

    public func upsertClusterSignature(sessionId: String, signature: String) throws {
        _ = try connection.prepare("""
            INSERT INTO face_cluster_state (session_id, cluster_signature, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
              cluster_signature = excluded.cluster_signature,
              updated_at = excluded.updated_at
          """).run([.text(sessionId), .text(signature), .text(nowISOString())])
    }

    /// 清空聚类签名（Cut 5 / 5c-2）。用于三阶段分析的失效边界：观测已更新但簇未
    /// 更新（B 阶段失败 / A 与 C 之间取消 / C 的 index_seq 守卫失败）时，签名必须
    /// 失效，否则下一次 analyze 会把旧簇误判为"仍然有效"而跳过重聚类。
    public func clearClusterSignature(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    // ─────────────────────────── 聚类 ───────────────────────────

    public func saveClusters(sessionId: String, clusters: [FaceClusterInput]) throws -> [Int64] {
        var ids: [Int64] = []
        // V1 的 face_clusters 没有 member_count/thumbnail_base64：成员计数是
        // COUNT(face_cluster_members) 的读取别名，缩略图只走 thumbnail_path（默认 ''）。
        let insertCluster = try connection.prepare(
            "INSERT INTO face_clusters (session_id, label, status, thumbnail_path) VALUES (?, ?, 'unbound', '')"
        )
        let insertMember = try connection.prepare(
            "INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for cluster in clusters {
                _ = try insertCluster.run([
                    .text(sessionId), .text(cluster.label),
                ])
                let clusterId = connection.lastInsertRowid
                ids.append(clusterId)
                for member in cluster.members {
                    let bboxJSON = try JSONValue.stringify(JSONValue.array(member.bbox.map { JSONValue.real($0) }))
                    _ = try insertMember.run([
                        .int(clusterId),
                        .text(sessionId),
                        .text(member.photoId),
                        .text(bboxJSON),
                        .real(member.confidence),
                        optDB(member.observationId),
                    ])
                }
            }
        }
        return ids
    }

    /// 会话簇清单。
    /// - memberCount 恒为实时 COUNT(face_cluster_members)；
    /// - 成员清单 LEFT JOIN photos（孤儿成员保留，photoPath 为空）；
    /// - **有绑定但无成员的孤儿绑定同样返回**（size=0），作为清理入口。
    public func getClusters(_ sessionId: String, includeMembers: Bool = false) throws -> [FaceClusterRow] {
        // SELECT 列序由 FaceClusterRow.columns 单点定义；member_count 是实时 COUNT 别名。
        let selectList = FaceClusterRow.columns.map { column in
            column == "member_count"
                ? "(SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = c.id) AS member_count"
                : "c." + column
        }.joined(separator: ", ")
        let clusters = try connection.prepare("""
            SELECT \(selectList)
            FROM face_clusters c
            WHERE c.session_id = ?
              AND (
                (SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = c.id) > 0
                OR EXISTS (SELECT 1 FROM role_bindings rb WHERE rb.cluster_id = c.id)
              )
            ORDER BY c.id
            """).query([.text(sessionId)]).map { try FaceClusterRow(row: $0) }
        if !includeMembers || clusters.isEmpty { return clusters }
        let clusterIds = clusters.map(\.id)

        var membersByCluster: [Int64: [FaceClusterMemberRow]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id,
                       COALESCE(p.filepath, '') AS photo_path, fm.bbox, fm.confidence, fm.observation_id
                FROM face_cluster_members fm
                LEFT JOIN photos p ON fm.photo_id = p.id
                WHERE fm.cluster_id IN (\(placeholders))
                ORDER BY fm.id
              """).query(chunk.map { .int($0) })
            for row in rows {
                let member = FaceClusterMemberRow(row: row)
                var list = membersByCluster[member.clusterId] ?? []
                list.append(member)
                membersByCluster[member.clusterId] = list
            }
        }

        var bindingByCluster: [Int64: RoleBindingRow] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            // role_bindings：7 列（TableColumns.roleBindings；RoleBindingRow 只读 0-4）
            let rows = try connection.prepare(
                "SELECT \(TableColumns.sql(TableColumns.roleBindings)) FROM role_bindings WHERE cluster_id IN (\(placeholders))"
            ).query(chunk.map { .int($0) })
            for row in rows {
                let binding = RoleBindingRow(row: row)
                bindingByCluster[binding.clusterId] = binding
            }
        }

        var result: [FaceClusterRow] = []
        for var cluster in clusters {
            cluster.members = membersByCluster[cluster.id] ?? []
            if let binding = bindingByCluster[cluster.id] {
                cluster.binding = FaceBindingData(
                    clusterId: String(binding.clusterId),
                    roleName: binding.roleName,
                    keywords: ((try? JSONValue.parse(binding.keywords)) as JSONValue?)?.arrayValue ?? []
                )
            }
            result.append(cluster)
        }
        return result
    }

    /// 跨库匹配的一次性批量输入（Cut 5 / 5c-2）：簇匹配状态 + 成员几何。
    /// 一条 LEFT JOIN 查询同时给出"哪些簇已绑定人物"与"每个簇的成员"，取代旧路径
    /// 的 getClusters(includeMembers:)（3 条 SELECT：簇/成员/绑定），使
    /// FaceKwService.matchClustersAgainstLibrary 的固定 SELECT 数降到 4：
    /// 库向量 + 本查询 + feedback + 人物阈值。
    /// 无成员的簇也返回一行（memberPhotoId == nil），调用方无需再补查簇表。
    public struct FaceClusterMatchRow: Equatable, Sendable {
        public let clusterId: Int64
        public let matchedPersonId: String?
        public let memberPhotoId: String?
        public let memberBbox: String

        public init(
            clusterId: Int64,
            matchedPersonId: String?,
            memberPhotoId: String?,
            memberBbox: String
        ) {
            self.clusterId = clusterId
            self.matchedPersonId = matchedPersonId
            self.memberPhotoId = memberPhotoId
            self.memberBbox = memberBbox
        }
    }

    /// 按簇 id 批量读取匹配状态与成员（一次 IN 查询；>800 簇按 800 分块）。
    /// session_id 过滤保证不会跨会话读到别的簇。
    public func getClusterMatchRows(
        sessionId: String,
        clusterIds: [Int64]
    ) throws -> [FaceClusterMatchRow] {
        guard !clusterIds.isEmpty else { return [] }
        var result: [FaceClusterMatchRow] = []
        for chunk in clusterIds.chunked(by: 800) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT c.id, c.matched_person_id, m.photo_id, m.bbox
                FROM face_clusters c
                LEFT JOIN face_cluster_members m ON m.cluster_id = c.id
                WHERE c.session_id = ? AND c.id IN (\(placeholders))
                ORDER BY c.id, m.id
              """).query([.text(sessionId)] + chunk.map { .int($0) })
            for row in rows {
                result.append(FaceClusterMatchRow(
                    clusterId: row[0].intValue ?? 0,
                    matchedPersonId: row[1].textValue,
                    memberPhotoId: row[2].textValue,
                    memberBbox: row[3].textValue ?? ""))
            }
        }
        return result
    }

    public func getClusterThumbnailPath(_ clusterId: Int64) throws -> String {
        guard let row = try connection.prepare("SELECT thumbnail_path FROM face_clusters WHERE id = ?")
            .get([.int(clusterId)]) else { return "" }
        return row[0].textValue ?? ""
    }

    public func getClusterSessionId(_ clusterId: Int64) throws -> String? {
        guard let row = try connection.prepare("SELECT session_id FROM face_clusters WHERE id = ?")
            .get([.int(clusterId)]) else { return nil }
        return row[0].textValue
    }

    /// 簇成员及其观察向量（仅 observation_id 非空且观察仍存在的成员）。
    public func getClusterMemberEmbeddings(_ clusterId: Int64) throws -> [ClusterMemberEmbedding] {
        let rows = try connection.prepare("""
            SELECT fm.id, fm.photo_id, fm.session_id, fo.id, fo.embedding, fm.bbox, fm.confidence,
                   fo.quality, fo.face_size_px, fo.roll_degrees,
                   fo.model_id, fo.model_version, fo.embedding_dim
            FROM face_cluster_members fm
            JOIN face_observations fo ON fo.id = fm.observation_id
            WHERE fm.cluster_id = ?
            ORDER BY fm.id
            """).query([.int(clusterId)])
        return rows.compactMap { row in
            guard let observationId = row[3].intValue else { return nil }
            let embedding: Data = {
                if case .blob(let data) = row[4] { return data }
                return Data()
            }()
            return ClusterMemberEmbedding(
                memberId: row[0].intValue ?? 0,
                photoId: row[1].textValue ?? "",
                sessionId: row[2].textValue ?? "",
                observationId: observationId,
                embedding: Self.floats(from: embedding),
                bbox: parseBbox(row[5].textValue ?? ""),
                confidence: row[6].doubleValue ?? 0,
                quality: row[7].doubleValue ?? 0,
                faceSizePx: row[8].doubleValue ?? 0,
                rollDegrees: row[9].doubleValue ?? 0,
                modelId: row[10].textValue ?? "",
                modelVersion: row[11].textValue ?? "",
                embeddingDim: Int(row[12].intValue ?? 0)
            )
        }
    }

    /// 写入/清除簇的身份匹配建议（跨会话重识别；显式绑定经 PersonRepo 写同一列）。
    public func setClusterMatch(clusterId: Int64, personId: String?, confidence: Double?) throws {
        _ = try connection.prepare("""
            UPDATE face_clusters SET matched_person_id = ?, match_confidence = ?, updated_at = ? WHERE id = ?
            """).run([
            personId.map { .text($0) },
            confidence.map { .real($0) },
            .text(nowISOString()),
            .int(clusterId),
        ])
    }

    /// 有成员的簇的缩略图文件（孤儿绑定没有缩略图）。
    public func getThumbnailPathsBySession(_ sessionId: String) throws -> [String] {
        let rows = try connection.prepare("""
            SELECT thumbnail_path FROM face_clusters c
            WHERE c.session_id = ? AND c.thumbnail_path != ''
              AND EXISTS (SELECT 1 FROM face_cluster_members m WHERE m.cluster_id = c.id)
            """).query([.text(sessionId)])
        return rows.compactMap { $0[0].textValue }
    }

    /// 合并簇：成员并入目标，源绑定删除、源簇保留为空行（调用方决定删除源簇还是
    /// 保留为孤儿绑定），源缩略图文件删除，计数按成员表重算。
    /// 注：撤销合并需要调用方持有 sourceMemberIds/sourceBinding 日志，本仓库不再
    /// 提供 restoreMerge（全仓无生产记录点，日志能力超出本域）。
    public func mergeClusters(sourceId: Int64, targetId: Int64) throws {
        let sourcePath = try getClusterThumbnailPath(sourceId)
        try connection.transaction {
            _ = try connection.prepare("UPDATE face_cluster_members SET cluster_id = ? WHERE cluster_id = ?")
                .run([.int(targetId), .int(sourceId)])
            _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(sourceId)])
            _ = try connection.prepare("UPDATE face_clusters SET status = 'unbound', updated_at = ? WHERE id = ?")
                .run([.text(nowISOString()), .int(sourceId)])
        }
        deleteThumbnailFile(sourcePath)
    }

    /// 会话删除专用：整会话簇/绑定/成员清理。**不得**用于内容/路径变化后的失效
    /// （那必须走 invalidateDerivedResults，绑定必须保留）。
    public func deleteClustersBySession(_ sessionId: String) throws {
        let paths = try getThumbnailPathsBySession(sessionId)
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM role_bindings WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_clusters WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?").run([.text(sessionId)])
        }
        for path in paths { deleteThumbnailFile(path) }
    }

    /// 无脸结果清理的簇段：删除会话内没有 role_bindings 引用的簇（旧语义逐字保留）。
    public func deleteUnboundClusters(sessionId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM face_clusters WHERE session_id = ? AND id NOT IN (SELECT cluster_id FROM role_bindings)"
        ).run([.text(sessionId)])
    }

    /// 存储 BLOB 的 Float32 视图（与 FaceKwService.floats 同语义）。
    private static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }
}
