import AVFoundation
import FileConverterCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A rough idea of how big the result will be, shown before converting.
/// Photos are measured by encoding a few of them in memory; audio and video
/// are worked out from their length and the bitrate the preset will use.
/// Nil when there is no honest way to tell (documents, lossless audio).
enum OutputSizePreview {
    static func estimate(preset: ConversionPreset, sources: [URL]) async -> String? {
        guard !sources.isEmpty else { return nil }
        if let cap = preset.videoTargetFileSizeBytes ?? preset.audioTargetFileSizeBytes {
            let size = format(Int64(cap))
            return sources.count == 1 ? "at most \(size)" : "at most \(size) each"
        }
        var sampled: [Int64] = []
        for url in sources.prefix(3) {
            guard let bytes = await estimateOne(preset: preset, source: url), bytes > 0 else { return nil }
            sampled.append(bytes)
        }
        let total = sampled.reduce(0, +) / Int64(sampled.count) * Int64(sources.count)
        return sources.count == 1 ? "about \(format(total))" : "about \(format(total)) in total"
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func estimateOne(preset: ConversionPreset, source: URL) async -> Int64? {
        switch preset.category {
        case .image:
            return await Task.detached(priority: .utility) { imageBytes(preset: preset, source: source) }.value
        case .video:
            return await mediaBytes(preset: preset, source: source, includesVideo: true)
        case .audio:
            return await mediaBytes(preset: preset, source: source, includesVideo: false)
        default:
            return nil
        }
    }

    // MARK: - Images

    private static func imageBytes(preset: ConversionPreset, source: URL) -> Int64? {
        guard source.pathExtension.lowercased() != "pdf",
              let type = UTType(filenameExtension: preset.destinationFormat),
              let writable = CGImageDestinationCopyTypeIdentifiers() as? [String],
              writable.contains(type.identifier),
              let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }

        var maxPixels: Int?
        switch preset.resolution {
        case .original: maxPixels = nil
        case .uhd4k: maxPixels = 3840
        case .hd1080p: maxPixels = 1920
        case .hd720p: maxPixels = 1280
        case .sd480p: maxPixels = 854
        case .custom(let width, let height): maxPixels = max(width, height)
        }
        let image: CGImage?
        if let maxPixels {
            image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        guard let image else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: lossyQuality(preset.quality),
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Int64(data.length)
    }

    /// The same quality numbers the ImageIO converter uses.
    private static func lossyQuality(_ quality: QualitySetting) -> Double {
        switch quality {
        case .low: return 0.5
        case .medium: return 0.75
        case .high: return 0.9
        case .veryHigh: return 0.98
        case .lossless: return 1.0
        case .custom: return 0.85
        }
    }

    // MARK: - Audio and video

    private static let losslessAudio: Set<AudioCodecType> = [.wav, .aiff, .flac, .alac]

    private static func mediaBytes(preset: ConversionPreset, source: URL, includesVideo: Bool) async -> Int64? {
        if losslessAudio.contains(preset.audioCodec) || preset.quality == .lossless { return nil }
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }

        var audioKbps = preset.audioBitrateKbps ?? defaultAudioKbps(preset.quality)
        if (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty ?? true { audioKbps = 0 }
        var videoKbps = 0
        if includesVideo {
            if preset.allowsStreamCopy == true {
                // Rewrapping keeps the original stream.
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return size > 0 ? size : nil
            }
            guard preset.videoCodec != .proRes,
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize) else { return nil }
            let fps = (try? await track.load(.nominalFrameRate)).map(Double.init)
            let sourceKbps = (try? await track.load(.estimatedDataRate)).map { Double($0) / 1_000 }
            let target = VideoGeometry.targetSize(
                displayWidth: Int(abs(natural.width)),
                displayHeight: Int(abs(natural.height)),
                resolution: preset.resolution
            )
            videoKbps = preset.videoBitrateKbps ?? VideoBitrateModel.targetKbps(
                width: target.width,
                height: target.height,
                fps: preset.framerate ?? fps,
                codec: preset.videoCodec == .auto ? .h264 : preset.videoCodec,
                quality: preset.quality,
                sourceKbps: sourceKbps
            )
        }
        return Int64(seconds * Double(videoKbps + audioKbps) * 1_000 / 8)
    }

    private static func defaultAudioKbps(_ quality: QualitySetting) -> Int {
        switch quality {
        case .low: return 128
        case .medium, .custom: return 192
        case .high: return 256
        case .veryHigh, .lossless: return 320
        }
    }
}
