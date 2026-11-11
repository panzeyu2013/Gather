// desktop/native/gather-app/Tests/GatherAppTests/FolderTreeTests.swift
// Wave5 batch4（task-18 / F1）：物理文件夹树 —— 目录枚举 / 懒加载 / directory 筛选规则。
//
// 覆盖（不碰真实照片库；临时目录 + 纯函数/模型）：
// 1. 目录枚举：只返回真实目录（文件/隐藏项/符号链接排除）、排序稳定；
// 2. 根缺失/根是文件 → 明确错误（UI 空态 + 重试的依据）；
// 3. 懒加载模型：根一层随 setRoot 读取，子目录只在展开时读取；可见行拍平 +
//    空目录占位；重复 setRoot 不重置；
// 4. directory 筛选前缀规则：末斜杠、归一化、选中判定、面包屑；
// 5. directory 与既有条件 AND 组合（复用 buildLibraryCriteria，不新增后端）。
import Foundation
import Testing
@testable import GatherUI
import GatherProtocol

private func makeFolderTreeRoot(_ label: String = "gather-foldertree") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Suite("FolderTree（物理文件夹树）")
struct FolderTreeTests {
    // MARK: 目录枚举

    @Test func childDirectoriesOnlyRealDirectoriesAndSorted() throws {
        let root = try makeFolderTreeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["banana", "Apple", "cherry"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("photo.jpg"))
        try fm.createDirectory(
            at: root.appendingPathComponent(".hiddenDir"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("banana"))

        let entries = try FolderTreeLoader.childDirectories(of: root.path)
        #expect(entries.map(\.name) == ["Apple", "banana", "cherry"],
                "只收目录、排除文件/隐藏/符号链接，并按 Finder 习惯排序")
        #expect(entries.allSatisfy { $0.path.hasPrefix(root.path) })
    }

    @Test func rootEntryReportsMissingAndNonDirectory() throws {
        let root = try makeFolderTreeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nope")
        var missingError: FolderTreeError?
        do {
            _ = try FolderTreeLoader.rootEntry(missing.path)
        } catch let error as FolderTreeError {
            missingError = error
        }
        #expect(missingError == .notFound)

        let file = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        var fileError: FolderTreeError?
        do {
            _ = try FolderTreeLoader.rootEntry(file.path)
        } catch let error as FolderTreeError {
            fileError = error
        }
        #expect(fileError == .notDirectory)
    }

    // MARK: 懒加载模型

    @Test func modelLoadsRootLayerLazilyAndFlattensRows() throws {
        let root = try makeFolderTreeRoot("gather-foldertree-model")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let a = root.appendingPathComponent("A")
        try fm.createDirectory(at: a, withIntermediateDirectories: false)
        try fm.createDirectory(
            at: a.appendingPathComponent("A1"), withIntermediateDirectories: false)
        let empty = root.appendingPathComponent("Empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)

        let model = FolderTreeModel()
        model.setRoot(root.path)

        #expect(model.rootError == nil)
        #expect(model.root?.path == root.path)
        #expect(model.children(of: root.path).map(\.name) == ["A", "Empty"])
        #expect(model.children(of: a.path).isEmpty, "未展开的子目录不得提前读取")
        #expect(model.isExpanded(root.path), "根默认展开")

        // 展开 A → 懒加载 A1；行拍平顺序 = 深度优先。
        model.toggleExpansion(a.path)
        #expect(model.children(of: a.path).map(\.name) == ["A1"])
        var rows = model.visibleRows()
        #expect(rows.map(\.name) == [root.lastPathComponent, "A", "A1", "Empty"])
        #expect(rows.map(\.depth) == [0, 1, 2, 1])

        // 展开空目录 → 空占位行；收起 A → A1 不再可见。
        model.toggleExpansion(empty.path)
        rows = model.visibleRows()
        #expect(rows.contains { $0.kind == .empty && $0.depth == 2 })
        model.toggleExpansion(a.path)
        rows = model.visibleRows()
        #expect(!rows.contains { $0.name == "A1" })
        #expect(!model.isExpanded(a.path))
    }

    @Test func modelReportsRootErrorAndKeepsNoRows() throws {
        let model = FolderTreeModel()
        model.setRoot("/nonexistent/gather-folder-tree-\(UUID().uuidString)")
        #expect(model.rootError == .notFound)
        #expect(model.root == nil)
        #expect(model.visibleRows().isEmpty)
    }

    // MARK: directory 筛选规则

    @Test func directoryFilterRuleNormalizesPrefixAndSelection() {
        #expect(DirectoryFilterRule.prefix(for: "/a/b") == "/a/b/")
        #expect(DirectoryFilterRule.prefix(for: " /a/b/ ") == "/a/b/")
        #expect(DirectoryFilterRule.normalizedFilterPath("/a/b/") == "/a/b")
        #expect(DirectoryFilterRule.normalizedFilterPath("   ") == nil)
        #expect(DirectoryFilterRule.isSelected(path: "/a/b", filterPrefix: "/a/b/"))
        #expect(!DirectoryFilterRule.isSelected(path: "/a/bc", filterPrefix: "/a/b/"),
                "前缀必须按目录边界，不能把 /a/bc 算进 /a/b")
        #expect(DirectoryFilterRule.breadcrumb(root: "/a/b", filterPrefix: "/a/b/c/")
            == "c")
        #expect(DirectoryFilterRule.breadcrumb(root: "/a/b", filterPrefix: "/a/b/c/d/")
            == "c / d")
        #expect(DirectoryFilterRule.breadcrumb(root: "/a/b", filterPrefix: "/x/y/")
            == "/x/y", "不在根内时退回绝对路径")
        #expect(DirectoryFilterRule.breadcrumb(root: "/a/b", filterPrefix: "") == nil)
    }

    @Test func directoryFilterCombinesWithExistingConditions() {
        var state = LibraryFilterState()
        state.directory = DirectoryFilterRule.prefix(for: "/a/b")
        state.rating = "4"
        let criteria = buildLibraryCriteria(state)
        #expect(criteria.logic == .and, "目录条件必须与既有筛选 AND 组合")
        let rules = criteria.conditions.compactMap { condition -> FilterRule? in
            if case .rule(let rule) = condition { return rule }
            return nil
        }
        #expect(rules.contains {
            $0.field == "directory" && $0.operator == .startsWith
                && $0.value == .string("/a/b/")
        })
        #expect(rules.contains { $0.field == "rating" })
    }
}
