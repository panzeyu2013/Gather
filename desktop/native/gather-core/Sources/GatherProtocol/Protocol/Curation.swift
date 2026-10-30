// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Curation.swift
// P1 下一波：手动集合 / 堆栈 / 保存查询的类型。

import Foundation

public struct CollectionSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var name: String
    public var itemCount: Int
    public var sortOrder: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        sessionId: String,
        name: String,
        itemCount: Int = 0,
        sortOrder: Int = 0,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.itemCount = itemCount
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CollectionMember: Codable, Equatable, Sendable {
    public var photoId: String
    public var position: Int
    /// 展示用路径 / 文件名（集合视图直接渲染缩略图，不再二次查照片）。
    /// 堆栈成员只填 photoId/position（网格已有照片行，不需要重复路径）。
    public var filepath: String
    public var filename: String

    public init(
        photoId: String,
        position: Int,
        filepath: String = "",
        filename: String = ""
    ) {
        self.photoId = photoId
        self.position = position
        self.filepath = filepath
        self.filename = filename
    }
}

public struct CollectionCreateInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var name: String

    public init(sessionId: String, name: String) {
        self.sessionId = sessionId
        self.name = name
    }
}

public struct CollectionItemsInput: Codable, Equatable, Sendable {
    public var collectionId: String
    public var photoIds: [String]

    public init(collectionId: String, photoIds: [String]) {
        self.collectionId = collectionId
        self.photoIds = photoIds
    }
}

