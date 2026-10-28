// desktop/native/gather-core/Sources/GatherTriageEval/main.swift
// P0 / T0：真实集质量门 CLI。
//
// 用法：
//   gather-triage-eval --db <gather.sqlite> --session <id> --labels <labels.csv|tsv> [--strict]
//
// labels 每行：photo_path,keep|reject|unsure[,category]
// - 路径可写绝对路径或唯一 basename；同 basename 多文件时必须用绝对路径。
// - unsure 不计入分母；unmatched 会单独计数，不静默吞掉。
// - --strict：误杀率 <1%、reject precision >=99%、复核率 <=35%、覆盖率 >=65%，任一失败 exit 1。
//
// 只读：打开库、loadCandidates、纯函数评估；不生成建议、不写决策、不写 XMP。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherApplication

private struct Options {
    var dbPath = ""
    var sessionId = ""
    var labelsPath = ""
    var exportSignals: String?
    var strict = false
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case io(String)
    var description: String {
        switch self {
        case .usage(let s): "usage: \(s)"
        case .io(let s): s
        }
    }
}

private func parseArgs(_ args: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--db":
            index += 1
            guard index < args.count else { throw CLIError.usage("--db needs a path") }
            options.dbPath = args[index]
        case "--session":
            index += 1
            guard index < args.count else { throw CLIError.usage("--session needs an id") }
            options.sessionId = args[index]
        case "--labels":
            index += 1
            guard index < args.count else { throw CLIError.usage("--labels needs a path") }
            options.labelsPath = args[index]
        case "--export-signals":
            index += 1
            guard index < args.count else { throw CLIError.usage("--export-signals needs a path") }
            options.exportSignals = args[index]
        case "--strict":
            options.strict = true
        case "--help", "-h":
            throw CLIError.usage(
                "gather-triage-eval --db <db> --session <id> [--labels <csv|tsv>] "
                    + "[--export-signals <out.csv>] [--strict]")
        default:
            throw CLIError.usage("unknown argument \(args[index])")
        }
        index += 1
    }
    guard !options.dbPath.isEmpty, !options.sessionId.isEmpty else {
        throw CLIError.usage("--db and --session are required")
    }
    guard !options.labelsPath.isEmpty || options.exportSignals != nil else {
        throw CLIError.usage("either --labels or --export-signals is required")
    }
    return options
}

private func readLabels(at path: String) throws -> [String] {
    do { return try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init) }
    catch { throw CLIError.io("cannot read labels: \(error)") }
}

private func normalizePath(_ path: String) -> String {
    (path as NSString).standardizingPath
}

private func parseLabel(_ raw: String) -> TriageGroundTruth? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "keep", "pick", "1", "yes": return .keep
    case "reject", "no", "0": return .reject
    case "unsure", "?", "maybe": return .unsure
    default: return nil
    }
}

