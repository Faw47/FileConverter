import Foundation

/// What a conversion needs to know about a video source.
public struct SourceMediaInfo: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    /// Clockwise display rotation in degrees (0, 90, 180, 270).
    public var rotation: Int
    public var frameRate: Double?
    public var bitRateKbps: Double?
    public var videoCodec: String?
    public var pixelFormat: String?
    public var colorTransfer: String?
    public var colorPrimaries: String?
    public var colorSpace: String?
    public var audioCodecs: [String]
    /// Subtitle codec names keyed by absolute stream index.
    public var subtitleStreams: [(index: Int, codec: String)]
    public var chapterCount: Int
    public var duration: Double?
    /// Sample rate of the first audio stream, in hertz.
    public var audioSampleRate: Int?

    public init(
        width: Int? = nil,
        height: Int? = nil,
        rotation: Int = 0,
        frameRate: Double? = nil,
        bitRateKbps: Double? = nil,
        videoCodec: String? = nil,
        pixelFormat: String? = nil,
        colorTransfer: String? = nil,
        colorPrimaries: String? = nil,
        colorSpace: String? = nil,
        audioCodecs: [String] = [],
        subtitleStreams: [(index: Int, codec: String)] = [],
        chapterCount: Int = 0,
        duration: Double? = nil,
        audioSampleRate: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.rotation = rotation
        self.frameRate = frameRate
        self.bitRateKbps = bitRateKbps
        self.videoCodec = videoCodec
        self.pixelFormat = pixelFormat
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.colorSpace = colorSpace
        self.audioCodecs = audioCodecs
        self.subtitleStreams = subtitleStreams
        self.chapterCount = chapterCount
        self.duration = duration
        self.audioSampleRate = audioSampleRate
    }

    public static func == (lhs: SourceMediaInfo, rhs: SourceMediaInfo) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.rotation == rhs.rotation
            && lhs.frameRate == rhs.frameRate && lhs.bitRateKbps == rhs.bitRateKbps
            && lhs.videoCodec == rhs.videoCodec && lhs.pixelFormat == rhs.pixelFormat
            && lhs.colorTransfer == rhs.colorTransfer && lhs.colorPrimaries == rhs.colorPrimaries
            && lhs.colorSpace == rhs.colorSpace && lhs.audioCodecs == rhs.audioCodecs
            && lhs.subtitleStreams.map(\.index) == rhs.subtitleStreams.map(\.index)
            && lhs.subtitleStreams.map(\.codec) == rhs.subtitleStreams.map(\.codec)
            && lhs.chapterCount == rhs.chapterCount && lhs.duration == rhs.duration
    }

    /// PQ (HDR10, Dolby Vision base) or HLG transfer.
    public var isHDR: Bool {
        guard let transfer = colorTransfer?.lowercased() else { return false }
        return transfer == "smpte2084" || transfer == "arib-std-b67"
            || transfer.contains("2084") || transfer.contains("hlg")
    }

    /// Size as shown to the viewer, after rotation.
    public var displaySize: (width: Int, height: Int)? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return abs(rotation) % 180 == 90 ? (height, width) : (width, height)
    }
}

public enum VideoGeometry {
    /// The bounding box a resolution setting describes, in landscape terms.
    /// `nil` means "keep the source size".
    public static func box(for resolution: ResolutionSetting) -> (long: Int, short: Int)? {
        switch resolution {
        case .original: return nil
        case .uhd4k: return (3840, 2160)
        case .hd1080p: return (1920, 1080)
        case .hd720p: return (1280, 720)
        case .sd480p: return (854, 480)
        case .custom(let width, let height):
            guard width > 0, height > 0 else { return nil }
            return (max(width, height), min(width, height))
        }
    }

    /// Output size for a source shown at `displayWidth`×`displayHeight`.
    /// The box is turned to match the source's orientation, the result keeps
    /// the source aspect ratio, never exceeds the source, and is even in both
    /// dimensions (required by 4:2:0 encoders).
    public static func targetSize(
        displayWidth: Int,
        displayHeight: Int,
        resolution: ResolutionSetting
    ) -> (width: Int, height: Int) {
        let evenWidth = max(2, displayWidth - displayWidth % 2)
        let evenHeight = max(2, displayHeight - displayHeight % 2)
        guard let box = box(for: resolution), displayWidth > 0, displayHeight > 0 else {
            return (evenWidth, evenHeight)
        }
        let isPortrait = displayHeight > displayWidth
        let boxWidth = Double(isPortrait ? box.short : box.long)
        let boxHeight = Double(isPortrait ? box.long : box.short)
        let scale = min(1.0, boxWidth / Double(displayWidth), boxHeight / Double(displayHeight))
        guard scale < 1.0 else { return (evenWidth, evenHeight) }
        let width = Int((Double(displayWidth) * scale).rounded(.down))
        let height = Int((Double(displayHeight) * scale).rounded(.down))
        return (max(2, width - width % 2), max(2, height - height % 2))
    }

    /// FFmpeg `scale` filter implementing `targetSize` without knowing the
    /// source size in advance. FFmpeg rotates before filtering, so `iw`/`ih`
    /// are display dimensions. Returns nil for `.original`.
    public static func ffmpegScaleFilter(for resolution: ResolutionSetting) -> String? {
        guard let box = box(for: resolution) else { return nil }
        let long = box.long, short = box.short
        // Fit inside the box oriented like the source, capped at the source
        // size so nothing is upscaled; force even dimensions.
        let width = "'if(gte(iw,ih),min(iw,\(long)),min(iw,\(short)))'"
        let height = "'if(gte(iw,ih),min(ih,\(short)),min(ih,\(long)))'"
        return "scale=w=\(width):h=\(height):force_original_aspect_ratio=decrease:force_divisible_by=2"
    }
}

public enum VideoBitrateModel {
    /// Target average bitrate in kbps for the output picture. Smaller presets
    /// never exceed the source bitrate (re-encoding cannot add detail).
    public static func targetKbps(
        width: Int,
        height: Int,
        fps: Double?,
        codec: VideoCodecType,
        quality: QualitySetting,
        sourceKbps: Double?
    ) -> Int {
        let bitsPerPixel: Double
        switch quality {
        case .low: bitsPerPixel = 0.05
        case .medium, .custom: bitsPerPixel = 0.07
        case .high: bitsPerPixel = 0.10
        case .veryHigh, .lossless: bitsPerPixel = 0.15
        }
        let codecFactor: Double
        switch codec {
        case .hevc, .av1: codecFactor = 0.6
        case .vp9: codecFactor = 0.7
        default: codecFactor = 1.0
        }
        let frameRate = min(max(fps ?? 30, 1), 60)
        var kbps = Double(width * height) * frameRate * bitsPerPixel * codecFactor / 1_000
        if let sourceKbps, sourceKbps > 0, quality == .low || quality == .medium {
            kbps = min(kbps, sourceKbps)
        }
        return Int(min(max(kbps, 300), 100_000))
    }
}
