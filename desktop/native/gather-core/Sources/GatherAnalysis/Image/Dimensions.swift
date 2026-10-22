// desktop/native/gather-core/Sources/GatherAnalysis/Image/Dimensions.swift
// fast-dimensions 移植（Phase 2 任务 2.1「解码 + 缩略图」）。
//
// TS 源：desktop/src/main/services/image/decoders/fast-dimensions.ts
//   readDimensions(buf, ext)：单遍状态机读取 JPEG/PNG/GIF/BMP/WebP/TIFF 尺寸，
//   buf < 12 字节返回 null。
//
// 移植说明：
//   - 逐字节语义与 TS 完全一致，含全部边界行为：JPEG 仅认 SOF0/1/2（C0/C1/C2）
//     与段长校验、PNG 直读偏移 12 的 "IHDR"、BMP 宽有符号/高取绝对值、
//     WebP VP8/VP8L/VP8X 三分支、TIFF II/MM 字节序与 IFD 链（至多 4 段）、
//     ext 兜底 .tif/.tiff。
//   - TS 对 Buffer 的越界读返回 undefined（比较恒 false），Swift 数组越界即
//     崩溃；本移植以守卫/长度校验保证所有读取落在界内，语义等价
//     （detectFormat 仅在 buf.count >= 12 时调用，buf[0..11] 全部在界内）。
//   - JS 位运算在 int32 上执行，Swift 以 UInt32 复算；VP8L 的 >> 14 与 & 0x3FFF
//     组合下算术/逻辑移位结果一致，无需模拟符号扩展。
//   - VP8X 分支按 TS 原样从偏移 18 读 3 字节小端宽（即 chunk size 低 2 字节 +
//     flags 字节，与标准 VP8X 布局有偏差但保持移植一致）。

import Foundation

public enum ImageDimensions {
    /// 读取图片宽高；无法识别或尺寸不合法时返回 nil（语义与 TS readDimensions 一致）。
    public static func read(_ data: Data, ext: String) -> (width: Int, height: Int)? {
        let buf = [UInt8](data)
        guard buf.count >= 12 else { return nil }

        switch detectFormat(buf, ext: ext) {
        case .jpeg: return readJpeg(buf)
        case .png: return readPng(buf)
        case .gif: return readGif(buf)
        case .bmp: return readBmp(buf)
        case .webp: return readWebp(buf)
        case .tiff: return readTiff(buf)
        case nil: return nil
        }
    }

    private enum Format {
        case jpeg, png, gif, bmp, webp, tiff
    }

    private static func detectFormat(_ buf: [UInt8], ext: String) -> Format? {
        if buf[0] == 0xFF && buf[1] == 0xD8 { return .jpeg }
        if buf[0] == 0x89 && buf[1] == 0x50 && buf[2] == 0x4E && buf[3] == 0x47 { return .png }
        if buf[0] == 0x47 && buf[1] == 0x49 && buf[2] == 0x46 { return .gif }
        if buf[0] == 0x42 && buf[1] == 0x4D { return .bmp }
        if buf[0] == 0x52 && buf[1] == 0x49 && buf[2] == 0x46 && buf[3] == 0x46 {
            if buf[8] == 0x57 && buf[9] == 0x45 && buf[10] == 0x42 && buf[11] == 0x50 { return .webp }
        }
        if (buf[0] == 0x49 && buf[1] == 0x49 && buf[2] == 0x2A && buf[3] == 0x00)
            || (buf[0] == 0x4D && buf[1] == 0x4D && buf[2] == 0x00 && buf[3] == 0x2A) {
            return .tiff
        }
        if ext == ".tif" || ext == ".tiff" { return .tiff }
        return nil
    }

