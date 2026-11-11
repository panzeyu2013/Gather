// desktop/native/gather-app/Sources/GatherHost/Automation/GatherAutomationRuntime.swift
// Wave3 / task-21：Shortcuts / App Intents 的宿主运行时。
//
// 边界：
// - 只把已有 typed API（SessionAPI / ExportAPI / CullingAPI）包成可注入的闭包，
//   不新造服务、不复制业务规则；App Intents（GatherApp target）只依赖本文件的
//   public struct，因此 intents 不需要 import 四层 core；
// - 运行时由 AppBootstrap 在 scene 发布前安装（进程内唯一），未启动时
//   registry.current == nil，intents 显式报 runtimeUnavailable；
// - 所有闭包 @Sendable；错误沿用各 API 的渗错误（GatherError / 域错误），
//   App Intent 只负责把错误表面化。
import Foundation
import os
import GatherProtocol

/// Shortcuts 动作的运行时能力面（闭包注入，测试可直接构造假实现）。
public struct GatherAutomationRuntime: Sendable {
    /// 新建工作区并导入给定文件（返回 sessionId）。files 为绝对路径。
    public var createWorkspaceAndImport: @Sendable (_ name: String?, _ filepaths: [String]) async throws -> String
    /// 按工作区执行导出（返回 ExportResult）。
    public var exportSession: @Sendable (
        _ sessionId: String, _ destination: String, _ format: String,
        _ quality: Double?, _ maxDimension: Int?
    ) async throws -> ExportResult
    /// 按工作区写回元数据（rating / color_label / keyword）。
    public var writebackMetadata: @Sendable (_ sessionId: String, _ target: String) async throws -> GatherAutomationWritebackSummary
    /// 查询工作区状态（只读）。
    public var sessionStatus: @Sendable (_ sessionId: String) async throws -> GatherAutomationSessionStatus

    public init(
        createWorkspaceAndImport: @escaping @Sendable (_ name: String?, _ filepaths: [String]) async throws -> String,
        exportSession: @escaping @Sendable (
            _ sessionId: String, _ destination: String, _ format: String,
            _ quality: Double?, _ maxDimension: Int?
        ) async throws -> ExportResult,
        writebackMetadata: @escaping @Sendable (_ sessionId: String, _ target: String) async throws -> GatherAutomationWritebackSummary,
        sessionStatus: @escaping @Sendable (_ sessionId: String) async throws -> GatherAutomationSessionStatus
    ) {
        self.createWorkspaceAndImport = createWorkspaceAndImport
        self.exportSession = exportSession
        self.writebackMetadata = writebackMetadata
        self.sessionStatus = sessionStatus
    }
}

/// 写回结果的可读摘要（App Intent 的 dialog 用它，不需要感知 WritebackResult 全量字段）。
public struct GatherAutomationWritebackSummary: Equatable, Sendable {
    public var sessionId: String
    public var target: String
    public var written: Int
    public var failed: Int
    public var skipped: Int

    public init(sessionId: String, target: String, written: Int, failed: Int, skipped: Int) {
        self.sessionId = sessionId
        self.target = target
        self.written = written
        self.failed = failed
        self.skipped = skipped
    }
}

/// 工作区状态摘要（只读动作的返回值）。
public struct GatherAutomationSessionStatus: Equatable, Sendable {
    public var sessionId: String
    public var name: String
    public var photoCount: Int
    public var pendingXmp: Int
    public var writtenXmp: Int
    public var failedXmp: Int
    public var conflictXmp: Int
    public var reloadAckedAt: String?

    public init(
        sessionId: String,
        name: String,
        photoCount: Int,
        pendingXmp: Int,
        writtenXmp: Int,
        failedXmp: Int,
        conflictXmp: Int,
        reloadAckedAt: String?
    ) {
        self.sessionId = sessionId
        self.name = name
        self.photoCount = photoCount
        self.pendingXmp = pendingXmp
        self.writtenXmp = writtenXmp
        self.failedXmp = failedXmp
        self.conflictXmp = conflictXmp
        self.reloadAckedAt = reloadAckedAt
    }
}

/// 运行时安装点：进程内唯一（AppBootstrap 启动后写入；退出不清理，进程结束即释放）。
///
/// 用 OSAllocatedUnfairLock 而不是全局 var：Swift 6 禁止可变全局状态；
/// 锁保护的是 Sendable 值（整个 struct 都是 @Sendable 闭包/值类型）。
public enum GatherAutomationRuntimeRegistry {
    private static let storage = OSAllocatedUnfairLock<GatherAutomationRuntime?>(initialState: nil)

    public static var current: GatherAutomationRuntime? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// 测试/启动失败清理。
    public static func reset() {
        storage.withLock { $0 = nil }
    }
}

/// Shortcuts 动作的稳定错误（App Intents 直接抛这个，UI 显示 errorDescription）。
public enum GatherAutomationError: Error, LocalizedError, Equatable, Sendable {
    case runtimeUnavailable
    case noFiles
    case unsupportedFormat(String)
    case unsupportedTarget(String)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Gather 尚未完成启动；请先打开应用再运行此动作。"
        case .noFiles:
            return "没有可导入的文件。"
        case .unsupportedFormat(let raw):
            return "不支持的导出格式：\(raw)。"
        case .unsupportedTarget(let raw):
            return "不支持的写回目标：\(raw)。"
        }
    }
}
