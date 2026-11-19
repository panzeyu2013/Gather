// desktop/native/gather-app/Sources/GatherHost/C1/CaptureOneBridge+Writeback.swift
// M11（Wave5 / task-9）后续：CaptureOneBridge 的写回路径（从主文件再拆）。
// 变体级判断写回 + 淘汰红标；R1 写前回读 / R3 browse 补救 / 不写 ack 的口径不变。
//
// 纯搬移：搬移块与拆分前逐字节一致（无需可见性改动，私有 helper 仍在同文件）。
import Foundation
import GatherProtocol
import GatherUI

extension CaptureOneBridge {
    /// 把文件级判断按 variant 写回 C1（在线通道）。
    ///
    /// 流程：路径 → `every image of targetDoc whose path is p`，取该 image 的 variants；
    /// 目标 variant = 已 pick 的那个，否则 position 1；**只写目标 variant**，
    /// 同一 image 其余 variant 原值不动（G5：多 variant 不互相覆盖）。
    /// 写属性：rating / color tag / pick。**A3：pick 只表达 keep**（写 true）；
    /// reject/unreviewed 一律不写 pick —— C1 16.7 sdef 没有 reject 位（:1084），
    /// 写 false 会取消 C1 已有的 pick 且读回只能当 unreviewed（不可逆）。
    /// 不写任何关键词：G4 明确禁止用 culling:keep 污染 C1 词库。
    ///
    /// 收口：写的是 C1 catalog 本身（已是权威），因此**不**再对同一 variant 调
    /// reload metadata（那会把盘上旧 XMP 读回、覆盖刚写入的判断）。**全部命中**时
    /// 才沿用 durable reload-ack（sessions.reload_acked_at），confirm/finalize 门禁
    /// 照常放行；部分成功（notFound/skipped/skippedMultiVariant）不写 ack
    ///（A1：避免门禁误放行）。
    /// 离线/未运行时仍走原 XMP 写回（本方法不触碰 XMP）。
    ///
    /// Wave5（2026-11-11，task-11）补两层安全：
    /// - **R1 写前回读**：先用只读脚本读每个 image 在当前集合里的 variant 数。
    ///   0 → notFound；1 → 维持原写回；>1 → **不猜目标**，整条跳过并进
    ///   skippedMultiVariant（写错 variant 不可逆，96 号 §10 判 P0）。
    ///   回读脚本失败 = 拿不到目标信息，直接上浮 C1_SCRIPT_FAILED（绝不盲写）。
    /// - **R3 作用域补救**：先写当前集合里能写的，再对 notFound（磁盘上存在、父目录
    ///   唯一）让 C1 `browse` 切到该目录后**只重试这些**（重读一次变体数；仍 notFound
    ///   才如实报，UI 提示"C1 当前集合未包含这些照片"）。browse 失败只记 warn，
    ///   不吞错也不谎报成功。
    ///
    /// 【口径已确认 2026-11-11（Lead/产品批准）】**不要**把这里"修"成先 reload 再写/写后 reload：
    /// 变体级写回取代的是"写 XMP 再让 C1 Load"这条链路；若需要 XMP 权威（离线兜底），
    /// 用户应显式走「写回 XMP…」再手动 Load/手动 ack。
    public func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport {
        var unique: [C1VariantWritebackItem] = []
        var seen = Set<String>()
        var notFound: [String] = []
        var skipped = 0
        for item in items {
            let path = item.photoPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else {
                notFound.append(item.photoPath)
                continue
            }
            // 去重键用 canonical（fold /private 前缀），脚本仍用原始路径匹配 C1 登记值。
            let key = ScanPath.canonical(path)
            guard seen.insert(key).inserted else { continue }
            guard unique.count < Self.maxVariantWritebackItems else {
                skipped += 1
                continue
            }
            unique.append(C1VariantWritebackItem(
                photoPath: path,
                rating: max(0, min(5, item.rating)),
                // 越界色标按 None(0) 写：宁可清色标也不把非法整数塞进 C1。
                colorTag: C1ColorTagMapping.label(for: item.colorTag) == nil ? 0 : item.colorTag,
                pick: item.pick))
        }
        guard !unique.isEmpty else {
            return C1VariantWritebackReport(written: 0, notFound: notFound, skipped: skipped)
        }

        let appName = try await captureOneApplicationName()
        // R1：写前回读变体数（脚本失败上浮，绝不按"未知"盲写）。
        let firstPartition = Self.partitionVariantTargets(
            items: unique,
            counts: try await readVariantCounts(
                paths: unique.map(\.photoPath), appName: appName))
        var multiVariant = firstPartition.multiVariant
        var written = 0

        // 第一批：写当前集合里**唯一 variant** 的目标（启发式此时等价于唯一目标）。
        let first = try await writeVariantItems(firstPartition.writable, appName: appName)
        written += first.written
        notFound.append(contentsOf: first.notFound)

        // R3：当前集合里没有的照片若磁盘上存在、父目录唯一 → 让 C1 browse 切到该目录，
        // 然后**只重试这些**（重读一次变体数；已写的第一批不受影响）。只重试一次。
        let missingItems = firstPartition.notFound
        if !missingItems.isEmpty,
           let directory = Self.singleParentDirectory(of: missingItems.map(\.photoPath)),
           await browse(toDirectory: directory, appName: appName) {
            var retried: C1VariantTargetPartition?
            do {
                retried = Self.partitionVariantTargets(
                    items: missingItems,
                    counts: try await readVariantCounts(
                        paths: missingItems.map(\.photoPath), appName: appName))
            } catch {
                // 切集合后回读失败：保留第一次的 notFound（不吞错：日志带原文）。
                GatherLogger.log(
                    "c1.variant_writeback browse=\(directory) 回读失败: \(error)",
                    level: .warn)
                notFound.append(contentsOf: missingItems.map(\.photoPath))
            }
            if let retried {
                multiVariant.append(contentsOf: retried.multiVariant)
                notFound.append(contentsOf: retried.notFound.map(\.photoPath))
                // 第二批的写回脚本失败仍然上浮（不是"找不到"，不能混成 notFound）。
                let second = try await writeVariantItems(retried.writable, appName: appName)
                written += second.written
                notFound.append(contentsOf: second.notFound)
            }
        } else {
            notFound.append(contentsOf: missingItems.map(\.photoPath))
        }

        // A1：部分写回**不解门禁**。reload-acked 是会话级"C1 已看到新值"的断言
        // （DeliveryCoordinator.requireReloadAck 用它放行 confirm/finalize→清理备份），
        // notFound/skipped/skippedMultiVariant 非空说明有请求没写进 C1；此时写 ack 会让
        // 交付在 C1 仍显示旧值时被确认/清理。只有全部命中（且确有写入）才写 ack。
        if written > 0, notFound.isEmpty, skipped == 0,
           multiVariant.isEmpty, let sessionId {
            // C1 catalog 已是权威值：写 durable ack 让 confirm/finalize 门禁放行，
            // 但绝不再触发 reload（会把旧 XMP 读回覆盖判断）。ack 写失败只记日志，
            // 不掩盖"C1 已写入"的事实（: ack 是会话级簿记，不是写入结果）。
            do { try recordReloadAck(sessionId) } catch {
                GatherLogger.log(
                    "c1.variant_writeback ack failed: \(error)", level: .warn)
            }
        }
        return C1VariantWritebackReport(
            written: written, notFound: notFound, skipped: skipped,
            skippedMultiVariant: multiVariant)
    }

