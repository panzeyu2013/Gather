// 第三轮全仓审查的**验收测试**（审查员探针原样收录）。
//
// 这些探针当初以「故意断言正确行为」的方式失败，从而暴露 1/2/4/5/6 号问题；
// 修复后它们必须全部通过——通过即视为对应验收标准达成。
//
import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost
@MainActor @Suite("FullScan gallery navigation probe") struct FullScanNavigationProbeTests {
 @Test func galleryBackMustReturnToControl() {
  let nav = RootNavigation(); nav.openSession("s1"); nav.openGallery("s1"); nav.backFromGallery()
  #expect(nav.isSessionPage(sessionId: "s1", page: .control))
 }
}


// MARK: 第三轮验收：管道排空（问题 7）与模型包完整性（问题 9）

@Suite("第三轮验收：子进程管道与模型安装")
struct ReviewAcceptanceProcessTests {
    @Test("问题 7：子进程 stdout 超过管道容量也必须完成（不依赖 terminationHandler 读取）")
    func largeStdoutDoesNotDeadlock() async throws {
        let bridge = CaptureOneBridge()
        // 200,000 字节（远超 pipe 缓冲 ~64KB），旧实现会卡死到超时。
        let output = try await bridge.runProcess(
            executable: "/usr/bin/awk",
            arguments: ["BEGIN { for (i = 0; i < 200000; i++) printf \"x\" }"],
            timeout: 10
        )
        #expect(output.count == 200000, "大输出必须被完整排空（实际 \(output.count) 字节）")
    }

    @Test("问题 7：stderr 大输出 + 非零退出也要返回失败而不挂死")
    func largeStderrDoesNotDeadlock() async throws {
        let bridge = CaptureOneBridge()
        do {
            _ = try await bridge.runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "awk 'BEGIN { for (i = 0; i < 200000; i++) printf \"e\" > \"/dev/stderr\" }'; exit 3"],
                timeout: 10
            )
            Issue.record("非零退出必须抛错")
        } catch {
            // 期望：拿到错误（而不是超时挂死）；错误信息非空。
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    // MARK: 模型包安装

    private func makeZip(files: [String: Data]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-model-zip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: dir.appendingPathComponent(name))
        }
        let zip = dir.appendingPathComponent("package.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-j", zip.path] + files.keys.sorted()
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "zip", code: Int(process.terminationStatus)) }
        return zip
    }

    private func install(_ zip: URL, modelsDir: URL) async throws {
        try await ModelInstaller.install(url: zip, modelsDir: modelsDir.path) { _, _, _ in }
    }

    @Test("问题 9：缺必需文件必须明确报错，且不动既有模型")
    func incompletePackageIsRejected() async throws {
        let modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-models-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelsDir) }
        let existing = modelsDir.appendingPathComponent("face_encoder.onnx")
        try Data("existing-model".utf8).write(to: existing)
        // 只含 det_10g.onnx（缺 w600k_r50.onnx）。
        let zip = try makeZip(files: ["det_10g.onnx": Data("det".utf8)])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        do {
            try await install(zip, modelsDir: modelsDir)
            Issue.record("缺文件必须报错")
        } catch let error as ModelInstaller.InstallError {
            guard case .missingFile = error else {
                Issue.record("期望 missingFile，实际 \(error)")
                return
            }
        }
        #expect(
            try Data(contentsOf: existing) == Data("existing-model".utf8),
            "安装失败必须保留既有模型"
        )
    }

    @Test("问题 9：空文件必须明确报错")
    func emptyFileIsRejected() async throws {
        let modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-models-empty-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: modelsDir) }
        let zip = try makeZip(files: [
            "det_10g.onnx": Data("det".utf8),
            "w600k_r50.onnx": Data(),
        ])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        do {
            try await install(zip, modelsDir: modelsDir)
            Issue.record("空文件必须报错")
        } catch let error as ModelInstaller.InstallError {
            guard case .emptyFile = error else {
                Issue.record("期望 emptyFile，实际 \(error)")
                return
            }
        }
    }

    @Test("问题 9：完整包安装成功并按映射改名")
    func completePackageInstalls() async throws {
        let modelsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-models-ok-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: modelsDir) }
        let zip = try makeZip(files: [
            "det_10g.onnx": Data("det-bytes".utf8),
            "w600k_r50.onnx": Data("enc-bytes".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        try await install(zip, modelsDir: modelsDir)
        #expect(try Data(contentsOf: modelsDir.appendingPathComponent("face_detector.onnx")) == Data("det-bytes".utf8))
        #expect(try Data(contentsOf: modelsDir.appendingPathComponent("face_encoder.onnx")) == Data("enc-bytes".utf8))
    }
}
