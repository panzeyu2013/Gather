// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Export/ExportAssemblerTests.swift
// W2d-4 步骤②a：ExportAssembler 纯函数单测（无数据库、无文件 IO，唯一例外是
// canonicalPath/assertDestinationPath 的符号链接解析，用临时目录夹具）。
//
// 语义对照旧端到端用例 Services/ExportServiceTests.swift 的纯逻辑触点：
// - copiesOriginalSidecarAndResumesFromCheckpoint：{original}/{filename} 命名、
//   validate destination、assertDestinationPath、uniqueName 冲突消解；
// - rejectsExportIntoSourceDirectory：isPathInside/canonicalPath；
// - timePlaceholderUsesFixed24HourFormat：{time} 固定 HH-mm-ss（24h 制）；
// 另按任务覆盖 scopedPhotos/selectVariants、报告聚合（csvField/mdField/
// sessionSummary/emptyReport，补充 personReport/keywords/keywordReport）与
// validate 全部可达错误分支（错误码逐字对应 ExportError.description）。
//
// 不可达分支说明（报告存疑项）：validate 对 format/variantPolicy 的校验是
// ExportFormat.allCases.contains(_:)，对任何可由类型系统构造的枚举值恒为真，
// 因此 formatInvalid/variantPolicyInvalid 无法从测试触发，只能用例证明枚举全
// 集可通过（validateAcceptsEachFormatAndVariantPolicy）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 最小夹具（不触碰数据库）

private func makeOptions(
    destination: String = "/tmp/gather-export-assembler",
    format: ExportFormat = .jpeg,
    variantPolicy: ExportVariantPolicy? = nil,
    quality: Double? = 90,
    maxDimension: Int? = nil,
    watermark: ExportWatermark? = nil,
    pattern: String = "{original}",
    counterStart: Int? = nil,
    dateFormat: String? = nil
) -> ExportOptions {
    ExportOptions(
        scope: .session,
        variantPolicy: variantPolicy,
        format: format,
        quality: quality,
        maxDimension: maxDimension,
        watermark: watermark,
        naming: ExportNaming(pattern: pattern, counterStart: counterStart, dateFormat: dateFormat),
        includeXmp: false,
        destination: destination
    )
}

private func makeWatermark(
    type: ExportWatermarkType = .text,
    content: String = "Gather",
    opacity: Double = 0.5,
    fontSize: Double? = nil
) -> ExportWatermark {
    ExportWatermark(type: type, content: content, position: .bottomRight, opacity: opacity, fontSize: fontSize)
}

private func makeDate(year: Int = 2026, month: Int = 3, day: Int = 17, hour: Int = 5, minute: Int = 7, second: Int = 9) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return Calendar.current.date(from: components)!
}

