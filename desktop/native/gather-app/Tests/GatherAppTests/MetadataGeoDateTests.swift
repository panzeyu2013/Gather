// desktop/native/gather-app/Tests/GatherAppTests/MetadataGeoDateTests.swift
// Wave5（batch5）：GPS 坐标 / 拍摄时间编辑的输入校验、反查映射与 API 接线。
//
// 覆盖：
// 1. MetadataGeoDateInput：范围/成对/时间格式/三态（nil 不动、空串清空、有值写入）；
// 2. 时间归一化：ISO-8601 带时区、EXIF 冒号形态、只有日期；
// 3. 坐标反查：fake 端口的成功/失败映射 + MapKit 实现里的 cityWithContext 解析；
// 4. API 默认未接线：不返回假成功的空 outcome，diskGeoDate 返回 nil；
// 5. LiveMetadataAPI 接线：坐标/时间确实进写盘 attributes，并且回读一致才报 written。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

// MARK: - 反查 fake

private struct FakeGeoPlaceLookup: GeoPlaceLookup {
    let result: Result<GeoPlace, GeoLookupError>
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeoPlace {
        switch result {
        case .success(let place): return place
        case .failure(let error): throw error
        }
    }
}

@Suite("位置/时间输入校验（Wave5 batch5）")
struct MetadataGeoDateInputTests {
    @Test("坐标范围与成对校验")
    func coordinateValidation() throws {
        #expect(throws: GatherError.self) {
            _ = try MetadataGeoDateInput(photoIds: ["p"], latitude: 91, longitude: 0)
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataGeoDateInput(photoIds: ["p"], latitude: -91, longitude: 0)
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataGeoDateInput(photoIds: ["p"], latitude: 0, longitude: 181)
        }
        // 只给一个坐标：不是合法资产。
        #expect(throws: GatherError.self) {
            _ = try MetadataGeoDateInput(photoIds: ["p"], latitude: 31.2, longitude: nil)
        }
        let ok = try MetadataGeoDateInput(photoIds: ["p"], latitude: 31.2304, longitude: 121.4737)
        #expect(ok.latitude == 31.2304)
        #expect(ok.longitude == 121.4737)
        #expect(ok.dateTaken == nil, "nil = 不动")
    }

    @Test("三项全空显式失败（避免 UI 误以为保存成功）")
    func emptyInputIsRejected() {
        #expect(throws: GatherError.self) {
            _ = try MetadataGeoDateInput(photoIds: ["p"])
        }
    }

    @Test("时间三态：nil 不动 / 空串清空 / 合法值归一化写入")
    func dateTriState() throws {
        let keep = try MetadataGeoDateInput(photoIds: ["p"], latitude: 1, longitude: 2, dateTaken: nil)
        #expect(keep.dateTaken == nil)
        let clear = try MetadataGeoDateInput(photoIds: ["p"], dateTaken: "  ")
        #expect(clear.dateTaken == "", "空白 = 清空")
        let write = try MetadataGeoDateInput(
            photoIds: ["p"], dateTaken: "2026-12-01T10:00:00")
        #expect(write.dateTaken == "2026-12-01T10:00:00")
        #expect(throws: GatherError.self) {
            _ = try MetadataGeoDateInput(photoIds: ["p"], dateTaken: "12/01/2026")
        }
    }

    @Test("时间归一化：EXIF 冒号 / 空格分隔 / 只有日期 / 带时区 ISO")
    func dateNormalization() {
        #expect(MetadataGeoDateInput.normalizedDateTime("2026:12:01 10:20:30") == "2026-12-01T10:20:30")
        #expect(MetadataGeoDateInput.normalizedDateTime("2026-12-01 10:20:30") == "2026-12-01T10:20:30")
        #expect(MetadataGeoDateInput.normalizedDateTime("2026-12-01T10:20:30") == "2026-12-01T10:20:30")
        #expect(MetadataGeoDateInput.normalizedDateTime("2026-12-01") == "2026-12-01T00:00:00")
        // 带时区：换算到 UTC 后输出（EXIF 无时区字段的取舍已在注释写明）。
        #expect(MetadataGeoDateInput.normalizedDateTime("2026-12-01T10:20:30Z") == "2026-12-01T10:20:30")
        #expect(MetadataGeoDateInput.normalizedDateTime("2026-12-01T18:20:30+08:00") == "2026-12-01T10:20:30")
        #expect(MetadataGeoDateInput.normalizedDateTime("不是时间") == nil)
    }
}

@Suite("坐标反查地名映射（Wave5 batch5）")
struct GeoPlaceMappingTests {
    @Test("成功映射只带命中的字段（空值不写）")
    func successMapping() {
        let values = GeoPlaceMapping.fieldValues(
            GeoPlace(city: "北京", state: nil, country: "中国"))
        #expect(values[.city] == "北京")
        #expect(values[.country] == "中国")
        #expect(values[.state] == nil, "未命中的字段不写，保留原值")
    }

