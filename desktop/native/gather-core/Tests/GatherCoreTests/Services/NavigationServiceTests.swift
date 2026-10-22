// desktop/native/gather-core/Tests/GatherCoreTests/Services/NavigationServiceTests.swift
// NavigationService 行为测试（Phase 3.6）。
// TS 源: tests/unit/services/navigation/navigation-service.test.ts（用例逐一对应）
// + 纯函数补充（filenameSequence/hammingDistance 对账）。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherDomain

private struct Harness {
    let db: DBConnection
    let service: NavigationService
}

/// TS: navigation-service.test.ts fixture —— 3 照片 + 元数据 + 哈希。
private func makeHarness() throws -> Harness {
    let db = try makeTestDB()
    let now = "2026-07-30T10:00:00.000Z"
    _ = try db.prepare("""
        INSERT INTO sessions (
          id, name, status, source_path, photo_count, created_at, updated_at
        ) VALUES ('session', 'Navigation', 'photos_loaded',
          '/photos', 3, ?, ?)
      """).run([.text(now), .text(now)])
    let insertPhoto = try db.prepare("""
        INSERT INTO photos (
          id, session_id, filepath, filename, checksum, status,
          width, height, created_at, updated_at
        ) VALUES (?, 'session', ?, ?, '', 'pending', 100, 80, ?, ?)
      """)
    let insertMetadata = try db.prepare("""
        INSERT INTO photo_metadata_cache (
          photo_id, session_id, date_taken, camera_model, rating, keywords,
          cached_at, updated_at
        ) VALUES (?, 'session', ?, 'Camera A', ?, '[]', ?, ?)
      """)
    let insertHash = try db.prepare("""
        INSERT INTO similarity_hashes (
          session_id, photo_id, hash_hex, file_size, file_mtime_ms
        ) VALUES ('session', ?, ?, 10, 1)
      """)
    let captures: [(String, String, String, Double)] = [
        ("p1", "IMG_0001.JPG", "2026-07-30T10:00:00.000Z", 0),
        ("p2", "IMG_0002.JPG", "2026-07-30T10:00:01.000Z", 5),
        ("p3", "IMG_0003.JPG", "2026-07-30T10:00:20.000Z", 0),
    ]
    for (id, filename, capturedAt, rating) in captures {
        _ = try insertPhoto.run([
            .text(id), .text("/photos/\(filename)"), .text(filename),
            .text(now), .text(now),
        ])
        _ = try insertMetadata.run([
            .text(id), .text(capturedAt), .real(rating), .text(now), .text(now),
        ])
        _ = try insertHash.run([.text(id), .text("0000000000000000")])
    }
    return Harness(db: db, service: NavigationService(connection: db))
}

