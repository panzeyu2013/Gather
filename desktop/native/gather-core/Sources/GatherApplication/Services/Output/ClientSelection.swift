// desktop/native/gather-core/Sources/GatherApplication/Services/Output/ClientSelection.swift
// 客户校样回传：解析 proof.html 下载的 selection.json。
//
// 约定（与 GalleryBuilder 的 proof.js 同源）：
//   {"version":1,"title":"...","picks":[{"id":"...","name":"...","pick":true}]}
// 只认 id；pick=false 跳过；重复 id 去重（保持首次出现顺序）。
import Foundation

public struct ClientSelectionPick: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var pick: Bool?

    public init(id: String, name: String? = nil, pick: Bool? = nil) {
        self.id = id
        self.name = name
        self.pick = pick
    }
}

public struct ClientSelectionFile: Codable, Equatable, Sendable {
    public var version: Int?
    public var title: String?
    public var picks: [ClientSelectionPick]

    public init(version: Int? = 1, title: String? = nil, picks: [ClientSelectionPick]) {
        self.version = version
        self.title = title
        self.picks = picks
    }
}

public enum ClientSelectionError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)

    public var code: String { "CLIENT_SELECTION_INVALID" }

    public var description: String {
        switch self {
        case .invalidJSON(let reason): "CLIENT_SELECTION_INVALID: " + reason
        }
    }
}

public enum ClientSelectionParser {
    /// 返回被勾选的 photoId（去重、保持顺序）。
    public static func pickedPhotoIds(from data: Data) throws -> [String] {
        let selection: ClientSelectionFile
        do {
            selection = try JSONDecoder().decode(ClientSelectionFile.self, from: data)
        } catch {
            throw ClientSelectionError.invalidJSON(String(describing: error))
        }
        var seen = Set<String>()
        var result: [String] = []
        for pick in selection.picks where pick.pick != false {
            let id = pick.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}
