// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/TriageRepo.swift
// P0 / T0：triage_suggestions 的读写 + 候选装配（逻辑资产代表行口径）。
//
// 只做 SQL 与 DTO；纯函数评估、决策写入/历史由 Application 的 TriageService 编排。
// 代表行规则复用 PhotoRepo.preferredRowOrderSQL（与图库/挑片同源）。
import Foundation
import GatherProtocol

public final class TriageRepo: TriageRepository {
    private static let precomputedMarker = "%\"precomputed\":true%"
    private static let chunkSize = 800

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 候选装配

    public func loadCandidates(sessionId: String) throws -> TriageCandidateLoad {
        let photos = try loadPhotos(sessionId: sessionId)
        guard !photos.isEmpty else {
            return TriageCandidateLoad(candidates: [], coverage: 0)
        }
        let reps = try loadRepresentatives(sessionId: sessionId, photos: photos)
        let repByPhoto = reps.repByPhoto

        let qualityByFile = try loadQuality(assetFileIds: Array(Set(photos.compactMap(\.assetFileId))))
        let dimensions = Dictionary(
            uniqueKeysWithValues: photos.map { ($0.id, (width: $0.width, height: $0.height)) })
        let faceByRep = try loadFaces(
            sessionId: sessionId, repByPhoto: repByPhoto, dimensions: dimensions)
        let decisions = try loadDecisionSnapshots(
            sessionId: sessionId, repByPhoto: repByPhoto)
        let groups = try loadGroups(
            sessionId: sessionId,
            repByPhoto: repByPhoto
        )
        // 组 → 成员反查表：避免每个代表行都线性扫全部组（20k 时是千万级包含判断）。
        var groupsByMember: [String: [TriageGroupRecord]] = [:]
        for group in groups {
            for member in group.memberPhotoIds {
                groupsByMember[member, default: []].append(group)
            }
        }

        var records: [TriageCandidateRecord] = []
        var analyzedCount = 0
        for rep in reps.repRows.sorted(by: { $0.rowId < $1.rowId }) {
            let quality = rep.assetFileId.flatMap { qualityByFile[$0] }
            if quality?.status == .succeeded { analyzedCount += 1 }
            let faces = faceByRep[rep.id] ?? (count: 0, maxArea: 0)
            let decision = decisions[rep.id]
            let repGroups = groupsByMember[rep.id] ?? []
            records.append(TriageCandidateRecord(
                photoId: rep.id,
                quality: quality,
                faceCount: faces.count,
                maxFaceAreaRatio: faces.maxArea,
                groups: repGroups,
                manualDecision: decision?.decision,
                decisionSource: decision?.source,
                importOrder: Int(rep.rowId),
                width: rep.width,
                height: rep.height,
                fileSize: rep.fileSize
            ))
        }
        let coverage = records.isEmpty ? 0 : Double(analyzedCount) / Double(records.count)
        return TriageCandidateLoad(candidates: records, coverage: coverage)
    }

    // MARK: - 指纹 / 建议 / 摘要

