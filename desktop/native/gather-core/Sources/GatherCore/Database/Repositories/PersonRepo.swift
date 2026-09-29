// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/PersonRepo.swift
// 人物身份生命周期（全量重写；TS person.repo.ts 时代的按名投影已删除）。
//
// 单一真相源：
//   persons                         身份本身（name/keywords/notes/match_threshold）
//   role_bindings                   身份在某个会话簇上的角色名（写回 XMP 的键）
//   face_clusters.matched_person_id 簇 → 身份 的显式链接
//   person_photos / person_embeddings  身份的投影（照片桥接、人脸向量）
//   metadata_keyword_origins（source='face-keyword'）我们实际写进 XMP 的关键词凭据
//
// 身份生命周期只有一处实现：applyIdentityTransition(_:)。bind / rename / delete /
// merge 四条路径全部经它落地，任何一条都不得各自半写。它保证不变量：
//   I1 绑定到身份的簇，其 role_name 恒等于身份当前 name（rename 同步 role_bindings）。
//   I2 身份消失后，不得残留任何「无 person 但会被 upsertByName 按名认领」的
//      role_binding —— 否则删除的身份会被对账复活（delete 同步）。
//   I3 合并把源身份的全部关联（簇链接、角色名、照片、向量、关键词）重指向目标，
//      源身份不留任何可认领物（merge 同步）。
//   I4 任何身份变更只要让某个关键词不再属于「当前会写回的名字集合」，就把它连同
//      实际持有它的 XMP 路径列进清理计划（PersonKeywordCleanup），由写回层执行移除；
//      origin 行保持 active=1（= 物理仍存在于 XMP），直到写回成功由写回层 deactivate。
//
// 复活防护选型：**清干净关联**，不用 tombstone。理由：
//   - upsertByName 的复活路径只有一条 —— role_bindings（FaceKwService.bindCluster
//     与 reconcileSession 都经它按名 adopt）。delete 把这些绑定与 matched_person_id
//     一并清掉，就没有可被认领的东西；
//   - tombstone 需要新表/新列（Schema.swift、Migrations.swift 不在本域文件所有权内），
//     且会把「用户以后再次显式绑定同名角色」误判为复活；
//   - 清关联后再次出现同名人物只可能来自用户显式绑定，语义上就是新身份，不是复活。
import Foundation

/// persons 表行 + thumbnail_path（最近照片 filepath，无关联照片时为 nil）。
/// get()/listWithCounts() 的 SELECT 带 thumbnail_path 子查询（9/10 列）；
/// list() 为 SELECT *（8 列，无 thumbnail_path 列）。
public struct PersonRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let keywords: String
    public let thumbnailBase64: String
    public let thumbnailPath: String?
    public let notes: String
    public let matchThreshold: Double
    public let createdAt: String
    public let updatedAt: String

    // 表列序（SELECT *，8 列）: id(0), name(1), keywords(2), thumbnail_base64(3),
    //   notes(4), match_threshold(5), created_at(6), updated_at(7)
    // get() 追加 thumbnail_path 子查询（9 列，位于索引 8）；
    // listWithCounts() 追加 thumbnail_path(8) + photo_count(9)/session_count(10)。
    init(row: DBRow) throws {
        guard row.count == 8 || row.count == 9 || row.count == 11 else {
            throw DBError.message("PersonRow 列数异常: \(row.count)")
        }
        id = row[0].textValue ?? ""
        name = row[1].textValue ?? ""
        keywords = row[2].textValue ?? ""
        thumbnailBase64 = row[3].textValue ?? ""
        notes = row[4].textValue ?? ""
        matchThreshold = row[5].doubleValue ?? 0
        createdAt = row[6].textValue ?? ""
        updatedAt = row[7].textValue ?? ""
        thumbnailPath = row.count >= 9 ? row[8].textValue : nil
    }
}

/// listWithCounts 的行：PersonRow + photo_count/session_count（第 9/10 列）。
public struct PersonWithCountsRow: Equatable, Sendable {
    public let person: PersonRow
    public let photoCount: Int
    public let sessionCount: Int

    init(row: DBRow) throws {
        person = try PersonRow(row: row)
        photoCount = Int(row[9].intValue ?? 0)
        sessionCount = Int(row[10].intValue ?? 0)
    }
}

