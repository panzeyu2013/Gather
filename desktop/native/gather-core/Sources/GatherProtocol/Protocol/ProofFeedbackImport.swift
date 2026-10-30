// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ProofFeedbackImport.swift
// P1 下一波：客户校样导入的**合并结果**。
//
// 为什么需要它：v1 的 selection.json 只有勾选，CullingAPI.importClientSelection 返回
// ClientSelectionImportResult（picked/applied/skipped/failed）。v2 追加星级/色标/评论，
// 结果要多带 conflicts / ratingApplied / labelApplied / comments / alreadyImported。
// 两段信息必须一次返回（再查一次库才能凑齐 = 多一次 API + 竞态窗口）。
//
// 该类型放在本文件而不是改 Culling.swift / Outputs/CullingOutputs.swift：那两个文件
// 由别的实现者维护；本文件只依赖已经存在的 ClientSelectionImportResult 与
// ClientFeedbackImportResult（ProofShare.swift），不改任何现有签名。

import Foundation

/// selection.json 导入结果（v1 勾选 + v2 反馈的合并视图）。
public struct ClientSelectionImportReport: Codable, Equatable, Sendable {
    /// 文件里被勾选的张数（去重后）。
    public var picked: Int
    /// 真正写成 keep（source=imported）的张数。
    public var applied: Int
    /// 未知 id / 人工保护 / 已导入（幂等）/ 无变化的张数。
    public var skipped: Int
    /// 服务层单张失败（并发修订冲突等）。
    public var failed: Int
    /// 真正入队的评分数。
    public var ratingApplied: Int
    /// 真正入队的色标数。
    public var labelApplied: Int
    /// 落库的评论数（不写 XMP）。
    public var comments: Int
    /// 与本地值冲突、默认保留本地值的项（UI 逐条给「用客户值」）。
    public var conflicts: [ProofFeedbackConflict]
    /// 同一份文件（同一 batch_id）此前已导入过：0 变更。
    public var alreadyImported: Bool

    public init(
        picked: Int = 0,
        applied: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        ratingApplied: Int = 0,
        labelApplied: Int = 0,
        comments: Int = 0,
        conflicts: [ProofFeedbackConflict] = [],
        alreadyImported: Bool = false
    ) {
        self.picked = picked
        self.applied = applied
        self.skipped = skipped
        self.failed = failed
        self.ratingApplied = ratingApplied
        self.labelApplied = labelApplied
        self.comments = comments
        self.conflicts = conflicts
        self.alreadyImported = alreadyImported
    }

    /// 由两段既有结果拼装（v1 勾选结果 + v2 反馈明细）。
    ///
    /// ClientFeedbackImportResult（ProofShare.swift）只带 conflicts/comments/
    /// alreadyImported 三类明细；评分/色标计数由调用方显式给出（ProofFeedbackService
    /// 直接返回本类型时无需用它）。
    public init(
        selection: ClientSelectionImportResult,
        feedback: ClientFeedbackImportResult,
        ratingApplied: Int = 0,
        labelApplied: Int = 0
    ) {
        self.init(
            picked: selection.picked,
            applied: selection.applied,
            skipped: selection.skipped,
            failed: selection.failed,
            ratingApplied: ratingApplied,
            labelApplied: labelApplied,
            comments: feedback.comments,
            conflicts: feedback.conflicts,
            alreadyImported: feedback.alreadyImported)
    }

    /// v1 形态（旧调用点/旧 UI 只读这四个数时用）。
    public var selection: ClientSelectionImportResult {
        ClientSelectionImportResult(
            picked: picked, applied: applied, skipped: skipped, failed: failed)
    }

    /// 客户端回传的"有内容"条目数（勾选之外的评分/色标/评论）。
    public var feedbackCount: Int { ratingApplied + labelApplied + comments }

    /// 一行可读摘要（日志/诊断用，不含路径）。
    public var summaryText: String {
        "picked=\(picked) applied=\(applied) skipped=\(skipped) failed=\(failed) "
            + "rating=\(ratingApplied) label=\(labelApplied) comments=\(comments) "
            + "conflicts=\(conflicts.count) already=\(alreadyImported)"
    }
}
