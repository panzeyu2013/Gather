// desktop/native/gather-core/Sources/GatherProtocol/API/APIContractIndex.swift
// Cut 1 / 阶段 1A：API 目录索引（只有注释，无运行时代码）。
//
// 本目录只放类型化协议与输入/输出类型，不含实现：
// - *API.swift：16 个域协议（110 个方法），文件头注明职责 / 对应命令 / 校验归属；
// - Core/：Confirmed、PageRequest、PhotoPathPolicy、Validation；
// - Errors/GatherError.swift：API 边界唯一错误类型（code + params + underlying）；
// - Inputs/：形状不匹配或需要校验/默认值的 Decodable + Sendable 输入；
// - Outputs/：新增的稳定结果类型。
//
// 输入策略（D-007）：
// - 复用旧 *Params：SessionUpdateParams、PersonCreateParams、PersonUpdateParams、
//   PersonSearchPhotosParams、AlbumCreateParams、AlbumUpdateParams、
//   NavigationSplitParams、NavigationMergeParams、NavigationAnalyzeParams、
//   JobCreateParams（JobRequest 别名）、QualityGetParams；
// - 其余在 Inputs/ 重建：默认值、范围校验、确认门禁、合并分支一律显式失败（D-012）。
//
// WP1（2026-10-22）：Protocol 公开面 347 类型 / 1,752 声明 → 251 / 1,320。
// 删除 89 个零引用 DTO（942 行）与 6 个 Router JSON 信封（ResponseID、ErrorDetail、
// ResponseErrorBody、ResponseOk、ResponseErr、Response<T>；原 Core.swift:158-315），
// 以及失去唯一消费者的 BindingData / MetadataMutationTarget。
// 上面 11 个旧 *Params 是仅存的复用输入（均被 API 签名直接引用）；新增输入必须放
// Inputs/，不要复活 Router 的 *Params 或 Response*。
//
// 破坏性入口（D-011）：一律 Confirmed<T>；public init + ConfirmationSource，
// 是调用点标记而非密码学门禁；API 实现不得自行补确认。
//
// 路径授权：PhotoAPI.pathPolicy（PhotoPathPolicy.containsFilepath）；实现必须先
// 判定再触碰文件系统，未登记路径转 PHOTO_NOT_FOUND 语义错误。
//
// 输出策略：优先复用 Protocol DTO；新增结果类型见 Outputs/（SessionCreateResult、
// PhotoPage、PhotoSearchResult、PhotoDimensions、FaceModelsStatus、CullingSyncStatus、
// PersonCreateResult、PersonPhotosResult、GlobalPhotoPage、JobHandle/JobEvent）。
//
// 待办 / 风险：
// 1. D-010（P0）：GatherErrorCode.INVALID_PARAM（当前 186 项）已在 Protocol/Core.swift；
//    GatherError.invalidParameter 直接使用该码，params 携带 field/reason。
//    路径授权失败由 PHOTO_NOT_FOUND 收敛（见 PhotoPathPolicy）。
// 2. 输入 init(from:) 对缺字段/未知枚举抛 DecodingError；1B 在 API 边界统一映射为
//    GatherError（D-010 后 INVALID_PARAM）。
// 3. FaceClusterData / FaceAnalysisResult / FkwUnbindResult / SimilarityResult 目前在
//    Services，协议暂直接引用；Cut 3 搬迁时随协议移入 GatherProtocol（字段不变）。
// 4. JobHandle 事件流：1B 需把 JobService 进度回调适配成 AsyncStream；
//    QualityAPI.analyze 仍返回 AnalysisJobData（旧形状）。
// 5. 语义保持：sim.analyze 仍返回 Bool、{done:true} 类命令改为 Void；
//    O1-O6 的进一步合并留给 Cut 1 后续评估，不在 1A 改语义。

import Foundation
