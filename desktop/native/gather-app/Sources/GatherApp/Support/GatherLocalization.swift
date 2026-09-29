// UI 对齐（§十一）：错误码/任务状态/任务类型/进度相位 中文文案本地化层。
// 文案来源：main 分支 renderer/locales/zh-CN.json（error.*/jobs.*/progress.* 键），
// 对齐 utils/errors.ts 的 translateErrorCode 多键回退语义：
// 未知错误码 → error.unspecific；任务错误消息非错误码 → error.unspecific。
import Foundation
import GatherCore

/// 进程级界面语言的存储盒子。
/// Swift 6：`nonisolated` 全局可变状态非法（#MutableGlobalVariable），原先的
/// `static var appLanguage` 改为锁保护盒子 + 计算属性，读写语义与原子性不变。
/// `@unchecked Sendable` 的依据：唯一可变状态 `value` 只在 `lock` 临界区内读写。
private final class AppLanguageStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ initial: String) {
        value = initial
    }

    var current: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

public enum GatherLocalization {
    // MARK: - 错误码 → 中文文案（error.* 键，156 项）
    public static let errorMessages: [String: String] = [
    "C1_NOT_RUNNING": "无法连接 Capture One。请确认 Capture One 已运行并打开文档。",
    "C1_NO_DOCUMENT": "Capture One 未打开文档。请先在 Capture One 中打开目录（Document）。",
    "C1_NOT_AUTHORIZED": "缺少自动化权限。请在 系统设置 → 隐私与安全性 → 自动化 中允许 Gather 控制 Capture One，然后重试。",
    "C1_SCRIPT_FAILED": "与 Capture One 通信失败，请重试。",
    "C1_SCRIPT_TIMEOUT": "与 Capture One 通信超时，请重试。",
    "C1_NO_SELECTED_PHOTOS": "请先在 Capture One 中选择至少一张照片",
    "SCAN_INVALID_DIR": "所选路径不是有效目录",
    "SCAN_READ_FAILED": "读取目录失败",
    "XMP_CONFLICT_RESOLUTION_REQUIRED": "冲突项目必须选择保留当前 XMP 或恢复写入前状态",
    "XMP_CONFIRM_INCOMPLETE": "仍有未完成、失败或冲突的 XMP 项目，不能确认同步",
    "XMP_CLEANUP_REQUIRES_LOADED": "请先在 Capture One 中加载元数据并确认同步，再执行清理",
    "XMP_CONFIRM_REQUIRES_SYNC": "请先在 Capture One 中加载元数据并确认同步",
    "XMP_EXTERNALLY_MODIFIED": "XMP 已被其他软件修改，不能自动恢复或删除",
    "XMP_BACKUP_MISSING": "原始 XMP 备份不存在",
    "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT": "XMP 在 Capture One 加载后又被修改，已停止清理以保护外部更改",
    "XMP_EXTERNAL_EDIT_CONFLICT": "XMP 已被其他软件修改，且与 Gather 待写字段冲突",
    "XMP_RELOAD_NOT_ACKED": "请先在 Capture One 中加载元数据并确认同步，再继续",
    "XMP_CONFLICT_NOT_FOUND": "该冲突项不存在",
    "XMP_CONFLICT_DETAILS_UNAVAILABLE": "无法读取冲突详情，请刷新后重试",
    "XMP_CHOICE_MISSING": "请为每个冲突字段选择保留或恢复",
    "XMP_CONFLICT_DETAILS_INVALID": "冲突详情已损坏，无法处理",
    "XMP_CONFIRM_OTHER_SESSION_PENDING": "同一 XMP 侧车文件仍被其他工作区占用且尚未确认同步（{{session}}）。请先在该工作区完成「加载元数据并确认同步」，再回来结清。",
    "XMP_ORPHAN_NOT_FOUND": "未找到该恢复项",
    "XMP_ORPHAN_NOT_RETRYABLE": "只有待处理或失败的项目可以重试",
    "XMP_WRITER_TIMEOUT": "等待 XMP 写入超时，请重试",
    "XMP_DOCUMENT_CORRUPT": "照片旁的 XMP 侧车文件已损坏，无法解析。请先备份该 .xmp 文件，用支持 XMP 的软件修复或重建后再重试写回。",
    "XMP_DOCUMENT_UNSUPPORTED": "XMP 侧车文件的结构不受支持（不是可识别的 RDF/XMP 文档）。请确认该 .xmp 文件内容，或替换为标准 XMP 文档后重试。",
    "XMP_DOCUMENT_READ_FAILED": "无法读取 XMP 侧车文件。请检查文件是否存在、磁盘是否可访问，以及当前用户是否有读取权限，然后重试。",
    "XMP_WRITE_FAILED": "写入 XMP 侧车文件失败。请检查磁盘剩余空间、文件写入权限，以及该文件是否被其他软件占用，然后重试。",
    "XMP_WRITE_VERIFICATION_FAILED": "XMP 写入后校验未通过，内容可能未完整落盘。请检查磁盘空间与文件权限后重试；若反复失败，请先备份该 .xmp 文件再排查磁盘错误。",
    "XMP_BACKUP_FAILED": "创建 XMP 备份失败，已停止写入以保护原文件。请检查备份目录的磁盘空间与写入权限，然后重试。",
    "XMP_RESTORE_FAILED": "从备份恢复 XMP 失败，原文件未被改动。请确认备份文件存在且可写、磁盘空间充足，然后重试恢复。",
    "WRITEBACK_OTHER_MODULE_ACTIVE": "请先完成其他模块的 Capture One 同步和清理，再开始新的写回",
    "WRITEBACK_UNDO_FACE_FAILED": "撤销人脸关键词失败",
    "WRITEBACK_FAILURES_PENDING": "仍有 XMP 写入失败项，请先重试或处理失败项",
    "WRITEBACK_GROUP_NOT_IN_SESSION": "相似分组不属于当前工作区",
    "EXPORT_PARAMS_INVALID": "导出参数无效",
    "EXPORT_CONFIRMATION_REQUIRED": "开始导出前需要明确确认",
    "EXPORT_DIR_INVALID": "导出目录无效",
    "EXPORT_DIR_ABSOLUTE_REQUIRED": "导出目录必须使用绝对路径",
    "EXPORT_DIR_ROOT_FORBIDDEN": "不能直接导出到磁盘根目录",
    "EXPORT_DIR_INSIDE_SESSION": "不能导出到工作区导入目录或其子目录，导出的文件会被重新导入当前工作区",
    "EXPORT_FORMAT_INVALID": "导出格式无效",
    "EXPORT_FORMAT_UNSUPPORTED": "不支持该导出格式",
    "EXPORT_VARIANT_POLICY_INVALID": "导出变体策略无效",
    "EXPORT_ORIGINAL_NO_TRANSFORM": "保持原格式仅复制文件，不能同时调整尺寸或添加水印",
    "EXPORT_NAMING_EMPTY": "文件命名规则不能为空",
    "EXPORT_NAMING_INVALID_CHARS": "文件命名规则不能包含路径分隔符或空字符",
    "EXPORT_JPEG_QUALITY_INVALID": "JPEG 质量必须是 1 到 100 之间的整数",
    "EXPORT_MAX_DIMENSION_INVALID": "最长边必须是大于等于 1 的整数",
    "EXPORT_START_INDEX_INVALID": "起始序号必须是大于等于 0 的整数",
    "EXPORT_WATERMARK_TYPE_UNSUPPORTED": "当前版本仅支持文字水印",
    "EXPORT_WATERMARK_TEXT_EMPTY": "水印文字不能为空",
    "EXPORT_WATERMARK_OPACITY_INVALID": "水印不透明度必须在 0 到 1 之间",
    "EXPORT_WATERMARK_FONT_SIZE_INVALID": "水印字号必须在 1 到 1000 之间",
    "EXPORT_XMP_CONFLICT": "目标 XMP 已存在且内容不同",
    "EXPORT_PATH_INVALID": "照片的导出路径无效",
    "EXPORT_SCOPE_UNSUPPORTED": "暂不支持该导出范围，请导出当前工作区的全部照片。",
    "EXPORT_SCOPE_UNKNOWN": "未知导出范围",
    "EXPORT_RAW_CONVERT_UNSUPPORTED": "暂不支持将此文件类型转换为全分辨率文件，请选择“保持原格式”。",
    "EXPORT_UNKNOWN_ERROR": "未知错误",
    "NAV_BURST_GAP_INVALID": "连拍间隔必须在 0.1 到 300 秒之间",
    "NAV_SCENE_GAP_INVALID": "场景间隔必须不小于连拍间隔，且不超过 24 小时",
    "CULLING_EMPTY_SELECTION": "请至少选择一张照片",
    "CULLING_PHOTOS_NOT_IN_SESSION": "部分照片不属于当前工作区，请刷新后重试",
    "CULLING_HISTORY_NOT_FOUND": "挑片历史记录不存在",
    "CULLING_HISTORY_ALREADY_UNDONE": "该操作已撤销",
    "CULLING_HISTORY_NOT_UNDONE": "该操作尚未撤销",
    "CULLING_HISTORY_DIVERGED": "挑片状态已在历史记录之外发生变化，请刷新后重试",
    "CULLING_HISTORY_STALE": "挑片历史状态已变化，请刷新后重试",
    "CULLING_HISTORY_CORRUPT": "挑片历史记录已损坏，无法执行撤销或重做",
    "CULLING_UNDO_NOT_LATEST": "只能撤销最近一次尚未撤销的操作",
    "CULLING_REDO_OUT_OF_ORDER": "必须按原顺序重做操作",
    "CULLING_NO_SIMILARITY": "尚无相似度分析结果",
    "CULLING_GROUP_TOO_SMALL": "相似组不存在或成员不足",
    "CULLING_KEEP_NOT_IN_GROUP": "保留照片必须来自当前相似组，且至少淘汰一张",
    "ASSET_RELINK_XMP_BUSY": "XMP 正在写入，暂时不能重连照片；请稍后重新扫描",
    "ASSET_RELINK_OUTBOX_CONFLICT": "新旧路径都存在未完成的 XMP 操作，请先在恢复中心处理",
    "ASSET_RELINK_XMP_CONFLICT": "目标路径已有不同的 XMP 元数据状态，请先人工确认后再重连",
    "ASSET_RELINK_SAME_ROOT": "新资源根目录与当前根目录相同，无需重连",
    "ASSET_RELINK_NESTED_ROOT": "新旧资源根目录存在嵌套关系，不能互相重连",
    "ASSET_RELINK_NO_FILES_REGISTERED": "该资源根目录下没有已登记的资产文件，无法重连",
    "ASSET_RELINK_NO_VERIFIED_FILE": "没有通过身份校验的资产文件，无法重连",
    "FACE_EPS_INVALID": "人脸聚类相似度必须是 0 到 1 之间的数字",
    "FACE_MIN_CLUSTER_INVALID": "人脸聚类最小样本数必须是大于等于 1 的整数",
    "FACE_NO_PHOTOS": "当前工作区没有可分析的照片",
    "FACE_SELF_MERGE": "不能将人脸组与自身合并",
    "FACE_MODEL_DETECTOR_CORRUPT": "face_detector.onnx 缺失或已损坏，请重新下载",
    "FACE_MODEL_ENCODER_CORRUPT": "face_encoder.onnx 缺失或已损坏，请重新下载",
    "SIM_THRESHOLD_INVALID": "相似度阈值必须是 0 到 64 之间的整数",
    "SIM_MIN_GROUP_INVALID": "相似组最小照片数必须是大于等于 2 的整数",
    "SIM_WRITEBACK_EMPTY": "请至少选择一个相似分组并填写关键词",
    "SIM_WRITEBACK_INVALID_ITEM": "每个分组必须包含有效的分组 ID 和至少一个关键词",
    "SIM_ANALYSIS_MISSING": "尚无相似度分析结果，请先完成分析",
    "SIM_THRESHOLD_NO_RESULTS": "该阈值无结果，请重新聚类",
    "SIM_PREVIEW_REQUIRED": "没有可写入的预览项，请先生成预览",
    "SIM_PREVIEW_STALE": "写回预览已失效，请重新预览后再执行",
    "NAV_GROUP_NOT_FOUND": "导航分组不存在",
    "NAV_SPLIT_OUT_OF_GROUP": "拆分点必须位于分组内",
    "NAV_MERGE_MIN_TWO": "至少需要两个分组才能合并",
    "NAV_MERGE_TYPE_MISMATCH": "只有同类型的分组才能合并",
    "SESSION_SOURCE_NOT_DIR": "所选路径不是目录",
    "SESSION_SOURCE_ROOT_FORBIDDEN": "文件系统根目录不能作为照片来源",
    "SESSION_NOT_FOUND": "工作区不存在",
    "SESSION_IDS_REQUIRED": "未提供工作区 ID",
    "CULLING_PHOTO_NOT_IN_SESSION": "照片不属于当前工作区",
    "CULLING_REVISION_CONFLICT": "挑片版本冲突：期望 {{expected}}，当前 {{current}}",
    "CULLING_PATCH_INVALID": "挑片更新内容不能为空",
    "CULLING_INVALID_SCOPE": "无效的挑片范围",
    "CULLING_FINALIZE_CONFIRM_REQUIRED": "结束 XMP 同步前需要明确确认",
    "CULLING_RESET_CONFIRM_REQUIRED": "重置挑片结果前需要明确确认",
    "CULLING_NO_DECISIONS": "没有可写回的挑片决策",
    "WRITEBACK_CONFIRM_REQUIRED": "执行写回前需要明确确认",
    "WRITEBACK_RETRY_CONFIRM_REQUIRED": "重试失败写回前需要明确确认",
    "WRITEBACK_CLEANUP_CONFIRM_REQUIRED": "清理前需要明确确认",
    "FKW_UNBIND_CONFIRM_REQUIRED": "解绑会撤销已写入的人脸关键词，需要明确确认",
    "FKW_CLEANUP_CONFIRM_REQUIRED": "清理人脸 XMP 前需要明确确认",
    "FKW_NO_OBSERVATIONS": "没有缓存的人脸特征，请先运行分析",
    "FKW_ANALYSIS_RUNNING": "人脸分析已在进行中",
    "FKW_CLUSTER_NOT_FOUND": "人脸聚类不存在",
    "FKW_CLUSTER_NOT_IN_SESSION": "人脸聚类不属于当前工作区",
    "FKW_CLUSTER_MEMBER_NOT_FOUND": "人脸聚类成员不存在",
    "FKW_ROLE_NAME_EMPTY": "角色名称不能为空",
    "FKW_KEYWORDS_INVALID": "关键词必须是字符串数组",
    "FKW_ITEMS_INVALID": "写入项无效",
    "SIM_ANALYSIS_RUNNING": "相似度分析已在进行中",
    "SIM_NO_PHOTOS": "当前工作区没有照片",
    "SIM_NO_HASH_DATA": "没有可用于聚类的哈希数据",
    "SIM_NO_HASH_RECLUSTER": "没有可用于重新聚类的哈希数据",
    "SIM_NO_RESULTS": "没有可用的相似度分析结果，请先运行分析",
    "SIM_ASSIGNMENT_INVALID": "相似分组关键词分配无效",
    "SIM_GROUPING_MODE_INVALID": "无效的分组方式",
    "DUP_RESOLVE_CONFIRM_REQUIRED": "处理重复组前需要明确确认",
    "DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED": "处理重复照片前需要明确确认",
    "DUP_THRESHOLD_INVALID": "视觉相似度阈值必须是 0 到 64 之间的整数",
    "METADATA_SET_CONFIRM_REQUIRED": "写入元数据前需要明确确认",
    "METADATA_BATCH_SET_CONFIRM_REQUIRED": "批量写入元数据前需要明确确认",
    "METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED": "裁决元数据冲突前需要明确确认",
    "METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED": "处理孤儿元数据前需要明确确认",
    "JOBS_CLEAR_CONFIRM_REQUIRED": "清理已完成任务前需要明确确认",
    "SETTINGS_LANGUAGE_INVALID": "无效的界面语言，必须是“zh-CN”或“en”",
    "QUALITY_NO_ASSET_FILE": "照片没有已索引的资源文件",
    "INDEX_SESSION_NO_SOURCE": "工作区没有来源目录",
    "ASSET_LINK_CANDIDATE_NOT_FOUND": "关联候选不存在",
    "ASSET_FILE_NOT_LINKED": "资源文件未关联到逻辑照片",
    "ASSET_MIGRATION_INCOMPLETE": "照片资产迁移不完整，请先重新索引",
    "SESSION_DELETE_NOT_CONFIRMED": "删除操作未经确认",
    "MODEL_EXTRACT_FAILED": "模型解压失败，请确保系统已安装 unzip 或 tar",
    "FACE_WORKERS_INIT_FAILED": "人脸推理引擎初始化失败",
    "DUPLICATE_SCAN_BUSY": "重复扫描正在进行，请稍后再试",
    "METADATA_KEYWORDS_INVALID": "关键词格式无效",
    "METADATA_PATCH_INVALID": "元数据修改格式无效",
    "METADATA_RATING_INVALID": "评分必须是 0 到 5 的整数",
    "METADATA_LABEL_INVALID": "标签必须是有效的 Capture One 颜色标签",
    "METADATA_KEYWORDS_OP_INVALID": "关键词操作无效（仅支持追加/替换/移除）",
    "METADATA_PATCH_EMPTY": "元数据修改内容为空",
    "METADATA_MUTATION_EMPTY": "没有可更新的元数据字段",
    "FILTER_CRITERIA_INVALID": "筛选条件无效",
    "FILTER_FIELD_UNKNOWN": "未知的筛选字段：{{field}}",
    "FILTER_SCHEMA_UNSUPPORTED": "不支持的筛选条件版本：{{version}}",
    "TEMPLATE_NOT_FOUND": "模板不存在",
    "TEMPLATE_CONFIG_INVALID": "模板配置格式无效",
    "TEMPLATE_DELETE_CONFIRM_REQUIRED": "删除模板前需要明确确认",
    "TEMPLATE_APPLY_CONFIRM_REQUIRED": "应用模板前需要明确确认",
    "ALBUM_DELETE_CONFIRM_REQUIRED": "删除相册前需要明确确认",
    "ALBUM_NOT_FOUND": "智能相册不存在",
    "PERSON_NOT_FOUND": "人物不存在",
    "PERSON_DELETE_CONFIRM_REQUIRED": "删除人物前需要明确确认",
    "PERSON_MERGE_CONFIRM_REQUIRED": "合并人物前需要明确确认",
    "PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED": "移除人物照片前需要明确确认",
    "ASSET_LINK_ACCEPT_CONFIRM_REQUIRED": "接受资源关联前需要明确确认",
    "ASSET_LINK_REJECT_CONFIRM_REQUIRED": "拒绝资源关联前需要明确确认",
    "ASSET_RELINK_CONFIRM_REQUIRED": "重连资源根目录前需要明确确认",
    ]

