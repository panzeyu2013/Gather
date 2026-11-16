// desktop/native/gather-app/Tests/GatherAppTests/MetadataTransferTests.swift
// Wave5（Batch5 / task-23）：元数据模板与词库导入/导出的回归测试。
//
// 覆盖：
// 1. 模板 JSON：编码/解码 round-trip、版本与文件级非法（空/非 JSON/版本过高/无模板）、
//    条目级非法（空名/重名/缺字段）、与现有同名的计数；
// 2. 模板规划：同名「跳过/覆盖」两种策略（默认跳过，覆盖带既有模板 id）；
// 3. 词库 CSV：RFC4180 引号 + 同义词 `;`/`\\` 转义 round-trip、新增/同义词更新/一致
//    三类分类、非法行（路径/引号/列数/超限同义词/文件内重复路径）、空文件与 >2000 行拒绝；
// 4. 执行器：只写计划内条目、失败逐条计数且继续后续条目、空计划零写入（Confirmed 门禁在
//    类型上强制——执行入口只接受 Confirmed<T>，本测试全部经 Confirmed 构造）。
import Foundation
import Testing
import GatherProtocol
import GatherTestSupport
@testable import GatherUI

// MARK: - 夹具

private func transferFields(
    title: String? = nil, caption: String? = nil, copyright: String? = nil
) -> DescriptiveMetadata {
    DescriptiveMetadata(title: title, caption: caption, copyrightNotice: copyright)
}

