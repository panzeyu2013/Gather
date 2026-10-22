// 第三轮全仓审查的**验收测试**（审查员探针原样收录）。
//
// 这些探针当初以「故意断言正确行为」的方式失败，从而暴露 1/2/4/5/6 号问题；
// 修复后它们必须全部通过——通过即视为对应验收标准达成。
//
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@Suite("FullScan reproduction probes")
struct FullScanProbeTests {
 func fixture() throws -> (DBConnection, String, ExportService, URL, ExportOptions) {
  let db = try makeTestDB()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gather-probe-" + UUID().uuidString)
  let source = root.appendingPathComponent("source")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  let photo = source.appendingPathComponent("sample.jpg"); try Data("photo".utf8).write(to: photo)
  let session = try SessionRepo(connection: db).create(name: "probe", source: "local", sourcePath: source.path)
  try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, checksum, status, width, height, created_at, updated_at) VALUES (?, ?, ?, ?, '', 'ready', 32, 24, '2026-01-01', '2026-01-01')").run([.text("p1"), .text(session.id), .text(photo.path), .text("sample.jpg")])
  let service = ExportService(photoRepo: PhotoRepo(connection: db), sessionRepo: SessionRepo(connection: db), connection: db)
  return (db, session.id, service, root, ExportOptions(scope: .session, variantPolicy: .preferred, format: .original, naming: ExportNaming(pattern: "{original}"), includeXmp: true, destination: root.appendingPathComponent("dest").path))
 }
 @Test func identityMustChangeFingerprint() throws {
  let (db,sid,service,root,options) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let before = try service.deliveryFingerprint(sessionId: sid, options: options)
  try db.prepare("UPDATE photos SET id = 'p2' WHERE id = 'p1'").run([])
  let after = try service.deliveryFingerprint(sessionId: sid, options: options)
  #expect(before != after)
 }
 @Test func xmpChangeMustInvalidateCompletedDelivery() throws {
  let (_,sid,service,root,options) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let xmp = root.appendingPathComponent("source/sample.xmp")
  try Data("old".utf8).write(to: xmp)
  let before = try service.deliveryFingerprint(sessionId: sid, options: options)
  _ = try service.execute(sessionId: sid, options: options)
  try Data("new".utf8).write(to: xmp)
  let after = try service.deliveryFingerprint(sessionId: sid, options: options)
  #expect(before != after)
  let result = try service.execute(sessionId: sid, options: options, resume: NativeExportResumeState(destinations: ["p1":"sample.jpg"], completedPhotoIds: ["p1"]))
  #expect(result.exported == 1)
  let actual = try String(contentsOf: root.appendingPathComponent("dest/sample.xmp"), encoding: .utf8)
  print("XMP resumed content=\(actual),exported=\(result.exported)")
  #expect(actual == "new")
 }
 @Test func newRunMustNotClearOtherRunCancellation() throws {
  let (db,sid,service,root,options) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let photo2 = root.appendingPathComponent("source/second.jpg"); try Data("second".utf8).write(to: photo2)
  try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, checksum, status, width, height, created_at, updated_at) SELECT 'p2', session_id, ?, 'second.jpg', checksum, status, width, height, created_at, updated_at FROM photos WHERE id = 'p1'").run([.text(photo2.path)])
  var nested = false
  var second = options; second.destination = root.appendingPathComponent("second-dest").path
  let result = try service.execute(sessionId: sid, options: options, onProgress: { _ in
   if !nested { nested = true; service.cancel(sessionId: sid); _ = try? service.execute(sessionId: sid, options: second) }
  })
  #expect(result.exported == 1)
  #expect(result.skipped == 1)
 }
}

import Testing
@Suite("Closed connection probe") struct ClosedConnectionProbeTests {
 @Test func preparedStatementAfterCloseMustThrow() throws {
  let db = try DBConnection(path: ":memory:")
  try db.exec("CREATE TABLE probe (id INTEGER)")
  let statement = try db.prepare("INSERT INTO probe VALUES (1)")
  db.close()
  #expect(throws: DBError.self) { try statement.run([]) }
 }
}

import Testing
@Suite("FullScan settings numeric probe") struct SettingsNumberProbeTests {
 @Test func numericSettingsMustRemainFiniteBeforeIntConversion() throws {
  let db = try makeTestDB()
  let service = SettingsService(repo: SettingsRepo(connection: db))
  try service.set("detect_input_size", value: "1e999")
  let value = service.getNumber("detect_input_size", defaultValue: 640)
  print("detect_input_size=\(value)")
  #expect(value.isFinite)
 }
}
