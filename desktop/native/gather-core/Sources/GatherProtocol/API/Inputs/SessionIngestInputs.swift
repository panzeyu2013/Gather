// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SessionIngestInputs.swift
// P1 / D：摄取（复制/重命名/校验 → 登记进会话）。
//
// 与 session.add_photos 的分工：add_photos 只登记"已经在位的文件"；ingest 先把文件
// 搬到目标位置（可选第二目的地）并校验，再用同一套 add_photos 语义登记，
// 因此 RAW/JPEG 配对、去重、校验和回填都不在这里重复实现。
import Foundation

/// Wave2（task-15）：跨会话导入去重策略。
///
/// 命中判据 = 全库（photos 表，任意工作区）已登记照片的校验和；大小/修改时间只做
/// 预筛，最终以 SHA-256 相等为准（与库内去重同一口径）。
public enum IngestDuplicatePolicy: String, Codable, CaseIterable, Equatable, Sendable {
    /// 跳过库内已存在的文件（默认；与 Wave2 之前的会话内去重行为一致）。
    case skip
    /// 并存：照常复制并登记为新照片（同一张图在两个工作区各一份）。
    case coexist
    /// 替换：用新文件覆盖库内那张照片的**登记路径**后重新索引（仅限同一工作区，
    /// 且原路径必须在当前会话源根内；否则退化为跳过并在结果里说明）。
    case replace
}

/// Wave5（F4）：源里被跳过的「不支持格式」统计。
///
/// `extensions` 的键是**归一化**扩展名（dotless、小写，如 `"gif"`/`"mov"`），
/// 值是该扩展名被跳过的文件数；`count` 为各分组之和。`samplePaths` 保留前几个
/// 源路径，供 UI 显示"具体哪些文件没进来"（最多 5 条，避免大卡把结果撑大）。
public struct IngestUnsupportedFormats: Codable, Equatable, Sendable {
    public var extensions: [String: Int]
    public var samplePaths: [String]

    /// 被跳过的文件总数（= 各分组之和；不参与编码）。
    public var count: Int { extensions.values.reduce(0, +) }

    public init(extensions: [String: Int] = [:], samplePaths: [String] = []) {
        self.extensions = extensions
        self.samplePaths = samplePaths
    }

    /// 段级兜底：旧载荷/未来缺键都按"没有不支持文件"解码，不抛错。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            extensions: try container.decodeIfPresent(
                [String: Int].self, forKey: .extensions) ?? [:],
            samplePaths: try container.decodeIfPresent(
                [String].self, forKey: .samplePaths) ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case extensions, samplePaths
    }
}

/// 摄取预检（只读）：让用户在按下「开始摄取」前看到各类计数。
///
/// - newCount：会复制并登记的新文件数；
/// - libraryDuplicateCount：命中**全库**已登记照片（跨工作区）的文件数；
/// - conflictCount：目标目录已有同名但内容不同的文件数（现有冲突语义）；
/// - unreadableCount：不可读 / 越界 / 模板越界被拒的源数量；
/// - unsupportedFormats：源里被跳过的「不支持格式」（按扩展名分组 + 样例）。
///
/// `totalCount` 是本次扫描到的文件总数（含被跳过的库内重复 / 冲突 / 不可读 /
/// 不支持格式）。各计数在 skip 策略下的含义：new 会导入，libraryDuplicate 会被跳过，
/// conflict 会被跳过；换成 coexist 时后两类都转为导入；换成 replace 时
/// libraryDuplicate 里"同工作区且路径可替换"的部分转为覆盖写入。
public struct SessionIngestPreview: Codable, Equatable, Sendable {
    public var totalCount: Int
    public var newCount: Int
    public var libraryDuplicateCount: Int
    public var conflictCount: Int
    public var unreadableCount: Int
    public var policy: IngestDuplicatePolicy
    /// 命中全库重复的路径（最多 20 条，供 UI 展示样例；不含隐私以外信息）。
    public var duplicateSamplePaths: [String]
    /// Wave4a：按当前策略会被跳过的库内重复数（skip 或 replace 不可用时退化）。
    public var librarySkippedCount: Int
    /// Wave4a：按当前策略会被覆盖写入的库内重复数（replace 且同工作区+源根内）。
    public var replaceableCount: Int
    /// Wave5（F4）：被跳过的「不支持格式」统计（扩展名分组 + 样例；旧载荷 = 空）。
    public var unsupportedFormats: IngestUnsupportedFormats

    public init(
        totalCount: Int,
        newCount: Int,
        libraryDuplicateCount: Int,
        conflictCount: Int,
        unreadableCount: Int,
        policy: IngestDuplicatePolicy,
        duplicateSamplePaths: [String] = [],
        librarySkippedCount: Int = 0,
        replaceableCount: Int = 0,
        unsupportedFormats: IngestUnsupportedFormats = IngestUnsupportedFormats()
    ) {
        self.totalCount = totalCount
        self.newCount = newCount
        self.libraryDuplicateCount = libraryDuplicateCount
        self.conflictCount = conflictCount
        self.unreadableCount = unreadableCount
        self.policy = policy
        self.duplicateSamplePaths = duplicateSamplePaths
        self.librarySkippedCount = librarySkippedCount
        self.replaceableCount = replaceableCount
        self.unsupportedFormats = unsupportedFormats
    }