    /// 对齐 TS translateErrorCode：未知/非错误码回退通用文案。
    /// 支持参数化错误码（路由返回 "CODE::p1::p2" 形式）：按模板中
    /// {{field}}/{{expected}}/{{current}} 占位符出现顺序依次插值。
    public static func errorText(_ code: String) -> String {
        guard let template = resolvedTemplate(for: code) else { return l("发生未知错误，请稍后重试") }
        return template
    }

    /// 错误码 → 模板（先本地化、再参数插值）；非错误码返回 nil（调用方回退）。
    /// 支持两种参数形态：路由的 `CODE::p1::p2`，以及 Core 侧 description 的
    /// `CODE: 参数`（如 XMP_CONFIRM_OTHER_SESSION_PENDING: <会话>）。
    /// 插值必须在本地化之后：否则中文模板 + 参数拼出的字符串查不到 en 表。
    private static func resolvedTemplate(for code: String) -> String? {
        let parts = code.components(separatedBy: "::")
        if let template = errorMessages[parts[0]] {
            return interpolate(template, params: Array(parts.dropFirst()))
        }
        guard let colon = code.firstIndex(of: ":") else { return nil }
        let head = String(code[code.startIndex..<colon])
        let tail = String(code[code.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty, let template = errorMessages[head] else { return nil }
        return interpolate(template, params: [tail])
    }

    /// 「已知码 + 单冒号参数」形态判定：首冒号前段是错误表收录的码，且其后参数
    /// 非空。与 resolvedTemplate 第二分支严格同构（同一冒号切分、同样 trim 后要求
    /// 非空），故命中即一定可插值。用于补 Library 的码形门槛：该门槛只认大写 ASCII
    /// 形态，会把 "XMP_CONFIRM_OTHER_SESSION_PENDING: s1" 误判为散文并丢掉插值。
    public static func isParameterizedErrorCode(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        let head = String(raw[raw.startIndex..<colon])
        guard errorMessages[head] != nil else { return false }
        let tail = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return !tail.isEmpty
    }

    private static func interpolate(_ template: String, params: [String]) -> String {
        var result = l(template)
        var paramIndex = 0
        while let range = result.range(of: #"\{\{[a-zA-Z]+\}\}"#, options: .regularExpression) {
            let replacement = paramIndex < params.count ? params[paramIndex] : ""
            result.replaceSubrange(range, with: replacement)
            paramIndex += 1
        }
        return result
    }

    /// 查 Apple 原生本地化表（.lproj/Localizable.strings，经 SPM 打进 Bundle.module）。
    /// key 即中文文案：zh 表留空 → 未命中自动回退 key（默认中文）；
    /// en 表提供英文翻译（en 界面命中返回英文，未翻译的 key 仍回退中文）。
    public static func l(_ key: String) -> String {
        let lang = appLanguage == "zh-CN" ? "zh-hans" : "en"
        guard let url = Bundle.module.url(forResource: lang, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return key }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return value == key ? key : value
    }

    /// 对齐 TS translateJobErrorMessage：任务错误消息仅错误码才展示对应文案，
    /// 其余（原始诊断/英文不变量）一律回退通用文案，原始细节保留给 tooltip。
    public static func jobErrorMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return l("发生未知错误，请稍后重试") }
        if let translated = resolvedTemplate(for: message) { return translated }
        return l("发生未知错误，请稍后重试")
    }