private func transferTemplateSummary(
    id: String, name: String, client: String? = nil
) -> MetadataTemplateSummary {
    MetadataTemplateSummary(
        id: id, name: name, fieldCount: 1,
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", client: client)
}

private func transferKeywordNode(
    path: String, synonyms: [String] = []
) -> KeywordLibraryNode {
    let parent = KeywordPath(path)?.parent?.serialized
    return KeywordLibraryNode(
        path: path,
        name: KeywordPath(path)?.leaf ?? path,
        parentPath: parent,
        usageCount: 0,
        synonyms: synonyms)
}

/// 执行器记录盒（@Sendable 闭包内写入；只用既有 LockedBox，不新增 @unchecked Sendable）。
private struct TransferRecorder {
    var savedTemplates: [MetadataTemplateSaveInput] = []
    var createdPaths: [String] = []
    var synonymWrites: [(path: String, synonyms: [String])] = []
    var failTemplateNames: Set<String> = []
    var failKeywordPaths: Set<String> = []
}

// MARK: - 模板文件格式

@Suite("Wave5 元数据模板导入导出（task-23）")
struct MetadataTemplateTransferTests {
    @Test("模板 JSON round-trip：name/fields/client/version/exportedAt 全保留")
    func templateJSONRoundTrip() throws {
        let entries = [
            MetadataTemplateImportEntry(
                name: "客户A", fields: transferFields(title: "标题", copyright: "© 客户A"),
                client: "客户A"),
            MetadataTemplateImportEntry(name: "旅行", fields: transferFields(caption: "巴黎")),
        ]
        let data = try MetadataTemplateTransfer.makeExportData(
            entries, exportedAt: "2026-11-11T00:00:00Z")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"version\""), "导出文件必须带版本号")
        #expect(text.contains("2026-11-11T00:00:00Z"))

        let preview = try MetadataTemplateTransfer.decode(data, existingNames: [])
        #expect(preview.entries == entries)
        #expect(preview.invalid.isEmpty)
        #expect(preview.duplicateNameCount == 0)
        #expect(preview.existingNameCount == 0)
        #expect(preview.exportedAt == "2026-11-11T00:00:00Z")
    }

    @Test("模板文件级非法：空 / 非 JSON / 版本过高 / 没有模板 显式拒绝")
    func templateFileLevelRejections() throws {
        #expect(throws: GatherError.self) {
            _ = try MetadataTemplateTransfer.decode(Data(), existingNames: [])
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataTemplateTransfer.decode(
                Data("not json".utf8), existingNames: [])
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataTemplateTransfer.decode(
                Data("{\"version\": 99, \"templates\": []}".utf8), existingNames: [])
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataTemplateTransfer.decode(
                Data("{\"version\": 1, \"templates\": []}".utf8), existingNames: [])
        }
        #expect(throws: GatherError.self) {
            _ = try MetadataTemplateTransfer.decode(
                Data("{\"version\": 1}".utf8), existingNames: [])
        }
    }

    @Test("版本号缺失按当前版本接受（旧文件兼容）")
    func templateMissingVersionIsAccepted() throws {
        let json = """
        {"exportedAt":"x","templates":[{"name":"A","fields":{}}]}
        """
        let preview = try MetadataTemplateTransfer.decode(
            Data(json.utf8), existingNames: [])
        #expect(preview.entries.map(\.name) == ["A"])
    }

    @Test("条目级非法逐条分类：空名 / 文件内重名 / 缺字段 不中断整批预览")
    func templateEntryLevelInvalid() throws {
        let json = """
        {"version":1,"templates":[
          {"name":"A","fields":{}},
          {"name":"  ","fields":{}},
          {"name":"A","fields":{}},
          {"name":"B"},
          {"fields":{"caption":"x"}}
        ]}
        """
        let preview = try MetadataTemplateTransfer.decode(
            Data(json.utf8), existingNames: ["A"])
        #expect(preview.entries.map(\.name) == ["A"])
        #expect(preview.invalid.count == 4)
        #expect(preview.duplicateNameCount == 1)
        #expect(preview.existingNameCount == 1, "A 与现有模板同名")
    }

    @Test("同名策略：默认跳过、覆盖用既有模板 id（保留 createdAt 的语义在服务端）")
    func templatePlanStrategies() throws {
        let entries = [
            MetadataTemplateImportEntry(name: "A", fields: transferFields(title: "新")),
            MetadataTemplateImportEntry(name: "B", fields: transferFields(caption: "新")),
        ]
        let preview = MetadataTemplateImportPreview(
            entries: entries, invalid: [], duplicateNameCount: 0,
            existingNameCount: 1, exportedAt: "")
        let existing = ["A": transferTemplateSummary(id: "t1", name: "A")]

        let skipped = MetadataTemplateTransfer.plan(
            preview, existing: existing, strategy: .skip)
        #expect(skipped.items.map(\.name) == ["B"])
        #expect(skipped.skippedExisting == ["A"])
        #expect(skipped.items.allSatisfy { $0.overwriteTemplateId == nil })

        let overwritten = MetadataTemplateTransfer.plan(
            preview, existing: existing, strategy: .overwrite)
        #expect(overwritten.items.map(\.name) == ["A", "B"])
        #expect(overwritten.skippedExisting.isEmpty)
        #expect(overwritten.items.first?.overwriteTemplateId == "t1")
        #expect(overwritten.items.last?.overwriteTemplateId == nil)
    }

    @Test("执行器：导出读列表+字段；导入逐条提交，失败计数且继续")
    func templateExecutorImportAndExport() async throws {
        let box = LockedBox(TransferRecorder())
        let executor = MetadataTransferExecutor(
            listTemplates: {
                [transferTemplateSummary(id: "t1", name: "客户A", client: "客户A")]
            },
            loadTemplateFields: { id in
                #expect(id == "t1")
                return transferFields(copyright: "© 客户A")
            },
            saveTemplate: { input in
                if box.lock.withLock({ box.failTemplateNames.contains(input.name) }) {
                    throw GatherError.invalidParameter(field: "name", reason: "boom")
                }
                box.lock.withLock { box.savedTemplates.append(input) }
                return transferTemplateSummary(
                    id: input.id ?? "new-\(input.name)", name: input.name)
            },
            listKeywords: { [] },
            createKeyword: { input in
                box.lock.withLock { box.createdPaths.append(input.value.path) }
                return KeywordMutationSummary(nodes: 1)
            },
            setSynonyms: { _ in KeywordMutationSummary(synonyms: 1) })

        let exported = try await executor.exportTemplates()
        #expect(exported.count == 1)
        let decoded = try MetadataTemplateTransfer.decode(
            exported.data, existingNames: [])
        #expect(decoded.entries.first?.name == "客户A")
        #expect(decoded.entries.first?.client == "客户A")

        box.lock.withLock { box.failTemplateNames = ["坏模板"] }
        let plan = MetadataTemplateImportPlan(
            items: [
                MetadataTemplateImportPlan.Item(
                    name: "新模板", fields: transferFields(title: "x"), client: nil,
                    overwriteTemplateId: nil),
                MetadataTemplateImportPlan.Item(
                    name: "坏模板", fields: transferFields(title: "y"), client: nil,
                    overwriteTemplateId: nil),
                MetadataTemplateImportPlan.Item(
                    name: "客户A", fields: transferFields(title: "z"), client: "客户A",
                    overwriteTemplateId: "t1"),
            ],
            skippedExisting: ["跳过的"],
            invalid: [])
        let outcome = await executor.importTemplates(Confirmed(plan, source: .test))
        #expect(outcome.created == 1)
        #expect(outcome.overwritten == 1)
        #expect(outcome.skipped == 1)
        #expect(outcome.failures.map(\.name) == ["坏模板"], "失败逐条计数且继续后续条目")
        let saved = box.lock.withLock { box.savedTemplates }
        #expect(saved.map(\.name) == ["新模板", "客户A"])
        #expect(saved.last?.id == "t1", "覆盖条目必须带既有模板 id")
    }

    @Test("执行器：空计划零写入（确认了但没有可导入项）")
    func templateExecutorEmptyPlan() async {
        let box = LockedBox(TransferRecorder())
        let executor = MetadataTransferExecutor(
            listTemplates: { [] },
            loadTemplateFields: { _ in DescriptiveMetadata() },
            saveTemplate: { input in
                box.lock.withLock { box.savedTemplates.append(input) }
                return transferTemplateSummary(id: "x", name: input.name)
            },
            listKeywords: { [] },
            createKeyword: { _ in KeywordMutationSummary() },
            setSynonyms: { _ in KeywordMutationSummary() })
        let empty = MetadataTemplateImportPlan(items: [], skippedExisting: ["A"], invalid: [])
        let outcome = await executor.importTemplates(Confirmed(empty, source: .test))
        #expect(outcome.created == 0 && outcome.overwritten == 0)
        #expect(outcome.skipped == 1)
        let savedAfterEmptyPlan = box.lock.withLock { box.savedTemplates }
        #expect(savedAfterEmptyPlan.isEmpty)
    }
}

