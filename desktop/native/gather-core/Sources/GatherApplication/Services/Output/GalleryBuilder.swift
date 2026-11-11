// desktop/native/gather-core/Sources/GatherApplication/Services/Output/GalleryBuilder.swift
// 静态 Web 画廊 + 客户校样（本地目录，不联网、不依赖服务器）。
//
// 产物：
//   index.html / gallery.css / gallery.js / data.json（v2：{version, items}）
//   thumbs/NNNN.jpg (长边 480)  large/NNNN.jpg (长边 1600)
//   proof.html / proof.js（勾选 + 星级 + 色标 + 评论 → 下载 selection.json v2）
//
// 设计取舍：
// - 缩略图与大图都从**导出后的文件**生成（保证画廊与交付一致）；
// - 单张失败只跳过该张并计数，不中断整本；
// - 元数据走共享模型 DeliveryPresentationItem：data.json 带全量字段（前端可排序/
//   筛选），index.html 只按 options.fields 叠加星条/色标 —— 默认不改变老画布；
// - data.json v2 是 **对象**（{version:2, items:[…]}），GalleryDataFile 同时解 v1 数组；
// - 灯箱大图加载失败自动退回缩略图：发布端 allowDownload=false 时不传 large/，
//   画廊仍可浏览（清晰度降级，这是有意的取舍）。

import Foundation
import GatherProtocol
import CoreGraphics
import ImageIO
import GatherAnalysis

/// 画廊单张：展示字段 + 导出产物路径（与联系表同一份模型）。
public struct GalleryItem: Equatable, Sendable {
    public var presentation: DeliveryPresentationItem
    /// figcaption 文案（空串 = 用文件名）。
    public var caption: String

    public var id: String { presentation.photoId }
    public var path: String { presentation.filePath }
    public var name: String { presentation.filename }

    public init(presentation: DeliveryPresentationItem) {
        self.presentation = presentation
        self.caption = presentation.caption ?? ""
    }

    /// 兼容旧调用点（无元数据）。
    public init(id: String, path: String, name: String, caption: String = "") {
        self.presentation = DeliveryPresentationItem(
            photoId: id, filePath: path, filename: name)
        self.caption = caption
    }
}

