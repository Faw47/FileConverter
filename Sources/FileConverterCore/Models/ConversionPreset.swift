import Foundation

public enum BackendType: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case avFoundation = "avFoundation"
    case imageIO = "imageIO"
    case pdfKit = "pdfKit"
    case ffmpeg = "ffmpeg"
    case imageMagick = "imageMagick"
    case libreOffice = "libreOffice"
    case ghostscript = "ghostscript"
    case calibre = "calibre"

    public var displayName: String {
        switch self {
        case .auto: return "Auto (Recommended)"
        case .avFoundation: return "Apple AVFoundation / VideoToolbox"
        case .imageIO: return "Apple ImageIO / Core Image"
        case .pdfKit: return "Apple PDFKit"
        case .ffmpeg: return "FFmpeg"
        case .imageMagick: return "ImageMagick"
        case .libreOffice: return "LibreOffice"
        case .ghostscript: return "Ghostscript"
        case .calibre: return "Calibre eBook Converter"
        }
    }
}

/// Optional transformations that change the number or size of outputs. Keeping
/// these in an optional value preserves compatibility with preset files written
/// before these workflows existed.
public struct ConversionProcessingOptions: Codable, Hashable, Sendable {
    public var audioSplitDurationSeconds: Int?
    public var audioTargetFileSizeBytes: Int?
    public var splitPDFIntoPages: Bool

    public init(
        audioSplitDurationSeconds: Int? = nil,
        audioTargetFileSizeBytes: Int? = nil,
        splitPDFIntoPages: Bool = false
    ) {
        self.audioSplitDurationSeconds = audioSplitDurationSeconds
        self.audioTargetFileSizeBytes = audioTargetFileSizeBytes
        self.splitPDFIntoPages = splitPDFIntoPages
    }

    public var isEmpty: Bool {
        audioSplitDurationSeconds == nil
            && audioTargetFileSizeBytes == nil
            && !splitPDFIntoPages
    }
}

public enum VideoCodecType: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case h264 = "h264"
    case hevc = "hevc"
    case proRes = "prores"
    case vp9 = "vp9"
    case av1 = "av1"
    case copy = "copy"
    case none = "none"

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .h264: return "H.264 / AVC"
        case .hevc: return "H.265 / HEVC"
        case .proRes: return "Apple ProRes"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        case .copy: return "Direct Stream Copy"
        case .none: return "No Video"
        }
    }
}

public enum AudioCodecType: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case aac = "aac"
    case alac = "alac"
    case mp3 = "mp3"
    case flac = "flac"
    case opus = "opus"
    case wav = "wav"
    case aiff = "aiff"
    case copy = "copy"
    case none = "none"

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .aac: return "AAC"
        case .alac: return "Apple Lossless (ALAC)"
        case .mp3: return "MP3 (LAME)"
        case .flac: return "FLAC (Lossless)"
        case .opus: return "Opus"
        case .wav: return "PCM WAV"
        case .aiff: return "PCM AIFF"
        case .copy: return "Direct Stream Copy"
        case .none: return "No Audio"
        }
    }
}

public enum QualitySetting: String, Codable, CaseIterable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case veryHigh = "veryHigh"
    case lossless = "lossless"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .low: return "Smaller File (Lower Quality)"
        case .medium: return "Balanced"
        case .high: return "High Quality"
        case .veryHigh: return "Maximum Visual Quality"
        case .lossless: return "Lossless"
        case .custom: return "Custom"
        }
    }
}

public enum ResolutionSetting: Codable, Hashable, Sendable {
    case original
    case uhd4k
    case hd1080p
    case hd720p
    case sd480p
    case custom(width: Int, height: Int)

    public var displayName: String {
        switch self {
        case .original: return "Original Dimensions"
        case .uhd4k: return "4K UHD (3840x2160)"
        case .hd1080p: return "1080p Full HD (1920x1080)"
        case .hd720p: return "720p HD (1280x720)"
        case .sd480p: return "480p SD (854x480)"
        case .custom(let w, let h): return "Custom (\(w)x\(h))"
        }
    }
}

public enum HardwareAccelerationPolicy: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case forceAppleHardware = "forceAppleHardware"
    case softwareOnly = "softwareOnly"

    public var displayName: String {
        switch self {
        case .auto: return "Auto (Hardware If Available)"
        case .forceAppleHardware: return "Apple Silicon / VideoToolbox Hardware"
        case .softwareOnly: return "Software Encoder (CPU)"
        }
    }
}

public enum OutputDirectoryPolicy: Codable, Hashable, Sendable {
    case sameAsSource
    case downloads
    case sourceSubfolder(subfolderName: String)
    case customFolder(bookmarkData: Data, displayPath: String)