/// person_photos 表行（SELECT *）。
public struct PersonPhotoRow: Equatable, Sendable {
    // 表列序: id(0), person_id(1), photo_id(2), session_id(3), face_bbox(4),
    // confidence(5), created_at(6)
    public let id: Int64
    public let personId: String
    public let photoId: String
    public let sessionId: String
    public let faceBbox: String
    public let confidence: Double
    public let createdAt: String

    init(row: DBRow) throws {
        guard row.count >= 7 else { throw DBError.message("PersonPhotoRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        personId = row[1].textValue ?? ""
        photoId = row[2].textValue ?? ""
        sessionId = row[3].textValue ?? ""
        faceBbox = row[4].textValue ?? ""
        confidence = row[5].doubleValue ?? 0
        createdAt = row[6].textValue ?? ""
    }
}

/// getPhotosWithDetails 的行：PersonPhotoRow + 会话名/文件名/路径（JOIN）。
public struct PersonPhotoDetail: Equatable, Sendable {
    // pp.*(0-6) + session_name(7), filename(8), filepath(9)
    public let photo: PersonPhotoRow
    public let sessionName: String
    public let filename: String
    public let filepath: String

    init(row: DBRow) throws {
        photo = try PersonPhotoRow(row: row)
        sessionName = row[7].textValue ?? ""
        filename = row[8].textValue ?? ""
        filepath = row[9].textValue ?? ""
    }
}

/// getAllEmbeddings 的轻量行（TS: { person_id, embedding, face_observation_id }）。
public struct PersonEmbeddingRef: Equatable, Sendable {
    public let personId: String
    public let embedding: Data
    public let faceObservationId: Int64?
}

/// addPhotos 的单条输入（TS: { photoId, faceBbox, confidence }）。
public struct PersonPhotoInput {
    public let photoId: String
    public let faceBbox: [Double]
    public let confidence: Double

    public init(photoId: String, faceBbox: [Double], confidence: Double) {
        self.photoId = photoId
        self.faceBbox = faceBbox
        self.confidence = confidence
    }
}

/// saveEmbeddings 的单条输入（TS: SaveEmbeddingInput，embedding 为 Float32 数组）。
public struct SaveEmbeddingInput {
    public let personId: String
    public let embedding: [Float]
    public let photoId: String
    public let sessionId: String
    public let faceObservationId: Int64?
    public let faceBbox: [Double]
    public let quality: Double

    public init(personId: String, embedding: [Float], photoId: String, sessionId: String, faceObservationId: Int64?, faceBbox: [Double], quality: Double) {
        self.personId = personId
        self.embedding = embedding
        self.photoId = photoId
        self.sessionId = sessionId
        self.faceObservationId = faceObservationId
        self.faceBbox = faceBbox
        self.quality = quality
    }
}

/// 身份的展示名与匹配合格线（fkw.clusters 的建议展示 / 跨会话匹配的阈值）。
public struct PersonIdentitySummary: Equatable, Sendable {
    public let id: String
    public let name: String
    public let matchThreshold: Double

    public init(id: String, name: String, matchThreshold: Double) {
        self.id = id
        self.name = name
        self.matchThreshold = matchThreshold
    }
}

public struct PersonUpdateFields {
    public let name: String?
    public let keywords: [String]?
    public let notes: String?
    public let matchThreshold: Double?

    public init(name: String? = nil, keywords: [String]? = nil, notes: String? = nil, matchThreshold: Double? = nil) {
        self.name = name
        self.keywords = keywords
        self.notes = notes
        self.matchThreshold = matchThreshold
    }
}

// MARK: - 身份生命周期值类型

/// 身份变更产生的 XMP 关键词清理计划条目：这些关键词物理上仍写在 xmpPath 中，
/// 但已不再属于该身份的写入集合，必须由写回层移除（face-keyword origin 凭据）。
public struct PersonKeywordCleanup: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let xmpPath: String
    public let keywords: [String]

    public init(photoId: String, sessionId: String, xmpPath: String, keywords: [String]) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.xmpPath = xmpPath
        self.keywords = keywords
    }
}

/// 身份生命周期函数的返回值：谁发生了变化 + 需要清理哪些 XMP 关键词。
/// cleanup 为空表示本次变更没有遗留外部关键词（例如纯绑定、只有备注变更）。
public struct PersonIdentityOutcome: Equatable, Sendable {
    public let personId: String?
    /// merge 时的目标身份；其余为 nil。
    public let mergedInto: String?
    public let cleanup: [PersonKeywordCleanup]

