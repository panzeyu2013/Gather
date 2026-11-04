// desktop/native/gather-core/Tests/GatherCoreTests/Services/CollectionRepoTests.swift
// P1 下一波 §3.8：集合 / 堆栈 / 跨工作区重复的持久化与编排测试。
//
// 验收对应（设计 §3.8 / 任务卡）：
// 1. 排序单行写：拖拽只改被拖那一行的 position（前后中点），其它行 byte-for-byte 不变；
// 2. 间隙耗尽：相邻 position 差 < 2 时在同一事务内重排为 step 网格；
// 3. 显式重排：位置写 1..n；
// 4. 堆栈折叠：folds 只影响展示数据，封面 SET NULL 语义；
// 5. 跨会话组可见：同 checksum 跨两个工作区才成组，单会话内重复不成组。
//
// 夹具：makeTestDB()（内存库 + 当前 schema），与其它 repo 测试同口径。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

// MARK: - 纯数学

@Suite("集合 position 纯数学")
struct CollectionPositionsTests {
    @Test("尾部追加步长 1024")
    func appendStep() {
        #expect(CollectionPositions.appendPosition(last: nil) == 1024)
        #expect(CollectionPositions.appendPosition(last: 1024) == 2048)
    }

    @Test("中点：正常间隙取中点")
    func midpointBetween() {
        #expect(CollectionPositions.midpoint(previous: 1024, next: 2048) == 1536)
        #expect(CollectionPositions.midpoint(previous: nil, next: 10) == 5)
        #expect(CollectionPositions.midpoint(previous: 1024, next: nil) == 2048)
        #expect(CollectionPositions.midpoint(previous: nil, next: nil) == 1024)
    }

    @Test("中点：没有间隙时返回 nil（调用方重排）")
    func midpointNoGap() {
        #expect(CollectionPositions.midpoint(previous: 5, next: 6) == nil)
        #expect(CollectionPositions.midpoint(previous: 5, next: 5) == nil)
        #expect(CollectionPositions.midpoint(previous: 5, next: 4) == nil)
        #expect(CollectionPositions.midpoint(previous: nil, next: 1) == nil)
    }

    @Test("重排网格与 1..n")
    func grids() {
        #expect(CollectionPositions.spacedGrid(count: 3) == [1024, 2048, 3072])
        #expect(CollectionPositions.sequential(count: 3) == [1, 2, 3])
        #expect(CollectionPositions.spacedGrid(count: 0).isEmpty)
    }

    @Test("movedOrder 把被拖照片插到锚点之间")
    func movedOrder() {
        let order = ["a", "b", "c", "d"]
        #expect(
            CollectionPositions.movedOrder(order, photoId: "d", previousPhotoId: "a", nextPhotoId: "b")
                == ["a", "d", "b", "c"]
        )
        #expect(
            CollectionPositions.movedOrder(order, photoId: "a", previousPhotoId: nil, nextPhotoId: nil)
                == ["a", "b", "c", "d"]
        )
        #expect(
            CollectionPositions.movedOrder(order, photoId: "b", previousPhotoId: "c", nextPhotoId: nil)
                == ["a", "c", "b", "d"]
        )
    }
}

// MARK: - 夹具

private struct CurationFixture {
    let db: DBConnection
    let collections: CollectionRepo
    let stacks: StackRepo
    let duplicates: GlobalDuplicateQuery
    let service: CurationService

    init(photoCount: Int = 6) throws {
        db = try makeTestDB()
        try insertSession(db, "session-a")
        try insertSession(db, "session-b")
        for index in 0..<photoCount {
            try insertPhoto(db, id: "p\(index)", sessionId: "session-a", checksum: "checksum-\(index)")
        }
        collections = CollectionRepo(connection: db)
        stacks = StackRepo(connection: db)
        duplicates = GlobalDuplicateQuery(connection: db)
        service = CurationService(
            collections: CollectionRepo(connection: db),
            stacks: StackRepo(connection: db),
            duplicates: GlobalDuplicateQuery(connection: db),
            transactions: db)
    }

