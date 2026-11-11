// desktop/native/gather-app/Tests/GatherAppTests/CollectionHierarchyTests.swift
// Wave2 收尾（task-27）：集合命名路径（层级约定）的纯逻辑、服务端改名/移动语义、
// 侧栏树组装与输入前置校验。
//
// 分层约定：路径规则的权威在 GatherApplication/CurationPath（服务端 create/rename 都过它）；
// GatherUI 的 CollectionTree/CollectionPathInput 是同一规则的最小副本（layering 门禁禁止
// UI import Application）。本文件同时覆盖两边：Application 用真实内存库 + 真实仓储，
// UI 用纯值类型（不启动 SwiftUI）。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication
@testable import GatherUI

// MARK: - 路径规则（Application 权威）

@Suite("集合命名路径规则（task-27）")
struct CurationPathRuleTests {

    @Test("规范化：每段去首尾空白、以分隔符连接")
    func parseNormalizesSegments() throws {
        let path = try CurationPath.parse("  客户A / 精选  ")
        #expect(path.segments == ["客户A", "精选"])
        #expect(path.fullName == "客户A/精选")
        #expect(path.leaf == "精选")
        #expect(path.depth == 2)
        #expect(path.parent?.fullName == "客户A")
        #expect(path.parent?.parent == nil)
    }

    @Test("非法输入逐类拒绝：空/空段/保留字符/控制字符/点名/单段过长/总长超限")
    func rejectsInvalidInputs() {
        let invalidInputs = [
            "", "   ", "A//B", "/A", "A/", "A:B", "A*B", "A\\B", "A\nB", ".", "A/..",
        ]
        for raw in invalidInputs {
            #expect(throws: CurationError.self) {
                _ = try CurationPath.parse(raw)
            }
        }
        #expect(throws: CurationError.self) {
            _ = try CurationPath.parse(String(repeating: "a", count: 81))
        }
        let overlong = [
            String(repeating: "a", count: 80),
            String(repeating: "b", count: 80),
            String(repeating: "c", count: 80),
        ].joined(separator: "/")
        #expect(throws: CurationError.self) {
            _ = try CurationPath.parse(overlong)
        }
    }

    @Test("宽容解析只用于既有名：空段被忽略、保留字符不拒绝")
    func lenientParseForExistingNames() {
        #expect(CurationPath.parseLenient("A//B").fullName == "A/B")
        #expect(CurationPath.parseLenient("客户:旧名").fullName == "客户:旧名")
    }

    @Test("派生：追加子段 / 换叶子 / 换父 / 祖先后代判定")
    func derivesPaths() throws {
        let base = try CurationPath.parse("客户A")
        let appended = try base.appending("精选")
        #expect(appended.fullName == "客户A/精选")
        let path = try CurationPath.parse("客户A/精选")
        let renamed = try path.replacingLeaf(with: "交付")
        #expect(renamed.fullName == "客户A/交付")
        let uprooted = try path.moving(under: nil)
        #expect(uprooted.fullName == "精选")
        let other = try CurationPath.parse("客户B")
        let moved = try path.moving(under: other)
        #expect(moved.fullName == "客户B/精选")
        let parent = try CurationPath.parse("A")
        let child = try CurationPath.parse("A/B")
        #expect(parent.isAncestor(of: child))
        #expect(!child.isAncestor(of: parent))
    }
}

// MARK: - 服务端：建集合 / 重命名 / 移动（真实内存库）

private func makeCurationService() throws -> (DBConnection, CurationService) {
    let db = try makeTestDB()
    try insertSession(db, "s1")
    let service = CurationService(
        collections: CollectionRepo(connection: db),
        stacks: StackRepo(connection: db),
        duplicates: GlobalDuplicateQuery(connection: db),
        transactions: db
    )
    return (db, service)
}

@Suite("集合改名/移动语义（task-27）")
struct CollectionRenameSemanticsTests {