    public var displayName: String {
        switch self {
        case .sameAsSource: return "Same Directory as Original"
        case .downloads: return "Downloads Folder"
        case .sourceSubfolder(let sub): return "Subfolder: \(sub)/"
        case .customFolder(_, let path): return "Custom Folder: \(path)"
        }
    }
}

public enum OverwritePolicy: String, Codable, CaseIterable, Sendable {
    case appendNumber = "appendNumber"
    case overwrite = "overwrite"
    case skip = "skip"
    case replaceIfNewer = "replaceIfNewer"
    case ask = "ask"

    public var displayName: String {
        switch self {
        case .appendNumber: return "Append Number (e.g. video (1).mp4)"
        case .overwrite: return "Overwrite Existing File"
        case .skip: return "Skip If File Exists"
        case .replaceIfNewer: return "Replace Only If Newer"
        case .ask: return "Ask Before Overwriting"
        }
    }
}

public struct ConversionPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var builtInKey: String?
    public var name: String
    public var menuName: String
    public var category: FormatCategory
    public var sourceFormats: [String]
    public var destinationFormat: String
    public var backend: BackendType
    public var videoCodec: VideoCodecType
    public var audioCodec: AudioCodecType
    public var container: String?
    public var quality: QualitySetting
    public var videoBitrateKbps: Int?
    public var crf: Int?
    public var resolution: ResolutionSetting
    public var framerate: Double?
    public var audioBitrateKbps: Int?
    public var audioSampleRate: Int?
    public var audioChannels: Int?
    public var hardwareAcceleration: HardwareAccelerationPolicy
    public var preserveMetadata: Bool
    public var preserveCreationDate: Bool
    public var outputDirectoryPolicy: OutputDirectoryPolicy
    public var filenamePattern: String
    public var overwritePolicy: OverwritePolicy
    public var extraBackendOptions: [String: String]
    public var processingOptions: ConversionProcessingOptions?
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        builtInKey: String? = nil,
        name: String,
        menuName: String? = nil,
        category: FormatCategory,
        sourceFormats: [String],
        destinationFormat: String,
        backend: BackendType = .auto,
        videoCodec: VideoCodecType = .auto,
        audioCodec: AudioCodecType = .auto,
        container: String? = nil,
        quality: QualitySetting = .high,
        videoBitrateKbps: Int? = nil,
        crf: Int? = nil,
        resolution: ResolutionSetting = .original,
        framerate: Double? = nil,
        audioBitrateKbps: Int? = nil,
        audioSampleRate: Int? = nil,
        audioChannels: Int? = nil,
        hardwareAcceleration: HardwareAccelerationPolicy = .auto,
        preserveMetadata: Bool = true,
        preserveCreationDate: Bool = true,
        outputDirectoryPolicy: OutputDirectoryPolicy = .sameAsSource,
        filenamePattern: String = "{name}",
        overwritePolicy: OverwritePolicy = .appendNumber,
        extraBackendOptions: [String: String] = [:],
        processingOptions: ConversionProcessingOptions? = nil,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.builtInKey = builtInKey
        self.name = name
        self.menuName = menuName ?? name
        self.category = category
        self.sourceFormats = sourceFormats.map { $0.lowercased() }
        self.destinationFormat = destinationFormat.lowercased()
        self.backend = backend
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.container = container?.lowercased()
        self.quality = quality
        self.videoBitrateKbps = videoBitrateKbps
        self.crf = crf
        self.resolution = resolution
        self.framerate = framerate
        self.audioBitrateKbps = audioBitrateKbps
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.hardwareAcceleration = hardwareAcceleration
        self.preserveMetadata = preserveMetadata
        self.preserveCreationDate = preserveCreationDate
        self.outputDirectoryPolicy = outputDirectoryPolicy
        self.filenamePattern = filenamePattern
        self.overwritePolicy = overwritePolicy
        self.extraBackendOptions = extraBackendOptions
        self.processingOptions = processingOptions?.isEmpty == true ? nil : processingOptions
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    public var audioSplitDurationSeconds: Int? {
        get { processingOptions?.audioSplitDurationSeconds }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.audioSplitDurationSeconds = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var audioTargetFileSizeBytes: Int? {
        get { processingOptions?.audioTargetFileSizeBytes }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.audioTargetFileSizeBytes = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var splitPDFIntoPages: Bool {
        get { processingOptions?.splitPDFIntoPages ?? false }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.splitPDFIntoPages = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var requiresExternalAudioProcessing: Bool {
        audioSplitDurationSeconds != nil || audioTargetFileSizeBytes != nil
    }
}