    func makeCollection(name: String = "Keepers") throws -> CollectionRow {
        try collections.create(
            sessionId: "session-a",
            name: name,
            sortOrder: collections.nextSortOrder(sessionId: "session-a")
        )
    }
}

// MARK: - 端口纪律（#8）

@Suite("CurationService 端口纪律")
struct CurationServicePortTests {
    /// 跨仓储事务必须经注入的 TransactionRunner，而不是服务自己拿连接开事务。
    ///
    /// 这条用例是 #8 的回归钉：CurationService 曾经持有 DBConnection 并直接
    /// 「connection.transaction { detach + create }」；端口化后如果谁把事务改回
    /// 「各自 repo 内部事务」，计数会变 0，用例先红。
    @Test("建栈/加成员/删成员各走一次注入的 TransactionRunner")
    func crossStoreTransactionsRouteThroughInjectedRunner() throws {
        let fixture = try CurationFixture()
        let counter = PortFakeTransactionRunner()
        let service = CurationService(
            collections: fixture.collections,
            stacks: fixture.stacks,
            duplicates: fixture.duplicates,
            transactions: counter)

        let stack = try service.createStack(
            StackCreateInput(sessionId: "session-a", name: "S", photoIds: ["p0", "p1"]))
        #expect(counter.transactionCount == 1, "createStack 必须恰好一次外层事务")

        _ = try service.addStackMembers(
            StackMembersInput(stackId: stack.id, photoIds: ["p2"]))
        #expect(counter.transactionCount == 2, "addStackMembers 必须恰好一次外层事务")

        _ = try service.removeStackMembers(
            StackMembersInput(stackId: stack.id, photoIds: ["p2"]))
        #expect(counter.transactionCount == 3, "removeStackMembers 必须恰好一次外层事务")
    }
}

// MARK: - 集合

@Suite("CollectionRepo 排序与成员")
struct CollectionRepoTests {
    @Test("新建集合按 sort_order 递增且 itemCount 为 0")
    func createAndList() throws {
        let fixture = try CurationFixture()
        let first = try fixture.makeCollection(name: "第一")
        let second = try fixture.makeCollection(name: "第二")
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
        #expect(first.itemCount == 0)
        let rows = try fixture.collections.list(sessionId: "session-a")
        #expect(rows.map(\.name) == ["第一", "第二"])
    }

