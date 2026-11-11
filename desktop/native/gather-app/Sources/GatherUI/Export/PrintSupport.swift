// desktop/native/gather-app/Sources/GatherUI/Export/PrintSupport.swift
// W3：打印联系表（PDF → 系统打印面板）。只做"把已有 PDF 交给打印系统"，
// 不做版面计算（版面在 ContactSheetRenderer / PrintLayout）。
//
// Wave3 / task-20：打印是**独占资源**——NSPrintOperation 同一时刻只能有一个
// 打印会话（联系表打印与新的版面打印共用这条路径）。这里加一把进程级闸：
// 已有打印面板在跑时，新的打印请求返回 false 且不构造第二个 NSPrintOperation；
// 调用方据此给"已有打印任务在进行中"的明确提示，而不是静默吞掉或起两个面板。
import AppKit
import Foundation
import PDFKit

enum PrintSupport {
    /// NSPrintOperation 在飞标志（跨 PrintSupport/新打印面板共用）。
    private static let operationGate = NSLock()
    nonisolated(unsafe) private static var operationInFlight = false

    /// 当前是否有打印面板在进行（调用方在渲染前用它给明确提示）。
    @MainActor
    static var isPrinting: Bool {
        operationGate.lock()
        defer { operationGate.unlock() }
        return operationInFlight
    }

    /// - Returns: false = 打不开 PDF / 已有打印进行中 / 无法构造打印操作
    ///   （调用方负责提示用户）。
    @MainActor
    @discardableResult
    static func printPDF(at path: String, jobTitle: String) -> Bool {
        operationGate.lock()
        if operationInFlight {
            operationGate.unlock()
            NSSound.beep()
            return false
        }
        operationInFlight = true
        operationGate.unlock()
        defer {
            operationGate.lock()
            operationInFlight = false
            operationGate.unlock()
        }

        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            NSSound.beep()
            return false
        }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.topMargin = 18
        info.bottomMargin = 18
        info.leftMargin = 18
        info.rightMargin = 18
        guard let operation = document.printOperation(
            for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            NSSound.beep()
            return false
        }
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        // run() 返回 false 是「用户取消打印」，不是失败，别弹错。
        _ = operation.run()
        return true
    }
}

/// 打印任务会话闸（渲染 + 系统打印面板整段独占）。
///
/// 与 PrintSupport 里的 NSPrintOperation 闸分工：
/// - 本闸在 UI 层覆盖「生成 PDF（可能几百毫秒）→ 打开打印面板」整段，避免用户
///   连点两次出现两份临时 PDF / 两个 printOperation；
/// - PrintSupport 的闸是最后一道（联系表路径不经过本闸，也必须共享同一份独占）。
@MainActor
enum PrintSessionGate {
    private(set) static var isActive = false

    /// 取得打印会话；已有会话时返回 false（调用方提示"已有打印任务在进行中"）。
    static func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    static func end() {
        isActive = false
    }
}