public struct StackSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var name: String
    public var coverPhotoId: String?
    public var memberCount: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        sessionId: String,
        name: String = "",
        coverPhotoId: String? = nil,
        memberCount: Int = 0,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.memberCount = memberCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StackCreateInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var name: String
    public var photoIds: [String]
    public var coverPhotoId: String?

    public init(
        sessionId: String,
        name: String = "",
        photoIds: [String],
        coverPhotoId: String? = nil
    ) {
        self.sessionId = sessionId
        self.name = name
        self.photoIds = photoIds
        self.coverPhotoId = coverPhotoId
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// P1 下一波 §3.8 / §3.9：集合与堆栈的输入/折叠视图、跨工作区重复、预览分析 DTO。
//
// 归属决策（父 agent 2026-10-30 约束）：**不新增协议域**。集合/堆栈挂在
// AlbumAPI（同属策展，smart_albums 的邻居），跨工作区重复挂在 DuplicateAPI；
// 两者的新方法都由协议扩展给默认实现（空数组 / 抛 INVALID_PARAM），既有
// Stub 与 Preview 实现不因新方法而编译失败。
//
// 这里只放 DTO；纯几何/像素算法在 GatherAnalysis/Preview/PreviewAnalysis.swift，
// 由宿主实现 PreviewAnalysisPort 后经 GatherUI 的注册表暴露（UI 不得 import 分析层）。
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - 集合（§3.8.1）

/// 重命名集合（name 去空白后非空、长度上限 200，由 API 实现校验）。
public struct CollectionRenameInput: Codable, Equatable, Sendable {
    public var collectionId: String
    public var name: String

    public init(collectionId: String, name: String) {
        self.collectionId = collectionId
        self.name = name
    }
}

/// 删除集合（破坏性入口，API 侧一律 Confirmed<T>；成员随 FK 级联删除）。
public struct CollectionDeleteInput: Codable, Equatable, Sendable {
    public var collectionId: String

    public init(collectionId: String) {
        self.collectionId = collectionId
    }
}

/// 显式重排：photoIds 即目标顺序（位置写 1..n，事务内一次完成）。
public struct CollectionReorderInput: Codable, Equatable, Sendable {
    public var collectionId: String
    public var photoIds: [String]

    public init(collectionId: String, photoIds: [String]) {
        self.collectionId = collectionId
        self.photoIds = photoIds
    }
}

/// 单行拖拽：把 photoId 移到 afterPhotoId 之后 / beforePhotoId 之前。
///
/// 二者都为 nil = 移到最前；只给 after = 移到该张之后；只给 before = 移到该张之前。
/// 契约：正常情况下**只写 1 行**（position 取前后中点）；间隙耗尽才在事务内重排。
public struct CollectionMoveInput: Codable, Equatable, Sendable {
    public var collectionId: String
    public var photoId: String
    public var afterPhotoId: String?
    public var beforePhotoId: String?

    public init(
        collectionId: String,
        photoId: String,
        afterPhotoId: String? = nil,
        beforePhotoId: String? = nil
    ) {
        self.collectionId = collectionId
        self.photoId = photoId
        self.afterPhotoId = afterPhotoId
        self.beforePhotoId = beforePhotoId
    }
}

// MARK: - 堆栈（§3.8.2）

/// 更新堆栈：name / coverPhotoId 二选一或同时；clearCover=true 时清空封面（SET NULL 语义）。
public struct StackUpdateInput: Codable, Equatable, Sendable {
    public var stackId: String
    public var name: String?
    public var coverPhotoId: String?
    public var clearCover: Bool

    public init(
        stackId: String,
        name: String? = nil,
        coverPhotoId: String? = nil,
        clearCover: Bool = false
    ) {
        self.stackId = stackId
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.clearCover = clearCover
    }
}

/// 解堆（破坏性入口，Confirmed<T>）。
public struct StackDeleteInput: Codable, Equatable, Sendable {
    public var stackId: String

    public init(stackId: String) {
        self.stackId = stackId
    }
}

/// 堆栈成员增删（photoIds 去重后处理；空数组是参数错误）。
public struct StackMembersInput: Codable, Equatable, Sendable {
    public var stackId: String
    public var photoIds: [String]

    public init(stackId: String, photoIds: [String]) {
        self.stackId = stackId
        self.photoIds = photoIds
    }
}

/// 折叠视图：一个堆栈 + 有序成员（网格只显示封面一张 + n 徽标）。
///
/// 折叠**只影响展示**：评分/决策/写回一律按成员照片各自处理。
public struct StackFold: Codable, Equatable, Sendable, Identifiable {
    public var stackId: String
    public var name: String
    public var coverPhotoId: String?
    /// 按 position 升序；第一个成员是封面兜底。
    public var photoIds: [String]

    public var id: String { stackId }

    public init(
        stackId: String,
        name: String = "",
        coverPhotoId: String? = nil,
        photoIds: [String] = []
    ) {
        self.stackId = stackId
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.photoIds = photoIds
    }

    /// 实际用于网格显示的封面：显式封面（仍属成员）→ 首个成员 → nil。
    public var displayCoverPhotoId: String? {
        if let coverPhotoId, photoIds.contains(coverPhotoId) { return coverPhotoId }
        return photoIds.first
    }

    /// 折叠后被隐藏的成员数（徽标显示 n = 成员总数，隐藏 = n-1）。
    public var hiddenMemberCount: Int {
        max(0, photoIds.count - 1)
    }
}
// MARK: - 跨工作区重复（§3.8.3，只读）

public enum GlobalDuplicateKind: String, Codable, Equatable, Sendable {
    /// 精确重复：photos.checksum 相同且跨 ≥2 个工作区。
    case exact
    /// 视觉近似：hash 桶内汉明距离 ≤ 阈值。
    case visual
}

/// 重复组成员（跨工作区展示用；只读，不提供删除）。
public struct GlobalDuplicateMember: Codable, Equatable, Sendable {
    public var photoId: String
    public var sessionId: String
    public var sessionName: String
    public var filepath: String
    public var filename: String
    /// 文件字节数；未知（未 stat）为 0。
    public var fileSize: Int64
    /// 该照片的 checksum 是否已计算（懒计算未补齐时为 false，UI 标注"未计算"）。
    public var checksumComputed: Bool

    public init(
        photoId: String,
        sessionId: String,
        sessionName: String = "",
        filepath: String = "",
        filename: String = "",
        fileSize: Int64 = 0,
        checksumComputed: Bool = false
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.filepath = filepath
        self.filename = filename
        self.fileSize = fileSize
        self.checksumComputed = checksumComputed
    }
}

/// 一个跨工作区重复组。id 稳定（kind:signature），可直接做 UI 列表标识。
public struct GlobalDuplicateGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: GlobalDuplicateKind
    /// exact: 完整 checksum；visual: 桶代表 hash（16 hex）。
    public var signature: String
    public var members: [GlobalDuplicateMember]
    /// 涉及的工作区数（成员 sessionId 去重计数）。
    public var sessionCount: Int

    public init(
        id: String,
        kind: GlobalDuplicateKind,
        signature: String,
        members: [GlobalDuplicateMember],
        sessionCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.signature = signature
        self.members = members
        self.sessionCount = sessionCount
    }
}

