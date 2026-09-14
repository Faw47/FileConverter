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

    // PDF Splitting Options
    public var pdfSplitMode: String? // "all", "ranges", "chunks", "evenOdd", "selected"
    public var pdfPageRanges: String? // e.g. "1-5, 8, 11-15"
    public var pdfChunkSize: Int? // e.g. 2
    public var pdfSelectedPages: [Int]? // e.g. [1, 3, 5]
    public var pdfMergeSplitOutputs: Bool
    public var pdfNamingPattern: String? // e.g. "{name}_page_{index}", "{name}_pages_{range}"
    public var pdfZeroPadDigits: Int? // e.g. 3 -> "001"
    public var pdfOutputSubfolder: String? // e.g. "{name} - Pages"

    // PDF Compression Options
    public var pdfCompressionProfile: String? // "screen", "ebook", "printer", "prepress", "custom"
    public var pdfDPI: Int? // 72, 96, 150, 200, 300
    public var pdfImageQuality: Double? // 0.1 to 1.0
    public var pdfColorMode: String? // "color", "grayscale", "monochrome"
    public var pdfRemoveMetadata: Bool
    public var pdfRemoveAnnotations: Bool
    public var pdfRemoveThumbnails: Bool
    public var pdfLinearize: Bool
    public var pdfCompatibilityLevel: String? // "1.4", "1.5", "1.6", "1.7"

    public init(
        audioSplitDurationSeconds: Int? = nil,
        audioTargetFileSizeBytes: Int? = nil,
        splitPDFIntoPages: Bool = false,
        pdfSplitMode: String? = nil,
        pdfPageRanges: String? = nil,
        pdfChunkSize: Int? = nil,
        pdfSelectedPages: [Int]? = nil,
        pdfMergeSplitOutputs: Bool = false,
        pdfNamingPattern: String? = nil,
        pdfZeroPadDigits: Int? = nil,
        pdfOutputSubfolder: String? = nil,
        pdfCompressionProfile: String? = nil,
        pdfDPI: Int? = nil,
        pdfImageQuality: Double? = nil,
        pdfColorMode: String? = nil,
        pdfRemoveMetadata: Bool = false,
        pdfRemoveAnnotations: Bool = false,
        pdfRemoveThumbnails: Bool = false,
        pdfLinearize: Bool = false,
        pdfCompatibilityLevel: String? = nil
    ) {
        self.audioSplitDurationSeconds = audioSplitDurationSeconds
        self.audioTargetFileSizeBytes = audioTargetFileSizeBytes
        self.splitPDFIntoPages = splitPDFIntoPages
        self.pdfSplitMode = pdfSplitMode
        self.pdfPageRanges = pdfPageRanges
        self.pdfChunkSize = pdfChunkSize
        self.pdfSelectedPages = pdfSelectedPages
        self.pdfMergeSplitOutputs = pdfMergeSplitOutputs
        self.pdfNamingPattern = pdfNamingPattern
        self.pdfZeroPadDigits = pdfZeroPadDigits
        self.pdfOutputSubfolder = pdfOutputSubfolder
        self.pdfCompressionProfile = pdfCompressionProfile
        self.pdfDPI = pdfDPI
        self.pdfImageQuality = pdfImageQuality
        self.pdfColorMode = pdfColorMode
        self.pdfRemoveMetadata = pdfRemoveMetadata
        self.pdfRemoveAnnotations = pdfRemoveAnnotations
        self.pdfRemoveThumbnails = pdfRemoveThumbnails
        self.pdfLinearize = pdfLinearize
        self.pdfCompatibilityLevel = pdfCompatibilityLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.audioSplitDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .audioSplitDurationSeconds)
        self.audioTargetFileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .audioTargetFileSizeBytes)
        self.splitPDFIntoPages = try container.decodeIfPresent(Bool.self, forKey: .splitPDFIntoPages) ?? false
        self.pdfSplitMode = try container.decodeIfPresent(String.self, forKey: .pdfSplitMode)
        self.pdfPageRanges = try container.decodeIfPresent(String.self, forKey: .pdfPageRanges)
        self.pdfChunkSize = try container.decodeIfPresent(Int.self, forKey: .pdfChunkSize)
        self.pdfSelectedPages = try container.decodeIfPresent([Int].self, forKey: .pdfSelectedPages)
        self.pdfMergeSplitOutputs = try container.decodeIfPresent(Bool.self, forKey: .pdfMergeSplitOutputs) ?? false
        self.pdfNamingPattern = try container.decodeIfPresent(String.self, forKey: .pdfNamingPattern)
        self.pdfZeroPadDigits = try container.decodeIfPresent(Int.self, forKey: .pdfZeroPadDigits)
        self.pdfOutputSubfolder = try container.decodeIfPresent(String.self, forKey: .pdfOutputSubfolder)
        self.pdfCompressionProfile = try container.decodeIfPresent(String.self, forKey: .pdfCompressionProfile)
        self.pdfDPI = try container.decodeIfPresent(Int.self, forKey: .pdfDPI)
        self.pdfImageQuality = try container.decodeIfPresent(Double.self, forKey: .pdfImageQuality)
        self.pdfColorMode = try container.decodeIfPresent(String.self, forKey: .pdfColorMode)
        self.pdfRemoveMetadata = try container.decodeIfPresent(Bool.self, forKey: .pdfRemoveMetadata) ?? false
        self.pdfRemoveAnnotations = try container.decodeIfPresent(Bool.self, forKey: .pdfRemoveAnnotations) ?? false
        self.pdfRemoveThumbnails = try container.decodeIfPresent(Bool.self, forKey: .pdfRemoveThumbnails) ?? false
        self.pdfLinearize = try container.decodeIfPresent(Bool.self, forKey: .pdfLinearize) ?? false
        self.pdfCompatibilityLevel = try container.decodeIfPresent(String.self, forKey: .pdfCompatibilityLevel)
    }

    public var isEmpty: Bool {
        audioSplitDurationSeconds == nil
            && audioTargetFileSizeBytes == nil
            && !splitPDFIntoPages
            && pdfSplitMode == nil
            && pdfPageRanges == nil
            && pdfChunkSize == nil
            && pdfSelectedPages == nil
            && !pdfMergeSplitOutputs
            && pdfNamingPattern == nil
            && pdfZeroPadDigits == nil
            && pdfOutputSubfolder == nil
            && pdfCompressionProfile == nil
            && pdfDPI == nil
            && pdfImageQuality == nil
            && pdfColorMode == nil
            && !pdfRemoveMetadata
            && !pdfRemoveAnnotations
            && !pdfRemoveThumbnails
            && !pdfLinearize
            && pdfCompatibilityLevel == nil
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

    public var isPDFCompressWorkflow: Bool {
        builtInKey == "document.pdf-compressed"
            || (category == .document && destinationFormat == "pdf" && (menuName.lowercased().contains("compress") || processingOptions?.pdfCompressionProfile != nil))
    }

    public var isPDFSplitWorkflow: Bool {
        builtInKey == "document.pdf-split-pages"
            || splitPDFIntoPages
            || (category == .document && destinationFormat == "pdf" && menuName.lowercased().contains("split"))
    }

    public var isInteractiveWorkflow: Bool {
        isPDFCompressWorkflow || isPDFSplitWorkflow
    }
}
