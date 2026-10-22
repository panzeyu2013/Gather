// desktop/native/gather-app/Sources/GatherUI/Support/PhotoThumbnailView.swift
// 3.2/3.3 共享缩略图视图：图像解码端口（ImageDecoderPort）的 SwiftUI 适配。
// TS 源: desktop/src/renderer/api/image.ts thumbnailUrl(path, size)
// 页面经 image decoder port 解码（库内路径 → 解码 JPEG → NSImage，失败显示占位符）。
// NSCache 做进程内内存缓存。
import SwiftUI
import AppKit
import GatherProtocol

/// 查看器的**渐进细节**解码档位（对齐 Bridge / Capture One 的查看器行为）。
///
/// 问题（用户实测）：审片台与灯箱此前把解码尺寸写死（2560 / 2048），放大只是
/// scaleEffect 放大同一张位图——放到 4×/8× 时等于在 Retina 上把 2560px 的图
/// 拉到 5000+ 设备像素，细节全靠插值，越放越糊。
///
/// 这里按「当前缩放级真正需要的像素」选一个**离散档位**重新解码：
/// - 需要像素 = 适配尺寸(pt) × 缩放级 × 屏幕缩放（Retina 2.0）；
/// - 取不小于需要值的最小档位（档位离散 → 连续捏合不会触发解码风暴）；
/// - 上界受源图尺寸与内存上限约束（8192px 单张约 256MB RGBA）。
public enum PhotoDetailTier {
    /// 硬上限：再高只增加内存与解码耗时，不再增加可见细节。
    public static let maxDimension = 8192
    /// 基准档：缩放 ≤1× 时使用（与旧行为一致）。
    public static let baseDimension = 2560
    /// 可选档位（升序）——离散化把「每一帧捏合」折成「跨档才重解码」。
    public static let tiers: [Int] = [2560, 3200, 4096, 5120, 6144, 8192]

    /// 目标解码边长（像素）。
    ///
    /// - Parameters:
    ///   - fitPoints: 图像未缩放时的适配显示尺寸（pt）的最长边。
    ///   - zoom: 当前缩放级（1 = 适配）。
    ///   - backingScale: 屏幕缩放（Retina 一般 2.0）。
    ///   - sourceMaxDimension: 源图最长边（避免超采样解码）。
    /// - Parameter budgetDimension: 本次允许的档位上限（默认硬上限）。对比模式同时
    ///   显示多格时调用方会收窄它——4 格各解码 8192px 会瞬时吃掉约 1GB 内存。
    public static func target(
        fitPoints: Double,
        zoom: Double,
        backingScale: Double,
        sourceMaxDimension: Int,
        budgetDimension: Int = PhotoDetailTier.maxDimension
    ) -> Int {
        guard fitPoints > 0, fitPoints.isFinite else { return baseDimension }
        let safeZoom = zoom.isFinite ? max(1, zoom) : 1
        let safeScale = backingScale > 0 && backingScale.isFinite ? backingScale : 1
        let needed = Int((fitPoints * safeZoom * safeScale).rounded(.up))
        // 源图本身就小于基准档时不要放大解码（避免无意义的内存与耗时）。
        let sourceCeiling = sourceMaxDimension > 0 ? sourceMaxDimension : maxDimension
        // 本次预算与源图能力取小；再与硬上限取小。
        let allowed = min(maxDimension, max(baseDimension, min(budgetDimension, sourceCeiling)))
        let tier = tiers.first { $0 >= needed } ?? maxDimension
        return min(allowed, max(baseDimension, tier))
    }

    /// 对比模式（同一屏 N 格）下的档位预算：格数越多，单格越不该申请超大解码。
    public static func budget(forVisibleCells count: Int) -> Int {
        switch count {
        case ..<2: return maxDimension
        case 2: return 5120
        default: return 4096
        }
    }
}

/// 查看器几何：把「当前缩放/平移下真正可见的图像区域」算成归一化矩形 + 视图矩形。
///
/// 与渲染共用同一套坐标模型（fit 居中 + scaleEffect 绕中心 + offset），
/// 因此细节层（只解可见区域）与底层低分辨率图**像素级对齐**。
public enum PhotoViewerGeometry {
    public struct DetailTile: Equatable {
        /// 需要解码的归一化矩形（左上原点，含少量余量）。
        public var normalizedRect: CGRect
        /// 该矩形在视图坐标里的落位（用于放置细节层）。
        public var viewRect: CGRect
    }

