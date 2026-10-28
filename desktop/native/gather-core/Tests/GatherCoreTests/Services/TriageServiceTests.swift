// desktop/native/gather-core/Tests/GatherCoreTests/Services/TriageServiceTests.swift
// P0 / T0：TriageService + TriageRepo 的真实 SQLite 集成测试（Schema V3）。
//
// 覆盖：候选装配（逻辑资产/质量/人脸/组/人工）、生成/指纹/stale、apply
// 变体展开/保留 rating+label/source=ai/单条 history、校验与 skip 计数。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

private let t0 = "2026-10-25T00:00:00.000Z"

private func qualityResult(
    _ photoId: String,
    _ score: Double,
    focus: Double? = nil,
    exposure: Double = 0.60,
    closedEyeRisk: Double? = nil,
    status: QualityResultStatus = .succeeded
) -> QualityResult {
    QualityResult(
        photoId: photoId,
        status: status,
        qualityScore: score,
        sharpness: focus ?? score,
        exposure: exposure,
        subjectSharpness: focus,
        closedEyeRisk: closedEyeRisk,
        warnings: [],
        modelId: "test",
        modelVersion: "1",
        inputFingerprint: "fp-\(photoId)",
        updatedAt: t0
    )
}

private struct Harness {
    let database: Database
    let db: DBConnection
    let repo: TriageRepo
    let service: TriageService
    let history: CullingHistoryRepo

    init() throws {
        database = try Database.openInMemory()
        db = database.connection
        repo = TriageRepo(connection: db)
        history = CullingHistoryRepo(connection: db)
        service = TriageService(
            repository: repo,
            decisions: CullingDecisionRepo(connection: db),
            history: history,
            transactions: db,
            now: { t0 }
        )
    }

    func close() { database.close() }
}

