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
           !(10...86_400).contains(seconds) {
            errors.append("Audio split length must be between 10 seconds and 24 hours.")
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

        if preset.backend == .calibre,
           !(preset.sourceFormats.map({ $0.lowercased() }).contains("epub") && destinationKey == "pdf") {
            errors.append("Calibre is currently used for EPUB to PDF conversion.")
        }

        return errors
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
              !detection.isDirectory,
              !(detection.isReadable && detection.isZeroByte) else {
            return false
        }
        return isPresetCompatible(preset, forFormat: format)
    }

    public static func isPresetCompatible(_ preset: ConversionPreset, forFormat format: FormatDefinition) -> Bool {
        guard preset.isEnabled else { return false }

        // Source compatibility check
        let lowerSources = Set(preset.sourceFormats.map { $0.lowercased() })
        let matchesCategory = lowerSources.contains(format.category.rawValue.lowercased())
        let matchesFormatID = lowerSources.contains(format.id.lowercased())
        let matchesPrimaryExt = lowerSources.contains(format.primaryExtension.lowercased())
        let matchesAny = lowerSources.contains("*")

        guard matchesCategory || matchesFormatID || matchesPrimaryExt || matchesAny else {
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

        // Detect format for each URL
        var sourceFormats: [FormatDefinition] = []
        for url in urls {
            let detection = FormatDetector.detect(url: url)
            guard let format = detection.format,
                  !detection.isDirectory,
                  !(detection.isReadable && detection.isZeroByte) else {
                // If any item is unsupported or a folder, no presets match
                return []
            }
            sourceFormats.append(format)
        }

        // Filter presets that are valid for ALL selected formats (Intersection)
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
}
