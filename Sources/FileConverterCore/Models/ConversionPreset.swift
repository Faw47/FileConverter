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
    /// Video size limit (MP4 through FFmpeg): bitrate and picture size are
    /// chosen to fit, and the result is checked and redone if it is larger.
    public var videoTargetFileSizeBytes: Int?
    /// Keep only part of a video or audio file: from this many seconds in.
    public var trimStartSeconds: Double?
    /// Keep only part of a video or audio file: up to this many seconds in.
    public var trimEndSeconds: Double?
    /// Video to image presets: the moment to save, in seconds. `nil` is the
    /// first frame.
    public var frameTimeSeconds: Double?
    /// Audio: make every file about as loud as the others (EBU R128,
    /// −16 LUFS) with FFmpeg's loudnorm filter.
    public var normalizeLoudness: Bool
    public var splitPDFIntoPages: Bool

    // PDF Splitting Options
    public var pdfSplitMode: String? // "all", "ranges", "chunks", "evenOdd", "selected", "extract"
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
    /// Native compression only: turn every page into an image (smallest
    /// file; text stays searchable through on-device recognition).
    public var pdfFlattenToImages: Bool
    /// Turn every page by this many degrees (90 right, 270 left, 180).
    public var pdfRotationDegrees: Int?
    /// Names a password held in memory by `PDFPasswordVault` for this run.
    /// The password itself is never stored here, so presets and history
    /// that keep these options never contain it.
    public var pdfPasswordToken: String?

    public init(
        audioSplitDurationSeconds: Int? = nil,
        audioTargetFileSizeBytes: Int? = nil,
        videoTargetFileSizeBytes: Int? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        frameTimeSeconds: Double? = nil,
        normalizeLoudness: Bool = false,
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
        pdfCompatibilityLevel: String? = nil,
        pdfFlattenToImages: Bool = false,
        pdfRotationDegrees: Int? = nil,
        pdfPasswordToken: String? = nil
    ) {
        self.audioSplitDurationSeconds = audioSplitDurationSeconds
        self.audioTargetFileSizeBytes = audioTargetFileSizeBytes
        self.videoTargetFileSizeBytes = videoTargetFileSizeBytes
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.frameTimeSeconds = frameTimeSeconds
        self.normalizeLoudness = normalizeLoudness
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
        self.pdfFlattenToImages = pdfFlattenToImages
        self.pdfRotationDegrees = pdfRotationDegrees
        self.pdfPasswordToken = pdfPasswordToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.audioSplitDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .audioSplitDurationSeconds)
        self.audioTargetFileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .audioTargetFileSizeBytes)
        self.videoTargetFileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .videoTargetFileSizeBytes)
        self.trimStartSeconds = try container.decodeIfPresent(Double.self, forKey: .trimStartSeconds)
        self.trimEndSeconds = try container.decodeIfPresent(Double.self, forKey: .trimEndSeconds)
        self.frameTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .frameTimeSeconds)
        self.normalizeLoudness = try container.decodeIfPresent(Bool.self, forKey: .normalizeLoudness) ?? false
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
        self.pdfFlattenToImages = try container.decodeIfPresent(Bool.self, forKey: .pdfFlattenToImages) ?? false
        self.pdfRotationDegrees = try container.decodeIfPresent(Int.self, forKey: .pdfRotationDegrees)
        self.pdfPasswordToken = try container.decodeIfPresent(String.self, forKey: .pdfPasswordToken)
    }

    public var isEmpty: Bool {
        audioSplitDurationSeconds == nil
            && audioTargetFileSizeBytes == nil
            && videoTargetFileSizeBytes == nil
            && trimStartSeconds == nil
            && trimEndSeconds == nil
            && frameTimeSeconds == nil
            && !normalizeLoudness
            && pdfRotationDegrees == nil
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
            && !pdfFlattenToImages
            && pdfPasswordToken == nil
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
        case .low: return "Smaller file"
        case .medium: return "Balanced"
        case .high: return "High"
        case .veryHigh: return "Highest"
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
        case .original: return "Original size"
        case .uhd4k: return "4K (3840 × 2160)"
        case .hd1080p: return "1080p (1920 × 1080)"
        case .hd720p: return "720p (1280 × 720)"
        case .sd480p: return "480p (854 × 480)"
        case .custom(let w, let h): return "Custom (\(w) × \(h))"
        }
    }
}

public enum HardwareAccelerationPolicy: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case forceAppleHardware = "forceAppleHardware"
    case softwareOnly = "softwareOnly"

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .forceAppleHardware: return "Hardware only"
        case .softwareOnly: return "Software only (slower)"
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

    public var isCustomFolderAuthorized: Bool {
        guard case .customFolder(let bookmarkData, _) = self else {
            return true
        }
        guard !bookmarkData.isEmpty else { return false }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return false
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
        case .appendNumber: return "Add a number"
        case .overwrite: return "Replace the existing file"
        case .skip: return "Skip the file"
        case .replaceIfNewer: return "Replace if the original is newer"
        case .ask: return "Ask"
        }
    }
}

/// Which settings a preset takes from General settings. `true` means the
/// preset uses the General value; `false` means it uses its own stored value.
public struct PresetInheritance: Codable, Hashable, Sendable {
    public var outputLocation: Bool
    public var filenamePattern: Bool
    public var collisionPolicy: Bool
    public var creationDate: Bool
    public var modificationDate: Bool
    public var locationData: Bool

    public init(
        outputLocation: Bool = true,
        filenamePattern: Bool = true,
        collisionPolicy: Bool = true,
        creationDate: Bool = true,
        modificationDate: Bool = true,
        locationData: Bool = true
    ) {
        self.outputLocation = outputLocation
        self.filenamePattern = filenamePattern
        self.collisionPolicy = collisionPolicy
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.locationData = locationData
    }