    @Test("追加按步长 1024，重复追加不新增")
    func appendUsesStep() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        let inserted = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1", "p2"]
        )
        #expect(inserted == 3)
        let items = try fixture.collections.items(collectionId: collection.id)
        #expect(items.map(\.photoId) == ["p0", "p1", "p2"])
        #expect(items.map(\.position) == [1024, 2048, 3072])

        // 再次追加同样的照片：全部命中主键，新增 0 条。
        let again = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1", "p2"]
        )
        #expect(again == 0)
        #expect(try fixture.collections.items(collectionId: collection.id).count == 3)
    }

    @Test("拖拽只写 1 行：其它成员的 position 完全不变")
    func moveWritesSingleRow() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1", "p2", "p3"]
        )
        let before = try fixture.collections.items(collectionId: collection.id)
        let beforePositions = Dictionary(uniqueKeysWithValues: before.map { ($0.photoId, $0.position) })

        // 把 p3 拖到 p0 之后（p0 与 p1 之间）。
        let moved = try fixture.collections.moveItem(
            collectionId: collection.id,
            photoId: "p3",
            afterPhotoId: "p0",
            beforePhotoId: nil
        )
        #expect(moved)

        let after = try fixture.collections.items(collectionId: collection.id)
        #expect(after.map(\.photoId) == ["p0", "p3", "p1", "p2"])
        // 被拖的那一行 position = (1024 + 2048) / 2 = 1536。
        #expect(after.first { $0.photoId == "p3" }?.position == 1536)
        // 其它三行一字未动（这是"单行写"的硬断言）。
        for item in after where item.photoId != "p3" {
            #expect(item.position == beforePositions[item.photoId])
        }
    }

    @Test("拖到最前 / 最后")
    func moveToEdges() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1", "p2"]
        )
        let toFront = try fixture.collections.moveItem(
            collectionId: collection.id,
            photoId: "p2",
            afterPhotoId: nil,
            beforePhotoId: nil
        )
        #expect(toFront)
        #expect(try fixture.collections.items(collectionId: collection.id).first?.photoId == "p2")

        let toBack = try fixture.collections.moveItem(
            collectionId: collection.id,
            photoId: "p2",
            afterPhotoId: "p1",
            beforePhotoId: nil
        )
        #expect(toBack)
        #expect(try fixture.collections.items(collectionId: collection.id).last?.photoId == "p2")
    }

    @Test("间隙耗尽时事务内重排，顺序仍然正确")
    func moveCompactsWhenNoGap() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1", "p2", "p3"]
        )
        // 显式重排成 1..n（相邻差 1，没有中点可用）。
        _ = try fixture.collections.reorderItems(
            collectionId: collection.id,
            orderedPhotoIds: ["p0", "p1", "p2", "p3"]
        )
        #expect(try fixture.collections.items(collectionId: collection.id).map(\.position) == [1, 2, 3, 4])

        // 把 p3 拖到 p1 之前：既没法取中点，也不能复用相邻位置 → 必须重排。
        let moved = try fixture.collections.moveItem(
            collectionId: collection.id,
            photoId: "p3",
            afterPhotoId: nil,
            beforePhotoId: "p1"
        )
        #expect(moved)
        let items = try fixture.collections.items(collectionId: collection.id)
        #expect(items.map(\.photoId) == ["p0", "p3", "p1", "p2"])
        // 重排后位置唯一且单调；被拖行落在重排网格的中点（不要求仍是 1024 的倍数）。
        #expect(Set(items.map(\.position)).count == items.count)
        #expect(items.map(\.position) == items.map(\.position).sorted())
    }

    @Test("显式重排写 1..n")
    func reorderWritesSequential() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1", "p2"]
        )
        let written = try fixture.collections.reorderItems(
            collectionId: collection.id,
            orderedPhotoIds: ["p2", "p0", "p1"]
        )
        #expect(written == 3)
        let items = try fixture.collections.items(collectionId: collection.id)
        #expect(items.map(\.photoId) == ["p2", "p0", "p1"])
        #expect(items.map(\.position) == [1, 2, 3])
    }

    @Test("拖拽参照照片不在集合里 → false（服务层转 PHOTO_NOT_FOUND）")
    func moveUnknownAnchor() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1"]
        )
        #expect(try fixture.collections.moveItem(
            collectionId: collection.id,
            photoId: "p0",
            afterPhotoId: "p5",
            beforePhotoId: nil
        ) == false)
        #expect(try fixture.collections.moveItem(
            collectionId: collection.id,
            photoId: "p5",
            afterPhotoId: "p0",
            beforePhotoId: nil
        ) == false)
    }

    @Test("删除成员与同名预检")
    func removeAndNameExists() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection(name: "A")
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1"]
        )
        #expect(try fixture.collections.removeItems(
            collectionId: collection.id,
            photoIds: ["p0"]
        ) == 1)
        #expect(try fixture.collections.items(collectionId: collection.id).map(\.photoId) == ["p1"])
        #expect(try fixture.collections.nameExists(sessionId: "session-a", name: "A"))
        #expect(try fixture.collections.nameExists(
            sessionId: "session-a", name: "A", excluding: collection.id
        ) == false)
    }

    @Test("集合删除级联清空成员")
    func deleteCascades() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id,
            photoIds: ["p0", "p1"]
        )
        #expect(try fixture.collections.delete(id: collection.id))
        #expect(try fixture.collections.items(collectionId: collection.id).isEmpty)
        // FK 级联：collection_items 里不再有该集合的行。
        let rows = try fixture.db.prepare(
            "SELECT COUNT(*) FROM collection_items WHERE collection_id = ?"
        ).query([.text(collection.id)])
        #expect(rows.first?[0].intValue == 0)
    }
}

