import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Estimates how much disk space a conversion will write, so the pre-flight
/// check refuses only conversions that genuinely will not fit.
public enum OutputSizeEstimator {
    public struct SourceMeasurements: Sendable, Equatable {
        public var fileSize: Int64
        public var duration: Double?
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var pageCount: Int?
        public var pageSizePoints: CGSize?

        public init(
            fileSize: Int64,
            duration: Double? = nil,
            pixelWidth: Int? = nil,
            pixelHeight: Int? = nil,
            pageCount: Int? = nil,
            pageSizePoints: CGSize? = nil
        ) {
            self.fileSize = fileSize
            self.duration = duration
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.pageCount = pageCount
            self.pageSizePoints = pageSizePoints
        }
    }

    /// Reads just enough of the source to size the output.
    public static func measure(_ url: URL, category: FormatCategory?, formatID: String?) async -> SourceMeasurements {
        let size = FileAccessManager.shared.fileSize(at: url)
        var result = SourceMeasurements(fileSize: size)
        switch category {
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 { result.duration = seconds }
            }
        case .image:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                result.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                result.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
            }
        case .document:
            if formatID == "pdf", let document = CGPDFDocument(url as CFURL) {
                result.pageCount = document.numberOfPages
                if let page = document.page(at: 1) {
                    result.pageSizePoints = page.getBoxRect(.cropBox).size
                }
            }
        default:
            break
        }
        return result
    }

    /// Bytes the conversion is expected to write (all outputs together).
    public static func estimate(
        preset: ConversionPreset,
        destination: FormatDefinition?,
        source: SourceMeasurements,
        outputCount: Int
    ) -> Int64 {
        let fallback = Int64(Double(max(source.fileSize, 1_000_000)) * 1.25)
        guard let destination else { return fallback }
        let destinationID = destination.id

        switch destination.category {
        case .audio:
            guard let duration = source.duration else { return fallback }
            if ["wav", "aiff"].contains(destinationID) || preset.audioCodec == .wav || preset.audioCodec == .aiff {
                return Int64(pcmBytesPerSecond(preset) * duration)
            }
            if ["flac"].contains(destinationID) || preset.audioCodec == .alac || preset.audioCodec == .flac {
                return Int64(pcmBytesPerSecond(preset) * duration * 0.7)
            }
            let kbps = Double(preset.audioBitrateKbps ?? 320)
            return Int64(duration * kbps * 1_000 / 8 * 1.05)

        case .video:
            guard let duration = source.duration else { return fallback }
            if destinationID == "gif" {
                return max(fallback, Int64(duration * 2_000_000))
            }
            let sourceKbps = Double(source.fileSize) * 8 / 1_000 / duration
            let videoKbps: Double
            if let explicit = preset.videoBitrateKbps {
                videoKbps = Double(explicit)
            } else if preset.videoCodec == .proRes {
                videoKbps = 150_000
            } else if preset.quality == .lossless || preset.quality == .veryHigh {
                videoKbps = sourceKbps * 1.5
            } else {
                videoKbps = sourceKbps
            }
            let audioKbps = Double(preset.audioBitrateKbps ?? 256)
            return Int64(duration * (videoKbps + audioKbps) * 1_000 / 8 * 1.05)

        case .image:
            if let pages = source.pageCount, let pageSize = source.pageSizePoints {
                // PDF pages rendered to images.
                let dpi = Double(preset.processingOptions?.pdfDPI ?? 300)
                let pixels = (pageSize.width * dpi / 72) * (pageSize.height * dpi / 72)
                let perPage = pixels * bytesPerPixel(destinationID)
                return Int64(perPage * Double(pages))
            }
            guard let width = source.pixelWidth, let height = source.pixelHeight else { return fallback }
            return Int64(Double(width * height) * bytesPerPixel(destinationID) * Double(max(1, outputCount)))

        case .document:
            if destinationID == "pdf", let pages = source.pageCount, preset.isPDFCompressWorkflow {
                // Compression is expected to shrink; allow for no gain.
                return max(source.fileSize, Int64(pages) * 50_000)
            }
            return fallback

        case .custom:
            return fallback
        }
    }

    private static func pcmBytesPerSecond(_ preset: ConversionPreset) -> Double {
        let rate = Double(preset.audioSampleRate ?? 48_000)
        let channels = Double(preset.audioChannels ?? 2)
        let bytes = Double(preset.audioBitDepth?.bitDepthNumber ?? 16) / 8
        return rate * channels * bytes
    }

    /// Upper bound per pixel: uncompressed formats need ~4 bytes, PNG ~2,
    /// lossy formats well under 1.
    private static func bytesPerPixel(_ formatID: String) -> Double {
        switch formatID {
        case "tiff", "bmp", "icns", "ico": return 4
        case "png", "gif": return 2
        default: return 0.6
        }
    }
}
