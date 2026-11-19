// desktop/native/gather-app/Tests/GatherAppTests/StartupContractTests.swift
// M9 可测化（Wave 5 下一轮）：启动阶段表契约测试（纯常量断言，无需 macOS 启动）。
//
// 守护：phaseTimings 的 7 个标签顺序/拼写与 StartupPhase 表一致；makeScene 只引用
// StartupPhase.rawValue，因此阶段改名/重排必须同步改这里与 makeScene 的记录顺序。
// 运行时启动顺序/锁语义仍由 macOS 首跑验证（本测试只覆盖阶段表契约）。
import Testing
@testable import GatherHost

@Suite("Startup 阶段契约")
struct StartupContractTests {
    @Test("启动阶段表的顺序与标签固定（防阶段重排/改名）")
    func startupPhaseTableIsStable() {
        #expect(StartupPhase.allCases == [
            .restore, .dbOpen, .composition, .languageSeed,
            .runtimeStart, .embeddingPrep, .wire,
        ])
        #expect(StartupPhase.allCases.map(\.rawValue) == [
            "restore", "dbOpen", "composition", "languageSeed",
            "runtimeStart", "embeddingPrep", "wire",
        ])
    }
}
