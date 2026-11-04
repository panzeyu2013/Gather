// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataParseSegments.swift
// 一次解码得到的元数据分段（IFD0/EXIF/GPS/XMP/dc/IIM）。
//
// #1 C4：从 GatherApplication 的 MetadataProviders.swift 上移。读盘侧（MetadataIO）与
// 抽取侧（Application）都要用它，属于共享词汇，放 Protocol 才不用互相当依赖。
import Foundation

/// TS: exifr.parse 的分段输出（ifd0/exif/gps/xmp/dc/iptc，mergeOutput: false）。
public struct MetadataParseSegments: Equatable, Sendable {
    public var ifd0: JSONValue?
    public var exif: JSONValue?
    public var gps: JSONValue?
    public var xmp: JSONValue?
    public var dc: JSONValue?
    public var iptc: JSONValue?
    /// 内嵌 XMP 里**存在但可能为空**的键（local name，含 dc 段）。
    ///
    /// 为什么需要：清空字段后 XMP 会留下空元素，而 IIM 若还没删就会把旧值"复活"。
    /// 读侧据此把「存在但为空」当显式清空，停止向 IIM 回退。
    public var xmpPresentKeys: Set<String>

    public init(
        ifd0: JSONValue? = nil,
        exif: JSONValue? = nil,
        gps: JSONValue? = nil,
        xmp: JSONValue? = nil,
        dc: JSONValue? = nil,
        iptc: JSONValue? = nil,
        xmpPresentKeys: Set<String> = []
    ) {
        self.ifd0 = ifd0
        self.exif = exif
        self.gps = gps
        self.xmp = xmp
        self.dc = dc
        self.iptc = iptc
        self.xmpPresentKeys = xmpPresentKeys
    }
}