    public func fingerprint(
        sessionId: String,
        policyVersion: String,
        thresholdsDigest: String
    ) throws -> String {
        let quality = try qualityFingerprint(sessionId: sessionId)
        let photos = try photoFingerprint(sessionId: sessionId)
        let faces = try faceFingerprint(sessionId: sessionId)
        let similarity = try latestSimilarityId(sessionId: sessionId)
        let duplicate = try duplicateFingerprint(sessionId: sessionId)
        let navigation = try navigationFingerprint(sessionId: sessionId)
        let material = [
            sessionId,
            policyVersion,
            thresholdsDigest,
            "\(quality.count)", quality.maxUpdatedAt,
            // 新增照片/变体/资产链接会改变候选集；不能用旧建议冒充新鲜。
            // mappingDigest 只随 asset_id/asset_file_id 长度变化（relink 会变），
            // 不再用 photos.updated_at：状态/checksum/维度写入不该让整批建议过期。
            "\(photos.count)", "\(photos.maxRowId)", "\(photos.assetCount)",
            "\(photos.mappingDigest)",
            // 人工决策不进指纹：建议是“决策前”的产物，人工决策在 apply 时跳过
            //（t0-triage-policy §6 / 未决问题 6）。把 manual 纳入会让任何一次
            // 人工改选把整批建议判 stale，SKIPPED_MANUAL 主流程不可达。
            // 人脸重跑可能改变 multiFace/闭眼保护。
            "\(faces.count)", "\(faces.maxId)",
            "\(similarity)",
            "\(duplicate.count)", duplicate.maxCreatedAt,
            "\(navigation.count)", navigation.maxUpdatedAt,
        ].joined(separator: "|")
        return SHA256.hash(Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func photoFingerprint(
        sessionId: String
    ) throws -> (count: Int, maxRowId: Int64, assetCount: Int, mappingDigest: Int64) {
        let row = try connection.prepare("""
            SELECT COUNT(*), COALESCE(MAX(rowid), 0),
                   COUNT(DISTINCT COALESCE(NULLIF(asset_id, ''), id)),
                   COALESCE(SUM(
                     LENGTH(COALESCE(asset_id, '')) + LENGTH(COALESCE(asset_file_id, ''))
                   ), 0)
            FROM photos WHERE session_id = ?
            """).get([.text(sessionId)])
        return (
            Int(row?[0].intValue ?? 0),
            row?[1].intValue ?? 0,
            Int(row?[2].intValue ?? 0),
            row?[3].intValue ?? 0
        )
    }

    private func faceFingerprint(
        sessionId: String
    ) throws -> (count: Int, maxId: Int64) {
        let row = try connection.prepare("""
            SELECT COUNT(*), COALESCE(MAX(id), 0)
            FROM face_observations WHERE session_id = ?
            """).get([.text(sessionId)])
        return (Int(row?[0].intValue ?? 0), row?[1].intValue ?? 0)
    }

    public func deleteSuggestionsForManualAssets(sessionId: String) throws {
        _ = try connection.prepare("""
            DELETE FROM triage_suggestions
            WHERE session_id = ?
              AND photo_id IN (
                SELECT p.id FROM photos p
                WHERE p.session_id = ?
                  AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (
                    SELECT DISTINCT COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                    FROM culling_decisions d
                    JOIN photos p2 ON p2.id = d.photo_id
                    WHERE d.session_id = ?
                      AND d.decision_source = 'manual'
                      AND d.decision <> 'pending'
                  )
              )
            """).run([.text(sessionId), .text(sessionId), .text(sessionId)])
    }

    public func eligibleSuggestionCount(sessionId: String) throws -> Int {
        let row = try connection.prepare("""
            WITH manual_gid AS (
              SELECT DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
              FROM culling_decisions d
              JOIN photos p ON p.id = d.photo_id AND p.session_id = d.session_id
              WHERE d.session_id = ?
                AND d.decision_source = 'manual'
                AND d.decision <> 'pending'
            ),
            rep AS (
              SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
              FROM photos p
              WHERE p.session_id = ? AND \(PhotoVisibility.visiblePredicate())
              GROUP BY gid
            )
            SELECT COUNT(*) FROM rep WHERE gid NOT IN (SELECT gid FROM manual_gid)
            """).get([.text(sessionId), .text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    public func loadSuggestions(sessionId: String) throws -> [TriageSuggestion] {
        let rows = try connection.prepare("""
            SELECT photo_id, verdict, score, confidence, reasons_json, group_id,
                   policy_version, input_fingerprint, computed_at
            FROM triage_suggestions
            WHERE session_id = ?
            ORDER BY photo_id
            """).query([.text(sessionId)])
        return rows.map { row in
            let verdict = TriageVerdict(rawValue: row[1].textValue ?? "") ?? .review
            let reasons: [TriageReason]
            do {
                reasons = try JSONDecoder().decode(
                    [TriageReason].self,
                    from: Data((row[4].textValue ?? "[]").utf8)
                )
            } catch {
                reasons = []
            }
            return TriageSuggestion(
                photoId: row[0].textValue ?? "",
                verdict: verdict,
                score: row[2].doubleValue ?? 0,
                confidence: row[3].doubleValue ?? 0,
                reasons: reasons,
                groupId: row[5].textValue,
                policyVersion: row[6].textValue ?? "",
                inputFingerprint: row[7].textValue ?? "",
                computedAt: row[8].textValue ?? ""
            )
        }
    }

    public func replaceSuggestions(sessionId: String, suggestions: [TriageSuggestion]) throws {
        _ = try connection.prepare("DELETE FROM triage_suggestions WHERE session_id = ?")
            .run([.text(sessionId)])
        let insert = try connection.prepare("""
            INSERT INTO triage_suggestions
              (photo_id, session_id, verdict, score, confidence, reasons_json, group_id,
               policy_version, input_fingerprint, computed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for suggestion in suggestions {
            let reasons: String
            do {
                let data = try JSONEncoder().encode(suggestion.reasons)
                reasons = String(data: data, encoding: .utf8) ?? "[]"
            } catch {
                reasons = "[]"
            }
            _ = try insert.run([
                .text(suggestion.photoId), .text(sessionId),
                .text(suggestion.verdict.rawValue), .real(suggestion.score),
                .real(suggestion.confidence), .text(reasons),
                suggestion.groupId.map(DBValue.text) ?? .null,
                .text(suggestion.policyVersion), .text(suggestion.inputFingerprint),
                .text(suggestion.computedAt),
            ])
        }
    }

    public func summary(
        sessionId: String,
        policyVersion: String,
        fingerprint: String
    ) throws -> TriageSummary {
        // 空行不再等于“过期”：只有存在可生成候选（未人工决策的代表行）时才算 stale。
        // 全人工/全无质量/空会话都返回 stale=false 与 0 计数，而不是永久“已过期”。
        let eligible = try eligibleSuggestionCount(sessionId: sessionId)
        // 只聚合，不把所有 suggestion 的 reasons_json 解码进 Swift（20k 时是纯浪费）。
        // 人工决策按资产排除：RAW+JPEG 任一成员被人工裁决，整条资产的建议都不计数。
        let manualExclusion = """
            NOT EXISTS (
              SELECT 1 FROM culling_decisions d
              JOIN photos p2 ON p2.id = d.photo_id
              WHERE d.session_id = t.session_id
                AND d.decision_source = 'manual'
                AND d.decision <> 'pending'
                AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                    = COALESCE(NULLIF(p.asset_id, ''), p.id)
            )
            """
        let stats = try connection.prepare("""
            SELECT COUNT(*), MAX(t.computed_at),
                   SUM(CASE WHEN t.policy_version != ? OR t.input_fingerprint != ?
                            THEN 1 ELSE 0 END)
            FROM triage_suggestions t
            JOIN photos p ON p.id = t.photo_id
            WHERE t.session_id = ? AND \(manualExclusion)
              AND \(PhotoVisibility.visiblePredicate())
            """).get([.text(policyVersion), .text(fingerprint), .text(sessionId)])
        let total = Int(stats?[0].intValue ?? 0)
        let generatedAt = stats?[1].textValue ?? ""
        let mismatched = Int(stats?[2].intValue ?? 0)
        let stale = (total == 0 && eligible > 0) || mismatched > 0

        var keep = 0, reject = 0, review = 0
        let verdictRows = try connection.prepare("""
            SELECT t.verdict, COUNT(*)
            FROM triage_suggestions t
            JOIN photos p ON p.id = t.photo_id
            WHERE t.session_id = ? AND \(manualExclusion)
              AND \(PhotoVisibility.visiblePredicate())
            GROUP BY t.verdict
            """).query([.text(sessionId)])
        for row in verdictRows {
            let count = Int(row[1].intValue ?? 0)
            switch row[0].textValue {
            case TriageVerdict.keep.rawValue: keep = count
            case TriageVerdict.reject.rawValue: reject = count
            case TriageVerdict.review.rawValue: review = count
            default: break
            }
        }
        let coverage = try coverage(sessionId: sessionId)
        return TriageSummary(
            counts: TriageCounts(
                keep: keep, reject: reject, review: review,
                total: total, coverage: coverage
            ),
            stale: stale,
            policyVersion: policyVersion,
            inputFingerprint: fingerprint,
            generatedAt: generatedAt
        )
    }

    // MARK: - 应用目标

    public func loadApplyTargets(
        sessionId: String,
        representativePhotoIds: [String]
    ) throws -> [TriageApplyTargetRecord] {
        guard !representativePhotoIds.isEmpty else { return [] }
        let wanted = Set(representativePhotoIds)
        var variantsByRep: [String: [TriageVariantRecord]] = [:]
        // 目标资产下推 SQL：只返回所选资产（及其 RAW/JPEG 变体），不再把全会话
        // 照片读进 Swift 再过滤。按 800 分块避开 SQLite 变量上限。
        for chunk in chunks(representativePhotoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var params: [DBValue?] = [.text(sessionId), .text(sessionId)]
            params.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
                       (SELECT p2.id FROM photos p2
                         WHERE p2.session_id = p.session_id
                           AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                               = COALESCE(NULLIF(p.asset_id, ''), p.id)
                           AND \(PhotoVisibility.visiblePredicate(alias: "p2"))
                         ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))
                         LIMIT 1) AS rep_id,
                       p.id, p.rowid, d.decision, d.decision_source, d.revision, d.group_id,
                       c.rating, c.label
                FROM photos p
                LEFT JOIN culling_decisions d
                  ON d.session_id = p.session_id AND d.photo_id = p.id
                LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
                WHERE p.session_id = ?
                  AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (
                    SELECT COALESCE(NULLIF(p3.asset_id, ''), p3.id)
                    FROM photos p3
                    WHERE p3.session_id = ? AND p3.id IN (\(placeholders))
                  )
                ORDER BY p.rowid
                """).query(params)
            for row in rows {
                let rep = row[1].textValue ?? ""
                guard wanted.contains(rep) else { continue }
                let photoId = row[2].textValue ?? ""
                let decision = row[4].textValue ?? "pending"
                let source = row[5].textValue
                let revision = Int(row[6].intValue ?? 0)
                let groupId = row[7].textValue ?? ""
                let rating = Int(row[8].intValue ?? 0)
                let label = row[9].textValue ?? "None"
                variantsByRep[rep, default: []].append(TriageVariantRecord(
                    photoId: photoId,
                    decision: decision,
                    decisionSource: source,
                    revision: revision,
                    rating: rating,
                    colorLabel: label,
                    groupId: groupId
                ))
            }
        }
        return wanted.sorted().compactMap { rep in
            guard let variants = variantsByRep[rep], !variants.isEmpty else { return nil }
            return TriageApplyTargetRecord(representativePhotoId: rep, variants: variants)
        }
    }

    // MARK: - 内部：照片/代表行

    private struct PhotoLite {
        let id: String
        let gid: String
        let assetFileId: String?
        let rowId: Int64
        let width: Int
        let height: Int
        let fileSize: Int64
    }

    private struct RepSet {
        let repRows: [PhotoLite]
        let repByPhoto: [String: String]
    }

    private func loadPhotos(sessionId: String) throws -> [PhotoLite] {
        let rows = try connection.prepare("""
            SELECT p.id, COALESCE(NULLIF(p.asset_id, ''), p.id), p.asset_file_id, p.rowid,
                   p.width, p.height,
                   COALESCE(af.file_size, p.checksum_file_size, 0)
            FROM photos p
            LEFT JOIN asset_files af ON af.id = p.asset_file_id
            WHERE p.session_id = ? AND \(PhotoVisibility.visiblePredicate())
            ORDER BY p.rowid
            """).query([.text(sessionId)])
        return rows.map {
            PhotoLite(
                id: $0[0].textValue ?? "",
                gid: $0[1].textValue ?? "",
                assetFileId: $0[2].textValue,
                rowId: $0[3].intValue ?? 0,
                width: Int($0[4].intValue ?? 0),
                height: Int($0[5].intValue ?? 0),
                fileSize: $0[6].intValue ?? 0
            )
        }
    }

    private func loadRepresentatives(sessionId: String, photos: [PhotoLite]) throws -> RepSet {
        let rows = try connection.prepare("""
            SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
                   (SELECT p2.id FROM photos p2
                     WHERE p2.session_id = p.session_id
                       AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                           = COALESCE(NULLIF(p.asset_id, ''), p.id)
                       AND \(PhotoVisibility.visiblePredicate(alias: "p2"))
                     ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))
                     LIMIT 1) AS rep_id
            FROM photos p
            WHERE p.session_id = ? AND \(PhotoVisibility.visiblePredicate())
            GROUP BY gid
            """).query([.text(sessionId)])
        let repByGid = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
                guard let gid = row[0].textValue, let rep = row[1].textValue else { return nil }
                return (gid, rep)
            }
        )
        var repByPhoto: [String: String] = [:]
        for photo in photos {
            repByPhoto[photo.id] = repByGid[photo.gid] ?? photo.id
        }
        let repIds = Set(repByGid.values)
        let repRows = photos.filter { repIds.contains($0.id) }
        return RepSet(repRows: repRows, repByPhoto: repByPhoto)
    }

    // MARK: - 内部：质量/人脸/决策

    private func loadQuality(assetFileIds: [String]) throws -> [String: QualityResult] {
        guard !assetFileIds.isEmpty else { return [:] }
        var result: [String: QualityResult] = [:]
        for chunk in chunks(assetFileIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var params: [DBValue?] = []
            params.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT asset_file_id, result_json
                FROM asset_analysis
                WHERE analysis_type = 'technical_quality'
                  AND asset_file_id IN (\(placeholders))
                ORDER BY updated_at DESC, id DESC
                """).query(params)
            for row in rows {
                let fileId = row[0].textValue ?? ""
                if result[fileId] != nil { continue }
                guard let json = row[1].textValue else { continue }
                let decoded: QualityResult
                do {
                    decoded = try JSONDecoder().decode(
                        QualityResult.self, from: Data(json.utf8)
                    )
                } catch {
                    continue
                }
                result[fileId] = decoded
            }
        }
        return result
    }

    private func loadFaces(
        sessionId: String,
        repByPhoto: [String: String],
        dimensions: [String: (width: Int, height: Int)]
    ) throws -> [String: (count: Int, maxArea: Double)] {
        let rows = try connection.prepare("""
            SELECT photo_id, bbox_w, bbox_h
            FROM face_observations
            WHERE session_id = ?
            """).query([.text(sessionId)])
        // 按逻辑资产聚合：每个变体只贡献一份观测，资产内取 max 而不是求和，
        // 既不会把 RAW/JPEG 的同一张脸算成两张，也不会因代表行无观测而丢信号。
        var perRep: [String: [String: (count: Int, maxArea: Double)]] = [:]
        for row in rows {
            let photoId = row[0].textValue ?? ""
            guard let rep = repByPhoto[photoId] else { continue }
            // 新观测是 0...1 归一化；老库是预览像素坐标，按原图尺寸折算成占比，
            // 否则 maxFaceAreaRatio 会 >1，smallFace/multiFace 保护失真。
            let boxW = row[1].doubleValue ?? 0
            let boxH = row[2].doubleValue ?? 0
            let normalizedInput = boxW > 0 && boxH > 0 && boxW <= 1 && boxH <= 1
            var area = boxW * boxH
            if !normalizedInput, let dims = dimensions[photoId],
               dims.width > 0, dims.height > 0 {
                area = (boxW * boxH) / Double(dims.width * dims.height)
            }
            if !normalizedInput, dimensions[photoId] == nil { area = 0 }
            area = min(1, max(0, area))
            var byPhoto = perRep[rep] ?? [:]
            let current = byPhoto[photoId] ?? (0, 0)
            byPhoto[photoId] = (current.count + 1, max(current.maxArea, area))
            perRep[rep] = byPhoto
        }
        var result: [String: (count: Int, maxArea: Double)] = [:]
        for (rep, byPhoto) in perRep {
            let count = byPhoto.values.map(\.count).max() ?? 0
            let area = byPhoto.values.map(\.maxArea).max() ?? 0
            result[rep] = (count, area)
        }
        return result
    }

    private struct DecisionSnapshot {
        let decision: String
        let source: String?
    }

    private func loadDecisionSnapshots(
        sessionId: String,
        repByPhoto: [String: String]
    ) throws -> [String: DecisionSnapshot] {
        let rows = try connection.prepare("""
            SELECT photo_id, decision, decision_source
            FROM culling_decisions
            WHERE session_id = ?
            """).query([.text(sessionId)])
        var result: [String: DecisionSnapshot] = [:]
        for row in rows {
            let photoId = row[0].textValue ?? ""
            let rep = repByPhoto[photoId] ?? photoId
            let snapshot = DecisionSnapshot(
                decision: row[1].textValue ?? "pending",
                source: row[2].textValue
            )
            // 任一变体的人工决策都必须保护整个逻辑资产；否则 RAW 代表行没有
            // 决策时仍会生成可执行建议，UI 计数也会误导。
            let isManual = snapshot.source == "manual" && snapshot.decision != "pending"
            if isManual || result[rep] == nil {
                result[rep] = snapshot
            }
        }
        return result
    }

    // MARK: - 内部：组

    private func loadGroups(
        sessionId: String,
        repByPhoto: [String: String]
    ) throws -> [TriageGroupRecord] {
        var groups: [String: TriageGroupRecord] = [:]

        // similarity：最新非预计算结果
        let latest = try connection.prepare("""
            SELECT id FROM similarity_results
            WHERE session_id = ? AND stats_json NOT LIKE ?
            ORDER BY id DESC LIMIT 1
            """).get([.text(sessionId), .text(Self.precomputedMarker)])
        if let latest, let resultId = latest[0].intValue {
            let rows = try connection.prepare("""
                SELECT group_index, photo_id FROM similarity_result_members
                WHERE result_id = ? AND session_id = ?
                """).query([.int(resultId), .text(sessionId)])
            var byIndex: [Int: Set<String>] = [:]
            for row in rows {
                let index = Int(row[0].intValue ?? 0)
                let photoId = row[1].textValue ?? ""
                if let rep = repByPhoto[photoId] {
                    byIndex[index, default: []].insert(rep)
                }
            }
            for (index, members) in byIndex where members.count >= 2 {
                let groupId = "sim:\(resultId):\(index)"
                groups[groupId] = TriageGroupRecord(
                    kind: "similarity",
                    groupId: groupId,
                    memberPhotoIds: members.sorted()
                )
            }
        }

        // duplicate：exact / visual（成员一次读完，避免每组一次查询）
        let duplicateRows = try connection.prepare("""
            SELECT id, group_type FROM duplicate_groups WHERE session_id = ?
            """).query([.text(sessionId)])
        let duplicateMemberRows = try connection.prepare("""
            SELECT group_id, photo_id FROM duplicate_group_members WHERE session_id = ?
            """).query([.text(sessionId)])
        var duplicateMembers: [Int: Set<String>] = [:]
        for row in duplicateMemberRows {
            let groupId = Int(row[0].intValue ?? 0)
            if let rep = repByPhoto[row[1].textValue ?? ""] {
                duplicateMembers[groupId, default: []].insert(rep)
            }
        }
        for groupRow in duplicateRows {
            let groupId = Int(groupRow[0].intValue ?? 0)
            let kind = groupRow[1].textValue ?? ""
            guard kind == "exact" || kind == "visual" else { continue }
            guard let members = duplicateMembers[groupId], members.count >= 2 else { continue }
            let key = "dup:\(groupId)"
            groups[key] = TriageGroupRecord(
                kind: kind,
                groupId: key,
                memberPhotoIds: members.sorted()
            )
        }

        // navigation：burst / scene
        let navigationRows = try connection.prepare("""
            SELECT id, group_type, photo_ids_json, lead_photo_id
            FROM navigation_groups WHERE session_id = ?
            """).query([.text(sessionId)])
        for row in navigationRows {
            let id = row[0].textValue ?? ""
            let type = row[1].textValue ?? ""
            guard type == "burst" || type == "scene" else { continue }
            guard let json = row[2].textValue else { continue }
            let photoIds: [String]
            do {
                photoIds = try JSONDecoder().decode([String].self, from: Data(json.utf8))
            } catch {
                continue
            }
            var members = Set<String>()
            for photoId in photoIds {
                if let rep = repByPhoto[photoId] { members.insert(rep) }
            }
            guard members.count >= 2 else { continue }
            let key = "nav:\(id)"
            let lead = row[3].textValue.flatMap { repByPhoto[$0] }
            groups[key] = TriageGroupRecord(
                kind: type,
                groupId: key,
                memberPhotoIds: members.sorted(),
                leadPhotoId: lead
            )
        }

        return groups.values.sorted { $0.groupId < $1.groupId }
    }

    // MARK: - 内部：指纹/覆盖

    private func qualityFingerprint(sessionId: String) throws -> (count: Int, maxUpdatedAt: String) {
        let row = try connection.prepare("""
            SELECT COUNT(*), COALESCE(MAX(aa.updated_at), '')
            FROM asset_analysis aa
            WHERE aa.analysis_type = 'technical_quality'
              AND aa.asset_file_id IN (
                SELECT p.asset_file_id FROM photos p
                WHERE p.session_id = ? AND p.asset_file_id IS NOT NULL
                  AND \(PhotoVisibility.visiblePredicate(alias: "p"))
                  AND p.id = (
                    SELECT p2.id FROM photos p2
                    WHERE p2.session_id = p.session_id
                      AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                          = COALESCE(NULLIF(p.asset_id, ''), p.id)
                      AND \(PhotoVisibility.visiblePredicate(alias: "p2"))
                    ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))
                    LIMIT 1
                  )
              )
            """).get([.text(sessionId)])
        return (Int(row?[0].intValue ?? 0), row?[1].textValue ?? "")
    }

    private func latestSimilarityId(sessionId: String) throws -> Int64 {
        let row = try connection.prepare("""
            SELECT COALESCE(MAX(id), 0) FROM similarity_results
            WHERE session_id = ? AND stats_json NOT LIKE ?
            """).get([.text(sessionId), .text(Self.precomputedMarker)])
        return row?[0].intValue ?? 0
    }

    private func duplicateFingerprint(sessionId: String) throws -> (count: Int, maxCreatedAt: String) {
        let row = try connection.prepare("""
            SELECT COUNT(*), COALESCE(MAX(created_at), '')
            FROM duplicate_groups WHERE session_id = ?
            """).get([.text(sessionId)])
        return (Int(row?[0].intValue ?? 0), row?[1].textValue ?? "")
    }

    private func navigationFingerprint(sessionId: String) throws -> (count: Int, maxUpdatedAt: String) {
        let row = try connection.prepare("""
            SELECT COUNT(*), COALESCE(MAX(updated_at), '')
            FROM navigation_groups WHERE session_id = ?
            """).get([.text(sessionId)])
        return (Int(row?[0].intValue ?? 0), row?[1].textValue ?? "")
    }

    private func coverage(sessionId: String) throws -> Double {
        let row = try connection.prepare("""
            SELECT
              (SELECT COUNT(*) FROM (
                 SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
                 FROM photos p
                 WHERE p.session_id = ? AND \(PhotoVisibility.visiblePredicate(alias: "p"))
                 GROUP BY gid
               )),
              (SELECT COUNT(*) FROM (
                 SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid,
                        (SELECT p2.id FROM photos p2
                          WHERE p2.session_id = p.session_id
                            AND COALESCE(NULLIF(p2.asset_id, ''), p2.id)
                                = COALESCE(NULLIF(p.asset_id, ''), p.id)
                            AND \(PhotoVisibility.visiblePredicate(alias: "p2"))
                          ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))
                          LIMIT 1) AS rep_id
                 FROM photos p
                 WHERE p.session_id = ? AND \(PhotoVisibility.visiblePredicate(alias: "p"))
                 GROUP BY gid
               ) r
               JOIN photos p ON p.id = r.rep_id
               WHERE p.asset_file_id IS NOT NULL
                 AND EXISTS (
                   SELECT 1 FROM asset_analysis aa
                   WHERE aa.asset_file_id = p.asset_file_id
                     AND aa.analysis_type = 'technical_quality'
                     AND json_valid(aa.result_json)
                     AND aa.id = (
                       SELECT a2.id FROM asset_analysis a2
                       WHERE a2.asset_file_id = p.asset_file_id
                         AND a2.analysis_type = 'technical_quality'
                       ORDER BY a2.updated_at DESC, a2.id DESC
                       LIMIT 1
                     )
                     AND json_extract(aa.result_json, '$.status') = 'succeeded'
                 ))
            """).get([.text(sessionId), .text(sessionId)])
        let total = Int(row?[0].intValue ?? 0)
        let analyzed = Int(row?[1].intValue ?? 0)
        return total > 0 ? Double(analyzed) / Double(total) : 0
    }

    private func chunks(_ values: [String]) -> [[String]] {
        guard values.count > Self.chunkSize else { return [values] }
        return stride(from: 0, to: values.count, by: Self.chunkSize).map {
            Array(values[$0..<min($0 + Self.chunkSize, values.count)])
        }
    }
}