    @Test("新建支持路径；落库名 = 规范化全路径；同父重名拒绝")
    func createSupportsPathAndRejectsSiblingDuplicate() throws {
        let (db, service) = try makeCurationService()
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: " 客户A "))
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "客户A/精选"))
        let rows = try CollectionRepo(connection: db).list(sessionId: "s1")
        let names = Set(rows.map(\.name))
        #expect(names == ["客户A", "客户A/精选"])
        #expect(throws: CurationError.self) {
            _ = try service.createCollection(
                CollectionCreateInput(sessionId: "s1", name: "客户A/精选"))
        }
        #expect(throws: CurationError.self) {
            _ = try service.createCollection(
                CollectionCreateInput(sessionId: "s1", name: "客户A//精选"))
        }
    }

    @Test("父集合改名会连同全部后代一起移动（同事务）")
    func renameMovesSubtree() throws {
        let (db, service) = try makeCurationService()
        let a = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A"))
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A/B"))
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A/C"))
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "X"))
        try service.renameCollection(
            CollectionRenameInput(collectionId: a.id, name: "X/A"))
        let rows = try CollectionRepo(connection: db).list(sessionId: "s1")
        #expect(Set(rows.map(\.name)) == ["X/A", "X/A/B", "X/A/C", "X"])
    }

    @Test("改最后一段 = 改名；换父 = 移动；不新增行")
    func renameLeafAndMoveUnderOtherParent() throws {
        let (db, service) = try makeCurationService()
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A"))
        let b = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A/B"))
        try service.renameCollection(
            CollectionRenameInput(collectionId: b.id, name: "A/C"))
        let renamed = try CollectionRepo(connection: db).get(id: b.id)
        #expect(renamed?.name == "A/C")
        try service.renameCollection(
            CollectionRenameInput(collectionId: b.id, name: "C"))
        let moved = try CollectionRepo(connection: db).get(id: b.id)
        #expect(moved?.name == "C")
        let rows = try CollectionRepo(connection: db).list(sessionId: "s1")
        #expect(rows.count == 2)
    }

    @Test("拒绝：移进自身子树；与既有集合撞名")
    func renameRejectsCyclesAndDuplicates() throws {
        let (db, service) = try makeCurationService()
        let a = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A"))
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A/B"))
        _ = try service.createCollection(
            CollectionCreateInput(sessionId: "s1", name: "A/C"))
        #expect(throws: CurationError.self) {
            try service.renameCollection(
                CollectionRenameInput(collectionId: a.id, name: "A/B/A"))
        }
        guard let c = try CollectionRepo(connection: db)
            .list(sessionId: "s1").first(where: { $0.name == "A/C" }) else {
            Issue.record("测试夹具缺少 A/C 集合")
            return
        }
        #expect(throws: CurationError.self) {
            try service.renameCollection(
                CollectionRenameInput(collectionId: c.id, name: "A/B"))
        }
    }
}

// MARK: - UI 侧：树组装与输入前置校验（纯值类型）

@Suite("集合树组装（task-27）")
struct CollectionTreeTests {

    private func summary(
        _ id: String, _ name: String, count: Int = 0
    ) -> CollectionSummary {
        CollectionSummary(id: id, sessionId: "s1", name: name, itemCount: count)
    }

    @Test("按命名路径组装：隐式父节点补全、同层确定顺序")
    func buildsTree() {
        let tree = CollectionTree.build([
            summary("1", "B"),
            summary("2", "A/C"),
            summary("3", "A"),
            summary("4", "A/B"),
            summary("5", "客户/精选"),
        ])
        #expect(tree.map(\.displayName) == ["A", "B", "客户"])
        let a = tree[0]
        #expect(a.collection?.id == "3")
        #expect(a.children.map(\.displayName) == ["B", "C"])
        #expect(a.children[0].collection?.id == "4")
        let client = tree[2]
        #expect(client.isGroup)
        #expect(client.children.map(\.displayName) == ["精选"])
        #expect(client.children[0].collection?.id == "5")
    }

    @Test("既有集合同时有子集合：节点仍可选；纯分组节点没有集合记录")
    func mixedNodes() {
        let tree = CollectionTree.build([
            summary("1", "X"),
            summary("2", "X/Y"),
            summary("3", "P/Q/R"),
        ])
        // 根节点按名称排序（P 在 X 前），不能按下标断言。
        let x = try! #require(tree.first { $0.path == "X" })
        #expect(!x.isGroup)
        #expect(x.children.map(\.displayName) == ["Y"])
        let p = try! #require(tree.first { $0.path == "P" })
        #expect(p.isGroup)
        #expect(p.children[0].isGroup)
        #expect(p.children[0].children[0].collection?.id == "3")
    }

    @Test("同层排序：大小写不敏感 + 数字感知，且结果稳定")
    func ordering() {
        #expect(CollectionTree.orderedBefore("A2", "A10"))
        #expect(CollectionTree.orderedBefore("a", "B"))
        #expect(!CollectionTree.orderedBefore("B", "a"))
    }

    @Test("输入前置校验与服务端规则对齐（最小副本）")
    func inputValidation() {
        #expect(CollectionPathInput.validate("") == .empty)
        #expect(CollectionPathInput.validate("A//B") == .emptySegment)
        #expect(CollectionPathInput.validate("A:B") == .reservedCharacter)
        #expect(CollectionPathInput.validate(".") == .dotSegment)
        #expect(CollectionPathInput.validate(String(repeating: "a", count: 81))
                == .segmentTooLong)
        #expect(CollectionPathInput.normalizedPath(" 客户A / 精选 ")
                == "客户A/精选")
    }

    @Test("历史非规范名可经重命名规范化（Wave4a：A//B → A/B）")
    func renameNormalizesLegacyName() throws {
        let (db, service) = try makeCurationService()
        let repo = CollectionRepo(connection: db)
        let legacy = try repo.create(sessionId: "s1", name: "A//B", sortOrder: nil)
        try service.renameCollection(
            CollectionRenameInput(collectionId: legacy.id, name: "A/B"))
        let updated = try repo.get(id: legacy.id)
        #expect(updated?.name == "A/B", "规范化后必须真正落库，而不是当 no-op 返回")
    }
}
