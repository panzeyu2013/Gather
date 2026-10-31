// V5 100k 排序分页预演（验证 harness；运行时临时复制进 GatherCoreTests）。
// 只测 SQL 读路径，不替代 App 端 facet/UI/缩略图。
import Foundation
import Testing
import GatherProtocol
import GatherTestSupport
@testable import GatherPersistence

@Suite("Culling 100k 排序分页预演")
struct CullingPaging100kPerfTests {
    @Test("100k 逻辑资产：三种排序分页 p95")
    func hundredThousandAssetsSortedPages() throws {
        let db = try makeQueryTestDB()
        try queryInsertSession(db, id: "s")
        try db.exec("BEGIN")
        let asset = try db.prepare("""
            INSERT INTO assets (id, created_at, updated_at)
            VALUES (?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """)
        let photo = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, asset_id, created_at, updated_at)
            VALUES (?, 's', ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """)
        let cache = try db.prepare("""
            INSERT INTO photo_metadata_cache
              (photo_id, session_id, date_taken, rating, keywords, cached_at, updated_at)
            VALUES (?, 's', '2026-01-01T00:00:00.000Z', ?, '[]',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """)
        let triage = try db.prepare("""
            INSERT INTO triage_suggestions
              (photo_id, session_id, verdict, score, confidence, reasons_json,
               group_id, policy_version, input_fingerprint, computed_at)
            VALUES (?, 's', 'review', 0.5, ?, '[]', NULL, 'triage-v1', 'fp',
                    '2026-01-01T00:00:00.000Z')
            """)
        for index in 0..<100_000 {
            let id = String(format: "a%06d", index)
            _ = try asset.run([.text(id)])
            _ = try photo.run([.text(id), .text("/s/\(id).jpg"), .text("\(id).jpg"), .text(id)])
            _ = try cache.run([.text(id), .int(Int64(index % 6))])
            _ = try triage.run([.text(id), .real(Double(index % 100) / 100.0)])
        }
        try db.exec("COMMIT")

        let query = CullingAssetPageQuery(connection: db)
        let filter = CullingPageFilter()
        func measure(_ sort: CullingSort) throws -> [Double] {
            var cursor: CullingPageCursor?
            var durations: [Double] = []
            for _ in 0..<10 {
                let started = DispatchTime.now().uptimeNanoseconds
                let page = try query.pageSorted(
                    sessionId: "s", scope: .filtered, filter: filter,
                    similarity: nil, sort: sort, cursor: cursor, limit: 200)
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                guard let next = page.cursor, !page.rows.isEmpty else { break }
                cursor = next
            }
            return durations
        }
        func p95(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return .infinity }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        }

        let capture = try measure(.captureDesc)
        let rating = try measure(.ratingDesc)
        let triageSort = try measure(.triageConfidenceAsc)
        print("PERF constraint=100k-sorted-pages " +
            "captureP95=\(String(format: "%.1f", p95(capture)))ms " +
            "ratingP95=\(String(format: "%.1f", p95(rating)))ms " +
            "triageP95=\(String(format: "%.1f", p95(triageSort)))ms")
        for (label, values) in [("capture", capture), ("rating", rating), ("triage", triageSort)] {
            #expect(!values.isEmpty, "\(label) 未取到页")
            #expect(p95(values) < 1_000, "\(label) p95 超过 1s：\(p95(values))ms")
        }
    }
}
