// desktop/native/gather-core/Sources/GatherApplication/Services/Output/GalleryBuilder.swift
// 静态 Web 画廊 + 客户校样（本地目录，不联网、不依赖服务器）。
//
// 产物：
//   index.html / gallery.css / gallery.js / data.json
//   thumbs/NNNN.jpg (长边 480)  large/NNNN.jpg (长边 1600)
//   proof.html / proof.js（勾选 → 下载 selection.json）
//
// 设计取舍：缩略图与大图都从**导出后的文件**生成（保证画廊与交付一致），
// 单张失败只跳过该张并计数，不中断整本。
import Foundation
import GatherProtocol
import CoreGraphics
import ImageIO
import GatherAnalysis

public struct GalleryItem: Equatable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let caption: String

    public init(id: String, path: String, name: String, caption: String = "") {
        self.id = id
        self.path = path
        self.name = name
        self.caption = caption
    }
}

public struct GalleryOptions: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var footer: String
    public var thumbnailMaxDimension: Int
    public var largeMaxDimension: Int

    public init(
        title: String = "",
        subtitle: String = "",
        footer: String = "",
        thumbnailMaxDimension: Int = 480,
        largeMaxDimension: Int = 1600
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.thumbnailMaxDimension = max(64, thumbnailMaxDimension)
        self.largeMaxDimension = max(256, largeMaxDimension)
    }
}

public struct GalleryResult: Equatable, Sendable {
    public let indexPath: String
    public let itemCount: Int
    public let skipped: Int
    public let bytes: Int

    public init(indexPath: String, itemCount: Int, skipped: Int, bytes: Int) {
        self.indexPath = indexPath
        self.itemCount = itemCount
        self.skipped = skipped
        self.bytes = bytes
    }
}

public enum GalleryBuilderError: Error, Equatable, CustomStringConvertible {
    case cannotCreateDirectory(String)

    public var code: String { "GALLERY_WRITE_FAILED" }
    public var description: String {
        switch self {
        case .cannotCreateDirectory(let reason): "GALLERY_WRITE_FAILED: " + reason
        }
    }
}

