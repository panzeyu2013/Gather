// 第三轮深审（D1–D8）的**验收测试**（审查员探针原样收录）。
//
// 这些探针当初以「断言正确行为」的方式失败，暴露 D1–D8；修复后必须全部通过。
//
import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost
@Suite("Deep model install probe") struct DeepModelProbeTests {
 @Test func failedSecondReplacementMustRollBackFirst() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gather-model-deep-" + UUID().uuidString)
  let source = root.appendingPathComponent("source"); let models = root.appendingPathComponent("models")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
  let order = Array(ModelInstaller.fileMap)
  let protected = models.appendingPathComponent(order[1].value)
  defer { try? FileManager.default.setAttributes([.immutable:false], ofItemAtPath: protected.path); try? FileManager.default.removeItem(at: root) }
  for item in order {
   try Data("new-model".utf8).write(to: source.appendingPathComponent(item.key))
   try Data("old-model".utf8).write(to: models.appendingPathComponent(item.value))
  }
  try FileManager.default.setAttributes([.immutable:true], ofItemAtPath: protected.path)
  let zip = root.appendingPathComponent("package.zip")
  let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
  process.arguments = ["-q","-j",zip.path] + order.map { $0.key }; process.currentDirectoryURL = source
  try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
  var failed = false
  do { try await ModelInstaller.install(url: zip, modelsDir: models.path) { _,_,_ in } }
  catch { failed = true; print("modelInstall: error=\(error)") }
  let first = try String(contentsOf: models.appendingPathComponent(order[0].value), encoding: .utf8)
  let second = try String(contentsOf: protected, encoding: .utf8)
  print("modelInstall: failed=\(failed),first=\(first),second=\(second)")
  #expect(failed)
  #expect(first == "old-model")
  #expect(second == "old-model")
 }
}
