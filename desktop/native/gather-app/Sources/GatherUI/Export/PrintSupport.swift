// desktop/native/gather-app/Sources/GatherUI/Export/PrintSupport.swift
// W3：打印联系表（PDF → 系统打印面板）。只做"把已有 PDF 交给打印系统"，
// 不做版面计算（版面在 ContactSheetRenderer）。
import AppKit
import Foundation
import PDFKit

enum PrintSupport {
    /// - Returns: false = 打不开 PDF / 无法构造打印操作（调用方负责提示用户）。
    @MainActor
    @discardableResult
    static func printPDF(at path: String, jobTitle: String) -> Bool {
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
