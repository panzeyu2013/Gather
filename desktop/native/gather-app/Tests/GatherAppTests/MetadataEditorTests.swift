// desktop/native/gather-app/Tests/GatherAppTests/MetadataEditorTests.swift
// Wave5（batch2）：元数据编辑器的受控值（IPTCControlledVocabulary）写盘口径。
//
// 覆盖：
// 1. 写盘归一化：countryCode 手打小写按大写写入（词表值形态唯一）；
// 2. 校验范围：只拦"改过的、非空的"词表外值（未改动/清空的存量值不阻塞编辑）；
// 3. 列表字段逐项校验（scene/subjectCode 的每个码都必须在词表内）；
// 4. 非受控值字段（自由文本 / release id）不误伤。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherApplication
import GatherDelivery
@testable import GatherUI
@testable import GatherHost
import GatherTestSupport

@Suite("元数据编辑器受控值（Wave5 batch2）")
struct MetadataEditorTests {
    private var emptyContact: DescriptiveContact { DescriptiveContact() }

    private func changes(
        _ values: [DescriptiveField: String], initial: [DescriptiveField: String]
    ) -> MetadataEditorDraft.Patch? {
        MetadataEditorDraft.changes(
            values: values, initial: initial,
            contact: emptyContact, initialContact: emptyContact)
    }

    @Test("countryCode 小写输入归一化为大写，且不算违规")
    func countryCodeNormalizesToUppercase() {
        let initial: [DescriptiveField: String] = [.countryCode: "CN"]
        var values = initial
        values[.countryCode] = "cn"
        #expect(MetadataEditorDraft.controlledValueViolation(values: values, initial: initial) == nil)
        let edited = changes(values, initial: initial)
        #expect(edited?.fields.countryCode == "CN", "写盘必须是词表形态（大写）")
        #expect(edited?.fields.value(for: .countryCode) != nil)
    }

    @Test("词表外标量值被拦截（countryCode / digitalSourceType）")
    func rejectsScalarValuesOutsideVocabulary() {
        let initial: [DescriptiveField: String] = [:]
        var country = initial
        country[.countryCode] = "ZZ"
        let countryViolation = MetadataEditorDraft.controlledValueViolation(
            values: country, initial: initial)
        #expect(countryViolation?.field == .countryCode)
        #expect(countryViolation?.value == "ZZ")

        var source = initial
        source[.digitalSourceType] = "digitalCapture"
        let sourceViolation = MetadataEditorDraft.controlledValueViolation(
            values: source, initial: initial)
        #expect(sourceViolation?.field == .digitalSourceType,
                "digitalSourceType 写的是 CV URI，不是短名")