    /// 对一批**已确认唯一 variant** 的条目发一次写回脚本；逐条判定写入/未命中。
    ///
    /// 未命中（脚本回 "0"）如实进 notFound：回读到写入之间用户可能切了集合/删了图，
    /// 这是真实结果，不重试也不假装成功。脚本/报告形状失败上浮 C1_SCRIPT_FAILED。
    private func writeVariantItems(
        _ items: [C1VariantWritebackItem],
        appName: String
    ) async throws -> (written: Int, notFound: [String]) {
        guard !items.isEmpty else { return (0, []) }
        let output = try await runAppleScript(
            Self.variantWritebackScript(appName: appName, items: items), timeout: 30)
        guard let flags = Self.parseVariantWritebackReport(output, expected: items.count) else {
            throw CaptureOneBridgeError.scriptFailed(
                "unexpected variant writeback report: \(output)")
        }
        var written = 0
        var notFound: [String] = []
        for (index, flag) in flags.enumerated() {
            if flag == "1" {
                written += 1
            } else {
                notFound.append(items[index].photoPath)
            }
        }
        return (written, notFound)
    }

    // MARK: - Wave5 batch6 / R6：淘汰的红标约定（C1 无 reject 位）

    /// 把"淘汰"在 C1 里表达成红标（只改 color tag = Red；不写 pick/rating/关键词）。
    ///
    /// 为什么用红标而不是别的通道：
    /// - C1 16.7 sdef 的 variant 只有布尔 pick（:1084），**没有 reject 位**；
    /// - XMP 侧用 `culling:reject` 关键词会污染 C1 词库（G4 / 复核 R13 明确禁止）；
    /// - "移入 Trash collection" 需要 collection 语义、会改会话结构（且不可从 Gather 撤销）。
    /// 红标是纯色标覆盖：C1 里一眼可见、用户换色标即可撤销，也不影响 pick/rating/keywords。
    /// 覆盖语义（会盖掉原有色标）必须在 UI 确认弹窗里明示。
    ///
    /// 安全规则（与变体级写回同源，R1/R3）：
    /// - 写前读 variant 数：0 → notFound；>1 → **不猜目标**，整条跳过并进
    ///   skippedMultiVariant（写错 variant 不可逆，96 号 §10 判 P0）；
    /// - 脚本内再防御一次：写入瞬间若 variant 数 ≠ 1 就返回 "2"、不写；
    /// - notFound 若磁盘上存在且父目录唯一 → browse 切集合后重试一次；
    /// - **不写 reload-ack**：红标不改变需要 C1 Load 的 rating/关键词，catalog 本就是权威；
    ///   也绝不写关键词、不调 reload metadata。
    public func writeRejectedColorTags(paths: [String]) async throws -> C1VariantWritebackReport {
        var unique: [String] = []
        var seen = Set<String>()
        var notFound: [String] = []
        var skipped = 0
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else {
                notFound.append(raw)
                continue
            }
            // 去重键用 canonical（fold /private 前缀），脚本仍用原始路径匹配 C1 登记值。
            guard seen.insert(ScanPath.canonical(path)).inserted else { continue }
            guard unique.count < Self.maxVariantWritebackItems else {
                skipped += 1
                continue
            }
            unique.append(path)
        }
        guard !unique.isEmpty else {
            return C1VariantWritebackReport(written: 0, notFound: notFound, skipped: skipped)
        }

