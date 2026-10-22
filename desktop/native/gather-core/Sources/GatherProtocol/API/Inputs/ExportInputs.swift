// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/ExportInputs.swift
// Cut 1 / 阶段 1A：ExportAPI 输入（export.* 4 条 -> 4 个方法）。
//
// 对应命令：export.preview / execute / cancel / report。
// 校验归属：
// - export.execute 为破坏性入口，使用 Confirmed<ExportInput>；preview 复用同一输入；
// - options 为 nil 时由 1B 实现按旧行为构造空对象默认值（旧 export.ipc 的 {} 分支）；
//   解码失败由 1B 收敛为 EXPORT_PARAMS_INVALID；
// - reportType 目前是自由字符串（G8 待补枚举），这里只做长度/非空白；
// - format 使用 ReportFormat 枚举，未知值解码期失败。

import Foundation

/// export.preview / export.execute 的统一输入。
public struct ExportInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    /// nil = 旧命令的“空对象”语义，由 API 实现补默认值。
    public let options: ExportOptions?

    public init(sessionId: String, options: ExportOptions? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            options: try container.decodeIfPresent(ExportOptions.self, forKey: .options)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, options
    }
}

/// export.report 的输入（reportType 缺省 session_summary）。
public struct ExportReportInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let reportType: String
    public let format: ReportFormat?

    public init(sessionId: String, reportType: String = "session_summary", format: ReportFormat? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.reportType = try APIValidation.nonBlank(reportType, field: "reportType", maxLength: 128)
        self.format = format
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            reportType: try container.decodeIfPresent(String.self, forKey: .reportType) ?? "session_summary",
            format: try container.decodeIfPresent(ReportFormat.self, forKey: .format)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, reportType, format
    }
}
