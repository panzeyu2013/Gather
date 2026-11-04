// desktop/native/gather-app/Sources/GatherUI/Curation/StackFoldIndex.swift
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

    /// 徽标数字：成员总数（>1 才显示，1 张不显示徽标）。
    ///
    /// 口径保持在"这一堆一共几张"（折叠只影响展示，不是筛选）：成员被当前
    /// 条件筛掉时徽标仍是全堆张数，与侧栏/堆栈管理的计数一致。
    func badgeCount(for photoId: String) -> Int {
        fold(for: photoId)?.photoIds.count ?? 0
    }

    /// 折叠后的可见顺序：每个堆栈只保留一张代表（封面优先，否则首个遇到的成员）。
    ///
    /// 注意封面若在输入列表里出现得更晚，仍放在"首个成员"的位置——保证网格
    /// 不因为折叠而整体重排。输入里不属于任何堆栈的照片原样保留。
    ///
    /// **必须在输入内选代表**（P1-7）：旧实现无条件 emit `displayCoverPhotoId`，
    /// 而调用方（GalleryViewModel.folded）用 `byId[代表]` 回填行——封面被 facet /
    /// 4 档筛掉、或还在未加载的后续页时，这个 id 不在输入里，回填时被 compactMap
    /// 静默丢弃，于是**整堆连同命中成员一起从网格消失**（胶囊却还按全堆张数显示）。
    /// 因此：封面确实在输入里才用它，否则退到该堆在输入里的第一个成员。
    /// 这样 emit 的每个 id 都属于输入，折叠只减少重复、绝不丢行。
    func visiblePhotoIds(_ photoIds: [String]) -> [String] {
        guard !foldByStack.isEmpty else { return photoIds }
        var result: [String] = []
        result.reserveCapacity(photoIds.count)
        var emittedStacks = Set<String>()
        // 封面是否真的在本次输入里（一次构集合，避免逐张 contains 的 O(n²)）。
        let present = Set(photoIds)
        for photoId in photoIds {
            guard let stackId = stackIdByPhoto[photoId], let fold = foldByStack[stackId] else {
                result.append(photoId)
                continue
            }
            if emittedStacks.contains(stackId) { continue }
            emittedStacks.insert(stackId)
            if let cover = fold.displayCoverPhotoId, present.contains(cover) {
                result.append(cover)
            } else {
                result.append(photoId)
            }
        }
        return result
    }

    /// 展开某个堆栈（"点开抽屉"）：把该堆成员按堆内顺序插回它代表的位置。
    ///
    /// **契约**：入参是"已按当前查询筛选、但尚未折叠"的成员 id 列表（代表张也在
    /// 其中）；返回同一批行，只把这一堆的成员收拢到首个成员的位置。传入已折叠的
    /// 列表只含代表张，展开自然没有新行可插（调用方要传未折叠的输入）。
    ///
    /// 只插入**输入里存在的**成员（与 visiblePhotoIds 同一条红线）：下游按 id
    /// 回填行，插进一个不在输入里的成员 id 会同样被静默丢弃，展开后的顺序也跟着
    /// 错位；把被 facet 筛掉的成员塞回来更是等于用折叠绕过筛选。
    func expandedPhotoIds(_ photoIds: [String], stackId: String) -> [String] {
        guard let fold = foldByStack[stackId] else { return photoIds }
        let present = Set(photoIds)
        let members = fold.photoIds.filter { present.contains($0) }
        var result: [String] = []
        result.reserveCapacity(photoIds.count + members.count)
        var inserted = false
        for photoId in photoIds {
            if stackIdByPhoto[photoId] == stackId {
                if !inserted {
                    result.append(contentsOf: members)
                    inserted = true
                }
                continue
            }
            result.append(photoId)
        }
        // 该堆在输入里一个成员都没有（例如代表张被筛掉后整堆已不可见）：
        // 没有可插回的位置，保持原样，不在末尾凭空追加。
        guard inserted else { return photoIds }
        return result
    }
}


