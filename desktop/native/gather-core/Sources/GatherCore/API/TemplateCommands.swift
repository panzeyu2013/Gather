// API/TemplateCommands.swift
// R5 类型化 async 域协议：template 域。
// 旧实现来源：gather-app 路由层的 template.* 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// template 域命令（6 条）。
///
/// 旧命令清单：template.create、template.list、template.get、
/// template.update、template.delete、template.apply。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 template.create 在 config 非对象时抛 TEMPLATE_CONFIG_INVALID；
///   本协议由 TemplateCreateParams.config 的非可选类型静态承载，
///   运行时校验由实现保留；description 缺省为空串。
/// - 旧 template.get / template.update 在模板不存在时抛 TEMPLATE_NOT_FOUND，
///   因此返回非可选 TemplateData。
/// - 旧 template.delete / template.apply 响应为 {done:true}，本协议返回空；
///   template.apply 的配置展开写入设置属实现编排，任一写入失败需整体传播。
public protocol TemplateCommands: Sendable {
    /// 旧命令：template.create。
    /// 创建模板，返回 Protocol/Template.swift 的 TemplateData。
    func create(_ params: TemplateCreateParams) async throws -> TemplateData

    /// 旧命令：template.list。
    /// 返回全部模板，元素为 Protocol/Template.swift 的 TemplateData。
    func list() async throws -> [TemplateData]

    /// 旧命令：template.get。
    /// 模板不存在时抛错（旧行为 TEMPLATE_NOT_FOUND）。
    func get(_ params: TemplateGetParams) async throws -> TemplateData

    /// 旧命令：template.update。
    /// 仅更新 params 中非 nil 的字段；返回更新后的模板，不存在时抛错。
    func update(_ params: TemplateUpdateParams) async throws -> TemplateData

    /// 旧命令：template.delete（破坏性）。
    /// TemplateDeleteParams.confirmed 必须为 true，否则实现抛
    /// TEMPLATE_DELETE_CONFIRM_REQUIRED。
    func delete(_ params: TemplateDeleteParams) async throws

    /// 旧命令：template.apply（破坏性）。
    /// TemplateApplyParams.confirmed 必须为 true，否则实现抛
    /// TEMPLATE_APPLY_CONFIRM_REQUIRED；把模板配置展开为设置写入后返回空
    /// （旧响应 {done:true}）。
    func apply(_ params: TemplateApplyParams) async throws
}
