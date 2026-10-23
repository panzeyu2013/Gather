#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Persons.swift
// Cut 4 / 4c-1 Preview 固定样例的纯移动拆分（人物库 / 人物详情）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

extension PreviewData {
    // MARK: 人物库（Persons）

    static let persons: [PersonData] = [
        person(id: "preview-person-1", name: "Mika", keywords: ["Mika", "人像"], photoCount: 42, sessions: 2),
        person(id: "preview-person-2", name: "Ren", keywords: ["Ren", "人像"], photoCount: 31, sessions: 2),
        person(id: "preview-person-3", name: "Aoi", keywords: ["Aoi"], photoCount: 18, sessions: 1),
        person(id: "preview-person-4", name: "Kai", keywords: ["Kai"], photoCount: 12, sessions: 1),
        person(id: "preview-person-5", name: "Yuki", keywords: ["Yuki"], photoCount: 7, sessions: 1),
    ]

    private static func person(
        id: String,
        name: String,
        keywords: [String],
        photoCount: Int,
        sessions: Int
    ) -> PersonData {
        PersonData(
            id: id,
            name: name,
            keywords: keywords,
            thumbnailBase64: nil,
            thumbnailPath: nil,
            notes: "",
            matchThreshold: 0.65,
            photoCount: photoCount,
            sessionCount: sessions,
            createdAt: earlierTimestamp,
            updatedAt: timestamp
        )
    }

    static func personDetail(_ id: String) -> PersonDetailData {
        let base = persons.first { $0.id == id } ?? persons[0]
        let photos = (1...6).map { index in
            PersonPhotoItem(
                photoId: "preview-person-\(base.id)-\(index)",
                sessionId: sessionOneId,
                sessionName: sessionOneName,
                filename: (personPaths[index - 1] as NSString).lastPathComponent,
                filepath: personPaths[index - 1],
                faceBbox: [0.22, 0.18, 0.3, 0.4],
                confidence: 0.9,
                thumbnailBase64: nil
            )
        }
        return PersonDetailData(
            id: base.id,
            name: base.name,
            keywords: base.keywords,
            thumbnailBase64: nil,
            thumbnailPath: nil,
            notes: "预览样例：\(base.name) 的人物档案",
            matchThreshold: base.matchThreshold,
            photoCount: base.photoCount,
            sessionCount: base.sessionCount,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            photos: photos,
            totalPhotoCount: base.photoCount
        )
    }
}
#endif
