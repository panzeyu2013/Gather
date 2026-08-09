// desktop/native/gather-core/Sources/GatherCore/Similarity/Hash.swift
// dHash 移植（Phase 1 任务 1.5「对账测试框架」首批函数）。
//
// TS 源：desktop/src/main/services/similarity/hash-computer.ts
//   computeDHash() 第 14-27 行核心循环：对 9x8 灰度像素网格逐像素比较
//   left < right，置位 hash |= 1n << BigInt(y * 8 + x)，
//   输出 hash.toString(16).padStart(16, '0')。
//
// 移植说明：
//   - resize/grayscale（TS 第 5-12 行，sharp 解码层）属 Phase 2.1 在 Swift 侧以
//     CoreImage 实现，不在本函数范围内；本函数只接收 9x8 灰度像素网格。
//   - Swift 无 BigInt：64 位网格恰好用 UInt64 累加，位序与 TS BigInt 逐位一致
//     （低位 = 第 0 行第 0 列比较结果）。
//   - 输出 16 位小写 hex，等价 TS 的 toString(16).padStart(16, '0')（大小写一致）。

import Foundation

public enum DHash {
    public static func compute(pixels9x8: [UInt8]) -> String {
        var hash: UInt64 = 0

        for y in 0..<8 {
            for x in 0..<8 {
                let left = pixels9x8[y * 9 + x]
                let right = pixels9x8[y * 9 + x + 1]
                if left < right {
                    hash |= 1 << UInt64(y * 8 + x)
                }
            }
        }

        return String(format: "%016llx", hash)
    }
}
