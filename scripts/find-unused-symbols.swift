#!/usr/bin/env swift
// 未使用 public 符号扫描（refactor-design-breaking-2026-10-21 §8.5 的 periphery 兜底）。
//
// 仅依赖 Foundation；不修改任何文件，只输出候选（启发式，结果需人工复核）：
//   - 定义：Sources 下以 public/open 开头的类型/函数/属性/typealias 声明
//     （gather-app 的 Culling/Settings/... 等 app target 源码目录也计入）。
//   - 引用：全仓 *.swift（含 Tests）按 ASCII 标识符做全量计数，减去声明本身。
//   - 候选：引用计数为 0 的 public 符号。
//
// 用法：
//   swift scripts/find-unused-symbols.swift [--json] [--all] [--limit N]
//                                           [--root PATH] [--allowlist PATH]
// 退出码：0 成功；2 参数/根目录错误。
import Foundation

struct Options {
    var root: String?
    var json = false
    var all = false
    var limit = 80
    var allowlist: String?
}

struct Declaration {
    let name: String
    let kind: String
    let path: String
    let line: Int
}

struct Candidate {
    let name: String
    let kind: String
    let path: String
    let line: Int
    let references: Int
}

func printUsage() {
    print("""
    find-unused-symbols (Foundation-only, heuristic)
      swift scripts/find-unused-symbols.swift [选项]
        --json             输出 JSON（含全部候选）
        --all              文本模式输出全部候选（默认前 80 条）
        --limit N          文本模式候选上限（默认 80）
        --root PATH        仓库根（默认由脚本位置推断）
        --allowlist PATH   每行一个符号名，# 开头为注释
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func hasRepoLayout(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appendingPathComponent("desktop/native").path)
}

func lineStarts(in text: String) -> [Int] {
    var starts = [0]
    var offset = 0
    for unit in text.utf16 {
        if unit == 10 {
            starts.append(offset + 1)
        }
        offset += 1
    }
    return starts
}

func lineNumber(for location: Int, lineStarts starts: [Int]) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
        let mid = (low + high + 1) / 2
        if starts[mid] <= location {
            low = mid
        } else {
            high = mid - 1
        }
    }
    return low + 1
}

func isIdentifierByte(_ byte: UInt8) -> Bool {
    (byte >= 48 && byte <= 57) ||
    (byte >= 65 && byte <= 90) ||
    (byte >= 97 && byte <= 122) ||
    byte == 95
}

func readText(_ url: URL) -> String? {
    guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
    return String(data: data, encoding: .utf8)
}

// ---------------------------------------------------------------- 参数

var options = Options()
let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--json":
        options.json = true
    case "--all":
        options.all = true
    case "--limit":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
            fail("--limit 需要正整数")
        }
        options.limit = value
    case "--root":
        index += 1
        guard index < arguments.count else { fail("--root 需要路径") }
        options.root = arguments[index]
    case "--allowlist":
        index += 1
        guard index < arguments.count else { fail("--allowlist 需要路径") }
        options.allowlist = arguments[index]
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        fail("未知参数：\(arguments[index])（--help 查看用法）")
    }
    index += 1
}

// ---------------------------------------------------------------- 根目录

let fileManager = FileManager.default
let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let inferredRoot = scriptPath.deletingLastPathComponent().deletingLastPathComponent()

let root: URL
if let explicit = options.root {
    let url = URL(fileURLWithPath: explicit).standardizedFileURL
    guard hasRepoLayout(url) else {
        fail("--root 下找不到 desktop/native：\(url.path)")
    }
    root = url
} else if hasRepoLayout(inferredRoot) {
    root = inferredRoot
} else {
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    guard hasRepoLayout(cwd) else {
        fail("无法推断仓库根（脚本位置：\(scriptPath.path)）；请用 --root 指定")
    }
    root = cwd
}

// ---------------------------------------------------------------- 文件枚举

let skippedDirectories: Set<String> = [
    ".build", ".git", ".swiftpm", "node_modules", "release",
    "Capture_One_Plugin_SDK_(Mac)_v1.0.1",
]

var swiftFiles: [URL] = []
if let enumerator = fileManager.enumerator(
    at: root,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles],
    errorHandler: { _, _ in true }
) {
    for case let url as URL in enumerator {
        if skippedDirectories.contains(url.lastPathComponent) {
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension == "swift" {
            swiftFiles.append(url)
        }
    }
}
swiftFiles.sort { $0.path < $1.path }

let testFiles = swiftFiles.filter { $0.path.contains("/Tests/") }
let sourceFiles = swiftFiles.filter { url in
    let path = url.path
    guard !path.contains("/Tests/") else { return false }
    return path.contains("/Sources/") || path.contains("/gather-app/") || path.contains("/gather-core/")
}

// ---------------------------------------------------------------- 标识符计数

var tokenCounts: [String: Int] = [:]
tokenCounts.reserveCapacity(30_000)

for url in swiftFiles {
    guard let text = readText(url) else { continue }
    var current: [UInt8] = []
    current.reserveCapacity(32)
    for byte in text.utf8 {
        if isIdentifierByte(byte) {
            current.append(byte)
        } else if !current.isEmpty {
            tokenCounts[String(decoding: current, as: UTF8.self), default: 0] += 1
            current.removeAll(keepingCapacity: true)
        }
    }
    if !current.isEmpty {
        tokenCounts[String(decoding: current, as: UTF8.self), default: 0] += 1
    }
}

// ---------------------------------------------------------------- public 声明

let declarationPattern = #"^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?[ \t]+)*(?:public|open)[ \t]+(?:(?:final|static|class|nonisolated|mutating|weak|unowned)[ \t]+)*(?:private\(set\)[ \t]+)?(func|var|let|class|struct|enum|actor|protocol|typealias)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"#
let declarationRegex: NSRegularExpression
do {
    declarationRegex = try NSRegularExpression(pattern: declarationPattern, options: [.anchorsMatchLines])
} catch {
    fail("内部正则编译失败：\(error)")
}

var declarations: [Declaration] = []
for url in sourceFiles {
    guard let text = readText(url) else { continue }
    let starts = lineStarts(in: text)
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    for match in declarationRegex.matches(in: text, options: [], range: range) {
        guard match.numberOfRanges >= 3 else { continue }
        let kind = nsText.substring(with: match.range(at: 1))
        let name = nsText.substring(with: match.range(at: 2))
        guard !name.isEmpty, !name.hasPrefix("_") else { continue }
        let line = lineNumber(for: match.range.location, lineStarts: starts)
        declarations.append(Declaration(name: name, kind: kind, path: url.path, line: line))
    }
}

var declarationCounts: [String: Int] = [:]
for declaration in declarations {
    declarationCounts[declaration.name, default: 0] += 1
}

// ---------------------------------------------------------------- allowlist

var allowlist: Set<String> = []
if let allowlistPath = options.allowlist {
    guard let data = fileManager.contents(atPath: allowlistPath),
          let text = String(data: data, encoding: .utf8) else {
        fail("无法读取 allowlist：\(allowlistPath)")
    }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        allowlist.insert(line)
    }
}

// ---------------------------------------------------------------- 候选

var seenNames: Set<String> = []
var candidates: [Candidate] = []
for declaration in declarations {
    guard !seenNames.contains(declaration.name) else { continue }
    seenNames.insert(declaration.name)
    guard !allowlist.contains(declaration.name) else { continue }
    let total = tokenCounts[declaration.name] ?? 0
    let declared = declarationCounts[declaration.name] ?? 1
    let references = max(0, total - declared)
    if references == 0 {
        candidates.append(Candidate(
            name: declaration.name,
            kind: declaration.kind,
            path: declaration.path,
            line: declaration.line,
            references: references
        ))
    }
}

candidates.sort { lhs, rhs in
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    return lhs.path < rhs.path
}

func relativePath(_ path: String) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    if path.hasPrefix(prefix) {
        return String(path.dropFirst(prefix.count))
    }
    return path
}

// ---------------------------------------------------------------- 输出

if options.json {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    var payload: [String: Any] = [
        "generated_at": formatter.string(from: Date()),
        "root": root.path,
        "swift_files": swiftFiles.count,
        "source_files": sourceFiles.count,
        "test_files": testFiles.count,
        "declarations": declarations.count,
        "unique_symbols": declarationCounts.count,
        "candidate_count": candidates.count,
        "candidates": candidates.map { candidate -> [String: Any] in
            [
                "name": candidate.name,
                "kind": candidate.kind,
                "file": relativePath(candidate.path),
                "line": candidate.line,
                "references": candidate.references,
            ]
        },
    ]
    payload["allowlist"] = allowlist.sorted()
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    ), let json = String(data: data, encoding: .utf8) else {
        fail("JSON 序列化失败")
    }
    print(json)
} else {
    print("find-unused-symbols (heuristic; Foundation-only)")
    print("root: \(root.path)")
    print("swift files: \(swiftFiles.count)（sources: \(sourceFiles.count), tests: \(testFiles.count)）")
    print("public declarations: \(declarations.count)（unique: \(declarationCounts.count)）")
    print("candidates (0 references outside declarations): \(candidates.count)")
    if !allowlist.isEmpty {
        print("allowlist: \(allowlist.count) 个符号")
    }
    print("------------------------------------------------------------")
    print("kind\tname\tlocation")
    let shown = options.all ? candidates : Array(candidates.prefix(options.limit))
    for candidate in shown {
        print("\(candidate.kind)\t\(candidate.name)\t\(relativePath(candidate.path)):\(candidate.line)")
    }
    if shown.isEmpty {
        print("(none)")
    }
    if !options.all && candidates.count > shown.count {
        print("... 其余 \(candidates.count - shown.count) 条：使用 --all 或 --json")
    }
    print("提示：引用计数按全仓 *.swift 的标识符出现次数估算；候选需人工复核后再删。")
}
