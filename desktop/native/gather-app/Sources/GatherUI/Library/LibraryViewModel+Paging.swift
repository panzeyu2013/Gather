// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel+Paging.swift
// Cut 4 / 4c-2j：从 LibraryViewModel.swift 移出分页（原 660-693 行）。
// 纯搬移：页码边界钳制、hasNextPage 与 rangeText 的区间语义逐字未动。
import Foundation
import GatherProtocol

extension LibraryViewModel {

    // MARK: 分页（TS prevPage/nextPage + toolbar range 语义）

    public func nextPage() {
        goToPage(page + 1)
    }

    public func prevPage() {
        goToPage(max(0, page - 1))
    }

    public func goToPage(_ target: Int) {
        // TS 分页边界：下一页按钮在 (page+1)*PAGE >= total 时禁用。
        let maxPage = max(0, Int(ceil(Double(total) / Double(Self.pageSize))) - 1)
        guard target >= 0, target <= maxPage, target != page else { return }
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(target, isFirst: false)
        }
    }

    public var hasNextPage: Bool {
        (page + 1) * Self.pageSize < total
    }

    /// TS: toolbar range —— 第 min(page*PAGE+1, max(1,total)) – min((page+1)*PAGE, total) 张。
    /// total==0 时旧版输出「第 1–0 张」（start 下界 1）；此处把 start 下界改为 0，
    /// 统一输出「第 0–0 张」，其余分支与旧版逐字一致。
    /// Cut 4 / 4b-2d：区间文案只存 key + 参数，由视图在渲染期按当前语言解析
    /// （VM 不再读进程级语言；切语言后重绘即换文案）。
    public var rangeText: LocalizedText {
        let start = min(page * Self.pageSize + 1, max(0, total))
        let end = min((page + 1) * Self.pageSize, total)
        return LocalizedText("第 %lld–%lld 张", params: ["\(start)", "\(end)"])
    }
}
