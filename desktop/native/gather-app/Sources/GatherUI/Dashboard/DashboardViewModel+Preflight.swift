// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel+Preflight.swift
// Cut 4 / 4c-2i：DashboardViewModel 的 C1 预检分区（自 DashboardViewModel.swift 原样移出）。
// 行为不变：四层预检门控与「检查中」判定。

import Foundation
import GatherProtocol

extension DashboardViewModel {
    /// TS handleCreate：打开对话框且来源为 Capture One 时自动预检；
    /// 切换来源时同样触发。
    func runC1Preflight() async {
        c1Preflight = .checking
        guard let bridge = captureOne else {
            c1Preflight = .finished(C1PreflightResult.failed())
            return
        }
        c1Preflight = .finished(C1PreflightResult.build(from: await bridge.preflight()))
    }

    /// 预检进行中（禁用创建按钮，对齐 TS createMutation 未完成时 disabled）。
    var isC1PreflightChecking: Bool {
        if case .checking = c1Preflight { return true }
        return false
    }
}