public struct GalleryOptions: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var footer: String
    public var thumbnailMaxDimension: Int
    public var largeMaxDimension: Int
    /// index.html 叠加哪些元数据（星条/色标/取舍）。data.json 始终带全量字段。
    public var fields: ContactSheetFields

    public init(
        title: String = "",
        subtitle: String = "",
        footer: String = "",
        thumbnailMaxDimension: Int = 480,
        largeMaxDimension: Int = 1600,
        fields: ContactSheetFields = [.rating, .label, .pick]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.thumbnailMaxDimension = max(64, thumbnailMaxDimension)
        self.largeMaxDimension = max(256, largeMaxDimension)
        self.fields = fields
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
        // "缩略图已更新、索引还是上一轮"的半成品画廊。
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
            // 不复用旧缩略图：缩略图按"本次序号"命名，而导出文件可能是 .original
            // 副本（copyItem 保留旧 mtime）。按 mtime 复用会把上一轮另一张照片的图
            // 挂到新照片名下（错图），名字前移时尤其危险。全量重建保证一致性。
            guard render(item.path, to: thumbURL, maxDimension: options.thumbnailMaxDimension),
                  render(item.path, to: largeURL, maxDimension: options.largeMaxDimension) else {
                skipped += 1
                continue
            }
            let size = imageSize(item.path)
            let presentation = item.presentation
            entries.append(GalleryEntry(
                id: item.id, name: item.name, caption: item.caption,
                thumb: "thumbs/" + thumbName, large: "large/" + largeName,
                width: size.width, height: size.height,
                title: presentation.title,
                rating: presentation.rating,
                label: presentation.effectiveLabel,
                pick: presentation.pick,
                keywords: presentation.keywords,
                captureTime: presentation.captureTime,
                triage: presentation.triageVerdict?.rawValue))
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

        let data = try JSONEncoder().encode(
            GalleryDataFile(version: GalleryDataFile.currentVersion, items: entries))
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

    /// 图上的徽标：星条 + 色点（由 options.fields 决定画不画）。
    private static func badgeHTML(_ entry: GalleryEntry, fields: ContactSheetFields) -> String {
        var parts: [String] = []
        if fields.contains(.rating), let rating = entry.rating, rating > 0 {
            let filled = String(repeating: "\u{2605}", count: rating)
            let empty = String(repeating: "\u{2606}", count: max(0, 5 - rating))
            parts.append("<span class=\"stars\">" + filled + empty + "</span>")
        }
        if fields.contains(.label), let label = entry.label,
           let hex = ColorLabelPalette.hex(for: label) {
            parts.append("<i class=\"dot\" style=\"background:" + hex + "\" title=\""
                + escapeHTML(label) + "\"></i>")
        }
        if fields.contains(.pick), let pick = entry.pick, pick != .unreviewed {
            let text = pick == .picked ? "PICK" : "REJECT"
            let kind = pick == .picked ? "pick" : "reject"
            parts.append("<span class=\"pick " + kind + "\">" + text + "</span>")
        }
        guard !parts.isEmpty else { return "" }
        return "<span class=\"badge\">" + parts.joined() + "</span>"
    }

    private static func indexHTML(entries: [GalleryEntry], options: GalleryOptions) -> String {
        let figures = entries.map { entry in
            let dataAttributes = "data-id=\"" + escapeHTML(entry.id)
                + "\" data-rating=\"" + String(entry.rating ?? 0)
                + "\" data-label=\"" + escapeHTML(entry.label ?? "")
                + "\" data-pick=\"" + escapeHTML(entry.pick?.rawValue ?? PickState.unreviewed.rawValue)
                + "\" data-keywords=\"" + escapeHTML((entry.keywords ?? []).joined(separator: ", "))
                + "\" data-title=\"" + escapeHTML(entry.title ?? "")
                + "\" data-capture=\"" + escapeHTML(entry.captureTime ?? "") + "\""
            return """
            <figure class="item" \(dataAttributes)>
              <a href="\(escapeHTML(entry.large))" data-large="\(escapeHTML(entry.large))" data-thumb="\(escapeHTML(entry.thumb))" class="thumb">
                <img loading="lazy" src="\(escapeHTML(entry.thumb))" alt="\(escapeHTML(entry.name))">
                \(badgeHTML(entry, fields: options.fields))
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

    private static let labelOptions: String = {
        let names = ["", "Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple"]
        return names.map { name in
            let text = name.isEmpty ? "无" : name
            return "<option value=\"" + name + "\">" + text + "</option>"
        }.joined()
    }()

    private static func proofHTML(entries: [GalleryEntry], options: GalleryOptions) -> String {
        let cells = entries.map { entry in
            let stars = (1...5).map { index in
                "<button type=\"button\" class=\"star\" data-rating=\"\(index)\" aria-label=\"\(index) 星\">\u{2605}</button>"
            }.joined()
            return """
            <div class="cell" data-id="\(escapeHTML(entry.id))" data-name="\(escapeHTML(entry.name))">
              <input type="checkbox" class="pick" aria-label="选择 \(escapeHTML(entry.name))">
              <img loading="lazy" src="\(escapeHTML(entry.thumb))" alt="\(escapeHTML(entry.name))">
              <div class="cell-meta">
                <span class="cell-name">\(escapeHTML(entry.name))</span>
                <span class="stars" role="group" aria-label="星级">\(stars)</span>
                <select class="label" aria-label="色标">\(labelOptions)</select>
                <button type="button" class="comment-toggle">评论</button>
                <textarea class="comment" rows="2" placeholder="给摄影师的话（可选）" hidden></textarea>
              </div>
            </div>
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
        <body class="proof gate-pending">
        <header>
          <h1>客户校样</h1>
          <p class="subtitle">勾选喜欢的照片，可以加星级、色标和评论，然后下载选择文件回传给摄影师。</p>
          <p class="meta">已选 <span id="picked">0</span> / \(entries.count)</p>
          <p class="meta" id="expiry-note" hidden></p>
          <p class="meta" id="locked-note" hidden></p>
          <p class="meta">口令与到期只是页面提示，不是加密；服务器上的文件不会自动删除（无服务端强制）。</p>
        </header>
        <section id="password-gate" class="gate" hidden aria-live="polite">
          <h2>需要访问口令</h2>
          <p class="meta">口令仅用于限制访问，页面内容并未加密（只防随手翻阅），请勿在此放置敏感素材。</p>
          <input id="gate-password" type="password" autocomplete="current-password" placeholder="输入口令">
          <button id="gate-submit" type="button" class="primary">进入校样</button>
          <p class="meta" id="gate-error" hidden></p>
        </section>
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
    .thumb { position: relative; display: block; }
    .badge { position: absolute; left: 8px; bottom: 8px; display: flex; align-items: center; gap: 6px; padding: 3px 7px; border-radius: 999px; background: rgba(0,0,0,.55); color: #fff; font-size: 11px; line-height: 1; }
    .badge .stars { letter-spacing: 1px; }
    .badge .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
    .badge .pick { font-weight: 600; }
    .badge .pick.reject { color: #ff9f9f; }
    figcaption { padding: 8px 10px; font-size: 12px; color: #6e6e73; }
    footer { padding: 24px; color: #6e6e73; font-size: 12px; text-align: center; }
    .lightbox { position: fixed; inset: 0; background: rgba(0,0,0,.92); display: flex; align-items: center; justify-content: center; }
    .lightbox img { max-width: 92vw; max-height: 92vh; }
    .lightbox .close { position: absolute; top: 16px; right: 20px; font-size: 32px; background: none; border: 0; color: #fff; cursor: pointer; }
    .lightbox .nav { position: absolute; top: 50%; transform: translateY(-50%); font-size: 42px; background: none; border: 0; color: #fff; cursor: pointer; padding: 0 16px; }
    .lightbox .prev { left: 8px; } .lightbox .next { right: 8px; }
    .proof-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; padding: 16px 24px 96px; max-width: 1200px; margin: 0 auto; }
    .cell { position: relative; display: block; background: #fff; border-radius: 8px; overflow: hidden; }
    .cell input.pick { position: absolute; top: 8px; right: 8px; width: 22px; height: 22px; }
    .cell img { display: block; width: 100%; height: auto; }
    .cell-meta { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; padding: 6px 8px; font-size: 12px; color: #6e6e73; }
    .cell-name { flex: 1 1 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .cell .stars { display: inline-flex; }
    .cell .star { border: 0; background: none; padding: 0 1px; font-size: 14px; line-height: 1; color: #c7c7cc; cursor: pointer; }
    .cell .star.on { color: #ff9f0a; }
    .cell select.label { font: inherit; font-size: 11px; padding: 2px 4px; border-radius: 6px; }
    .cell .comment-toggle { font-size: 11px; padding: 2px 8px; }
    .cell textarea.comment { flex: 1 1 100%; font: inherit; font-size: 12px; padding: 6px; border-radius: 6px; border: 1px solid #d2d2d7; resize: vertical; }
    .proof-actions { position: fixed; bottom: 0; left: 0; right: 0; padding: 12px 24px; background: rgba(250,250,250,.92); border-top: 1px solid #e5e5e7; display: flex; gap: 12px; justify-content: flex-end; }
    button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid #d2d2d7; background: #fff; cursor: pointer; }
    button.primary { background: #0071e3; border-color: #0071e3; color: #fff; }
    .locked .cell, .locked .proof-actions { opacity: .65; }
    .gate-pending .proof-grid, .gate-pending .proof-actions, .gate-pending #picked { visibility: hidden; }
    .gate { max-width: 560px; margin: 32px auto; padding: 24px; border: 1px solid #d2d2d7; border-radius: 12px; background: #fff; }
    .gate h2 { margin: 0 0 8px; font-size: 20px; }
    .gate input { width: 100%; box-sizing: border-box; padding: 10px 12px; margin: 12px 0; border: 1px solid #d2d2d7; border-radius: 8px; font: inherit; }
    .gated .proof-grid, .gated .proof-actions { display: none; }
    @media (prefers-color-scheme: dark) {
      body { background: #111; color: #f5f5f7; }
      .item, .cell { background: #1c1c1e; }
      .proof-actions { background: rgba(17,17,17,.92); border-color: #333; }
      button { background: #1c1c1e; color: #f5f5f7; border-color: #333; }
      button.primary { background: #0a84ff; border-color: #0a84ff; }
      .cell textarea.comment { background: #1c1c1e; color: #f5f5f7; border-color: #333; }
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
        var large = links[current].getAttribute('data-large');
        var thumb = links[current].getAttribute('data-thumb');
        // 发布端 allowDownload=false 时不传 large/：大图 404 自动退回缩略图，
        // 灯箱仍然可用（清晰度降级，这是有意的取舍）。
        image.onerror = function () {
          if (thumb && image.getAttribute('src') !== thumb) { image.src = thumb; }
        };
        image.src = large || thumb || '';
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

    // Wave4b：internal 而非 private —— ProofPageScriptTests 用 node 驱动真实脚本做
    // fail-closed/到期/口令闸的 JS 级回归（避免只断言字符串子串）。
    static let proofJS = """
    (function () {
      // v2：localStorage 存 {version:2, items:{ id: {pick,rating,label,comment} }}；
      // v1 键（id 数组）自动迁移，老客户回传不会丢勾选。
      var KEY = 'gather-proof-v2';
      var LEGACY_KEY = 'gather-proof-selection';
      var SUBMITTED_KEY = 'gather-proof-submitted';
      var cells = Array.prototype.slice.call(document.querySelectorAll('.cell'));
      var pickedOut = document.getElementById('picked');
      var note = document.getElementById('locked-note');
      var locked = false;

      // ---- Wave3（task-17）：口令门 + 到期提示（纯前端，非加密） ----
      // Wave4b 说明：新生成的 proof.html/js 一律带 gate-pending/gate DOM（即使本次
      // 没配口令/到期）——这是新页面的默认安全态；旧已发布包自带旧 proof.*，不受影响。
      // 强制：body 初始带 gate-pending（内容不可见），拿到 share.json 后再决定；
      // 没有 share.json / fetch 不可用（旧分享包/file://）则放行，保持旧行为。
      var shareState = null;
      var needsGate = false;
      var gateVerified = false;
      // Wave4a-C2：到期只读；C1：share.json 读不到时 fail-closed（http 发布）。
      var expired = false;
      var shareLoadFailed = false;
      var gate = document.getElementById('password-gate');
      var gateInput = document.getElementById('gate-password');
      var gateSubmit = document.getElementById('gate-submit');
      var gateError = document.getElementById('gate-error');
      var expiryNote = document.getElementById('expiry-note');

      function setActionsDisabled(disabled) {
        var actions = document.querySelectorAll('.proof-actions button');
        Array.prototype.forEach.call(actions, function (el) { el.disabled = disabled; });
      }
      function setGated(on) {
        document.body.classList.toggle('gated', !!on);
        if (gate) { gate.hidden = !on; }
        if (on) {
          gateVerified = false;
          setActionsDisabled(true);
        } else if (!locked) {
          setActionsDisabled(false);
        }
      }
      function gateMessage(text) {
        if (gateError) { gateError.hidden = !text; gateError.textContent = text || ''; }
      }
      function hexToBytes(hex) {
        var clean = String(hex || '').replace(/[^0-9a-f]/gi, '');
        var bytes = new Uint8Array(Math.floor(clean.length / 2));
        for (var i = 0; i < bytes.length; i++) {
          bytes[i] = parseInt(clean.substr(i * 2, 2), 16);
        }
        return bytes;
      }
      function bytesToHex(buffer) {
        var view = new Uint8Array(buffer);
        var out = '';
        for (var i = 0; i < view.length; i++) {
          out += ('0' + view[i].toString(16)).slice(-2);
        }
        return out;
      }
      function unlockAfterGate() {
        gateVerified = true;
        setGated(false);
        if (gate) { gate.hidden = true; }
        gateMessage('');
      }
      function verifyGate() {
        if (!shareState) { return; }
        var password = gateInput ? gateInput.value : '';
        if (!password) { gateMessage('请输入口令'); return; }
        if (!window.crypto || !window.crypto.subtle || !window.TextEncoder) {
          gateMessage('当前浏览器环境不支持口令校验（需要 HTTPS）。请不要通过此链接分享。');
          return;
        }
        var salt = hexToBytes(shareState.passwordSalt);
        var iterations = Number(shareState.passwordIterations) || 100000;
        var expected = String(shareState.passwordHash || '').toLowerCase();
        window.crypto.subtle.importKey(
          'raw', new TextEncoder().encode(password), { name: 'PBKDF2' }, false, ['deriveBits']
        ).then(function (key) {
          return window.crypto.subtle.deriveBits(
            { name: 'PBKDF2', salt: salt, iterations: iterations, hash: 'SHA-256' }, key, 256);
        }).then(function (bits) {
          if (bytesToHex(bits) === expected) { unlockAfterGate(); }
          else { gateMessage('口令不正确'); }
        }).catch(function () {
          gateMessage('口令校验失败，请重试');
        });
      }
      if (gateSubmit) { gateSubmit.addEventListener('click', verifyGate); }
      if (gateInput) {
        gateInput.addEventListener('keydown', function (event) {
          if (event.key === 'Enter') { event.preventDefault(); verifyGate(); }
        });
      }
      function applyShare(share) {
        shareState = share || {};
        document.body.classList.remove('gate-pending');
        var expires = share && share.expiresAt ? Date.parse(share.expiresAt) : NaN;
        if (share && share.expiresAt && !isNaN(expires) && expiryNote) {
          expiryNote.hidden = false;
          expiryNote.textContent = '有效期至 ' + share.expiresAt
            + '（到期后页面只读；没有服务端强制，文件不会自动删除）。';
        }
        if (!isNaN(expires) && Date.now() > expires) {
          expired = true;
          setLocked('分享已于 ' + share.expiresAt
            + ' 到期，当前为只读状态（没有服务端强制，文件仍可访问）。');
          // C2：到期后连「重新下载 selection.json」也禁用（submit 里另有 early return）。
          var expiredDownload = document.getElementById('download');
          if (expiredDownload) {
            expiredDownload.disabled = true;
            expiredDownload.textContent = '已过期（只读）';
          }
        }
        if (share && share.passwordHash) {
          needsGate = true;
          setGated(true);
          return;
        }
        setGated(false);
      }

      function readJSON(key, fallback) {
        try {
          var raw = window.localStorage.getItem(key);
          if (!raw) return fallback;
          return JSON.parse(raw);
        } catch (e) { return fallback; }
      }
      function writeJSON(key, value) {
        try { window.localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* 隐私模式 */ }
      }
      function load() {
        var saved = readJSON(KEY, null);
        if (saved && typeof saved === 'object' && !Array.isArray(saved)) {
          return saved.items || {};
        }
        var map = {};
        var legacy = readJSON(LEGACY_KEY, []);
        if (Array.isArray(legacy)) {
          legacy.forEach(function (id) { map[id] = { pick: true, rating: 0, label: '', comment: '' }; });
        }
        return map;
      }
      var state = load();

      function entryFor(id) {
        if (!state[id]) { state[id] = { pick: false, rating: 0, label: '', comment: '' }; }
        return state[id];
      }
      function save() { writeJSON(KEY, { version: 2, items: state }); }
      function refresh() {
        var count = cells.filter(function (cell) {
          return cell.querySelector('input.pick').checked;
        }).length;
        if (pickedOut) pickedOut.textContent = String(count);
      }
      function setLocked(reason) {
        locked = true;
        document.body.classList.add('locked');
        cells.forEach(function (cell) {
          Array.prototype.forEach.call(cell.querySelectorAll('input, button, select, textarea'), function (el) {
            el.disabled = true;
          });
        });
        var actions = document.querySelectorAll('.proof-actions button');
        Array.prototype.forEach.call(actions, function (el) {
          if (el.id !== 'download') { el.disabled = true; }
        });
        var download = document.getElementById('download');
        if (download) { download.textContent = '重新下载 selection.json'; }
        if (note) { note.hidden = false; note.textContent = reason; }
      }

      cells.forEach(function (cell) {
        var id = cell.getAttribute('data-id');
        var entry = entryFor(id);
        var box = cell.querySelector('input.pick');
        var stars = Array.prototype.slice.call(cell.querySelectorAll('button.star'));
        var select = cell.querySelector('select.label');
        var toggle = cell.querySelector('button.comment-toggle');
        var area = cell.querySelector('textarea.comment');
        // 提前取出字段并规范化：v1 迁移来的对象缺 rating/label/comment。
        var rating = Number(entry.rating) || 0;
        box.checked = !!entry.pick;
        select.value = entry.label || '';
        area.value = entry.comment || '';
        if (area.value) { area.hidden = false; toggle.textContent = '收起评论'; }
        stars.forEach(function (button) {
          if (Number(button.getAttribute('data-rating')) <= rating) { button.classList.add('on'); }
        });

        box.addEventListener('change', function () {
          entry.pick = box.checked;
          save(); refresh();
        });
        stars.forEach(function (button) {
          button.addEventListener('click', function () {
            var value = Number(button.getAttribute('data-rating'));
            // 再点同一个星 = 取消该星级（0）。
            entry.rating = (Number(entry.rating) === value) ? 0 : value;
            stars.forEach(function (other) {
              if (Number(other.getAttribute('data-rating')) <= Number(entry.rating)) {
                other.classList.add('on');
              } else {
                other.classList.remove('on');
              }
            });
            save();
          });
        });
        select.addEventListener('change', function () {
          entry.label = select.value;
          save();
        });
        toggle.addEventListener('click', function () {
          area.hidden = !area.hidden;
          toggle.textContent = area.hidden ? '评论' : '收起评论';
          if (!area.hidden) { area.focus(); }
        });
        area.addEventListener('input', function () {
          entry.comment = area.value;
          save();
        });
      });
      refresh();

      var selectAll = document.getElementById('select-all');
      var clearAll = document.getElementById('clear-all');
      if (selectAll) {
        selectAll.addEventListener('click', function () {
          cells.forEach(function (cell) {
            cell.querySelector('input.pick').checked = true;
            entryFor(cell.getAttribute('data-id')).pick = true;
          });
          save(); refresh();
        });
      }
      if (clearAll) {
        clearAll.addEventListener('click', function () {
          cells.forEach(function (cell) {
            cell.querySelector('input.pick').checked = false;
            entryFor(cell.getAttribute('data-id')).pick = false;
          });
          save(); refresh();
        });
      }

      function submit() {
        // C2：到期后只读；C1：share.json 不可读时锁定。两者都在此 early return，
        // 防止通过控制台/快捷键绕过按钮 disabled 生成提交文件。
        if (expired || shareLoadFailed) { return; }
        // 口令门未通过时不得提交（纯前端门槛；防止绕过 disabled 直接调函数）。
        if (needsGate && !gateVerified) { return; }
        var items = cells.map(function (cell) {
          var id = cell.getAttribute('data-id');
          var entry = entryFor(id);
          return {
            id: id,
            name: cell.getAttribute('data-name'),
            pick: !!entry.pick,
            rating: Number(entry.rating) || 0,
            label: entry.label || '',
            comment: entry.comment || ''
          };
        }).filter(function (item) {
          return item.pick || item.rating > 0 || item.label || item.comment;
        });
        var payload = {
          version: 2,
          title: document.title,
          submittedAt: new Date().toISOString(),
          items: items
        };
        writeJSON(SUBMITTED_KEY, payload.submittedAt);
        var blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
        var link = document.createElement('a');
        link.href = URL.createObjectURL(blob);
        link.download = 'selection.json';
        link.click();
        URL.revokeObjectURL(link.href);
        setLocked('已提交，可重新下载。如需修改，请与摄影师联系。');
      }

      var download = document.getElementById('download');
      if (download) { download.addEventListener('click', submit); }

      // 提交后锁定（本地记录）+ 分享过期后禁止提交（share.json 可选；取不到就不管）。
      var submittedAt = readJSON(SUBMITTED_KEY, null);
      if (submittedAt) { setLocked('已提交，可重新下载。'); }
      // C1：http(s) 发布却读不到 share.json —— 保持门槛关闭（fail-closed），
      // 不再退回“无口令/无到期”的放行页；file:// 本地预览保留旧回退。
      function handleShareUnavailable() {
        if (window.location.protocol === 'file:') {
          document.body.classList.remove('gate-pending');
          return;
        }
        shareLoadFailed = true;
        setActionsDisabled(true);
        if (note) {
          note.hidden = false;
          note.textContent = '无法读取分享配置（share.json 缺失或不可访问）：'
            + '页面已锁定，请重新发布或联系摄影师。';
        }
      }
      function loadShare(paths, index) {
        if (!window.fetch || index >= paths.length) {
          handleShareUnavailable();
          return;
        }
        window.fetch(paths[index], { cache: 'no-store' }).then(function (response) {
          if (!response.ok) { throw new Error('missing'); }
          return response.json();
        }).then(function (share) {
          applyShare(share);
        }).catch(function () {
          loadShare(paths, index + 1);
        });
      }
      // 发布根可能比画廊目录高一层（share.json 在交付包根目录）：两条都试。
      loadShare(['share.json', '../share.json'], 0);
    })();
    """
}

/// data.json 的 v2 容器：{version: 2, items: [...]}。
///
/// 同时兼容 v1 的**顶层数组**（升级前的 data.json），所以老画廊被新代码读回不炸。
public struct GalleryDataFile: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var items: [GalleryEntry]

    public init(version: Int = GalleryDataFile.currentVersion, items: [GalleryEntry]) {
        self.version = version
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case version, items }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            // v1：顶层就是数组（此时 version = 1）。
            let entries = try container.decode([GalleryEntry].self)
            self.version = 1
            self.items = entries
            return
        } catch {
            // 不是数组 → 按 v2 对象继续解析（不要吞掉真正的坏 JSON）。
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try keyed.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.items = try keyed.decodeIfPresent([GalleryEntry].self, forKey: .items) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: CodingKeys.self)
        try keyed.encode(version, forKey: .version)
        try keyed.encode(items, forKey: .items)
    }

    /// 读回 data.json（v1/v2 皆可）。
    public static func load(_ data: Data) throws -> GalleryDataFile {
        try JSONDecoder().decode(GalleryDataFile.self, from: data)
    }
}

public struct GalleryEntry: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let caption: String
    public let thumb: String
    public let large: String
    public let width: Int
    public let height: Int
    // v2 增量字段（全部可选：旧 data.json 缺键仍可解）。
    public let title: String?
    public let rating: Int?
    public let label: String?
    public let pick: PickState?
    public let keywords: [String]?
    public let captureTime: String?
    public let triage: String?
}
