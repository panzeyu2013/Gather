import Foundation
import GatherCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 只读原始素材。所有预览、向量与评测输出仅写到调用者指定目录。
struct Sample: Codable {
    let id: Int
    let photo: String
    let bbox: [Double]
    let quality: Double
    let aligned: Bool
    let embedding: [Double]
}
struct PhotoRun: Codable {
    let photo: String
    let decodeSeconds: Double
    let baselineSeconds: Double
    let sfaceSeconds: Double
    let baselineFailures: Int
    let sfaceFailures: Int
}
struct Sweep: Codable {
    let model: String
    let similarityThreshold: Double
    let clusterSizes: [Int]
    let clusters: [[Int]]
    let noise: [Int]
    let seconds: Double
}
struct Report: Codable {
    let date: String
    let inputPhotos: Int
    let modelSpec: String
    let photos: [PhotoRun]
    let failures: [String]
    let baseline: [Sample]
    let sface: [Sample]
    let sweeps: [Sweep]
    let limitation: String
}
func writeJPEG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw NSError(domain: "Benchmark", code: 1)
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Benchmark", code: 2) }
}
func run() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else {
        print("Usage: gather-face-benchmarks <read-only-photo-folder> <output-folder>")
        return
    }
    let root = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
    guard output.path != root.path, !output.path.hasPrefix(root.path + "/") else {
        throw NSError(domain: "Benchmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "Output must be outside the source folder"])
    }
    let fm = FileManager.default
    try fm.createDirectory(at: output.appendingPathComponent("faces"), withIntermediateDirectories: true)
    let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    let photos = (enumerator?.allObjects as? [URL] ?? []).filter {
        RAWDecoder.supports("." + $0.pathExtension) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.path < $1.path }
    guard !photos.isEmpty else { throw NSError(domain: "Benchmark", code: 4, userInfo: [NSLocalizedDescriptionKey: "No supported photos found"]) }
    let sfaceModel = try FaceEmbeddingModelFactory.make(modelPath: "", modelVersion: "")
    let oldModel = VisionFeaturePrintEmbedder()
    var baseline: [Sample] = [], sface: [Sample] = [], runs: [PhotoRun] = [], failures: [String] = []
    for (index, photo) in photos.enumerated() {
        autoreleasepool {
            do {
                let started = Date()
                let preview = try RAWDecoder.getPreview(path: photo.path, maxDimension: 2048)
                let decoded = Date()
                guard let source = CGImageSourceCreateWithData(preview.buffer as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "Benchmark", code: 5) }
                let oldStart = Date()
                let old = try FaceEncoder.encodeFacesDetailed(in: image, embedder: oldModel)
                let oldTime = Date().timeIntervalSince(oldStart)
                let newStart = Date()
                let new = try FaceEncoder.encodeFacesDetailed(in: image, embedder: sfaceModel)
                let newTime = Date().timeIntervalSince(newStart)
                for face in old.faces {
                    baseline.append(Sample(id: baseline.count, photo: photo.lastPathComponent, bbox: face.bbox,
                        quality: face.quality, aligned: face.aligned, embedding: face.embedding))
                }
                for face in new.faces {
                    let id = sface.count
                    sface.append(Sample(id: id, photo: photo.lastPathComponent, bbox: face.bbox,
                        quality: face.quality, aligned: face.aligned, embedding: face.embedding))
                    let b = face.bbox
                    let rectangle = CGRect(x: b[0] * Double(image.width), y: b[1] * Double(image.height),
                        width: b[2] * Double(image.width), height: b[3] * Double(image.height)).integral
                    if let crop = image.cropping(to: rectangle) {
                        try writeJPEG(crop, to: output.appendingPathComponent("faces/\(id).jpg"))
                    }
                }
                runs.append(PhotoRun(photo: photo.lastPathComponent, decodeSeconds: decoded.timeIntervalSince(started),
                    baselineSeconds: oldTime, sfaceSeconds: newTime, baselineFailures: old.encodeFailures, sfaceFailures: new.encodeFailures))
                print("\(index + 1)/\(photos.count) \(photo.lastPathComponent) faces=\(new.faces.count) baseline=\(String(format: "%.3f", oldTime))s sface=\(String(format: "%.3f", newTime))s")

            } catch {
                failures.append("\(photo.lastPathComponent): \(error.localizedDescription)")
                print("\(index + 1)/\(photos.count) failed: \(error)")
            }
        }
    }
    var sweeps: [Sweep] = []
    for (name, samples) in [("vision-featureprint", baseline), ("sface", sface)] {
        let entries = samples.map { EmbeddingEntry(observationId: $0.id, photoId: $0.photo,
            embedding: $0.embedding.map(Float.init), quality: $0.quality) }
        for threshold in [0.4, 0.5, 0.6, 0.65, 0.7, 0.75] {
            let start = Date()
            let result = try FaceClusterer.clusterEmbeddings(entries: entries, eps: threshold, minPts: 2, coreQualityFloor: 0.35)
            sweeps.append(Sweep(model: name, similarityThreshold: threshold, clusterSizes: result.clusters.map(\.count),
                clusters: result.clusters.map { $0.map(\.observationId) }, noise: result.noise.map(\.observationId), seconds: Date().timeIntervalSince(start)))
        }
    }
    let report = Report(date: ISO8601DateFormatter().string(from: Date()), inputPhotos: photos.count,
        modelSpec: sfaceModel.spec.signature, photos: runs, failures: failures, baseline: baseline, sface: sface,
        sweeps: sweeps, limitation: "Unlabeled single-session dataset: clustering and timing evidence only; no identity accuracy or cross-session generalization claim. Detection/alignment/quality use the same Vision pipeline in both passes. Model loading is excluded from inference timing.")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
    print("Report: \(output.appendingPathComponent("report.json").path)")
}
do { try run() } catch { print("Benchmark failed: \(error)"); exit(1) }
