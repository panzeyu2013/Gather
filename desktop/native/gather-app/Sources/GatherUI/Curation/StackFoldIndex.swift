// desktop/native/gather-app/Sources/GatherUI/Curation/StackBadge.swift
// P1 下一波 §3.8.2：堆栈折叠的展示层零件（徽标 + 折叠索引）。
//
// 铁律：**折叠只影响展示**。本文件只回答"这张照片在这个网格里代表几张"，
// 不读也不写评分/决策/交付；任何筛选、导出、写回都应按真实照片逐张处理。
//
// 与 expandVariants（RAW/JPEG 折叠）正交：先按 asset 折叠，再按 stack 折叠。
import SwiftUI
import GatherProtocol

/// 折叠索引：photoId → 堆栈，以及堆栈 → 成员（封面/隐藏判定）。
///
/// 纯值类型，可从 AlbumAPI.stackFolds(sessionId) 的结果直接构造；
/// 不依赖视图状态，网格与胶片条共用同一份。
struct StackFoldIndex: Equatable {
    private let foldByStack: [String: StackFold]
    private let stackIdByPhoto: [String: String]

    init(folds: [StackFold] = []) {
        var byStack: [String: StackFold] = [:]
        var byPhoto: [String: String] = [:]
        for fold in folds where fold.photoIds.count > 1 {
            byStack[fold.stackId] = fold
            for photoId in fold.photoIds {
                // 一照一堆栈：重复出现时取第一个（CurationService 已保证唯一）。
                if byPhoto[photoId] == nil { byPhoto[photoId] = fold.stackId }
            }
        }
        self.foldByStack = byStack
        self.stackIdByPhoto = byPhoto
    }

    var isEmpty: Bool { foldByStack.isEmpty }

    func stackId(for photoId: String) -> String? {
        stackIdByPhoto[photoId]
    }

    func fold(for photoId: String) -> StackFold? {
        stackIdByPhoto[photoId].flatMap { foldByStack[$0] }
    }

    /// 这张照片是它所在堆栈的展示封面（网格里代表整堆的那张）。
    func isRepresentative(_ photoId: String) -> Bool {
        guard let fold = fold(for: photoId) else { return false }
        return fold.displayCoverPhotoId == photoId
    }

    /// 徽标数字：成员总数（>1 才显示，1 张不显示徽标）。
    func badgeCount(for photoId: String) -> Int {
        fold(for: photoId)?.photoIds.count ?? 0
    }

    /// 折叠后的可见顺序：每个堆栈只保留一张（封面优先，否则首个遇到的成员）。
    ///
    /// 注意封面若在输入列表里出现得更晚，仍放在"首个成员"的位置——保证网格
    /// 不因为折叠而整体重排。输入里不属于任何堆栈的照片原样保留。
    func visiblePhotoIds(_ photoIds: [String]) -> [String] {
        guard !foldByStack.isEmpty else { return photoIds }
        var result: [String] = []
        result.reserveCapacity(photoIds.count)
        var emittedStacks = Set<String>()
        for photoId in photoIds {
            guard let stackId = stackIdByPhoto[photoId], let fold = foldByStack[stackId] else {
                result.append(photoId)
                continue
            }
            if emittedStacks.contains(stackId) { continue }
            emittedStacks.insert(stackId)
            result.append(fold.displayCoverPhotoId ?? photoId)
        }
        return result
    }

    /// 展开某个堆栈（"点开抽屉"）：把该堆的成员按原顺序插回它代表的位置。
    func expandedPhotoIds(_ photoIds: [String], stackId: String) -> [String] {
        guard let fold = foldByStack[stackId] else { return photoIds }
        var result: [String] = []
        result.reserveCapacity(photoIds.count + fold.photoIds.count)
        var inserted = false
        for photoId in photoIds {
            if stackIdByPhoto[photoId] == stackId {
                if !inserted {
                    result.append(contentsOf: fold.photoIds)
                    inserted = true
                }
                continue
            }
            result.append(photoId)
        }
        if !inserted { result.append(contentsOf: fold.photoIds) }
        return result
    }
}


