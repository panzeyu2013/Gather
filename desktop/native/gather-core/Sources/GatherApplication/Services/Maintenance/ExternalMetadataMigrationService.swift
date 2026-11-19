// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/ExternalMetadataMigrationService.swift
// Wave3（task-24）：从其他软件迁移的最小路径 —— 只读**已有 sidecar/XMP** 的
// rating / label / keywords，写回 Gather 的 photo_metadata_cache。
//
// 明确不做：不解析 .lrcat（Lightroom 目录）/ .cos（Capture One 会话）、不读厂商私有 DB
// —— 没有稳定公开契约；用户已从 LR/C1 写回 XMP（Write Settings to XMP / 导出 XMP）的场景
// 才是本入口的目标。
//
// 两阶段设计（重要）：
//   1) evaluate：读库取本地现值（candidates 由调用方在只读事务里取好）+ 逐张 await 读 XMP
//      → 纯计算得到"要写什么"与报告计数（不在任何 DB 事务里跨 await）；
//   2) apply：在一个写事务里落库（MetadataCacheRepo），失败整批回滚。
// 这样 XMP IO 慢不会长时间占着写锁。
//
// 冲突口径：默认只在本地为空（rating=0 / label 空 / keywords 空）时补写；
// overwriteExisting=true 时用 XMP 覆盖本地已有值。不一致且未覆盖 → conflicts 计数。
//
// 边界：本文件不含 SQL，不写 XMP、不改照片文件。
import Foundation
import GatherProtocol
import GatherPersistence

/// 一件待写的字段变更（同一张照片可能同时改 rating/label/keywords）。
public struct ExternalMigrationUpdate: Equatable, Sendable {
    public enum Field: Equatable, Sendable {
        case rating(Int64)
        case label(String)
        case keywords([String])
    }

    public let photoId: String
    public let fields: [Field]

    public init(photoId: String, fields: [Field]) {
        self.photoId = photoId
        self.fields = fields
    }
}

public struct ExternalMigrationEvaluation: Sendable {
    public var report: ExternalMigrationReport
    public var updates: [ExternalMigrationUpdate]

    public init(report: ExternalMigrationReport, updates: [ExternalMigrationUpdate]) {
        self.report = report
        self.updates = updates
    }
}

public struct ExternalMetadataMigrationService: Sendable {
    private let xmp: any XMPProvider

    /// 逐行解码 keywordsJSON 的共享解码器（round-4 性能）。
    ///
    /// decodeKeywords 在 evaluate 的逐候选循环里被调用（一行一次；迁移可扫到上万张）。
    /// JSONDecoder 无跨调用可变状态且已标 Sendable（与 GatherPersistence 的
    /// RepoJSONCoding 同一依据），复用不改变输出字节与失败语义（失败仍按空列表）。
    private static let keywordDecoder = JSONDecoder()

    public init(xmp: any XMPProvider) {
        self.xmp = xmp
    }

    /// 阶段 1：读 XMP 并与本地现值比较，产出变更清单与报告（无 DB 写、无事务）。
    public func evaluate(
        candidates: [ExternalMigrationCandidateRow],
        overwriteExisting: Bool
    ) async -> ExternalMigrationEvaluation {
        var report = ExternalMigrationReport(scanned: candidates.count)
        var updates: [ExternalMigrationUpdate] = []
        for candidate in candidates {
            let sidecar = TSPath.xmpSidecarPath(candidate.filepath)
            guard FileManager.default.fileExists(atPath: sidecar) else { continue }
            report.sidecarsFound += 1
            let attributes: MetadataWriteAttributes
            do {
                attributes = try await xmp.readAttributes(photoPath: candidate.filepath)
            } catch {
                report.failed.append(candidate.filepath)
                continue
            }
            var fields: [ExternalMigrationUpdate.Field] = []

            if let desired = attributes.rating {
                let desiredValue = Int64(desired.rounded())
                // D2（task-31 review）：Lightroom 的 -1（reject）以及异常的 6 都会
                // 触发 photo_metadata_cache 的 CHECK(0...5)，旧实现会让整个迁移事务
                // 回滚。evaluate 阶段丢弃该 rating 并计数，label/keywords 照常处理。
                if !(0...5).contains(desiredValue) {
                    report.skippedInvalidRating += 1
                } else if desiredValue != candidate.rating {
                    if candidate.rating > 0 && !overwriteExisting {
                        report.conflicts += 1
                    } else {
                        fields.append(.rating(desiredValue))
                    }
                }
            } else {
                report.missingRating += 1
            }

            if let desired = attributes.label, !desired.isEmpty {
                let localLabel = candidate.label ?? ""
                let normalizedLocal = localLabel == "None" ? "" : localLabel
                if desired != normalizedLocal {
                    if !normalizedLocal.isEmpty && !overwriteExisting {
                        report.conflicts += 1
                    } else {
                        fields.append(.label(desired))
                    }
                }
            } else {
                report.missingLabel += 1
            }

            if let desired = attributes.keywords, !desired.isEmpty {
                let localKeywords = Self.decodeKeywords(candidate.keywordsJSON)
                if Set(desired) != Set(localKeywords) {
                    if !localKeywords.isEmpty && !overwriteExisting {
                        report.conflicts += 1
                    } else {
                        fields.append(.keywords(desired))
                    }
                }
            } else {
                report.missingKeywords += 1
            }

            if !fields.isEmpty {
                updates.append(ExternalMigrationUpdate(photoId: candidate.photoId, fields: fields))
            }
        }
        return ExternalMigrationEvaluation(report: report, updates: updates)
    }

    /// 阶段 2：在调用方给定的写事务里落库（R1：注入窄写端口，不再自建仓储/连接）。
    public static func apply(
        updates: [ExternalMigrationUpdate], into metadata: any MetadataCacheStore
    ) throws {
        guard !updates.isEmpty else { return }
        for update in updates {
            for field in update.fields {
                switch field {
                case .rating(let value):
                    try metadata.updateRating(photoId: update.photoId, rating: value)
                case .label(let value):
                    try metadata.updateLabel(photoId: update.photoId, label: value)
                case .keywords(let values):
                    try metadata.updateKeywords(photoId: update.photoId, keywords: values)
                }
            }
        }
    }

    private static func decodeKeywords(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            return try keywordDecoder.decode([String].self, from: data)
        } catch {
            GatherLogger.log("migration keywords decode failed: \(error)", level: .debug)
            return []
        }
    }
}
