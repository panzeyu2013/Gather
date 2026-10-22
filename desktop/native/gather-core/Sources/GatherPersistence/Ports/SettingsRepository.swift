// desktop/native/gather-core/Sources/GatherPersistence/Ports/SettingsRepository.swift
// P1-1：app_settings 端口（只含 Application 实际调用的方法）。
//
// SettingsService 构造时 getAll 全量灌入内存缓存；set/reset 走 upsert /
// batchUpsert 双写。读写语义（INSERT OR REPLACE、默认值表）留在 Application。
import Foundation

public protocol SettingsRepository {
    /// 全量键值（构造时灌缓存）。
    func getAll() throws -> [SettingsRow]
    /// 单键 upsert（set）。
    func upsert(key: String, value: String) throws
    /// 批量 upsert（reset 的默认值全量写入；实现内自带事务）。
    func batchUpsert(entries: [(key: String, value: String)]) throws
}

extension SettingsRepo: SettingsRepository {}
