// SessionControlView 阶段标记推导单测：对齐 workspace-view.ts deriveStageMarks
// （imported/indexed/analyzed 三硬阶段；created 窗口高亮第一个阶段）。
//
// 合并说明：原 4 条用例对同一纯推导只换了 stage 参数，现合并为一条
// @Test(arguments:) 参数化用例（case 数不变、声明数 5 → 2）。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

@MainActor
@Suite("deriveStageMarks（对齐 workspace-view.test.ts）")
struct WorkspaceStageMarksTests {
    private func marks(_ stage: WorkspaceStage) -> [SessionControlView.StageMark] {
        // 标签经 l() 出当前语言：锁内钉死 zh-CN，避免并行套件临时切语言
        // （或系统语言为 en）时中文断言 flake。
        AppLanguageLock.withCopy("zh-CN") {
            SessionControlView(
                sessionId: "s1",
                router: StubCommandRouter.empty()
            ).stageMarks(stage)
        }
    }

    @Test("三阶段顺序与标签")
    func orderAndLabels() {
        let m = marks(.analyzed)
        #expect(m.map(\.id) == ["imported", "indexed", "analyzed"])
        #expect(m.map(\.label) == ["已导入", "已索引", "已分析"])
    }

    // 原 4 条用例：analyzed / imported / indexed / created —— 逐索引断言
    // （reached 与 current）等值改写为布尔数组比较，覆盖不变。
    @Test("reached/current 随 stage 推进", arguments: [
        (WorkspaceStage.analyzed, [true, true, true], [false, false, true],
         "analyzed：全部已到达，最后阶段为 current"),
        (WorkspaceStage.imported, [true, false, false], [true, false, false],
         "imported：仅第一个到达且为 current"),
        (WorkspaceStage.indexed, [true, true, false], [false, true, false],
         "indexed：前两个到达，第二个为 current"),
        (WorkspaceStage.created, [false, false, false], [true, false, false],
         "created：全部未到达，第一个 current（一跳化导入窗口）"),
    ])
    private func marksMatrix(
        stage: WorkspaceStage,
        reached: [Bool],
        current: [Bool],
        label: String
    ) {
        let m = marks(stage)
        #expect(m.map(\.reached) == reached, Comment(rawValue: label))
        #expect(m.map(\.current) == current, Comment(rawValue: label))
    }
}
