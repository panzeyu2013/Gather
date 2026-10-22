// desktop/native/gather-app/Tests/GatherAppTests/WorkspaceIntentTests.swift
// Cut 4 / 4a-0：入口意图的 Kind 映射、相等与"按 Kind 去重"语义。
//
// 这些用例对应审计 §4.2 的 pendingIntents 设计：同 Kind 是同一个槽位，
// 后到覆盖先到；不同载荷/不同 Kind 必须不相等，避免 View 误消费。
import Testing
@testable import GatherUI

@Suite("WorkspaceIntent 入口意图")
struct WorkspaceIntentTests {
    @Test("kind：六种 case 各自映射到唯一 Kind")
    func kindMapping() {
        #expect(WorkspaceIntent.galleryFilter(.hasFace).kind == .galleryFilter)
        #expect(WorkspaceIntent.galleryPhoto(id: "p1", path: nil).kind == .galleryPhoto)
        #expect(WorkspaceIntent.cullingConflicts.kind == .cullingConflicts)
        #expect(WorkspaceIntent.faceAnalyze.kind == .faceAnalyze)
        #expect(WorkspaceIntent.faceRole("model").kind == .faceRole)
        #expect(WorkspaceIntent.exportRange(.picks).kind == .exportRange)

        #expect(WorkspaceIntent.Kind.allCases.count == 6)
        #expect(Set(WorkspaceIntent.Kind.allCases).count == 6)
    }

    @Test("Kind：rawValue 与 case 同名（诊断/日志可读）")
    func kindRawValues() {
        #expect(WorkspaceIntent.Kind.galleryFilter.rawValue == "galleryFilter")
        #expect(WorkspaceIntent.Kind.galleryPhoto.rawValue == "galleryPhoto")
        #expect(WorkspaceIntent.Kind.cullingConflicts.rawValue == "cullingConflicts")
        #expect(WorkspaceIntent.Kind.faceAnalyze.rawValue == "faceAnalyze")
        #expect(WorkspaceIntent.Kind.faceRole.rawValue == "faceRole")
        #expect(WorkspaceIntent.Kind.exportRange.rawValue == "exportRange")
    }

    @Test("相等：同 case 同载荷相等，跨载荷/跨 case 不等")
    func equality() {
        #expect(WorkspaceIntent.galleryFilter(.offline) == .galleryFilter(.offline))
        #expect(WorkspaceIntent.galleryFilter(.offline) != .galleryFilter(.all))

        #expect(WorkspaceIntent.galleryPhoto(id: "p1", path: "/a") == .galleryPhoto(id: "p1", path: "/a"))
        #expect(WorkspaceIntent.galleryPhoto(id: "p1", path: nil) != .galleryPhoto(id: "p2", path: nil))
        #expect(WorkspaceIntent.galleryPhoto(id: nil, path: "/a") != .galleryPhoto(id: nil, path: "/b"))

        #expect(WorkspaceIntent.faceRole("model") == .faceRole("model"))
        #expect(WorkspaceIntent.faceRole("model") != .faceRole("makeup"))

        #expect(WorkspaceIntent.exportRange(.picks) == .exportRange(.picks))
        #expect(WorkspaceIntent.exportRange(.picks) != .exportRange(.allPhotos))

        #expect(WorkspaceIntent.cullingConflicts == .cullingConflicts)
        #expect(WorkspaceIntent.cullingConflicts != .faceAnalyze)
        #expect(WorkspaceIntent.faceAnalyze != .galleryFilter(.all))
    }

    @Test("Kind 作 pendingIntents 键：同类后到覆盖先到（单槽语义）")
    func kindAsPendingKey() {
        var pending: [WorkspaceIntent.Kind: WorkspaceIntent] = [:]
        pending[.galleryFilter] = .galleryFilter(.all)
        pending[.galleryFilter] = .galleryFilter(.hasFace)
        pending[.cullingConflicts] = .cullingConflicts

        #expect(pending.count == 2)
        #expect(pending[.galleryFilter] == .galleryFilter(.hasFace))
        #expect(pending[.cullingConflicts] == .cullingConflicts)
        #expect(pending[.faceAnalyze] == nil)

        // take 语义：取出即清
        let taken = pending.removeValue(forKey: .galleryFilter)
        #expect(taken == .galleryFilter(.hasFace))
        #expect(pending[.galleryFilter] == nil)
    }
}
