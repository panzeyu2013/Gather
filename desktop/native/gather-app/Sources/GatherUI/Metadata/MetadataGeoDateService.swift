// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataGeoDateService.swift
// Wave5（batch5）：坐标反查地名（编辑器"根据坐标反查地名"按钮）与失败映射。
//
// 为什么不用 CLGeocoder：macOS 26 起 CLGeocoder / CLPlacemark 已废弃
// （scripts/check-warnings.sh 是 -warnings-as-errors，用旧 API 直接红）；
// 改用 MapKit 的 MKReverseGeocodingRequest（macOS 26+，项目最低版本即 26）。
//
// 分层：UI 只依赖 GeoPlaceLookup 端口；MapKitGeoPlaceLookup 负责把
// MKMapItem.addressRepresentations 映射成 IPTC 需要的 city/state/country；
// 测试注入 fake，不触网。
import CoreLocation
import Foundation
import GatherProtocol
import MapKit

/// 反查命中的地名（只保留编辑器要填的 IPTC 字段；空值不写）。
struct GeoPlace: Equatable, Sendable {
    var city: String?
    var state: String?
    var country: String?
}

/// 反查失败分类：UI 只按分类给中文文案，不解析 MapKit 错误文本。
enum GeoLookupError: Error, Equatable {
    /// 坐标没有对应地名（海面 / 无人区）。
    case noResult
    /// 网络或地理编码服务不可用（超时/限流/离线）。
    case network
    /// 调用被取消。
    case cancelled
}

/// 反查端口（测试注入 fake；生产用 MapKitGeoPlaceLookup）。
protocol GeoPlaceLookup: Sendable {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeoPlace
}

/// MapKit 实现（macOS 26+ 新 API）。
struct MapKitGeoPlaceLookup: GeoPlaceLookup {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeoPlace {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw GeoLookupError.noResult
        }
        let items: [MKMapItem]
        do {
            items = try await request.mapItems
        } catch is CancellationError {
            throw GeoLookupError.cancelled
        } catch {
            throw GeoLookupError.network
        }
        guard let representations = items.first?.addressRepresentations else {
            throw GeoLookupError.noResult
        }
        let city = Self.normalized(representations.cityName)
        let country = Self.normalized(representations.regionName)
        // 新 API 没有 administrativeArea（州/省）：只能从 "Cupertino, CA" 取第二段，
        // 且只在短代码形态时采用（长地名分支交给 cityName/regionName）。
        let state = Self.stateFromContext(representations.cityWithContext)
        guard city != nil || country != nil || state != nil else {
            throw GeoLookupError.noResult
        }
        return GeoPlace(city: city, state: state, country: country)
    }

    /// "Cupertino, CA" → "CA"；没有第二段/第二段过长（不是州省代码）返回 nil。
    static func stateFromContext(_ context: String?) -> String? {
        guard let context else { return nil }
        let parts = context.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count >= 2 else { return nil }
        let candidate = parts[1]
        guard !candidate.isEmpty, candidate.count <= 12 else { return nil }
        return candidate
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 反查结果 → 编辑器字段值（空值不写，保持 DescriptiveMetadata 三态语义）。
enum GeoPlaceMapping {
    static func fieldValues(_ place: GeoPlace) -> [DescriptiveField: String] {
        var values: [DescriptiveField: String] = [:]
        if let city = place.city { values[.city] = city }
        if let state = place.state { values[.state] = state }
        if let country = place.country { values[.country] = country }
        return values
    }

    /// 失败分类 → 本地化 key（新增 key 列在回执，由 Lead 统一补 en）。
    static func messageKey(for error: Error) -> String {
        guard let lookupError = error as? GeoLookupError else {
            return "地名反查失败：网络或服务不可用，请稍后重试"
        }
        switch lookupError {
        case .noResult:
            return "该坐标没有对应的地名"
        case .cancelled:
            return "地名反查已取消"
        case .network:
            return "地名反查失败：网络或服务不可用，请稍后重试"
        }
    }
}
