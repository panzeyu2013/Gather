// desktop/native/gather-app/Tests/GatherAppTests/StackFoldIndexTests.swift
// P1-7：堆栈折叠的代表张必须在**输入内**选。
//
// 背景（台账 2026-10-30 §3 P1-7）：旧实现无条件 emit fold.displayCoverPhotoId，
// 调用方 GalleryViewModel.folded 再按 id 回填行——封面被 facet / 4 档筛掉、
// 或还在未加载的后续页时，这个 id 不在输入里，compactMap 直接把它丢掉，
// 于是**整堆连同命中成员一起从网格消失**（胶囊却仍按全堆张数显示）。
//
// 这里锁三条不变量：
// 1. visiblePhotoIds 只 emit 输入里存在的 id（下游按 id 回填绝不丢行）；
// 2. 同一堆只留一个代表，且封面在输入里时优先用它；
// 3. 展开只插输入里存在的成员，插回代表所在的原始位置。
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("堆栈折叠索引（P1-7）")
struct StackFoldIndexTests {

    // MARK: - 夹具

    /// 两照一堆：p1 是显式封面，p2 是兄弟成员。
    private func pairFold() -> StackFold {
        StackFold(stackId: "s1", name: "连拍", coverPhotoId: "p1", photoIds: ["p1", "p2"])
    }

    /// 三照一堆：p1 封面，p2/p3 成员（用于"输入缺成员"与"展开"两类用例）。
    private func tripleFold() -> StackFold {
        StackFold(stackId: "s1", name: "连拍", coverPhotoId: "p1", photoIds: ["p1", "p2", "p3"])
    }

