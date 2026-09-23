// Store/StoreSupport.swift
// R1：Store 层共享支撑（旧 Repo 文件的通用工具迁入此处，避免随旧文件删除而丢失）。
import Foundation

public extension Array {
    /// 与 TS 分批循环等价的切片（每批 size 个）：用于规避 SQLite 变量数上限。
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
