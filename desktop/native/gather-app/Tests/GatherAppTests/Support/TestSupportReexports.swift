// desktop/native/gather-app/Tests/GatherAppTests/Support/TestSupportReexports.swift
// WP7：app 侧不再复制 core 的测试夹具。
//
// GatherTestSupport 现在是 gather-core 的 library product（Tests/GatherTestSupport，
// public API）。app 测试 target 依赖该 product，AsyncGate / LockedBox / makeTestDB
// 只有一份实现；本文件保留 app 既有符号名作为 typealias 薄转发。

import GatherTestSupport

typealias AsyncGate = GatherTestSupport.AsyncGate
typealias LockedBox<State> = GatherTestSupport.LockedBox<State>
