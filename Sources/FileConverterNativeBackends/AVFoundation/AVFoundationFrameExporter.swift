import AVFoundation
import CoreMedia
import FileConverterCore
import Foundation
import ImageIO

/// Saves one frame of a video as a still image (JPEG, PNG, HEIC, TIFF).
enum AVFoundationFrameExporter {
    static func canWrite(_ destination: FormatDefinition) -> Bool {
        destination.category == .image
            && destination.nativeEncoderAvailable
            && NativeImageCodecs.canEncode(destination)
            && destination.id != "gif"
    }

    static func export(
        asset: AVAsset,
        preset: ConversionPreset,
        sourcePath: String,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.decoderUnavailable(codec: "video", reason: "The source has no video track.")
        }
        guard let destination = FormatRegistry.shared.format(forID: preset.destinationFormat),
              let typeIdentifier = destination.utTypeIdentifiers.first(where: NativeImageCodecs.canEncode(typeIdentifier:)) else {
            throw ConversionError.unsupportedOutputFormat(targetFormat: preset.destinationFormat)
        }

        var warnings: [String] = []
        let duration = max(0, CMTimeGetSeconds(try await asset.load(.duration)))
        let requested = max(0, preset.frameTimeSeconds ?? 0)
        let seconds = MediaTrim.frameTime(for: preset, durationSeconds: duration)
        if duration > 0, requested > duration {
            warnings.append("The video is shorter than \(MediaTrim.formatTime(requested)), so the last frame was saved.")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = CGRect(origin: .zero, size: naturalSize).applying(transform)
        if let limit = ImageGeometry.maxPixelSize(
            resolution: preset.resolution,
            sourceWidth: Int(abs(display.width).rounded()),
            sourceHeight: Int(abs(display.height).rounded())
        ) {
            generator.maximumSize = CGSize(width: limit, height: limit)
        }
        progress(0.2)

        // The exact frame first; a time past the last frame falls back to
        // the nearest one.
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let image: CGImage
        do {
            image = try await generator.image(at: time).image
        } catch {
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            do {
                image = try await generator.image(at: time).image
            } catch {
                throw ConversionError.malformedSource(
                    path: sourcePath,
                    reason: "Could not read a frame at \(MediaTrim.formatTime(seconds)): \(error.localizedDescription)"
                )
            }
        }
        try Task.checkCancellation()
        progress(0.7)

        guard let output = CGImageDestinationCreateWithURL(destinationURL as CFURL, typeIdentifier as CFString, 1, nil) else {
            throw ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: qualityFactor(preset.quality)]
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.encoderUnavailable(codec: destination.id, reason: "Could not write the image.")
        }
        progress(1)
        return warnings
    }

    static func qualityFactor(_ quality: QualitySetting) -> Double {
        switch quality {
        case .low: return 0.5
        case .medium: return 0.75
        case .high: return 0.9
        case .veryHigh: return 0.98
        case .lossless: return 1.0
        case .custom: return 0.85
        }
    }
}
