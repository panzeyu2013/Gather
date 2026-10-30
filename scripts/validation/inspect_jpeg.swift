// scripts/validation/inspect_jpeg.swift
// 独立回读：用 ImageIO（Bridge/C1 同族解析器）读出 EXIF / IPTC / XMP / ICC。
// 用法：swift scripts/validation/inspect_jpeg.swift <file.jpg>
import Foundation
import ImageIO

let args = CommandLine.arguments.dropFirst()
guard let path = args.first, !path.isEmpty else {
    FileHandle.standardError.write(Data("usage: inspect_jpeg.swift <file.jpg>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: path) as CFURL
guard let source = CGImageSourceCreateWithURL(url, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
    FileHandle.standardError.write(Data("cannot read image\n".utf8))
    exit(3)
}
func value(_ key: CFString) -> String {
    guard let raw = properties[key as String] else { return "-" }
    return String(describing: raw)
}
print("file=\(path)")
print("width=\(value(kCGImagePropertyPixelWidth)) height=\(value(kCGImagePropertyPixelHeight))")
print("profile=\(value(kCGImagePropertyProfileName))")

func dump(_ key: CFString, _ label: String) {
    guard let dict = properties[key as String] as? [String: Any], !dict.isEmpty else {
        print("[\(label)] (none)")
        return
    }
    print("[\(label)]")
    for name in dict.keys.sorted() {
        print("\(name)=\(String(describing: dict[name]!))")
    }
}
dump(kCGImagePropertyExifDictionary, "Exif")
dump(kCGImagePropertyIPTCDictionary, "IPTC")
dump(kCGImagePropertyTIFFDictionary, "TIFF")

if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
   let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
    print("[XMP]")
    for tag in tags {
        let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
        let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
        let content = CGImageMetadataTagCopyValue(tag).map { String(describing: $0) } ?? ""
        print("\(prefix):\(name)=\(content)")
    }
} else {
    print("[XMP] (none)")
}