    /// 计算可见区域的细节层。返回 nil = 当前缩放级下底层位图已经足够（不需要细节层）。
    ///
    /// - Parameters:
    ///   - imageSize: 图像的像素/点尺寸（取宽高比即可）。
    ///   - viewSize: 查看器单元格尺寸（pt）。
    ///   - zoom: 当前缩放级。
    ///   - panOffset: 平移量（含人脸对齐位移，必须与渲染用的同一个值）。
    ///   - backingPixelBudget: 底层位图最长边的像素数（超过它才需要细节层）。
    ///   - padding: 归一化余量（减少平移时重解码；默认 0.12）。
    public static func detailTile(
        imageSize: CGSize,
        viewSize: CGSize,
        zoom: Double,
        panOffset: CGSize,
        backingPixelBudget: Int,
        padding: Double = 0.12
    ) -> DetailTile? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0,
              zoom > 1, zoom.isFinite else { return nil }
        let fitScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let base = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        // 底层位图在屏幕上的像素密度：还没被放大到超出位图分辨率时不需要细节层。
        let baseLongest = Double(max(base.width, base.height))
        guard baseLongest > 0 else { return nil }
        let backing = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let onScreenPixels = baseLongest * zoom * backing
        guard onScreenPixels > Double(backingPixelBudget) else { return nil }

        let displayed = CGSize(width: base.width * zoom, height: base.height * zoom)
        let origin = CGPoint(
            x: viewSize.width / 2 - displayed.width / 2 + panOffset.width,
            y: viewSize.height / 2 - displayed.height / 2 + panOffset.height
        )
        let visible = CGRect(origin: origin, size: displayed)
            .intersection(CGRect(origin: .zero, size: viewSize))
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }

        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: (point.x - origin.x) / displayed.width,
                y: (point.y - origin.y) / displayed.height
            )
        }
        let topLeft = normalized(visible.origin)
        let bottomRight = normalized(CGPoint(x: visible.maxX, y: visible.maxY))
        let raw = CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
        ).insetBy(dx: -(bottomRight.x - topLeft.x) * padding, dy: -(bottomRight.y - topLeft.y) * padding)
        let clamped = raw.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        // 归一化矩形 → 视图矩形（用同一套线性映射反算，保证像素级对齐）。
        let viewRect = CGRect(
            x: origin.x + clamped.minX * displayed.width,
            y: origin.y + clamped.minY * displayed.height,
            width: clamped.width * displayed.width,
            height: clamped.height * displayed.height
        )
        return DetailTile(normalizedRect: clamped, viewRect: viewRect)
    }

    /// 细节层需要的像素边长：按视图矩形 × 屏幕缩放，量化到 256 的倍数（提高缓存复用），
    /// 并受调用方预算（对比模式按格数收窄）与硬上限约束。
    public static func tilePixelSize(viewRect: CGRect, budgetDimension: Int) -> Int {
        let backing = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let needed = Double(max(viewRect.width, viewRect.height)) * backing
        let quantized = Int((needed / 256).rounded(.up)) * 256
        return min(max(256, quantized), max(256, min(budgetDimension, PhotoDetailTier.maxDimension)))
    }
}

/// 按需加载的缩略图（对齐 TS GalleryThumbnail 的 IntersectionObserver 懒加载：
/// SwiftUI 惰性容器只会实例化可见行的视图，onAppear 即触发加载）。
public struct PhotoThumbnailView: View {
    let path: String
    var size: Int
    var placeholderSize: CGSize?
    /// true 时走 gather-image://preview 语义（getPreview，大图预览）。
    var preview: Bool
    /// 图片适配模式：默认 .fill（封面裁切，用于缩略图网格）；查看器传 .fit
    /// （整图可见，对齐旧版 object-fit: contain 的查看器交互语义）。
    var contentMode: ContentMode

    /// 当前应显示的 cache key（B5）：由 .task(id:) 在任务启动时写入，
    /// 异步解码返回后与它比较，避免值类型 self 快照导致的错图覆盖。
    @State private var activeLoadKey = ""
    /// 已成功显示的**照片路径**（渐进细节档位切换时判断「同一张图、只换档位」）。
    @State private var loadedPath = ""
    @State private var image: NSImage?
    @State private var failed = false
    @State private var loading = false