    @Test("失败分类 → 文案 key（不静默）")
    func failureMessages() {
        #expect(GeoPlaceMapping.messageKey(for: GeoLookupError.noResult) == "该坐标没有对应的地名")
        #expect(GeoPlaceMapping.messageKey(for: GeoLookupError.network)
            == "地名反查失败：网络或服务不可用，请稍后重试")
        #expect(GeoPlaceMapping.messageKey(for: GeoLookupError.cancelled) == "地名反查已取消")
        // 未知错误也走可见文案，不吞。
        #expect(!GeoPlaceMapping.messageKey(for: GeoLookupError.noResult).isEmpty)
    }

    @Test("fake 端口：成功返回地名，失败抛出分类错误")
    func fakeLookupBehavior() async throws {
        let success = FakeGeoPlaceLookup(result: .success(GeoPlace(city: "上海", state: "上海", country: "中国")))
        let place = try await success.reverseGeocode(latitude: 31.2, longitude: 121.5)
        #expect(place.city == "上海")
        let failure = FakeGeoPlaceLookup(result: .failure(.network))
        do {
            _ = try await failure.reverseGeocode(latitude: 31.2, longitude: 121.5)
            Issue.record("网络失败应抛出 GeoLookupError.network")
        } catch let error as GeoLookupError {
            #expect(error == .network)
        } catch {
            Issue.record("非预期错误类型：\(error)")
        }
    }

    @Test("MapKit 实现：cityWithContext 的省州解析（新 API 无 administrativeArea）")
    func stateFromCityWithContext() {
        #expect(MapKitGeoPlaceLookup.stateFromContext("Cupertino, CA") == "CA")
        #expect(MapKitGeoPlaceLookup.stateFromContext("Shanghai") == nil)
        #expect(MapKitGeoPlaceLookup.stateFromContext(nil) == nil)
        #expect(MapKitGeoPlaceLookup.stateFromContext("A, Some Extremely Long Region Name") == nil)
    }
}

// MARK: - API 默认未接线

@Suite("位置/时间 API 默认实现（未接线）")
struct MetadataGeoDateAPIStubTests {
    @Test("未接线的 stub：applyGeoAndDate 显式失败，diskGeoDate 返回 nil")
    func unwiredBehavior() async throws {
        let stub = B6bMetadataAPIStub()
        let input = try MetadataGeoDateInput(
            photoIds: ["p1"], latitude: 31.2304, longitude: 121.4737)
        await #expect(throws: GatherError.self) {
            _ = try await stub.applyGeoAndDate(Confirmed(input, source: .userDialog))
        }
        let snapshot = try await stub.diskGeoDate(photoId: "p1")
        #expect(snapshot == nil, "未接线 = 未知，不是「盘上为空」")
    }
}

// MARK: - Live 接线

private final class GeoDateRecordingXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: MetadataWriteAttributes] = [:]
    private var dropsGeoDateOnRead = false

    func setDropsGeoDateOnRead(_ value: Bool) {
        lock.lock(); dropsGeoDateOnRead = value; lock.unlock()
    }
    func record(_ attributes: MetadataWriteAttributes, path: String) {
        lock.lock(); stored[path] = attributes; lock.unlock()
    }
    func recorded(_ path: String) -> MetadataWriteAttributes? {
        lock.lock(); defer { lock.unlock() }; return stored[path]
    }
    private func drops() -> Bool {
        lock.lock(); defer { lock.unlock() }; return dropsGeoDateOnRead
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        recorded(photoPath)?.keywords ?? []
    }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let snapshot = recorded(photoPath) ?? MetadataWriteAttributes()
        guard drops() else { return snapshot }
        // 模拟「写盘成功但读侧拿不到 GPS/时间」的宿主（JPEG 内嵌读侧未接线的形态）。
        return MetadataWriteAttributes(
            keywords: snapshot.keywords, rating: snapshot.rating, label: snapshot.label,
            descriptive: snapshot.descriptive, triageSignal: snapshot.triageSignal,
            keywordsMode: snapshot.keywordsMode, replaceContact: snapshot.replaceContact,
            clearedContactMembers: snapshot.clearedContactMembers)
    }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        record(attributes, path: photoPath)
    }
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { true }
    func removeFile(_ path: String) async throws {}
}

private final class GeoDateMutationPort: MetadataMutationPort, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: MetadataWriteAttributes] = [:]

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        lock.lock()
        defer { lock.unlock() }
        pending[photoId] = MetadataWriteAttributes(jsonValue: .object(values))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending")
    }
    func takePending() -> [String: MetadataWriteAttributes] {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = [:]
        return result
    }
}

@Suite("LiveMetadataAPI 位置/时间接线（Wave5 batch5）")
struct LiveMetadataGeoDateWiringTests {
    private struct Fixture {
        let dir: URL
        let photoIds: [String]
        let photoPaths: [String]
        let xmp: GeoDateRecordingXMP
        let api: LiveMetadataAPI

