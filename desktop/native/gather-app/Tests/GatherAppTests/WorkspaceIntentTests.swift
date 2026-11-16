// desktop/native/gather-app/Tests/GatherAppTests/WorkspaceIntentTests.swift
// Cut 4 / 4a-0：入口意图的 Kind 映射、相等与"按 Kind 去重"语义。
//
// 这些用例对应审计 §4.2 的 pendingIntents 设计：同 Kind 是同一个槽位，
// 后到覆盖先到；不同载荷/不同 Kind 必须不相等，避免 View 误消费。
import Testing
@testable import GatherUI
@testable import GatherHost
@testable import GatherProtocol

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
// MARK: - Wave5 batch5：自动化命令参数面（App Intents / URL scheme 共用）

/// App Intents 的参数校验不在 intent 结构体上直接测：GatherApp 是 executableTarget，
/// 测试 target 不能 import 它。intent 只做「String 参数 → GatherHost 归一化」这一步，
/// 因此参数契约统一钉在 GatherHost 的入口类型上（Shortcuts 与 gather:// 共用同一份
/// 校验，避免两套入口给出不同的合法值集合）。
@Suite("自动化命令参数面（intent ↔ runtime 契约）")
struct AutomationCommandParameterContractTests {
    @Test("查询照片：空串 = 未设置（Shortcuts 可选参数的语义）")
    func queryParametersTreatEmptyAsUnset() throws {
        let defaults = try GatherAutomationPhotoQuery.parse(
            sessionId: "session-1", keyword: "", minRating: "", limit: "")
        #expect(defaults.keyword == nil)
        #expect(defaults.minRating == nil)
        #expect(defaults.limit == GatherAutomationPhotoQuery.defaultLimit)

        // 0 星是合法过滤值（不是"未设置"）：不能把 "0" 当空串吞掉。
        let zero = try GatherAutomationPhotoQuery.parse(
            sessionId: "session-1", keyword: "", minRating: "0", limit: "")
        #expect(zero.minRating == 0)
    }

    @Test("查询照片：越界/非数字一律报错，不静默回落默认值")
    func queryParametersRejectOutOfRange() {
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "session-1", keyword: "", minRating: "6", limit: "")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "session-1", keyword: "", minRating: "", limit: "0")
        }
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "session-1", keyword: "", minRating: "",
                limit: String(GatherAutomationPhotoQuery.maxLimit + 1))
        }
        // 空 sessionId：宁可报错，也不让脚本以为"查了整个库"。
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationPhotoQuery.parse(
                sessionId: "", keyword: "", minRating: "", limit: "")
        }
    }

    @Test("写判断：字符串参数按「空串 = 不改」解释")
    func decisionParametersTreatEmptyAsUnset() throws {
        let ratingOnly = try GatherAutomationDecisionPatch.parse(
            rating: "2", label: "", pick: "")
        #expect(ratingOnly.rating == 2)
        #expect(ratingOnly.colorLabel == nil)
        #expect(ratingOnly.pickState == nil)

        let pickOnly = try GatherAutomationDecisionPatch.parse(
            rating: "", label: "", pick: "keep")
        #expect(pickOnly.rating == nil)
        #expect(pickOnly.pickState == .picked)

        // 全空 = 空写：intent 必须拿到错误（不能"成功但什么都没改"）。
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "", label: "", pick: "")
        }
    }

    @Test("写判断：每个 C1 色标的 rawValue 小写形式都被接受（枚举漂移先红）")
    func everyColorLabelIsAddressable() throws {
        for label in CaptureOneColorLabel.allCases {
            let parsed = try GatherAutomationDecisionPatch.parse(
                rating: "", label: label.rawValue.lowercased(), pick: "")
            #expect(parsed.colorLabel == label, "label=\(label.rawValue)")
        }
        // 反向：大小写不敏感，但不能接受未知名字。
        #expect(throws: GatherAutomationError.self) {
            try GatherAutomationDecisionPatch.parse(rating: "", label: "chartreuse", pick: "")
        }
    }

    @Test("未启动文案稳定：Shortcuts 直接展示 runtimeUnavailable 的 errorDescription")
    func runtimeUnavailableCopyIsStable() {
        #expect(GatherAutomationError.runtimeUnavailable.errorDescription
            == "Gather 尚未完成启动；请先打开应用再运行此动作。")
        #expect(GatherAutomationError.noPhotoIds.errorDescription == "没有指定照片 ID。")
    }
}
