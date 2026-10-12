import Foundation

/// Which presets are worth offering for a file type, shared by the Finder
/// menu snapshot and the in-app picker so both show the same list.
public enum PresetVisibility {
    /// True when `preset` names `format` explicitly (by id or extension)
    /// rather than through a category such as "audio".
    public static func targetsExplicitly(_ preset: ConversionPreset, format: FormatDefinition) -> Bool {
        let registry = FormatRegistry.shared
        return preset.sourceFormats.contains { specifier in
            let normalized = specifier.lowercased()
            guard normalized != "*", FormatCategory(rawValue: normalized) == nil else { return false }
            return registry.matchesSourceSpecifier(specifier, format: format)
        }
    }

    /// Re-encoding a file into its own format at default settings changes
    /// nothing useful (a "JPEG" preset for a JPEG), so it is not offered.
    /// Presets that resize, compress, split, or name the result differently
    /// still are.
    public static func isIdentityTransform(_ preset: ConversionPreset, for format: FormatDefinition) -> Bool {
        guard let destination = FormatRegistry.shared.format(forID: preset.destinationFormat),
              destination.id == format.id,
              !containerFormatIDs.contains(format.id),
              format.category != .video else { return false }
        let keepsQuality: Bool
        switch preset.quality {
        case .high, .veryHigh, .lossless: keepsQuality = true
        case .low, .medium, .custom: keepsQuality = false
        }
        return preset.resolution == .original
            && preset.framerate == nil
            && preset.processingOptions == nil
            && preset.sameFormatSuffix == nil
            && keepsQuality
            && !preset.isInteractiveWorkflow
    }

    /// Containers that can hold different codecs; converting into the same
    /// container can still change the encoding (HEVC .mp4 → H.264 .mp4).
    static let containerFormatIDs: Set<String> = ["m4a", "qta", "ogg", "mka", "webm", "mkv", "mov", "mp4", "avi"]

    /// Same output from the same input, regardless of which engine runs it.
    public static func isEquivalent(_ lhs: ConversionPreset, _ rhs: ConversionPreset) -> Bool {
        lhs.destinationFormat == rhs.destinationFormat
            && lhs.videoCodec == rhs.videoCodec
            && lhs.audioCodec == rhs.audioCodec
            && lhs.quality == rhs.quality
            && lhs.videoBitrateKbps == rhs.videoBitrateKbps
            && lhs.audioBitrateKbps == rhs.audioBitrateKbps
            && lhs.audioSampleRate == rhs.audioSampleRate
            && lhs.audioChannels == rhs.audioChannels
            && lhs.resolution == rhs.resolution
            && lhs.framerate == rhs.framerate
            && lhs.processingOptions == rhs.processingOptions
            && (lhs.allowsStreamCopy ?? false) == (rhs.allowsStreamCopy ?? false)
    }

    /// Presets from `candidates` (already known to accept `format`) that are
    /// worth showing for it: identity conversions are dropped, and a generic
    /// preset is dropped when a preset written for this exact format does
    /// the same thing ("WAV → MP3" replaces "MP3 – 320 kbps" for WAV files).
    public static func visible(_ candidates: [ConversionPreset], for format: FormatDefinition) -> [ConversionPreset] {
        let useful = candidates.filter { !isIdentityTransform($0, for: format) }
        let specific = useful.filter { targetsExplicitly($0, format: format) }
        return useful.filter { preset in
            if targetsExplicitly(preset, format: format) { return true }
            return !specific.contains { isEquivalent($0, preset) }
        }
    }
}
