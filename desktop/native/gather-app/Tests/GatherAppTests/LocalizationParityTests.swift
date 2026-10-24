// desktop/native/gather-app/Tests/GatherAppTests/LocalizationParityTests.swift
// Cut 4 / 4b-1：en 表质量与「代码在用 key ⊆ 表」parity（审计 §3.5 R6 / §7.2）。
//
// 四组断言：
// 1. en 表无重复键（.strings 后写覆盖先写，译文不可预期）；
// 2. 代码在用的每个 key 都在 en 表里（en 界面不回落中文）；
// 3. error / job / progress / 取消等本地化关键路径在 zh、en 下与码表/键表一致（B03 收口）；
// 4. 反方向 parity（Cut 6 / 6a-1）：en 表里不得残留无代码引用的孤儿键（仅 allowlist）。
//
// key 集合来自三处：源码字面量（按 l/l10n/LocalizedText/CommandError.localized 的
// 调用形态扫描）、动态码表（错误码模板 / 任务状态 / 任务类型 / 进度相位）、设置
// 目录的 zh 文案。扫描只读 Sources，不改产品；新增漏翻译的 key 会在这里直接红。
//
// 边界：本用例只读 en.lproj 与源码文本；zh 表留空（中文即 key），因此 parity
// 基线是「代码 key ⊆ en 键」而不是 zh/en 双向对齐。
import Foundation
import Testing
@testable import GatherUI

