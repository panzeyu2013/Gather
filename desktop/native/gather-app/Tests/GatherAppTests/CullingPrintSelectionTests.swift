// desktop/native/gather-app/Tests/GatherAppTests/CullingPrintSelectionTests.swift
// Wave4b / P2-11：打印候选集上限（200）的纯逻辑回归。
import Foundation
import Testing
@testable import GatherUI

@Suite("打印候选集上限（Wave4b P2-11）")
struct CullingPrintSelectionTests {
    @Test("上限 200：未超不截断，超出给未包含张数")
    func truncationCount() {
        #expect(CullingPrintSelection.limit == 200)
        #expect(CullingPrintSelection.truncatedCount(total: 0) == 0)
        #expect(CullingPrintSelection.truncatedCount(total: 200) == 0)
        #expect(CullingPrintSelection.truncatedCount(total: 201) == 1)
        #expect(CullingPrintSelection.truncatedCount(total: 350) == 150)
    }
}