// MARK: - 堆栈

@Suite("StackRepo 折叠与封面")
struct StackRepoTests {
    @Test("建堆栈：成员按 position 递增，封面缺省取首个成员")
    func createStack() throws {
        let fixture = try CurationFixture()
        let row = try fixture.stacks.create(
            sessionId: "session-a",
            name: "连拍",
            coverPhotoId: nil,
            photoIds: ["p0", "p1", "p2"]
        )
        #expect(row.coverPhotoId == "p0")
        #expect(row.memberCount == 3)
        let members = try fixture.stacks.members(stackId: row.id)
        #expect(members.map(\.photoId) == ["p0", "p1", "p2"])
        #expect(members.map(\.position) == [1024, 2048, 3072])
    }

    @Test("空成员建堆栈被拒绝")
    func createEmptyStack() throws {
        let fixture = try CurationFixture()
        #expect(throws: (any Error).self) {
            _ = try fixture.stacks.create(
                sessionId: "session-a", name: "", coverPhotoId: nil, photoIds: []
            )
        }
    }

    @Test("移出封面成员 → 封面 SET NULL，展示回落首个成员")
    func coverClearedWhenMemberRemoved() throws {
        let fixture = try CurationFixture()
        let row = try fixture.stacks.create(
            sessionId: "session-a",
            name: "",
            coverPhotoId: nil,
            photoIds: ["p0", "p1", "p2"]
        )
        #expect(try fixture.stacks.removeMembers(stackId: row.id, photoIds: ["p0"]) == 1)
        let updated = try fixture.stacks.get(id: row.id)
        #expect(updated?.coverPhotoId == nil)
        let folds = try fixture.stacks.folds(sessionId: "session-a")
        #expect(folds.first?.coverPhotoId == nil)
        #expect(folds.first?.displayCoverPhotoId == "p1")
        #expect(folds.first?.hiddenMemberCount == 1)
    }

    @Test("折叠视图：成员按 position 排序，跨会话不串")
    func foldsAreSessionScoped() throws {
        let fixture = try CurationFixture()
        let row = try fixture.stacks.create(
            sessionId: "session-a", name: "", coverPhotoId: "p2", photoIds: ["p0", "p1", "p2"]
        )
        try insertPhoto(fixture.db, id: "q0", sessionId: "session-b")
        let other = try fixture.stacks.create(
            sessionId: "session-b", name: "", coverPhotoId: nil, photoIds: ["q0", "q0"]
        )
        let foldsA = try fixture.stacks.folds(sessionId: "session-a")
        #expect(foldsA.count == 1)
        #expect(foldsA.first?.stackId == row.id)
        #expect(foldsA.first?.photoIds == ["p0", "p1", "p2"])
        let foldsB = try fixture.stacks.folds(sessionId: "session-b")
        #expect(foldsB.first?.stackId == other.id)
        #expect(foldsB.first?.photoIds == ["q0"])
    }

    @Test("一照一堆栈：detachPhotos 摘走照片，空壳堆栈不保留")
    func detachRemovesEmptyStack() throws {
        let fixture = try CurationFixture()
        let row = try fixture.stacks.create(
            sessionId: "session-a", name: "", coverPhotoId: nil, photoIds: ["p0", "p1"]
        )
        #expect(try fixture.stacks.detachPhotos(photoIds: ["p0", "p1"]) == 2)
        #expect(try fixture.stacks.get(id: row.id) == nil)
        #expect(try fixture.stacks.stackIdsByPhoto(photoIds: ["p0"]).isEmpty)
    }

    @Test("服务层：建堆栈会把照片从旧堆栈摘走，且至少 2 张")
    func serviceCreateStackMovesPhotos() throws {
        let fixture = try CurationFixture()
        let first = try fixture.service.createStack(
            StackCreateInput(sessionId: "session-a", name: "旧", photoIds: ["p0", "p1"])
        )
        let second = try fixture.service.createStack(
            StackCreateInput(sessionId: "session-a", name: "新", photoIds: ["p1", "p2"])
        )
        #expect(second.memberCount == 2)
        let stackById = try fixture.stacks.stackIdsByPhoto(photoIds: ["p0", "p1", "p2"])
        #expect(stackById["p0"] == first.id)
        #expect(stackById["p1"] == second.id)
        #expect(stackById["p2"] == second.id)

        #expect(throws: CurationError.self) {
            _ = try fixture.service.createStack(
                StackCreateInput(sessionId: "session-a", name: "", photoIds: ["p0"])
            )
        }
    }
}

