// Tests/GatherCoreTests/API/AssetsCommandsImplTests.swift
// R5：assets 域命令实现直测（批次 B6）。
// 覆盖命令边界语义：candidates 的会话过滤透传、accept_candidate /
// reject_candidate / relink_root 的 confirmed 门控与错误码、volumes 透传、
// relink_root 的计数承接（Int）与存储错误透传。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 存储桩

/// 资产存储桩：记录命令边界传入的调用，并按注入结果作答；
/// 未参与命令边界的协议方法给空实现（只服务于本域直测）。
private actor AssetStoreStub: AssetStore {
    private let candidateRows: [AssetLinkCandidateData]
    private let volumeRows: [AssetVolumeData]
    private let relinkOutcome: AssetRelinkRootResult
    private let failing: Bool
    private(set) var candidateQueries: [String?] = []
    private(set) var acceptedIds: [String] = []
    private(set) var rejectedIds: [String] = []
    private(set) var relinkCalls: [(oldRoot: String, newRoot: String)] = []

    init(
        candidates: [AssetLinkCandidateData] = [],
        volumes: [AssetVolumeData] = [],
        relink: AssetRelinkRootResult = AssetRelinkRootResult(
            relocatedFiles: 0, relocatedOutboxPaths: []),
        failing: Bool = false
    ) {
        self.candidateRows = candidates
        self.volumeRows = volumes
        self.relinkOutcome = relink
        self.failing = failing
    }

    func memberRoles(sessionId: String, photoIds: [String]) async throws -> [String: String] { [:] }

    func listCandidates(sessionId: String?) async throws -> [AssetLinkCandidateData] {
        candidateQueries.append(sessionId)
        if failing { throw AssetStoreError.candidateNotFound }
        return candidateRows
    }

    func listVolumes() async throws -> [AssetVolumeData] {
        if failing { throw AssetStoreError.fileNotLinked }
        return volumeRows
    }

    func assetFile(id: String) async throws -> AssetFileRecord? { nil }

    func assetFileStatsBySession(sessionId: String) async throws -> [String: AssetFileScanBaseline] { [:] }

    func relinkRoot(oldRoot: String, newRoot: String) async throws -> AssetRelinkRootResult {
        relinkCalls.append((oldRoot: oldRoot, newRoot: newRoot))
        if failing { throw AssetStoreError.fileNotLinked }
        return relinkOutcome
    }

    func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        fileIdentity: String
    ) async throws -> AssetRelinkFileResult? { nil }

    func acceptCandidate(_ candidateId: String) async throws {
        acceptedIds.append(candidateId)
        if failing { throw AssetStoreError.candidateNotFound }
    }

    func rejectCandidate(_ candidateId: String) async throws {
        rejectedIds.append(candidateId)
        if failing { throw AssetStoreError.candidateNotFound }
    }

    func reconcileRawJpegLinks(sessionId: String) async throws -> Int64 { 0 }

    func markAssetFilesOffline(ids: [String], updatedAt: String) async throws -> Int { 0 }

    func applyScannedFiles(
        _ updates: [AssetFileScanUpdate], sessionId: String
    ) async throws -> [String] { [] }

    @discardableResult
    func invalidatePathDependentAnalysis(photoIds: [String]) async throws -> Int { 0 }

    func backfillSession(_ sessionId: String) async throws -> AssetBackfillResult {
        AssetBackfillResult(migrated: 0, offline: 0, candidates: 0)
    }
}

// MARK: - 夹具

private func candidate(
    _ id: String,
    status: AssetLinkCandidateStatus = .pending
) -> AssetLinkCandidateData {
    AssetLinkCandidateData(
        id: id,
        leftFileId: "\(id)-left",
        rightFileId: "\(id)-right",
        leftPath: "/photos/\(id).nef",
        rightPath: "/photos/\(id).jpg",
        confidence: 0.85,
        status: status,
        evidence: ["unambiguous": .bool(true)]
    )
}

private func volume(_ id: String, online: Int, offline: Int) -> AssetVolumeData {
    AssetVolumeData(
        volumeId: id, roots: ["/Volumes/\(id)"], onlineFiles: online, offlineFiles: offline)
}

// MARK: - 用例

@Suite("API/AssetsCommandsImpl (R5)")
struct AssetsCommandsImplTests {
    @Test("candidates passes the session filter through and returns the store rows")
    func candidatesPassThrough() async throws {
        let stub = AssetStoreStub(candidates: [candidate("c1"), candidate("c2", status: .accepted)])
        let impl = AssetsCommandsImpl(assets: stub)

        let scoped = try await impl.candidates(AssetCandidateListParams(sessionId: "s1"))
        #expect(scoped.map(\.id) == ["c1", "c2"])
        #expect(scoped.map(\.status) == [.pending, .accepted])

        let all = try await impl.candidates(AssetCandidateListParams(sessionId: nil))
        #expect(all.count == 2)

        let queries = await stub.candidateQueries
        #expect(queries == ["s1", nil])
    }

