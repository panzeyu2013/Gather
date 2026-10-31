// desktop/native/gather-app/Tests/GatherAppTests/C1InstallationTests.swift
// V2 C1 冒烟发现的回归：Capture One 16 的 bundle id 是 com.captureone.captureone16，
// 旧检测表只有 com.captureone.captureone / com.phaseone.captureone，导致装了 C1 也判 false。
import Testing
@testable import GatherHost

@Suite("C1 安装检测（版本化 bundle id / 路径兜底）")
struct C1InstallationTests {
    @Test("Capture One 16 的版本化 id 与标准路径都能识别")
    func detectsVersionedIdentifierAndFallbackPath() {
        #expect(C1Installation.probeInstalled(
            bundleIDExists: { $0 == "com.captureone.captureone16" },
            fileExists: { _ in false }))
        #expect(C1Installation.probeInstalled(
            bundleIDExists: { _ in false },
            fileExists: { $0 == "/Applications/Capture One.app" }))
        #expect(!C1Installation.probeInstalled(
            bundleIDExists: { _ in false },
            fileExists: { _ in false }))
    }
}