        var valid = initial
        valid[.digitalSourceType] =
            "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
        #expect(MetadataEditorDraft.controlledValueViolation(values: valid, initial: initial) == nil)
    }

    @Test("列表受控值逐项校验；合法组合可写盘")
    func validatesEachListControlledItem() {
        let initial: [DescriptiveField: String] = [:]
        var scene = initial
        scene[.scene] = "010100、011100"
        #expect(MetadataEditorDraft.controlledValueViolation(values: scene, initial: initial) == nil)
        #expect(changes(scene, initial: initial)?.fields.scene == ["010100", "011100"])

        scene[.scene] = "010100、 999999"
        let violation = MetadataEditorDraft.controlledValueViolation(values: scene, initial: initial)
        #expect(violation?.field == .scene)
        #expect(violation?.value == "999999", "逐项校验要报出具体那个错码")

        var subject = initial
        subject[.subjectCode] = "01000000, 15000000"
        #expect(MetadataEditorDraft.controlledValueViolation(values: subject, initial: initial) == nil)
        #expect(changes(subject, initial: initial)?.fields.subjectCode == ["01000000", "15000000"])
    }

    @Test("未改动 / 清空 / 其它字段编辑都不触发受控值校验")
    func unchangedOrClearedValuesAreAllowed() {
        // 盘上存量词表外值（3 字母国家码）：用户不动它就不该被拦。
        let initial: [DescriptiveField: String] = [.countryCode: "CHN"]
        #expect(MetadataEditorDraft.controlledValueViolation(values: initial, initial: initial) == nil)

        var cleared = initial
        cleared[.countryCode] = ""
        #expect(MetadataEditorDraft.controlledValueViolation(values: cleared, initial: initial) == nil)
        #expect(changes(cleared, initial: initial)?.fields.countryCode == "", "清空仍是显式清空")

        var other = initial
        other[.city] = "任意城市名"
        #expect(MetadataEditorDraft.controlledValueViolation(values: other, initial: initial) == nil)
        #expect(changes(other, initial: initial)?.fields.city == "任意城市名")
    }

    @Test("非受控值字段（instructions / release id）自由写入，只做 trim")
    func freeTextFieldsAreNotValidated() {
        let initial: [DescriptiveField: String] = [:]
        var values = initial
        values[.instructions] = "  禁发至 2026-12-01  "
        values[.modelReleaseID] = " MR-0001 、MR-0002 "
        #expect(MetadataEditorDraft.controlledValueViolation(values: values, initial: initial) == nil)
        let edited = changes(values, initial: initial)
        #expect(edited?.fields.instructions == "禁发至 2026-12-01")
        #expect(edited?.fields.modelReleaseID == ["MR-0001", "MR-0002"])
        #expect(edited?.fields.eventIdentifier == nil, "未改动字段不出现（nil = 不触碰）")
    }

    // MARK: - Wave5（batch5）：位置 / 拍摄时间草稿

    @Test("位置/时间草稿：坐标成对提交，未改动返回 nil")
    func geoDateDraftCoordinates() throws {
        let unchanged = try MetadataEditorDraft.geoDateChanges(
            latitude: "31.230400", longitude: "121.473700",
            dateTaken: "", initialLatitude: "31.230400",
            initialLongitude: "121.473700", initialDate: "")
        #expect(unchanged == nil, "与初值相同 = 无改动")

        let changedDraft = try MetadataEditorDraft.geoDateChanges(
            latitude: "39.904200", longitude: "116.407400",
            dateTaken: "", initialLatitude: "31.230400",
            initialLongitude: "121.473700", initialDate: "")
        let changed = try #require(changedDraft)
        #expect(changed.latitude == 39.9042)
        #expect(changed.longitude == 116.4074)
        #expect(changed.dateTaken == nil, "时间未改动 = 不写")
    }

    /// 位置/时间校验失败的断言（不用 #expect(throws: 错误值)：统一 do/catch 断言具体分类）。
    private func expectGeoDateViolation(
        _ expected: MetadataEditorDraft.GeoDateValidationError,
        latitude: String,
        longitude: String,
        dateTaken: String = ""
    ) {
        do {
            _ = try MetadataEditorDraft.geoDateChanges(
                latitude: latitude, longitude: longitude, dateTaken: dateTaken,
                initialLatitude: "", initialLongitude: "", initialDate: "")
            Issue.record("应抛出 \(expected)")
        } catch let error as MetadataEditorDraft.GeoDateValidationError {
            #expect(error == expected)
        } catch {
            Issue.record("非预期错误类型：\(error)")
        }
    }

    @Test("位置/时间草稿：半个坐标/越界/非数字显式失败")
    func geoDateDraftValidation() {
        expectGeoDateViolation(.coordinatesIncomplete, latitude: "31.2", longitude: "")
        expectGeoDateViolation(.latitudeOutOfRange(91), latitude: "91", longitude: "0")
        expectGeoDateViolation(.longitudeOutOfRange(181), latitude: "0", longitude: "181")
        expectGeoDateViolation(.latitudeNotNumber("abc"), latitude: "abc", longitude: "0")
        expectGeoDateViolation(.longitudeNotNumber("abc"), latitude: "0", longitude: "abc")
    }

    @Test("位置/时间草稿：时间归一化写入 / 空串清空 / 初值同形态不算改动")
    func geoDateDraftDate() throws {
        // 初值是 EXIF 冒号形态（盘上常见），用户输入 ISO：归一化后相同 → 不算改动。
        let sameForm = try MetadataEditorDraft.geoDateChanges(
            latitude: "", longitude: "", dateTaken: "2026-12-01T10:20:30",
            initialLatitude: "", initialLongitude: "",
            initialDate: "2026:12:01 10:20:30")
        #expect(sameForm == nil)

        let changedDraft = try MetadataEditorDraft.geoDateChanges(
            latitude: "", longitude: "", dateTaken: "2026:12:02 08:00:00",
            initialLatitude: "", initialLongitude: "",
            initialDate: "2026:12:01 10:20:30")
        let changed = try #require(changedDraft)
        #expect(changed.dateTaken == "2026-12-02T08:00:00")

        let clearedDraft = try MetadataEditorDraft.geoDateChanges(
            latitude: "", longitude: "", dateTaken: "",
            initialLatitude: "", initialLongitude: "",
            initialDate: "2026:12:01 10:20:30")
        let cleared = try #require(clearedDraft)
        #expect(cleared.dateTaken == "", "空串 = 清空")

        // 初值本来就空 + 输入也空 = 无改动。
        let emptyDraft = try MetadataEditorDraft.geoDateChanges(
            latitude: "", longitude: "", dateTaken: "",
            initialLatitude: "", initialLongitude: "", initialDate: "")
        #expect(emptyDraft == nil)

        do {
            _ = try MetadataEditorDraft.geoDateChanges(
                latitude: "", longitude: "", dateTaken: "12/01/2026",
                initialLatitude: "", initialLongitude: "", initialDate: "")
            Issue.record("非法时间应抛出 invalidDate")
        } catch let error as MetadataEditorDraft.GeoDateValidationError {
            #expect(error == .invalidDate("12/01/2026"))
        } catch {
            Issue.record("非预期错误类型：\(error)")
        }
    }

    @Test("面板分组：Core 22 / Extension 10 / 交付字段 4，三组并集 == 全部字段")
    func panelGroupsPartitionAllFields() {
        let groups = MetadataDisplay.iptcCoreFields
            + MetadataDisplay.iptcExtensionFields
            + MetadataDisplay.wave5DeliveryFields
        #expect(MetadataDisplay.iptcCoreFields.count == 22)
        #expect(MetadataDisplay.iptcExtensionFields.count == 10)
        #expect(MetadataDisplay.wave5DeliveryFields.count == 4)
        #expect(Set(groups) == Set(DescriptiveField.allCases))
        #expect(groups.count == DescriptiveField.allCases.count, "分组不能重复覆盖同一字段")
        for field in DescriptiveField.allCases {
            #expect(!MetadataDisplay.fieldTitle(field).isEmpty)
        }
    }

    // MARK: - Wave5（batch7）：批量时间调整纯计算

    @Test("偏移量解析：带符号整数 × 单位 → 秒；非法/空 → nil")
    func offsetSecondsParsing() {
        #expect(MetadataEditorDraft.offsetSeconds("-2", unit: .hours) == -7_200)
        #expect(MetadataEditorDraft.offsetSeconds("30", unit: .minutes) == 1_800)
        #expect(MetadataEditorDraft.offsetSeconds("+1", unit: .days) == 86_400)
        #expect(MetadataEditorDraft.offsetSeconds("0", unit: .seconds) == 0, "0 由调用方禁用按钮")
        #expect(MetadataEditorDraft.offsetSeconds("abc", unit: .hours) == nil)
        #expect(MetadataEditorDraft.offsetSeconds("", unit: .hours) == nil)
        #expect(MetadataEditorDraft.offsetSeconds("1.5", unit: .hours) == nil)
        #expect(MetadataEditorDraft.offsetSeconds("99999999999999999999", unit: .days) == nil,
                "溢出必须失败，不能静默截断")
    }

    @Test("时间偏移：跨日/跨月/闰年进位，负偏移回到前一天")
    func shiftedDateTimeArithmetic() {
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2026-12-01T23:30:00", bySeconds: 3_600) == "2026-12-02T00:30:00")
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2026-12-01T00:30:00", bySeconds: -3_600) == "2026-11-30T23:30:00")
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2026-12-31T23:59:30", bySeconds: 60) == "2027-01-01T00:00:30")
        // 闰年 2 月 29 日存在，跨年不丢日。
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2028-02-28T23:00:00", bySeconds: 3_600) == "2028-02-29T00:00:00")
        // 输入形态兼容：EXIF 冒号/空格都能先归一化再偏移。
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2026:12:01 10:00:00", bySeconds: 60) == "2026-12-01T10:01:00")
        #expect(MetadataEditorDraft.shiftedDateTime("不是时间", bySeconds: 60) == nil)
    }

    @Test("批量时间预演示例：不同形态旧时间同偏移后各自正确（跨日/冒号形态）")
    func batchTimePreviewSamples() {
        let olds = ["2026-12-01T23:30:00", "2026:12:02 08:00:00", "2026-12-01"]
        let shifted = olds.compactMap {
            MetadataEditorDraft.shiftedDateTime($0, bySeconds: 3_600)
        }
        #expect(shifted == [
            "2026-12-02T00:30:00",
            "2026-12-02T09:00:00",
            "2026-12-01T01:00:00",
        ])
        // 不可解析的旧值在预演里走"不可调整"分支（不写、不静默算错）。
        #expect(olds.compactMap {
            MetadataEditorDraft.shiftedDateTime($0, bySeconds: 3_600)
        }.count == 3)
        #expect(MetadataEditorDraft.shiftedDateTime("", bySeconds: 60) == nil)
    }

    @Test("时间偏移与夏令时无关：固定 UTC 墙上时间算术（跨 DST 切换日不跳变）")
    func shiftedDateTimeIsDSTInsensitive() {
        // 欧洲 2026-03-29 是夏令时切换日。若用设备本地日历做算术，01:30 + 1h 可能
        // 变成 03:30 或 01:30；这里按固定 UTC 墙上时间，必须是 02:30。
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2026-03-29T01:30:00", bySeconds: 3_600) == "2026-03-29T02:30:00")
        // 美国 2026-11-01 回拨日同理：01:30 + 1h = 02:30（不是 01:30 重复小时）。
        #expect(MetadataEditorDraft.shiftedDateTime(
            "2026-11-01T01:30:00", bySeconds: 3_600) == "2026-11-01T02:30:00")
    }
}