    public init(path: String, size: Int = 512, placeholderSize: CGSize? = nil, preview: Bool = false, contentMode: ContentMode = .fill) {
        self.path = path
        self.size = size
        self.placeholderSize = placeholderSize
        self.preview = preview
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                // TS: thumbError —— 感叹号 + 文件名。
                ZStack {
                    Rectangle().fill(GatherTheme.backgroundSecondary)
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            } else {
                Rectangle()
                    .fill(GatherTheme.backgroundSecondary)
                    .overlay {
                        if loading {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: placeholderSize?.width, height: placeholderSize?.height)
        .task(id: cacheKey) {
            // B5（9-30 审查）：过期判定必须与**当前**视图比较。视图是值类型，
            // 异步任务捕获的是启动时的 self 快照——旧实现里的 key == cacheKey
            // 比的是「旧键 == 旧键」，永远成立，晚返回的旧图会覆盖新图。
            // 这里把当前键写进 @State（所有副本共享同一份存储），任务返回后
            // 与它比较；同时检查任务取消。
            activeLoadKey = cacheKey
            await load(for: cacheKey)
        }
    }

    private func load(for key: String) async {
        guard key == activeLoadKey else { return }
        if let cached = PhotoThumbnailCache.image(for: key) {
            image = cached
            loadedPath = path
            failed = false
            loading = false
            return
        }
        // 渐进细节（PhotoDetailTier）：同一张照片换档位（size 变、path 不变）时
        // **保留当前低分辨率图**继续显示，直到新档位解码完成再替换——否则每次
        // 跨档都会闪一下占位符。只有换了照片（path 变）才立即清空。
        let samePhoto = loadedPath == path && image != nil
        if !samePhoto {
            image = nil
        }
        failed = false
        loading = true
        // 图像解码（100-800ms）移出主线程：image decoder port 的实现必须
        // 无状态/可并发，可安全在后台调用；完成后回主线程设置 image。
        let path = path
        let size = size
        let preview = preview
        do {
            // A-2/A-3：统一的异步解码入口（闸门 + 取消 + 磁盘缓存）。
            let data = try await PhotoThumbnailDecoder.decodeAsync(path: path, size: size, preview: preview)
            // Task.detached 不继承取消：因此这里既查任务取消，也比对**共享的**
            // 当前键（B5）——key 已变时丢弃旧结果。
            guard !Task.isCancelled, key == activeLoadKey else { return }
            guard let nsImage = NSImage(data: data) else {
                failed = true
                loading = false
                return
            }
            PhotoThumbnailCache.setImage(nsImage, for: key)
            image = nsImage
            loadedPath = path
        } catch {
            // 过期任务的失败同样不应污染新 key 的状态。
            guard !Task.isCancelled, key == activeLoadKey else { return }
            failed = true
        }
        loading = false
    }

    private var cacheKey: String {
        PhotoThumbnailCache.key(path: path, size: size, preview: preview)
    }
}

/// 人脸裁切缩略图（F05）：按归一化 bbox 裁出脸部区域。
///
/// 为什么需要它：人脸审核的任务是判断「这些脸是不是同一个人」，整图缩略图
/// （尤其小尺寸下）提供不了这个证据——同一张照片里的两张脸更是完全无法区分。
/// bbox 来自检测阶段（FaceEncodeResult.bbox：**左上原点**的归一化 [x, y, w, h]）。
///
/// 实现说明：不做 CoreGraphics 二次裁剪，而是把整幅预览图放大后按 bbox 中心
/// 平移——少一次位图拷贝，且窗口尺寸变化时不会失真。
public struct FaceCropThumbnailView: View {
    let path: String
    let bbox: [Double]
    /// 预览解码目标边长（越大裁切后越清晰，代价是解码时间与内存）。
    var loadSize: Int
    /// 检测框外的余量比例（检测框通常贴着脸的边界，留一点更像「人像」）。
    var margin: Double

    /// 当前应显示的 cache key（B5）：与 PhotoThumbnailView 同一机制。
    @State private var activeLoadKey = ""
    /// 已成功显示的**照片路径**（渐进细节档位切换时判断「同一张图、只换档位」）。
    @State private var loadedPath = ""
    @State private var image: NSImage?
    @State private var failed = false

    public init(path: String, bbox: [Double], loadSize: Int = 512, margin: Double = 0.25) {
        self.path = path
        self.bbox = bbox
        self.loadSize = loadSize
        self.margin = margin
    }

    /// 直接注入已解码图像（单测/预览用）：跳过文件读取与解码。
    ///
    /// 存在的理由（N02 教训）：裁切换算曾经**单测通过但仍然错裁**——因为测试
    /// 复述了换算公式，而不是验证真实渲染结果。这个入口让测试可以用
    /// ImageRenderer 把视图渲染成位图，再按像素断言「中心就是脸」。
    init(previewImage: NSImage, bbox: [Double], margin: Double = 0.25) {
        self.path = ""
        self.bbox = bbox
        self.loadSize = 0
        self.margin = margin
        _image = State(initialValue: previewImage)
    }

    public var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            ZStack {
                GatherTheme.backgroundSecondary
                if let image {
                    let layout = Self.layout(
                        imageSize: image.size,
                        bbox: bbox,
                        frame: frame,
                        margin: margin
                    )
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: layout.displayed.width, height: layout.displayed.height)
                        .offset(x: layout.offset.width, y: layout.offset.height)
                } else if failed {
                    Image(systemName: "person.crop.square")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: max(0, frame.width), height: max(0, frame.height))
            .clipped()
        }
        .task(id: cacheKey) {
            // B5：同 PhotoThumbnailView —— 用共享 @State 当前键做过期判定。
            activeLoadKey = cacheKey
            await load(for: cacheKey)
        }
    }

