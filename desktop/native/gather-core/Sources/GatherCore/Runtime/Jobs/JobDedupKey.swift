// desktop/native/gather-core/Sources/GatherCore/Runtime/Jobs/JobDedupKey.swift
// R3：作业去重键（单飞键）策略的唯一来源——旧 JobService/SessionCommandRouter 各自
// 拼字符串的 dedupeKey 语义收敛到本文件。
//
// 规则（计划 §R3 / 审计 7.1-4）：
// 1) 同 key：create 复用既有活跃作业行，调用方共享同一在飞结果；
// 2) 同资源（type + scopeType + scopeId）但不同 key：新的 create 抛 busy，
//    不静默复用到别的目标的作业；
// 3) export.execute 的 key 必须把「目标摘要」（导出 options 的规范化 JSON
//    指纹）纳入 qualifier —— 旧键只有 export.execute:<sessionId>，换目标导出
//    会命中同一活跃行/同一完成结果（审计 7.1-4）。
//
// 键字符串保持旧格式逐字兼容：rawValue == "<type>:<scopeId>[:<qualifier>]"
// （既有调用方传入的 dedupeKey 非空时原样沿用，仅做资源归类）。

import Foundation

/// 作业资源标识：同一 (type, scopeType, scopeId) 视为同一份资源（单飞粒度）。
public struct JobResource: Hashable, Sendable {
    public let type: AnalysisJobType
    public let scopeType: String
    public let scopeId: String

    public init(type: AnalysisJobType, scopeType: String, scopeId: String) {
        self.type = type
        self.scopeType = scopeType
        self.scopeId = scopeId
    }
}

/// 去重键：rawValue 是写入 analysis_jobs.dedupe_key 的权威字符串。
public struct JobDedupKey: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let resource: JobResource
    /// 附加限定维度（export 的目标摘要等）；nil/空表示无附加维度。
    public let qualifier: String?

    public init(type: AnalysisJobType, scopeType: String, scopeId: String, qualifier: String? = nil) {
        let normalized = qualifier.flatMap { $0.isEmpty ? nil : $0 }
        self.resource = JobResource(type: type, scopeType: scopeType, scopeId: scopeId)
        self.qualifier = normalized
        self.rawValue = Self.compose(type: type, scopeId: scopeId, qualifier: normalized)
    }

    private init(rawValue: String, resource: JobResource, qualifier: String?) {
        self.rawValue = rawValue
        self.resource = resource
        self.qualifier = qualifier
    }

    public var description: String { rawValue }

    /// 旧格式：type:scopeId[:qualifier]（qualifier 为空时与旧键逐字一致）。
    public static func compose(type: AnalysisJobType, scopeId: String, qualifier: String?) -> String {
        var value = type.rawValue + ":" + scopeId
        if let qualifier, !qualifier.isEmpty {
            value += ":" + qualifier
        }
        return value
    }

    /// 由既有 JobCreateParams 归一化：
    /// - dedupeKey 非空：原样作为 rawValue（保持旧键字符串），qualifier 解析失败视为无；
    /// - dedupeKey 为空：回退 type:scopeId（旧库部分唯一索引不接受空键并发）。
    public static func resolve(_ params: JobCreateParams) -> JobDedupKey {
        let resource = JobResource(type: params.type, scopeType: params.scopeType, scopeId: params.scopeId)
        let raw = params.dedupeKey
        guard !raw.isEmpty else {
            let fallback = compose(type: params.type, scopeId: params.scopeId, qualifier: nil)
            return JobDedupKey(rawValue: fallback, resource: resource, qualifier: nil)
        }
        let prefix = params.type.rawValue + ":" + params.scopeId
        var qualifier: String?
        if raw == prefix {
            qualifier = nil
        } else if raw.hasPrefix(prefix + ":") {
            qualifier = String(raw.dropFirst(prefix.count + 1))
        } else {
            // 调用方提供了自定义键（与 type:scopeId 前缀不同）：无附加维度可解析。
            qualifier = nil
        }
        return JobDedupKey(rawValue: raw, resource: resource, qualifier: qualifier)
    }

    /// export.execute 专用：目标摘要进入 qualifier，换目标即换 key。
    public static func export(sessionId: String, targetSummary: String) -> JobDedupKey {
        JobDedupKey(
            type: .exportExecute,
            scopeType: "session",
            scopeId: sessionId,
            qualifier: targetSummary)
    }

    /// 导出目标摘要：任意 Encodable（ExportOptions 等）的规范化 JSON（键排序）
    /// 的 SHA-256 十六进制。字段顺序/字典序不影响结果，字段值变化必然变 key。
    public static func exportTargetSummary<Options: Encodable>(_ options: Options) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(options)
        return digest(data)
    }

    /// 数据摘要（SHA-256 十六进制小写）。
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
    }
}
