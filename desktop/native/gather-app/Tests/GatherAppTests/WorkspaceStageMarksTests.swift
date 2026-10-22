// SessionControlView 阶段标记推导单测：对齐 workspace-view.ts deriveStageMarks
// （imported/indexed/analyzed 三硬阶段；created 窗口高亮第一个阶段）。
//
// 合并说明：原 4 条用例对同一纯推导只换了 stage 参数，现合并为一条
// @Test(arguments:) 参数化用例（case 数不变、声明数 5 → 2）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

@MainActor
@Suite("deriveStageMarks（对齐 workspace-view.test.ts）")
struct WorkspaceStageMarksTests {
    private func marks(_ stage: WorkspaceStage, language: L10n.Language = .zhCN) -> [SessionControlView.StageMark] {
        // Cut 4 / 4b-2f：标签由**显式传入**的 L10n 解析，不读进程全局语言
        //（并行套件切语言/系统语言为 en 都不影响断言）。
        SessionControlView(
            workspace: makeTestControlWorkspace(),
            culling: B8CullingAPIStub()
        ).stageMarks(stage, with: L10n(language: language))
    }

    // 裸 View 上没有 languageStore env：en 标签证明语言来自显式 L10n。
    @Test("显式 L10n：en 阶段标签")
    func englishLabels() {
        #expect(marks(.analyzed, language: .en).map(\.label) == ["Imported", "Indexed", "Analyzed"])
        #expect(marks(.created, language: .en).map(\.label) == ["Imported", "Indexed", "Analyzed"])
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
