// desktop/native/gather-app/Tests/GatherAppTests/StackAndVolumeWiringTests.swift
// Wave1 · task-9：堆栈管理（加入/移出/重命名/取消堆叠）与「卷重连结果可见」的接线测试。
//
// 覆盖点（对应 05 册 §1.3 / §1.4「API 有 / UI 无」）：
// - 四个写命令真的打到 AlbumAPI（参数逐字断言）；
// - 取消堆叠必须由确认分支驱动：未确认 → 零命令 + 本地可见错误，确认 → Confirmed(source: .userDialog)；
// - 空白堆栈名在本地拒绝，不发命令；
// - 卷重连把服务端返回的改写文件数落进 lastRelink（0 也必须可见，那是"选错根目录"的信号）。
import Foundation
import Testing
@testable import GatherUI
@testable import GatherProtocol
import GatherTestSupport

// MARK: - 测试替身

/// Gallery 数据端口：本套件只用到堆栈写命令，分页恒空。
private struct StackTestGalleryProvider: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? { nil }

    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) { ([], nil) }
}

/// AlbumAPI 替身：记录堆栈写命令；堆栈/折叠列表由测试预置。
private struct StackTestAlbumAPI: AlbumAPI {
    struct State {
        var stacks: [StackSummary] = []
        var folds: [StackFold] = []
        var updates: [StackUpdateInput] = []
        var deletes: [Confirmed<StackDeleteInput>] = []
        var added: [StackMembersInput] = []
        var removed: [StackMembersInput] = []
    }

    let box: LockedBox<State>

    // 基线 5 方法（本套件不涉及）
    func create(_ input: AlbumCreateParams) async throws -> SmartAlbumDetailData {
        throw GatherError(code: .INVALID_PARAM)
    }

    func list() async throws -> [SmartAlbumData] { [] }

    func update(_ input: AlbumUpdateParams) async throws {}

    func delete(_ input: Confirmed<AlbumDeleteInput>) async throws {}

    func photos(_ query: AlbumPhotosQuery) async throws -> GlobalPhotoPage {
        throw GatherError(code: .INVALID_PARAM)
    }

    // 堆栈
    func stacks(_ sessionId: String) async throws -> [StackSummary] {
        box.lock.withLock { box.stacks }
    }

    func stackFolds(_ sessionId: String) async throws -> [StackFold] {
        box.lock.withLock { box.folds }
    }

    func updateStack(_ input: StackUpdateInput) async throws {
        box.lock.withLock {
            box.updates.append(input)
            // 服务端语义：改名后折叠视图里的名字同步（本套件断言刷新结果）。
            if let name = input.name {
                for index in box.stacks.indices where box.stacks[index].id == input.stackId {
                    box.stacks[index].name = name
                }
                for index in box.folds.indices where box.folds[index].stackId == input.stackId {
                    box.folds[index].name = name
                }
            }
        }
    }

    func deleteStack(_ input: Confirmed<StackDeleteInput>) async throws {
        box.lock.withLock {
            box.deletes.append(input)
            box.stacks.removeAll { $0.id == input.value.stackId }
            box.folds.removeAll { $0.stackId == input.value.stackId }
        }
    }

    func addStackMembers(_ input: StackMembersInput) async throws -> Int {
        box.lock.withLock { box.added.append(input) }
        return input.photoIds.count
    }

    func removeStackMembers(_ input: StackMembersInput) async throws -> Int {
        box.lock.withLock { box.removed.append(input) }
        return input.photoIds.count
    }
}

/// Library 数据端口：只需 relinkAssetRoot 返回固定改写数。
private struct RelinkTestLibraryProvider: LibraryDataProvider {
    let rewritten: Int

    func listSessions() async throws -> [SessionData] { [] }

    func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) { ([], 0) }

    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) async throws -> Int {
        rewritten
    }
}

// MARK: - 夹具

@MainActor
private func makeStackFixtures() -> (GalleryViewModel, StackTestAlbumAPI) {
    var fold = StackFold(stackId: "stk1", photoIds: ["p1", "p2"])
    fold.name = ""
    let album = StackTestAlbumAPI(box: LockedBox(StackTestAlbumAPI.State(
        stacks: [
            StackSummary(id: "stk1", sessionId: "s1", name: "", memberCount: 2),
            StackSummary(id: "stk2", sessionId: "s1", name: "备选", memberCount: 3),
        ],
        folds: [fold, StackFold(stackId: "stk2", name: "备选", photoIds: ["p3", "p4", "p5"])]
    )))
    let viewModel = GalleryViewModel(
        sessionId: "s1",
        provider: StackTestGalleryProvider(),
        job: B5bJobAPIStub(),
        album: album,
        debounceDelay: .milliseconds(1)
    )
    return (viewModel, album)
}

