import Foundation
import ImageIO
import XCTest

/// Reads real output files so tests assert on what a conversion produced,
/// not only on the arguments that were built.
enum MediaAssertions {
    struct Stream {
        let index: Int
        let codecType: String
        let codecName: String
        let codecTag: String
        let width: Int?
        let height: Int?
        let pixelFormat: String?
        let colorTransfer: String?
        let rotation: Int
        let bitRate: Int?
        let sampleRate: Int?
        let channels: Int?
        let bitsPerRawSample: Int?
        let averageFrameRate: Double?
        let tags: [String: String]
    }

    struct ProbeResult {
        let streams: [Stream]
        let chapterCount: Int
        let formatTags: [String: String]
        let duration: Double?
        let formatBitRate: Int?

        var video: Stream? { streams.first { $0.codecType == "video" } }
        var audioStreams: [Stream] { streams.filter { $0.codecType == "audio" } }
        var subtitleStreams: [Stream] { streams.filter { $0.codecType == "subtitle" } }

        /// Dimensions as displayed, after applying rotation metadata.
        var displaySize: (width: Int, height: Int)? {
            guard let video, let width = video.width, let height = video.height else { return nil }
            return abs(video.rotation) % 180 == 90 ? (height, width) : (width, height)
        }
    }

    static func probe(_ url: URL) throws -> ProbeResult {
        guard let ffprobe = TestFixtures.ffprobePath else {
            throw XCTSkip("ffprobe is not installed.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error", "-show_streams", "-show_format", "-show_chapters",
            "-of", "json", url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("ffprobe could not read \(url.lastPathComponent)")
            return ProbeResult(streams: [], chapterCount: 0, formatTags: [:], duration: nil, formatBitRate: nil)
        }

        let rawStreams = json["streams"] as? [[String: Any]] ?? []
        let streams = rawStreams.map { raw -> Stream in
            var rotation = 0
            if let sideData = raw["side_data_list"] as? [[String: Any]] {
                for entry in sideData {
                    if let value = entry["rotation"] as? Int { rotation = value }
                    if let value = entry["rotation"] as? Double { rotation = Int(value) }
                }
            }
            let tags = raw["tags"] as? [String: String] ?? [:]
            if rotation == 0, let rotate = tags["rotate"], let value = Int(rotate) {
                rotation = value
            }
            return Stream(
                index: raw["index"] as? Int ?? 0,
                codecType: raw["codec_type"] as? String ?? "",
                codecName: raw["codec_name"] as? String ?? "",
                codecTag: raw["codec_tag_string"] as? String ?? "",
                width: raw["width"] as? Int,
                height: raw["height"] as? Int,
                pixelFormat: raw["pix_fmt"] as? String,
                colorTransfer: raw["color_transfer"] as? String,
                rotation: rotation,
                bitRate: (raw["bit_rate"] as? String).flatMap(Int.init),
                sampleRate: (raw["sample_rate"] as? String).flatMap(Int.init),
                channels: raw["channels"] as? Int,
                bitsPerRawSample: (raw["bits_per_raw_sample"] as? String).flatMap(Int.init),
                averageFrameRate: (raw["avg_frame_rate"] as? String).flatMap { rate in
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : nil
                },
                tags: tags
            )
        }
        let format = json["format"] as? [String: Any] ?? [:]
        return ProbeResult(
            streams: streams,
            chapterCount: (json["chapters"] as? [Any])?.count ?? 0,
            formatTags: format["tags"] as? [String: String] ?? [:],
            duration: (format["duration"] as? String).flatMap(Double.init),
            formatBitRate: (format["bit_rate"] as? String).flatMap(Int.init)
        )
    }

    /// True when the MP4/MOV `moov` atom precedes `mdat` (fast start).
    static func isFastStart(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return false }
            var size = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            if type == "moov" { return true }
            if type == "mdat" { return false }
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            }
            guard size >= 8 else { return false }
            offset += size
        }
    }
}

enum ImageAssertions {
    struct Info {
        let width: Int
        let height: Int
        let hasAlpha: Bool
        let hasGPS: Bool
        let typeIdentifier: String
    }

    static func info(_ url: URL) throws -> Info {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("ImageIO could not read \(url.lastPathComponent)")
            return Info(width: 0, height: 0, hasAlpha: false, hasGPS: false, typeIdentifier: "")
        }
        return Info(
            width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            hasGPS: props[kCGImagePropertyGPSDictionary] != nil,
            typeIdentifier: CGImageSourceGetType(source) as String? ?? ""
        )
    }

    /// RGBA of the pixel at (x, y) measured from the top-left corner.
    static func pixel(_ url: URL, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("ImageIO could not decode \(url.lastPathComponent)")
            return (0, 0, 0, 0)
        }
        var buffer = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }
}
