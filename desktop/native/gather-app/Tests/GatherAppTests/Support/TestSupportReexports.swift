// desktop/native/gather-app/Tests/GatherAppTests/Support/TestSupportReexports.swift
// WP7：app 侧不再复制 core 的测试夹具。
//
// GatherTestSupport 现在是 gather-core 的 library product（Tests/GatherTestSupport，
// public API）。app 测试 target 依赖该 product，AsyncGate / LockedBox / makeTestDB
// 只有一份实现；本文件保留 app 既有符号名作为薄转发，调用点零改动：
// - AsyncGate / LockedBox：typealias 到 product 内的实现；
// - makeGatherTestDB：转发到统一入口 makeTestDB（并行工作区收尾后，把 22 处
//   调用点改名为 makeTestDB，再删除本转发）。

import GatherPersistence
import GatherTestSupport

typealias AsyncGate = GatherTestSupport.AsyncGate
typealias LockedBox<State> = GatherTestSupport.LockedBox<State>

/// 兼容转发（WP7）：统一建库入口是 GatherTestSupport.makeTestDB()。
func makeGatherTestDB() throws -> DBConnection {
    try makeTestDB()
}
