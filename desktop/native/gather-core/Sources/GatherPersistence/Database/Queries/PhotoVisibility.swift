// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/PhotoVisibility.swift
// P0 / A1：照片可见性的唯一 SQL 谓词。
//
// 语义：photos.archived_at 是"是否仍在工作区"的唯一真相源（淘汰移出到 _rejects 时写入）。
// 所有面向用户的读面（挑片网格/计数/摘要、图库分页、全局检索、facet、导航条、
// triage 候选、导出范围）必须加本谓词；按显式 id 的操作（撤销、审计、photoDetail）
// 不过滤——否则历史回放会找不到已被移出的照片。
//
// 为什么不复用 photos.status：status 的 'removed' 已被重复项裁决占用
// （DuplicateRepo.recomputePhotoStatuses，语义是"排除出导出"），与"移出工作区"
// 是两件事；复用会让两套语义互相污染。
import Foundation

public enum PhotoVisibility {
    /// 可见行谓词。alias 传 SQL 里的照片表别名（"p"/"p2"），空串表示无别名。
    public static func visiblePredicate(alias: String = "p") -> String {
        alias.isEmpty ? "archived_at IS NULL" : "\(alias).archived_at IS NULL"
    }

    /// 已归档行谓词（"已移出"列表/审计用）。
    public static func archivedPredicate(alias: String = "p") -> String {
        alias.isEmpty ? "archived_at IS NOT NULL" : "\(alias).archived_at IS NOT NULL"
    }
}
