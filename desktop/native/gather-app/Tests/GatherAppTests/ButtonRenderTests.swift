// desktop/native/gather-app/Tests/GatherAppTests/ButtonRenderTests.swift
// 按钮渲染采样：把"样式映射"从文档承诺变成像素证据。
//
// 背景：ThemeContrastTests 校核的是 token 之间的对比度，ButtonStylePolicyTests 校核的是
// 页面有没有绕过语义层——两者都证明不了"按钮真的用了那个 token"。这里用 ImageRenderer
// 离屏渲染真实的系统按钮，再比对像素：
//   - prominent 角色的主填充色必须与同 token 的纯色矩形逐像素一致；
//   - secondary 必须完全不着品牌色（macOS 的 tint 只染标签，取消/关闭不该变橙）；
//   - prominent 的标签必须是接近白的高对比色（onAccent）。
//
// 注意：颜色经过 SwiftUI 绘制与色彩管理后不是原始 hex（#B3261E 会渲染成 C23927），
// 所以断言一律用"与同 token 矩形相等"而不是硬编码 RGB。
import AppKit
import SwiftUI
import Testing
@testable import GatherUI

@MainActor
@Suite("按钮渲染采样")
struct ButtonRenderTests {
    private struct Sample {
        let r: Int
        let g: Int
        let b: Int
        let a: Double

        var isOpaque: Bool { a > 0.5 }
        var chroma: Int { max(r, max(g, b)) - min(r, min(g, b)) }
        var isNearWhite: Bool {
            isOpaque && r >= 230 && g >= 230 && b >= 230
        }
        func isClose(to other: Sample, tolerance: Int = 2) -> Bool {
            isOpaque && other.isOpaque
                && abs(r - other.r) <= tolerance
                && abs(g - other.g) <= tolerance
                && abs(b - other.b) <= tolerance
        }
    }

    /// 采样整张图（隔 2px 取一点），返回按出现次数降序的颜色直方图。
    private func samples(of view: some View) throws -> [Sample] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "ImageRenderer 没有产出位图（离屏渲染不可用）")
        let rep = NSBitmapImageRep(cgImage: image)
        var histogram: [String: (Sample, Int)] = [:]
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let sample = Sample(
                    r: Int((c.redComponent * 255).rounded()),
                    g: Int((c.greenComponent * 255).rounded()),
                    b: Int((c.blueComponent * 255).rounded()),
                    a: Double(c.alphaComponent)
                )
                let key = "\(sample.r),\(sample.g),\(sample.b),\(Int(sample.a * 100))"
                histogram[key] = (sample, (histogram[key]?.1 ?? 0) + 1)
            }
        }
        return histogram.values.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// 同 token 的纯色矩形：按钮填充"应该长成"的基准。
    private func tokenFill(_ color: Color) throws -> Sample {
        let squares = try samples(of: Rectangle().fill(color).frame(width: 40, height: 20))
        return try #require(squares.first, "纯色矩形没有采到任何像素")
    }

    private func button(_ title: String, _ role: GatherButtonRole) -> some View {
        Button(title) {}
            .gatherButton(role)
            .frame(width: 120, height: 32)
            .padding(8)
    }

    @Test("prominent 角色的填充就是对应 token，标签为高对比白字")
    func prominentButtonsRenderTokenFill() throws {
        for (role, token, name) in [
            (GatherButtonRole.primary, GatherTheme.accentFill, "accentFill"),
            (.destructiveProminent, GatherTheme.errorFill, "errorFill"),
        ] {
            let expected = try tokenFill(token)
            let rendered = try samples(of: button("确认", role))
            let opaque = rendered.filter(\.isOpaque)
            let fill = try #require(opaque.first, "\(name)：没有采到不透明像素")
            #expect(
                fill.isClose(to: expected),
                "\(name)：按钮填充 \(fill.r),\(fill.g),\(fill.b) 与 token 矩形 \(expected.r),\(expected.g),\(expected.b) 不一致"
            )
            // 先算成 Bool 再断言：把 contains(where: \.isNearWhite) 塞进 #expect 会让
            // Testing 宏把 key-path 当闭包展开，报 rethrows 相关错误。
            let hasWhiteLabel = opaque.contains { $0.isNearWhite }
            #expect(hasWhiteLabel, "\(name)：没有白字像素，标签色可能不是 onAccent")
        }
    }

    @Test("secondary 角色完全不着品牌色（tint 只染标签的坑）")
    func secondaryButtonIsNeutral() throws {
        let rendered = try samples(of: button("取消", .secondary))
        let chromatic = rendered.filter { $0.isOpaque && $0.chroma > 20 }
        #expect(
            chromatic.isEmpty,
            "secondary 出现了带色像素（\(chromatic.prefix(3).map { "\($0.r),\($0.g),\($0.b)" })），描边/标签被品牌色污染"
        )
        let opaque = rendered.filter(\.isOpaque)
        #expect(!opaque.isEmpty, "secondary：没有采到不透明像素，渲染可能是空的")
    }

    @Test("destructive 的标签是危险红，secondary 的标签保持系统中性色")
    func destructiveLabelIsDangerRed() throws {
        // 浅色态下 errorText 与 errorFill 同为 #B3261E（渲染出来都是 C23A27），
        // 所以这里的判据是「不是系统默认标签色」，而不是「等于哪个 token」。
        let dangerToken = try tokenFill(GatherTheme.errorText)
        let rendered = try samples(of: button("删除", .destructive))
        let firstOpaque = rendered.first { $0.isOpaque }
        let label = try #require(firstOpaque, "destructive：没有采到不透明像素（标签未渲染）")
        #expect(
            label.isClose(to: dangerToken, tolerance: 6),
            "destructive 标签色 \(label.r),\(label.g),\(label.b) 与 errorText 矩形 \(dangerToken.r),\(dangerToken.g),\(dangerToken.b) 不一致"
        )

        let neutral = try samples(of: button("取消", .secondary))
        let neutralFirstOpaque = neutral.first { $0.isOpaque }
        let neutralLabel = try #require(neutralFirstOpaque, "secondary：没有采到不透明像素")
        #expect(
            neutralLabel.chroma <= 20,
            "secondary 标签/描边被上了色（\(neutralLabel.r),\(neutralLabel.g),\(neutralLabel.b)），不该带品牌色"
        )
    }

    // 已知限制：`.borderless`（tertiary / tertiaryDanger / gatherIconButton）在 ImageRenderer
    // 下不喷真实标签色（同一控件加不加 tint / foregroundStyle 都是同一张图），
    // 所以二者只做设计文档约定 + 代码里 tint/foregroundStyle 成对写，不做像素断言。
}