@Suite("NavigationService")
struct NavigationServiceTests {
    // TS: "rejects unsafe or inverted grouping intervals"。
    @Test func rejectsUnsafeOrInvertedIntervals() {
        #expect(throws: (any Error).self) {
            try validateNavigationParameters(burstGapSeconds: .nan, sceneGapSeconds: 100)
        }
        #expect(throws: (any Error).self) {
            try validateNavigationParameters(burstGapSeconds: 2, sceneGapSeconds: 1)
        }
        #expect(throws: (any Error).self) {
            try validateNavigationParameters(burstGapSeconds: 2, sceneGapSeconds: 86_401)
        }
        // 合法参数不抛错。
        #expect(throws: Never.self) {
            try validateNavigationParameters(burstGapSeconds: 2, sceneGapSeconds: 1_800)
        }
    }

    /// TS 边界：sceneGap == burstGap 合法（只有 `sceneGap < burstGap` 才是倒挂），
    /// burstGap 的闭区间两端 0.1 / 300 合法、越界非法。
    /// 变异「sceneGapSeconds < burstGapSeconds 改成 <=」可杀。
    @Test func equalSceneAndBurstGapIsLegalAtClosedBoundaries() {
        #expect(throws: Never.self) {
            try validateNavigationParameters(burstGapSeconds: 2, sceneGapSeconds: 2)
        }
        #expect(throws: Never.self) {
            try validateNavigationParameters(burstGapSeconds: 0.1, sceneGapSeconds: 0.1)
        }
        #expect(throws: Never.self) {
            try validateNavigationParameters(burstGapSeconds: 300, sceneGapSeconds: 86_400)
        }
        #expect(throws: (any Error).self) {
            try validateNavigationParameters(burstGapSeconds: 0.099, sceneGapSeconds: 10)
        }
        #expect(throws: (any Error).self) {
            try validateNavigationParameters(burstGapSeconds: 300.1, sceneGapSeconds: 86_400)
        }
        #expect(throws: (any Error).self) {
            try validateNavigationParameters(burstGapSeconds: 300, sceneGapSeconds: 86_400.5)
        }
    }

    // TS: "recomputes when thresholds change and explains the rating-only lead fallback"。
    @Test func recomputesWhenThresholdsChange() throws {
        let harness = try makeHarness()
        let initial = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        let burst = initial.first { $0.type == .burst }
        let scene = initial.first { $0.type == .scene }
        #expect(burst?.photoIds == ["p1", "p2"])
        #expect(scene?.photoIds == ["p1", "p2", "p3"])
        #expect(burst?.leadPhotoId == "p2")
        #expect(burst?.explanation == "NAV_RECOMMEND_RATING")

        let tighter = try harness.service.analyze(sessionId: "session", burstGapSeconds: 0.5, sceneGapSeconds: 1_800)
        #expect(tighter.contains { $0.type == .burst } == false)
        #expect(tighter.contains { $0.type == .scene } == true)
    }

    // TS: "keeps manual overrides scoped to their own navigation type"。
    @Test func manualOverridesScopedToOwnType() throws {
        let harness = try makeHarness()
        let groups = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        let burst = try #require(groups.first { $0.type == .burst })
        _ = try harness.service.split(sessionId: "session", groupId: burst.id, beforePhotoId: "p2")

        _ = try harness.db.prepare(
            "UPDATE similarity_hashes SET hash_hex = '0000000000000001' WHERE photo_id = 'p3'"
        ).run([])

        let refreshed = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        #expect(refreshed.contains { group in
            group.type == .scene && group.photoIds.contains("p1") && group.photoIds.contains("p2")
        })
        // manual 组保留（split 产生 2 个 manual burst 组）。
        let manualCount = try harness.db.prepare("""
            SELECT COUNT(*) AS count FROM navigation_groups
            WHERE session_id = 'session' AND group_type = 'burst' AND source = 'manual'
        """).query().first?[0].intValue ?? 0
        #expect(manualCount == 2)
    }

    // TS: "penalizes the current heuristic closed-eye warning when choosing a lead"。
    @Test func closedEyeWarningPenalizedInLead() throws {
        let harness = try makeHarness()
        let db = harness.db
        let now = "2026-07-30T10:00:00.000Z"
        _ = try db.prepare("""
            INSERT INTO assets (id, status, created_at, updated_at)
            VALUES ('asset-1', 'active', ?, ?), ('asset-2', 'active', ?, ?)
          """).run([.text(now), .text(now), .text(now), .text(now)])
        let insertFile = try db.prepare("""
            INSERT INTO asset_files (
              id, normalized_path, filename, extension, media_type,
              created_at, updated_at
            ) VALUES (?, ?, ?, '.JPG', 'image', ?, ?)
          """)
        _ = try insertFile.run([.text("file-1"), .text("/photos/IMG_0001.JPG"), .text("IMG_0001.JPG"), .text(now), .text(now)])
        _ = try insertFile.run([.text("file-2"), .text("/photos/IMG_0002.JPG"), .text("IMG_0002.JPG"), .text(now), .text(now)])
        _ = try db.prepare("UPDATE photos SET asset_id = 'asset-1', asset_file_id = 'file-1' WHERE id = 'p1'").run()
        _ = try db.prepare("UPDATE photos SET asset_id = 'asset-2', asset_file_id = 'file-2' WHERE id = 'p2'").run()
        let insertAnalysis = try db.prepare("""
            INSERT INTO asset_analysis (
              photo_id, asset_file_id, analysis_type, result_json, warnings_json,
              model_id, model_version, input_fingerprint, created_at, updated_at
            ) VALUES (?, ?, 'technical_quality', ?, ?, 'test', '1', ?, ?, ?)
          """)
        _ = try insertAnalysis.run([
            .text("p1"), .text("file-1"),
            .text(#"{"status":"succeeded","qualityScore":0.9,"warnings":["closed_eye_risk_heuristic"]}"#),
            .text(#"["closed_eye_risk_heuristic"]"#),
            .text("p1"), .text(now), .text(now),
        ])
        _ = try insertAnalysis.run([
            .text("p2"), .text("file-2"),
            .text(#"{"status":"succeeded","qualityScore":0.8,"warnings":[]}"#),
            .text("[]"),
            .text("p2"), .text(now), .text(now),
        ])

        let burst = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800, dryRun: true)
            .first { $0.type == .burst }
        // p1 质量分 0.9 但闭眼警告 -0.25 → 0.65 < p2 的 0.8 → lead 为 p2。
        #expect(burst?.leadPhotoId == "p2")
    }

    // TS 补充：merge 错误码（≥2 组/同类型）。
    @Test func mergeValidation() throws {
        let harness = try makeHarness()
        let groups = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        let burst = try #require(groups.first { $0.type == .burst })
        let scene = try #require(groups.first { $0.type == .scene })

        // 单组 → NAV_MERGE_MIN_TWO。
        #expect(throws: (any Error).self) {
            try harness.service.merge(sessionId: "session", groupIds: [burst.id])
        }
        // 类型不同 → NAV_MERGE_TYPE_MISMATCH。
        #expect(throws: (any Error).self) {
            try harness.service.merge(sessionId: "session", groupIds: [burst.id, scene.id])
        }
        // 不存在的组 → NAV_GROUP_NOT_FOUND。
        #expect(throws: (any Error).self) {
            try harness.service.merge(sessionId: "session", groupIds: [burst.id, "nope"])
        }
    }

    // TS 补充：split 越界 → NAV_SPLIT_OUT_OF_GROUP。
    @Test func splitOutOfGroupThrows() throws {
        let harness = try makeHarness()
        let groups = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        let burst = try #require(groups.first { $0.type == .burst })
        #expect(throws: (any Error).self) {
            try harness.service.split(sessionId: "session", groupId: burst.id, beforePhotoId: "p1")
        }
        // 正常 split 产生两个 manual 组（list 过滤 <2 张的组，直接查库断言）。
        _ = try harness.service.split(sessionId: "session", groupId: burst.id, beforePhotoId: "p2")
        let manualCount = try harness.db.prepare("""
            SELECT COUNT(*) AS count FROM navigation_groups
            WHERE session_id = 'session' AND group_type = 'burst' AND source = 'manual'
        """).query().first?[0].intValue ?? 0
        #expect(manualCount == 2)
    }

    // TS: 缓存语义 —— 相同指纹直接返回缓存组（不重建，组 id 不变）。
    @Test func fingerprintCacheReusesGroups() throws {
        let harness = try makeHarness()
        let first = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        let firstBurst = try #require(first.first { $0.type == .burst })
        let second = try harness.service.analyze(sessionId: "session", burstGapSeconds: 2, sceneGapSeconds: 1_800)
        let secondBurst = try #require(second.first { $0.type == .burst })
        #expect(firstBurst.id == secondBurst.id)
        #expect(secondBurst.photoIds == firstBurst.photoIds)
    }
}

