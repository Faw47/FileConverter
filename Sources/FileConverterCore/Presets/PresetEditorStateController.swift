import Foundation

/// Encapsulates format-aware state transitions and validation rules for the preset editor.
public struct PresetEditorStateController: Sendable {
    public init() {}

    public func isDirectStreamCopy(_ preset: ConversionPreset) -> Bool {
        preset.audioCodec == .copy
    }

    public func isAudioDisabled(_ preset: ConversionPreset) -> Bool {
        preset.audioCodec == .none
    }

    public func isPCMFormat(_ preset: ConversionPreset) -> Bool {
        if preset.audioCodec == .wav || preset.audioCodec == .aiff { return true }
        let dest = preset.destinationFormat.lowercased()
        return (dest == "wav" || dest == "aiff" || dest == "aif") && preset.audioCodec != .copy
    }

    public func isFLACFormat(_ preset: ConversionPreset) -> Bool {
        preset.audioCodec == .flac || preset.destinationFormat.lowercased() == "flac"
    }

    public func shouldShowAudioBitrate(for preset: ConversionPreset) -> Bool {
        if isDirectStreamCopy(preset) || isAudioDisabled(preset) { return false }
        if preset.audioCodec == .wav || preset.audioCodec == .aiff || preset.audioCodec == .flac || preset.audioCodec == .alac { return false }
        let dest = preset.destinationFormat.lowercased()
        if dest == "wav" || dest == "aiff" || dest == "aif" || dest == "flac" { return false }
        return true
    }

    public func shouldShowBitDepth(for preset: ConversionPreset) -> Bool {
        isPCMFormat(preset)
    }

    public func isSampleRateEnabled(for preset: ConversionPreset) -> Bool {
        !isDirectStreamCopy(preset) && !isAudioDisabled(preset)
    }

    public func isChannelsEnabled(for preset: ConversionPreset) -> Bool {
        !isDirectStreamCopy(preset) && !isAudioDisabled(preset)
    }

    public func isQualityEnabled(for preset: ConversionPreset) -> Bool {
        !isDirectStreamCopy(preset)
    }

    public func isHardwareAccelerationEnabled(for preset: ConversionPreset) -> Bool {
        !isDirectStreamCopy(preset) && preset.category != .audio
    }

    public func isTargetFileSizeEnabled(for preset: ConversionPreset) -> Bool {
        !isDirectStreamCopy(preset)
    }

    public func availableQualities(for preset: ConversionPreset) -> [QualitySetting] {
        if isFLACFormat(preset) {
            // All FLAC compression levels are 100% bit-for-bit lossless.
            // Expose compression-oriented levels without presenting "Lossless" as one level.
            return [.low, .medium, .high, .veryHigh]
        }
        if PresetValidator.isLossyAudioCodec(preset.audioCodec) ||
            (preset.category == .audio && PresetValidator.isLossyContainer(preset.destinationFormat)) {
            return QualitySetting.allCases.filter { $0 != .lossless }
        }
        return QualitySetting.allCases
    }

    public func qualityDisplayName(_ quality: QualitySetting, for preset: ConversionPreset) -> String {
        if isFLACFormat(preset) {
            switch quality {
            case .low: return "Fast (level 2)"
            case .medium: return "Standard (level 5)"
            case .high, .lossless: return "Smaller (level 8)"
            case .veryHigh: return "Smallest (level 12)"
            default: return quality.displayName
            }
        }
        return quality.displayName
    }

    public func qualitySectionTitle(for preset: ConversionPreset) -> String {
        isFLACFormat(preset) ? "Compression level" : "Quality"
    }

    public func qualitySectionSubtitle(for preset: ConversionPreset) -> String? {
        if isDirectStreamCopy(preset) {
            return "Copied unchanged from the original"
        }
        if isFLACFormat(preset) {
            return "Every level is lossless. Higher levels make smaller files but take longer."
        }
        return nil
    }

    public func setAudioCodec(_ newCodec: AudioCodecType, in preset: inout ConversionPreset) {
        preset.audioCodec = newCodec
        if newCodec == .copy {
            preset.audioBitrateKbps = nil
            preset.audioTargetFileSizeBytes = nil
            preset.audioBitDepth = nil
        } else if newCodec == .wav || newCodec == .aiff {
            preset.audioBitrateKbps = nil
            if preset.audioBitDepth == nil {
                preset.audioBitDepth = .bit16
            }
        } else if newCodec == .flac || newCodec == .alac {
            preset.audioBitrateKbps = nil
        }

        if (newCodec == .flac || PresetValidator.isLossyAudioCodec(newCodec)) && preset.quality == .lossless {
            preset.quality = .high
        }
    }

    public func setDestinationFormat(_ newFormat: String, in preset: inout ConversionPreset) {
        preset.destinationFormat = newFormat
        let clean = newFormat.lowercased()
        if clean == "wav" || clean == "aiff" || clean == "aif" {
            preset.audioBitrateKbps = nil
            if preset.audioBitDepth == nil {
                preset.audioBitDepth = .bit16
            }
            if preset.audioCodec != .copy {
                preset.audioCodec = (clean == "wav") ? .wav : .aiff
            }
        } else if clean == "flac" {
            preset.audioBitrateKbps = nil
            if preset.audioCodec != .copy {
                preset.audioCodec = .flac
            }
        }

        if (clean == "flac" || PresetValidator.isLossyContainer(newFormat)) && preset.quality == .lossless {
            preset.quality = .high
        }
    }

    public func setPartLengthText(_ newText: String, in preset: inout ConversionPreset) -> String? {
        if let error = AudioDurationParser.validateDurationString(newText) {
            return error
        }
        if let seconds = AudioDurationParser.parseSecondsInt(newText) {
            preset.audioSplitDurationSeconds = seconds
        }
        return nil
    }
}