// MARK: - 跨工作区重复

@Suite("跨工作区重复（只读）")
struct GlobalDuplicateQueryTests {
    @Test("精确重复：跨两个工作区才成组，单会话内不报")
    func exactGroupsCrossSessions() throws {
        let fixture = try CurationFixture(photoCount: 0)
        try insertPhoto(fixture.db, id: "a1", sessionId: "session-a", checksum: "same")
        try insertPhoto(fixture.db, id: "b1", sessionId: "session-b", checksum: "same")
        try insertPhoto(fixture.db, id: "a2", sessionId: "session-a", checksum: "only-a")
        try insertPhoto(fixture.db, id: "a3", sessionId: "session-a", checksum: "only-a")

        let groups = try fixture.duplicates.exactGroups(minSessionCount: 2, limit: 100)
        #expect(groups.map(\.checksum) == ["same"])
        #expect(groups.first?.sessionCount == 2)
        #expect(groups.first?.photoCount == 2)

        let photos = try fixture.duplicates.photos(checksums: ["same"])
        #expect(photos.count == 2)
        #expect(Set(photos.map(\.sessionId)) == ["session-a", "session-b"])
        let names = Set(photos.map(\.sessionName))
        #expect(names == [""]) // 夹具的 sessions.name 是空串（insertSession）
    }

    @Test("未计算 checksum 单独计数")
    func missingChecksumCount() throws {
        let fixture = try CurationFixture(photoCount: 0)
        try insertPhoto(fixture.db, id: "a1", sessionId: "session-a", checksum: "x")
        try insertPhoto(fixture.db, id: "a2", sessionId: "session-a", checksum: "")
        #expect(try fixture.duplicates.totalPhotoCount() == 2)
        #expect(try fixture.duplicates.missingChecksumCount() == 1)
    }

    @Test("汉明距离按位计")
    func hammingDistance() {
        #expect(VisualHashBuckets.hammingDistance("0000", "0000") == 0)
        #expect(VisualHashBuckets.hammingDistance("0000", "000f") == 4)
        #expect(VisualHashBuckets.hammingDistance("ffff", "0000") == 16)
        #expect(VisualHashBuckets.hammingDistance("0000", "000") == nil)
        #expect(VisualHashBuckets.hammingDistance("0000", "00zz") == nil)
    }

    @Test("视觉桶内聚类：跨会话近似成簇，同会话不成簇")
    func visualClusters() throws {
        let rows = [
            row(photoId: "a1", sessionId: "s1", hash: "0000000000000000"),
            row(photoId: "b1", sessionId: "s2", hash: "0000000000000003"),
            row(photoId: "c1", sessionId: "s1", hash: "0000000000000001"),
            row(photoId: "d1", sessionId: "s1", hash: "ffffffffffffffff"),
        ]
        let clusters = try VisualHashBuckets.clusters(rows: rows, threshold: 14)
        // 前缀桶（前 8 hex = 00000000）内 a1/b1/c1 两两距离 ≤ 14 → 一簇；
        // ffffffff 前缀桶只有一张 → 不成簇。
        #expect(clusters.count == 1)
        #expect(clusters.first?.photoIds == ["a1", "b1", "c1"])
        #expect(clusters.first?.sessionIds == ["s1", "s2"])
        #expect(clusters.first?.degraded == false)
    }

