// desktop/native/gather-core/Tests/GatherCoreTests/Support/IntegrationTestGate.swift
// 集成测试门控：默认 PR 套件不做 Vision/CoreML 推理（少量 spec 指纹加载仍可能发生）。
// 夜间任务设置 GATHER_MODEL_TESTS=1 后运行真实模型/Vision 推理用例。

import Foundation

enum IntegrationTestGate {
    static let modelTestsEnabled =
        ProcessInfo.processInfo.environment["GATHER_MODEL_TESTS"] == "1"
}
