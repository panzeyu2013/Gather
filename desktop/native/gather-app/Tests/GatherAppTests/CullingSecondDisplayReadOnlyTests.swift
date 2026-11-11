// desktop/native/gather-app/Tests/GatherAppTests/CullingSecondDisplayReadOnlyTests.swift
// Wave4b / §6 第 4 条：第二屏"真只读"的源码契约守卫 + 画布复用同一套贴片逻辑。
//
// 第二屏共享主窗口的 CullingViewModel；只读是产品硬约束（评审 §5 已确认成立）。
// 画布是私有 View、无法直接实例化断言，因此这里用源码契约守卫把"不许出现写 API"
// 固化成测试：将来有人给第二屏加手势/写盘会立刻红。
import Foundation
import Testing

@Suite("第二屏只读契约（源码守卫）", .serialized)
struct CullingSecondDisplayReadOnlyTests {
    private var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GatherAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // gather-app
            .appendingPathComponent("Sources/GatherUI/Culling/CullingSecondDisplay.swift")
    }

    @Test("第二屏不出现任何写 API（只读镜像）")
    func secondDisplayHasNoWriteAPIs() throws {
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let forbidden = [
            "setVisible(", ".commit(", "batchUpdate(", "writeback", "applyDecision",
            "toggleSelection", "advanceCurrent(", "retreatCurrent(", "queuePendingCommit",
            "performSelectionUpdate",
        ]
        for token in forbidden {
            #expect(!text.contains(token), "第二屏源码出现写 API：\(token)")
        }
    }

    @Test("画布复用主查看器同源的贴片策略与几何（不是另起一套）")
    func secondDisplayCanvasReusesMirrorLogic() throws {
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(text.contains("CullingSecondDisplayMirror.showsTile"), "贴片可见性必须走统一策略")
        #expect(text.contains("CullingSecondDisplayMirror.tile"), "贴片几何必须走统一换算")
        #expect(text.contains("PhotoDetailTileView"), "zoom>1 时必须有细节贴片（不是只放大 2560 位图）")
        #expect(text.contains("allowsHitTesting(false)"), "镜像画布不得接收交互")
    }
}
