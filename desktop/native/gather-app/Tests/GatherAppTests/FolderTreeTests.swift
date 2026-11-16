// desktop/native/gather-app/Tests/GatherAppTests/FolderTreeTests.swift
// Wave5 batch4（task-18 / F1）：物理文件夹树 —— 目录枚举 / 懒加载 / directory 筛选规则。
// Wave5 batch6（task-27 / A5）：文件夹树右键「用此目录新建工作区」入口映射。
// Wave5 batch8（task-32 / A5）：文件夹树右键「摄取到此工作区」入口映射。
//
// 覆盖（不碰真实照片库；临时目录 + 纯函数/模型）：
// 1. 目录枚举：只返回真实目录（文件/隐藏项/符号链接排除）、排序稳定；
// 2. 根缺失/根是文件 → 明确错误（UI 空态 + 重试的依据）；
// 3. 懒加载模型：根一层随 setRoot 读取，子目录只在展开时读取；可见行拍平 +
//    空目录占位；重复 setRoot 不重置；
// 4. directory 筛选前缀规则：末斜杠、归一化、选中判定、面包屑；
// 5. directory 与既有条件 AND 组合（复用 buildLibraryCriteria，不新增后端）；
// 6. 新建工作区：目录→NewWorkspaceRequest 纯映射（trim/空路径/请求身份）、
//    只有真实目录行才提供动作、回调收到绝对目录路径、默认回调 no-op；
// 7. 摄取到此工作区：门控矩阵（未选工作区/工作区根/根内/外部卷/占位行）、
//    外部卷筛选（排除系统盘与工作区所在卷）、确认上下文映射、ingest 入参映射
//    （复制/登记、默认模板、校验开、skip、无第二目的地）、回调收到绝对路径。
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

    // MARK: - 用此目录新建工作区（Batch6 / task-27）

    @Test func workspaceCreationRequestMapsDirectoryAndTrimsWhitespace() {
        let request = RootView.workspaceCreationRequest(
            forDirectory: " /tmp/gather-album \n")
        #expect(request?.folderPath == "/tmp/gather-album")
        #expect(request?.folderPath.isEmpty == false,
                "预填目录必须非空，Dashboard 才会把它带进新建表单")
        // 同一路径的重复请求也必须是新身份（Equatable 依赖 UUID，表单才会重开）。
        let again = RootView.workspaceCreationRequest(forDirectory: "/tmp/gather-album")
        #expect(request != again)
        // 空/纯空白路径不产生请求（也不切 Dashboard）。
        #expect(RootView.workspaceCreationRequest(forDirectory: "") == nil)
        #expect(RootView.workspaceCreationRequest(forDirectory: "   ") == nil)
    }

    @Test func onlyRealDirectoryRowsOfferWorkspaceCreation() {
        #expect(FolderTreeRow(path: "/a", name: "a", depth: 0, kind: .directory)
            .canCreateWorkspace)
        #expect(!FolderTreeRow(path: "/a", name: "", depth: 1, kind: .empty)
            .canCreateWorkspace, "空目录占位行没有可用路径，右键不出现该项")
        #expect(!FolderTreeRow(path: "/a", name: "", depth: 1, kind: .unreadable)
            .canCreateWorkspace, "不可读占位行没有可用路径，右键不出现该项")
    }

    @Test func folderTreeWorkspaceActionPassesAbsoluteDirectoryPath() throws {
        let root = try makeFolderTreeRoot("gather-foldertree-action")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FolderTreeModel()
        model.setRoot(root.path)
        let directoryRow = try #require(model.visibleRows().first)
        #expect(directoryRow.canCreateWorkspace)

        var received: [String] = []
        let panel = FolderTreePanel(
            rootPath: root.path,
            rootTitle: nil,
            selectedDirectoryPrefix: "",
            onSelectDirectory: { _ in },
            onClearDirectory: {},
            onCreateWorkspace: { received.append($0) })
        panel.onCreateWorkspace(directoryRow.path)
        #expect(received == [root.path], "右键动作必须传当前目录的绝对路径")
    }

    @Test func folderTreeWorkspaceActionDefaultsToNoOp() {
        // 预览/独立测试路径不注入回调：默认闭包必须存在且可安全调用（不崩/不导航）。
        let panel = FolderTreePanel(
            rootPath: nil,
            rootTitle: nil,
            selectedDirectoryPrefix: "",
            onSelectDirectory: { _ in },
            onClearDirectory: {})
        panel.onCreateWorkspace("/tmp/gather-does-not-matter")
        panel.onIngestFolder("/tmp/gather-does-not-matter")
    }

    // MARK: - 摄取到此工作区（Batch8 / task-32）

    @Test func canIngestOnlyOutsideWorkspaceAtNonRootDepth() {
        let workspace = "/Users/me/Pictures"
        // 未选工作区 → 无目标，false。
        #expect(!FolderTreeRow(path: "/Volumes/Card/DCIM", name: "DCIM",
                               depth: 1, kind: .directory)
            .canIngestToWorkspace(workspaceRoot: nil))
        // 工作区根 / 树根（depth 0）→ false，避免把工作区重新摄取到自己。
        #expect(!FolderTreeRow(path: workspace, name: "Pictures",
                               depth: 0, kind: .directory)
            .canIngestToWorkspace(workspaceRoot: workspace))
        // 工作区 sourcePath 内的目录：已被本工作区扫描覆盖 → false。
        #expect(!FolderTreeRow(path: workspace + "/2024", name: "2024",
                               depth: 1, kind: .directory)
            .canIngestToWorkspace(workspaceRoot: workspace))
        // 尾斜杠归一化后同样按"根内"处理。
        #expect(!FolderTreeRow(path: workspace + "/2024/01", name: "01",
                               depth: 2, kind: .directory)
            .canIngestToWorkspace(workspaceRoot: workspace + "/"))
        // 外部挂载卷下的目录 → true（唯一有意义的摄取来源）。
        #expect(FolderTreeRow(path: "/Volumes/Card/DCIM", name: "DCIM",
                              depth: 1, kind: .directory)
            .canIngestToWorkspace(workspaceRoot: workspace))
        // 外部卷根（depth 0）也是树根 → false。
        #expect(!FolderTreeRow(path: "/Volumes/Card", name: "Card",
                               depth: 0, kind: .directory)
            .canIngestToWorkspace(workspaceRoot: workspace))
        // 空/不可读占位行没有路径 → false。
        #expect(!FolderTreeRow(path: workspace, name: "", depth: 1, kind: .empty)
            .canIngestToWorkspace(workspaceRoot: workspace))
        #expect(!FolderTreeRow(path: workspace, name: "", depth: 1, kind: .unreadable)
            .canIngestToWorkspace(workspaceRoot: workspace))
    }

    @Test func externalRootSelectionExcludesSystemAndWorkspaceVolumes() {
        let candidates = [
            FolderTreeItem(path: "/", name: "/"),
            FolderTreeItem(path: "/Volumes/Work", name: "Work"),
            FolderTreeItem(path: "/Volumes/Card", name: "Card"),
            FolderTreeItem(path: "/Volumes/Card/", name: "Card"),
        ]
        // 工作区在 /Volumes/Work（该卷根不列为外部位置；系统盘 "/" 永远排除）。
        let onWorkVolume = FolderTreeLoader.selectExternalRoots(
            candidates: candidates, workspaceRoot: "/Volumes/Work/Photos")
        #expect(onWorkVolume.map(\.path) == ["/Volumes/Card"])
        // 工作区在系统盘：其它挂载卷都是外部位置。
        let onSystemDisk = FolderTreeLoader.selectExternalRoots(
            candidates: candidates, workspaceRoot: "/Users/me/Pictures")
        #expect(onSystemDisk.map(\.path) == ["/Volumes/Card", "/Volumes/Work"])
        // 未选工作区不枚举外部位置。
        #expect(FolderTreeLoader.selectExternalRoots(
            candidates: candidates, workspaceRoot: nil).isEmpty)
    }

    @Test func pendingIngestFolderMapsSessionSourceAndNames() {
        let pending = LibraryView.pendingIngestFolder(
            sessionId: " s1 ",
            workspaceRoot: "/Volumes/Work/Photos/",
            workspaceName: "客户A",
            folderPath: "/Volumes/Card/DCIM/100CANON/")
        #expect(pending?.sessionId == "s1")
        #expect(pending?.sessionSourcePath == "/Volumes/Work/Photos")
        #expect(pending?.folderPath == "/Volumes/Card/DCIM/100CANON")
        #expect(pending?.folderName == "100CANON")
        #expect(pending?.workspaceName == "客户A")
        // 名称回退：无会话名时用工作区根最后一段。
        #expect(LibraryView.pendingIngestFolder(
            sessionId: "s1", workspaceRoot: "/Volumes/Work/Photos",
            workspaceName: "  ", folderPath: "/Volumes/Card/DCIM")?.workspaceName
            == "Photos")
        // 未选工作区 / 空 session / 目录=工作区根 → nil（不弹确认、不发请求）。
        #expect(LibraryView.pendingIngestFolder(
            sessionId: "s1", workspaceRoot: nil,
            workspaceName: nil, folderPath: "/Volumes/Card") == nil)
        #expect(LibraryView.pendingIngestFolder(
            sessionId: "", workspaceRoot: "/a",
            workspaceName: nil, folderPath: "/Volumes/Card") == nil)
        #expect(LibraryView.pendingIngestFolder(
            sessionId: "s1", workspaceRoot: "/a",
            workspaceName: nil, folderPath: "/a/") == nil)
    }

    @Test func ingestFolderInputMapsCopySemantics() throws {
        let mapped = try RootView.ingestFolderInput(
            sessionId: " s1 ",
            sessionSourcePath: "/Volumes/Work/Photos/",
            folderPath: "/Volumes/Card/DCIM/100CANON/")
        let input = try #require(mapped)
        #expect(input.sessionId == "s1")
        #expect(input.sourcePaths == ["/Volumes/Card/DCIM/100CANON"],
                "摄取源 = 右键目录的绝对路径")
        #expect(input.destinationRoot == "/Volumes/Work/Photos",
                "目的地 = 当前工作区 sourcePath")
        #expect(input.renameTemplate == "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}")
        #expect(input.secondDestinationRoot == nil, "本批不写第二目的地（UI 默认空）")
        #expect(input.verifyChecksum, "默认开启校验")
        #expect(input.duplicatePolicy == .skip, "默认跳过库内已存在照片")
        // 目录=工作区根（自我摄取）/ 空目录 → nil。
        #expect(try RootView.ingestFolderInput(
            sessionId: "s1", sessionSourcePath: "/a", folderPath: "/a/") == nil)
        #expect(try RootView.ingestFolderInput(
            sessionId: "s1", sessionSourcePath: "/a", folderPath: "   ") == nil)
    }

    @Test func folderTreeIngestActionPassesAbsoluteDirectoryPath() {
        var received: [String] = []
        let panel = FolderTreePanel(
            rootPath: "/Users/me/Pictures",
            rootTitle: nil,
            selectedDirectoryPrefix: "",
            onSelectDirectory: { _ in },
            onClearDirectory: {},
            onCreateWorkspace: { _ in },
            onIngestFolder: { received.append($0) })
        panel.onIngestFolder("/Volumes/Card/DCIM/100CANON")
        #expect(received == ["/Volumes/Card/DCIM/100CANON"],
                "右键动作必须传当前目录的绝对路径")
    }
}
