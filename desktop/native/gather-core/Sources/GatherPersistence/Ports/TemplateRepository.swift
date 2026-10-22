// desktop/native/gather-core/Sources/GatherPersistence/Ports/TemplateRepository.swift
// WP3b-1：workflow_templates 仓储端口。
import Foundation

public protocol TemplateRepository {
    func list() throws -> [TemplateRow]
    func get(id: String) throws -> TemplateRow?
    func create(id: String, name: String, description: String, configJSON: String) throws -> TemplateRow?
    func update(id: String, fields: TemplateUpdatePayload) throws
    func delete(id: String) throws
    func sessionStatus(id: String) throws -> String?
}

extension TemplateRepo: TemplateRepository {}
