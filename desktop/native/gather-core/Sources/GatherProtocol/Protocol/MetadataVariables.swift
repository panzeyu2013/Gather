// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataVariables.swift
// Wave2 task-13：元数据文案变量（{seq}/{client}/{year}/{month}/{day}/{filename}/
// {name}/{ext}/{camera}）的纯解析引擎。
//
// 语义冻结（写入前校验与预览共用同一实现，避免"UI 显示展开值、写盘写原文"）：
// - 占位符语法：{name} 或 {name:width}（width = 1...9 的零填充宽度）；
// - 支持的名字见 supportedNames；未知名字记为 unresolved（不抛错，预览可枚举）；
// - 已知名字但该照片没有值（无 client / 无相机 / 无拍摄时间）同样记 unresolved；
// - 未解析占位符**原样保留在输出文本里**：预览能直接看到缺什么，写入路径再以
//   unresolved 非空为拒绝条件做二次校验；
// - 序号语义：调用方显式传 sequence（本引擎不做排序），起始值由
//   MetadataVariableScope.sequenceStart 决定；UI 按目标照片 id 升序、从
//   sequenceStart 开始逐张 +1（{seq} 不带宽度 = 不补零）；
// - 日期取自照片拍摄时间（EXIF DateTimeOriginal 的 "yyyy:MM:dd HH:mm:ss" 或
//   "yyyy-MM-dd HH:mm:ss" / ISO8601 前缀），不是"导出当天"；缺日期 = unresolved；
// - "{{" / "}}" 是字面量花括号转义（避免正文里的 JSON/模板片段被误解析）。
//
// 本文件只有 Foundation + 纯函数，符合 Protocol 层的"值 + 纯逻辑"约束。
import Foundation

/// 一批文案的变量作用域（跨照片共享的部分）。
public struct MetadataVariableScope: Codable, Equatable, Sendable {
    /// 客户名（模板级变量；nil/空白 = 未提供 → {client} 记 unresolved）。
    public var client: String?
    /// 第一张照片的序号（默认 1）。UI 按目标照片 id 升序逐张 +1。
    public var sequenceStart: Int

    public init(client: String? = nil, sequenceStart: Int = 1) {
        self.client = client
        self.sequenceStart = max(1, sequenceStart)
    }

    public var normalizedClient: String? {
        guard let client else { return nil }
        let trimmed = client.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 单张照片的变量取值（由调用方从 PhotoMetadataDetail 派生）。
public struct MetadataVariablePhoto: Codable, Equatable, Sendable {
    public var filename: String
    public var camera: String?
    /// 拍摄时间原文（EXIF 或 ISO8601；只取年月日）。
    public var dateTaken: String?

    public init(filename: String, camera: String? = nil, dateTaken: String? = nil) {
        self.filename = filename
        self.camera = camera
        self.dateTaken = dateTaken
    }

    /// 不含扩展名的文件名。
    public var stem: String {
        (filename as NSString).deletingPathExtension
    }

    /// 扩展名（不含 "."；无扩展名 = 空串）。
    public var fileExtension: String {
        (filename as NSString).pathExtension
    }

    /// 从拍摄时间取 (year, month, day)；格式不认识/非法返回 nil。
    public var dateComponents: (year: String, month: String, day: String)? {
        guard let dateTaken else { return nil }
        let trimmed = dateTaken.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return nil }
        let head = Array(trimmed.prefix(10))
        // 允许 "yyyy:MM:dd" 与 "yyyy-MM-dd" 两种分隔符。
        guard head[4] == "-" || head[4] == ":", head[7] == "-" || head[7] == ":" else {
            return nil
        }
        let year = String(head[0..<4])
        let month = String(head[5..<7])
        let day = String(head[8..<10])
        guard year.allSatisfy({ $0.isNumber }),
              month.allSatisfy({ $0.isNumber }),
              day.allSatisfy({ $0.isNumber }) else { return nil }
        return (year, month, day)
    }
}

/// 一个未解析变量（预览可枚举；photoId/field 在批量计划里补上下文）。
public struct MetadataVariableUnresolved: Codable, Equatable, Hashable, Sendable {
    /// 占位符名字（已小写），如 "client"。
    public var name: String
    /// 原文占位符，如 "{client:4}"。
    public var raw: String

    public init(name: String, raw: String) {
        self.name = name
        self.raw = raw
    }
}

/// 展开结果：text 可能仍含未解析占位符（原样保留）。
public struct MetadataVariableExpansion: Equatable, Sendable {
    public var text: String
    public var unresolved: [MetadataVariableUnresolved]

    public init(text: String, unresolved: [MetadataVariableUnresolved]) {
        self.text = text
        self.unresolved = unresolved
    }