    /// bbox → 「整图显示尺寸 + 平移量」的纯换算（可单测）。
    ///
    /// 缩放取两个方向的较大者：bbox 区域**覆盖**整个 frame（cover 语义），
    /// 因此人脸不会被拉伸变形；多余的边缘由 .clipped() 裁掉。
    ///
    /// **坐标模型必须与视图一致**（N02 的错因）：图像在 ZStack 里是**居中**
    /// 布局的，它的左上角位于 ((frame.w − displayed.w)/2, (frame.h − displayed.h)/2)。
    /// 因此把 bbox 中心搬到 frame 中心所需平移量是
    ///   ((0.5 − box.midX) · displayed.w, (0.5 − box.midY) · displayed.h)
    /// 而不是 (frame.w/2 − box.midX·displayed.w)——后者只在「图像左上角与 frame
    /// 左上角重合」时成立，落在居中布局上会让脸偏出画面（实测只剩色条/错位图块）。
    static func layout(
        imageSize: CGSize,
        bbox: [Double],
        frame: CGSize,
        margin: Double
    ) -> (displayed: CGSize, offset: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0,
              frame.width > 0, frame.height > 0 else { return (.zero, .zero) }
        // 缺 bbox（老数据/整图）或非法/退化 bbox → 整图：宁可显示整图，
        // 也不给一个空白或错位的裁切。
        guard bbox.count >= 4 else { return fit(imageSize: imageSize, frame: frame) }
        let x = bbox[0], y = bbox[1], w = bbox[2], h = bbox[3]
        guard w.isFinite, h.isFinite, x.isFinite, y.isFinite, w > 0.001, h > 0.001 else {
            return fit(imageSize: imageSize, frame: frame)
        }
        let marginX = w * margin
        let marginY = h * margin
        // 展开后收敛回图像范围：框外的区域没有像素，向它索要面积只会得到空白边
        //（贴边人脸 + 余量展开就会命中）。
        let box = CGRect(
            x: x - marginX,
            y: y - marginY,
            width: w + marginX * 2,
            height: h + marginY * 2
        )
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard box.width > 0.001, box.height > 0.001 else {
            return fit(imageSize: imageSize, frame: frame)
        }
        let scale = max(
            frame.width / (box.width * imageSize.width),
            frame.height / (box.height * imageSize.height)
        )
        let displayed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        // 居中布局下的平移量（推导见函数头注）：与 frame 尺寸无关，只与
        // displayed 尺寸和 bbox 中心有关。
        let offset = CGSize(
            width: (0.5 - box.midX) * displayed.width,
            height: (0.5 - box.midY) * displayed.height
        )
        return (displayed, offset)
    }

    private static func fit(imageSize: CGSize, frame: CGSize) -> (displayed: CGSize, offset: CGSize) {
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let displayed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return (displayed, .zero)
    }

    private var cacheKey: String {
        // A-9（性能审计）：裁切是**视图内的几何平移**（layout 只改 offset/尺寸），
        // 解码结果与 bbox 无关。旧键含 bbox ⇒ 同一张照片 N 张脸各解一次整图预览。
        "facecrop:\(path)#\(loadSize)"
    }

