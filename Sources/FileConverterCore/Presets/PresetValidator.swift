import Foundation

public enum PresetValidator {
    public static func validationErrors(for preset: ConversionPreset) -> [String] {
        var errors: [String] = []

        if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Enter a full preset name.")
        }
        if preset.menuName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Enter a short Finder menu title.")
        }

        let destinationKey = preset.destinationFormat
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if destinationKey.isEmpty {
            errors.append("Choose an output extension.")
        } else if let format = FormatRegistry.shared.format(forID: destinationKey)
                    ?? FormatRegistry.shared.format(forExtension: destinationKey) {
            if !format.supportedOutput {
                errors.append(".\(destinationKey) is input-only. Choose a writable format.")
            }
        } else {
            errors.append("Unknown output format .\(destinationKey).")
        }

        if preset.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Filename pattern cannot be empty. Use {name} for the source filename.")
        }

        if preset.sourceFormats.isEmpty {
            errors.append("Choose which source files can show this preset.")
        } else {
            let knownCategories = Set(FormatCategory.allCases.map { $0.rawValue.lowercased() })
            let knownAliases = Set(FormatRegistry.shared.allFormats().flatMap { format in
                [format.id.lowercased(), format.primaryExtension.lowercased()] + format.extensions.map { $0.lowercased() }
            })
            let invalidSources = preset.sourceFormats.filter { source in
                let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized != "*" && !knownCategories.contains(normalized) && !knownAliases.contains(normalized)
            }
            if !invalidSources.isEmpty {
                errors.append("Unknown source format: \(invalidSources.sorted().joined(separator: ", ")).")
            }
        }

        if case .sourceSubfolder(let name) = preset.outputDirectoryPolicy {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned.contains("/") || cleaned.contains("\\") {
                errors.append("Subfolder must be a single folder name without slashes.")
            }
        }

        if preset.splitPDFIntoPages, !canSplitPDFPages(preset) {
            errors.append("Split PDF pages requires PDF input and PDF output.")
        }

        if let seconds = preset.audioSplitDurationSeconds,
           seconds < 1 {
            errors.append("Audio split length must be at least 1 second.")
        }
        if let bytes = preset.audioTargetFileSizeBytes,
           bytes < 256 * 1_024 {
            errors.append("Audio target size must be at least 256 KB.")
        }
        if preset.audioTargetFileSizeBytes != nil {
            let compressedAudioFormats: Set<String> = ["aac", "m4a", "mp3", "opus", "ogg"]
            if !compressedAudioFormats.contains(destinationKey) {
                errors.append("Audio size targets require a compressed audio output such as AAC, M4A, MP3, Opus, or Ogg.")
            }
            if compressedAudioFormats.contains(destinationKey) {
                switch preset.audioCodec {
                case .aac where !["aac", "m4a"].contains(destinationKey):
                    errors.append("AAC size targets must use AAC or M4A output.")
                case .mp3 where destinationKey != "mp3":
                    errors.append("MP3 size targets must use MP3 output.")
                case .opus where !["opus", "ogg"].contains(destinationKey):
                    errors.append("Opus size targets must use Opus or Ogg output.")
                default:
                    break
                }
            }
        }
        if preset.audioSplitDurationSeconds != nil, preset.audioTargetFileSizeBytes != nil {
            errors.append("Choose either split audio or a target file size, not both.")
        }
        if preset.requiresExternalAudioProcessing {
            let sources = Set(preset.sourceFormats.map { $0.lowercased() })
            let destination = FormatRegistry.shared.format(forID: destinationKey)
                ?? FormatRegistry.shared.format(forExtension: destinationKey)
            if !sources.contains("audio") || destination?.category != .audio {
                errors.append("Audio tools require audio input and audio output.")
            }
            if preset.audioTargetFileSizeBytes != nil,
               ![.auto, .aac, .mp3, .opus].contains(preset.audioCodec) {
                errors.append("A target audio size requires AAC, MP3, Opus, or Auto audio encoding.")
            }
        }

        // Codec and container compatibility
        if preset.category == .audio || ["mp3", "wav", "flac", "aac", "opus", "ogg", "aiff", "aif", "m4a"].contains(destinationKey) {
            if !isCodecCompatible(audioCodec: preset.audioCodec, destinationFormat: destinationKey) {
                errors.append("Destination format .\(destinationKey) cannot contain audio codec \(preset.audioCodec.displayName).")
            }
        }

        // Lossless quality cannot be selected with lossy codecs (Requirement 5)
        if preset.quality == .lossless {
            if isLossyAudioCodec(preset.audioCodec) || (preset.category == .audio && isLossyContainer(destinationKey) && preset.audioCodec != .flac && preset.audioCodec != .alac && preset.audioCodec != .wav && preset.audioCodec != .aiff) {
                errors.append("Lossless quality cannot be used with lossy audio codec \(preset.audioCodec.displayName).")
            }
        }

        // Direct Stream Copy checks (Requirement 3)
        if preset.audioCodec == .copy {
            if preset.audioTargetFileSizeBytes != nil {
                errors.append("Direct Stream Copy cannot target a specific file size because it does not re-encode audio.")
            }
        }

        // Sample rate validation
        if let rate = preset.audioSampleRate {
            if rate <= 0 || rate > 384_000 {
                errors.append("Audio sample rate must be a positive number up to 384 kHz.")
            }
        }

        // Channel count validation
        if let channels = preset.audioChannels {
            if !(1...8).contains(channels) {
                errors.append("Audio channel count must be between 1 and 8.")
            }
        }

        // Video codec and container compatibility
        if preset.category == .video || ["mp4", "mov", "mkv", "webm", "m4v"].contains(destinationKey) {
            if !isCodecCompatible(videoCodec: preset.videoCodec, destinationFormat: destinationKey) {
                errors.append("Destination format .\(destinationKey) cannot contain video codec \(preset.videoCodec.displayName).")
            }
        }

        if preset.backend == .calibre,
           !(preset.sourceFormats.map({ $0.lowercased() }).contains("epub") && destinationKey == "pdf") {
            errors.append("Calibre conversion is currently supported for EPUB to PDF.")
        }

        // Control characters guard
        if containsControlCharacters(preset.name) || preset.name.contains("\0") {
            errors.append(preset.name.contains("\0") ? "Preset names cannot contain null bytes." : "Preset names cannot contain line breaks.")
        }
        if containsControlCharacters(preset.menuName) || preset.menuName.contains("\0") {
            errors.append(preset.menuName.contains("\0") ? "Preset names cannot contain null bytes." : "Preset names cannot contain line breaks.")
        }
        if containsControlCharacters(preset.filenamePattern) {
            errors.append("Filename pattern contains prohibited control characters.")
        }
        if containsControlCharacters(preset.destinationFormat) {
            errors.append("Destination format contains prohibited control characters.")
        }
        for source in preset.sourceFormats {
            if containsControlCharacters(source) {
                errors.append("Source format '\(source)' contains prohibited control characters.")
            }
        }
        switch preset.outputDirectoryPolicy {
        case .sourceSubfolder(let name):
            if containsControlCharacters(name) {
                errors.append("Subfolder name contains prohibited control characters.")
            }
        case .customFolder(_, let path):
            if containsControlCharacters(path) {
                errors.append("Custom folder path contains prohibited control characters.")
            }
        default:
            break
        }
        if let opts = preset.processingOptions {
            if let ranges = opts.pdfPageRanges, containsControlCharacters(ranges) {
                errors.append("PDF page ranges contain prohibited control characters.")
            }
            if let pattern = opts.pdfNamingPattern, containsControlCharacters(pattern) {
                errors.append("PDF naming pattern contains prohibited control characters.")
            }
            if let subfolder = opts.pdfOutputSubfolder, containsControlCharacters(subfolder) {
                errors.append("PDF output subfolder contains prohibited control characters.")
            }
            if let profile = opts.pdfCompressionProfile, containsControlCharacters(profile) {
                errors.append("PDF compression profile contains prohibited control characters.")
            }
            if let colorMode = opts.pdfColorMode, containsControlCharacters(colorMode) {
                errors.append("PDF color mode contains prohibited control characters.")
            }
        }

        // Container format validation
        if let container = preset.container?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !container.isEmpty {
            if containsControlCharacters(container) {
                errors.append("Output container contains prohibited control characters.")
            }
            let containerKey = container.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let containerFormat = FormatRegistry.shared.format(forID: containerKey)
                ?? FormatRegistry.shared.format(forExtension: containerKey) {
                if !containerFormat.supportedOutput {
                    errors.append("Output container .\(containerKey) is input-only and does not support output.")
                }
                if let destFormat = FormatRegistry.shared.format(forID: destinationKey)
                    ?? FormatRegistry.shared.format(forExtension: destinationKey) {
                    if destFormat.category != containerFormat.category &&
                       !(destFormat.category == .audio && containerFormat.category == .video) {
                        errors.append("Output container .\(containerKey) (\(containerFormat.category.displayName)) is incompatible with destination .\(destinationKey) (\(destFormat.category.displayName)).")
                    }
                }
            } else {
                errors.append("Unknown output container .\(container).")
            }
        }

        // PDF compatibility level validation
        if let compat = preset.processingOptions?.pdfCompatibilityLevel {
            let allowedLevels: Set<String> = ["1.4", "1.5", "1.6", "1.7"]
            if !allowedLevels.contains(compat) {
                errors.append("Unsupported PDF compatibility level '\(compat)'. Must be 1.4, 1.5, 1.6, or 1.7.")
            }
        }

        // Extra backend options validation
        if preset.backend != .ffmpeg && preset.backend != .auto && !preset.extraBackendOptions.isEmpty {
            errors.append("Backend '\(preset.backend.displayName)' does not support extra backend options.")
        }

        for (key, value) in preset.extraBackendOptions {
            if key == "__unrecognizedJSON" {
                errors.append("Unrecognized preset metadata cannot be used as a backend option.")
                continue
            }
            if !isAllowlistedFFmpegOption(key) {
                errors.append("Unsupported backend option '\(key)'. Only allowlisted backend options may be executed.")
            }
            if containsControlCharacters(key) || containsControlCharacters(value) ||
               key.contains("\n") || key.contains("\r") || key.contains("\0") ||
               value.contains("\n") || value.contains("\r") || value.contains("\0") {
                errors.append("Backend option '\(key)' contains prohibited control characters.")
            }
            let dangerousChars = CharacterSet(charactersIn: ";|&`$<>")
            if key.rangeOfCharacter(from: dangerousChars) != nil || value.rangeOfCharacter(from: dangerousChars) != nil {
                errors.append("Backend option '\(key)' contains prohibited shell metacharacters.")
            }
            if key.count > 32 {
                errors.append("Backend option key '\(key)' exceeds maximum allowed length.")
            }
            if value.count > 128 {
                errors.append("Backend option '\(key)' value exceeds maximum allowed length.")
            }
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.hasPrefix("--") {
                errors.append("Backend option '\(key)' contains a prohibited prefix ('--').")
            }
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue.hasPrefix("-") {
                errors.append("Backend option '\(key)' value cannot start with a prohibited prefix ('-').")
            }

            let optionName = trimmedKey.hasPrefix("-") ? String(trimmedKey.dropFirst()) : trimmedKey

            switch optionName {
            case "preset":
                let allowedPresets: Set<String> = [
                    "ultrafast", "superfast", "veryfast", "faster", "fast",
                    "medium", "slow", "slower", "veryslow", "placebo"
                ]
                if !allowedPresets.contains(trimmedValue.lowercased()) {
                    errors.append("Invalid FFmpeg preset value '\(value)'.")
                }
            case "tune":
                let allowedTunes: Set<String> = [
                    "film", "animation", "grain", "stillimage", "fastdecode", "zerolatency"
                ]
                if !allowedTunes.contains(trimmedValue.lowercased()) {
                    errors.append("Invalid FFmpeg tune value '\(value)'.")
                }
            case "profile:v":
                let allowedProfiles: Set<String> = [
                    "baseline", "main", "high", "high10", "high422", "high444p"
                ]
                if !allowedProfiles.contains(trimmedValue.lowercased()) {
                    errors.append("Invalid video profile '\(value)'.")
                }
            case "pix_fmt":
                let allowedPixFmts: Set<String> = [
                    "yuv420p", "yuvj420p", "yuv422p", "yuv444p", "nv12", "nv21",
                    "rgb24", "rgba", "bgr24", "bgra", "gray", "monow", "monob"
                ]
                if !allowedPixFmts.contains(trimmedValue.lowercased()) {
                    errors.append("Invalid pixel format '\(value)'.")
                }
            case "movflags":
                let allowedMovFlags: Set<String> = [
                    "faststart", "+faststart", "empty_moov", "+empty_moov"
                ]
                if !allowedMovFlags.contains(trimmedValue.lowercased()) {
                    errors.append("Invalid movflags value '\(value)'.")
                }
                if !["mp4", "mov", "m4v", "qt"].contains(destinationKey) {
                    errors.append("Option 'movflags' is only supported for MP4 or MOV output containers.")
                }
            case "crf":
                if let intVal = Int(trimmedValue) {
                    if !(0...63).contains(intVal) {
                        errors.append("CRF must be an integer between 0 and 63.")
                    }
                } else {
                    errors.append("CRF must be a numeric integer value.")
                }
            case "threads":
                if let intVal = Int(trimmedValue) {
                    if !(0...64).contains(intVal) {
                        errors.append("Threads must be an integer between 0 and 64.")
                    }
                } else {
                    errors.append("Threads must be a numeric integer value.")
                }
            case "fpsmax":
                if let dVal = Double(trimmedValue) {
                    if dVal < 1 || dVal > 240 {
                        errors.append("fpsmax must be a number between 1 and 240.")
                    }
                } else {
                    errors.append("fpsmax must be a numeric value.")
                }
            case "ar":
                if let intVal = Int(trimmedValue) {
                    if !(8000...384000).contains(intVal) {
                        errors.append("Audio sample rate (ar) must be between 8000 and 384000 Hz.")
                    }
                } else {
                    errors.append("Audio sample rate (ar) must be an integer.")
                }
            case "ac":
                if let intVal = Int(trimmedValue) {
                    if !(1...8).contains(intVal) {
                        errors.append("Audio channels (ac) must be between 1 and 8.")
                    }
                } else {
                    errors.append("Audio channels (ac) must be an integer between 1 and 8.")
                }
            case "qscale:v", "q:v", "qscale:a", "q:a":
                if let intVal = Int(trimmedValue) {
                    if !(0...31).contains(intVal) {
                        errors.append("Quality scale '\(key)' must be an integer between 0 and 31.")
                    }
                } else {
                    errors.append("Quality scale '\(key)' must be an integer.")
                }
            case "vn", "an", "sn":
                let lower = trimmedValue.lowercased()
                if !lower.isEmpty && lower != "true" && lower != "false" && lower != "1" && lower != "0" {
                    errors.append("Boolean option '\(key)' must be true, false, 1, 0, or empty.")
                }
            default:
                break
            }

            let videoOnlyOptions: Set<String> = ["b:v", "crf", "fpsmax", "profile:v", "qscale:v", "q:v", "vn", "pix_fmt"]
            if videoOnlyOptions.contains(optionName) {
                if preset.category == .audio || ["mp3", "wav", "flac", "aac", "opus", "ogg", "aiff", "aif", "m4a"].contains(destinationKey) {
                    errors.append("Video option '\(key)' cannot be used with an audio preset.")
                }
            }
        }

        return errors
    }

    public static func containsControlCharacters(_ string: String) -> Bool {
        return string.unicodeScalars.contains { scalar in
            (scalar.value <= 0x1F) || (scalar.value >= 0x7F && scalar.value <= 0x9F)
        }
    }

    public static let allowlistedFFmpegOptionKeys: Set<String> = [
        "preset", "-preset",
        "tune", "-tune",
        "crf", "-crf",
        "profile:v", "-profile:v",
        "level", "-level",
        "pix_fmt", "-pix_fmt",
        "movflags", "-movflags",
        "threads", "-threads",
        "qscale:v", "-qscale:v",
        "q:v", "-q:v",
        "qscale:a", "-qscale:a",
        "q:a", "-q:a",
        "b:v", "-b:v",
        "b:a", "-b:a",
        "ar", "-ar",
        "ac", "-ac",
        "vn", "-vn",
        "an", "-an",
        "sn", "-sn",
        "fpsmax", "-fpsmax"
    ]

    public static func isAllowlistedFFmpegOption(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("--") else { return false }
        let optionName = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        return allowlistedFFmpegOptionKeys.contains(optionName) || allowlistedFFmpegOptionKeys.contains("-\(optionName)")
    }

    public static func validate(_ preset: ConversionPreset) throws {
        if let firstError = validationErrors(for: preset).first {
            throw ConversionError.invalidPreset(reason: firstError)
        }
    }

    /// Whether this preset is already scoped to a PDF-preserving conversion.
    /// The editor uses this to avoid presenting page splitting as an option for
    /// unrelated workflows such as EPUB to PDF.
    public static func canSplitPDFPages(_ preset: ConversionPreset) -> Bool {
        let sources = Set(preset.sourceFormats.map { $0.lowercased() })
        return sources.contains("pdf") && preset.destinationFormat.lowercased() == "pdf"
    }

    public static func isPresetCompatible(_ preset: ConversionPreset, forURL url: URL) -> Bool {
        let detection = FormatDetector.detect(url: url)
        guard let format = detection.format,
              detection.exists,
              detection.isReadable,
              !detection.isDirectory,
              !detection.isZeroByte else {
            return false
        }
        return isPresetCompatible(preset, forFormat: format)
    }

    public static func isPresetCompatible(_ preset: ConversionPreset, forFormat format: FormatDefinition) -> Bool {
        guard preset.isEnabled else { return false }

        // Source compatibility check — use the canonical alias vocabulary so
        // `tif`/`tiff`, `jpe`/`jpeg`, `m4v`/`mp4`, `htm`/`html`, etc. agree
        // between validation, queue admission, and Finder snapshots.
        let registry = FormatRegistry.shared
        guard preset.sourceFormats.contains(where: { registry.matchesSourceSpecifier($0, format: format) }) else {
            return false
        }

        return true
    }

    public static func compatiblePresets(
        forURLs urls: [URL],
        from presets: [ConversionPreset] = PresetStore.shared.enabledPresets,
        resolver: BackendResolver = .shared
    ) -> [ConversionPreset] {
        guard !urls.isEmpty else { return [] }

        // Every selected source must be usable. Returning presets for only a
        // valid subset would let a later queue admission fail with a less
        // useful error for the omitted files.
        var sourceFormats: [FormatDefinition] = []
        for url in urls {
            let detection = FormatDetector.detect(url: url)
            guard let format = detection.format,
                  detection.exists,
                  detection.isReadable,
                  !detection.isDirectory,
                  !detection.isZeroByte else {
                return []
            }
            sourceFormats.append(format)
        }

        guard sourceFormats.count == urls.count else { return [] }

        // Filter presets that are valid for ALL selected valid formats (Intersection)
        let matchingPresets = presets.filter { preset in
            sourceFormats.allSatisfy { format in
                isPresetCompatible(preset, forFormat: format)
                    && resolver.canResolve(preset: preset, sourceFormat: format)
            }
        }

        return matchingPresets.sorted { $0.sortOrder < $1.sortOrder }
    }

    public static func groupPresetsByCategory(_ presets: [ConversionPreset]) -> [FormatCategory: [ConversionPreset]] {
        var grouped: [FormatCategory: [ConversionPreset]] = [:]
        for preset in presets {
            grouped[preset.category, default: []].append(preset)
        }
        for (cat, list) in grouped {
            grouped[cat] = list.sorted { $0.sortOrder < $1.sortOrder }
        }
        return grouped
    }

    /// Shared admission report: every source's existence/access, directory/
    /// zero-byte, detected format, preset compatibility, backend availability,
    /// and rejection reason. Finder requests fail safely with an explanation;
    /// the main app may offer partial selection with explicit confirmation.
    public struct AdmissionSourceReport: Sendable, Equatable {
        public let url: URL
        public let exists: Bool
        public let isReadable: Bool
        public let isDirectory: Bool
        public let isZeroByte: Bool
        public let detectedFormatID: String?
        public let isCompatible: Bool
        public let backendAvailable: Bool
        public let rejectionReason: String?

        public init(
            url: URL,
            exists: Bool,
            isReadable: Bool,
            isDirectory: Bool,
            isZeroByte: Bool,
            detectedFormatID: String?,
            isCompatible: Bool,
            backendAvailable: Bool,
            rejectionReason: String?
        ) {
            self.url = url
            self.exists = exists
            self.isReadable = isReadable
            self.isDirectory = isDirectory
            self.isZeroByte = isZeroByte
            self.detectedFormatID = detectedFormatID
            self.isCompatible = isCompatible
            self.backendAvailable = backendAvailable
            self.rejectionReason = rejectionReason
        }
    }

    public struct AdmissionReport: Sendable {
        public let preset: ConversionPreset
        public let sources: [AdmissionSourceReport]
        public var rejectedSources: [AdmissionSourceReport] {
            sources.filter { $0.rejectionReason != nil }
        }
        public var isFullyAdmissible: Bool { rejectedSources.isEmpty }
    }

    public static func admissionReport(
        forURLs urls: [URL],
        preset: ConversionPreset,
        resolver: BackendResolver = .shared
    ) -> AdmissionReport {
        let sources = urls.map { url -> AdmissionSourceReport in
            let detection = FormatDetector.detect(url: url)
            let exists = detection.exists
            let isReadable = detection.isReadable
            if !exists {
                return AdmissionSourceReport(
                    url: url, exists: false, isReadable: false, isDirectory: false, isZeroByte: false,
                    detectedFormatID: detection.format?.id, isCompatible: false, backendAvailable: false,
                    rejectionReason: "\(url.lastPathComponent) was not found."
                )
            }
            if detection.isDirectory {
                let reason = detection.isPackage
                    ? "\(url.lastPathComponent) is a package bundle and cannot be converted."
                    : "\(url.lastPathComponent) is a folder and cannot be converted."
                return AdmissionSourceReport(
                    url: url, exists: true, isReadable: true, isDirectory: true, isZeroByte: false,
                    detectedFormatID: nil, isCompatible: false, backendAvailable: false,
                    rejectionReason: reason
                )
            }
            if !isReadable {
                return AdmissionSourceReport(
                    url: url, exists: true, isReadable: false, isDirectory: false, isZeroByte: false,
                    detectedFormatID: detection.format?.id, isCompatible: false, backendAvailable: false,
                    rejectionReason: "\(url.lastPathComponent) exists but is not readable."
                )
            }
            if detection.isZeroByte {
                return AdmissionSourceReport(
                    url: url, exists: true, isReadable: true, isDirectory: false, isZeroByte: true,
                    detectedFormatID: detection.format?.id, isCompatible: false, backendAvailable: false,
                    rejectionReason: "\(url.lastPathComponent) is empty (0 bytes)."
                )
            }
            guard let format = detection.format else {
                return AdmissionSourceReport(
                    url: url, exists: true, isReadable: true, isDirectory: false, isZeroByte: false,
                    detectedFormatID: nil, isCompatible: false, backendAvailable: false,
                    rejectionReason: "\(url.lastPathComponent) has an unsupported format."
                )
            }
            guard isPresetCompatible(preset, forFormat: format) else {
                return AdmissionSourceReport(
                    url: url, exists: true, isReadable: true, isDirectory: false, isZeroByte: false,
                    detectedFormatID: format.id, isCompatible: false, backendAvailable: false,
                    rejectionReason: "\(url.lastPathComponent) (\(format.id.uppercased())) is not supported by \(preset.name)."
                )
            }
            let evaluation = resolver.evaluate(preset: preset, sourceFormat: format)
            guard evaluation.isUsable else {
                return AdmissionSourceReport(
                    url: url, exists: true, isReadable: true, isDirectory: false, isZeroByte: false,
                    detectedFormatID: format.id, isCompatible: true, backendAvailable: false,
                    rejectionReason: "\(url.lastPathComponent) requires an unavailable backend (\(evaluation.backendType?.displayName ?? "unknown"))."
                )
            }
            return AdmissionSourceReport(
                url: url, exists: true, isReadable: true, isDirectory: false, isZeroByte: false,
                detectedFormatID: format.id, isCompatible: true, backendAvailable: true,
                rejectionReason: nil
            )
        }
        return AdmissionReport(preset: preset, sources: sources)
    }

    public static func isLossyAudioCodec(_ codec: AudioCodecType) -> Bool {
        codec == .aac || codec == .mp3 || codec == .opus
    }

    public static func isLossyContainer(_ container: String) -> Bool {
        let clean = container.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return ["mp3", "aac", "opus", "ogg"].contains(clean)
    }

    public static func isCodecCompatible(audioCodec: AudioCodecType, destinationFormat: String) -> Bool {
        let dest = destinationFormat.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        switch dest {
        case "mp3":
            return audioCodec == .mp3 || audioCodec == .auto || audioCodec == .copy
        case "wav":
            return audioCodec == .wav || audioCodec == .auto || audioCodec == .copy
        case "aiff", "aif":
            return audioCodec == .aiff || audioCodec == .auto || audioCodec == .copy
        case "flac":
            return audioCodec == .flac || audioCodec == .auto || audioCodec == .copy
        case "aac":
            return audioCodec == .aac || audioCodec == .auto || audioCodec == .copy
        case "m4a":
            return audioCodec == .aac || audioCodec == .alac || audioCodec == .auto || audioCodec == .copy
        case "opus":
            return audioCodec == .opus || audioCodec == .auto || audioCodec == .copy
        case "ogg":
            return audioCodec == .opus || audioCodec == .auto || audioCodec == .copy
        case "webm":
            return audioCodec == .opus || audioCodec == .auto || audioCodec == .copy || audioCodec == .none
        default:
            return true
        }
    }

    public static func compatibleAudioCodecs(forDestinationFormat format: String) -> [AudioCodecType] {
        AudioCodecType.allCases.filter { isCodecCompatible(audioCodec: $0, destinationFormat: format) }
    }

    public static func compatibleContainers(forAudioCodec codec: AudioCodecType) -> [String] {
        switch codec {
        case .mp3: return ["mp3", "m4a", "mp4", "mkv"]
        case .aac: return ["m4a", "aac", "mp4", "mov", "mkv"]
        case .opus: return ["opus", "ogg", "webm", "mkv"]
        case .flac: return ["flac", "mkv"]
        case .alac: return ["m4a", "mov", "mp4", "mkv"]
        case .wav: return ["wav"]
        case .aiff: return ["aiff", "aif"]
        case .copy, .auto, .none:
            return ["mp3", "m4a", "wav", "flac", "aac", "opus", "ogg", "aiff", "mp4", "mov", "webm", "mkv"]
        }
    }

    public static func isCodecCompatible(videoCodec: VideoCodecType, destinationFormat: String) -> Bool {
        let dest = destinationFormat.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        switch videoCodec {
        case .auto, .copy, .none:
            return true
        case .h264, .hevc:
            return ["mp4", "mov", "mkv", "m4v"].contains(dest)
        case .proRes:
            return ["mov", "mkv"].contains(dest)
        case .vp9:
            return ["webm", "mkv"].contains(dest)
        case .av1:
            return ["mp4", "webm", "mkv"].contains(dest)
        }
    }

    public static func compatibleVideoCodecs(forDestinationFormat format: String) -> [VideoCodecType] {
        VideoCodecType.allCases.filter { isCodecCompatible(videoCodec: $0, destinationFormat: format) }
    }
}
