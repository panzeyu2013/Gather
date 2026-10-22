// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/SchemaSnapshot.swift
// WP6a：某个 schema 版本的冻结快照（设计 §5.1）。版本、DDL、期望列形三者必须同源，
// 迁移器用 shape 校验「版本对了但形态不对」。
//
// WP6b 起快照的 ddl 不含 PRAGMA user_version（V1/V2 共享 SchemaV1.ddl），createSQL
// 统一追加版本号；检测到 ddl 已带同版本声明时不再追加，兼容旧快照形态。
public struct SchemaSnapshot: Sendable {
    public let version: SchemaVersion
    /// 建库 DDL。WP6b 起不含 PRAGMA user_version；WP6a 的 v1 仍含（见文件头）。
    public let ddl: String
    public let shape: SchemaShapeExpectation

    public init(version: SchemaVersion, ddl: String, shape: SchemaShapeExpectation) {
        self.version = version
        self.ddl = ddl
        self.shape = shape
    }

    /// 一次成型：ddl + 版本号（若 ddl 已带**同一版本**的声明则原样返回，
    /// 避免把「含旧版本 PRAGMA 的完整 DDL」重复追加成两个版本声明）。
    public var createSQL: String {
        let marker = "PRAGMA user_version = \(version.rawValue)"
        if ddl.range(of: marker, options: .caseInsensitive) != nil {
            return ddl
        }
        return ddl + "\nPRAGMA user_version = \(version.rawValue);\n"
    }
}