    @Test("超过桶上限时降级为精确哈希分组并标记 degraded")
    func visualClustersDegrade() throws {
        var rows: [GlobalDuplicatePhotoRow] = []
        for index in 0..<4 {
            rows.append(row(photoId: "a\(index)", sessionId: "s1", hash: "000000000000000\(index)"))
        }
        // 上限 2：桶内 4 张 > 2 → 降级；精确哈希分组各只有 1 张 → 无簇。
        let clusters = try VisualHashBuckets.clusters(
            rows: rows, threshold: 14, maxBucketSize: 2
        )
        #expect(clusters.isEmpty)

        // 上限 2 且同哈希重复 → 降级后仍按精确 hash 成簇（并标 degraded）。
        var sameRows: [GlobalDuplicatePhotoRow] = []
        for index in 0..<3 {
            sameRows.append(row(photoId: "b\(index)", sessionId: "s\(index)", hash: "00000000000000aa"))
        }
        let degraded = try VisualHashBuckets.clusters(
            rows: sameRows, threshold: 14, maxBucketSize: 2
        )
        #expect(degraded.count == 1)
        #expect(degraded.first?.degraded == true)
    }

    @Test("服务层：扫描结果跨会话可见并进缓存，失效后重算")
    func serviceScan() throws {
        let fixture = try CurationFixture(photoCount: 0)
        try insertPhoto(fixture.db, id: "a1", sessionId: "session-a", checksum: "same")
        try insertPhoto(fixture.db, id: "b1", sessionId: "session-b", checksum: "same")
        let result = try fixture.service.scanGlobalDuplicates(
            GlobalDuplicateScanInput(includeVisual: false)
        )
        #expect(result.exactGroupCount == 1)
        #expect(result.groups.first?.members.count == 2)
        #expect(result.groups.first?.sessionCount == 2)
        #expect(result.missingChecksumCount == 0)
        #expect(result.truncated == false)
        #expect(result.scannedPhotoCount == 2)

        // 缓存命中：新增照片后不失效时仍是旧结果。
        try insertPhoto(fixture.db, id: "c1", sessionId: "session-b", checksum: "other")
        try insertPhoto(fixture.db, id: "d1", sessionId: "session-a", checksum: "other")
        let cached = try fixture.service.scanGlobalDuplicates(
            GlobalDuplicateScanInput(includeVisual: false)
        )
        #expect(cached.exactGroupCount == 1)
        fixture.service.invalidateGlobalDuplicateCache()
        let rescanned = try fixture.service.scanGlobalDuplicates(
            GlobalDuplicateScanInput(includeVisual: false)
        )
        #expect(rescanned.exactGroupCount == 2)
    }

    @Test("服务层：阈值/上限越界拒绝")
    func serviceValidatesInput() throws {
        let fixture = try CurationFixture(photoCount: 1)
        #expect(throws: CurationError.self) {
            _ = try fixture.service.scanGlobalDuplicates(
                GlobalDuplicateScanInput(includeVisual: true, visualThreshold: 15)
            )
        }
        #expect(throws: CurationError.self) {
            _ = try fixture.service.scanGlobalDuplicates(
                GlobalDuplicateScanInput(includeVisual: true, maxGroupCount: 0)
            )
        }
    }

    private func row(
        photoId: String,
        sessionId: String,
        hash: String
    ) -> GlobalDuplicatePhotoRow {
        GlobalDuplicatePhotoRow(
            photoId: photoId,
            sessionId: sessionId,
            sessionName: sessionId,
            filepath: "/tmp/\(photoId).jpg",
            filename: "\(photoId).jpg",
            checksum: "",
            checksumFileSize: 0,
            hashHex: hash
        )
    }
}

// MARK: - 服务层集合规则

