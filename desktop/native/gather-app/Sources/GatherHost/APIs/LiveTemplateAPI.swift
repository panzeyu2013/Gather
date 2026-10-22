// desktop/native/gather-app/Sources/GatherHost/APIs/LiveTemplateAPI.swift
// Cut 1 / B7a：TemplateAPI 的 Live 实现（6 个方法；D-008 保留）。
//
// 对应命令（6 条）：template.create / list / get / update / delete / apply。
// 当前 UI 0 调用（ROADMAP 4.2 预留 typed API）；B7a 只落实现，不接页面。
//
// 校验归属：
// - create / update 复用 TemplateCreateParams / TemplateUpdateParams；config 已
//   类型化为 WorkflowTemplateConfig，非对象/结构错误在解码期失败（旧命令面 的
//   TEMPLATE_CONFIG_INVALID 检查由类型系统承担）；
// - get 的 templateId 与 update 的 templateId 按非空白 + 128 上限收敛（旧
//   旧命令面只校验存在，D-012 改为显式失败）；get 无记录 → TEMPLATE_NOT_FOUND；
// - create 的 name 复刻旧 validatedString：<=4096、trim(.whitespaces) 后非空并
//   返回 trim 值；description 缺省为 ""（旧命令面 同语义，不 trim）；
// - update 的 name/description 原样透传（旧命令面 对 name 不做 trim、对
//   description 做强制 String 化；类型化后非法 JSON 在解码期失败），空更新
//   返回现值且不触碰 updated_at（TemplateService 语义）；
// - delete / apply 只接收 Confirmed<T>（D-011）；delete 对不存在的 id 保持
//   TemplateService 的幂等 no-op（旧命令同样返回 {done:true}），apply 的
//   模板/会话存在性由服务层负责。
//
// 错误映射：
// - TemplateServiceError.templateNotFound / sessionNotFound → 带
//   TEMPLATE_NOT_FOUND / SESSION_NOT_FOUND 的 GatherError；
// - invalidSessionStatus（模板只能 apply 到 draft / photos_loaded）没有专用码
//   （GatherErrorCode 里没有会话状态码），按 D-012 显式收敛为 INVALID_PARAM，
//   field=sessionId，原动态消息只进 underlying（D-030：不伪造业务码、不上屏）；
// - DBError.message 若本身是错误码同样还原。本文件不新建 TemplateService
//   （它持有 SettingsService 缓存，只能有一份）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveTemplateAPI: TemplateAPI, @unchecked Sendable {
    private let templateService: TemplateService

    /// @unchecked Sendable 依据：templateService 是构造后不再变更的 let；
    /// TemplateService 无自有可变状态，内部经 DBConnection 的递归锁串行化，
    /// SettingsService 的缓存由该服务自身同步维护。
    public init(templateService: TemplateService) {
        self.templateService = templateService
    }

    // MARK: - 写入口

    public func create(_ input: TemplateCreateParams) async throws -> TemplateData {
        let name = try Self.validatedName(input.name)
        return try map {
            try templateService.create(
                name: name,
                description: input.description ?? "",
                config: input.config
            )
        }
    }

    public func update(_ input: TemplateUpdateParams) async throws -> TemplateData {
        let templateId = try Self.requireNonBlank(input.templateId, field: "templateId", maxLength: 128)
        let fields = TemplateUpdateFields(
            name: input.name,
            description: input.description,
            config: input.config
        )
        return try map {
            try templateService.update(id: templateId, fields: fields)
        }
    }

    public func delete(_ input: Confirmed<TemplateReference>) async throws {
        try map {
            try templateService.delete(id: input.value.templateId)
        }
    }

    public func apply(_ input: Confirmed<TemplateApplyInput>) async throws {
        try map {
            try templateService.apply(
                templateId: input.value.templateId,
                sessionId: input.value.sessionId
            )
        }
    }

    // MARK: - 读取

    public func list() async throws -> [TemplateData] {
        try map { try templateService.list() }
    }

    public func get(_ templateId: String) async throws -> TemplateData {
        let id = try Self.requireNonBlank(templateId, field: "templateId", maxLength: 128)
        guard let template = try map({ try templateService.get(id: id) }) else {
            throw GatherError(code: .TEMPLATE_NOT_FOUND)
        }
        return template
    }

    // MARK: - 校验与错误映射

    /// 旧命令面 validatedString（maxLength 默认 4096、非空白、trim 空白）。
    private static func validatedName(_ value: String) throws -> String {
        guard value.count <= 4096 else {
            throw GatherError.invalidParameter(
                field: "name",
                reason: "length must be at most 4096"
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: "name", reason: "must not be blank")
        }
        return trimmed
    }

    private static func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return trimmed
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    /// 域臂：TemplateServiceError；无专用码的 invalidSessionStatus 折算 INVALID_PARAM。
    private static func translate(_ error: Error) -> Error {
        LiveAPIErrorMapping.translateDomain(error) { domainError in
            guard let template = domainError as? TemplateServiceError else { return nil }
            if let code = template.gatherCode {
                return GatherError(code: code, underlying: template.description)
            }
            // invalidSessionStatus：无专用码，按参数/状态前置条件错误显式失败。
            return GatherError(
                code: .INVALID_PARAM,
                params: ["field": "sessionId", "reason": "session status must be draft or photos_loaded"],
                underlying: template.description
            )
        }
    }
}