private func splitLine(_ line: String) -> [String] {
    if line.contains("\t") { return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    return line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
}

private func mapGroupKind(_ raw: String) -> TriageGroupRef.Kind? {
    switch raw {
    case "similarity": return .similarity
    case "exact", "exactDuplicate": return .exactDuplicate
    case "visual", "visualDuplicate": return .visualDuplicate
    case "burst": return .burst
    case "scene": return .scene
    default: return nil
    }
}

private func mapCandidate(_ record: TriageCandidateRecord) -> TriageCandidate {
    TriageCandidate(
        photoId: record.photoId,
        quality: record.quality,
        modelReview: record.modelReview,
        faceCount: record.faceCount,
        maxFaceAreaRatio: record.maxFaceAreaRatio,
        groups: record.groups.compactMap { group in
            guard let kind = mapGroupKind(group.kind) else { return nil }
            return TriageGroupRef(kind: kind, groupId: group.groupId,
                                  memberPhotoIds: group.memberPhotoIds, leadPhotoId: group.leadPhotoId)
        },
        manualDecision: record.manualDecision.flatMap(CullingDecisionValue.init(rawValue:)),
        decisionSource: record.decisionSource.flatMap(CullingDecisionSource.init(rawValue:)),
        importOrder: record.importOrder,
        width: record.width,
        height: record.height,
        fileSize: record.fileSize
    )
}

private func percent(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.2f%%", value * 100)
}

private func metric(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.4f", value)
}

/// 逐张导出模型/技术信号，供离线拟合与分层评估（不写库、不生成建议）。
private func exportSignalCSV(
    path: String,
    candidates: [TriageCandidate],
    evaluations: [TriageEvaluation],
    policyVersion: String
) throws {
    var byId: [String: TriageResult] = [:]
    for evaluation in evaluations {
        if case .suggestion(let result) = evaluation { byId[result.photoId] = result }
    }
    func number(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? ""
    }
    var lines = [
        "photoId,policyVersion,verdict,confidence,score,qualityScore,"
            + "eyesOpen,faceFocus,smile,aesthetic,utility,reasons",
    ]
    for candidate in candidates {
        let result = byId[candidate.photoId]
        let model = candidate.modelReview
        let reasons = result?.reasons.map(\.code.rawValue).joined(separator: "|") ?? ""
        let verdict = result?.verdict.rawValue ?? "excluded"
        lines.append([
            candidate.photoId,
            policyVersion,
            verdict,
            number(result?.confidence),
            number(result?.score),
            number(candidate.quality?.qualityScore),
            number(model?.eyesOpenScore),
            number(model?.faceFocusScore),
            number(model?.smileScore),
            number(model?.aestheticScore),
            model?.isUtilityImage.map { $0 ? "1" : "0" } ?? "",
            reasons,
        ].joined(separator: ","))
    }
    do {
        try lines.joined(separator: "\n").write(
            toFile: path, atomically: true, encoding: .utf8)
    } catch {
        throw CLIError.io("cannot write signals: \(error)")
    }
    FileHandle.standardOutput.write(Data(("wrote \(candidates.count) rows -> \(path)\n").utf8))
}

private func run(_ options: Options) throws -> Int32 {
    let database = try Database.open(at: options.dbPath)
    defer { database.close() }
    let repo = TriageRepo(connection: database.connection)
    let load = try repo.loadCandidates(sessionId: options.sessionId)
    let candidates = load.candidates.map(mapCandidate)
    // 评估默认对齐线上（v2 才读模型信号）；CSV 记录真实策略版本。
    let policy = TriagePolicy.v2
    let evaluations = evaluateTriage(candidates: candidates, policy: policy)
    var verdicts: [String: TriageVerdict] = [:]
    for evaluation in evaluations {
        if case .suggestion(let result) = evaluation { verdicts[result.photoId] = result.verdict }
    }

    if let output = options.exportSignals {
        try exportSignalCSV(
            path: output, candidates: candidates, evaluations: evaluations,
            policyVersion: policy.version)
        if options.labelsPath.isEmpty { return 0 }
    }

    // photo id -> asset group / filepath
    struct PhotoRow { let id: String; let gid: String; let path: String }
    let photos: [PhotoRow] = try database.read { conn in
        try conn.prepare("""
            SELECT id, COALESCE(NULLIF(asset_id, ''), id), filepath
            FROM photos WHERE session_id = ?
            """).query([.text(options.sessionId)]).map {
                PhotoRow(id: $0[0].textValue ?? "", gid: $0[1].textValue ?? "", path: $0[2].textValue ?? "")
            }
    }

    var byFullPath: [String: String] = [:]
    var byBasename: [String: [String]] = [:]
    var gidToCandidate: [String: String] = [:]
    var photoIdToGid: [String: String] = [:]
    for photo in photos {
        photoIdToGid[photo.id] = photo.gid
        byFullPath[normalizePath(photo.path)] = photo.id
        byBasename[(photo.path as NSString).lastPathComponent, default: []].append(photo.id)
    }
    for candidate in load.candidates {
        if let gid = photoIdToGid[candidate.photoId] { gidToCandidate[gid] = candidate.photoId }
    }

    var labeled: [String: (TriageGroundTruth, String?)] = [:]
    var unmatched: [String] = []
    var unknown: [String] = []
    for raw in try readLabels(at: options.labelsPath) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let cells = splitLine(line)
        if cells.count < 2 { continue }
        if cells[0].lowercased() == "photo_path" || cells[0].lowercased() == "path" { continue }
        guard let truth = parseLabel(cells[1]) else { unknown.append(line); continue }
        let rawPath = cells[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let category = cells.count > 2 ? cells[2].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let photoId: String?
        if let exact = byFullPath[normalizePath(rawPath)] {
            photoId = exact
        } else if let matches = byBasename[(rawPath as NSString).lastPathComponent], matches.count == 1 {
            photoId = matches[0]
        } else {
            photoId = nil
        }
        guard let photoId, let gid = photoIdToGid[photoId], let candidateId = gidToCandidate[gid] else {
            unmatched.append(line); continue
        }
        labeled[candidateId] = (truth, category?.isEmpty == false ? category : nil)
    }

    let rows = labeled.compactMap { candidateId, pair -> TriageLabeledVerdict? in
        guard let verdict = verdicts[candidateId] else { return nil }
        return TriageLabeledVerdict(label: pair.0, verdict: verdict, category: pair.1)
    }
    let missingFromSuggestions = labeled.keys.filter { verdicts[$0] == nil }.count
    let report = TriageMetrics.evaluate(rows)

    print("# T0 真实集质量门")
    print("")
    print("- db: `\(options.dbPath)`")
    print("- session: `\(options.sessionId)`")
    print("- candidates: \(load.candidates.count)  labeled: \(report.overall.labeled)  unsure: \(report.ignoredUnsure)")
    print("- unmatched labels: \(unmatched.count)  unknown label values: \(unknown.count)")
    print("- labeled but no suggestion: \(missingFromSuggestions)")
    print("")
    print("| metric | value | threshold | status |")
    print("|---|---:|---:|---|")
    let b = report.overall
    func status(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }
    let fr = b.falseRejectRate
    let rp = b.rejectPrecision
    let rr = b.reviewRate
    let cv = b.coverage
    let frOK = (fr ?? 1) < 0.01
    let rpOK = (rp ?? 0) >= 0.99
    // v2 收益门限（设计 §2.1.6）：复核率 ≤20%、覆盖率 ≥75%；缺指标不能算 PASS。
    let rrOK = (rr ?? 1) <= 0.20
    let cvOK = (cv ?? 0) >= 0.75
    print("| 误杀率 (false reject) | \(percent(fr)) | < 1% | \(status(frOK)) |")
    print("| reject precision | \(percent(rp)) | >= 99% | \(status(rpOK)) |")
    print("| 复核率 | \(percent(rr)) | <= 20% | \(status(rrOK)) |")
    print("| 覆盖率 | \(percent(cv)) | >= 75% | \(status(cvOK)) |")
    print("")
    if !report.byCategory.isEmpty {
        print("## 分类")
        print("")
        print("| category | labeled | falseReject | falseRejectRate | rejectPrecision | reviewRate |")
        print("|---|---:|---:|---:|---:|---:|")
        for key in report.byCategory.keys.sorted() {
            guard let bucket = report.byCategory[key] else { continue }
            print("| \(key) | \(bucket.labeled) | \(bucket.falseReject) | \(percent(bucket.falseRejectRate)) | \(percent(bucket.rejectPrecision)) | \(percent(bucket.reviewRate)) |")
        }
    }

    if !unmatched.isEmpty {
        print("")
        print("> \(unmatched.count) 条标注未匹配到逻辑资产（前 5 条）：")
        for line in unmatched.prefix(5) { print("> - \(line)") }
    }
    if !unknown.isEmpty {
        print("")
        print("> \(unknown.count) 条标注的 label 无法识别（前 5 条）：")
        for line in unknown.prefix(5) { print("> - \(line)") }
    }

    let failed = !(frOK && rpOK && rrOK && cvOK)
    if options.strict && failed { return 1 }
    return 0
}

do {
    let options = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    exit(try run(options))
} catch {
    FileHandle.standardError.write(Data(("gather-triage-eval: \(error)\n").utf8))
    exit(2)
}