    public var isResolved: Bool { unresolved.isEmpty }
}

/// 变量解析唯一实现。
public enum MetadataVariableEngine {
    /// 支持的变量名（新增变量必须同时更新本表与文档/UI 提示）。
    public static let supportedNames: [String] = [
        "seq", "client", "year", "month", "day",
        "filename", "name", "ext", "camera",
    ]

    /// 语法层未知变量（不依赖照片/作用域；用于"模板保存/预览前"的早期校验）。
    public static func unknownVariables(in template: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        scan(template) { placeholder in
            guard !supportedNames.contains(placeholder.name) else { return }
            if seen.insert(placeholder.name).inserted { names.append(placeholder.name) }
        }
        return names
    }

    /// 展开一张照片的文案。
    ///
    /// - Parameters:
    ///   - template: 可含变量的原文；
    ///   - scope: 跨照片作用域（client / sequenceStart）；
    ///   - photo: 该照片的 filename/camera/dateTaken；
    ///   - sequence: 该照片的序号（由调用方决定排序与起始值）。
    public static func expand(
        _ template: String,
        scope: MetadataVariableScope,
        photo: MetadataVariablePhoto,
        sequence: Int
    ) -> MetadataVariableExpansion {
        var output = ""
        var unresolved: [MetadataVariableUnresolved] = []
        var seenUnresolved = Set<String>()
        var cursor = template.startIndex

        while cursor < template.endIndex {
            let character = template[cursor]
            if character == "{" {
                let next = template.index(after: cursor)
                if next < template.endIndex, template[next] == "{" {
                    output.append("{")
                    cursor = template.index(after: next)
                    continue
                }
                if let parsed = parsePlaceholder(template, from: cursor) {
                    if let resolved = resolve(
                        parsed, scope: scope, photo: photo, sequence: sequence) {
                        output.append(resolved)
                    } else {
                        output.append(parsed.raw)
                        if seenUnresolved.insert(parsed.raw).inserted {
                            unresolved.append(MetadataVariableUnresolved(
                                name: parsed.name, raw: parsed.raw))
                        }
                    }
                    cursor = parsed.end
                    continue
                }
            } else if character == "}" {
                let next = template.index(after: cursor)
                if next < template.endIndex, template[next] == "}" {
                    output.append("}")
                    cursor = template.index(after: next)
                    continue
                }
            }
            output.append(character)
            cursor = template.index(after: cursor)
        }
        return MetadataVariableExpansion(text: output, unresolved: unresolved)
    }

    // MARK: - 解析

    struct Placeholder: Equatable {
        var name: String
        var width: Int?
        var raw: String
        var end: String.Index
    }

    /// 从 "{" 起解析一个占位符；格式非法返回 nil（按字面量处理）。
    static func parsePlaceholder(_ text: String, from start: String.Index) -> Placeholder? {
        var cursor = text.index(after: start)
        var content = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "}" {
                let raw = String(text[start...cursor])
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                    return nil
                }
                var width: Int?
                if parts.count == 2 {
                    let widthText = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    guard let value = Int(widthText), (1...9).contains(value) else { return nil }
                    width = value
                }
                return Placeholder(name: name, width: width, raw: raw, end: text.index(after: cursor))
            }
            if character == "{" { return nil }
            content.append(character)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func resolve(
        _ placeholder: Placeholder,
        scope: MetadataVariableScope,
        photo: MetadataVariablePhoto,
        sequence: Int
    ) -> String? {
        switch placeholder.name {
        case "seq":
            let value = max(1, sequence)
            let digits = String(value)
            if let width = placeholder.width, digits.count < width {
                return String(repeating: "0", count: width - digits.count) + digits
            }
            return digits
        case "client":
            return scope.normalizedClient
        case "year":
            return photo.dateComponents?.year
        case "month":
            return photo.dateComponents?.month
        case "day":
            return photo.dateComponents?.day
        case "filename":
            return photo.filename.isEmpty ? nil : photo.filename
        case "name":
            return photo.stem.isEmpty ? nil : photo.stem
        case "ext":
            return photo.fileExtension.isEmpty ? nil : photo.fileExtension
        case "camera":
            guard let camera = photo.camera?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !camera.isEmpty else { return nil }
            return camera
        default:
            return nil
        }
    }

    /// 语法扫描：只产出格式合法的占位符（非法 {xxx 按字面量，不计入未知变量）。
    private static func scan(_ text: String, visit: (Placeholder) -> Void) {
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "{" {
                let next = text.index(after: cursor)
                if next < text.endIndex, text[next] == "{" {
                    cursor = text.index(after: next)
                    continue
                }
                if let parsed = parsePlaceholder(text, from: cursor) {
                    visit(parsed)
                    cursor = parsed.end
                    continue
                }
            }
            cursor = text.index(after: cursor)
        }
    }
}