/// 跨工作区重复扫描输入。
///
/// - includeVisual=false 时只做精确 checksum 分组（视觉哈希缺失/未算出时的降级）。
/// - visualThreshold 取 0...14（视觉近似上限；0 = 仅同哈希）。
/// - maxGroupCount 上限 1...500（默认 200），超出置 truncated。
public struct GlobalDuplicateScanInput: Codable, Equatable, Sendable {
    public var includeVisual: Bool
    public var visualThreshold: Int
    public var maxGroupCount: Int

    public init(
        includeVisual: Bool = true,
        visualThreshold: Int = 14,
        maxGroupCount: Int = 200
    ) {
        self.includeVisual = includeVisual
        self.visualThreshold = visualThreshold
        self.maxGroupCount = maxGroupCount
    }
}

/// 跨工作区重复扫描结果（只读；结果同时缓存在 CurationService 内存）。
public struct GlobalDuplicateScanResult: Codable, Equatable, Sendable {
    public var groups: [GlobalDuplicateGroup]
    /// 参与扫描的照片总数（含未计算 checksum 的）。
    public var scannedPhotoCount: Int
    /// checksum 为空、需要先补算的照片数（UI 显示"未计算"）。
    public var missingChecksumCount: Int
    /// 分组数超过 maxGroupCount 被截断。
    public var truncated: Bool
    public var exactGroupCount: Int
    public var visualGroupCount: Int

    public init(
        groups: [GlobalDuplicateGroup] = [],
        scannedPhotoCount: Int = 0,
        missingChecksumCount: Int = 0,
        truncated: Bool = false,
        exactGroupCount: Int = 0,
        visualGroupCount: Int = 0
    ) {
        self.groups = groups
        self.scannedPhotoCount = scannedPhotoCount
        self.missingChecksumCount = missingChecksumCount
        self.truncated = truncated
        self.exactGroupCount = exactGroupCount
        self.visualGroupCount = visualGroupCount
    }
}
// MARK: - 挑片可视化（§3.9）

/// 已加载预览的像素缓冲（RGBA8，行主序）。
///
/// 为什么不直接在 UI 里算：GatherUI 不得 import GatherAnalysis（layering 门禁）。
/// 像素算法留在分析层，宿主实现 PreviewAnalysisPort 后经 GatherUI 的注册表暴露。
public struct PreviewPixels: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 长度必须 = width * height * 4（RGBA8）；不等时端口实现返回空结果，不崩。
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var isWellFormed: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4
    }
}

/// 预览直方图（64 bin 亮度 + RGB；语义是**预览**直方图，不是 RAW 线性数据）。
public struct PreviewHistogram: Codable, Equatable, Sendable {
    public var bins: Int
    /// 各 bin 像素占比（0...1），长度 = bins。
    public var luminance: [Double]
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]
    /// 采样像素里 max(R,G,B) == 0 的占比（阴影死黑）。
    public var shadowClip: Double
    /// 采样像素里 max(R,G,B) == 255 的占比（高光溢出）。
    public var highlightClip: Double
    /// 参与统计的采样像素数（降采样后）。
    public var sampleCount: Int

    public init(
        bins: Int = PreviewHistogram.defaultBins,
        luminance: [Double] = [],
        red: [Double] = [],
        green: [Double] = [],
        blue: [Double] = [],
        shadowClip: Double = 0,
        highlightClip: Double = 0,
        sampleCount: Int = 0
    ) {
        self.bins = bins
        self.luminance = luminance
        self.red = red
        self.green = green
        self.blue = blue
        self.shadowClip = shadowClip
        self.highlightClip = highlightClip
        self.sampleCount = sampleCount
    }

    public static let defaultBins = 64

    public var isEmpty: Bool { luminance.isEmpty || sampleCount == 0 }
}