    private func load(for key: String) async {
        // 注入图像（loadSize == 0 / 无路径）：不读文件，也不清空注入的图。
        guard loadSize > 0, !path.isEmpty else { return }
        guard key == activeLoadKey else { return }
        if let cached = PhotoThumbnailCache.image(for: key) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        let path = path
        let size = loadSize
        do {
            // A-2/A-9（第二轮验证）：不再裸 Task.detached —— 人脸页一屏 20-40 个裁切
            // 会同时解码（limit=4 形同虚设），且同照片 N 张脸各解一次。
            // 走统一入口：受闸门约束、同键去重，并顺带拿到磁盘缓存。
            let data = try await PhotoThumbnailDecoder.decodeAsync(path: path, size: size, preview: true)
            guard !Task.isCancelled, key == activeLoadKey else { return }
            guard let nsImage = NSImage(data: data) else {
                failed = true
                return
            }
            PhotoThumbnailCache.setImage(nsImage, for: key)
            image = nsImage
            loadedPath = path
        } catch {
            guard !Task.isCancelled, key == activeLoadKey else { return }
            failed = true
        }
    }
}

/// 异步解码闸门（A-2 性能审计）。
///
/// 旧实现用 `DispatchSemaphore(4)` 在 `Task.detached` 里**阻塞**协作线程池，
/// 且取消只丢弃结果——快速滚动时最多 200 个任务排队占线程，屏上内容被排在
/// 陈旧请求之后。actor 版：排队不占线程、取名额前检查取消、同键在飞去重。
/// 在飞去重的任务盒子（引用语义：用于「只清理自己登记的那一份」的 identity 校验）。
final class PhotoDecodeTaskBox: @unchecked Sendable {
    let task: Task<Data, Error>
    /// 等待者计数（A-2 残余，第二轮验证）：归零即取消在飞解码——否则滚走/切图后
    /// 已没人要的结果仍会占着闸门名额跑完（RAW 100-800ms）。
    private let lock = NSLock()
    private var waiters = 0

    init(_ task: Task<Data, Error>) { self.task = task }

    func addWaiter() {
        lock.lock(); waiters += 1; lock.unlock()
    }

    func removeWaiter() {
        lock.lock()
        waiters -= 1
        let noWaitersLeft = waiters <= 0
        lock.unlock()
        if noWaitersLeft { task.cancel() }
    }
}

public actor PhotoDecodeGate {
    public static let shared = PhotoDecodeGate(limit: 4)
    /// 区域解码（放大细节贴片）独立闸门：贴片与整图解码互不排队，但自身也受限。
    public static let region = PhotoDecodeGate(limit: 2)

    private let limit: Int
    private var running = 0
    private var inFlight: [String: PhotoDecodeTaskBox] = [:]

    init(limit: Int) { self.limit = max(1, limit) }

    /// 取名额；返回 false = 等待期间被取消（调用方必须放弃解码且不释放名额）。
    ///
    /// 用「可取消睡眠 + 退避」而不是 checked continuation 排队：continuation 在
    /// 等待期间**不会**因任务取消而 resume（取消的等待者会永久挂起，并让 inFlight
    /// 永不清理）。退避把空转的 actor hop 从固定 20ms 降到 2→4→…→20ms。
    func acquire() async -> Bool {
        var backoff = Duration.milliseconds(2)
        while true {
            if running < limit {
                running += 1
                return true
            }
            do {
                try await Task.sleep(for: backoff)
            } catch {
                return false   // 已取消
            }
            if Task.isCancelled { return false }
            backoff = backoff < .milliseconds(20) ? backoff * 2 : .milliseconds(20)
        }
    }

    func release() {
        running = max(0, running - 1)
    }

    /// 单次 actor 事务完成「查已有 / 创建并登记」——两次独立 await（check-then-act）
    /// 会让同键并发调用各自建一个任务（重复解码），这里合并掉这个窗口。
    func taskBox(for key: String, make: () -> PhotoDecodeTaskBox) -> PhotoDecodeTaskBox {
        if let existing = inFlight[key] { return existing }
        let box = make()
        inFlight[key] = box
        return box
    }

    /// 只清理**自己**登记的那一份（避免清掉后来者的在飞任务）。
    func remove(_ box: PhotoDecodeTaskBox, for key: String) {
        if inFlight[key] === box { inFlight[key] = nil }
    }
}