// MARK: - 词库 CSV

@Suite("Wave5 词库 CSV 导入导出（task-23）")
struct KeywordLibraryTransferTests {
    @Test("CSV round-trip：层级路径 / 逗号同义词 / 分号与反斜杠转义")
    func csvRoundTrip() throws {
        let nodes = [
            transferKeywordNode(path: "Travel|Paris", synonyms: ["旅行", "trip, travel"]),
            transferKeywordNode(path: "People", synonyms: ["人物; portrait", "back\\slash"]),
        ]
        let text = KeywordLibraryTransfer.encodeCSV(nodes)
        #expect(text.hasPrefix(KeywordLibraryTransfer.headerLine + "\n"))
        #expect(text.contains("\"旅行; trip, travel\""), "含分隔符的单元格要加引号")

        let preview = try KeywordLibraryTransfer.decodeCSV(text, existing: [])
        #expect(preview.invalid.isEmpty)
        #expect(preview.rows.map(\.path) == ["People", "Travel|Paris"], "导出按 path 排序")
        let allRowsAreNew = preview.rows.allSatisfy { $0.isNew }
        #expect(allRowsAreNew)
        let travel = try #require(preview.rows.first { $0.path == "Travel|Paris" })
        #expect(travel.synonyms == ["旅行", "trip, travel"])
        let people = try #require(preview.rows.first { $0.path == "People" })
        #expect(people.synonyms == ["人物; portrait", "back\\slash"])
    }

    @Test("CSV 解析：新增 / 同义词更新 / 完全一致 三类分类 + 路径归一化")
    func csvClassification() throws {
        let text = """
        path,synonyms
        Travel|Paris,旅行; 浪漫
        People,人物
        Travel,
        """
        let existing = [
            transferKeywordNode(path: "Travel", synonyms: ["旧词"]),
            transferKeywordNode(path: "People", synonyms: ["人物"]),
        ]
        let preview = try KeywordLibraryTransfer.decodeCSV(text, existing: existing)
        #expect(preview.invalid.isEmpty)
        #expect(preview.dataLineCount == 3)
        #expect(preview.unchangedCount == 1, "People 同义词一致 → 跳过")
        #expect(preview.newCount == 1, "Travel|Paris 是新路径")
        #expect(preview.synonymUpdateCount == 1, "Travel 只更新同义词")
        #expect(preview.rows.first { $0.path == "Travel" }?.isNew == false)
        let paris = try #require(preview.rows.first { $0.path == "Travel|Paris" })
        #expect(paris.synonyms == ["旅行", "浪漫"])

        let plan = KeywordLibraryTransfer.plan(preview)
        #expect(plan.newRows.map(\.path) == ["Travel|Paris"])
        #expect(plan.synonymUpdates.map(\.path) == ["Travel"])
        #expect(plan.unchangedCount == 1)
    }

    @Test("CSV 非法行逐行分类：空路径 / 列数 / 引号未闭合 / 文件内重复路径")
    func csvInvalidRows() throws {
        let text = """
        path,synonyms
        ,x
        A|B
        "C|D,foo
        E,one
        E,two
        """
        let preview = try KeywordLibraryTransfer.decodeCSV(text, existing: [])
        #expect(preview.rows.map(\.path) == ["E"])
        #expect(preview.invalid.count == 4)
        #expect(preview.invalid.allSatisfy { !$0.reason.isEmpty })
        let duplicate = try #require(preview.invalid.last)
        #expect(duplicate.reason.contains("重复"))
    }

