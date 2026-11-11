// desktop/native/gather-app/Sources/GatherUI/SemanticSearch/SemanticKeywordBatchStore.swift
// Wave4c / task-50（E2 收尾）：场景标签写回的"上一次批次"持久化。
//
// 为什么需要：撤销 scope（appliedPhotoIds）之前只活在面板模型内存里，
// 关掉面板/重启 App 后"撤销本批"入口消失，用户无法回滚误写的关键词。
//
// 存储选型：**会话级 JSON 文件**（Application Support），不新增 settings key、
// 不改 schema。理由：settings 路线需要 SettingsKey（GatherProtocol）与新 key 的
// 读写通道（SettingsService 不在 UI 模型手里，要么扩 PhotoAPI 要么改 Culling 接线），
// 两处都是协议/越界改动；文件方案只动本模块，满足"最小修法"。
import Foundation

/// 上一次场景标签写回批次（撤销 scope 的持久化形态）。
struct SemanticKeywordBatchRecord: Codable, Equatable, Sendable {
    /// 本批实际写到/移除的照片（undo 的 photoIds）。
    var photoIds: [String]
    /// 服务端返回的批次 id（审计/日志）。
    var batchId: String
    /// 保存时间（ISO8601；UI 提示/排查用）。
    var savedAt: String
    var keywordsAdded: Int
    var keywordsRemoved: Int
}

/// 会话级"上一次写回"存储：面板重开 / App 重启后仍能撤销。
@MainActor
protocol SemanticKeywordBatchStoring {
    func load(sessionId: String) -> SemanticKeywordBatchRecord?
    func save(_ record: SemanticKeywordBatchRecord, sessionId: String)
    func clear(sessionId: String)
}

/// 文件实现：`<Application Support>/<bundle>/SemanticKeywordBatches/<session>.json`。
///
/// 边界：读失败/JSON 损坏/无权限 → 返回 nil（退化成"没有可撤销批次"，不崩、不阻塞写回）；
/// 写入失败只丢"重启后仍可撤销"这一增强，不影响本次写回（模型内 scope 仍可用）。
@MainActor
final class FileSemanticKeywordBatchStore: SemanticKeywordBatchStoring {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundle = Bundle.main.bundleIdentifier ?? "Gather"
        return base
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("SemanticKeywordBatches", isDirectory: true)
    }

    /// 文件名：会话 id 只保留常见安全字符，其余映射成下划线（防路径穿越/非法字符）。
    private static func safeFileName(_ sessionId: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        var name = ""
        for scalar in sessionId.unicodeScalars {
            name.append(allowed.contains(scalar) ? Character(String(scalar)) : "_")
        }
        if name.isEmpty { name = "default" }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }

    /// 会话对应的 JSON 路径（internal：测试用来构造损坏文件）。
    func fileURL(sessionId: String) -> URL {
        directory.appendingPathComponent(Self.safeFileName(sessionId) + ".json")
    }

    func load(sessionId: String) -> SemanticKeywordBatchRecord? {
        let url = fileURL(sessionId: sessionId)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return nil
        }
        do {
            return try JSONDecoder().decode(SemanticKeywordBatchRecord.self, from: data)
        } catch {
            return nil
        }
    }

    func save(_ record: SemanticKeywordBatchRecord, sessionId: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: fileURL(sessionId: sessionId), options: .atomic)
        } catch {
            // 持久化失败不影响本次写回：撤销退化为"本进程内可用"。
        }
    }

    func clear(sessionId: String) {
        do {
            try fileManager.removeItem(at: fileURL(sessionId: sessionId))
        } catch {
            // 文件不存在/删除失败都视为已清空（撤销 scope 已从模型里清掉）。
        }
    }
}
