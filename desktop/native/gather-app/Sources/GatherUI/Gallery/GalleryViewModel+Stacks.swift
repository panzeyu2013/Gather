// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Stacks.swift
// Wave1 · 堆栈的只读派生（堆栈管理写命令在 +Load，与既有 createStack 同文件：
// 堆栈是库级数据，写路径必须与 .library 域广播同处一个登记过的发布点）。
//
// 这里只回答两件事：某张照片属于哪个堆栈、一批选中照片涉及哪些堆栈。折叠索引
// 只收成员 ≥2 的堆栈（StackFoldIndex），所以单人堆栈在菜单里天然不出现。
import Foundation
import GatherProtocol

extension GalleryViewModel {

    /// 指定照片涉及的堆栈（按出现顺序去重；只含成员 ≥2 的堆栈）。
    func folds(for photoIds: [String]) -> [StackFold] {
        var seen = Set<String>()
        var result: [StackFold] = []
        for photoId in photoIds {
            guard let fold = stackFolds.fold(for: photoId),
                  seen.insert(fold.stackId).inserted else { continue }
            result.append(fold)
        }
        return result
    }

    /// 照片所属堆栈（网格右键菜单的可用性判定用）。
    func fold(containing photoId: String) -> StackFold? {
        stackFolds.fold(for: photoId)
    }
}