public enum GalleryBuilder {
    public static func build(
        items: [GalleryItem],
        options: GalleryOptions,
        destination: URL,
        isCancelled: () -> Bool = { false }
    ) throws -> GalleryResult {
        // 先生成到隐藏临时目录，成功后整体替换：取消/崩溃不会留下
        // “缩略图已更新、索引还是上一轮”的半成品画廊。
        let finalDestination = destination
        let workDestination = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).partial-\(UUID().uuidString.lowercased())",
            isDirectory: true)
        var committed = false
        defer {
            if !committed {
                do {
                    try FileManager.default.removeItem(at: workDestination)
                } catch {
                    GatherLogger.log("gallery partial cleanup skipped", level: .debug)
                }
            }
        }
        let thumbsDir = workDestination.appendingPathComponent("thumbs", isDirectory: true)
        let largeDir = workDestination.appendingPathComponent("large", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: largeDir, withIntermediateDirectories: true)
        } catch {
            throw GalleryBuilderError.cannotCreateDirectory(String(describing: error))
        }

        var entries: [GalleryEntry] = []
        var skipped = 0
        for item in items {
            if isCancelled() { throw CancellationError() }
            let index = entries.count + 1
            let stem = String(format: "%04d", index)
            let thumbName = stem + ".jpg"
            let largeName = stem + ".jpg"
            let thumbURL = thumbsDir.appendingPathComponent(thumbName)
            let largeURL = largeDir.appendingPathComponent(largeName)
            // 不复用旧缩略图：缩略图按“本次序号”命名，而导出文件可能是 .original
            // 副本（copyItem 保留旧 mtime）。按 mtime 复用会把上一轮另一张照片的图
            // 挂到新照片名下（错图），名字前移时尤其危险。全量重建保证一致性。
            guard render(item.path, to: thumbURL, maxDimension: options.thumbnailMaxDimension),
                  render(item.path, to: largeURL, maxDimension: options.largeMaxDimension) else {
                skipped += 1
                continue
            }
            let size = imageSize(item.path)
            entries.append(GalleryEntry(
                id: item.id, name: item.name, caption: item.caption,
                thumb: "thumbs/" + thumbName, large: "large/" + largeName,
                width: size.width, height: size.height))
        }

        // 清理上次运行残留的编号文件（这次张数更少时）。
        let usedNames = Set(entries.map { $0.large })
            .union(entries.map { $0.thumb })
        for directory in [thumbsDir, largeDir] {
            let files: [String]
            do {
                files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                continue
            }
            for file in files {
                let relative = (directory == thumbsDir ? "thumbs/" : "large/") + file
                guard !usedNames.contains(relative) else { continue }
                do {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                } catch {
                    continue
                }
            }
        }

        let data = try JSONEncoder().encode(entries)
        try data.write(to: workDestination.appendingPathComponent("data.json"), options: .atomic)
        try write(indexHTML(entries: entries, options: options),
                  to: workDestination.appendingPathComponent("index.html"))
        try write(css, to: workDestination.appendingPathComponent("gallery.css"))
        try write(js, to: workDestination.appendingPathComponent("gallery.js"))
        try write(proofHTML(entries: entries, options: options),
                  to: workDestination.appendingPathComponent("proof.html"))
        try write(proofJS, to: workDestination.appendingPathComponent("proof.js"))

        // 原子替换：旧画廊先改名 .old-*，新目录就位后再删旧目录；失败回滚。
        let fileManager = FileManager.default
        let oldDestination = finalDestination.deletingLastPathComponent().appendingPathComponent(
            ".\(finalDestination.lastPathComponent).old-\(UUID().uuidString.lowercased())")
        do {
            if fileManager.fileExists(atPath: finalDestination.path) {
                try fileManager.moveItem(at: finalDestination, to: oldDestination)
            }
            try fileManager.moveItem(at: workDestination, to: finalDestination)
            committed = true
            // 删旧目录失败不影响「新画廊已就位」这个事实：此前会抛错，让 manifest 记
            // failed、galleryPath 为空，而磁盘上其实已经是新画廊。
            if fileManager.fileExists(atPath: oldDestination.path) {
                do {
                    try fileManager.removeItem(at: oldDestination)
                } catch {
                    GatherLogger.log("gallery old directory cleanup failed: \(error)", level: .warn)
                }
            }
        } catch {
            if !fileManager.fileExists(atPath: finalDestination.path),
               fileManager.fileExists(atPath: oldDestination.path) {
                do {
                    try fileManager.moveItem(at: oldDestination, to: finalDestination)
                } catch {
                    GatherLogger.log("gallery rollback failed", level: .error)
                }
            }
            throw GalleryBuilderError.cannotCreateDirectory(String(describing: error))
        }
        // 不再在提交后递归 stat 整本（2 万张 ≈ 4 万次 syscall，且没有任何读取方用 bytes）。
        return GalleryResult(
            indexPath: finalDestination.appendingPathComponent("index.html").path,
            itemCount: entries.count, skipped: skipped, bytes: 0)
    }

    // MARK: - 渲染

    private static func render(_ path: String, to url: URL, maxDimension: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let decoded: RAWDecodeResult
        do {
            decoded = try RAWDecoder.getThumbnail(path: path, size: maxDimension)
        } catch {
            return false
        }
        do {
            try decoded.buffer.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func imageSize(_ path: String) -> (width: Int, height: Int) {
        do {
            return try RAWDecoder.getDimensions(path: path)
        } catch {
            return (0, 0)
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - HTML

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func indexHTML(entries: [GalleryEntry], options: GalleryOptions) -> String {
        let figures = entries.map { entry in
            """
            <figure class="item">
              <a href="\(escapeHTML(entry.large))" data-large="\(escapeHTML(entry.large))" class="thumb">
                <img loading="lazy" src="\(escapeHTML(entry.thumb))" alt="\(escapeHTML(entry.name))">
              </a>
              <figcaption>\(escapeHTML(entry.caption.isEmpty ? entry.name : entry.caption))</figcaption>
            </figure>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(options.title))</title>
        <link rel="stylesheet" href="gallery.css">
        </head>
        <body>
        <header>
          <h1>\(escapeHTML(options.title))</h1>
          <p class="subtitle">\(escapeHTML(options.subtitle))</p>
          <p class="meta">\(entries.count) 张 · <a href="proof.html">客户校样</a></p>
        </header>
        <main class="grid">
        \(figures)
        </main>
        <footer>\(escapeHTML(options.footer))</footer>
        <div id="lightbox" class="lightbox" hidden>
          <button class="nav prev" aria-label="上一张">‹</button>
          <img id="lightbox-image" alt="">
          <button class="nav next" aria-label="下一张">›</button>
          <button class="close" aria-label="关闭">×</button>
        </div>
        <script src="gallery.js"></script>
        </body>
        </html>
        """
    }

    private static func proofHTML(entries: [GalleryEntry], options: GalleryOptions) -> String {
        let cells = entries.map { entry in
            """
            <label class="cell">
              <input type="checkbox" data-id="\(escapeHTML(entry.id))" data-name="\(escapeHTML(entry.name))">
              <img loading="lazy" src="\(escapeHTML(entry.thumb))" alt="\(escapeHTML(entry.name))">
              <span>\(escapeHTML(entry.name))</span>
            </label>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>客户校样 · \(escapeHTML(options.title))</title>
        <link rel="stylesheet" href="gallery.css">
        </head>
        <body class="proof">
        <header>
          <h1>客户校样</h1>
          <p class="subtitle">勾选喜欢的照片，然后下载选择文件回传给摄影师。</p>
          <p class="meta">已选 <span id="picked">0</span> / \(entries.count)</p>
        </header>
        <main class="proof-grid">
        \(cells)
        </main>
        <div class="proof-actions">
          <button id="select-all">全选</button>
          <button id="clear-all">清空</button>
          <button id="download" class="primary">下载选择（selection.json）</button>
        </div>
        <script src="proof.js"></script>
        </body>
        </html>
        """
    }

    private static let css = """
    :root { color-scheme: light dark; }
    body { margin: 0; font: 15px/1.5 -apple-system, "SF Pro Text", system-ui, sans-serif; background: #fafafa; color: #1d1d1f; }
    header { padding: 32px 24px 12px; max-width: 1200px; margin: 0 auto; }
    h1 { font-size: 26px; margin: 0 0 4px; }
    .subtitle { color: #6e6e73; margin: 0; }
    .meta { color: #6e6e73; font-size: 13px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 16px; padding: 16px 24px 48px; max-width: 1200px; margin: 0 auto; }
    .item { margin: 0; background: #fff; border-radius: 10px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
    .item img { display: block; width: 100%; height: auto; }
    figcaption { padding: 8px 10px; font-size: 12px; color: #6e6e73; }
    footer { padding: 24px; color: #6e6e73; font-size: 12px; text-align: center; }
    .lightbox { position: fixed; inset: 0; background: rgba(0,0,0,.92); display: flex; align-items: center; justify-content: center; }
    .lightbox img { max-width: 92vw; max-height: 92vh; }
    .lightbox .close { position: absolute; top: 16px; right: 20px; font-size: 32px; background: none; border: 0; color: #fff; cursor: pointer; }
    .lightbox .nav { position: absolute; top: 50%; transform: translateY(-50%); font-size: 42px; background: none; border: 0; color: #fff; cursor: pointer; padding: 0 16px; }
    .lightbox .prev { left: 8px; } .lightbox .next { right: 8px; }
    .proof-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 12px; padding: 16px 24px 96px; max-width: 1200px; margin: 0 auto; }
    .cell { position: relative; display: block; background: #fff; border-radius: 8px; overflow: hidden; cursor: pointer; }
    .cell input { position: absolute; top: 8px; left: 8px; width: 22px; height: 22px; }
    .cell img { display: block; width: 100%; height: auto; }
    .cell span { display: block; padding: 6px 8px; font-size: 12px; color: #6e6e73; }
    .proof-actions { position: fixed; bottom: 0; left: 0; right: 0; padding: 12px 24px; background: rgba(250,250,250,.92); border-top: 1px solid #e5e5e7; display: flex; gap: 12px; justify-content: flex-end; }
    button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid #d2d2d7; background: #fff; cursor: pointer; }
    button.primary { background: #0071e3; border-color: #0071e3; color: #fff; }
    @media (prefers-color-scheme: dark) {
      body { background: #111; color: #f5f5f7; }
      .item, .cell { background: #1c1c1e; }
      .proof-actions { background: rgba(17,17,17,.92); border-color: #333; }
      button { background: #1c1c1e; color: #f5f5f7; border-color: #333; }
      button.primary { background: #0a84ff; border-color: #0a84ff; }
    }
    """

    private static let js = """
    (function () {
      var links = Array.prototype.slice.call(document.querySelectorAll('a.thumb'));
      var box = document.getElementById('lightbox');
      if (!links.length || !box) return;
      var image = document.getElementById('lightbox-image');
      var current = 0;
      function show(index) {
        current = (index + links.length) % links.length;
        image.src = links[current].getAttribute('data-large');
        box.hidden = false;
      }
      function hide() { box.hidden = true; image.src = ''; }
      links.forEach(function (link, index) {
        link.addEventListener('click', function (event) { event.preventDefault(); show(index); });
      });
      box.querySelector('.close').addEventListener('click', hide);
      box.querySelector('.prev').addEventListener('click', function () { show(current - 1); });
      box.querySelector('.next').addEventListener('click', function () { show(current + 1); });
      document.addEventListener('keydown', function (event) {
        if (box.hidden) return;
        if (event.key === 'Escape') hide();
        if (event.key === 'ArrowLeft') show(current - 1);
        if (event.key === 'ArrowRight') show(current + 1);
      });
    })();
    """

    private static let proofJS = """
    (function () {
      var KEY = 'gather-proof-selection';
      var boxes = Array.prototype.slice.call(document.querySelectorAll('input[type=checkbox]'));
      var picked = document.getElementById('picked');
      function load() {
        try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { return []; }
      }
      function save(ids) { localStorage.setItem(KEY, JSON.stringify(ids)); }
      function refresh() {
        var count = boxes.filter(function (box) { return box.checked; }).length;
        if (picked) picked.textContent = String(count);
      }
      var saved = load();
      boxes.forEach(function (box) {
        box.checked = saved.indexOf(box.getAttribute('data-id')) >= 0;
        box.addEventListener('change', function () {
          var ids = boxes.filter(function (b) { return b.checked; })
            .map(function (b) { return b.getAttribute('data-id'); });
          save(ids);
          refresh();
        });
      });
      refresh();
      document.getElementById('select-all').addEventListener('click', function () {
        boxes.forEach(function (b) { b.checked = true; });
        save(boxes.map(function (b) { return b.getAttribute('data-id'); }));
        refresh();
      });
      document.getElementById('clear-all').addEventListener('click', function () {
        boxes.forEach(function (b) { b.checked = false; });
        save([]);
        refresh();
      });
      document.getElementById('download').addEventListener('click', function () {
        var picks = boxes.filter(function (b) { return b.checked; }).map(function (b) {
          return { id: b.getAttribute('data-id'), name: b.getAttribute('data-name'), pick: true };
        });
        var payload = { version: 1, title: document.title, picks: picks };
        var blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
        var link = document.createElement('a');
        link.href = URL.createObjectURL(blob);
        link.download = 'selection.json';
        link.click();
        URL.revokeObjectURL(link.href);
      });
    })();
    """
}

public struct GalleryEntry: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let caption: String
    public let thumb: String
    public let large: String
    public let width: Int
    public let height: Int
}