    private static func readJpeg(_ buf: [UInt8]) -> (width: Int, height: Int)? {
        var i = 0
        while i < buf.count - 5 {
            if buf[i] == 0xFF {
                let marker = buf[i + 1]
                if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                    let length = u16BE(buf, i + 2)
                    if length >= 7 && i + 2 + length <= buf.count {
                        let h = u16BE(buf, i + 5)
                        let w = u16BE(buf, i + 7)
                        if w > 0 && h > 0 { return (w, h) }
                        i += 2 + length - 1
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func readPng(_ buf: [UInt8]) -> (width: Int, height: Int)? {
        guard buf.count >= 24 else { return nil }
        if buf[12] != 0x49 || buf[13] != 0x48 || buf[14] != 0x44 || buf[15] != 0x52 { return nil }
        let w = u32BE(buf, 16)
        let h = u32BE(buf, 20)
        if w > 0 && h > 0 { return (w, h) }
        return nil
    }

    private static func readGif(_ buf: [UInt8]) -> (width: Int, height: Int)? {
        guard buf.count >= 10 else { return nil }
        let w = u16LE(buf, 6)
        let h = u16LE(buf, 8)
        if w > 0 && h > 0 { return (w, h) }
        return nil
    }

    private static func readBmp(_ buf: [UInt8]) -> (width: Int, height: Int)? {
        guard buf.count >= 26 else { return nil }
        let w = i32LE(buf, 18)
        let h = Int(i32LE(buf, 22).magnitude)
        if Int(w) > 0 && h > 0 { return (Int(w), h) }
        return nil
    }

    private static func readWebp(_ buf: [UInt8]) -> (width: Int, height: Int)? {
        guard buf.count >= 30 else { return nil }
        if buf[12] == 0x56 && buf[13] == 0x50 && buf[14] == 0x38 && buf[15] == 0x20 {
            let w = u16LE(buf, 26) & 0x3FFF
            let h = u16LE(buf, 28) & 0x3FFF
            if w > 0 && h > 0 { return (w, h) }
        } else if buf[12] == 0x56 && buf[13] == 0x50 && buf[14] == 0x38 && buf[15] == 0x4C {
            let bits = u32LE(buf, 21)
            let w = Int(bits & 0x3FFF) + 1
            let h = Int((bits >> 14) & 0x3FFF) + 1
            if w > 0 && h > 0 { return (w, h) }
        } else if buf[12] == 0x56 && buf[13] == 0x50 && buf[14] == 0x38 && buf[15] == 0x58 {
            if buf.count < 24 { return nil }
            let w = (u24LE(buf, 18) & 0xFFFFFF) + 1
            let h = (u24LE(buf, 21) & 0xFFFFFF) + 1
            if w > 0 && h > 0 { return (w, h) }
        }
        return nil
    }

    private static func readTiff(_ buf: [UInt8]) -> (width: Int, height: Int)? {
        guard buf.count >= 8 else { return nil }
        let isLE = buf[0] == 0x49

        var offset = r32(buf, isLE, 4)
        var ifd = 0
        while ifd < 4 && offset + 2 <= buf.count {
            let n = r16(buf, isLE, offset)
            var w = 0
            var h = 0
            var i = 0
            while i < n && offset + 2 + (i + 1) * 12 <= buf.count {
                let eo = offset + 2 + i * 12
                let tag = r16(buf, isLE, eo)
                let type = r16(buf, isLE, eo + 2)
                let valOffset = eo + 8
                if tag == 0x0100 { w = type == 3 ? r16(buf, isLE, valOffset) : r32(buf, isLE, valOffset) }
                if tag == 0x0101 { h = type == 3 ? r16(buf, isLE, valOffset) : r32(buf, isLE, valOffset) }
                i += 1
            }
            if w > 0 && h > 0 { return (w, h) }
            if offset + 2 + n * 12 + 4 > buf.count { break }
            offset = r32(buf, isLE, offset + 2 + n * 12)
            ifd += 1
        }
        return nil
    }

    // ── 字节读取（所有调用点均已由各自解析器的长度守卫保证界内）──

    private static func u16BE(_ buf: [UInt8], _ o: Int) -> Int {
        (Int(buf[o]) << 8) | Int(buf[o + 1])
    }

    private static func u32BE(_ buf: [UInt8], _ o: Int) -> Int {
        (Int(buf[o]) << 24) | (Int(buf[o + 1]) << 16) | (Int(buf[o + 2]) << 8) | Int(buf[o + 3])
    }

    private static func u16LE(_ buf: [UInt8], _ o: Int) -> Int {
        Int(buf[o]) | (Int(buf[o + 1]) << 8)
    }

    private static func u32LE(_ buf: [UInt8], _ o: Int) -> UInt32 {
        UInt32(buf[o]) | (UInt32(buf[o + 1]) << 8) | (UInt32(buf[o + 2]) << 16) | (UInt32(buf[o + 3]) << 24)
    }

    private static func u24LE(_ buf: [UInt8], _ o: Int) -> Int {
        Int(buf[o]) | (Int(buf[o + 1]) << 8) | (Int(buf[o + 2]) << 16)
    }

    private static func i32LE(_ buf: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: u32LE(buf, o))
    }

    private static func r16(_ buf: [UInt8], _ isLE: Bool, _ o: Int) -> Int {
        isLE ? u16LE(buf, o) : u16BE(buf, o)
    }

    private static func r32(_ buf: [UInt8], _ isLE: Bool, _ o: Int) -> Int {
        isLE ? Int(u32LE(buf, o)) : u32BE(buf, o)
    }
}
