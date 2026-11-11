// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputShareProofPage.swift
// Wave4c（task-47）：分享策略标记注入（legacy share=nil × 新 proof.js fail-closed 回归）。
//
// 背景：GalleryBuilder 生成的 proof.html 默认带 data-gather-expect-share="0"
// （“本交付包未声明分享策略”），proof.js 只在标记为 "1" 时对 share.json 缺失
// fail-closed，避免 legacy 发布（share=nil，不上传 share.json）把新页面锁死。
//
// 严格发布（share != nil）时由 WebDAV/S3 发布器在上传 proof.html 前把标记改成
// "1"：随后若 share.json 上传失败，C1 已保证整个发布中止，不会出现“声明了
// 分享策略但没有 share.json”的已发布页面；手工上传/旧包保持 "0"/缺省 → 旧回退。
import Foundation
import GatherProtocol

public enum OutputShareProofPage {
    /// 发布器写入/替换的标记名（与 GalleryBuilder/proof.js 保持一致）。
    public static let markerAttribute = "data-gather-expect-share"
    public static let markerDeclared = "1"
    public static let markerUndeclared = "0"

    /// 严格发布时把 proof.html 标记为“已声明分享策略”。
    ///
    /// 只处理 proof.html；没有标记的旧页面原样返回（发布器不应重写未知内容）；
    /// 其他文件/非 UTF-8 数据原样返回。
    public static func declaringSharePolicy(_ data: Data, relativePath: String) -> Data {
        guard relativePath.split(separator: "/").last.map(String.init) == "proof.html" else {
            return data
        }
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let replacement = "\(markerAttribute)=\"\(markerDeclared)\""
        let original = "\(markerAttribute)=\"\(markerUndeclared)\""
        guard text.contains(original) else { return data }
        let updated = text.replacingOccurrences(of: original, with: replacement)
        guard let encoded = updated.data(using: .utf8) else { return data }
        return encoded
    }
}
