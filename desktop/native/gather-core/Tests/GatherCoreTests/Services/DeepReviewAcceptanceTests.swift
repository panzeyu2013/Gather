// 第三轮深审（D1–D8）的**验收测试**（审查员探针原样收录）。
//
// S5c-2b-3b-2b-3：旧同步栈（MetadataSyncCoordinator / MetadataOutboxRepo /
// WritebackRepo）删除后，本文件只保留与旧栈无关的三条探针：
//   · failedSidecarMustPreservePriorPhoto（导出原子性）
//   · oldStatementMustBeInvalidAfterReopen（连接代数）
//   · finiteOversizedFaceParameterMustBeRejected（参数校验）
// 依赖 coordinator/outbox 的 debounce、cleanup-revision、waitForIdle、orphan-restore
// 探针随对象一起删除（其语义已由 DeliveryCoordinatorTests 覆盖）。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

@Suite("Deep review probes") struct DeepReviewProbeTests {
 func fixture() throws -> (DBConnection,String,URL) {
  let db = try makeTestDB()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gather-deep-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
  let session = try SessionRepo(connection: db).create(name: "probe", source: "local", sourcePath: root.appendingPathComponent("source").path)
  return (db,session.id,root)
 }
 @Test func failedSidecarMustPreservePriorPhoto() throws {
  let (db,sid,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("source/photo.jpg"); try Data("new-photo".utf8).write(to: input)
  try Data("new-xmp".utf8).write(to: root.appendingPathComponent("source/photo.xmp"))
  try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, checksum, status, width, height, created_at, updated_at) VALUES ('p1', ?, ?, 'photo.jpg', '', 'ready', 32, 24, '2026-01-01', '2026-01-01')").run([.text(sid),.text(input.path)])
  let dest = root.appendingPathComponent("dest"); try FileManager.default.createDirectory(at: dest.appendingPathComponent("photo.xmp"), withIntermediateDirectories: true)
  let output = dest.appendingPathComponent("photo.jpg"); try Data("old-photo".utf8).write(to: output)
  let service = ExportService(photoRepo: PhotoRepo(connection: db), sessionRepo: SessionRepo(connection: db), connection: db)
  let options = ExportOptions(scope: .session, variantPolicy: .preferred, format: .original, naming: ExportNaming(pattern: "{original}"), includeXmp: true, destination: dest.path)
  let result = try service.execute(sessionId: sid, options: options, resume: NativeExportResumeState(destinations: ["p1":"photo.jpg"], completedPhotoIds: ["p1"]))
  print("failedSidecar: failed=\(result.failed),priorPhotoExists=\(FileManager.default.fileExists(atPath: output.path))")
  #expect(result.failed == 1)
  #expect(FileManager.default.fileExists(atPath: output.path))
 }
 @Test func oldStatementMustBeInvalidAfterReopen() throws {
  let db = try DBConnection(path: ":memory:")
  try db.exec("CREATE TABLE probe (id INTEGER)")
  let statement = try db.prepare("INSERT INTO probe VALUES (1)")
  db.close(); try db.reopen(); try db.exec("CREATE TABLE probe (id INTEGER)")
  #expect(throws: DBError.self) { try statement.run([]) }
  let count = try db.prepare("SELECT COUNT(*) FROM probe").get()?[0].intValue
  print("reopen: newConnectionRowCount=\(count ?? -1)")
 }
 @Test func finiteOversizedFaceParameterMustBeRejected() throws {
  print("finiteParameter: minPts=1e30,isFinite=\(Double(1e30).isFinite)")
  #expect(throws: FaceKwServiceError.self) { try validateFaceClusteringParameters(eps: 0.5, minPts: 1e30) }
 }
}
