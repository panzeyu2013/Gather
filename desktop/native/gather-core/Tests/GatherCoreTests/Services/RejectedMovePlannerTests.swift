// desktop/native/gather-core/Tests/GatherCoreTests/Services/RejectedMovePlannerTests.swift
// #2 S3：淘汰移出的纯规划（不需要 DB / 文件系统 / app target）。
//
// 这段逻辑此前内联在 LiveCullingAPI.moveRejected 的闭包里，只能通过 app 端到端
// 用例覆盖；抽成纯函数后，「资产展开 / skipped 归因 / sharesSidecar / 目标目录
// 安全校验」四条不变量都能在 core 侧直接钉住。
import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

@Suite("RejectedMovePlanner（纯规划）")
struct RejectedMovePlannerTests {
    private func candidate(
        _ id: String, _ path: String, asset: String? = nil, archived: Bool = false
    ) -> RejectedMovePlanner.Candidate {
        RejectedMovePlanner.Candidate(
            photoId: id, filepath: path, assetId: asset, isArchived: archived)
    }

    @Test("按资产展开：只请求 RAW 也会带上同资产的 JPEG 变体")
    func expandsWholeAsset() throws {
        let plan = try RejectedMovePlanner.plan(
            requestedIds: ["raw"],
            candidates: [
                candidate("raw", "/shots/x.nef", asset: "a1"),
                candidate("jpeg", "/shots/x.jpg", asset: "a1"),
            ],
            rejectedIds: ["raw", "jpeg"],
            sessionSourcePath: "/shots",
            explicitDestinationRoot: nil)
        #expect(Set(plan.items.map(\.photoId)) == ["raw", "jpeg"])
        #expect(plan.skipped.isEmpty)
    }

    @Test("sharesSidecar 只按实际会移动的行算：留下的兄弟保住了共享 .xmp")
    func sharesSidecarOnlyCountsMovingRows() throws {
        let plan = try RejectedMovePlanner.plan(
            requestedIds: ["raw"],
            candidates: [
                candidate("raw", "/shots/x.nef", asset: "a1"),
                candidate("jpeg", "/shots/x.jpg", asset: "a1"),
            ],
            // JPEG 没被淘汰 → 不移动 → RAW 的 sidecar 与它共享
            rejectedIds: ["raw"],
            sessionSourcePath: "/shots",
            explicitDestinationRoot: nil)
        #expect(plan.items.count == 1)
        #expect(plan.items.first?.sharesSidecar == true)
    }

    @Test("skipped 归因：不在会话 / 已移出 / 未淘汰各归各的")
    func skipReasons() throws {
        let plan = try RejectedMovePlanner.plan(
            requestedIds: ["missing", "archived", "kept"],
            candidates: [
                candidate("archived", "/shots/a.jpg", archived: true),
                candidate("kept", "/shots/k.jpg"),
            ],
            rejectedIds: ["archived", "missing"],
            sessionSourcePath: "/shots",
            explicitDestinationRoot: nil)
        #expect(plan.items.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0.photoId, $0.reason) })
        #expect(reasons["missing"] == "not_in_session")
        #expect(reasons["archived"] == "already_archived")
        #expect(reasons["kept"] == "not_rejected")
    }

    @Test("目标目录：越界抛 INVALID_PARAM，合法则拼上 _rejects")
    func destinationRootSafety() throws {
        let rows = [candidate("p1", "/shots/x.jpg")]
        #expect(throws: GatherError.self) {
            _ = try RejectedMovePlanner.plan(
                requestedIds: ["p1"], candidates: rows, rejectedIds: ["p1"],
                sessionSourcePath: "/shots", explicitDestinationRoot: "/elsewhere")
        }
        let inside = try RejectedMovePlanner.plan(
            requestedIds: ["p1"], candidates: rows, rejectedIds: ["p1"],
            sessionSourcePath: "/shots", explicitDestinationRoot: "/shots/pick")
        #expect(inside.destination == "/shots/pick/_rejects")
        let defaulted = try RejectedMovePlanner.plan(
            requestedIds: ["p1"], candidates: rows, rejectedIds: ["p1"],
            sessionSourcePath: "/shots", explicitDestinationRoot: nil)
        #expect(defaulted.destination == "/shots/_rejects")
    }
}