    /// 翻译任意 Error/字符串：消息是错误码则翻译（含参数化错误码插值），
    /// 否则原样返回。
    public static func message(for error: Any) -> String {
        let raw: String
        switch error {
        case let e as RouterCommandError: raw = e.message
        case let e as NativeCommandError: raw = e.description
        case let e as BridgeError: raw = e.description
        case let e as Error: raw = (e as NSError).localizedDescription
        case let s as String: raw = s
        default: raw = String(describing: error)
        }
        return resolvedTemplate(for: raw) ?? raw
    }

    /// 破坏性动作被用户取消时的统一可见文案（「已取消“%@”，未执行任何更改」）：
    /// Duplicates/Settings/FaceKeywording/Similarity 四处逐字同款，收敛为单一出口；
    /// 各自的状态面（notice/writebackMessage、附带清理的字段）仍在调用点。
    /// Culling 的取消文案是另一句（「已取消：%@」），语义不同，不并入此处。
    public static func cancellationNotice(_ action: String) -> String {
        String(format: l("已取消“%@”，未执行任何更改"), action)
    }

    // MARK: - 任务状态/类型/进度相位（jobs.* / progress.*）
    // 旧 switch 表恒中文；现统一收敛为「码 → 中文 key」表，显示语言由 l()
    // 决定（zh 命中 key 本身，en 查 .lproj；en 表缺项回退中文，不再有无条件中文）。

