// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PersonRepo+Identity.swift
// 源：PersonRepo.swift（HEAD 3fbf997）；纯拆分（身份生命周期 + 写入），方法体/SQL 逐字未改。
// applyIdentityTransition 仍是唯一落地函数（I1–I4 语义不变）。
// 访问级：connection 为 internal；linkClusters(_:personId:) 为 internal（见主文件头部）。

import Foundation
import GatherProtocol

extension PersonRepo {
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
                _ = try connection.prepare("UPDATE face_identity_feedback SET person_id = ? WHERE person_id = ?")
                    .run([.text(targetId), .text(sourceId)])
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

    func linkClusters(_ clusterIds: [Int64], personId: String) throws {
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
}

/// TS: JSON.stringify(keywords) —— JSON 数组文本。
private func jsonString(_ keywords: [String]) -> String {
    guard let data = try? JSONEncoder().encode(keywords) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}
