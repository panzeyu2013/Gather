import Foundation

// 自 Services/ExportService.swift 迁移（R2/W2d-4 语义承接）：导出进度/续传契约类型，声明逐字保留。

public struct NativeExportProgress: Equatable, Sendable {
    public let sessionId: String
    public let current: Int
    public let total: Int
    public let fileName: String
    public let bytesWritten: Int
    public let status: String
    public let errorMessage: String?

    public init(
        sessionId: String,
        current: Int,
        total: Int,
        fileName: String,
        bytesWritten: Int,
        status: String,
        errorMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.current = current
        self.total = total
        self.fileName = fileName
        self.bytesWritten = bytesWritten
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct NativeExportResumeState {
    public var destinations: [String: String]
    public var completedPhotoIds: Set<String>
    public var onPlanned: ((String, String) -> Void)?
    public var onPlanReady: (() -> Void)?
    public var onCompleted: ((String) -> Void)?

    public init(
        destinations: [String: String] = [:],
        completedPhotoIds: Set<String> = [],
        onPlanned: ((String, String) -> Void)? = nil,
        onPlanReady: (() -> Void)? = nil,
        onCompleted: ((String) -> Void)? = nil
    ) {
        self.destinations = destinations
        self.completedPhotoIds = completedPhotoIds
        self.onPlanned = onPlanned
        self.onPlanReady = onPlanReady
        self.onCompleted = onCompleted
    }
}