// MARK: - 堆栈写命令接线

@MainActor
@Suite("Wave1 堆栈管理接线（task-9）")
struct StackWiringTests {

    @Test func refreshLoadsStacksAndFolds() async {
        let (viewModel, _) = makeStackFixtures()
        await viewModel.refreshStackFolds()
        #expect(viewModel.stacks.map(\.id) == ["stk1", "stk2"])
        #expect(viewModel.stackFolds.badgeCount(for: "p1") == 2)
    }

    @Test func selectionToStacksDeduplicates() async {
        let (viewModel, _) = makeStackFixtures()
        await viewModel.refreshStackFolds()
        let folds = viewModel.folds(for: ["p1", "p3", "p1"])
        #expect(folds.map(\.stackId) == ["stk1", "stk2"],
                "同一堆栈只出现一次，顺序按选中序列首次出现")
    }

    @Test func renameStackTrimsNameAndRefreshes() async throws {
        let (viewModel, album) = makeStackFixtures()
        await viewModel.refreshStackFolds()

        await viewModel.renameStack(stackId: "stk1", name: "  客户 A  ")

        let updates = album.box.lock.withLock { album.box.updates }
        #expect(updates == [StackUpdateInput(stackId: "stk1", name: "客户 A")])
        #expect(viewModel.actionError == nil)
        #expect(viewModel.stacks.first(where: { $0.id == "stk1" })?.name == "客户 A")
    }

    @Test func blankStackNameIsRejectedLocally() async {
        let (viewModel, album) = makeStackFixtures()
        await viewModel.renameStack(stackId: "stk1", name: "   ")

        #expect(album.box.lock.withLock { album.box.updates }.isEmpty, "空白名不发命令")
        #expect(viewModel.actionError?.origin == .localValidation)
    }

    @Test func addAndRemoveMembersSendExactIds() async {
        let (viewModel, album) = makeStackFixtures()

        await viewModel.addToStack(stackId: "stk2", photoIds: ["p1"])
        await viewModel.removeFromStack(stackId: "stk1", photoIds: ["p2"])

        #expect(album.box.lock.withLock { album.box.added } == [
            StackMembersInput(stackId: "stk2", photoIds: ["p1"]),
        ])
        #expect(album.box.lock.withLock { album.box.removed } == [
            StackMembersInput(stackId: "stk1", photoIds: ["p2"]),
        ])
        #expect(viewModel.actionError == nil)
    }

    @Test func dissolveRequiresConfirmation() async {
        let (viewModel, album) = makeStackFixtures()

        await viewModel.dissolveStack(stackId: "stk1", confirmed: false)
        #expect(album.box.lock.withLock { album.box.deletes }.isEmpty,
                "未确认不得发 deleteStack")
        #expect(viewModel.actionError?.origin == .localValidation)

        await viewModel.dissolveStack(stackId: "stk1", confirmed: true)
        let deletes = album.box.lock.withLock { album.box.deletes }
        #expect(deletes.map(\.value.stackId) == ["stk1"])
        #expect(deletes.map(\.source) == [.userDialog],
                "Confirmed 只能从确认分支构造")
        #expect(viewModel.actionError == nil)
    }
}

// MARK: - 卷重连结果可见

@MainActor
@Suite("Wave1 卷重连结果可见（task-9）")
struct VolumeRelinkWiringTests {

    @Test func relinkSurfacesRewrittenFileCount() async {
        let viewModel = LibraryViewModel(provider: RelinkTestLibraryProvider(rewritten: 128))
        await viewModel.relinkVolume(
            root: "/Volumes/A", newRoot: "/Users/me/A", confirmed: true)

        #expect(viewModel.lastRelink == LibraryRelinkOutcome(
            oldRoot: "/Volumes/A", newRoot: "/Users/me/A", fileCount: 128))
        #expect(viewModel.actionError == nil)
    }

    @Test func relinkZeroFilesIsStillVisible() async {
        let viewModel = LibraryViewModel(provider: RelinkTestLibraryProvider(rewritten: 0))
        await viewModel.relinkVolume(
            root: "/Volumes/A", newRoot: "/Users/me/B", confirmed: true)

        // 0 不是"没有结果"：多为一根目录选错，界面必须能提示。
        #expect(viewModel.lastRelink?.fileCount == 0)
        #expect(viewModel.lastRelink != nil)
    }
}