/// 后台解码（并发上限由 PhotoDecodeGate 管；磁盘缓存见 ThumbnailDiskCache）。
public enum PhotoThumbnailDecoder {
    /// 同步解码（保留给 IPC/测试等无取消语义的调用点）。
    public static func decode(path: String, size: Int, preview: Bool) throws -> Data {
        try decodeUncached(path: path, size: size, preview: Bool(preview))
    }

    private static func decodeUncached(path: String, size: Int, preview: Bool) throws -> Data {
        // Cut 3 / 3b-3（E-04）：经 ImageDecoderPort 解码，GatherUI 不 import 分析层。
        let decoder = try ImageDecodingRegistry.current()
        let decoded: ImageDecodeResult
        if preview {
            decoded = try decoder.getPreview(path: path, maxDimension: size)
        } else {
            decoded = try decoder.getThumbnail(path: path, size: size)
        }
        return decoded.buffer
    }

    /// 带取消、异步闸门、同键去重与磁盘缓存的解码（视图层统一入口）。
    public static func decodeAsync(path: String, size: Int, preview: Bool) async throws -> Data {
        try Task.checkCancellation()
        let key = "\(preview ? "preview" : "thumb"):\(path)#\(size)"
        // 单次 actor 事务：查已有 / 否则创建并登记（关闭 check-then-act 的重复解码窗口）。
        let box = await PhotoDecodeGate.shared.taskBox(for: key) {
            PhotoDecodeTaskBox(Task<Data, Error> {
                if let cached = ThumbnailDiskCache.data(path: path, size: size, preview: preview) {
                    return cached
                }
                try Task.checkCancellation()
                let acquired = await PhotoDecodeGate.shared.acquire()
                guard acquired else { throw CancellationError() }
                defer { Task { await PhotoDecodeGate.shared.release() } }
                // 取到名额后再查一次：排队期间可能已被取消（滚动离开/换照片）。
                try Task.checkCancellation()
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let decoded = try decodeUncached(path: path, size: size, preview: preview)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
                ThumbnailDiskCache.store(data, path: path, size: size, preview: preview)
                return data
            })
        }
        defer { Task { await PhotoDecodeGate.shared.remove(box, for: key) } }
        box.addWaiter()
        defer { box.removeWaiter() }
        return try await Self.awaitShared(box)
    }

