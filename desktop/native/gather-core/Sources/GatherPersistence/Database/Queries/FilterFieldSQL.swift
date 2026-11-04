// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/FilterFieldSQL.swift
// 过滤字段的列规范化原子（#10）。
//
// 为什么只做「原子」不做 DSL：图库（PhotoFilterQuery）与挑片（CullingAssetPageQuery）
// 的过滤模型刻意不合并（粒度/游标/专有维都不同），但**同一个字段的空值口径**必须一致，
// 否则同一个「未评级」在两页给出不同结果。这里把两种规范化表达式收成唯一真相：
//
// - rating：photo_metadata_cache 缺行 = 未评级 = 0 星；
// - label：`''`（写回清空）与 NULL（未抽取）都算 None，与 reset 写入的字面 `None` 同义。
//
// 使用约束（踩过的坑）：只能在 **eq / in** 上套。套到 neq/gt/exists 会改变「未填写」
// 的语义——例如 `label exists` 会因为 COALESCE 恒有值而变成恒真。
import Foundation

public enum FilterFieldSQL {
    /// 星级：缺行按 0 星（与 `COALESCE(pmc.rating, 0) AS rating` 的投影口径一致）。
    public static func rating(_ column: String) -> String {
        "COALESCE(\(column), 0)"
    }

    /// 色标：空串与 NULL 都归一到 `None`（三种形态在库里都真实存在）。
    public static func label(_ column: String) -> String {
        "COALESCE(NULLIF(\(column), ''), 'None')"
    }
}
