// desktop/native/gather-app/Tests/GatherAppTests/Support/TestDatabase.swift
// Cut 2 / S5c-2b-3b-2b-3 测试基建：内存库 = 纯 SchemaV1。
//
// 生产入口是 Database.open(at:)（user_version=1）；测试夹具只需要同一份 DDL，
// 直接 exec SchemaV1.sql。SchemaV1Transition（3 张 legacy 表 + sessions 3 列）
// 与 MigrationRunner 已随旧同步栈删除，这里不再有 hybrid 形态。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain

/// 全新的内存 V1 库（43 表，user_version = 1）。
func makeGatherTestDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaV1.sql)
    return db
}
