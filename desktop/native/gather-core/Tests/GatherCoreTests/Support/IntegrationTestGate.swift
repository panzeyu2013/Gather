// desktop/native/gather-core/Tests/GatherCoreTests/Support/IntegrationTestGate.swift
// 集成测试门控：默认 PR 套件不做 Vision/CoreML 推理（少量 spec 指纹加载仍可能发生）。
// 手动设置 GATHER_MODEL_TESTS=1 后运行真实模型/Vision 推理用例（无夜间 CI）。

import Foundation

enum IntegrationTestGate {
    static let modelTestsEnabled =
        ProcessInfo.processInfo.environment["GATHER_MODEL_TESTS"] == "1"

    // 已知边界（task-42 静态审计）：未 gated 的 FaceKwService.analyze 用例仍会经
    // 生产路径 FaceEmbeddingModelFactory.make(modelPath: "") 编译 37MB 内置
    // SFace.mlpackage——测试注入的 decodeProvider/inferenceProvider 绕不过这一层
    //（analyze 开头无条件创建嵌入实例）。同进程只编译一次、后续命中 provider 缓存；
    // 若要默认 PR 套件彻底不编译模型，需在 Sources 给 FaceKwService 增加嵌入模型
    // 注入点（跨轮事项，非本文件可解决）。
}