    @Test("CSV 空文件 / 只有表头 / 超过 2000 行 显式拒绝")
    func csvEmptyAndTooLarge() throws {
        #expect(throws: GatherError.self) {
            _ = try KeywordLibraryTransfer.decodeCSV("", existing: [])
        }
        #expect(throws: GatherError.self) {
            _ = try KeywordLibraryTransfer.decodeCSV(
                KeywordLibraryTransfer.headerLine + "\n\n", existing: [])
        }
        var lines = [KeywordLibraryTransfer.headerLine]
        for index in 0...(KeywordLibraryTransfer.maxImportLines) {
            lines.append("K\(index),")
        }
        do {
            _ = try KeywordLibraryTransfer.decodeCSV(
                lines.joined(separator: "\n"), existing: [])
            Issue.record("超过 2000 行必须拒绝")
        } catch let error as GatherError {
            #expect(error.params["reason"]?.contains("2000") == true)
        }
    }

    @Test("执行器：新路径 createKeyword（有同义词才 setSynonyms），既有路径只覆盖同义词")
    func keywordExecutorImport() async {
        let box = LockedBox(TransferRecorder())
        let executor = MetadataTransferExecutor(
            listTemplates: { [] },
            loadTemplateFields: { _ in DescriptiveMetadata() },
            saveTemplate: { input in
                transferTemplateSummary(id: "x", name: input.name)
            },
            listKeywords: { [] },
            createKeyword: { input in
                if box.lock.withLock({ box.failKeywordPaths.contains(input.value.path) }) {
                    throw GatherError.invalidParameter(field: "path", reason: "boom")
                }
                box.lock.withLock { box.createdPaths.append(input.value.path) }
                return KeywordMutationSummary(nodes: 1)
            },
            setSynonyms: { input in
                box.lock.withLock {
                    box.synonymWrites.append((input.value.path, input.value.synonyms))
                }
                return KeywordMutationSummary(synonyms: input.value.synonyms.count)
            })
        box.lock.withLock { box.failKeywordPaths = ["Bad|Path"] }
        let plan = KeywordImportPlan(
            newRows: [
                KeywordCsvRow(lineNumber: 2, path: "A|B", synonyms: ["x"], isNew: true),
                KeywordCsvRow(lineNumber: 3, path: "Bad|Path", synonyms: [], isNew: true),
                KeywordCsvRow(lineNumber: 4, path: "C", synonyms: [], isNew: true),
            ],
            synonymUpdates: [
                KeywordCsvRow(lineNumber: 5, path: "D", synonyms: ["y"], isNew: false),
            ],
            unchangedCount: 2,
            invalid: [])
        let outcome = await executor.importKeywords(Confirmed(plan, source: .test))
        #expect(outcome.createdPaths == 2)
        #expect(outcome.updatedSynonyms == 1)
        #expect(outcome.unchanged == 2)
        #expect(outcome.failures.map(\.name) == ["Bad|Path"])
        let createdPaths = box.lock.withLock { box.createdPaths }
        #expect(createdPaths == ["A|B", "C"])
        let writes = box.lock.withLock { box.synonymWrites }
        #expect(writes.map(\.path) == ["A|B", "D"], "无同义词的新路径不写同义词")
    }

    @Test("执行器：空计划零写入")
    func keywordExecutorEmptyPlan() async {
        let box = LockedBox(TransferRecorder())
        let executor = MetadataTransferExecutor(
            listTemplates: { [] },
            loadTemplateFields: { _ in DescriptiveMetadata() },
            saveTemplate: { input in transferTemplateSummary(id: "x", name: input.name) },
            listKeywords: { [] },
            createKeyword: { input in
                box.lock.withLock { box.createdPaths.append(input.value.path) }
                return KeywordMutationSummary()
            },
            setSynonyms: { input in
                box.lock.withLock { box.synonymWrites.append((input.value.path, [])) }
                return KeywordMutationSummary()
            })
        let plan = KeywordImportPlan(
            newRows: [], synonymUpdates: [], unchangedCount: 3, invalid: [])
        let outcome = await executor.importKeywords(Confirmed(plan, source: .test))
        #expect(outcome.unchanged == 3)
        let createdPathsAfterEmptyPlan = box.lock.withLock { box.createdPaths }
        #expect(createdPathsAfterEmptyPlan.isEmpty)
        let synonymWritesAfterEmptyPlan = box.lock.withLock { box.synonymWrites }
        #expect(synonymWritesAfterEmptyPlan.isEmpty)
    }
}
