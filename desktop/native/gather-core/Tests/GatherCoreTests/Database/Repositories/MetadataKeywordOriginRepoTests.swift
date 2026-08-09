// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/MetadataKeywordOriginRepoTests.swift
// TS 源: desktop/src/main/db/repositories/metadata-keyword-origin.repo.ts

import Foundation
import Testing
@testable import GatherCore

struct MetadataKeywordOriginRepoTests {
    private func makeRepo() throws -> (DBConnection, MetadataKeywordOriginRepo) {
        let db = try makeMigratedDB()
        return (db, MetadataKeywordOriginRepo(connection: db))
    }

    @Test func markIntroducedInsertsActiveRows() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.markIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["person-a", "person-b"])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_keyword_origins") == 2)
        let row = try db.prepare("""
            SELECT active FROM metadata_keyword_origins WHERE xmp_path = '/v/IMG_1.xmp' AND keyword = 'person-a'
        """).get()
        #expect(row?[0].intValue == 1)
    }

    @Test func markIntroducedEmptyIsNoopAndDeduplicates() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.markIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: [])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_keyword_origins") == 0)

        // Set 语义：重复关键词只写一行
        try repo.markIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "a", "b"])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_keyword_origins") == 2)
    }

    @Test func getActiveIntroducedFilters() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.markIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b", "c"])
        try repo.markIntroduced(xmpPath: "/v/IMG_2.xmp", source: "face-keyword", keywords: ["a"])

        let active = try repo.getActiveIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "c", "zzz"])
        #expect(active == ["a", "c"])
        #expect(try repo.getActiveIntroduced(xmpPath: "/v/IMG_2.xmp", source: "face-keyword", keywords: ["a"]) == ["a"])
        #expect(try repo.getActiveIntroduced(xmpPath: "/v/IMG_1.xmp", source: "other", keywords: ["a"]).isEmpty)
        #expect(try repo.getActiveIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: []).isEmpty)
    }

    @Test func deactivateAndReactivate() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.markIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b"])
        try repo.deactivate(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a"])
        #expect(try repo.getActiveIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b"]) == ["b"])
        #expect(try db.prepare("""
            SELECT active FROM metadata_keyword_origins WHERE keyword = 'a'
        """).get()?[0].intValue == 0)

        // deactivate 空列表是 noop
        try repo.deactivate(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: [])
        #expect(try rowCount(db, "SELECT COUNT(*) FROM metadata_keyword_origins") == 2)

        // markIntroduced 重新激活
        try repo.markIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a"])
        #expect(try repo.getActiveIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b"]) == ["a", "b"])
    }
}
