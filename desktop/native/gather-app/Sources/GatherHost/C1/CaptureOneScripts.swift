// desktop/native/gather-app/Sources/GatherHost/C1/CaptureOneScripts.swift
// M11（Wave5 / task-9）：从 CaptureOneBridge.swift 纯搬移的 AppleScript 脚本构造器。
// 脚本文本契约由 C1BridgeWave1/2/3/4Tests 直接断言（只改文件归属，不改脚本内容）。
//
// 纯移动：搬运块与 HEAD 逐字节一致；唯一改动是 isSafeApplicationName 由 private 改
// internal——实例执行路径（openInCaptureOne / preflight / captureOneApplicationName）
// 仍在 CaptureOneBridge.swift，跨文件同 target 可见。
import Foundation
import GatherProtocol
import GatherUI

extension CaptureOneBridge {
    /// TS buildDocumentProbeScript：发 Apple Event 同时探测自动化权限与文档。
    /// 共享实现：CaptureOneBridge 预检与设置页 C1 健康检查共用同一脚本文本。
    public static func documentProbeScript(appName: String) -> String {
        """
        tell application "\(appName)"
          get name of current document
        end tell
        """
    }

    static func isSafeApplicationName(_ name: String) -> Bool {
        name.range(of: #"^Capture One( [A-Za-z0-9 ._+()$-]*)?$"#, options: .regularExpression) != nil
    }

    /// 读取 C1 当前选中的 variant 路径（G1）。
    ///
    /// C1 16.7 sdef 依据（本机 CaptureOne.sdef，16.7.8.16）：
    /// - selected variants 是 **application** 属性（code csev，`:244-247`，
    ///   "List of selected variants in the front document's browser"）；
    ///   标了 deprecated，但 16.7 里它是唯一能一次读出多个选中项的对象面
    ///   （application 级的 `primary variant` 只有单选，`:253`）；
    /// - variant **没有 path**：路径在 `parent image`（`:1081`）的 `path`
    ///   （image.path，`:1541`，"The full path to the original image file"）。
    ///
    /// 旧脚本写成 `selected variants of current document`（对象归属错）并取
    /// `path of img`（variant 无该属性），在 16.7 上必然报错；旧实现再用
    /// `on error return ""` 把错误吞成"没有选中照片"，用户只会看到"请先选照片"。
    /// 现在**不吞错**：脚本失败由 osascript 非零退出上浮为 C1_SCRIPT_FAILED。
    static func selectedVariantsScript(appName: String) -> String {
        """
        tell application "\(appName)"
          -- 无文档时先在这里抛错（宿主归一到 C1_NO_DOCUMENT），不被当成"没有选中"。
          set frontDocument to current document
          set selectedVariantsList to {}
          try
            set selectedVariantsList to selected variants
          on error
            -- P2（Wave4b）受控回退：该属性在部分 C1 版本 deprecated/hidden；不可读时退回
            -- primary variant（单张），避免整个读取失效。空选中仍按空处理（不误导入）。
            try
              set primaryVariant to primary variant
              if primaryVariant is not missing value then set selectedVariantsList to {primaryVariant}
            end try
          end try
          set output to ""
          repeat with v in selectedVariantsList
            set parentImage to parent image of v
            set output to output & (path of parentImage) & linefeed
          end repeat
          return output
        end tell
        """
    }

    /// 按路径逐个匹配后 select（§3.10.2）。
    ///
    /// C1 16.7 sdef 依据：
    /// - variant 没有 path，只能经 `parent image` 反查 `image.path`（`:1081`/`:1541`）；
    /// - select 命令的直接参数是 **document**，variant 是具名参数（`variant` /
    ///   `variants`，`:1956-1966`）——旧脚本把 variant 当直接参数，16.7 会拒绝；
    /// - **R12（Wave5）**：select 的语义是"加入当前集选中"（`:1956` "Add one or more
    ///   variants to the current collection's selection"），旧实现只加不减 → UI 提示
    ///   "已在 C1 中显示 N 张"与 C1 实际选中（旧选中 + N）不符。sdef:1967 有配对的
    ///   deselect（直接参数同样是 document、variants 是具名参数），因此 select 前先
    ///   清掉当前选中，让"显示"= 真正替换选中。
    ///
    /// 输出：每条路径一行 "1"/"0"，与 paths 同序（调用方据此算 notFound）；
    /// `on error` 分支返回单行 `"error:<msg>"`，由 reportedScriptError(in:) 先筛出
    /// 并当脚本失败抛出（C7：不能被当"未找到"，也不能兜底 open -a）。
    ///
    /// - Parameter deselectFirst：true = 先清掉当前选中（默认；"在 C1 中显示"是替换语义）。
    ///   false = 只追加选中，供 R3 的 browse 重试用（重试只带 notFound 的照片，
    ///   清选中会把第一批已选中的照片从 C1 选中里抹掉）。
    static func selectVariantsScript(
        appName: String,
        paths: [String],
        deselectFirst: Bool = true
    ) -> String {
        let literals = paths.map(appleScriptLiteral).joined(separator: ", ")
        let deselectBlock = deselectFirst ? """
            -- R12：select 只"加入"选中；先 deselect 当前选中，最终选中 = 本批命中项。
            -- 读不到/清不掉选中是受控降级（继续 select），不让它把整次"显示"变成脚本失败。
            set previousSelection to {}
            try
              set previousSelection to selected variants
            end try
            if (count of previousSelection) > 0 then
              try
                deselect targetDoc variants previousSelection
              end try
            end if
        """ : ""
        return """
        tell application "\(appName)"
          try
            set targetDoc to current document
        \(deselectBlock)
            set report to ""
            repeat with p in {\(literals)}
              -- variant 没有 path：按 parent image 的 path 在当前 collection 里找图片。
              set matches to (every image of targetDoc whose path is p)
              if (count of matches) > 0 then
                set variantsToSelect to {}
                repeat with img in matches
                  repeat with v in (variants of img)
                    set end of variantsToSelect to v
                  end repeat
                end repeat
                -- sdef：select 的直接参数是 document，variant/variants 是具名参数。
                select targetDoc variants variantsToSelect
                set report to report & "1" & linefeed
              else
                set report to report & "0" & linefeed
              end if
            end repeat
            return report
          on error theErr
            return "error:" & (theErr as text)
          end try
        end tell
        """
    }

    /// R3（Wave5）：让 C1 把浏览集合切到指定目录（sdef:678-684，
    /// `browse <document> to path <folder>`，cocoa key thePath）。
    ///
    /// 为什么需要：写回/选中/"在 C1 中显示"的作用域都是 C1 **当前集合**
    /// （sdef:325-334 document 的 image 元素、:736），Gather 从不切换集合 → 跨集合
    /// 一律 0 命中（notFound）且旧实现没有补救。这里只做"切集合"这一件事：
    /// 切不切、切到哪个目录由调用方决定（**唯一父目录**才切，不猜）。
    ///
    /// 输出："1" = 已切；失败走 `on error` 返回 `error:<msg>`（调用方用
    /// reportedScriptError 判定并记日志——切集合失败不得被当成"没找到"吞掉）。
    static func browseScript(appName: String, path: String) -> String {
        """
        tell application "\(appName)"
          try
            set targetDoc to current document
            browse targetDoc to path \(appleScriptLiteral(path))
            return "1"
          on error theErr
            return "error:" & (theErr as text)
          end try
        end tell
        """
    }

    /// R1（Wave5）只读脚本：一次读回每个 image 在**当前集合**里的 variant 数。
    ///
    /// 为什么必须先读：变体级写回的目标是启发式（已 pick 否则 variant 1），同一 image
    /// 有多个 variant 时会改错目标且不可逆（96 号 §10 把"写错 variant"判 P0）。
    /// 数量是唯一能安全判定的信号：
    /// - 0 → 不在当前集合（notFound，可按父目录 browse 补救一次）；
    /// - 1 → 唯一目标，维持原写回；
    /// - >1 → 不猜目标，整条跳过（skippedMultiVariant），由用户回 C1 选变体后重试。
    ///
    /// C1 16.7 sdef 依据：document 的 image 元素 = 当前集合（`:325-334`、`:736`）；
    /// variant 是 image 的子元素（`variants of theImage`），自身没有 path（`:1081`/`:1541`）。
    /// 输出：每条请求路径一行十进制计数，与 paths 同序（解析见 parseVariantCounts）。
    static func variantCountReadScript(appName: String, paths: [String]) -> String {
        let literals = paths.map(appleScriptLiteral).joined(separator: ", ")
        return """
        tell application "\(appName)"
          set targetDoc to current document
          set report to ""
          repeat with p in {\(literals)}
            set matches to (every image of targetDoc whose path is p)
            if (count of matches) > 0 then
              set theImage to (item 1 of matches)
              set report to report & ((count of (variants of theImage)) as text) & linefeed
            else
              set report to report & "0" & linefeed
            end if
          end repeat
          return report
        end tell
        """
    }

    /// 双引号 / 反斜杠用码点构造：避免在本文件里堆叠难读的连续转义。
    private static let appleScriptQuote = String(decoding: [0x22] as [UInt8], as: UTF8.self)
    private static let appleScriptBackslash = String(decoding: [0x5C] as [UInt8], as: UTF8.self)

    /// AppleScript 字符串字面量转义：反斜杠与双引号，然后整体加引号。
    /// 换行/回车会让脚本变成多行字面量（AppleScript 不允许），直接退化为空串。
    static func appleScriptLiteral(_ value: String) -> String {
        guard !value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D }) else {
            return appleScriptQuote + appleScriptQuote
        }
        let escaped = value
            .replacingOccurrences(
                of: appleScriptBackslash,
                with: appleScriptBackslash + appleScriptBackslash)
            .replacingOccurrences(
                of: appleScriptQuote,
                with: appleScriptBackslash + appleScriptQuote)
        return appleScriptQuote + escaped + appleScriptQuote
    }

    /// G2 的 reload 脚本：按当前选中的 variant 逐个 reload。
    ///
    /// C1 16.7 sdef 依据：reload metadata（`:1852-1855`）"Reload a variant's source
    /// file metadata"，直接参数是 **variant**，命令只声明在 variant 类上响应
    /// （`:1176`）—— document 级调用在 16.7 上不成立（旧脚本正是如此）。
    /// 没有选中项时不向任何对象盲发：直接返回 "0"，宿主映射成 C1_NO_SELECTED_PHOTOS。
    ///
    /// 输出：已重载的 variant 数量（十进制字符串）。
    static func reloadMetadataScript(appName: String) -> String {
        """
        tell application "\(appName)"
          set frontDocument to current document
          set selectedVariantsList to {}
          try
            set selectedVariantsList to selected variants
          on error
            -- P2（Wave4b）受控回退 primary variant（不整体失败）。
            try
              set primaryVariant to primary variant
              if primaryVariant is not missing value then set selectedVariantsList to {primaryVariant}
            end try
          end try
          set selectedCount to count of selectedVariantsList
          if selectedCount = 0 then return "0"
          repeat with v in selectedVariantsList
            reload metadata v
          end repeat
          return (selectedCount as text)
        end tell
        """
    }

    // MARK: - G3：导出选中 variant 的判断数据（只读）

    /// G3 只读脚本：导出当前选中 variant 的判断数据。
    ///
    /// C1 16.7 sdef 依据（本机 CaptureOne.sdef，16.7.8.16）：
    /// - selected variants 是 application 属性（`:244-247`；前端文档浏览器的选中项）；
    /// - 路径：variant 没有 path，路径在 parent image（`:1081`）的 path（`:1541`）；
    /// - 判断：rating（`:1097`）、color tag（`:1096`）、pick（`:1084`）是 variant 属性；
    /// - 关键词：variant 的 keyword 元素（`:1073`）→ keyword.name（`:966`）；
    /// - 无文档时先取 current document 抛错（宿主归一到 C1_NO_DOCUMENT）。
    ///
    /// 输出契约：P 行 = TAB 分隔的 4 个带前缀字段（P=路径、R=rating、T=color tag、
    /// K=pick 0/1）；W 行 = 一个关键词（挂到最近一条 P 记录）。值内的反斜杠 /
    /// 换行 / 回车 / TAB 由 escapeField 转义（路径与关键词可含任意字符），解析见
    /// parseVariantJudgements。转义只影响可读性，不改变 AppleScript 侧的数据语义。
    static func selectedVariantJudgementsScript(appName: String) -> String {
        #"""
        on escapeField(theText)
          set savedDelimiters to AppleScript's text item delimiters
          set AppleScript's text item delimiters to "\\"
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\\\"
          set theText to parts as text
          set AppleScript's text item delimiters to linefeed
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\n"
          set theText to parts as text
          set AppleScript's text item delimiters to return
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\r"
          set theText to parts as text
          set AppleScript's text item delimiters to tab
          set parts to text items of theText
          set AppleScript's text item delimiters to "\\t"
          set theText to parts as text
          set AppleScript's text item delimiters to savedDelimiters
          return theText
        end escapeField

        tell application "\#(appName)"
          set frontDocument to current document
          set selectedVariantsList to {}
          try
            set selectedVariantsList to selected variants
          on error
            -- P2（Wave4b）受控回退 primary variant（不整体失败）。
            try
              set primaryVariant to primary variant
              if primaryVariant is not missing value then set selectedVariantsList to {primaryVariant}
            end try
          end try
          set output to ""
          repeat with v in selectedVariantsList
            set parentImage to parent image of v
            set pickFlag to "0"
            if pick of v then set pickFlag to "1"
            set output to output & "P" & my escapeField(path of parentImage) & tab & "R" & (rating of v as text) & tab & "T" & (color tag of v as text) & tab & "K" & pickFlag & linefeed
            repeat with k in (keywords of v)
              set output to output & "W" & my escapeField(name of k) & linefeed
            end repeat
          end repeat
          return output
        end tell
        """#
    }

    /// 写回脚本（internal：脚本契约由 C1BridgeWave3Tests 文本断言）。
    ///
    /// 输入只包含**写前回读确认过**的单 variant image（Wave5 / R1：多 variant 已在
    /// partitionVariantTargets 里整条跳过），因此下面的"已 pick 否则 variant 1"启发式
    /// 只会落在唯一那个 variant 上，不再有"改错 variant"的风险。
    ///
    /// 输出：每条请求路径一行 "1"/"0"，与 items 同序（解析见 parseVariantWritebackReport）。
    static func variantWritebackScript(
        appName: String,
        items: [C1VariantWritebackItem]
    ) -> String {
        var blocks: [String] = []
        for item in items {
            let rating = max(0, min(5, item.rating))
            let tag = C1ColorTagMapping.label(for: item.colorTag) == nil ? 0 : item.colorTag
            var lines = [
                "    set matches to (every image of targetDoc whose path is \(appleScriptLiteral(item.photoPath)))",
                "    if (count of matches) > 0 then",
                "      set theImage to (item 1 of matches)",
                "      set targetVariant to missing value",
                "      repeat with v in (variants of theImage)",
                "        if pick of v then set targetVariant to v",
                "      end repeat",
                "      if targetVariant is missing value then set targetVariant to variant 1 of theImage",
                "      if targetVariant is not missing value then",
                "        set rating of targetVariant to \(rating)",
                "        set color tag of targetVariant to \(tag)",
            ]
            // A3：C1 无 reject 位 → 只写 keep（true）。false 视为"不写"：
            // 保留 C1 现值比写入一个不可逆的 false 更安全（淘汰不写回 C1）。
            if item.pick == true {
                lines.append("        set pick of targetVariant to true")
            }
            lines.append(contentsOf: [
                "        set report to report & \"1\" & linefeed",
                "      else",
                "        set report to report & \"0\" & linefeed",
                "      end if",
                "    else",
                "      set report to report & \"0\" & linefeed",
                "    end if",
            ])
            blocks.append(lines.joined(separator: "\n"))
        }
        return """
        tell application "\(appName)"
          set targetDoc to current document
          set report to ""
        \(blocks.joined(separator: "\n"))
          return report
        end tell
        """
    }

    /// 红标脚本（internal：脚本契约由 C1BridgeWave3Tests 文本断言）。
    ///
    /// 只发 **color tag = Red**（C1ColorTagMapping.rawValue(for: .red) = 1）；
    /// 不碰 pick / rating / 关键词，也不调 reload metadata。每条路径一行报告：
    /// "1" = 已标红、"0" = 当前集合里没有、"2" = 变体数 ≠ 1（防御：不写、让用户定变体）。
    static func rejectedColorTagScript(appName: String, paths: [String]) -> String {
        let red = C1ColorTagMapping.rawValue(for: .red)
        var blocks: [String] = []
        for path in paths {
            blocks.append([
                "    set matches to (every image of targetDoc whose path is \(appleScriptLiteral(path)))",
                "    if (count of matches) > 0 then",
                "      set theImage to (item 1 of matches)",
                "      if (count of (variants of theImage)) is 1 then",
                "        set color tag of (variant 1 of theImage) to \(red)",
                "        set report to report & \"1\" & linefeed",
                "      else",
                "        set report to report & \"2\" & linefeed",
                "      end if",
                "    else",
                "      set report to report & \"0\" & linefeed",
                "    end if",
            ].joined(separator: "\n"))
        }
        return """
        tell application "\(appName)"
          set targetDoc to current document
          set report to ""
        \(blocks.joined(separator: "\n"))
          return report
        end tell
        """
    }
}