// MARK: - 纯函数对账

@Suite("NavigationPureFunctions")
struct NavigationPureFunctionsTests {
    // TS: filenameSequence —— 尾部数字；无数字 nil。
    @Test func filenameSequenceExtractsTrailingDigits() {
        #expect(filenameSequence("IMG_0001.JPG") == 1)
        #expect(filenameSequence("IMG_0042.jpg") == 42)
        #expect(filenameSequence("IMG_0001_EDIT.JPG") == 1)
        #expect(filenameSequence("IMG.JPG") == nil)
        #expect(filenameSequence("0001.JPG") == 1)
    }

    // TS: hammingDistance —— 同长 hex 逐位差异。
    @Test func hammingDistanceCountsBits() {
        #expect(hammingDistance("0000000000000000", "0000000000000000") == 0)
        #expect(hammingDistance("0000000000000000", "0000000000000001") == 1)
        #expect(hammingDistance("0000000000000000", "ffffffffffffffff") == 64)
        #expect(hammingDistance("0000000000000001", "0000000000000003") == 1)
        // 长度不同 → nil。
        #expect(hammingDistance("0000", "0000000000000000") == nil)
        // 空串 → nil。
        #expect(hammingDistance("", "0000000000000000") == nil)
        // 非法 hex → nil。
        #expect(hammingDistance("zzzzzzzzzzzzzzzz", "0000000000000000") == nil)
    }
}

// TS↔Swift 用例对照：
// - navigation-service.test.ts（4 用例）→ rejectsUnsafeOrInvertedIntervals /
//   recomputesWhenThresholdsChange / manualOverridesScopedToOwnType /
//   closedEyeWarningPenalizedInLead
// - 本文件补充 → mergeValidation / splitOutOfGroupThrows /
//   fingerprintCacheReusesGroups / NavigationPureFunctionsTests（filenameSequence /
//   hammingDistance 对账）
