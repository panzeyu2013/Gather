// desktop/native/gather-app/Sources/GatherHost/Startup/StartupPhase.swift
// M9 可测化（Wave 5 下一轮）：启动阶段的唯一标签来源。
//
// 为什么单独成类型：makeScene 的 7 个 phaseTimings.record 标签过去是散落字符串，
// 阶段改名/重排没有编译期或测试约束。这里把「阶段表 + 顺序 + 标签」收敛为一处，
// makeScene 只引用 StartupPhase 的 rawValue；GatherAppTests 的契约测试断言
// allCases 的顺序与标签（顺序即装配顺序：restore→dbOpen→composition→
// languageSeed→runtimeStart→embeddingPrep→wire）。
//
// 注意：languageSeed 与 runtimeStart 在 makeScene 里并行执行，但计时记录点顺序
// 固定为 languageSeed 先、runtimeStart 后（与拆分前一致），本枚举按记录点排序。
enum StartupPhase: String, CaseIterable, Sendable {
    case restore
    case dbOpen
    case composition
    case languageSeed
    case runtimeStart
    case embeddingPrep
    case wire
}