@Suite("CurationService 集合规则")
struct CurationServiceCollectionTests {
    @Test("同名集合拒绝（nameConflict）")
    func duplicateNameRejected() throws {
        let fixture = try CurationFixture()
        _ = try fixture.service.createCollection(
            CollectionCreateInput(sessionId: "session-a", name: "A")
        )
        #expect(throws: CurationError.self) {
            _ = try fixture.service.createCollection(
                CollectionCreateInput(sessionId: "session-a", name: "A")
            )
        }
    }

    @Test("跨会话照片不能加入集合（PHOTO_NOT_FOUND）")
    func crossSessionPhotoRejected() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.service.createCollection(
            CollectionCreateInput(sessionId: "session-a", name: "A")
        )
        try insertPhoto(fixture.db, id: "b0", sessionId: "session-b")
        #expect(throws: CurationError.self) {
            _ = try fixture.service.addCollectionItems(
                CollectionItemsInput(collectionId: collection.id, photoIds: ["b0"])
            )
        }
        // 会话内照片正常加入。
        #expect(try fixture.service.addCollectionItems(
            CollectionItemsInput(collectionId: collection.id, photoIds: ["p0", "p1"])
        ) == 2)
    }

    @Test("集合不存在 → collectionNotFound（ALBUM_NOT_FOUND）")
    func missingCollection() throws {
        let fixture = try CurationFixture()
        #expect(throws: CurationError.self) {
            _ = try fixture.service.collectionItems(collectionId: "missing")
        }
        let error = CurationError.collectionNotFound("missing")
        #expect(error.code == .ALBUM_NOT_FOUND)
        #expect(error.params["collectionId"] == "missing")
    }
}

// MARK: - 可见性口径（P1-8）

/// 淘汰移出（`photos.archived_at` 非空）的照片**不得**出现在用户可见读面里，
/// 但"按 id 的显式操作"与"判空"必须看见全体成员——否则撤销/移回要重新加成员，
/// 而"成员全被淘汰"会被误判成空堆栈删掉。
@Suite("策展读面的可见性（P1-8）")
struct CurationVisibilityTests {
    @Test("集合成员与 itemCount 只算未淘汰照片；显式 id 操作仍能看见")
    func collectionHidesArchived() throws {
        let fixture = try CurationFixture()
        let collection = try fixture.makeCollection()
        _ = try fixture.collections.appendItems(
            collectionId: collection.id, photoIds: ["p0", "p1"])
        #expect(try fixture.collections.items(collectionId: collection.id).map(\.photoId) == ["p0", "p1"])
        #expect(try fixture.collections.get(id: collection.id)?.itemCount == 2)

        _ = try fixture.db.prepare("UPDATE photos SET archived_at = ? WHERE id = ?")
            .run([.text("2026-10-30T00:00:00.000Z"), .text("p0")])

        #expect(try fixture.collections.items(collectionId: collection.id).map(\.photoId) == ["p1"])
        #expect(try fixture.collections.get(id: collection.id)?.itemCount == 1)
        // 显式 id 路径不过滤：撤销/移回不需要重新加成员。
        #expect(try fixture.collections.contains(collectionId: collection.id, photoId: "p0"))
        #expect(try fixture.collections.memberPhotoIds(collectionId: collection.id) == ["p0", "p1"])
    }

    @Test("堆栈成员/折叠只算未淘汰照片；判空与封面校验看全体成员")
    func stackHidesArchivedButKeepsMembership() throws {
        let fixture = try CurationFixture()
        let stack = try fixture.stacks.create(
            sessionId: "session-a", name: "Burst", coverPhotoId: nil, photoIds: ["p0", "p1"])
        #expect(try fixture.stacks.members(stackId: stack.id).map(\.photoId) == ["p0", "p1"])

        _ = try fixture.db.prepare("UPDATE photos SET archived_at = ? WHERE id = ?")
            .run([.text("2026-10-30T00:00:00.000Z"), .text("p0")])

        #expect(try fixture.stacks.members(stackId: stack.id).map(\.photoId) == ["p1"])
        #expect(try fixture.stacks.folds(sessionId: "session-a")
            .first(where: { $0.stackId == stack.id })?.photoIds == ["p1"])
        // 判空/封面校验必须看全体成员：否则"成员全被淘汰"会被当成空堆栈删掉。
        #expect(try fixture.stacks.hasAnyMember(stackId: stack.id))
        #expect(try fixture.stacks.isMember(stackId: stack.id, photoId: "p0"))
    }
}