private func makePhoto(
    _ id: String,
    filename: String? = nil,
    assetId: String? = nil,
    status: String = "ready"
) -> PhotoProjection {
    let name = filename ?? "\(id).jpg"
    return PhotoProjection(
        id: id, sessionId: "session", filepath: "/shoot/\(name)",
        filename: name,
        checksum: "checksum-\(id)", checksumFileSize: 0, checksumFileMtimeMs: 0,
        status: status, assetId: assetId, assetFileId: nil,
        width: 100, height: 100,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeRow(_ pairs: [(String, String)]) -> SQLiteRow {
    var values: [String: SQLiteValue] = [:]
    var order: [String] = []
    for (key, value) in pairs {
        values[key] = .text(value)
        order.append(key)
    }
    return SQLiteRow(values: values, columnOrder: order)
}

/// RFC 4180 逻辑记录计数：只按引号外的换行切分记录（引号内的换行属于同一
/// 记录），成对的 "" 为引号转义。用于断言行数时不被字段内换行虚增。
private func csvLogicalRecordCount(_ content: String) -> Int {
    var records = 0
    var inQuotes = false
    var hasPendingCharacters = false
    for character in content {
        if character == "\"" {
            // 成对的 "" 连续两次翻转，中间无字符，与转义语义等价。
            inQuotes.toggle()
            hasPendingCharacters = true
        } else if character == "\n", !inQuotes {
            records += 1
            hasPendingCharacters = false
        } else {
            hasPendingCharacters = true
        }
    }
    if hasPendingCharacters { records += 1 }
    return records
}

private func validationError(_ options: ExportOptions) -> ExportError? {
    do {
        try ExportAssembler.validate(options)
        return nil
    } catch let error as ExportError {
        return error
    } catch {
        return nil
    }
}

private func scopedError(_ photos: [PhotoProjection], scope: ExportScope) -> ExportError? {
    do {
        _ = try ExportAssembler.scopedPhotos(photos, scope: scope)
        return nil
    } catch let error as ExportError {
        return error
    } catch {
        return nil
    }
}

@Suite("ExportAssembler")
struct ExportAssemblerTests {

    // MARK: - 1) resolveName 模板

    @Test func resolveNameFilenameAndOriginalAliasesShareSanitizedStem() {
        #expect(ExportAssembler.resolveName(
            filename: "/shoot/family.raw",
            options: makeOptions(format: .original, pattern: "{filename}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "family.raw")
        #expect(ExportAssembler.resolveName(
            filename: "/shoot/family.raw",
            options: makeOptions(format: .original, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "family.raw")
        // {filename} 是 {original} 的兼容别名，且基名先经 sanitize 改写。
        #expect(ExportAssembler.resolveName(
            filename: "/shoot/my:photo?.jpeg",
            options: makeOptions(format: .original, pattern: "{filename}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "my_photo_.jpeg")
        #expect(ExportAssembler.resolveName(
            filename: "/shoot/my:photo?.jpeg",
            options: makeOptions(format: .original, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "my_photo_.jpeg")
    }

    @Test func resolveNameDateUsesInjectedDateAndDateFormat() {
        // 显式注入 2026-03-17；默认 dateFormat 为 YYYY-MM-DD。
        #expect(ExportAssembler.resolveName(
            filename: "photo.nef",
            options: makeOptions(format: .jpeg, pattern: "{date}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "2026-03-17.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.nef",
            options: makeOptions(format: .jpeg, pattern: "{date}", dateFormat: "YYYY.MM.DD"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "2026.03.17.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.nef",
            options: makeOptions(format: .jpeg, pattern: "{date}", dateFormat: "YYYY"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "2026.jpg")
        // 月/日零填充。
        #expect(ExportAssembler.resolveName(
            filename: "photo.nef",
            options: makeOptions(format: .jpeg, pattern: "{date}"),
            counter: 1, sessionName: "s", date: makeDate(month: 1, day: 5)
        ) == "2026-01-05.jpg")
    }

    @Test func resolveNameTimePlaceholderIsFixed24Hour() {
        let name = ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{time}"),
            counter: 1, sessionName: "s", date: makeDate(hour: 15, minute: 45, second: 30)
        )
        #expect(name == "15-45-30.jpg")
        #expect(name.range(of: #"^[0-2]\d-[0-5]\d-[0-5]\d\.jpg$"#, options: .regularExpression) != nil)
        #expect(!name.contains("AM") && !name.contains("PM") && !name.contains(" "))
        let morning = ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{time}"),
            counter: 1, sessionName: "s", date: makeDate(hour: 5, minute: 7, second: 9)
        )
        #expect(morning == "05-07-09.jpg")
        #expect(morning.range(of: #"^[0-2]\d-[0-5]\d-[0-5]\d"#, options: .regularExpression) != nil)
    }

    @Test func resolveNameCounterUsesZeroPaddedValueAndCounterStart() {
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{counter}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "0001.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{counter}"),
            counter: 0, sessionName: "s", date: makeDate()
        ) == "0000.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{counter}"),
            counter: 1234, sessionName: "s", date: makeDate()
        ) == "1234.jpg")
        // 服务侧口径：counter = (naming.counterStart ?? 1) + index。
        let options = makeOptions(format: .jpeg, pattern: "{counter}", counterStart: 100)
        let start = options.naming.counterStart ?? 1
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg", options: options,
            counter: start + 0, sessionName: "s", date: makeDate()
        ) == "0100.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg", options: options,
            counter: start + 2, sessionName: "s", date: makeDate()
        ) == "0102.jpg")
    }

    @Test func resolveNameSessionPlaceholderSanitizesSessionName() {
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{session}"),
            counter: 1, sessionName: "Summer Trip", date: makeDate()
        ) == "Summer Trip.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpg",
            options: makeOptions(format: .jpeg, pattern: "{session}_{counter}"),
            counter: 3, sessionName: "Family: 2026/Trip", date: makeDate()
        ) == "Family_ 2026_Trip_0003.jpg")
    }

    @Test func resolveNameExtensionMappingAndEmptyExtensionFallback() {
        // jpeg -> jpg
        #expect(ExportAssembler.resolveName(
            filename: "photo.jpeg", options: makeOptions(format: .jpeg, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "photo.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo.jfif", options: makeOptions(format: .jpeg, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "photo.jpg")
        // tiff 输出固定 tiff 扩展名
        #expect(ExportAssembler.resolveName(
            filename: "photo.nef", options: makeOptions(format: .tiff, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "photo.tiff")
        // original 保留原扩展名大小写
        #expect(ExportAssembler.resolveName(
            filename: "photo.NEF", options: makeOptions(format: .original, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "photo.NEF")
        // 空扩展名回退 jpg（original 与 jpeg 皆然）
        #expect(ExportAssembler.resolveName(
            filename: "photo", options: makeOptions(format: .original, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "photo.jpg")
        #expect(ExportAssembler.resolveName(
            filename: "photo", options: makeOptions(format: .jpeg, pattern: "{original}"),
            counter: 1, sessionName: "s", date: makeDate()
        ) == "photo.jpg")
    }

    // MARK: - 2) uniqueName

    @Test func uniqueNameAppendsNumericSuffixFromTwo() {
        var used = Set<String>()
        var queries: [String] = []
        let name = ExportAssembler.uniqueName("a.jpg", usedNames: &used) { candidate in
            queries.append(candidate)
            return candidate == "a.jpg" || candidate == "a_2.jpg"
        }
        #expect(name == "a_3.jpg")
        #expect(queries == ["a.jpg", "a_2.jpg", "a_3.jpg"])
        #expect(used == ["a_3.jpg"])
    }

    @Test func uniqueNamePreservesExtensionAndStemOnConflict() {
        var used = Set<String>()
        let noExt = ExportAssembler.uniqueName("notes", usedNames: &used) { $0 == "notes" }
        #expect(noExt == "notes_2")
        let dotted = ExportAssembler.uniqueName("My.Photo.JPG", usedNames: &used) { $0 == "My.Photo.JPG" }
        #expect(dotted == "My.Photo_2.JPG")
        // 已是 _2 的输入再冲突时按整段 stem 继续追加（a_2 -> a_2_2）。
        var usedAgain = Set(["a_2.jpg"])
        let resuffixed = ExportAssembler.uniqueName("a_2.jpg", usedNames: &usedAgain) { $0 == "a_2.jpg" }
        #expect(resuffixed == "a_2_2.jpg")
    }

    @Test func uniqueNameSkipsNameExistsOnUsedNamesHit() {
        var used = Set(["photo.jpg"])
        var queries: [String] = []
        let name = ExportAssembler.uniqueName("photo.jpg", usedNames: &used) { candidate in
            queries.append(candidate)
            return false
        }
        #expect(name == "photo_2.jpg")
        // usedNames 命中候选（photo.jpg）不查询闭包；终止候选（photo_2.jpg）
        // 必须查询一次以确认磁盘上不存在，故总调用数为 1，对命中项为 0。
        #expect(queries == ["photo_2.jpg"])
        #expect(queries.filter { $0.lowercased() == "photo.jpg" }.isEmpty)
        #expect(used.contains("photo_2.jpg"))
    }

    @Test func uniqueNameUsedNamesAreCaseInsensitive() {
        var used = Set<String>()
        let first = ExportAssembler.uniqueName("Photo.JPG", usedNames: &used) { _ in false }
        #expect(first == "Photo.JPG")
        #expect(used == ["photo.jpg"])
        // 与已占用名仅大小写不同即冲突，且新名以小写写入 usedNames。
        let second = ExportAssembler.uniqueName("PHOTO.jpg", usedNames: &used) { _ in false }
        #expect(second == "PHOTO_2.jpg")
        #expect(used == ["photo.jpg", "photo_2.jpg"])
        // 后续同名文件继续让位。
        let third = ExportAssembler.uniqueName("photo_2.jpg", usedNames: &used) { _ in false }
        #expect(third == "photo_2_2.jpg")
    }

    // MARK: - 3) 路径工具

    @Test func isPathInsideDistinguishesEqualityParentAndPrefix() {
        #expect(ExportAssembler.isPathInside("/a/b/c", "/a/b"))
        #expect(ExportAssembler.isPathInside("/a/b/c/d", "/a/b"))
        #expect(ExportAssembler.isPathInside("/a/b/c", "/a/b/"))
        #expect(!ExportAssembler.isPathInside("/a/b", "/a/b"))       // 相等不算 inside
        #expect(!ExportAssembler.isPathInside("/a", "/a/b"))         // 父路径
        #expect(!ExportAssembler.isPathInside("/a/bc", "/a/b"))      // 前缀相似但不包含
        #expect(!ExportAssembler.isPathInside("/a/b", "/a/bc"))
        #expect(ExportAssembler.isPathInside("/anything", "/"))      // 根目录包含一切
        #expect(!ExportAssembler.isPathInside("/", "/"))             // 根不包含自身
    }

    @Test func canonicalPathResolvesSymlinksAndStandardizes() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gather-canon-\(UUID().uuidString)", isDirectory: true)
        let real = tmp.appendingPathComponent("real", isDirectory: true)
        let link = tmp.appendingPathComponent("link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ExportAssembler.canonicalPath(link.path) == ExportAssembler.canonicalPath(real.path))
        // 符号链接解析后 isPathInside 可比较（导出目的地越界防护的纯逻辑面）。
        #expect(ExportAssembler.isPathInside(
            ExportAssembler.canonicalPath(link.path), ExportAssembler.canonicalPath(tmp.path)
        ))
        #expect(!ExportAssembler.isPathInside(
            ExportAssembler.canonicalPath(real.path), ExportAssembler.canonicalPath(real.path)
        ))
    }

    @Test func sanitizeRewritesIllegalCharactersAndNeutralizesTraversal() {
        #expect(ExportAssembler.sanitize("plain name.jpg") == "plain name.jpg")
        #expect(ExportAssembler.sanitize("a<b>c:d\"e/f\\g|h?i*j") == "a_b_c_d_e_f_g_h_i_j")
        #expect(ExportAssembler.sanitize("/path/to/file") == "_path_to_file")
        #expect(ExportAssembler.sanitize("dir/../evil") == "dir_.._evil")
        // NUL 不在 [<>:"/\\|?*] 改写集合内，Foundation 将其百分号编码为 %00。
        #expect(ExportAssembler.sanitize("a\u{0}b") == "a%00b")
    }

    @Test func assertDestinationPathAcceptsInsideAndRejectsOutside() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gather-dest-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("root", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        let sibling = tmp.appendingPathComponent("sibling", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // 相等与子路径通过。
        try ExportAssembler.assertDestinationPath(root, inside: root)
        try ExportAssembler.assertDestinationPath(sub, inside: root)
        // 兄弟目录/父目录拒绝，错误码逐字。
        #expect(throws: ExportError.exportPathInvalid) {
            try ExportAssembler.assertDestinationPath(sibling, inside: root)
        }
        #expect(throws: ExportError.exportPathInvalid) {
            try ExportAssembler.assertDestinationPath(tmp, inside: root)
        }
        #expect(ExportError.exportPathInvalid.description == "EXPORT_PATH_INVALID")
        // 符号链接指向 root 之外时按真实路径判定拒绝。
        let escape = root.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: sibling)
        #expect(throws: ExportError.exportPathInvalid) {
            try ExportAssembler.assertDestinationPath(escape, inside: root)
        }
    }

    // MARK: - 4) selectVariants / scopedPhotos

    @Test func selectVariantsAllReturnsInputUnchanged() {
        let photos = [
            makePhoto("a", filename: "a.dng", assetId: "A"),
            makePhoto("b", filename: "a.jpg", assetId: "A"),
            makePhoto("c", filename: "c.tif"),
        ]
        let selected = ExportAssembler.selectVariants(photos, policy: .all)
        #expect(selected == photos)
        #expect(selected.map(\.id) == ["a", "b", "c"])
    }

    @Test func selectVariantsGroupsByAssetIdOrId() {
        let aRaw = makePhoto("a-raw", filename: "a.dng", assetId: "A")
        let aJpeg = makePhoto("a-jpeg", filename: "a.jpg", assetId: "A")
        let bJpeg = makePhoto("b-jpeg", filename: "b.jpeg", assetId: "B")
        let c1 = makePhoto("c-1", filename: "c1.tif")
        let c2 = makePhoto("c-2", filename: "c2.tif")
        let photos = [aRaw, aJpeg, bJpeg, c1, c2]
        // group A 取 RAW；group B 无 RAW 被 raw 策略丢弃。
        #expect(ExportAssembler.selectVariants(photos, policy: .raw).map(\.id) == ["a-raw"])
        // group A 取 JPEG；group B 取 JPEG。
        #expect(Set(ExportAssembler.selectVariants(photos, policy: .jpeg).map(\.id)) == ["a-jpeg", "b-jpeg"])
        // preferred：有 RAW 取 RAW，无 RAW 取 JPEG，都无取组内首个；assetId 为 nil 者按 id 各自成组。
        #expect(Set(ExportAssembler.selectVariants(photos, policy: .preferred).map(\.id)) == ["a-raw", "b-jpeg", "c-1", "c-2"])
    }

    @Test func selectVariantsPreservesWithinGroupOrder() {
        let x1 = makePhoto("x1", filename: "x1.tif", assetId: "X")
        let x2 = makePhoto("x2", filename: "x2.tif", assetId: "X")
        let x3 = makePhoto("x3", filename: "x3.tif", assetId: "X")
        #expect(ExportAssembler.selectVariants([x1, x2, x3], policy: .preferred).map(\.id) == ["x1"])
        let y1 = makePhoto("y1", filename: "y1.jpg", assetId: "Y")
        let y2 = makePhoto("y2", filename: "y2.jpeg", assetId: "Y")
        #expect(ExportAssembler.selectVariants([y1, y2], policy: .jpeg).map(\.id) == ["y1"])
        let z1 = makePhoto("z1", filename: "z1.raw", assetId: "Z")
        let z2 = makePhoto("z2", filename: "z2.cr3", assetId: "Z")
        #expect(ExportAssembler.selectVariants([z1, z2], policy: .raw).map(\.id) == ["z1"])
        // 混合组：preferred 无论顺序都优先 RAW。
        let mJpeg = makePhoto("m-jpeg", filename: "m.jpg", assetId: "M")
        let mRaw = makePhoto("m-raw", filename: "m.nef", assetId: "M")
        #expect(ExportAssembler.selectVariants([mJpeg, mRaw], policy: .preferred).map(\.id) == ["m-raw"])
    }

    @Test func selectVariantsMatchesExtensionsCaseInsensitivelyAndFoldsEmptyAssetId() {
        #expect(ExportAssembler.selectVariants([makePhoto("up", filename: "UP.RAW")], policy: .raw).map(\.id) == ["up"])
        #expect(ExportAssembler.selectVariants([makePhoto("up", filename: "UP.JpEg")], policy: .jpeg).map(\.id) == ["up"])
        // 无扩展名：raw/jpeg 均不匹配，preferred 回退组内首个。
        let noExt = makePhoto("noext", filename: "noext")
        #expect(ExportAssembler.selectVariants([noExt], policy: .raw).isEmpty)
        #expect(ExportAssembler.selectVariants([noExt], policy: .jpeg).isEmpty)
        #expect(ExportAssembler.selectVariants([noExt], policy: .preferred).map(\.id) == ["noext"])
        // E1（保持现状）：asset_id = '' 也并组，raw/jpeg 各取组内首个匹配。
        let emptyRaw = makePhoto("empty-raw", filename: "e.raw", assetId: "")
        let emptyJpeg = makePhoto("empty-jpeg", filename: "e.jpg", assetId: "")
        #expect(ExportAssembler.selectVariants([emptyRaw, emptyJpeg], policy: .raw).map(\.id) == ["empty-raw"])
        #expect(ExportAssembler.selectVariants([emptyRaw, emptyJpeg], policy: .jpeg).map(\.id) == ["empty-jpeg"])
    }

    @Test func scopedPhotosDropsRemovedAndRejectsNonSessionScope() {
        let photos = [
            makePhoto("keep-1"),
            makePhoto("gone", status: "removed"),
            makePhoto("keep-2"),
        ]
        #expect(try! ExportAssembler.scopedPhotos(photos, scope: .session).map(\.id) == ["keep-1", "keep-2"])
        #expect(scopedError(photos, scope: .selected) == .scopeUnsupported)
        #expect(scopedError(photos, scope: .filtered) == .scopeUnsupported)
        #expect(ExportError.scopeUnsupported.description == "EXPORT_SCOPE_UNSUPPORTED")
    }

    // MARK: - 5) 报告聚合

    @Test func csvFieldQuotesCommasQuotesAndNewlines() {
        #expect(ExportAssembler.csvField("plain") == "plain")
        #expect(ExportAssembler.csvField("") == "")
        #expect(ExportAssembler.csvField("a,b") == "\"a,b\"")
        #expect(ExportAssembler.csvField("a\"b") == "\"a\"\"b\"")
        #expect(ExportAssembler.csvField("a\nb") == "\"a\nb\"")
        #expect(ExportAssembler.csvField("a,b\"c\nd") == "\"a,b\"\"c\nd\"")
    }

    @Test func csvFieldQuotesWholeFieldAndDoublesEveryInnerQuote() {
        // 字段由一对包裹引号定界，内部引号逐个双写；字段内换行保留在引号内。
        #expect(ExportAssembler.csvField("a,\"b\"") == "\"a,\"\"b\"\"\"")
        #expect(ExportAssembler.csvField("/shoot\nx") == "\"/shoot\nx\"")
        #expect(ExportAssembler.csvField("a,\"b\",\"/shoot\nx\"") == "\"a,\"\"b\"\",\"\"/shoot\nx\"\"\"")
    }

    @Test func mdFieldEscapesPipesAndFlattensNewlines() {
        #expect(ExportAssembler.mdField("plain") == "plain")
        #expect(ExportAssembler.mdField("a|b") == "a\\|b")
        #expect(ExportAssembler.mdField("a\nb") == "a b")
        #expect(ExportAssembler.mdField("a|b\nc") == "a\\|b c")
    }

    @Test func sessionSummaryCsvHeaderRowCountAndEscaping() {
        let rows = [
            makeRow([("filename", "a.jpg"), ("filepath", "/shoot/a.jpg"), ("status", "ready")]),
            makeRow([("filename", "a,\"b\""), ("filepath", "/shoot\nx"), ("status", "removed")]),
            SQLiteRow(values: ["filename": .text("only.jpg")], columnOrder: ["filename", "filepath", "status"]),
        ]
        let report = ExportAssembler.sessionSummary(rows: rows, format: .csv)
        #expect(report.path == "")
        #expect(report.format == .csv)
        #expect(report.content.hasPrefix("filename,filepath,status\n"))
        // 表头 + 3 条逻辑记录；第 2 条的 filepath 含字段内换行且被引号包裹，
        // 按物理行切分会虚增，故按 CSV 逻辑记录计数。
        #expect(csvLogicalRecordCount(report.content) == 4)
        #expect(!report.content.hasSuffix("\n"))
        #expect(report.content.contains("a.jpg,/shoot/a.jpg,ready"))
        // 字段整体被引号包裹：内部每个引号双写后，仍需补上收尾的包裹引号。
        #expect(report.content.contains("\"a,\"\"b\"\"\",\"/shoot\nx\",removed"))
        #expect(report.content.contains("only.jpg,,"))
        // 空输入只留表头。
        let empty = ExportAssembler.sessionSummary(rows: [], format: .csv)
        #expect(empty.content == "filename,filepath,status\n")
    }

    @Test func sessionSummaryMdHeaderAndRowCount() {
        let rows = [
            makeRow([("filename", "a.jpg"), ("filepath", "/shoot/a.jpg"), ("status", "ready")]),
            makeRow([("filename", "a|b\nc"), ("filepath", "/shoot/b.jpg"), ("status", "removed")]),
        ]
        let report = ExportAssembler.sessionSummary(rows: rows, format: .md)
        #expect(report.path == "")
        #expect(report.format == .md)
        let header = "# Session summary\n\nTotal photos: 2\n\n| # | Filename | Path | Status |\n|---:|---|---|---|\n"
        #expect(report.content.hasPrefix(header))
        #expect(report.content.contains("| 1 | a.jpg | /shoot/a.jpg | ready |\n"))
        #expect(report.content.contains("| 2 | a\\|b c | /shoot/b.jpg | removed |\n"))
        #expect(report.content.hasSuffix("|\n"))
        // 文档共 8 行（含两处空行）；mdField 已把字段内换行压成空格，
        // 但 split 默认丢弃空子序列会少 2，故保留空行切分并去掉末尾换行产生的空段。
        let documentLines = report.content.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(documentLines.count == 8)
        let empty = ExportAssembler.sessionSummary(rows: [], format: .md)
        #expect(empty.content == "# Session summary\n\nTotal photos: 0\n\n| # | Filename | Path | Status |\n|---:|---|---|---|\n")
    }

    @Test func emptyReportKeepsRequestedFormatWithEmptyContent() {
        #expect(ExportAssembler.emptyReport(format: .csv) == ReportData(path: "", content: "", format: .csv))
        #expect(ExportAssembler.emptyReport(format: .md) == ReportData(path: "", content: "", format: .md))
    }

    @Test func personReportAggregatesKeywordJson() {
        let rows = [
            // person 报告按 columnOrder[3] 取 member_count；缺失值等价 NULL，聚合回退 0。
            SQLiteRow(
                values: ["role_name": .text("Alice"), "keywords": .text("[\"mother\",\"chef\"]"), "cluster_label": .text("Family")],
                columnOrder: ["role_name", "keywords", "cluster_label", "member_count"]
            ),
            SQLiteRow(
                values: ["role_name": .text("Bob"), "keywords": .text("not-json"), "cluster_label": .text("Friends"), "member_count": .int(3)],
                columnOrder: ["role_name", "keywords", "cluster_label", "member_count"]
            ),
        ]
        let report = ExportAssembler.personReport(rows: rows)
        #expect(report.path == "")
        #expect(report.format == .md)
        #expect(report.content.hasPrefix("# Person report\n\nBindings: 2\n\n| Role | Keywords | Cluster | Members |\n|---|---|---|---:|\n"))
        #expect(report.content.contains("| Alice | mother, chef | Family | 0 |"))
        #expect(report.content.contains("| Bob |  | Friends | 3 |"))
    }

    @Test func keywordsUnionAndKeywordReportLines() {
        let bindingRows = [
            makeRow([("keywords", "[\"alpha\",\"beta\"]")]),
            makeRow([("keywords", "[\"beta\",\"gamma\"]")]),
            makeRow([("keywords", "not-json")]),
        ]
        let cullingRows = [
            makeRow([("decision", "keep")]),
            makeRow([("decision", "reject")]),
            makeRow([("decision", "pending")]),
        ]
        let set = ExportAssembler.keywords(bindingRows: bindingRows, cullingRows: cullingRows)
        #expect(set == Set(["alpha", "beta", "gamma", "culling:keep", "culling:reject"]))
        let report = ExportAssembler.keywordReport(keywords: set)
        #expect(report.content == "# Keyword report\n\n- alpha\n- beta\n- culling:keep\n- culling:reject\n- gamma\n")
        #expect(report.format == .md)
        #expect(ExportAssembler.keywordReport(keywords: []).content == "# Keyword report\n\n")
    }

    // MARK: - 6) validate（错误码/文案逐字）

    @Test func validateRejectsDestinationVariantsVerbatim() {
        #expect(validationError(makeOptions(destination: "")) == .destinationInvalid)
        #expect(ExportError.destinationInvalid.description == "EXPORT_DIR_INVALID")
        #expect(validationError(makeOptions(destination: "relative/path")) == .destinationAbsoluteRequired)
        #expect(ExportError.destinationAbsoluteRequired.description == "EXPORT_DIR_ABSOLUTE_REQUIRED")
        #expect(validationError(makeOptions(destination: "/")) == .destinationRootForbidden)
        #expect(ExportError.destinationRootForbidden.description == "EXPORT_DIR_ROOT_FORBIDDEN")
        #expect(validationError(makeOptions()) == nil)
    }

    @Test func validateRejectsOriginalTransform() {
        let original = makeOptions(format: .original, maxDimension: 100)
        #expect(validationError(original) == .originalTransformNotAllowed)
        #expect(ExportError.originalTransformNotAllowed.description == "EXPORT_ORIGINAL_NO_TRANSFORM")
        #expect(validationError(makeOptions(format: .original, watermark: makeWatermark())) == .originalTransformNotAllowed)
        #expect(validationError(makeOptions(format: .original)) == nil)
        // 非 original 格式允许变换。
        #expect(validationError(makeOptions(format: .jpeg, maxDimension: 100)) == nil)
        #expect(validationError(makeOptions(format: .tiff, watermark: makeWatermark())) == nil)
    }

    @Test func validateRejectsNamingEmptyAndInvalidCharacters() {
        #expect(validationError(makeOptions(pattern: "")) == .namingEmpty)
        #expect(ExportError.namingEmpty.description == "EXPORT_NAMING_EMPTY")
        #expect(validationError(makeOptions(pattern: "   \n")) == .namingEmpty)
        #expect(validationError(makeOptions(pattern: "a/b")) == .namingInvalidCharacters)
        #expect(ExportError.namingInvalidCharacters.description == "EXPORT_NAMING_INVALID_CHARS")
        #expect(validationError(makeOptions(pattern: "a\\b")) == .namingInvalidCharacters)
        #expect(validationError(makeOptions(pattern: "a\u{0}b")) == .namingInvalidCharacters)
        #expect(validationError(makeOptions(pattern: "{original}")) == nil)
    }

    @Test func validateRejectsQualityMaxDimensionAndCounterStart() {
        #expect(validationError(makeOptions(quality: 0.5)) == .qualityInvalid)
        #expect(ExportError.qualityInvalid.description == "EXPORT_JPEG_QUALITY_INVALID")
        #expect(validationError(makeOptions(quality: 0)) == .qualityInvalid)
        #expect(validationError(makeOptions(quality: 101)) == .qualityInvalid)
        #expect(validationError(makeOptions(quality: 1)) == nil)
        #expect(validationError(makeOptions(quality: 100)) == nil)
        #expect(validationError(makeOptions(maxDimension: 0)) == .maxDimensionInvalid)
        #expect(ExportError.maxDimensionInvalid.description == "EXPORT_MAX_DIMENSION_INVALID")
        #expect(validationError(makeOptions(maxDimension: 1)) == nil)
        #expect(validationError(makeOptions(counterStart: -1)) == .startIndexInvalid)
        #expect(ExportError.startIndexInvalid.description == "EXPORT_START_INDEX_INVALID")
        #expect(validationError(makeOptions(counterStart: 0)) == nil)
    }

    @Test func validateRejectsWatermarkVariantsVerbatim() {
        #expect(validationError(makeOptions(watermark: makeWatermark(type: .image))) == .watermarkTypeUnsupported)
        #expect(ExportError.watermarkTypeUnsupported.description == "EXPORT_WATERMARK_TYPE_UNSUPPORTED")
        #expect(validationError(makeOptions(watermark: makeWatermark(content: "   "))) == .watermarkTextEmpty)
        #expect(ExportError.watermarkTextEmpty.description == "EXPORT_WATERMARK_TEXT_EMPTY")
        #expect(validationError(makeOptions(watermark: makeWatermark(opacity: -0.1))) == .watermarkOpacityInvalid)
        #expect(ExportError.watermarkOpacityInvalid.description == "EXPORT_WATERMARK_OPACITY_INVALID")
        #expect(validationError(makeOptions(watermark: makeWatermark(opacity: 1.5))) == .watermarkOpacityInvalid)
        #expect(validationError(makeOptions(watermark: makeWatermark(opacity: .nan))) == .watermarkOpacityInvalid)
        #expect(validationError(makeOptions(watermark: makeWatermark(fontSize: 0))) == .watermarkFontSizeInvalid)
        #expect(ExportError.watermarkFontSizeInvalid.description == "EXPORT_WATERMARK_FONT_SIZE_INVALID")
        #expect(validationError(makeOptions(watermark: makeWatermark(fontSize: 2000))) == .watermarkFontSizeInvalid)
        #expect(validationError(makeOptions(watermark: makeWatermark(content: "©", opacity: 0.5, fontSize: 24))) == nil)
    }

    @Test func validateAcceptsEachFormatAndVariantPolicy() {
        // formatInvalid/variantPolicyInvalid 分支不可达（allCases.contains 恒真），
        // 此用例证明全部可构造枚举值均通过。
        for format in ExportFormat.allCases {
            #expect(validationError(makeOptions(format: format)) == nil)
        }
        for policy in ExportVariantPolicy.allCases {
            #expect(validationError(makeOptions(variantPolicy: policy)) == nil)
        }
        #expect(validationError(makeOptions(variantPolicy: nil)) == nil)
    }
}
