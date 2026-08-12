// SessionControlView 阶段标记推导单测：对齐 workspace-view.ts deriveStageMarks
// （imported/indexed/analyzed 三硬阶段；created 窗口高亮第一个阶段）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@Suite("deriveStageMarks（对齐 workspace-view.test.ts）")
struct WorkspaceStageMarksTests {
    private func marks(_ stage: WorkspaceStage) -> [SessionControlView.StageMark] {
        SessionControlView(
            sessionId: "s1",
            router: StubCommandRouter.empty()
        ).stageMarks(stage)
    }

    @Test("三阶段顺序与标签")
    func orderAndLabels() {
        let m = marks(.analyzed)
        #expect(m.map(\.id) == ["imported", "indexed", "analyzed"])
        #expect(m.map(\.label) == ["已导入", "已索引", "已分析"])
    }

    @Test("analyzed：全部已到达，最后阶段为 current")
    func analyzedAllReached() {
        let m = marks(.analyzed)
        #expect(m.allSatisfy { $0.reached })
        #expect(m[0].current == false)
        #expect(m[1].current == false)
        #expect(m[2].current == true)
    }

    @Test("imported：仅第一个到达且为 current")
    func importedOnlyFirst() {
        let m = marks(.imported)
        #expect(m[0].reached == true)
        #expect(m[1].reached == false)
        #expect(m[2].reached == false)
        #expect(m[0].current == true)
        #expect(m[1].current == false)
    }

    @Test("indexed：前两个到达，第二个为 current")
    func indexedTwoReached() {
        let m = marks(.indexed)
        #expect(m[0].reached == true)
        #expect(m[1].reached == true)
        #expect(m[2].reached == false)
        #expect(m[1].current == true)
    }

    @Test("created：全部未到达，第一个 current（一跳化导入窗口）")
    func createdHighlightsFirst() {
        let m = marks(.created)
        #expect(m.allSatisfy { !$0.reached })
        #expect(m[0].current == true)
        #expect(m[1].current == false)
    }
}