// MARK: - Wave5（batch9）：双源冲突可见性

/// 可编程的内嵌读侧替身（nil = 内嵌不可读）。
private struct DualSourceStubExif: ExifProvider {
    let segments: MetadataParseSegments?

    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        segments
    }
}

/// 不可变的 sidecar 读侧替身（读盘只走它，文件存在性由夹具真实创建/删除）。
private struct DualSourceFakeXMP: XMPProvider {
    let attributes: MetadataWriteAttributes

    func readKeywords(photoPath: String) async throws -> [String] {
        attributes.keywords ?? []
    }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        attributes
    }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { true }
    func removeFile(_ path: String) async throws {}
}

private struct DualSourceNoopMutations: MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending")
    }
}

@Suite("双源冲突：API 默认与警示映射（Wave5 batch9）")
struct MetadataDualSourceConflictUITests {
    @Test("未接线的 stub：dualSourceConflict 返回 nil（未知，UI 不显示）")
    func apiDefaultNil() async throws {
        let stub = B6bMetadataAPIStub()
        let conflict = try await stub.dualSourceConflict(photoId: "p1")
        #expect(conflict == nil)
    }

    @Test("警示映射：字段列表拼接；空列表不显示")
    func warningMapping() {
        #expect(MetadataEditorSheet.dualSourceFieldNames([], localize: { $0 }) == nil,
                "空 = 不显示警示")