    public static let inheritAll = PresetInheritance()
    public static let inheritNone = PresetInheritance(
        outputLocation: false,
        filenamePattern: false,
        collisionPolicy: false,
        creationDate: false,
        modificationDate: false,
        locationData: false
    )

    /// Rules for presets saved before inheritance was explicit. They keep the
    /// behavior those presets had: built-ins followed General settings; custom
    /// presets followed General only where they held the old sentinel values.
    public static func legacy(for preset: ConversionPreset) -> PresetInheritance {
        let outputWasSentinel = preset.outputDirectoryPolicy == .sameAsSource
        let patternWasSentinel = preset.filenamePattern.isEmpty || preset.filenamePattern == "{name}"
        if preset.isBuiltIn {
            // Built-ins always took the General collision policy; their dates
            // now follow General too (the General toggle never reached them).
            return PresetInheritance(
                outputLocation: outputWasSentinel,
                filenamePattern: patternWasSentinel,
                collisionPolicy: true,
                creationDate: true,
                modificationDate: true,
                locationData: true
            )
        }
        return PresetInheritance(
            outputLocation: outputWasSentinel,
            filenamePattern: patternWasSentinel,
            collisionPolicy: preset.overwritePolicy == .ask,
            creationDate: false,
            modificationDate: false,
            locationData: true
        )
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
    public var audioBitDepth: AudioBitDepth?
    public var hardwareAcceleration: HardwareAccelerationPolicy
    public var preserveMetadata: Bool
    public var preserveCreationDate: Bool
    public var outputDirectoryPolicy: OutputDirectoryPolicy
    public var filenamePattern: String
    public var overwritePolicy: OverwritePolicy
    public var extraBackendOptions: [String: String]
    public var processingOptions: ConversionProcessingOptions?
    public var opaqueFields: PresetOpaqueFields?
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var sortOrder: Int
    /// Factory revision a stored built-in was last upgraded to. `nil` for
    /// custom presets and for built-ins saved before revisions existed.
    public var factoryRevision: Int?
    /// Which settings come from General settings. `nil` only for presets
    /// saved before inheritance was explicit; see `resolvedInheritance`.
    public var inheritance: PresetInheritance?
    /// Used when `modificationDate` is not inherited. `nil` means false.
    public var preserveModificationDate: Bool?
    /// Used when `locationData` is not inherited. `nil` means true (remove).
    public var removeLocationData: Bool?
    /// Appended to the name when the output keeps the source's file type and
    /// the pattern is just `{name}` (for example "-web" for "photo-web.jpg").
    public var sameFormatSuffix: String?
    /// Container-change presets (MKV → MP4) copy compatible streams instead
    /// of re-encoding them.
    public var allowsStreamCopy: Bool?

    public var resolvedInheritance: PresetInheritance {
        inheritance ?? .legacy(for: self)
    }

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
        audioBitDepth: AudioBitDepth? = nil,
        hardwareAcceleration: HardwareAccelerationPolicy = .auto,
        preserveMetadata: Bool = true,
        preserveCreationDate: Bool = true,
        outputDirectoryPolicy: OutputDirectoryPolicy = .sameAsSource,
        filenamePattern: String = "{name}",
        overwritePolicy: OverwritePolicy = .appendNumber,
        extraBackendOptions: [String: String] = [:],
        processingOptions: ConversionProcessingOptions? = nil,
        opaqueFields: PresetOpaqueFields? = nil,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        inheritance: PresetInheritance? = nil,
        preserveModificationDate: Bool? = nil,
        removeLocationData: Bool? = nil,
        sameFormatSuffix: String? = nil,
        allowsStreamCopy: Bool? = nil
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
        self.audioBitDepth = audioBitDepth
        self.hardwareAcceleration = hardwareAcceleration
        self.preserveMetadata = preserveMetadata
        self.preserveCreationDate = preserveCreationDate
        self.outputDirectoryPolicy = outputDirectoryPolicy
        self.filenamePattern = filenamePattern
        self.overwritePolicy = overwritePolicy
        self.extraBackendOptions = extraBackendOptions
        self.processingOptions = processingOptions?.isEmpty == true ? nil : processingOptions
        self.opaqueFields = opaqueFields
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.inheritance = inheritance
        self.preserveModificationDate = preserveModificationDate
        self.removeLocationData = removeLocationData
        self.sameFormatSuffix = sameFormatSuffix
        self.allowsStreamCopy = allowsStreamCopy
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

    public var videoTargetFileSizeBytes: Int? {
        get { processingOptions?.videoTargetFileSizeBytes }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.videoTargetFileSizeBytes = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var trimStartSeconds: Double? {
        get { processingOptions?.trimStartSeconds }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.trimStartSeconds = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var trimEndSeconds: Double? {
        get { processingOptions?.trimEndSeconds }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.trimEndSeconds = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var frameTimeSeconds: Double? {
        get { processingOptions?.frameTimeSeconds }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.frameTimeSeconds = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    public var normalizeLoudness: Bool {
        get { processingOptions?.normalizeLoudness ?? false }
        set {
            var options = processingOptions ?? ConversionProcessingOptions()
            options.normalizeLoudness = newValue
            processingOptions = options.isEmpty ? nil : options
        }
    }

    /// True when the preset keeps only part of the file.
    public var isTrimmed: Bool {
        trimStartSeconds != nil || trimEndSeconds != nil
    }

    /// Video to still image: saves one frame instead of converting.
    public var isVideoFrameExport: Bool {
        category == .video
            && FormatRegistry.shared.format(forID: destinationFormat)?.category == .image
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
