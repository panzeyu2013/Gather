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
@testable import GatherUI

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
}