        var photoId: String { photoIds[0] }
        var photoPath: String { photoPaths[0] }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// photoCount > 1 用于批量时间调整用例（一次 applyGeoAndDate 传 photoIds 数组）。
    private func makeFixture(
        photoCount: Int = 1, dropsGeoDateOnRead: Bool = false
    ) throws -> Fixture {
        let db = try makeTestDB()
        let session = try SessionRepo(connection: db).create(name: "geo-date", source: "test")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-geodate-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var inputs: [PhotoAddInput] = []
        var photoPaths: [String] = []
        for index in 1...max(1, photoCount) {
            let photoURL = dir.appendingPathComponent("GEO_\(index).cr3")
            try Data("raw-bytes".utf8).write(to: photoURL)
            inputs.append(PhotoAddInput(filepath: photoURL.path, width: 100, height: 80))
            photoPaths.append(photoURL.path)
        }
        let photoIds = try PhotoRepo(connection: db).addPhotos(
            sessionId: session.id, filepaths: inputs, "test").ids
        // let 常量：会被 @Sendable 的 flushPending 闭包捕获，不能再在闭包里看到可变 var。
        let paths = Dictionary(uniqueKeysWithValues: zip(photoIds, photoPaths))

        let xmp = GeoDateRecordingXMP()
        xmp.setDropsGeoDateOnRead(dropsGeoDateOnRead)
        let mutations = GeoDateMutationPort()
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: mutations,
            flushPending: { _ in
                let pending = mutations.takePending()
                for (id, attributes) in pending {
                    guard let path = paths[id] else { continue }
                    xmp.record(attributes, path: path)
                }
                return WritebackResult(
                    totalAffected: pending.count, written: pending.count, failed: 0,
                    skipped: 0, errors: [], failedItems: [], report: "")
            }
        )
        let api = LiveMetadataAPI(
            metadataService: service,
            deliveryRepo: DeliveryRepo(connection: db),
            xmp: xmp,
            fileLock: XMPFileLock(),
            settingsService: SettingsService(repo: SettingsRepo(connection: db)))
        return Fixture(
            dir: dir, photoIds: photoIds, photoPaths: photoPaths, xmp: xmp, api: api)
    }

    @Test("批量时间：一次 applyGeoAndDate 用 photoIds 数组写同一时刻")
    func batchAbsoluteTimeAdjustment() async throws {
        let fixture = try makeFixture(photoCount: 2)
        defer { fixture.cleanup() }
        let input = try MetadataGeoDateInput(
            photoIds: fixture.photoIds, dateTaken: "2026-12-01T10:00:00")
        let outcome = try await fixture.api.applyGeoAndDate(
            Confirmed(input, source: .userDialog))
        #expect(Set(outcome.written) == Set(fixture.photoIds))
        #expect(outcome.failed.isEmpty)
        for path in fixture.photoPaths {
            let written = try #require(fixture.xmp.recorded(path))
            #expect(written.dateTaken == "2026-12-01T10:00:00")
        }
        for photoId in fixture.photoIds {
            let snapshot = try await fixture.api.diskGeoDate(photoId: photoId)
            #expect(snapshot?.dateTaken == "2026-12-01T10:00:00")
        }
    }

    @Test("批量时间：非法时刻整批拒绝（不产生写入）")
    func batchInvalidTimeRejected() {
        do {
            _ = try MetadataGeoDateInput(photoIds: ["a", "b"], dateTaken: "12/01/2026")
            Issue.record("非法时间应被输入层拒绝")
        } catch {
            #expect(error is GatherError)
        }
    }

    @Test("applyGeoAndDate：坐标/时间进写盘 attributes，回读一致才 written")
    func writesThroughLiveAPI() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let input = try MetadataGeoDateInput(
            photoIds: [fixture.photoId],
            latitude: 31.2304,
            longitude: 121.4737,
            dateTaken: "2026-12-01T10:00:00")
        let outcome = try await fixture.api.applyGeoAndDate(
            Confirmed(input, source: .userDialog))
        #expect(outcome.written == [fixture.photoId])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.batchId.isEmpty, "坐标/时间不建批次快照")
        #expect(outcome.undoAvailable == false)

        let written = try #require(fixture.xmp.recorded(fixture.photoPath))
        #expect(abs((written.latitude ?? 0) - 31.2304) < 1e-5)
        #expect(abs((written.longitude ?? 0) - 121.4737) < 1e-5)
        #expect(written.dateTaken == "2026-12-01T10:00:00")

        let snapshot = try await fixture.api.diskGeoDate(photoId: fixture.photoId)
        #expect(snapshot?.dateTaken == "2026-12-01T10:00:00")
    }

    @Test("读侧拿不到 GPS/时间 → 显式 failed（不谎报 written）")
    func failsWhenReadBackDropsFields() async throws {
        let fixture = try makeFixture(dropsGeoDateOnRead: true)
        defer { fixture.cleanup() }
        let input = try MetadataGeoDateInput(
            photoIds: [fixture.photoId], latitude: 31.2304, longitude: 121.4737)
        let outcome = try await fixture.api.applyGeoAndDate(
            Confirmed(input, source: .userDialog))
        #expect(outcome.written.isEmpty)
        #expect(outcome.failed.first?.message.hasPrefix("XMP_WRITE_VERIFICATION_FAILED") == true)
    }
}