        let names = MetadataEditorSheet.dualSourceFieldNames(
            ["dateTaken", "rating", "title"], localize: { $0 })
        #expect(names?.contains("评分") == true)
        #expect(names?.contains("标题") == true)
        #expect(names?.contains("拍摄时间") == true)
        #expect(names?.split(separator: "、").count == 3)
    }

    @Test("字段显示名：非描述字段用既有中文 key，未知 id 原样透出")
    func fieldLabels() {
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("rating") == "评分")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("label") == "色标")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("keywords") == "关键词")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("dateTaken") == "拍摄时间")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("latitude") == "纬度")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("longitude") == "经度")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("caption") == "说明")
        #expect(MetadataEditorSheet.dualSourceFieldLabelKey("weird") == "weird")
    }

    // MARK: Live 接线（fake 内嵌/sidecar）

    private struct LiveFixture {
        let dir: URL
        let photoId: String
        let api: LiveMetadataAPI

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeLiveFixture(
        embedded: MetadataParseSegments?,
        sidecar: MetadataWriteAttributes,
        withSidecar: Bool = true
    ) throws -> LiveFixture {
        let db = try makeTestDB()
        let session = try SessionRepo(connection: db).create(name: "dual", source: "test")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-dual-live-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photoURL = dir.appendingPathComponent("IMG_DUAL.jpg")
        try Data("jpeg-bytes".utf8).write(to: photoURL)
        if withSidecar {
            try Data("sidecar".utf8).write(
                to: URL(fileURLWithPath: TSPath.xmpSidecarPath(photoURL.path)))
        }
        let photoId = try PhotoRepo(connection: db).addPhotos(
            sessionId: session.id,
            filepaths: [PhotoAddInput(filepath: photoURL.path, width: 100, height: 80)],
            "test").ids[0]
        let xmp = DualSourceFakeXMP(attributes: sidecar)
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: DualSourceNoopMutations(),
            exif: DualSourceStubExif(segments: embedded))
        let api = LiveMetadataAPI(
            metadataService: service,
            deliveryRepo: DeliveryRepo(connection: db),
            xmp: xmp,
            fileLock: XMPFileLock(),
            settingsService: SettingsService(repo: SettingsRepo(connection: db)))
        return LiveFixture(dir: dir, photoId: photoId, api: api)
    }

    @Test("Live 接线：内嵌与 sidecar 冲突 → DTO（排序 + canonical=sidecar）；无 sidecar → nil")
    func liveWiring() async throws {
        let embedded = MetadataParseSegments(
            ifd0: .object(["Rating": .number(5)]),
            dc: .object(["title": .string("内嵌标题")]))
        let fixture = try makeLiveFixture(
            embedded: embedded,
            sidecar: MetadataWriteAttributes(
                rating: 3, descriptive: DescriptiveMetadata(title: "sidecar 标题")))
        defer { fixture.cleanup() }
        let conflict = try await fixture.api.dualSourceConflict(photoId: fixture.photoId)
        #expect(conflict?.photoId == fixture.photoId)
        #expect(conflict?.fields == ["rating", "title"])
        #expect(conflict?.canonical == .sidecar)

        // 没有 sidecar = 单源：即便内嵌与"空 sidecar"不同也不报。
        let single = try makeLiveFixture(
            embedded: embedded, sidecar: MetadataWriteAttributes(), withSidecar: false)
        defer { single.cleanup() }
        let none = try await single.api.dualSourceConflict(photoId: single.photoId)
        #expect(none == nil)
    }
}