        let appName = try await captureOneApplicationName()
        // R1：写前回读变体数（脚本失败上浮，绝不按"未知"盲写）。
        let firstPartition = Self.partitionRejectedColorTagPaths(
            paths: unique,
            counts: try await readVariantCounts(paths: unique, appName: appName))
        var multiVariant = firstPartition.multiVariant
        var written = 0

        let first = try await writeRejectedColorTagItems(
            firstPartition.writable, appName: appName)
        written += first.written
        notFound.append(contentsOf: first.notFound)
        multiVariant.append(contentsOf: first.multiVariant)

        // R3：当前集合里没有的照片若磁盘上存在、父目录唯一 → browse 后只重试这些。
        let missing = firstPartition.notFound
        if !missing.isEmpty,
           let directory = Self.singleParentDirectory(of: missing),
           await browse(toDirectory: directory, appName: appName) {
            var retried: C1RejectedColorTagPartition?
            do {
                retried = Self.partitionRejectedColorTagPaths(
                    paths: missing,
                    counts: try await readVariantCounts(paths: missing, appName: appName))
            } catch {
                GatherLogger.log(
                    "c1.rejected_color_tag browse=\(directory) 回读失败: \(error)",
                    level: .warn)
                notFound.append(contentsOf: missing)
            }
            if let retried {
                multiVariant.append(contentsOf: retried.multiVariant)
                notFound.append(contentsOf: retried.notFound)
                let second = try await writeRejectedColorTagItems(
                    retried.writable, appName: appName)
                written += second.written
                notFound.append(contentsOf: second.notFound)
                multiVariant.append(contentsOf: second.multiVariant)
            }
        } else {
            notFound.append(contentsOf: missing)
        }

        // 口径：不写 durable reload-ack（红标不是"C1 需要重载的元数据"）。
        return C1VariantWritebackReport(
            written: written, notFound: notFound, skipped: skipped,
            skippedMultiVariant: multiVariant)
    }

    /// 对一批**已确认单 variant** 的路径发一次红标脚本；逐条判定结果。
    ///
    /// 为什么把 "2" 单独返回而非当未命中：脚本内防御发现多 variant 是"契约/竞态"
    /// 信息（用户需要回 C1 定变体），与"照片不在当前集合"是两种可执行下一步。
    private func writeRejectedColorTagItems(
        _ paths: [String],
        appName: String
    ) async throws -> (written: Int, notFound: [String], multiVariant: [String]) {
        guard !paths.isEmpty else { return (0, [], []) }
        let output = try await runAppleScript(
            Self.rejectedColorTagScript(appName: appName, paths: paths), timeout: 30)
        guard let flags = Self.parseRejectedColorTagReport(output, expected: paths.count) else {
            throw CaptureOneBridgeError.scriptFailed(
                "unexpected rejected color tag report: \(output)")
        }
        var written = 0
        var notFound: [String] = []
        var multiVariant: [String] = []
        for (index, flag) in flags.enumerated() {
            switch flag {
            case "1": written += 1
            case "2": multiVariant.append(paths[index])
            default: notFound.append(paths[index])
            }
        }
        return (written, notFound, multiVariant)
    }
}
