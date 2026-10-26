// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PersonRepo.swift
// 人物身份生命周期（全量重写；TS person.repo.ts 时代的按名投影已删除）。
//
// 单一真相源：
//   persons                         身份本身（name/keywords/notes/match_threshold）
//   role_bindings                   身份在某个会话簇上的角色名（写回 XMP 的键）
//   face_clusters.matched_person_id 簇 → 身份 的显式链接
//   person_photos / person_embeddings  身份的投影（照片桥接、人脸向量）
//   metadata_keyword_origins（source='face-keyword'）我们实际写进 XMP 的关键词凭据
//
// 身份生命周期只有一处实现：applyIdentityTransition(_:)。bind / rename / delete /
// merge 四条路径全部经它落地，任何一条都不得各自半写。它保证不变量：
//   I1 绑定到身份的簇，其 role_name 恒等于身份当前 name（rename 同步 role_bindings）。
//   I2 身份消失后，不得残留任何「无 person 但会被 upsertByName 按名认领」的
//      role_binding —— 否则删除的身份会被对账复活（delete 同步）。
//   I3 合并把源身份的全部关联（簇链接、角色名、照片、向量、关键词）重指向目标，
//      源身份不留任何可认领物（merge 同步）。
//   I4 任何身份变更只要让某个关键词不再属于「当前会写回的名字集合」，就把它连同
//      实际持有它的 XMP 路径列进清理计划（PersonKeywordCleanup），由写回层执行移除；
//      origin 行保持 active=1（= 物理仍存在于 XMP），直到写回成功由写回层 deactivate。
//
// 复活防护选型：**清干净关联**，不用 tombstone。理由：
//   - upsertByName 的复活路径只有一条 —— role_bindings（FaceKwService.bindCluster
//     与 reconcileSession 都经它按名 adopt）。delete 把这些绑定与 matched_person_id
//     一并清掉，就没有可被认领的东西；
//   - tombstone 需要新表/新列（SchemaCurrent.swift 不在本域文件所有权内），
//     且会把「用户以后再次显式绑定同名角色」误判为复活；
//   - 清关联后再次出现同名人物只可能来自用户显式绑定，语义上就是新身份，不是复活。
// 拆分（WP5，纯移动）：值类型与主类型留本文件；实现见
//   PersonRepo+Query.swift（只读查询）/ PersonRepo+Identity.swift（身份生命周期）/
//   PersonRepo+Projection.swift（会话行与 person_photos/embeddings 投影）。
// 跨文件访问级：connection、linkClusters(_:personId:) 由 private 放宽为 internal
//   （后者供 +Projection 的 reconcileSession 调用）。

import Foundation
import GatherProtocol

/// persons 表行 + thumbnail_path（最近照片 filepath，无关联照片时为 nil）。
/// get()/listWithCounts() 的 SELECT 带 thumbnail_path 子查询（9/10 列）；
/// list() 为 persons 的 8 列显式清单（TableColumns.persons，无 thumbnail_path 列）。
public struct PersonRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let keywords: String
    public let thumbnailBase64: String
    public let thumbnailPath: String?
    public let notes: String
    public let matchThreshold: Double
    public let createdAt: String
    public let updatedAt: String

    // 表列序（TableColumns.persons，8 列）: id(0), name(1), keywords(2), thumbnail_base64(3),
    //   notes(4), match_threshold(5), created_at(6), updated_at(7)
    // get() 追加 thumbnail_path 子查询（9 列，位于索引 8）；
    // listWithCounts() 追加 thumbnail_path(8) + photo_count(9)/session_count(10)。
    init(row: DBRow) throws {
        guard row.count == 8 || row.count == 9 || row.count == 11 else {
            throw DBError.message("PersonRow 列数异常: \(row.count)")
        }
        id = row[0].textValue ?? ""
        name = row[1].textValue ?? ""
        keywords = row[2].textValue ?? ""
        thumbnailBase64 = row[3].textValue ?? ""
        notes = row[4].textValue ?? ""
        matchThreshold = row[5].doubleValue ?? 0
        createdAt = row[6].textValue ?? ""
        updatedAt = row[7].textValue ?? ""
        thumbnailPath = row.count >= 9 ? row[8].textValue : nil
    }
}

/// listWithCounts 的行：PersonRow + photo_count/session_count（第 9/10 列）。
public struct PersonWithCountsRow: Equatable, Sendable {
    public let person: PersonRow
    public let photoCount: Int
    public let sessionCount: Int

    init(row: DBRow) throws {
        person = try PersonRow(row: row)
        photoCount = Int(row[9].intValue ?? 0)
        sessionCount = Int(row[10].intValue ?? 0)
    }
}

/// person_photos 表行（列序 = TableColumns.personPhotos，7 列）。
public struct PersonPhotoRow: Equatable, Sendable {
    // 表列序: id(0), person_id(1), photo_id(2), session_id(3), face_bbox(4),
    // confidence(5), created_at(6)
    public let id: Int64
    public let personId: String
    public let photoId: String
    public let sessionId: String
    public let faceBbox: String
    public let confidence: Double
    public let createdAt: String

