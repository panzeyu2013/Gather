// desktop/native/gather-app/Tests/GatherAppTests/Support/StubSessionAPI.swift
// Cut 1 / B8.2a：SessionAPI 的类型化替身（B8.1a 未覆盖会话域）。
//
// 取代已删除的测试同步命令适配层（字符串命令 + [String: JSONValue] 响应表）：
// SessionControlViewModel /
// SettingsViewModel 改持 SessionAPI 后，用例只需注入 SessionData /
// WorkspaceStatus 夹具，断言只看类型化调用记录，不再断言命令名。
//
// 其余 5 个方法（create/update/delete/addPhotos）页面不调用，直接抛
// INVALID_PARAM 让「误调用」显式失败，而不是静默返回空数据。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

struct StubSessionState {
    var sessions: [SessionData] = []
    /// session.get 的夹具（nil = 按 sessions 里的同 id 项查找）。
    var session: SessionData?
    var status: WorkspaceStatus?
    var listError: (any Error)?
    var getError: (any Error)?
    var statusError: (any Error)?
    var listCalls = 0
    var getCalls: [String] = []
    var statusCalls: [String] = []
}

/// 可配置 SessionAPI：默认 get/status 按会话夹具返回、list 返回夹具数组。
@dynamicMemberLookup
final class B8SessionAPIStub: SessionAPI, @unchecked Sendable {
    private let box = LockedBox(StubSessionState())

    /// 状态字段经 LockedBox 动态转发：与逐属性访问器同一把锁、同一份状态；
    /// 测试侧原有的赋值（记录数组/错误注入）语义不变。
    subscript<T>(dynamicMember keyPath: WritableKeyPath<StubSessionState, T>) -> T {
        get { box.lock.withLock { box[dynamicMember: keyPath] } }
        set { box.lock.withLock { box[dynamicMember: keyPath] = newValue } }
    }

    init(sessions: [SessionData] = [], session: SessionData? = nil, status: WorkspaceStatus? = nil) {
        box.lock.withLock {
            box.sessions = sessions
            box.session = session
            box.status = status
        }
    }

    var status: WorkspaceStatus? {
        get { box.lock.withLock { box.status } }
        set { box.lock.withLock { box.status = newValue } }
    }

    func list() async throws -> [SessionData] {
        let (error, sessions): ((any Error)?, [SessionData]) = box.lock.withLock {
            box.listCalls += 1
            return (box.listError, box.sessions)
        }
        if let error { throw error }
        return sessions
    }

    func get(_ sessionId: String) async throws -> SessionData {
        let (error, configured, sessions): ((any Error)?, SessionData?, [SessionData]) = box.lock.withLock {
            box.getCalls.append(sessionId)
            return (box.getError, box.session, box.sessions)
        }
        if let error { throw error }
        if let configured { return configured }
        if let match = sessions.first(where: { $0.id == sessionId }) { return match }
        throw GatherError(code: .SESSION_NOT_FOUND)
    }

    // P1 / D：摄取（stub：不碰文件系统，直接回报 0 登记）。
    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        SessionIngestResult(registered: 0, copiedButUnregistered: [], skipped: [], failed: [])
    }

    func status(_ sessionId: String) async throws -> WorkspaceStatus {
        let (error, status): ((any Error)?, WorkspaceStatus?) = box.lock.withLock {
            box.statusCalls.append(sessionId)
            return (box.statusError, box.status)
        }
        if let error { throw error }
        guard let status else { throw GatherError(code: .SESSION_NOT_FOUND) }
        return status
    }

    // MARK: - 页面未使用的方法（误调用即显式失败）

    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        throw Self.unsupported("create")
    }

    func setSourceRoot(_ input: Confirmed<SessionSetSourceRootInput>) async throws -> SessionData {
        throw Self.unsupported("setSourceRoot")
    }

    func update(_ input: SessionUpdateParams) async throws -> SessionData {
        throw Self.unsupported("update")
    }

    func delete(_ input: Confirmed<SessionDeleteInput>) async throws {
        throw Self.unsupported("delete")
    }

    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        throw Self.unsupported("addPhotos")
    }

    private static func unsupported(_ method: String) -> GatherError {
        GatherError.invalidParameter(field: "sessionAPI", reason: "stub does not implement \(method)")
    }
}