/// 合焦图参数（阈值默认 0.55；当前未暴露设置项）。
public struct FocusMaskParameters: Codable, Equatable, Sendable {
    /// 0...1：局部方差归一化后高于该值的格子算"合焦"。
    public var threshold: Double
    /// 二值掩膜的最长边（320 = 叠加层分辨率）。
    public var maxDimension: Int

    public init(threshold: Double = 0.55, maxDimension: Int = 320) {
        self.threshold = threshold
        self.maxDimension = maxDimension
    }
}

/// 合焦图（3×3 局部方差归一化到 0...1，行主序）。
public struct FocusMap: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var values: [Double]
    /// 归一化用的 99 分位（>0），供 UI/诊断显示量级。
    public var normalization: Double

    public init(width: Int = 0, height: Int = 0, values: [Double] = [], normalization: Double = 0) {
        self.width = width
        self.height = height
        self.values = values
        self.normalization = normalization
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 || values.isEmpty }
}

/// 合焦掩膜（二值 0/1 + 阈值），由 FocusMap 降采样得到。
public struct FocusMask: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// 0 或 1；行主序，长度 = width * height。
    public var values: [UInt8]
    public var threshold: Double

    public init(width: Int = 0, height: Int = 0, values: [UInt8] = [], threshold: Double = 0.55) {
        self.width = width
        self.height = height
        self.values = values
        self.threshold = threshold
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 || values.isEmpty }

    /// 合焦像素占比（诊断/金样用）。
    public var focusedFraction: Double {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(values.count)
    }
}

/// AF 点来源（UI 据此决定是否标注"启发式"）。
public enum AFPointSource: String, Codable, Equatable, Sendable {
    /// ImageIO ExifAux / 已登记机型表的 AF 点。
    case camera
    /// MakerNote 有限扫描命中（本波不实现通用解析，恒不产生）。
    case makerNote
    /// 回退：主体人脸框中心。
    case face
}

/// AF 点（归一化 0...1，左上原点）。
public struct AFPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var source: AFPointSource
    /// UI 展示的机型/说明（不含绝对路径）。
    public var label: String

    public init(x: Double, y: Double, source: AFPointSource, label: String = "") {
        self.x = x
        self.y = y
        self.source = source
        self.label = label
    }

    /// 把该点搬到视口中心所需的归一化位移（点击 AF 框 → 以该点为中心 100%）。
    public func centeringOffset() -> (x: Double, y: Double) {
        (0.5 - x, 0.5 - y)
    }
}

/// 裁剪几何（Lightroom/C1 约定：crs:Crop* 是 0...1 单位矩形，crs:Angle 是角度）。
///
/// **只读**：Gather 不提供裁剪编辑，这里只解决"预览与 C1 看到的构图不一样"。
///
/// 命名说明：叫 CropFrame 而不是 "Crop" + "Geometry"——后者的可选写法
/// （…Geometry?）会被 cleanup ratchet 的 try 可选计数当成命中（子串 "try?"），
/// 无故抬高预算。
public struct CropFrame: Codable, Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var angle: Double

    public init(left: Double, top: Double, right: Double, bottom: Double, angle: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.angle = angle
    }

    /// 从 crs:* 原始值构造：越界值夹取到 0...1；退化矩形（全画幅且未旋转）→ nil。
    ///
    /// Lightroom 写的是"保留区域的边界"（crs:CropLeft/Top/Right/Bottom 为 0...1）；
    /// C1 开启"包含调整"时同义。缺失任一字段 → nil（无裁剪标记）。
    public static func fromLightroom(
        angle: Double?,
        left: Double?,
        top: Double?,
        right: Double?,
        bottom: Double?
    ) -> CropFrame? {
        guard let left, let top, let right, let bottom else { return nil }
        let l = clampUnit(left)
        let t = clampUnit(top)
        let r = clampUnit(right)
        let b = clampUnit(bottom)
        // 退化矩形（零面积）不是裁剪，按"无裁剪"处理，避免画一条退化虚线。
        guard r - l > 0.001, b - t > 0.001 else { return nil }
        let geometry = CropFrame(
            left: l,
            top: t,
            right: r,
            bottom: b,
            angle: normalizedAngle(angle ?? 0)
        )
        return geometry.isFullFrame && !geometry.isRotated ? nil : geometry
    }

    /// 单位区间夹取（NaN/∞ → 0，其余夹到 0...1）。
    public static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// 角度归一到 (-180, 180]。
    public static func normalizedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    public var width: Double { max(0, right - left) }
    public var height: Double { max(0, bottom - top) }
    public var centerX: Double { (left + right) / 2 }
    public var centerY: Double { (top + bottom) / 2 }

    /// 近似全画幅（容差 0.5%）：UI 不画虚线框。
    public var isFullFrame: Bool {
        left <= 0.005 && top <= 0.005 && right >= 0.995 && bottom >= 0.995
    }

    /// 角度是否可感知（> 0.1°）。
    public var isRotated: Bool {
        abs(angle) > 0.1
    }

    /// "显示全图"（O 键临时去掉裁剪蒙版）时的几何：矩形回到全画幅，角度保留。
    public func showingFullFrame(_ showFullFrame: Bool) -> CropFrame {
        guard showFullFrame else { return self }
        return CropFrame(left: 0, top: 0, right: 1, bottom: 1, angle: angle)
    }
}