    private static let jobStatusKeys: [String: String] = [
        "queued": "排队中",
        "running": "运行中",
        "cancelling": "取消中",
        "succeeded": "已完成",
        "failed": "失败",
        "cancelled": "已取消",
        "interrupted": "已中断",
    ]

    public static func jobStatusText(_ status: String) -> String {
        guard let key = jobStatusKeys[status] else { return status }
        return l(key)
    }

    private static let jobTypeKeys: [String: String] = [
        "metadata.scan": "照片索引与元数据",
        "checksum.backfill": "文件校验和补全",
        "similarity.analyze": "相似照片分析",
        "face.analyze": "人脸分析",
        "duplicate.scan": "重复照片扫描",
        "quality.score": "技术质量分析",
        "export.execute": "照片导出",
        "thumbnail.build": "缩略图生成",
    ]

    public static func jobTypeText(_ type: String) -> String {
        guard let key = jobTypeKeys[type] else { return type }
        return l(key)
    }

    // 相位码 → 中文 key（TS 原文省略号为 "..."，全站统一为 "…"）。
    private static let progressPhaseKeys: [String: String] = [
        "export.processing": "正在导出照片…",
        "index.scanning": "正在增量扫描文件",
        "index.checksum": "正在后台补齐文件校验和",
        "index.done": "索引完成",
        "index.metadata-read": "正在读取拍摄元数据",
        "index.metadata-done": "索引与元数据完成",
        "similarity.hash": "正在计算感知哈希…",
        "similarity.hash-done": "哈希计算完成",
        "similarity.cluster": "正在聚类相似照片…",
        "similarity.cluster-done": "聚类完成",
        "similarity.thresholds": "正在预计算邻居阈值…",
        "similarity.analyzing": "正在计算哈希并聚类…",
        "face.init": "正在初始化人脸检测器…",
        "face.detect": "正在检测人脸…",
        "face.detecting": "正在检测人脸…",
        "face.cached-clusters": "正在复用缓存的人脸聚类…",
        "face.cached-faces": "正在复用缓存的人脸…",
        "face.cluster": "正在聚类人脸…",
        "face.done": "分析完成",
        "duplicate.read": "正在读取文件信息",
        "duplicate.hash": "正在计算内容校验和",
        "duplicate.done": "重复扫描完成",
        "quality.scoring": "正在分析技术质量",
        "thumbnail.building": "正在生成缩略图",
        "models.installed": "人脸模型已安装",
    ]

