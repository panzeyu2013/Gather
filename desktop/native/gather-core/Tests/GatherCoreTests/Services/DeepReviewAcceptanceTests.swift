// 第三轮深审（D1–D8）的**验收测试**（审查员探针原样收录）。
//
// 这些探针当初以「断言正确行为」的方式失败，暴露 D1–D8；修复后必须全部通过。
//
import Foundation
import Testing
@testable import GatherCore

private actor ProbeGate {
 var started = false; var opened = false; var waiters: [CheckedContinuation<Void,Never>] = []
 func pause() async { started = true; if opened { return }; await withCheckedContinuation { waiters.append($0) } }
 func hasStarted() -> Bool { started }
 func release() { opened = true; let all = waiters; waiters.removeAll(); for c in all { c.resume() } }
}
private final class ProbeXMP: XMPProvider, @unchecked Sendable {
 let lock = NSLock(); private var writes = 0
 let restoreHook: (@Sendable () throws -> Void)?
 let backupGate: ProbeGate?
 let writeGate: ProbeGate?
 init(restoreHook: (@Sendable () throws -> Void)? = nil, backupGate: ProbeGate? = nil, writeGate: ProbeGate? = nil) { self.restoreHook = restoreHook; self.backupGate = backupGate; self.writeGate = writeGate }
 var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
 func path(_ photo: String) -> String { MetadataOutboxPath.sidecar(photo) }
 func readKeywords(photoPath: String) async throws -> [String] { try await readAttributes(photoPath: photoPath).keywords ?? [] }
 func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
  guard FileManager.default.fileExists(atPath: path(photoPath)) else { return MetadataWriteAttributes() }
  return try JSONDecoder().decode(MetadataWriteAttributes.self, from: Data(contentsOf: URL(fileURLWithPath: path(photoPath))))
 }
 private func noteWrite() { lock.lock(); writes += 1; lock.unlock() }
 func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
  await writeGate?.pause()
  try JSONEncoder().encode(attributes).write(to: URL(fileURLWithPath: path(photoPath)), options: .atomic); noteWrite()
 }
 func backup(photoPath: String) async throws -> String {
  await backupGate?.pause()
  let source = path(photoPath); guard fileExists(source) else { return "" }
  let target = source + ".backup"; try FileManager.default.copyItem(atPath: source, toPath: target); return target
 }
 func restore(photoPath: String, backupPath: String) async throws {
  try restoreHook?()
  try Data(contentsOf: URL(fileURLWithPath: backupPath)).write(to: URL(fileURLWithPath: path(photoPath)), options: .atomic)
 }
 func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
 func removeFile(_ path: String) async throws { try FileManager.default.removeItem(atPath: path) }
}