    /// 折叠结果的基本不变量：emit 的 id 必须都在输入里，且不出现重复行。
    /// 这条断言就是 P1-7 的根因守卫——旧实现会在封面不在输入时立刻违反它。
    private func expectRepresentable(_ visible: [String], from input: [String]) {
        let inputSet = Set(input)
        #expect(
            visible.allSatisfy { inputSet.contains($0) },
            "折叠 emit 了输入里不存在的 id（下游按 id 回填会整行丢掉）：\(visible)")
        #expect(Set(visible).count == visible.count, "折叠结果出现重复行：\(visible)")
    }

    // MARK: - 代表张

    @Test("封面在输入里时用封面当代表，且封面排在成员之后也放在首位")
    func coverInInputBecomesRepresentative() {
        let index = StackFoldIndex(folds: [pairFold()])
        // 网格顺序是 p2 在前（例如按文件名排序）：代表张仍应是封面 p1，
        // 但位置必须留在"首个成员"处，不因为折叠整体重排。
        let visible = index.visiblePhotoIds(["p2", "p1"])
        #expect(visible == ["p1"])
        expectRepresentable(visible, from: ["p2", "p1"])
    }

    @Test("封面被筛掉（不在输入）时回退该堆首个成员，整堆不消失")
    func coverFilteredOutFallsBackToFirstMember() {
        let index = StackFoldIndex(folds: [pairFold()])
        // facet / 4 档把封面筛掉后，输入只剩兄弟成员。
        let visible = index.visiblePhotoIds(["p2"])
        #expect(visible == ["p2"], "封面不在输入时必须用命中成员代表，而不是 emit 一个查不到的 id")
        expectRepresentable(visible, from: ["p2"])
        // 回归证明：旧实现这里 emit 的是 "p1"（输入里没有），下游会整行丢弃。
        #expect(index.stackId(for: "p2") == "s1")
    }

    @Test("封面在未加载的后续页：先由成员代表，补页后回到封面")
    func coverOnLaterPage() {
        let index = StackFoldIndex(folds: [pairFold()])
        // 只有第一页：封面 p1 还没取回来。
        let firstPage = index.visiblePhotoIds(["p2"])
        #expect(firstPage == ["p2"])
        expectRepresentable(firstPage, from: ["p2"])
        // 补第二页后 p1 进入输入：代表张换回封面，位置仍在 p2（首个成员）处。
        let secondPage = index.visiblePhotoIds(["p2", "p1"])
        #expect(secondPage == ["p1"])
        expectRepresentable(secondPage, from: ["p2", "p1"])
    }

    @Test("输入缺部分成员：只折叠留在输入里的成员，堆外的行一个不丢")
    func partialMembersKeepEveryInputRow() {
        let index = StackFoldIndex(folds: [tripleFold()])
        // p2 被筛掉；p1（封面）+ p3 在输入里；p9 不属于任何堆栈。
        let input = ["p1", "p3", "p9"]
        let visible = index.visiblePhotoIds(input)
        #expect(visible == ["p1", "p9"], "同一堆只留一个代表，非堆栈照片按原顺序保留")
        expectRepresentable(visible, from: input)
    }

    @Test("封面不在但多名成员在输入：仍只留一个代表且不丢该行")
    func multipleMembersWithoutCoverKeepOneRow() {
        // 显式封面指向不在成员里的照片 → displayCoverPhotoId 退到首个成员 p2。
        let fold = StackFold(
            stackId: "s1", name: "连拍", coverPhotoId: "ghost", photoIds: ["p2", "p3"])
        let index = StackFoldIndex(folds: [fold])
        let input = ["p2", "p3", "p9"]
        let visible = index.visiblePhotoIds(input)
        #expect(visible.count == 2, "3 行进 2 行出（一堆折叠成一张 + 1 张独立）")
        #expect(visible.first == "p2")
        expectRepresentable(visible, from: input)
    }

    @Test("徽标仍是全堆张数（折叠是展示，不是筛选）")
    func badgeCountStaysFullStackSize() {
        let index = StackFoldIndex(folds: [tripleFold()])
        // 只加载/筛出 p2 时，徽标依然按整堆 3 张显示（与侧栏/堆栈计数同口径）。
        #expect(index.badgeCount(for: "p2") == 3)
        #expect(index.badgeCount(for: "p9") == 0)
    }

    // MARK: - 展开

    @Test("展开把成员按堆内顺序插回代表的位置")
    func expandInsertsMembersAtRepresentativePosition() {
        let index = StackFoldIndex(folds: [tripleFold()])
        // 已筛选、未折叠的输入：成员按文件名排序时可以散落（p2 在 p1/p3 之前）。
        let filtered = ["x", "p2", "y", "p1", "p3"]
        let expanded = index.expandedPhotoIds(filtered, stackId: "s1")
        #expect(
            expanded == ["x", "p1", "p2", "p3", "y"],
            "成员应收拢到首个成员的位置，并按堆内顺序（position 序）排列")
        expectRepresentable(expanded, from: filtered)
    }

    @Test("展开不插入不在输入里的成员（否则等于用折叠绕过筛选）")
    func expandSkipsMembersOutsideInput() {
        let index = StackFoldIndex(folds: [tripleFold()])
        // p1（封面）与 p3 被 facet 筛掉：展开只能补回同样在输入里的 p2。
        let filtered = ["p2", "z"]
        let expanded = index.expandedPhotoIds(filtered, stackId: "s1")
        #expect(expanded == ["p2", "z"])
        expectRepresentable(expanded, from: filtered)
    }

    @Test("输入里没有该堆成员时展开保持原样，不在末尾凭空追加")
    func expandWithoutAnchorKeepsInput() {
        let index = StackFoldIndex(folds: [tripleFold()])
        #expect(index.expandedPhotoIds(["z"], stackId: "s1") == ["z"])
        #expect(index.expandedPhotoIds([], stackId: "s1") == [])
        // 未知堆栈 id 也必须是恒等变换（不猜）。
        #expect(index.expandedPhotoIds(["z"], stackId: "no-such-stack") == ["z"])
    }

    // MARK: - 直通

    @Test("空索引或单成员堆栈时折叠是恒等变换")
    func noFoldingIsIdentity() {
        let input = ["a", "b", "c"]
        #expect(StackFoldIndex().visiblePhotoIds(input) == input)
        // 单成员堆栈在 init 就被过滤掉（>1 才算堆栈），否则会给一张照片加"1 张"徽标。
        let singleton = StackFoldIndex(folds: [
            StackFold(stackId: "s2", coverPhotoId: "b", photoIds: ["b"]),
        ])
        #expect(singleton.isEmpty)
        #expect(singleton.visiblePhotoIds(input) == input)
        #expect(singleton.badgeCount(for: "b") == 0)
    }
}