    public init(personId: String?, mergedInto: String? = nil, cleanup: [PersonKeywordCleanup] = []) {
        self.personId = personId
        self.mergedInto = mergedInto
        self.cleanup = cleanup
    }

    public static let noop = PersonIdentityOutcome(personId: nil)
}

public final class PersonRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // ─────────────────────────── 查询 ───────────────────────────

    public func list() throws -> [PersonRow] {
        let rows = try connection.prepare("SELECT * FROM persons ORDER BY name").query()
        return try rows.map { try PersonRow(row: $0) }
    }

    public func listWithCounts() throws -> [PersonWithCountsRow] {
        let rows = try connection.prepare(
            "SELECT p.*, (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id WHERE pp.person_id = p.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) as thumbnail_path, COALESCE(pp.photo_count, 0) as photo_count, COALESCE(pp.session_count, 0) as session_count FROM persons p LEFT JOIN (SELECT person_id, COUNT(*) as photo_count, COUNT(DISTINCT session_id) as session_count FROM person_photos GROUP BY person_id) pp ON p.id = pp.person_id ORDER BY p.name"
        ).query()
        return try rows.map { try PersonWithCountsRow(row: $0) }
    }

    /// 批量身份摘要（名字 + match_threshold）；未命中的 id 不出现在结果中。
    public func summaries(ids: [String]) throws -> [String: PersonIdentitySummary] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: PersonIdentitySummary] = [:]
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare(
                "SELECT id, name, match_threshold FROM persons WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            for row in rows {
                guard let id = row[0].textValue else { continue }
                result[id] = PersonIdentitySummary(
                    id: id,
                    name: row[1].textValue ?? "",
                    matchThreshold: row[2].doubleValue ?? 0.65
                )
            }
        }
        return result
    }

    public func get(id: String) throws -> PersonRow? {
        guard let row = try connection.prepare(
            "SELECT *, (SELECT ph.filepath FROM person_photos pp JOIN photos ph ON ph.id = pp.photo_id WHERE pp.person_id = persons.id ORDER BY pp.created_at DESC, pp.id DESC LIMIT 1) as thumbnail_path FROM persons WHERE id = ?"
        ).get([.text(id)]) else {
            return nil
        }
        return try PersonRow(row: row)
    }

    /// 按精确姓名查找，不存在则创建（角色绑定与对账的身份 adopt 入口）。
    /// 这不是复活路径：删除身份时其 role_bindings / matched_person_id 已被
    /// applyIdentityTransition(.delete) 清空，同名调用只可能来自用户显式绑定。
    public func upsertByName(name: String, keywords: [String]? = nil) throws -> String {
        guard let existing = try connection.prepare("SELECT id, keywords FROM persons WHERE name = ?").get([.text(name)]) else {
            return try create(name: name, keywords: keywords)
        }
        let existingId = existing[0].textValue ?? ""
        if let keywords, !keywords.isEmpty {
            let existingKeywords = parseKeywords(existing[1].textValue ?? "")
            var merged = existingKeywords
            for keyword in keywords where !merged.contains(keyword) {
                merged.append(keyword)
            }
            if merged.count != existingKeywords.count {
                try updatePersonRow(id: existingId, fields: PersonUpdateFields(keywords: merged))
            }
        }
        return existingId
    }

    public func create(name: String, keywords: [String]? = nil) throws -> String {
        let id = newUUIDString()
        let now = nowISOString()
        _ = try connection.prepare(
            "INSERT INTO persons (id, name, keywords, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
        ).run([.text(id), .text(name), .text(jsonString(keywords ?? [])), .text(now), .text(now)])
        return id
    }

    // ─────────────────────────── 身份生命周期 ───────────────────────────

    /// 绑定入口：把簇绑定到角色名所代表的身份（adopt-or-create + 照片桥接 + 显式链接）。
    /// role_bindings 行由 FaceRepo.updateBinding 维护；这里只做身份侧关联。
    @discardableResult
    public func bindRole(
        clusterId: Int64,
        sessionId: String,
        roleName: String,
        keywords: [String],
        members: [PersonPhotoInput]
    ) throws -> PersonIdentityOutcome {
        let name = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let personId = try upsertByName(name: name, keywords: keywords)
        try addPhotos(personId: personId, sessionId: sessionId, photos: members)
        return try applyIdentityTransition(
            .bind(personId: personId, name: name, sessionId: sessionId, clusterIds: [clusterId]))
    }

    /// 改名：persons.name 更新之外，同步全部由该身份持有的 role_bindings.role_name，
    /// 旧名不再写回；旧名已写入 XMP 的部分进入清理计划。
    @discardableResult
    public func update(id: String, fields: PersonUpdateFields) throws -> PersonIdentityOutcome {
        guard let previousName = try connection.prepare("SELECT name FROM persons WHERE id = ?")
            .get([.text(id)])?[0].textValue else {
            return .noop
        }
        var effective = fields
        if let raw = fields.name {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空名不是身份（会把角色名同步成无法写回的空关键词）：拒绝并保持原名。
            effective = PersonUpdateFields(
                name: trimmed.isEmpty ? previousName : trimmed,
                keywords: fields.keywords,
                notes: fields.notes,
                matchThreshold: fields.matchThreshold)
        }
        try updatePersonRow(id: id, fields: effective)
        guard let newName = effective.name, newName != previousName else {
            return PersonIdentityOutcome(personId: id)
        }
        return try applyIdentityTransition(.rename(personId: id, from: previousName, to: newName))
    }

    /// 删除：解绑该身份持有的全部簇（role_bindings + matched_person_id），删除身份
    /// 及其投影；名字与角色关键词若已写入 XMP，进入清理计划。删除后 upsertByName
    /// 无从复活（I2）。
    @discardableResult
    public func delete(id: String) throws -> PersonIdentityOutcome {
        guard let name = try connection.prepare("SELECT name FROM persons WHERE id = ?")
            .get([.text(id)])?[0].textValue else {
            return .noop
        }
        return try applyIdentityTransition(.delete(personId: id, name: name))
    }

    /// 合并：投影/向量/关键词并入目标，源身份的簇与角色名重指向目标后删除源身份。
    /// 源名若已写入 XMP，进入清理计划（目标名由后续写回补写）。
    @discardableResult
    public func merge(sourceId: String, targetId: String) throws -> PersonIdentityOutcome {
        guard let sourceName = try connection.prepare("SELECT name FROM persons WHERE id = ?")
            .get([.text(sourceId)])?[0].textValue,
            let targetName = try connection.prepare("SELECT name FROM persons WHERE id = ?")
            .get([.text(targetId)])?[0].textValue else {
            return .noop
        }
        if sourceId == targetId {
            return PersonIdentityOutcome(personId: targetId)
        }
        return try applyIdentityTransition(
            .merge(sourceId: sourceId, sourceName: sourceName, targetId: targetId, targetName: targetName))
    }

    /// 按会话对账角色绑定与人物库投影；同时把按名归属的簇补上显式链接
    /// （rename/delete 的归属判据）。
    public func reconcileSession(sessionId: String) throws {
        let bindingRows = try connection.prepare(
            "SELECT rb.role_name, fcm.photo_id, fcm.bbox, fcm.confidence FROM role_bindings rb JOIN face_cluster_members fcm ON fcm.cluster_id = rb.cluster_id WHERE rb.session_id = ?"
        ).query([.text(sessionId)])

        var desiredByRole: [String: [String: (bbox: [Double], confidence: Double)]] = [:]
        for row in bindingRows {
            let roleName = row[0].textValue ?? ""
            let photoId = row[1].textValue ?? ""
            let bbox = decodeBbox(row[2].textValue ?? "")
            let confidence = row[3].doubleValue ?? 0
            if desiredByRole[roleName] == nil {
                desiredByRole[roleName] = [:]
            }
            desiredByRole[roleName]?[photoId] = (bbox, confidence)
        }

        var affected: Set<String> = []
        for roleName in desiredByRole.keys {
            let personId = try upsertByName(name: roleName)
            affected.insert(personId)
            try linkClusters(named: roleName, sessionId: sessionId, personId: personId)
        }
        let linkedRows = try connection.prepare("SELECT DISTINCT person_id FROM person_photos WHERE session_id = ?")
            .query([.text(sessionId)])
        for row in linkedRows {
            if let personId = row[0].textValue {
                affected.insert(personId)
            }
        }
        if affected.isEmpty { return }

        let now = nowISOString()
        let insertStmt = try connection.prepare(
            "INSERT OR IGNORE INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for personId in affected {
                let roleName = try getPersonName(personId) ?? ""
                guard let desired = desiredByRole[roleName], !desired.isEmpty else {
                    _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ? AND session_id = ?")
                        .run([.text(personId), .text(sessionId)])
                    continue
                }
                let existingRows = try connection.prepare(
                    "SELECT photo_id FROM person_photos WHERE person_id = ? AND session_id = ?"
                ).query([.text(personId), .text(sessionId)])
                for existing in existingRows {
                    if let existingPhotoId = existing[0].textValue, desired[existingPhotoId] == nil {
                        _ = try connection.prepare(
                            "DELETE FROM person_photos WHERE person_id = ? AND session_id = ? AND photo_id = ?"
                        ).run([.text(personId), .text(sessionId), .text(existingPhotoId)])
                    }
                }
                for (photoId, info) in desired {
                    _ = try insertStmt.run([
                        .text(personId), .text(photoId), .text(sessionId),
                        .text(jsonString(info.bbox)), .real(info.confidence), .text(now),
                    ])
                }
            }
        }
    }

    // ─────────────────────── 身份生命周期唯一实现 ───────────────────────

    private enum IdentityTransition {
        case bind(personId: String, name: String, sessionId: String, clusterIds: [Int64])
        case rename(personId: String, from: String, to: String)
        case delete(personId: String, name: String)
        case merge(sourceId: String, sourceName: String, targetId: String, targetName: String)
    }

    /// 所有身份变更的唯一落地函数（I1–I4）。
    private func applyIdentityTransition(_ transition: IdentityTransition) throws -> PersonIdentityOutcome {
        switch transition {
        case .bind(let personId, _, _, let clusterIds):
            try linkClusters(clusterIds, personId: personId)
            return PersonIdentityOutcome(personId: personId)

        case .rename(let personId, let from, let to):
            let clusterIds = try ownedClusterIds(personId: personId, name: from)
            let cleanup = try cleanupPlan(sessions: try sessions(of: clusterIds), keywords: [from])
            try connection.transaction {
                for chunk in clusterIds.chunked(by: 400) where !chunk.isEmpty {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    _ = try connection.prepare(
                        "UPDATE role_bindings SET role_name = ?, updated_at = ? WHERE cluster_id IN (\(placeholders))"
                    ).run([.text(to), .text(nowISOString())] + chunk.map { .int($0) })
                }
            }
            return PersonIdentityOutcome(personId: personId, cleanup: cleanup)

        case .delete(let personId, let name):
            let clusterIds = try ownedClusterIds(personId: personId, name: name)
            let deprecated = [name] + (try bindingKeywords(clusterIds: clusterIds))
            let cleanup = try cleanupPlan(sessions: try sessions(of: clusterIds), keywords: deprecated)
            try connection.transaction {
                for chunk in clusterIds.chunked(by: 400) where !chunk.isEmpty {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    _ = try connection.prepare(
                        "DELETE FROM role_bindings WHERE cluster_id IN (\(placeholders))"
                    ).run(chunk.map { .int($0) })
                    _ = try connection.prepare(
                        "UPDATE face_clusters SET matched_person_id = NULL, match_confidence = NULL, status = 'unbound', updated_at = ? WHERE id IN (\(placeholders))"
                    ).run([.text(nowISOString())] + chunk.map { .int($0) })
                }
                _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ?").run([.text(personId)])
                _ = try connection.prepare("DELETE FROM person_embeddings WHERE person_id = ?").run([.text(personId)])
                _ = try connection.prepare("DELETE FROM persons WHERE id = ?").run([.text(personId)])
            }
            return PersonIdentityOutcome(personId: personId, cleanup: cleanup)

        case .merge(let sourceId, let sourceName, let targetId, let targetName):
            let clusterIds = try ownedClusterIds(personId: sourceId, name: sourceName)
            let deprecated = [sourceName] + (try bindingKeywords(clusterIds: clusterIds))
            let cleanup = try cleanupPlan(sessions: try sessions(of: clusterIds), keywords: deprecated)
            try connection.transaction {
                _ = try connection.prepare("UPDATE person_embeddings SET person_id = ? WHERE person_id = ?")
                    .run([.text(targetId), .text(sourceId)])
                _ = try connection.prepare("UPDATE person_photos SET person_id = ? WHERE person_id = ?")
                    .run([.text(targetId), .text(sourceId)])
                let mergedKeywords = try getMergedKeywords(sourceId: sourceId, targetId: targetId)
                _ = try connection.prepare("UPDATE persons SET keywords = ?, updated_at = ? WHERE id = ?")
                    .run([.text(jsonString(mergedKeywords)), .text(nowISOString()), .text(targetId)])
                for chunk in clusterIds.chunked(by: 400) where !chunk.isEmpty {
                    let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                    _ = try connection.prepare(
                        "UPDATE role_bindings SET role_name = ?, updated_at = ? WHERE cluster_id IN (\(placeholders))"
                    ).run([.text(targetName), .text(nowISOString())] + chunk.map { .int($0) })
                    _ = try connection.prepare(
                        "UPDATE face_clusters SET matched_person_id = ?, updated_at = ? WHERE id IN (\(placeholders))"
                    ).run([.text(targetId), .text(nowISOString())] + chunk.map { .int($0) })
                }
                _ = try connection.prepare("DELETE FROM persons WHERE id = ?").run([.text(sourceId)])
            }
            return PersonIdentityOutcome(personId: targetId, mergedInto: targetId, cleanup: cleanup)
        }
    }

    /// 身份持有的簇：显式链接的 ∪ （该名字无第二持有者时）按名可被认领的未链接簇。
    /// 删除/改名/合并只作用于这个集合，避免误伤另一个同名身份。
    private func ownedClusterIds(personId: String, name: String) throws -> [Int64] {
        var ids = Set<Int64>()
        let linked = try connection.prepare("SELECT id FROM face_clusters WHERE matched_person_id = ?")
            .query([.text(personId)])
        for row in linked {
            if let id = row[0].intValue { ids.insert(id) }
        }
        let otherSameName = try connection.prepare("SELECT COUNT(*) FROM persons WHERE name = ? AND id <> ?")
            .get([.text(name), .text(personId)])
        if (otherSameName?[0].intValue ?? 0) == 0 {
            let byName = try connection.prepare("""
                SELECT rb.cluster_id FROM role_bindings rb
                JOIN face_clusters c ON c.id = rb.cluster_id
                WHERE rb.role_name = ? AND c.matched_person_id IS NULL
                """).query([.text(name)])
            for row in byName {
                if let id = row[0].intValue { ids.insert(id) }
            }
        }
        return ids.sorted()
    }

    private func linkClusters(_ clusterIds: [Int64], personId: String) throws {
        for chunk in clusterIds.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "UPDATE face_clusters SET matched_person_id = ?, updated_at = ? WHERE id IN (\(placeholders))"
            ).run([.text(personId), .text(nowISOString())] + chunk.map { .int($0) })
        }
    }

    private func linkClusters(named roleName: String, sessionId: String, personId: String) throws {
        _ = try connection.prepare("""
            UPDATE face_clusters SET matched_person_id = ?, updated_at = ?
            WHERE session_id = ? AND id IN (
              SELECT rb.cluster_id FROM role_bindings rb
              WHERE rb.session_id = ? AND rb.role_name = ?
            )
            """).run([.text(personId), .text(nowISOString()), .text(sessionId), .text(sessionId), .text(roleName)])
    }

    private func sessions(of clusterIds: [Int64]) throws -> Set<String> {
        var result = Set<String>()
        for chunk in clusterIds.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT DISTINCT session_id FROM face_clusters WHERE id IN (\(placeholders))"
            ).query(chunk.map { .int($0) })
            for row in rows {
                if let sessionId = row[0].textValue { result.insert(sessionId) }
            }
        }
        return result
    }

    /// 这些簇上的绑定带了哪些额外关键词（删除/合并后不再写回，需要清理）。
    private func bindingKeywords(clusterIds: [Int64]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for chunk in clusterIds.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT keywords FROM role_bindings WHERE cluster_id IN (\(placeholders))"
            ).query(chunk.map { .int($0) })
            for row in rows {
                for keyword in parseKeywords(row[0].textValue ?? "") where seen.insert(keyword).inserted {
                    result.append(keyword)
                }
            }
        }
        return result
    }

    /// XMP 清理计划：以 metadata_keyword_origins（source='face-keyword'，active=1）
    /// 为凭据反查实际持有这些关键词的照片 —— 与簇成员身份**无关**，因此成员被
    /// 重扫/移出后的残留同样可清理。
    private func cleanupPlan(sessions: Set<String>, keywords: [String]) throws -> [PersonKeywordCleanup] {
        var wanted: [String] = []
        var seen = Set<String>()
        for raw in keywords {
            let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyword.isEmpty && seen.insert(keyword).inserted { wanted.append(keyword) }
        }
        guard !wanted.isEmpty, !sessions.isEmpty else { return [] }

        let placeholders = wanted.map { _ in "?" }.joined(separator: ",")
        let originRows = try connection.prepare("""
            SELECT DISTINCT xmp_path, keyword FROM metadata_keyword_origins
            WHERE source = 'face-keyword' AND active = 1 AND keyword IN (\(placeholders))
            """).query(wanted.map { .text($0) })
        var keywordsByPath: [String: Set<String>] = [:]
        for row in originRows {
            guard let path = row[0].textValue, let keyword = row[1].textValue else { continue }
            keywordsByPath[path, default: []].insert(keyword)
        }
        if keywordsByPath.isEmpty { return [] }

        var entries: [PersonKeywordCleanup] = []
        var seenPhotos = Set<String>()
        let sessionList = Array(sessions)
        for chunk in sessionList.chunked(by: 400) {
            let sessionPlaceholders = chunk.map { _ in "?" }.joined(separator: ",")
            let photos = try connection.prepare("""
                SELECT id, session_id, filepath FROM photos
                WHERE session_id IN (\(sessionPlaceholders))
                """).query(chunk.map { .text($0) })
            for row in photos {
                guard let photoId = row[0].textValue,
                      let sessionId = row[1].textValue,
                      let filepath = row[2].textValue else { continue }
                let xmpPath = TSPath.xmpSidecarPath(filepath)
                guard let owned = keywordsByPath[xmpPath] else { continue }
                guard seenPhotos.insert(photoId).inserted else { continue }
                let ordered = wanted.filter { owned.contains($0) }
                guard !ordered.isEmpty else { continue }
                entries.append(PersonKeywordCleanup(
                    photoId: photoId, sessionId: sessionId, xmpPath: xmpPath, keywords: ordered))
            }
        }
        return entries
    }

    private func getPersonName(_ id: String) throws -> String? {
        try connection.prepare("SELECT name FROM persons WHERE id = ?").get([.text(id)])?[0].textValue
    }

    // ─────────────────────────── 投影维护 ───────────────────────────

    /// 批量添加照片到人物（INSERT OR IGNORE，重复安全，可用于重复绑定）。
    public func addPhotos(personId: String, sessionId: String, photos: [PersonPhotoInput]) throws {
        if photos.isEmpty { return }
        let now = nowISOString()
        let stmt = try connection.prepare(
            "INSERT OR IGNORE INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for photo in photos {
                _ = try stmt.run([
                    .text(personId), .text(photo.photoId), .text(sessionId),
                    .text(jsonString(photo.faceBbox)), .real(photo.confidence), .text(now),
                ])
            }
        }
    }

    /// 纯行更新（不触发身份生命周期）：生命周期内的改名经 applyIdentityTransition。
    private func updatePersonRow(id: String, fields: PersonUpdateFields) throws {
        let now = nowISOString()
        var sets: [String] = []
        var values: [DBValue?] = []

        if let name = fields.name {
            sets.append("name = ?")
            values.append(.text(name))
        }
        if let keywords = fields.keywords {
            sets.append("keywords = ?")
            values.append(.text(jsonString(keywords)))
        }
        if let notes = fields.notes {
            sets.append("notes = ?")
            values.append(.text(notes))
        }
        if let matchThreshold = fields.matchThreshold {
            sets.append("match_threshold = ?")
            values.append(.real(matchThreshold))
        }

        if sets.isEmpty { return }

        sets.append("updated_at = ?")
        values.append(.text(now))
        values.append(.text(id))

        _ = try connection.prepare("UPDATE persons SET \(sets.joined(separator: ", ")) WHERE id = ?").run(values)
    }

    public func removePhoto(personId: String, photoId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM person_photos WHERE person_id = ? AND photo_id = ?")
                .run([.text(personId), .text(photoId)])
            _ = try connection.prepare("DELETE FROM person_embeddings WHERE person_id = ? AND photo_id = ?")
                .run([.text(personId), .text(photoId)])
        }
    }

    /// 批量保存嵌入（INSERT OR REPLACE，按 face_observation_id 唯一替换）。
    public func saveEmbeddings(embeddings: [SaveEmbeddingInput]) throws {
        let now = nowISOString()
        let stmt = try connection.prepare(
            "INSERT OR REPLACE INTO person_embeddings (person_id, embedding, photo_id, session_id, face_observation_id, face_bbox, quality, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for emb in embeddings {
                _ = try stmt.run([
                    .text(emb.personId),
                    .blob(float32Data(emb.embedding)),
                    .text(emb.photoId),
                    .text(emb.sessionId),
                    emb.faceObservationId.map { .int($0) },
                    .text(jsonString(emb.faceBbox)),
                    .real(emb.quality),
                    .text(now),
                ])
            }
        }
    }

    public func getAllEmbeddings() throws -> [PersonEmbeddingRef] {
        let rows = try connection.prepare(
            "SELECT person_id, embedding, face_observation_id FROM person_embeddings"
        ).query()
        return rows.map { row in
            PersonEmbeddingRef(
                personId: row[0].textValue ?? "",
                embedding: row[1].blobValue ?? Data(),
                faceObservationId: row[2].intValue
            )
        }
    }

    public func countPhotos(personId: String) throws -> Int {
        let row = try connection.prepare("SELECT COUNT(*) as count FROM person_photos WHERE person_id = ?")
            .get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func getSessionCount(personId: String) throws -> Int {
        let row = try connection.prepare("SELECT COUNT(DISTINCT session_id) as count FROM person_photos WHERE person_id = ?")
            .get([.text(personId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func getPhotosWithDetails(personId: String, sessionIds: [String]? = nil, limit: Int? = nil, offset: Int? = nil) throws -> (photos: [PersonPhotoDetail], total: Int) {
        var whereClause = "pp.person_id = ?"
        var params: [DBValue?] = [.text(personId)]
        if let sessionIds, !sessionIds.isEmpty {
            whereClause += " AND pp.session_id IN (\(sessionIds.map { _ in "?" }.joined(separator: ",")))"
            params.append(contentsOf: sessionIds.map { .text($0) })
        }

        let countRow = try connection.prepare("SELECT COUNT(*) as count FROM person_photos pp WHERE \(whereClause)")
            .get(params)
        let total = Int(countRow?[0].intValue ?? 0)

        var sql = """
        SELECT pp.*, s.name as session_name, p.filename, p.filepath
        FROM person_photos pp
        JOIN sessions s ON pp.session_id = s.id
        JOIN photos p ON pp.photo_id = p.id
        WHERE \(whereClause)
        ORDER BY pp.created_at DESC
        """
        var queryParams = params
        if let limit {
            sql += " LIMIT ?"
            queryParams.append(.int(Int64(limit)))
        }
        if let offset {
            sql += " OFFSET ?"
            queryParams.append(.int(Int64(offset)))
        }

        let rows = try connection.prepare(sql).query(queryParams)
        let photos = try rows.map { try PersonPhotoDetail(row: $0) }
        return (photos, total)
    }

    // ── 私有辅助 ──

    private func getMergedKeywords(sourceId: String, targetId: String) throws -> [String] {
        var merged: [String] = []
        let sourceRow = try connection.prepare("SELECT keywords FROM persons WHERE id = ?").get([.text(sourceId)])
        let targetRow = try connection.prepare("SELECT keywords FROM persons WHERE id = ?").get([.text(targetId)])
        if let sourceRow {
            for keyword in parseKeywords(sourceRow[0].textValue ?? "") where !merged.contains(keyword) {
                merged.append(keyword)
            }
        }
        if let targetRow {
            for keyword in parseKeywords(targetRow[0].textValue ?? "") where !merged.contains(keyword) {
                merged.append(keyword)
            }
        }
        return merged
    }

    private func parseKeywords(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return parsed
    }

    private func decodeBbox(_ raw: String) -> [Double] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Double].self, from: data) else {
            return []
        }
        return decoded
    }
}

private extension DBValue {
    var blobValue: Data? {
        if case .blob(let data) = self { return data }
        return nil
    }
}

/// TS: JSON.stringify(keywords) —— JSON 数组文本。
private func jsonString(_ keywords: [String]) -> String {
    guard let data = try? JSONEncoder().encode(keywords) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// TS: JSON.stringify(faceBbox)（number[]）。
private func jsonString(_ bbox: [Double]) -> String {
    guard let data = try? JSONEncoder().encode(bbox) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// TS: Buffer.from(new Float32Array(embedding).buffer) —— Float32 小端字节序。
private func float32Data(_ floats: [Float]) -> Data {
    floats.withUnsafeBytes { Data($0) }
}