private func insertSession(_ db: DBConnection, _ id: String = "s1") throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, created_at, updated_at)
        VALUES (?, 'test', 't', 't')
        """).run([.text(id)])
}

private func insertAsset(_ db: DBConnection, _ assetId: String) throws {
    _ = try db.prepare("""
        INSERT INTO assets (id, status, created_at, updated_at)
        VALUES (?, 'active', 't', 't')
        """).run([.text(assetId)])
}

private func insertAssetFile(_ db: DBConnection, _ id: String, _ path: String) throws {
    _ = try db.prepare("""
        INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at)
        VALUES (?, ?, ?, 't', 't')
        """).run([.text(id), .text(path), .text((path as NSString).lastPathComponent)])
}

private func insertPhoto(
    _ db: DBConnection,
    id: String,
    assetId: String?,
    assetFileId: String?,
    path: String,
    sessionId: String = "s1"
) throws {
    _ = try db.prepare("""
        INSERT INTO photos
          (id, session_id, filepath, filename, status, asset_id, asset_file_id,
           width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'ready', ?, ?, 6000, 4000, 't', 't')
        """).run([
            .text(id), .text(sessionId), .text(path),
            .text((path as NSString).lastPathComponent),
            assetId.map(DBValue.text) ?? .null,
            assetFileId.map(DBValue.text) ?? .null,
        ])
}

private func insertQuality(
    _ db: DBConnection,
    assetFileId: String,
    photoId: String,
    result: QualityResult
) throws {
    let json = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? "{}"
    _ = try db.prepare("""
        INSERT INTO asset_analysis
          (photo_id, asset_file_id, analysis_type, result_json, warnings_json,
           model_id, model_version, input_fingerprint, created_at, updated_at)
        VALUES (?, ?, 'technical_quality', ?, '[]', 'test', '1', ?, ?, ?)
        """).run([
            .text(photoId), .text(assetFileId), .text(json),
            .text(result.inputFingerprint), .text(t0), .text(t0),
        ])
}

private func insertFace(_ db: DBConnection, photoId: String, w: Double, h: Double) throws {
    _ = try db.prepare("""
        INSERT INTO face_observations
          (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding,
           confidence, quality, face_size_px, created_at)
        VALUES (?, 's1', 0.1, 0.1, ?, ?, x'00', 0.9, 0.9, 100, 't')
        """).run([.text(photoId), .real(w), .real(h)])
}

private func insertMetadata(
    _ db: DBConnection,
    photoId: String,
    rating: Int,
    label: String
) throws {
    _ = try db.prepare("""
        INSERT INTO photo_metadata_cache
          (photo_id, session_id, rating, label, cached_at, updated_at)
        VALUES (?, 's1', ?, ?, 't', 't')
        """).run([.text(photoId), .int(Int64(rating)), .text(label)])
}

private func insertSimilarity(_ db: DBConnection, members: [String]) throws {
    _ = try db.prepare("""
        INSERT INTO similarity_results
          (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
        VALUES ('s1', '[]', '{}', 10, 2, 't')
        """).run()
    let resultId = db.lastInsertRowid
    for photoId in members {
        _ = try db.prepare("""
            INSERT INTO similarity_result_members (result_id, session_id, group_index, photo_id)
            VALUES (?, 's1', 0, ?)
            """).run([.int(resultId), .text(photoId)])
    }
}

private func insertDuplicate(_ db: DBConnection, members: [String]) throws {
    _ = try db.prepare("""
        INSERT INTO duplicate_groups (session_id, group_type, member_count, created_at)
        VALUES ('s1', 'exact', ?, 't')
        """).run([.int(Int64(members.count))])
    let groupId = db.lastInsertRowid
    for photoId in members {
        _ = try db.prepare("""
            INSERT INTO duplicate_group_members (group_id, photo_id, session_id)
            VALUES (?, ?, 's1')
            """).run([.int(groupId), .text(photoId)])
    }
}

private func insertNavigation(_ db: DBConnection, members: [String], lead: String? = nil) throws {
    let json = String(data: try JSONEncoder().encode(members), encoding: .utf8) ?? "[]"
    _ = try db.prepare("""
        INSERT INTO navigation_groups
          (id, session_id, group_type, photo_ids_json, lead_photo_id, created_at, updated_at)
        VALUES ('n1', 's1', 'burst', ?, ?, 't', 't')
        """).run([.text(json), lead.map(DBValue.text) ?? .null])
}

private func insertManualDecision(
    _ db: DBConnection, photoId: String, decision: String, source: String = "manual"
) throws {
    _ = try db.prepare("""
        INSERT INTO culling_decisions
          (session_id, photo_id, group_id, decision, rating, color_label,
           decision_source, revision, created_at, updated_at)
        VALUES ('s1', ?, 'ungrouped', ?, 0, 'None', ?, 1, 't', 't')
        """).run([.text(photoId), .text(decision), .text(source)])
}

private func seedBasic(_ h: Harness) throws {
    try insertSession(h.db)
    try insertAsset(h.db, "a1")
    try insertAsset(h.db, "a2")
    try insertAssetFile(h.db, "af1", "/photos/p1.NEF")
    try insertAssetFile(h.db, "af2", "/photos/p2.NEF")
    try insertPhoto(h.db, id: "p1", assetId: "a1", assetFileId: "af1", path: "/photos/p1.NEF")
    try insertPhoto(h.db, id: "p1j", assetId: "a1", assetFileId: "af1", path: "/photos/p1.JPG")
    try insertPhoto(h.db, id: "p2", assetId: "a2", assetFileId: "af2", path: "/photos/p2.NEF")
    try insertQuality(h.db, assetFileId: "af1", photoId: "p1", result: qualityResult("p1", 0.86, focus: 0.90))
    try insertQuality(h.db, assetFileId: "af2", photoId: "p2", result: qualityResult("p2", 0.50, focus: 0.50))
    try insertFace(h.db, photoId: "p1", w: 0.3, h: 0.3)
    try insertMetadata(h.db, photoId: "p1", rating: 4, label: "Red")
    try insertMetadata(h.db, photoId: "p1j", rating: 4, label: "Red")
    try insertMetadata(h.db, photoId: "p2", rating: 2, label: "None")
}

@Suite
struct TriageServiceTests {
    @Test("generate：相似组最佳 keep、弱者 reject、计数落库")
    func generateSimilarity() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p1", "p2"])

        let summary = try h.service.generate(sessionId: "s1")
        #expect(summary.counts.keep == 1)
        #expect(summary.counts.reject == 1)
        #expect(summary.counts.review == 0)
        #expect(summary.counts.total == 2)
        #expect(abs(summary.counts.coverage - 1.0) < 0.001)

        let rows = try h.repo.loadSuggestions(sessionId: "s1")
        #expect(rows.count == 2)
        let p1 = rows.first { $0.photoId == "p1" }
        let p2 = rows.first { $0.photoId == "p2" }
        #expect(p1?.verdict == .keep)
        #expect(p2?.verdict == .reject)
        #expect(p1?.groupId?.hasPrefix("sim:") == true)
    }

    @Test("generate：exact 组优先，且未分析/人工候选不落库")
    func generateExactAndManual() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertPhoto(h.db, id: "p3", assetId: nil, assetFileId: nil, path: "/photos/p3.NEF")
        try insertDuplicate(h.db, members: ["p1", "p2"])
        try insertManualDecision(h.db, photoId: "p2", decision: "keep")

        let summary = try h.service.generate(sessionId: "s1")
        let rows = try h.repo.loadSuggestions(sessionId: "s1")
        #expect(rows.contains { $0.photoId == "p2" } == false)
        let p1 = try #require(rows.first { $0.photoId == "p1" })
        #expect(p1.verdict == .keep)
        #expect(p1.groupId?.hasPrefix("dup:") == true)
        let p3 = try #require(rows.first { $0.photoId == "p3" })
        #expect(p3.verdict == .review)
        #expect(p3.reasons.map(\.code).contains(.qualityMissing))
        #expect(summary.counts.review == 1)
        #expect(summary.counts.coverage < 0.99)
    }

    @Test("generate(force=false)：人工决策撤销后建议行缺失会重建")
    func generateRebuildsAfterManualUndo() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p1", "p2"])
        _ = try h.service.generate(sessionId: "s1")
        #expect(try h.repo.loadSuggestions(sessionId: "s1").count == 2)

        // 人工决策 p2：generate 删掉 p2 的建议行，eligible 也变 1。
        try insertManualDecision(h.db, photoId: "p2", decision: "reject")
        _ = try h.service.generate(sessionId: "s1")
        #expect(try h.repo.loadSuggestions(sessionId: "s1").count == 1)

        // 撤销人工决策：eligible 回到 2，但旧行只有 1；force=false 也必须重建。
        _ = try h.db.prepare(
            "DELETE FROM culling_decisions WHERE session_id = 's1' AND photo_id = 'p2'"
        ).run([])
        _ = try h.service.generate(sessionId: "s1")
        let rows = try h.repo.loadSuggestions(sessionId: "s1")
        #expect(rows.count == 2, "人工撤销后必须补回缺失的建议行")
        #expect(rows.contains { $0.photoId == "p2" })
    }

    @Test("generate：同指纹 force=false 不重写；新增质量后 stale")
    func fingerprintAndStale() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p2"])

        let first = try h.service.generate(sessionId: "s1")
        let rows = try h.repo.loadSuggestions(sessionId: "s1")
        let second = try h.service.generate(sessionId: "s1")
        #expect(second.inputFingerprint == first.inputFingerprint)
        #expect(second.generatedAt == first.generatedAt)
        #expect(try h.repo.loadSuggestions(sessionId: "s1") == rows)

        _ = try h.db.prepare("""
            UPDATE asset_analysis SET updated_at = '2026-10-25T00:01:00.000Z'
            WHERE asset_file_id = 'af2'
            """).run([])
        let stale = try h.service.summary(sessionId: "s1")
        #expect(stale.stale == true)
    }

    @Test("apply：变体展开、保留 rating/label、source=ai、单条 history")
    func applyExpandsVariants() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p1", "p2"])
        let summary = try h.service.generate(sessionId: "s1")
        let input = TriageApplyInput(
            sessionId: "s1",
            verdicts: [.keep, .reject],
            fingerprint: summary.inputFingerprint
        )
        let result = try h.service.apply(Confirmed(input))
        #expect(result.appliedAssets == 2)
        #expect(result.appliedPhotos == 3)
        #expect(result.appliedKeep == 1)
        #expect(result.appliedReject == 1)
        #expect(result.historyOperationId != nil)

        let decisionRows = try h.db.prepare("""
            SELECT photo_id, decision, decision_source, rating, color_label, revision
            FROM culling_decisions WHERE session_id = 's1' ORDER BY photo_id
            """).query([])
        #expect(decisionRows.count == 3)
        for row in decisionRows {
            #expect(row[2].textValue == "ai")
            #expect(Int(row[5].intValue ?? 0) == 1)
        }
        let p1 = decisionRows.first { $0[0].textValue == "p1" }
        #expect(p1?[1].textValue == "keep")
        #expect(Int(p1?[3].intValue ?? 0) == 4)
        #expect(p1?[4].textValue == "Red")

        let ops = try h.history.list(sessionId: "s1", limit: 10)
        #expect(ops.count == 1)
        #expect(ops[0].entries.count == 3)
        #expect(Set(ops[0].entries.map(\.photoId)) == ["p1", "p1j", "p2"])
    }

    @Test("apply：review/低置信/stale/缺失分别拒绝或计数")
    func applyValidation() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p1", "p2"])
        let summary = try h.service.generate(sessionId: "s1")

        #expect(throws: TriageServiceError.self) {
            try h.service.apply(Confirmed(TriageApplyInput(
                sessionId: "s1", verdicts: [.review], fingerprint: summary.inputFingerprint
            )))
        }
        #expect(throws: TriageServiceError.stale) {
            try h.service.apply(Confirmed(TriageApplyInput(
                sessionId: "s1", verdicts: [.reject], fingerprint: "bad"
            )))
        }

        let low = try h.service.apply(Confirmed(TriageApplyInput(
            sessionId: "s1", verdicts: [.keep, .reject],
            minConfidence: 0.99, fingerprint: summary.inputFingerprint
        )))
        // p1 keep 的公式置信度是 1.0（全部信号命中），p2 reject 0.884：只跳过后者。
        #expect(low.skippedLowConfidence == 1)
        #expect(low.appliedAssets == 1)
        #expect(low.appliedKeep == 1)
        #expect(low.appliedReject == 0)

        let missing = try h.service.apply(Confirmed(TriageApplyInput(
            sessionId: "s1", verdicts: [.keep],
            fingerprint: summary.inputFingerprint, photoIds: ["p2"]
        )))
        // p2 有建议但 verdict=reject，不匹配 → 0 selected；p1 未请求。
        #expect(missing.appliedAssets == 0)
    }

    @Test("指纹：新增照片/人脸观测会让旧建议 stale")
    func fingerprintTracksNewInputs() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        let first = try h.service.generate(sessionId: "s1")
        #expect(!first.stale)

        try insertPhoto(
            h.db, id: "p3", assetId: nil, assetFileId: nil, path: "/photos/p3.NEF")
        #expect(try h.service.summary(sessionId: "s1").stale)
        let second = try h.service.generate(sessionId: "s1")
        #expect(!second.stale)
        #expect(second.counts.total == 3)

        try insertFace(h.db, photoId: "p1j", w: 0.2, h: 0.2)
        #expect(try h.service.summary(sessionId: "s1").stale)
    }

    @Test("人工决策写在变体上也保护整个逻辑资产")
    func manualVariantProtectsAsset() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertManualDecision(h.db, photoId: "p1j", decision: "keep")
        _ = try h.service.generate(sessionId: "s1")
        let suggestions = try h.repo.loadSuggestions(sessionId: "s1")
        #expect(!suggestions.contains { $0.photoId == "p1" })
    }

    @Test("客户校样勾选（imported）同样受人工保护：应用建议不得翻转")
    func applySkipsImportedPicks() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p1", "p2"])
        let summary = try h.service.generate(sessionId: "s1")
        // 客户在 selection.json 里勾了 p2：source=imported，仍属人的决定。
        try insertManualDecision(h.db, photoId: "p2", decision: "keep", source: "imported")

        let result = try h.service.apply(Confirmed(TriageApplyInput(
            sessionId: "s1", verdicts: [.keep, .reject],
            fingerprint: summary.inputFingerprint
        )))
        #expect(result.skippedManual == 1, "imported 必须与 manual 一起被跳过")
        let row = try h.db.prepare("""
            SELECT decision, decision_source FROM culling_decisions WHERE photo_id = 'p2'
            """).get([])
        #expect(row?[0].textValue == "keep", "客户勾选不得被 AI 翻成 reject")
        #expect(row?[1].textValue == "imported")

        // 生成也不得为「客户已选」的资产建行（计数与 apply 同口径）。
        let fresh = try h.service.generate(sessionId: "s1")
        #expect(!fresh.stale)
        #expect(try h.repo.loadSuggestions(sessionId: "s1").contains { $0.photoId == "p2" } == false)
    }

    @Test("空会话 summary 不是 stale")
    func emptySessionNotStale() throws {
        let h = try Harness(); defer { h.close() }
        try insertSession(h.db)
        let summary = try h.service.summary(sessionId: "s1")
        #expect(!summary.stale)
        #expect(summary.counts.total == 0)
    }

    @Test("设置：置信度/策略映射；关闭时拒绝生成")
    func settingsPolicyAndDisabled() throws {
        let h = try Harness(); defer { h.close() }
        let settings = SettingsService(repo: SettingsRepo(connection: h.db))
        try settings.set("triage_policy", value: "triage-v1")
        try settings.set("triage_keep_confidence_min", value: "0.65")
        try settings.set("triage_reject_confidence_min", value: "0.80")
        try settings.set("triage_min_executable_confidence", value: "0.58")

        let policy = TriagePolicy.fromSettings(settings)
        #expect(policy.version == "triage-v1")
        #expect(policy.keepConfidenceMin == 0.65)
        #expect(policy.rejectConfidenceMin == 0.80)
        #expect(policy.minExecutableConfidence == 0.58)
        #expect(policy.executionFloor(for: .keep) == 0.65)
        #expect(policy.executionFloor(for: .reject) == 0.80)

        let raised = TriagePolicy(keepConfidenceMin: 0.40, minExecutableConfidence: 0.90)
        #expect(raised.executionFloor(for: .keep) == 0.90)
        #expect(raised.executionFloor(for: .reject) == 0.90)

        let disabled = TriageService(
            repository: h.repo, decisions: CullingDecisionRepo(connection: h.db),
            history: h.history, transactions: h.db, enabled: false)
        #expect(throws: TriageServiceError.self) {
            _ = try disabled.generate(sessionId: "s1")
        }
    }

    @Test("apply：人工决策不使建议过期；整条资产跳过并计数")
    func applySkipsManual() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertSimilarity(h.db, members: ["p1", "p2"])
        let summary = try h.service.generate(sessionId: "s1")
        try insertManualDecision(h.db, photoId: "p2", decision: "keep")

        // 人工决策不进指纹（t0 §6）：建议仍新鲜，但 p2 作为人工决策被跳过。
        let afterManual = try h.service.summary(sessionId: "s1")
        #expect(!afterManual.stale)
        let result = try h.service.apply(Confirmed(TriageApplyInput(
            sessionId: "s1", verdicts: [.keep, .reject],
            fingerprint: summary.inputFingerprint
        )))
        #expect(result.skippedManual == 1)
        let p2 = try h.db.prepare("""
            SELECT decision, decision_source FROM culling_decisions WHERE photo_id = 'p2'
            """).get([])
        #expect(p2?[0].textValue == "keep")
        #expect(p2?[1].textValue == "manual")

        // 再次生成：人工资产不再保留建议行，计数随之下降。
        let fresh = try h.service.generate(sessionId: "s1")
        #expect(!fresh.stale)
        #expect(try h.repo.loadSuggestions(sessionId: "s1").contains { $0.photoId == "p2" } == false)
        #expect(fresh.counts.total == 1)
    }

    @Test("apply：建议行指纹落后于当前输入时整批拒绝（不应用旧建议）")
    func applyRejectsStaleRows() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        _ = try h.service.generate(sessionId: "s1")
        _ = try h.db.prepare("""
            UPDATE asset_analysis SET updated_at = '2026-10-25T00:05:00.000Z'
            WHERE asset_file_id = 'af2'
            """).run([])

        let summary = try h.service.summary(sessionId: "s1")
        #expect(summary.stale)
        #expect(throws: TriageServiceError.stale) {
            _ = try h.service.apply(Confirmed(TriageApplyInput(
                sessionId: "s1", verdicts: [.keep, .reject],
                fingerprint: summary.inputFingerprint
            )))
        }
    }

    @Test("summary：全人工决策会话不判 stale，计数为 0")
    func summaryAllManualIsNotStale() throws {
        let h = try Harness(); defer { h.close() }
        try seedBasic(h)
        try insertManualDecision(h.db, photoId: "p1", decision: "keep")
        try insertManualDecision(h.db, photoId: "p2", decision: "reject")

        let summary = try h.service.summary(sessionId: "s1")
        #expect(!summary.stale)
        #expect(summary.counts.total == 0)

        let generated = try h.service.generate(sessionId: "s1")
        #expect(!generated.stale)
        #expect(generated.counts.total == 0)
        #expect(try h.repo.loadSuggestions(sessionId: "s1").isEmpty)
    }
}
