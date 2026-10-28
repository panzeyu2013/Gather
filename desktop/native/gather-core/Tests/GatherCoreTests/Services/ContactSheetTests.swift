// desktop/native/gather-core/Tests/GatherCoreTests/Services/ContactSheetTests.swift
// 交付联系表：分页纯函数 + PDF 渲染（页数/文件有效性/缺图不中断）。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherApplication

private func makeTestJPEG(at path: String, width: Int = 40, height: Int = 30) throws {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let url = URL(fileURLWithPath: path)
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite("交付联系表")
struct ContactSheetTests {

    @Test("分页纯函数：空输入、整除、余数")
    func paginate() {
        #expect(ContactSheetLayout.paginate(count: 0, perPage: 20).isEmpty)
        #expect(ContactSheetLayout.paginate(count: 20, perPage: 20) == [0..<20])
        #expect(ContactSheetLayout.paginate(count: 21, perPage: 20) == [0..<20, 20..<21])
        #expect(ContactSheetLayout.paginate(count: 7, perPage: 5) == [0..<5, 5..<7])
        #expect(ContactSheetLayout.perPage(columns: 4, rows: 5) == 20)
        #expect(ContactSheetLayout.perPage(columns: 0, rows: 0) == 1)
    }

    @Test("渲染：3 张图 → 单页 PDF，页数与文件头正确")
    func renderThreePhotos() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-contact-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var items: [ContactSheetItem] = []
        for index in 0..<3 {
            let path = directory.appendingPathComponent("IMG_\(index).jpg").path
            try makeTestJPEG(at: path)
            items.append(ContactSheetItem(path: path, caption: "IMG_\(index).jpg"))
        }
        let output = directory.appendingPathComponent("sheet.pdf")
        let result = try ContactSheetRenderer.render(
            items: items,
            options: ContactSheetOptions(
                columns: 2, rows: 2, title: "Wedding", subtitle: "2026-10-28", footerText: "Studio"),
            to: output)
        #expect(result.pages == 1)
        #expect(result.failedImages == 0)
        #expect(result.bytes > 1000)

        let document = try #require(CGPDFDocument(URL(fileURLWithPath: output.path) as CFURL))
        #expect(document.numberOfPages == 1)
    }

    @Test("渲染：缺图只留空框，不中断整本；21 张 → 2 页")
    func renderWithMissingImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-contact-miss-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var items: [ContactSheetItem] = []
        for index in 0..<20 {
            let path = directory.appendingPathComponent("IMG_\(index).jpg").path
            try makeTestJPEG(at: path)
            items.append(ContactSheetItem(path: path, caption: "IMG_\(index).jpg"))
        }
        items.append(ContactSheetItem(path: directory.appendingPathComponent("missing.jpg").path, caption: "missing"))
        let output = directory.appendingPathComponent("sheet.pdf")
        let result = try ContactSheetRenderer.render(
            items: items, options: ContactSheetOptions(columns: 4, rows: 5), to: output)
        #expect(result.pages == 2)
        #expect(result.failedImages == 1)
        let document = try #require(CGPDFDocument(URL(fileURLWithPath: output.path) as CFURL))
        #expect(document.numberOfPages == 2)
    }

    @Test("空集合也产出可打开的 1 页 PDF（交付包不留空文件）")
    func renderEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-contact-empty-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("sheet.pdf")
        let result = try ContactSheetRenderer.render(
            items: [], options: ContactSheetOptions(title: "Empty"), to: output)
        #expect(result.pages == 1)
        #expect(result.bytes > 100)
    }
}