@Suite("Deep review probes") struct DeepReviewProbeTests {
 func fixture() throws -> (DBConnection,String,URL) {
  let db = try DBConnection(path: ":memory:"); try MigrationRunner().migrate(db)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gather-deep-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
  let session = try SessionRepo(connection: db).create(name: "probe", source: "local", sourcePath: root.appendingPathComponent("source").path)
  return (db,session.id,root)
 }
 private func coordinator(_ db: DBConnection, _ provider: ProbeXMP) -> MetadataSyncCoordinator {
  MetadataSyncCoordinator(outboxRepo: MetadataOutboxRepo(connection: db), writebackRepo: WritebackRepo(connection: db), xmp: provider, connection: db, skipReloadAck: true)
 }
 @Test func failedSidecarMustPreservePriorPhoto() throws {
  let (db,sid,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("source/photo.jpg"); try Data("new-photo".utf8).write(to: input)
  try Data("new-xmp".utf8).write(to: root.appendingPathComponent("source/photo.xmp"))
  try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, width, height, created_at, updated_at) VALUES ('p1', ?, ?, 'photo.jpg', '', 'ready', '{}', '{}', 32, 24, '2026-01-01', '2026-01-01')").run([.text(sid),.text(input.path)])
  let dest = root.appendingPathComponent("dest"); try FileManager.default.createDirectory(at: dest.appendingPathComponent("photo.xmp"), withIntermediateDirectories: true)
  let output = dest.appendingPathComponent("photo.jpg"); try Data("old-photo".utf8).write(to: output)
  let service = ExportService(photoRepo: PhotoRepo(connection: db), sessionRepo: SessionRepo(connection: db), connection: db)
  let options = ExportOptions(scope: .session, variantPolicy: .preferred, format: .original, naming: ExportNaming(pattern: "{original}"), includeXmp: true, destination: dest.path)
  let result = try service.execute(sessionId: sid, options: options, resume: NativeExportResumeState(destinations: ["p1":"photo.jpg"], completedPhotoIds: ["p1"]))
  print("failedSidecar: failed=\(result.failed),priorPhotoExists=\(FileManager.default.fileExists(atPath: output.path))")
  #expect(result.failed == 1)
  #expect(FileManager.default.fileExists(atPath: output.path))
 }
 @Test func reschedulingMustNotBypassDebounce() async throws {
  let (db,sid,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let provider = ProbeXMP(); let co = coordinator(db,provider); co.start()
  let photo = root.appendingPathComponent("source/photo.jpg").path; let path = MetadataOutboxPath.sidecar(photo)
  let repo = MetadataOutboxRepo(connection: db)
  _ = try repo.mergePatch(xmpPath: path, sessionId: sid, photoPath: photo, patch: .object(["rating":.number(3)]), dirtyFields: ["rating"])
  co.schedule(xmpPath: path, delayMs: 10_000)
  try await Task.sleep(for: .milliseconds(50))
  co.schedule(xmpPath: path, delayMs: 10_000)
  try await Task.sleep(for: .milliseconds(150))
  print("debounce: writesBeforeDeadline=\(provider.writeCount),status=\(try repo.get(path)?.status ?? "nil")")
  #expect(provider.writeCount == 0)
  await co.shutdown()
 }
 @Test func cleanupMustNotDeleteNewRevision() async throws {
  let (db,sid,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let photo = root.appendingPathComponent("source/photo.jpg").path; let path = MetadataOutboxPath.sidecar(photo)
  let repo = MetadataOutboxRepo(connection: db)
  _ = try repo.mergePatch(xmpPath: path, sessionId: sid, photoPath: photo, patch: .object(["rating":.number(3)]), dirtyFields: ["rating"])
  let data = try JSONEncoder().encode(MetadataWriteAttributes(rating: 3)); try data.write(to: URL(fileURLWithPath: path))
  let backup = path + ".original"; try JSONEncoder().encode(MetadataWriteAttributes(rating: 1)).write(to: URL(fileURLWithPath: backup))
  let fingerprint = try await MetadataFingerprint.contentFingerprint(path)
  try db.prepare("UPDATE metadata_outbox SET status = 'synced', persisted_revision = revision, base_fingerprint = ?, backup_path = ? WHERE xmp_path = ?").run([.text(fingerprint),.text(backup),.text(path)])
  let provider = ProbeXMP(restoreHook: {
   _ = try repo.mergePatch(xmpPath: path, sessionId: sid, photoPath: photo, patch: .object(["rating":.number(5)]), dirtyFields: ["rating"])
  })
  let co = coordinator(db,provider)
  let result = try await co.cleanup(sessionId: sid, sourceModule: "manual")
  let row = try repo.get(path)
  print("cleanup: deleted=\(result.deletedCount),newRevision=\(String(describing:row?.revision)),backupExists=\(FileManager.default.fileExists(atPath: backup))")
  #expect(row?.revision == 2)
  #expect(row?.fieldsPatch["rating"] == .number(5))
  await co.shutdown()
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
 @Test func waitForIdleMustHonorTimeout() async throws {
  let (db,sid,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let gate = ProbeGate(); let provider = ProbeXMP(writeGate: gate); let co = coordinator(db,provider); co.start()
  let photo = root.appendingPathComponent("source/photo.jpg").path; let path = MetadataOutboxPath.sidecar(photo)
  _ = try MetadataOutboxRepo(connection: db).mergePatch(xmpPath: path, sessionId: sid, photoPath: photo, patch: .object(["rating":.number(3)]), dirtyFields: ["rating"])
  co.schedule(xmpPath: path, delayMs: 0)
  for _ in 0..<100 { if await gate.hasStarted() { break }; try await Task.sleep(for: .milliseconds(5)) }
  #expect(await gate.hasStarted())
  let begin = Date()
  let waiter = Task { () -> Bool in
   do { try await co.waitForIdle(xmpPath: path, timeoutMs: 20); return false }
   catch MetadataSyncError.writerTimeout { return true }
   catch { return false }
  }
  try await Task.sleep(for: .milliseconds(200)); await gate.release()
  let timedOut = await waiter.value
  print("waitForIdle: timeoutMs=20,elapsedMs=\(Int(Date().timeIntervalSince(begin)*1000)),returnedTimeout=\(timedOut)")
  #expect(timedOut)
  await co.shutdown()
 }
 @Test func orphanRestoreMustReloadBackupAfterWaiting() async throws {
  let (db,sid,root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
  let photo = root.appendingPathComponent("source/photo.jpg").path; let path = MetadataOutboxPath.sidecar(photo)
  try JSONEncoder().encode(MetadataWriteAttributes(rating: 1)).write(to: URL(fileURLWithPath: path))
  let gate = ProbeGate(); let provider = ProbeXMP(backupGate: gate); let co = coordinator(db,provider); co.start()
  let repo = MetadataOutboxRepo(connection: db)
  _ = try repo.mergePatch(xmpPath: path, sessionId: sid, photoPath: photo, patch: .object(["rating":.number(3)]), dirtyFields: ["rating"])
  _ = try SessionRepo(connection: db).delete(id: sid)
  _ = try await co.resolveOrphan(xmpPath: path, action: .retry)
  for _ in 0..<100 { if await gate.hasStarted() { break }; try await Task.sleep(for: .milliseconds(5)) }
  #expect(await gate.hasStarted())
  let restore = Task { try await co.resolveOrphan(xmpPath: path, action: .restore) }
  try await Task.sleep(for: .milliseconds(75)); await gate.release()
  _ = try await restore.value
  let exists = FileManager.default.fileExists(atPath: path)
  print("orphanRestore: originalSidecarExists=\(exists),backupLeft=\(FileManager.default.fileExists(atPath: path+".backup"))")
  #expect(exists)
  if exists { #expect(try await provider.readAttributes(photoPath: photo).rating == 1) }
  await co.shutdown()
 }

 @Test func finiteOversizedFaceParameterMustBeRejected() throws {
  print("finiteParameter: minPts=1e30,isFinite=\(Double(1e30).isFinite)")
  #expect(throws: FaceKwServiceError.self) { try validateFaceClusteringParameters(eps: 0.5, minPts: 1e30) }
 }

}
