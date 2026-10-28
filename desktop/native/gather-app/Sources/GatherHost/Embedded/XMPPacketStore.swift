// desktop/native/gather-app/Sources/GatherHost/Embedded/XMPPacketStore.swift
// JPEG 内嵌 XMP 包体（APP1 / http://ns.adobe.com/xap/1.0/）的补丁。
//
// 复用侧车同一条 patchDocument 管线（同一张 32 字段表、同一套三态语义、同一份
// 命名空间注入），差别只在"文档来自 JPEG 段"而不是 .xmp 文件。
import Foundation
import GatherProtocol

enum XMPPacketStoreError: Error, Equatable, CustomStringConvertible {
    case notUTF8
    case malformedAfterPatch

    var code: String {
        switch self {
        case .notUTF8: "EMBEDDED_XMP_NOT_UTF8"
        case .malformedAfterPatch: "EMBEDDED_XMP_MALFORMED"
        }
    }

    var description: String {
        switch self {
        case .notUTF8: "EMBEDDED_XMP_NOT_UTF8"
        case .malformedAfterPatch: "EMBEDDED_XMP_MALFORMED"
        }
    }
}

enum XMPPacketStore {
    /// 空包骨架（新建内嵌 XMP 时使用）。命名空间覆盖 32 字段表里用到的全部前缀。
    static let skeleton = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
            xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
            xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/">
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    /// 对现有包体做补丁；existing == nil 时以骨架为底。返回新包体字节。
    static func patched(
        existing: Data?,
        attributes: MetadataWriteAttributes,
        target: String
    ) throws -> Data {
        let document: String
        if let existing, !existing.isEmpty {
            guard let text = String(data: existing, encoding: .utf8) else {
                throw XMPPacketStoreError.notUTF8
            }
            // ImageIO 写出的 XMP 包体末尾常带一个 NUL（APP1 填充）；XMLParser 会因此
            // 判整份文档不合法。NUL 在 XML 里本就不允许，统一剥掉。
            document = text.replacingOccurrences(of: "\u{0}", with: "")
        } else {
            document = skeleton
        }
        let patched = try SidecarXMPProvider.patchDocument(
            document, attributes: attributes, xmpPath: target)
        guard isWellFormedXML(patched) else {
            throw XMPPacketStoreError.malformedAfterPatch
        }
        if !patched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try SidecarXMPProvider.assertNamespacePrefixes(patched, xmpPath: target)
        }
        return Data(patched.utf8)
    }

    private static func isWellFormedXML(_ text: String) -> Bool {
        let parser = XMLParser(data: Data(text.utf8))
        return parser.parse()
    }
}
