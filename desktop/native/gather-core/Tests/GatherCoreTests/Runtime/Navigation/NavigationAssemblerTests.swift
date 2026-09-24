// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Navigation/NavigationAssemblerTests.swift
// NavigationAssembler 纯函数行为测试（W2d；由 Services/NavigationServiceTests 迁移，断言逐字保留）。

import Testing
@testable import GatherCore

@Suite("Navigation/NavigationAssembler (W2d)")
struct NavigationAssemblerTests {
    // TS: filenameSequence —— 取文件名尾部数字序号。
    @Test func filenameSequenceExtractsTrailingDigits() {
        #expect(NavigationAssembler.filenameSequence("IMG_0001.JPG") == 1)
        #expect(NavigationAssembler.filenameSequence("IMG_0042.jpg") == 42)
        #expect(NavigationAssembler.filenameSequence("IMG_0001_EDIT.JPG") == 1)
        #expect(NavigationAssembler.filenameSequence("IMG.JPG") == nil)
        #expect(NavigationAssembler.filenameSequence("0001.JPG") == 1)
    }

    // TS: hammingDistance —— 同长 hex 逐位差异。
    @Test func hammingDistanceCountsBits() {
        #expect(NavigationAssembler.hammingDistance("0000000000000000", "0000000000000000") == 0)
        #expect(NavigationAssembler.hammingDistance("0000000000000000", "0000000000000001") == 1)
        #expect(NavigationAssembler.hammingDistance("0000000000000000", "ffffffffffffffff") == 64)
        #expect(NavigationAssembler.hammingDistance("0000000000000001", "0000000000000003") == 1)
        // 长度不同 → nil。
        #expect(NavigationAssembler.hammingDistance("0000", "0000000000000000") == nil)
        // 空串 → nil。
        #expect(NavigationAssembler.hammingDistance("", "0000000000000000") == nil)
    }
}