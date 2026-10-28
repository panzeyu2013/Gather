// desktop/native/gather-core/Sources/GatherPersistence/Database/Schema.swift
// 旧迁移链素材（SCHEMA_SQL / INDEX_SQL）已删除。
//
// 唯一 DDL 真相源是 SchemaCurrent.swift（44 表一次成型）。
// 本文件只保留两处**仍被引用**的常量：
//   1) activeAnalysisJobStatusSQLList —— AnalysisJobRepo 的部分唯一索引 WHERE 子句
//      字面量（SQLite 部分索引匹配是语法级的，必须与 DDL 逐字一致）；
//   2) currentSchemaVersion —— check-docs.sh 的代码版本对照入口；它是
//      SchemaCurrent.userVersion 的字面量镜像，SchemaCurrentTests 断言两者相等。
public enum SchemaSQL {
    /// 当前库版本（镜像 SchemaCurrent.userVersion；见文件头）。
    // 注意：不要写类型标注（check-docs.sh 按 currentSchemaVersion = <n> 提取）。
    public static let currentSchemaVersion = 1

    /// 活跃 job 状态集合的 **SQL 字面量唯一真相源**（顺序是语义的一部分）：
    /// 改顺序或改写成绑定参数都会让 AnalysisJobRepo.activeRow 失去
    /// idx_analysis_jobs_active_dedupe，退化为 status+priority 索引 + 临时 B-TREE。
    public static let activeAnalysisJobStatusSQLList = "'queued', 'running', 'cancelling'"
}