@MainActor
@Suite("本地化表 parity（4b-1）")
struct LocalizationParityTests {
    // MARK: - 路径

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/Tests/GatherAppTests/LocalizationParityTests.swift
            .deletingLastPathComponent()     // …/Tests/GatherAppTests
            .deletingLastPathComponent()     // …/Tests
            .deletingLastPathComponent()     // …/gather-app
    }

    private static var stringsURL: URL {
        packageRoot.appendingPathComponent("Sources/GatherUI/Resources/en.lproj/Localizable.strings")
    }

    private static var sourcesURL: URL {
        packageRoot.appendingPathComponent("Sources")
    }

    // MARK: - en 表

    /// 本仓 .strings 条目都是单行 `"key" = "value";`（允许转义引号）。
    private static let entryPattern = #"(?m)^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$"#

    private func parseEntries() throws -> [(key: String, value: String)] {
        let text = try String(contentsOf: Self.stringsURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: Self.entryPattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return nil }
            return (Self.unescape(String(text[keyRange])), Self.unescape(String(text[valueRange])))
        }
    }

    private func parseTable() throws -> [String: String] {
        var table: [String: String] = [:]
        for entry in try parseEntries() {
            // 重复键在 noDuplicateKeys 里单独报错；这里保持「后写覆盖」的运行时语义。
            table[entry.key] = entry.value
        }
        return table
    }

    // MARK: - 代码在用 key

    /// 调用形态：l("…") / l10n("…") / l10n.format("…") / l10n.plural("…") /
    /// LocalizedText("…") / LocalizedText.plural("…") / Notice 包装器 /
    /// CommandError.localized("…")。
    ///
    /// Cut 4 / 4b-2l：加入 `l10n.format`。带参模板（含本批 Support 的 5 个）绝大多数
    /// 只以这个形态出现；漏扫时新增 key 即使缺英文条目也不会在这里报红。
    /// R5-P1-3：加入 CullingNotice/FaceNotice/SimilarityNotice（3 类轻包装器，
    /// 共 53 个 CJK 字面量）与 plural 入口；否则整类 notice 缺英文不会报红。
    private static let callPattern = /(?m)(?:^|[^A-Za-z0-9_.])(?:GatherLocalization\.l|l10n\.format|l10n\.plural|LocalizedText\.plural|l10n|LocalizedText|CullingNotice|FaceNotice|SimilarityNotice|l|CommandError\.localized)\(/

    /// 纯 printf 数值格式（`l10n.format("%.2f", value)` / `"%lld"`）：机器值，
    /// 不是待译 key。本仓 key 约定为中文原文，`%.1f MB` 这类带字面量的模板
    /// 仍按 key 处理（有空格/文字，不匹配本模式）。
    private static let machineFormatPattern = #"^%[-+ #0-9.']*(?:hh|ll|[hlqjzt])?[a-zA-Z@%]$"#

    private func scannedLiteralKeys() -> (keys: Set<String>, files: Int) {
        var keys: Set<String> = []
        var files = 0
        let enumerator = FileManager.default.enumerator(
            at: Self.sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/.build/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files += 1
            for match in text.matches(of: Self.callPattern) {
                // `l10n.format` 的 key 必须是**第一个实参**：后续实参是运行时值
                // （三元分支的 "Burst"/"Scene"、数字、路径），把它们当 key 会制造
                // 永远缺翻译的假红。其余调用形态维持原行为（收集 depth==1 字面量）。
                // format/plural 只把**第一个实参**当 key；其余实参是运行时值。
                // 非 format 调用（含 Notice/LocalizedText）仍收集全部 depth==1 字面量。
                let isFormatCall = text[match.range].hasSuffix("format(")
                    || text[match.range].hasSuffix("plural(")
                var isFirstArgument = true
                var index = match.range.upperBound
                var depth = 1
                while index < text.endIndex, depth > 0 {
                    let character = text[index]
                    if character == "," && depth == 1 {
                        isFirstArgument = false
                    }
                    if character == "\"" {
                        var cursor = text.index(after: index)
                        var raw = ""
                        var interpolated = false
                        var terminated = false
                        while cursor < text.endIndex {
                            let current = text[cursor]
                            if current == "\\" {
                                let next = text.index(after: cursor)
                                guard next < text.endIndex else { break }
                                if text[next] == "(" { interpolated = true }
                                raw.append(current)
                                raw.append(text[next])
                                cursor = text.index(after: next)
                                continue
                            }
                            if current == "\"" {
                                terminated = true
                                break
                            }
                            raw.append(current)
                            cursor = text.index(after: cursor)
                        }
                        // 只收最外层实参里的字面量（嵌套调用/参数数组不算 key）；
                        // format 调用只收第一个实参。
                        if depth == 1, terminated, !interpolated, !raw.isEmpty,
                           !isFormatCall || isFirstArgument {
                            let literal = Self.unescape(raw)
                            if !Self.isMachineFormat(literal) {
                                keys.insert(literal)
                            }
                        }
                        // R5-P1-3：字符串结束不等于实参结束。三元表达式
                        // （cond ? "A" : "B"）的两个分支都要收集；只有 depth==1
                        // 的逗号才终止 format/plural 的第一个实参。
                        index = terminated ? text.index(after: cursor) : text.endIndex
                        continue
                    }
                    if character == "(" { depth += 1 }
                    else if character == ")" { depth -= 1 }
                    index = text.index(after: index)
                }
            }
        }
        return (keys, files)
    }

    /// 动态 key：码表模板、任务/进度码表、设置目录 zh 文案（这些 key 不经过字面量调用）。
    private func dynamicKeys() -> Set<String> {
        var keys = Set(GatherLocalization.jobStatusKeys.values)
        keys.formUnion(GatherLocalization.jobTypeKeys.values)
        keys.formUnion(GatherLocalization.progressPhaseKeys.values)
        keys.formUnion(GatherLocalization.errorMessages.values)
        // Delivery P2 的 11 个码不在 errorMessages（避免与 GatherErrorCode 契约冲突），
        // 但模板同样是动态 key，必须纳入 en 覆盖检查。
        keys.formUnion(DeliveryErrorPresentation.messageKeys)
        keys.formUnion(SettingsViewModel.FaceModelPathIssue.templateKeys)
        keys.insert(L10n.unknownErrorKey)
        keys.insert(L10n.unknownPhaseKey)

        for group in SettingsViewModel.settingGroups {
            keys.insert(group.titleZh)
            for field in group.fields {
                keys.insert(field.zhLabel)
                if !field.zhDesc.isEmpty { keys.insert(field.zhDesc) }
                if case .select(let options) = field.type {
                    for option in options { keys.insert(option.labelZh) }
                }
            }
        }
        for slider in SettingsViewModel.generalSliders + SettingsViewModel.advancedSliders {
            keys.insert(slider.zhLabel)
            if !slider.zhDesc.isEmpty { keys.insert(slider.zhDesc) }
        }
        return keys.filter { !$0.isEmpty }
    }

    /// 代码在用的全部 key：字面量 ∪ 动态表 − 错误码（错误码走码表，不是 .strings key）。
    private func usedKeys() -> Set<String> {
        let scanned = scannedLiteralKeys().keys
        let errorCodes = Set(GatherLocalization.errorMessages.keys)
        return (scanned.union(dynamicKeys())).subtracting(errorCodes)
    }

    /// 在用 key 中缺英文条目的那些。抽成独立函数是为了让「漏扫/缺译必须失败」
    /// 本身可测：用一张人工删掉某 key 的表调用它，必须返回该 key。
    private func missingEnglishKeys(in table: [String: String]) -> [String] {
        usedKeys().filter { table[$0] == nil }.sorted()
    }

    /// 一行里的字符串字面量（不含插值的整段，含转义）。
    private static let literalPattern = /"(?:[^"\\]|\\.)*"/

    /// Sources 里出现过的**整段**字符串字面量（跳过注释行与插值）。
    ///
    /// 孤儿判定必须看它、不能只看调用点：本仓大量 key 以裸字面量交给包装类型
    /// （`CullingNotice("已重试同步队列")`、`notice = "已刷新同步队列"`），只在
    /// `l(...)` 调用点收集会把它们误判成孤儿（6a-1 实测 77 个误报）。
    ///
    /// 偏差：行首注释整行跳过（注释不算引用），行尾注释不剥离（保守，只会漏报孤儿）；
    /// 运行时拼接出来的 key 扫不到 —— 真出现时本用例会红，属预期（必须显式登记）。
    private func sourceLiteralKeys() -> Set<String> {
        var keys: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: Self.sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/.build/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                // 注释行（含文档注释与块注释续行）不是引用。
                guard !line.hasPrefix("//"), !line.hasPrefix("/*"), !line.hasPrefix("*") else { continue }
                for match in line.matches(of: Self.literalPattern) {
                    let literal = Self.unescape(String(match.output.dropFirst().dropLast()))
                    // 插值字面量是运行时拼出来的，不是整键；空串不是 key。
                    guard !literal.isEmpty, !literal.contains("\\(") else { continue }
                    keys.insert(literal)
                }
            }
        }
        return keys
    }

    // MARK: - 孤儿键 allowlist（Cut 6 / 6a-2 收口）

    /// 只剩 1 个允许「en 表里有、Sources 里没有整段字面量」的 key。
    ///
    /// 判定口径是**整段字面量**，不是审计 §2 的「整键子串」：后者会把注释与长句里的
    /// 同名子串当成引用（`完成` ⊂ `已完成`、`多选` ⊂ `…多选…`、`最近同步` ⊂
    /// `最近同步时间`），短键几乎全被误判成「在用」——6a-1 按整段字面量复核，
    /// 存量孤儿是 **32** 个（审计写 1 个）；6a-2 删掉其中 31 个，只剩下面这一个。
    ///
    /// `检测模型路径`：**在用**，只是不在 Sources。由 `SettingsSaveSemanticsTests:284`
    /// 构造 `SettingField(zhLabel:)` 时传入（动态 key），该用例断言英文
    /// `“Detection Model Path” cannot be empty`；删掉条目这段断言会回落中文
    /// （审计 §2 #5 明确保留）。
    private static let testPinnedOrphans: Set<String> = ["检测模型路径"]

    // MARK: - 测试

    @Test("en 表无重复键（后写覆盖先写会让译文不可预期）")
    func noDuplicateKeys() throws {
        var counts: [String: Int] = [:]
        for entry in try parseEntries() { counts[entry.key, default: 0] += 1 }
        // 解析失效（匹配 0 条）时不能静默变绿。
        #expect(counts.values.reduce(0, +) > 1000, "en 表解析到的条目数异常，路径/格式假设可能失效")
        let duplicates = counts
            .filter { $0.value > 1 }
            .map { "\($0.key) ×\($0.value)" }
            .sorted()
        #expect(duplicates.isEmpty, "en 表存在重复键（运行时后者覆盖前者）：\(duplicates)")
    }

    @Test("en 表覆盖全部在用 key（缺项会让 en 界面回落中文）")
    func englishTableCoversEveryUsedKey() throws {
        let table = try parseTable()
        #expect(!table.isEmpty, "读不到 en.lproj/Localizable.strings（路径假设失效）")
        let scanned = scannedLiteralKeys()
        #expect(scanned.files > 60, "源码扫描文件数异常（\(scanned.files)），路径假设可能失效")
        let used = usedKeys()
        // 扫描/动态表失效（key 集合塌缩）时不能静默变绿。
        #expect(used.count > 1000, "在用 key 集合只有 \(used.count) 个，扫描或动态表可能失效")
        let missing = missingEnglishKeys(in: table)
        #expect(missing.isEmpty, "以下在用 key 缺英文条目：\(missing.prefix(20))")
    }

    @Test("孤儿键（en 表有、代码无）仅限 allowlist（6a-2）")
    func orphanKeysStayWithinAllowlist() throws {
        let table = try parseTable()
        let literals = sourceLiteralKeys()
        // 扫描塌缩时孤儿会虚假膨胀：先用与覆盖性断言同一条下界兜住。
        #expect(literals.count > 1000, "Sources 整段字面量只有 \(literals.count) 个，扫描或路径假设失效")
        let allowed = Self.testPinnedOrphans
        let used = usedKeys()
        // R5-P1-2：plural 的单数条目（base + "#one"）不在源码字面量里，只能由
        // base key 的引用证明；base 不在用法的 #one 仍是孤儿（下一行会报红）。
        let pluralOnes = Set(table.keys.filter {
            $0.hasSuffix(L10n.pluralOneSuffix)
                && used.contains(String($0.dropLast(L10n.pluralOneSuffix.count)))
        })
        // 6a-2 删掉 31 个遗留死键后的反方向 parity：表里不得再长出无人引用的条目。
        let orphans = Set(table.keys)
            .subtracting(used)
            .subtracting(literals)
            .subtracting(allowed)
            .subtracting(pluralOnes)
            .sorted()
        #expect(orphans.isEmpty, "以下 en 键已无代码引用（删除或写清理由加入 allowlist）：\(orphans)")
        // allowlist 自身必须仍在表里：防止它变成「已删键」的垃圾场。
        for key in allowed {
            #expect(table[key] != nil, "allowlist 键不在 en 表：\(key)")
        }
        // `检测模型路径` 只允许来自测试构造：一旦进了 Sources，就该从 allowlist 摘掉。
        #expect(!literals.contains("检测模型路径"), "`检测模型路径` 已在 Sources 引用，应从 allowlist 移除")
    }

    @Test("l10n.format 的 key 参与 parity；机器格式与非 key 实参不误扫（4b-2l）")
    func formatKeyCallsAreScanned() {
        let used = usedKeys()
        // 本批 Support 迁移后由 l10n.format 承载的 5 个 key（原 String(format: l(...))）。
        // 任一漏扫 → 缺英文条目不会被 englishTableCoversEveryUsedKey 发现。
        for key in [
            "写回队列：%d 项",
            "最近同步：%@",
            "失败项（%lld）",
            "%@：%@（范围 %@–%@）",
            "%@：%lld（范围 %lld–%lld）",
        ] {
            #expect(used.contains(key), "\(key) 必须被 parity 扫描（缺英文条目要在这里报红）")
        }
        // 4b-2l 之前只以 l10n.format 出现、且不含中文的 3 个 key 也必须覆盖。
        for key in ["RAW+JPEG · %lld", "%@ · %@", "%.1f MB"] {
            #expect(used.contains(key), "\(key) 必须被 parity 扫描")
        }
        // 非 key 字面量：机器数值格式、以及 format 第二实参里的三元分支文案。
        for literal in ["%.2f", "Burst", "Scene"] {
            #expect(!used.contains(literal), "\(literal) 不是界面文案 key，不应被扫描")
        }
    }

    @Test("Notice / 三元第二分支 / plural 进入 parity；en 缺条目会被判缺失（R5-P1-3）")
    func noticeTernaryAndPluralKeysAreScanned() throws {
        let used = usedKeys()
        // Notice 包装器：此前 callPattern 不含这 3 个类型，整类 key 漏扫。
        for key in [
            "已重试同步队列",
            "已刷新同步队列",
            "已生成导航组预览，未写入工作区",
            "导航组已分析并保存",
            "已撤销上一次挑片操作",
            "已重做挑片操作",
            "已写回 %lld 项；请先让 Capture One 重新加载元数据",
        ] {
            #expect(used.contains(key), "Notice key 漏扫：\(key)")
        }
        // 三元表达式两个分支都要在集合里（此前只收第一支）。
        for key in ["显示侧栏", "隐藏侧栏"] {
            #expect(used.contains(key), "三元分支漏扫：\(key)")
        }
        // plural 的 base 模板（单数条目由 pluralOneFormsExistInEnglish 校验）。
        for key in [
            "%lld 张照片",
            "写回队列：%d 项",
            "已完成任务（%lld）",
            "失败任务 %lld",
            "%lld 个人脸样本",
            "%@ · %lld 张照片",
            "%lld 个工作区",
        ] {
            #expect(used.contains(key), "plural 模板漏扫：\(key)")
        }
        // 反向证明：把 en 表里的 Notice 键删掉后，覆盖性判定必须报缺失。
        // 若扫描再次漏掉 Notice，这个断言会变绿（回归失败）。
        var table = try parseTable()
        table.removeValue(forKey: "已刷新同步队列")
        #expect(missingEnglishKeys(in: table).contains("已刷新同步队列"),
                "Notice key 缺英文时 parity 未报红（漏扫回归）")
    }

    @Test("plural：7 个高频模板都有 #one 单数条目（R5-P1-2）")
    func pluralOneFormsExistInEnglish() throws {
        let table = try parseTable()
        for key in [
            "%lld 张照片",
            "写回队列：%d 项",
            "已完成任务（%lld）",
            "失败任务 %lld",
            "%lld 个人脸样本",
            "%@ · %lld 张照片",
            "%lld 个工作区",
        ] {
            let one = key + L10n.pluralOneSuffix
            let value = try #require(table[one], "缺单数条目：\(one)")
            #expect(!Self.containsCJK(value), "\(one) 的英文单数条目含中文：\(value)")
        }
    }

    @Test("中文字面量 key 的 en 译文不得回落中文（含 4b-1 补的 6 个 error 文案）")
    func englishTableDoesNotFallBackToChinese() throws {
        let en = L10n(language: .en)
        let offenders = usedKeys()
            .filter { Self.containsCJK($0) && Self.containsCJK(en($0)) }
            .sorted()
        #expect(offenders.isEmpty, "以下 key 的 en 查询仍返回中文（缺表或漏翻）：\(offenders.prefix(20))")
    }

    @Test("3 个冲突 key 的裁决值固定（防译文再次漂移）")
    func adjudicatedConflictsStayPinned() throws {
        let table = try parseTable()
        #expect(table["星级"] == "Star Rating")
        #expect(table["存在 XMP 冲突，请先裁决"] == "XMP conflicts exist; resolve them first")
        #expect(table["有写入失败项，请先重试"] == "Some writes failed; retry them first")
    }

    @Test("关键路径 zh/en 与码表/键表一致（error/job/progress/取消/延迟文案）")
    func renderPathsFollowTablesInBothLanguages() {
        // B03：旧 GatherLocalization 出口已删，语言由 L10n 显式传入（不读进程级 appLanguage）。
        assertParity(with: L10n(language: .zhCN))
        assertParity(with: L10n(language: .en))
    }

    // MARK: - 一致性断言

    private func assertParity(with l10n: L10n) {
        // 1. 错误码表：全部码的模板在当前语言都能解析（表仍是唯一码源）。
        //    期望值 = 模板本地化后按 `{{name}}` 出现顺序插空（与 L10n.resolvedTemplate 同义）。
        for (code, template) in GatherLocalization.errorMessages {
            let expected = L10n.interpolate(l10n(template), params: [])
            #expect(l10n.errorText(code) == expected, "\(code) 在 \(l10n.language) 下不一致")
        }
        // 双形态解析：CODE::p1::p2 与 CODE: 散文，参数顺序不得丢。
        let parameterized: [(raw: String, code: String, params: [String])] = [
            ("CULLING_REVISION_CONFLICT::3::5", "CULLING_REVISION_CONFLICT", ["3", "5"]),
            ("CULLING_REVISION_CONFLICT: 7", "CULLING_REVISION_CONFLICT", ["7"]),
            ("XMP_CONFIRM_OTHER_SESSION_PENDING: s1", "XMP_CONFIRM_OTHER_SESSION_PENDING", ["s1"]),
            ("FILTER_FIELD_UNKNOWN::rating", "FILTER_FIELD_UNKNOWN", ["rating"]),
            ("NOT_A_REAL_CODE", "", []),
        ]
        for item in parameterized {
            let template = GatherLocalization.errorMessages[item.code] ?? ""
            #expect(!template.isEmpty || item.code.isEmpty, "码表缺 \(item.code)")
            let expected = item.code.isEmpty
                ? l10n(L10n.unknownErrorKey)
                : L10n.interpolate(l10n(template), params: item.params)
            #expect(l10n.errorText(item.raw) == expected, "\(item.raw) 在 \(l10n.language) 下不一致")
        }

        // 2. 任务状态 / 类型 / 进度相位：显示文案 = 码表 key 的本地化结果。
        for (status, key) in GatherLocalization.jobStatusKeys {
            #expect(l10n.jobStatusText(status) == l10n(key))
        }
        for (type, key) in GatherLocalization.jobTypeKeys {
            #expect(l10n.jobTypeText(type) == l10n(key))
        }
        for (phase, key) in GatherLocalization.progressPhaseKeys {
            #expect(l10n.progressPhaseText(phase) == l10n(key))
        }
        #expect(l10n.progressPhaseText(nil) == l10n(L10n.unknownPhaseKey))
        #expect(l10n.progressPhaseText("no.such.phase") == l10n(L10n.unknownPhaseKey))

        // 3. 任务错误消息：码值 / 参数化码 / 散文 / 空 —— 与 errorText 同一解析路径。
        for message in ["XMP_WRITE_FAILED", "CULLING_REVISION_CONFLICT::3::5", "disk offline", ""] {
            #expect(l10n.jobErrorMessage(message) == l10n.errorText(message))
        }
        #expect(l10n.jobErrorMessage(nil) == l10n(L10n.unknownErrorKey))

        // 4. 取消文案（4b-1 收敛到 LocalizedText.cancel）+ 延迟文案渲染。
        #expect(LocalizedText.cancel("导出").resolved(with: l10n)
            == l10n.format("已取消“%@”，未执行任何更改", "导出"))
        #expect(LocalizedText("已保存 %@", params: ["缩略图尺寸"]).resolved(with: l10n)
            == l10n.format("已保存 %@", "缩略图尺寸"))
        #expect(LocalizedText("已写入 %lld 项", params: ["3"]).resolved(with: l10n)
            == l10n.format("已写入 %lld 项", 3))
        // 未知 key 原样透传（诊断原文上屏路径，不能丢）。
        #expect(LocalizedText("RAW_DIAGNOSTIC").resolved(with: l10n) == "RAW_DIAGNOSTIC")
    }

    // MARK: - 工具

    /// 纯 printf 数值格式（不是 key）：与 en 表的存在性无关，直接不参与 parity。
    private static func isMachineFormat(_ literal: String) -> Bool {
        literal.range(of: machineFormatPattern, options: .regularExpression) != nil
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value)
                || (0x3000...0x303F).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }

    private static func unescape(_ raw: String) -> String {
        var result = ""
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            default: result.append(escaped)
            }
        }
        return result
    }
}