    /// 等待共享解码结果，**等待期间被取消就立刻返回**。
    ///
    /// 直接 await box.task.value 时，取消等待者并不会让它提前返回——defer 里的
    /// removeWaiter 就永远不会执行，在飞任务也就不会被取消。这里用一个可取消的
    /// 探针任务与共享结果赛跑：取消时探针抛错、函数立刻返回，等待者计数随之归零。
    private static func awaitShared(_ box: PhotoDecodeTaskBox) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await box.task.value }
            group.addTask {
                // 取消时 Task.sleep 抛出；正常路径由 group.next() 先拿到结果后 cancelAll。
                while true { try await Task.sleep(for: .milliseconds(50)) }
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// **区域解码**（异步）：独立闸门（limit 2，不与整图解码互相排队），
    /// 避免多格同时放大时排出一串重解码；注释与实现一致（第二轮验证指出原注释是假的）。
    public static func decodeRegionAsync(
        path: String,
        normalizedRect: CGRect,
        maxPixel: Int
    ) async throws -> ImageRegionDecodeResult {
        let acquired = await PhotoDecodeGate.region.acquire()
        guard acquired else { throw CancellationError() }
        defer { Task { await PhotoDecodeGate.region.release() } }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ImageRegionDecodeResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let decoded = try decodeRegion(path: path, normalizedRect: normalizedRect, maxPixel: maxPixel)
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 区域解码（同步；无闸门，供内部/测试复用）。
    public static func decodeRegion(
        path: String,
        normalizedRect: CGRect,
        maxPixel: Int
    ) throws -> ImageRegionDecodeResult {
        return try ImageDecodingRegistry.current().decodeRegion(
            path: path,
            normalizedRect: normalizedRect,
            maxPixel: maxPixel
        )
    }
}

/// 只解码**可见区域**的高分辨率细节层。
///
/// 与底层低分辨率图叠加使用：底层负责整体构图与手势（立即显示、不闪），
/// 细节层负责放大后的真实像素。二者共用 PhotoViewerGeometry.detailTile 的几何，
/// 因此叠加是像素级对齐的。
///
/// 未就绪或解码失败时渲染 Color.clear——绝不遮挡底层图
///（失败就退化成「糊但能看到」，不会白屏）。
public struct PhotoDetailTileView: View {
    let path: String
    let normalizedRect: CGRect
    let targetPixel: Int
    /// 区域解码不可用（平台或格式不支持）时回调一次，供调用方退回整图高档位。
    var onUnavailable: (() -> Void)?

    @State private var image: NSImage?
    @State private var activeKey = ""

    public init(
        path: String,
        normalizedRect: CGRect,
        targetPixel: Int,
        onUnavailable: (() -> Void)? = nil
    ) {
        self.path = path
        self.normalizedRect = normalizedRect
        self.targetPixel = targetPixel
        self.onUnavailable = onUnavailable
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: cacheKey) {
            activeKey = cacheKey
            await load(for: cacheKey)
        }
    }

    /// 缓存键：路径 + 量化后的归一化矩形 + 目标像素。
    /// 矩形按 1/128 量化——平移时的小块变化仍命中同一缓存项。
    private var cacheKey: String {
        let q = 128.0
        let x = (normalizedRect.minX * q).rounded() / q
        let y = (normalizedRect.minY * q).rounded() / q
        let w = max(1 / q, (normalizedRect.width * q).rounded() / q)
        let h = max(1 / q, (normalizedRect.height * q).rounded() / q)
        return "region:\(path)#\(x),\(y),\(w),\(h)#\(targetPixel)"
    }

    private func load(for key: String) async {
        guard key == activeKey else { return }
        if let cached = PhotoThumbnailCache.image(for: key) {
            image = cached
            return
        }
        let path = path
        let rect = normalizedRect
        let maxPixel = targetPixel
        do {
            let decoded = try await PhotoThumbnailDecoder.decodeRegionAsync(
                path: path,
                normalizedRect: rect,
                maxPixel: maxPixel
            )
            guard !Task.isCancelled, key == activeKey else { return }
            guard let nsImage = NSImage(data: decoded.buffer) else {
                onUnavailable?()
                return
            }
            PhotoThumbnailCache.setImage(nsImage, for: key)
            image = nsImage
        } catch {
            guard !Task.isCancelled, key == activeKey else { return }
            // 区域解码不可用（例如平台/格式不支持）：交给调用方退回整图高档位。
            onUnavailable?()
        }
    }
}

/// 缩略图缓存盒子：NSCache 非 Sendable，不能直接作为静态属性持有。
/// 线程安全说明（Swift 6 `Sendable`）：可变状态 `cache`（条目与
/// totalCostLimit）只在 `lock`（NSLock）临界区内读写，读接口
/// `object(forKey:)` 与写接口 `setObject(_:forKey:cost:)` 均不回调外部代码，
/// 因此不会在锁内重入。锁纪律无法被编译器静态验证，故标注 `@unchecked`。
private final class PhotoThumbnailCacheBox: @unchecked Sendable {
    let cache: NSCache<NSString, NSImage>
    let lock = NSLock()

    init() {
        // 审计 P1-性能：2048px preview ≈16MB/张，浏览 1 万张可致 GB 级内存。
        // 按解码尺寸计入 cost：256 桶 ≈1MB、1024 ≈4MB、2048 ≈16MB（粗估
        // NSImage 位深/缩放开销），全缓存上限 512MB 后按 LRU 淘汰。
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 512 * 1024 * 1024
        self.cache = cache
    }
}

/// 缩略图加载缓存（进程内，键 = 模式 + path + size）。
public enum PhotoThumbnailCache {
    /// 缓存键的**唯一**生成处（显示与预取共用，防止两边漂移导致永不命中）。
    public static func key(path: String, size: Int, preview: Bool) -> String {
        "\(preview ? "preview" : "thumb"):\(path)#\(size)"
    }

    private static let box = PhotoThumbnailCacheBox()

    public static func image(for key: String) -> NSImage? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.cache.object(forKey: key as NSString)
    }

    public static func setImage(_ image: NSImage, for key: String) {
        box.lock.lock()
        defer { box.lock.unlock() }
        let size = image.size.width * image.size.height
        // 粗估：RGBA 4B/像素 + 20% 元数据开销；小图下限 256KB 防过度淘汰。
        let cost = max(256 * 1024, Int(size * 4 * 1.2))
        box.cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
