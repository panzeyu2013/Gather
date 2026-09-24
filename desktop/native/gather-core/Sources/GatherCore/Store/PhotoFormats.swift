// Store/PhotoFormats.swift
// R1：照片格式与分页列清单的唯一来源（旧 PhotoRepo 静态常量改为转调本类型，
// 避免新 Store 与旧 Repo 两份常量漂移；R1 收尾删除旧 Repo 后此处即为唯一定义）。
public enum PhotoFormats {
    /// 原始格式扩展名（RAW+JPEG 配对时优先变体）。
    public static let rawExtensions: [String] = [
        ".nef", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw",
    ]

    /// 由 rawExtensions 推导的 SQL 片段（需 p2 表别名）。
    public static let rawExtensionLikeSQL: String = rawExtensions
        .map { "LOWER(p2.filename) LIKE '%\($0)'" }
        .joined(separator: " OR ")

    /// 目录监听支持的扩展名（无点前缀，WatchCoordinator 用）。
    public static let watchingExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "heif",
        "nef", "arw", "cr2", "cr3", "dng", "raf", "orf", "rw2", "pef", "srw",
        "tif", "tiff", "psd",
    ]

    /// 解码器支持的全部扩展名（含 RAW，带点前缀，RAWDecoder 用）。
    public static let decoderSupportedExtensions: Set<String> = [
        ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp",
        ".cr2", ".cr3", ".nef", ".nrw", ".arw",
        ".raf", ".dng", ".orf", ".rw2", ".pef",
        ".srw", ".srf", ".x3f", ".3fr", ".fff",
        ".mef", ".mos", ".iiq", ".eip", ".erf",
        ".kdc", ".mrw",
    ]

    /// 键集分页与 service 侧共享的列清单（需 p 别名）。
    public static let pageColumns: String = """
    p.rowid, p.id, p.session_id, p.filepath, p.filename, p.status,
      p.asset_id, p.asset_file_id, p.width, p.height, p.checksum, p.created_at, p.updated_at
    """
}