/// 预览分析端口（宿主实现；UI 只声明契约）。
///
/// 三个方法都是纯函数语义：相同输入必须得到相同输出，不触盘、不改状态。
/// 输入 PreviewPixels 由 UI 从**已加载预览**栅格化而来（不新增文件解码）。
public protocol PreviewAnalysisPort: Sendable {
    /// 64 bin 亮度 + RGB 占比 + 溢出比例；像素格式不合法时返回空直方图。
    func histogram(_ pixels: PreviewPixels, bins: Int) -> PreviewHistogram
    /// 3×3 局部方差 → 阈值二值掩膜（maxDimension 最长边）。
    func focusMask(_ pixels: PreviewPixels, parameters: FocusMaskParameters) -> FocusMask
    /// AF 点：ExifAux/机型表优先，无数据回退主体人脸框中心；都无 → nil。
    func afPoint(faceBoxes: [[Double]], cameraModel: String, afIndex: Int?) -> AFPoint?
}
// MARK: - 参考对比几何（§3.9.5，纯几何；UI 直接用，属协议层）

/// 参考对比的纯几何：分割线位置 ↔ 视图坐标映射、缩放同步、主/参考交换。
///
/// 为什么放在协议层而不是分析层：它不碰像素，只是查看器的坐标约定，GatherUI
/// 需要直接调用（UI 不得 import GatherAnalysis）。与 UI 的坐标模型一致
/// （fit 居中 + scaleEffect 绕中心 + offset）：分割线用归一化 0...1 表示
/// "参考图占左半的比例"，两侧共享同一缩放系数。
public enum ReferenceCompareGeometry {
    /// 分割线夹取（0.05...0.95：两端各留 5% 避免拖出命中区）。
    public static func clampedSplit(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0.5 }
        return min(0.95, max(0.05, fraction))
    }

    /// 视图拖动位置 → 归一化分割线（view 宽 0 → 0.5）。
    public static func splitFraction(dragX: Double, viewWidth: Double) -> Double {
        guard viewWidth > 0, dragX.isFinite else { return 0.5 }
        return clampedSplit(dragX / viewWidth)
    }

    /// 分割线在视图里的 x（pt）。
    public static func splitX(fraction: Double, viewWidth: Double) -> Double {
        guard viewWidth > 0 else { return 0 }
        return clampedSplit(fraction) * viewWidth
    }

    /// 交换主/参考（反斜杠键）：分割线镜像，保证视觉位置不跳。
    public static func mirroredSplit(_ fraction: Double) -> Double {
        1 - clampedSplit(fraction)
    }

    /// 缩放同步：两侧共用同一系数（夹到 1...8）；参考侧不单独缩放。
    public static func synchronizedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(8, max(1, zoom))
    }
}