    public static func progressPhaseText(_ phase: String?) -> String {
        guard let phase, let key = progressPhaseKeys[phase] else { return l("正在处理…") }
        return l(key)
    }

    // MARK: - 界面语言（settings.ui_language 共享访问；对齐 SettingsViewModel
    // 的 ui_language 读取与 SessionCommandRouter.effectiveAppLocale 回退语义：
    // ui_language 覆盖 > 系统语言 zh 前缀 > en）
    /// 当前界面语言（"zh-CN"/"en"）。设置页 settings.set_language 后经
    /// languageChanged 通知刷新（DashboardView 订阅）；启动时未收到通知 →
    /// 回退系统语言检测（对齐 effectiveAppLocale 未设置 ui_language 分支）。
    private static let appLanguageStorage = AppLanguageStorage(Self.detectSystemLanguage())

    public static var appLanguage: String {
        get { appLanguageStorage.current }
        set { appLanguageStorage.current = newValue }
    }

    /// 显式设置界面语言（对齐 effectiveAppLocale：仅接受 zh-CN/en，
    /// 其余回退系统检测）。
    public static func setAppLanguage(_ language: String) {
        appLanguage = language == "zh-CN" || language == "en"
            ? language
            : Self.detectSystemLanguage()
    }

    /// 格式化 locale：跟随 appLanguage（zh-CN → zh_CN，其余 en_US）。
    /// 旧版 Dashboard formatDate 用 toLocaleDateString(undefined, ...)
    /// 跟随应用语言；新实现不硬编码 zh_CN。
    public static var appLocale: Locale {
        Locale(identifier: appLanguage == "zh-CN" ? "zh_CN" : "en_US")
    }

    private static func detectSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh") ? "zh-CN" : "en"
    }
}
