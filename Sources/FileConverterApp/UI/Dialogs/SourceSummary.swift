import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One line about a file, for dialog headers: "JPEG image · 3.1 MB · 4032 × 3024"
/// or "MPEG-4 movie · 48 MB · 2:31".
enum SourceSummary {
    static func line(for url: URL) async -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        var parts: [String] = []
        if let kind = values?.localizedTypeDescription { parts.append(kind) }
        if let size = values?.fileSize {
            parts.append(Int64(size).formatted(.byteCount(style: .file)))
        }
        if let detail = await detail(for: url) { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func detail(for url: URL) async -> String? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width) × \(height)"
        }
        if type?.conforms(to: .audiovisualContent) == true {
            guard let duration = try? await AVURLAsset(url: url).load(.duration),
                  duration.seconds.isFinite, duration.seconds > 0 else { return nil }
            return Duration.seconds(duration.seconds).formatted(.time(pattern: duration.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        }
        return nil
    }
}