    init(row: DBRow) throws {
        guard row.count >= 7 else { throw DBError.message("PersonPhotoRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        personId = row[1].textValue ?? ""
        photoId = row[2].textValue ?? ""
        sessionId = row[3].textValue ?? ""
        faceBbox = row[4].textValue ?? ""
        confidence = row[5].doubleValue ?? 0
        createdAt = row[6].textValue ?? ""
    }
}

/// getPhotosWithDetails 的行：PersonPhotoRow + 会话名/文件名/路径（JOIN）。
public struct PersonPhotoDetail: Equatable, Sendable {
    // pp.*(0-6) + session_name(7), filename(8), filepath(9)
    public let photo: PersonPhotoRow
    public let sessionName: String
    public let filename: String
    public let filepath: String

    init(row: DBRow) throws {
        photo = try PersonPhotoRow(row: row)
        sessionName = row[7].textValue ?? ""
        filename = row[8].textValue ?? ""
        filepath = row[9].textValue ?? ""
    }
}

/// getAllEmbeddings 的轻量行（TS: { person_id, embedding, face_observation_id }）。
public struct PersonEmbeddingRef: Equatable, Sendable {
    public let personId: String
    public let embedding: Data
    public let faceObservationId: Int64?
}

/// addPhotos 的单条输入（TS: { photoId, faceBbox, confidence }）。
public struct PersonPhotoInput {
    public let photoId: String
    public let faceBbox: [Double]
    public let confidence: Double

    public init(photoId: String, faceBbox: [Double], confidence: Double) {
        self.photoId = photoId
        self.faceBbox = faceBbox
        self.confidence = confidence
    }
}

/// saveEmbeddings 的单条输入（TS: SaveEmbeddingInput，embedding 为 Float32 数组）。
///
/// Cut 2 / S5c-1：V1 的 person_embeddings 只存「向量 + 关联键」，删除了 face_bbox/quality
/// 两列冗余副本。二者的真相源分别是 person_photos.face_bbox（绑定桥接）与
/// face_observations.quality，故本输入不再携带这两个形参（旧实现写而无人读）。
public struct SaveEmbeddingInput {
    public let personId: String
    public let embedding: [Float]
    public let photoId: String
    public let sessionId: String
    public let faceObservationId: Int64?

    public init(personId: String, embedding: [Float], photoId: String, sessionId: String, faceObservationId: Int64?) {
        self.personId = personId
        self.embedding = embedding
        self.photoId = photoId
        self.sessionId = sessionId
        self.faceObservationId = faceObservationId
    }
}

/// 身份的展示名与匹配合格线（fkw.clusters 的建议展示 / 跨会话匹配的阈值）。
public struct PersonIdentitySummary: Equatable, Sendable {
    public let id: String
    public let name: String
    public let matchThreshold: Double

    public init(id: String, name: String, matchThreshold: Double) {
        self.id = id
        self.name = name
        self.matchThreshold = matchThreshold
    }
}

public struct PersonUpdateFields {
    public let name: String?
    public let keywords: [String]?
    public let notes: String?
    public let matchThreshold: Double?

    public init(name: String? = nil, keywords: [String]? = nil, notes: String? = nil, matchThreshold: Double? = nil) {
        self.name = name
        self.keywords = keywords
        self.notes = notes
        self.matchThreshold = matchThreshold
    }
}

// MARK: - 身份生命周期值类型

/// 身份变更产生的 XMP 关键词清理计划条目：这些关键词物理上仍写在 xmpPath 中，
/// 但已不再属于该身份的写入集合，必须由写回层移除（face-keyword origin 凭据）。
public struct PersonKeywordCleanup: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let xmpPath: String
    public let keywords: [String]

    public init(photoId: String, sessionId: String, xmpPath: String, keywords: [String]) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.xmpPath = xmpPath
        self.keywords = keywords
    }
}

/// 身份生命周期函数的返回值：谁发生了变化 + 需要清理哪些 XMP 关键词。
/// cleanup 为空表示本次变更没有遗留外部关键词（例如纯绑定、只有备注变更）。
public struct PersonIdentityOutcome: Equatable, Sendable {
    public let personId: String?
    /// merge 时的目标身份；其余为 nil。
    public let mergedInto: String?
    public let cleanup: [PersonKeywordCleanup]

    public init(personId: String?, mergedInto: String? = nil, cleanup: [PersonKeywordCleanup] = []) {
        self.personId = personId
        self.mergedInto = mergedInto
        self.cleanup = cleanup
    }

    public static let noop = PersonIdentityOutcome(personId: nil)
}

public final class PersonRepo {
    let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // 其余实现见 PersonRepo+Query/Identity/Projection.swift（纯移动）。
}
