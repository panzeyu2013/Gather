// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel+C1Health.swift
// Cut 4 / 4c-2d：Capture One 四层预检（reachable/appRunning/documentOpen/
// automationAuthorized）与 osascript 探测（原 SettingsView.swift 506-615 行）。
// 纯搬移：runAppleScript 仍只 resume 一次（C1ProbeGate 在 C1Probe.swift）。
import Foundation
import GatherProtocol

extension SettingsViewModel {

    // MARK: - Capture One 四层预检

    /// 对齐 TS c1-health.ts：reachable/appRunning 复用 CaptureOneBridge
    /// checkHealth（System Events 进程探测）；documentOpen/automationAuthorized
    /// 由本文件内 osascript 文档探测补充（失败分类与 TS errors.ts 一致：
    /// -1743/not authorized → 未授权；no document → 事件已到达应用但无文档 →
    /// automationAuthorized=true；-1712/timed out → 自动化通道不可用）。
    public func checkC1Health() async {
        c1Checking = true
        defer { c1Checking = false }
        let started = Date()
        let result = await captureOne.checkHealth()
        switch result {
        case .success(let appName):
            var snapshot = C1HealthSnapshot(
                reachable: true,
                appRunning: true,
                documentOpen: false,
                automationAuthorized: false,
                appName: appName,
                latencyMs: nil,
                lastError: nil
            )
            do {
                // 协议静态成员不能经实例调用：按 metatype 取实现（E-17）。
                _ = try await runAppleScript(
                    type(of: captureOne).documentProbeScript(appName: appName),
                    timeout: 3
                )
                snapshot.documentOpen = true
                snapshot.automationAuthorized = true
            } catch let probe as C1ProbeError {
                snapshot.documentOpen = false
                // 事件到达应用（无文档/应用侧错误）说明 TCC 已通过；
                // 未授权与超时则自动化通道不可用。
                snapshot.automationAuthorized = (probe != .notAuthorized && probe != .timedOut)
                snapshot.lastError = String(describing: probe)
            } catch {
                snapshot.documentOpen = false
                snapshot.automationAuthorized = false
                snapshot.lastError = String(describing: error)
            }
            snapshot.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            c1Health = snapshot
            c1HealthError = false
        case .failure(let error):
            c1Health = C1HealthSnapshot(
                reachable: false,
                appRunning: false,
                documentOpen: false,
                automationAuthorized: false,
                appName: nil,
                latencyMs: nil,
                lastError: error.description
            )
            c1HealthError = true
        }
    }

    private func runAppleScript(_ script: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let gate = C1ProbeGate(continuation: continuation)
            process.terminationHandler = { process in
                let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    gate.finish(.success(stdout))
                } else {
                    gate.finish(.failure(Self.classifyProbe(stderr)))
                }
            }

            do {
                try process.run()
            } catch {
                gate.finish(.failure(Self.classifyProbe(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                gate.finish(.failure(C1ProbeError.timedOut))
            }
        }
    }

    /// 对齐 TS capture-one/errors.ts 的 classifyCaptureOneError：timeout 优先于
    /// denied 判定（hung app 不能误判为拒绝）。
    nonisolated private static func classifyProbe(_ message: String) -> C1ProbeError {
        let lowercased = message.lowercased()
        if lowercased.contains("-1712") || lowercased.contains("timed out") {
            return .timedOut
        }
        if lowercased.contains("-1743") || lowercased.contains("not authorized") || lowercased.contains("not authorised") {
            return .notAuthorized
        }
        if lowercased.contains("no document") || lowercased.contains("no current document") {
            return .noDocument
        }
        return .scriptFailed(message.isEmpty ? "osascript failed" : message)
    }
}
