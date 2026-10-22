// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Execute.swift
// Cut 4 / 4c-2f：确认载荷、执行、取消与参数校验（原 ExportView.swift 352-463、
// 510-569）。确认/执行/取消的通道、错误映射与文案逐字未动。
import GatherProtocol

extension ExportViewModel {
    /// 组装「开始导出」确认载荷：先跑与 executeExport 同一套参数校验，
    /// 失败就地写行内错误并返回 nil（不弹确认、不发命令）。
    ///
    /// F04：确认弹窗里的文件数必须来自**当前范围**的真实导出计划。
    /// 旧实现直接取上次手动「预览」的缓存（没预览过就是 0），用户可能据此
    /// 确认一个与范围不符的导出。现在先重算计划，算不出来就不弹确认。
    public func exportConfirmation() async -> ExportConfirmation? {
        // D03：先把**完整请求参数**冻结成一份快照，之后预览、展示、执行全部只用它。
        // 旧实现在 await 前后各读一次可变状态：等待预览期间用户改了目录/范围，弹窗
        // 就会把新目录和旧文件数拼在一起，执行时又读第三份参数。
        let options: ExportOptions
        do {
            options = try exportOptions()
        } catch {
            fieldError = Self.fieldError(for: error)
            errorMessage = CommandError(error)
            return nil
        }
        let signature = planSignature
        let destinationSnapshot = destination
        let scopeSnapshot = scope
        guard !isConfirming else { return nil }
        isConfirming = true
        defer { isConfirming = false }
        do {
            let fetched = try await exportAPI.preview(
                ExportInput(sessionId: sessionId, options: options)
            )
            // 计划返回后参数又被改过：这份计划已经不是用户点确认时看到的那份，
            // 丢弃确认并让自动刷新去算新计划（下一次点击会用新快照）。
            guard signature == planSignature else {
                errorMessage = nil
                notice = LocalizedText("导出参数已变化，请确认新的导出计划")
                return nil
            }
            preview = fetched
            plannedSignature = signature
        } catch {
            errorMessage = CommandError(error)
            fieldError = Self.fieldError(for: error)
            return nil
        }
        return ExportConfirmation(
            destination: destinationSnapshot,
            // D09：确认文案用物理文件数（照片 + 边车）。
            fileCount: preview?.physicalFileCount ?? 0,
            scopeLabel: ExportConfirmation.scopeLabel(for: scopeSnapshot),
            planSignature: signature,
            request: options
        )
    }

    /// 确认弹窗取消：写可见文案（不静默 return），不发命令。
    public func reportExportCancelled() {
        notice = LocalizedText("已取消导出")
        fieldError = nil
    }

    /// 执行导出。confirmed 只能由视图确认分支传 true；API 只接收
    /// Confirmed<ExportInput>，未确认时本地即以 EXPORT_CONFIRMATION_REQUIRED 拒绝
    /// （不伪造确认、不发送请求）——UI 不得自证确认。
    /// - Parameter request: 确认弹窗冻结的参数（D03）。传入时执行的就是被确认的
    ///   那一份，不再重新读界面状态；为 nil（无确认路径）则现读当前参数。
    public func executeExport(confirmed: Bool, request: ExportOptions? = nil) async {
        exportProgress = nil
        currentFileName = nil
        guard confirmed else {
            errorMessage = CommandError(GatherError(code: .EXPORT_CONFIRMATION_REQUIRED))
            fieldError = nil
            return
        }
        await run {
            self.isExporting = true
            defer { self.isExporting = false }
            let options = try request ?? self.exportOptions()
            let input = try ExportInput(sessionId: self.sessionId, options: options)
            // 确认来源固定为用户弹窗：只有视图的确认分支能到达这里。
            let result = try await self.exportAPI.execute(
                Confirmed(input, source: .userDialog)
            )
            self.result = result
            // D02：部分失败不得只报「已完成」——成功/失败数量都要说清楚，否则用户会
            // 以为本次交付完整（全失败由 EXPORT_ALL_FAILED 走错误横幅）。
            self.notice = result.failed > 0
                ? LocalizedText(
                    "导出完成：成功 %lld 张，失败 %lld 张，请在结果中查看失败原因。",
                    params: ["\(result.exported)", "\(result.failed)"]
                )
                : LocalizedText(result.totalFiles == 0
                    // 零项（范围为空）：说「已完成」会让用户以为交付过了——明确说明没导出任何东西。
                    ? "当前范围没有可导出的照片，未写入任何文件。"
                    : "导出任务已完成")
        }
        exportProgress = nil
        currentFileName = nil
    }

    public func cancelExport() async {
        do {
            // ExportAPI.cancel 恒返回 true（无可取消任务时同样如此），无法区分
            // no-op，因此保持提示展示。
            _ = try await exportAPI.cancel(sessionId)
            notice = LocalizedText("已请求取消导出")
            fieldError = nil
        } catch {
            errorMessage = CommandError(error)
            fieldError = nil
        }
    }

    /// 界面状态 → 类型化导出参数（preview / execute / 确认快照共用同一套校验）。
    func exportOptions() throws -> ExportOptions {
        guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Cut 3 / 3b-3（E-19 相邻）：UI 侧校验错误直接用协议层的 GatherError
            // 码（码值与 GatherDomain.ExportServiceError.description 逐字一致，
            // 文案漏斗不变），不再引用领域枚举。
            throw GatherError(code: .EXPORT_DIR_INVALID)
        }
        let parsedQuality: Double?
        if format == .jpeg {
            guard let value = Double(quality), value.rounded() == value else {
                throw GatherError(code: .EXPORT_JPEG_QUALITY_INVALID)
            }
            parsedQuality = value
        } else {
            parsedQuality = nil
        }
        let parsedDimension: Int?
        if format == .original {
            parsedDimension = nil
        } else if maxDimension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedDimension = nil
        } else if let value = Int(maxDimension.prefix(while: \.isNumber)), value > 0 {
            // 对齐 TS parseInt(maxDimension, 10)：小数截断（"12.5"→12）；
            // 非数字前缀 → nil → maxDimensionInvalid，保持安全路径。
            parsedDimension = value
        } else {
            throw GatherError(code: .EXPORT_MAX_DIMENSION_INVALID)
        }
        return ExportOptions(
            scope: scope,
            variantPolicy: variantPolicy,
            format: format,
            quality: parsedQuality,
            maxDimension: parsedDimension,
            tiffCompression: format == .tiff ? tiffCompression : nil,
            // 对齐 TS export.tsx:67-75：watermarkEnabled && watermarkText 才发送；
            // 勾选但文本为空时不发 watermark，不再以 EXPORT_WATERMARK_TEXT_EMPTY 阻断。
            watermark: transformsAllowed && watermarkEnabled && !watermarkText.isEmpty ? try watermark() : nil,
            // TS export.tsx:60-61：counterStart 1 / dateFormat YYYY-MM-DD。
            naming: ExportNaming(pattern: namingPattern, counterStart: 1, dateFormat: "YYYY-MM-DD"),
            includeXmp: includeXmp,
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func watermark() throws -> ExportWatermark {
        let text = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GatherError(code: .EXPORT_WATERMARK_TEXT_EMPTY) }
        guard let fontSize = Double(watermarkFontSize), fontSize > 0 else {
            throw GatherError(code: .EXPORT_WATERMARK_FONT_SIZE_INVALID)
        }
        return ExportWatermark(
            type: .text,
            content: text,
            position: watermarkPosition,
            opacity: watermarkOpacity,
            fontSize: fontSize
        )
    }
}