    /// 旧载荷（Wave3 之前）没有后两个字段：解码按 0 兜底，避免 IPC/持久化升级失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalCount: try container.decode(Int.self, forKey: .totalCount),
            newCount: try container.decode(Int.self, forKey: .newCount),
            libraryDuplicateCount: try container.decode(Int.self, forKey: .libraryDuplicateCount),
            conflictCount: try container.decode(Int.self, forKey: .conflictCount),
            unreadableCount: try container.decode(Int.self, forKey: .unreadableCount),
            policy: try container.decode(IngestDuplicatePolicy.self, forKey: .policy),
            duplicateSamplePaths: try container.decodeIfPresent(
                [String].self, forKey: .duplicateSamplePaths) ?? [],
            librarySkippedCount: try container.decodeIfPresent(
                Int.self, forKey: .librarySkippedCount) ?? 0,
            replaceableCount: try container.decodeIfPresent(
                Int.self, forKey: .replaceableCount) ?? 0,
            unsupportedFormats: try container.decodeIfPresent(
                IngestUnsupportedFormats.self, forKey: .unsupportedFormats)
                ?? IngestUnsupportedFormats()
        )
    }

    private enum CodingKeys: String, CodingKey {
        case totalCount, newCount, libraryDuplicateCount, conflictCount,
             unreadableCount, policy, duplicateSamplePaths,
             librarySkippedCount, replaceableCount, unsupportedFormats
    }
}

public struct SessionIngestInput: Codable, Sendable, Equatable {
    public let sessionId: String
    /// 源：单个文件或目录（目录只扫一层，不递归子目录）。
    public let sourcePaths: [String]
    public let destinationRoot: String
    /// 重命名模板，如 {yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}。
    public let renameTemplate: String
    public let secondDestinationRoot: String?
    public let verifyChecksum: Bool
    /// Wave2：跨会话重复的处置策略（缺省 skip，旧载荷解码同样落到 skip）。
    public let duplicatePolicy: IngestDuplicatePolicy

    public init(
        sessionId: String,
        sourcePaths: [String],
        destinationRoot: String,
        renameTemplate: String = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
        secondDestinationRoot: String? = nil,
        verifyChecksum: Bool = true,
        duplicatePolicy: IngestDuplicatePolicy = .skip
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.sourcePaths = try APIValidation.nonEmpty(sourcePaths, field: "sourcePaths")
        self.destinationRoot = try APIValidation.path(destinationRoot, field: "destinationRoot")
        self.renameTemplate = try APIValidation.nonBlank(renameTemplate, field: "renameTemplate", maxLength: 256)
        self.secondDestinationRoot = try secondDestinationRoot.map {
            try APIValidation.path($0, field: "secondDestinationRoot")
        }
        self.verifyChecksum = verifyChecksum
        self.duplicatePolicy = duplicatePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            sourcePaths: try container.decode([String].self, forKey: .sourcePaths),
            destinationRoot: try container.decode(String.self, forKey: .destinationRoot),
            renameTemplate: try container.decodeIfPresent(String.self, forKey: .renameTemplate)
                ?? "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
            secondDestinationRoot: try container.decodeIfPresent(String.self, forKey: .secondDestinationRoot),
            verifyChecksum: try container.decodeIfPresent(Bool.self, forKey: .verifyChecksum) ?? true,
            duplicatePolicy: try container.decodeIfPresent(
                IngestDuplicatePolicy.self, forKey: .duplicatePolicy) ?? .skip
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, sourcePaths, destinationRoot, renameTemplate, secondDestinationRoot,
             verifyChecksum, duplicatePolicy
    }
}

public struct SessionIngestResult: Codable, Equatable, Sendable {
    /// 成功复制并已登记的照片数。
    public var registered: Int
    /// 已复制但登记失败（路径仍在，重试 add_photos 即可）。
    public var copiedButUnregistered: [String]
    public var skipped: [String]
    /// 计划阶段被拒绝的源（不可读、或重命名模板越界被拦）。
    public var unreadable: [String]
    public var failed: [MetadataApplyFailureDTO]
    /// Wave2：因**跨工作区重复**被跳过的张数（旧载荷无此字段 → nil 表示未统计）。
    public var libraryDuplicatesSkipped: Int?
    /// Wave2：按 replace 策略覆盖写入的张数。
    public var replaced: Int?
    /// Wave4a-F4：replace 项在第二目的地被跳过（无法按相对路径镜像）的张数。
    public var secondDestinationSkipped: Int?
    /// Wave4a：命中全库重复的源总数（与策略无关；旧载荷 nil = 未统计）。
    public var libraryDuplicateCount: Int?
    /// Wave5（F4）：被跳过的「不支持格式」统计（nil = 旧任务结果未统计）。
    public var unsupportedFormats: IngestUnsupportedFormats?
    public init(registered: Int, copiedButUnregistered: [String], skipped: [String],
                unreadable: [String] = [], failed: [MetadataApplyFailureDTO],
                libraryDuplicatesSkipped: Int? = nil, replaced: Int? = nil,
                libraryDuplicateCount: Int? = nil,
                secondDestinationSkipped: Int? = nil,
                unsupportedFormats: IngestUnsupportedFormats? = nil) {
        self.registered = registered
        self.copiedButUnregistered = copiedButUnregistered
        self.skipped = skipped
        self.unreadable = unreadable
        self.failed = failed
        self.libraryDuplicatesSkipped = libraryDuplicatesSkipped
        self.replaced = replaced
        self.libraryDuplicateCount = libraryDuplicateCount
        self.secondDestinationSkipped = secondDestinationSkipped
        self.unsupportedFormats = unsupportedFormats
    }
}