    @Test("candidates propagates the store failure")
    func candidatesPropagatesFailure() async throws {
        let impl = AssetsCommandsImpl(assets: AssetStoreStub(failing: true))
        await #expect(throws: AssetStoreError.candidateNotFound) {
            _ = try await impl.candidates(AssetCandidateListParams(sessionId: nil))
        }
    }

    @Test("acceptCandidate gates on confirmed and forwards the candidate id")
    func acceptCandidateGate() async throws {
        let stub = AssetStoreStub()
        let impl = AssetsCommandsImpl(assets: stub)

        do {
            try await impl.acceptCandidate(
                AssetCandidateMutationParams(candidateId: "c1", confirmed: false))
            Issue.record("confirmed=false 应抛 ASSET_LINK_ACCEPT_CONFIRM_REQUIRED")
        } catch let error as AssetsCommandsError {
            #expect(error == .acceptConfirmRequired)
            #expect(error.description == "ASSET_LINK_ACCEPT_CONFIRM_REQUIRED")
            #expect(error.gatherCode == .ASSET_LINK_ACCEPT_CONFIRM_REQUIRED)
        }
        #expect(await stub.acceptedIds.isEmpty)

        try await impl.acceptCandidate(
            AssetCandidateMutationParams(candidateId: "c1", confirmed: true))
        #expect(await stub.acceptedIds == ["c1"])
    }

    @Test("acceptCandidate propagates the store failure")
    func acceptCandidatePropagatesFailure() async throws {
        let impl = AssetsCommandsImpl(assets: AssetStoreStub(failing: true))
        await #expect(throws: AssetStoreError.candidateNotFound) {
            try await impl.acceptCandidate(
                AssetCandidateMutationParams(candidateId: "c1", confirmed: true))
        }
    }

    @Test("rejectCandidate gates on confirmed and forwards the candidate id")
    func rejectCandidateGate() async throws {
        let stub = AssetStoreStub()
        let impl = AssetsCommandsImpl(assets: stub)

        do {
            try await impl.rejectCandidate(
                AssetCandidateMutationParams(candidateId: "c2", confirmed: false))
            Issue.record("confirmed=false 应抛 ASSET_LINK_REJECT_CONFIRM_REQUIRED")
        } catch let error as AssetsCommandsError {
            #expect(error == .rejectConfirmRequired)
            #expect(error.description == "ASSET_LINK_REJECT_CONFIRM_REQUIRED")
            #expect(error.gatherCode == .ASSET_LINK_REJECT_CONFIRM_REQUIRED)
        }
        #expect(await stub.rejectedIds.isEmpty)

        try await impl.rejectCandidate(
            AssetCandidateMutationParams(candidateId: "c2", confirmed: true))
        #expect(await stub.rejectedIds == ["c2"])
    }

    @Test("volumes returns the store rows and propagates failures")
    func volumesPassThrough() async throws {
        let stub = AssetStoreStub(volumes: [volume("dev:1", online: 4, offline: 1)])
        let impl = AssetsCommandsImpl(assets: stub)

        let rows = try await impl.volumes()
        #expect(rows.map(\.volumeId) == ["dev:1"])
        #expect(rows[0].onlineFiles == 4)
        #expect(rows[0].offlineFiles == 1)

        let failing = AssetsCommandsImpl(assets: AssetStoreStub(failing: true))
        await #expect(throws: AssetStoreError.fileNotLinked) {
            _ = try await failing.volumes()
        }
    }

    @Test("relinkRoot gates on confirmed and returns the relocated count")
    func relinkRootGate() async throws {
        let stub = AssetStoreStub(relink: AssetRelinkRootResult(
            relocatedFiles: 3, relocatedOutboxPaths: ["/new/a.xmp"]))
        let impl = AssetsCommandsImpl(assets: stub)

        do {
            _ = try await impl.relinkRoot(AssetRelinkRootParams(
                oldRoot: "/old", newRoot: "/new", confirmed: false))
            Issue.record("confirmed=false 应抛 ASSET_RELINK_CONFIRM_REQUIRED")
        } catch let error as AssetsCommandsError {
            #expect(error == .relinkConfirmRequired)
            #expect(error.description == "ASSET_RELINK_CONFIRM_REQUIRED")
            #expect(error.gatherCode == .ASSET_RELINK_CONFIRM_REQUIRED)
        }
        #expect(await stub.relinkCalls.isEmpty)

        let count = try await impl.relinkRoot(AssetRelinkRootParams(
            oldRoot: "/old", newRoot: "/new", confirmed: true))
        #expect(count == 3, "旧 number 计数以 Int 承接（不含 outbox 路径）")

        let calls = await stub.relinkCalls
        #expect(calls.map { $0.oldRoot } == ["/old"])
        #expect(calls.map { $0.newRoot } == ["/new"])
    }
}
