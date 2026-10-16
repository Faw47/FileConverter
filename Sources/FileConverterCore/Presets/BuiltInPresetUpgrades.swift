import Foundation

/// Carries factory changes to built-in presets that users already have on
/// disk. Stored built-ins keep user edits, so each upgrade changes a field
/// only when it still holds the value the previous factory version shipped.
public enum BuiltInPresetUpgrades {
    public static let currentRevision = 5

    private struct Upgrade: Sendable {
        let revision: Int
        let apply: @Sendable (inout ConversionPreset) -> Void
    }

    private static let upgrades: [String: [Upgrade]] = [
        // Revision 1: macOS cannot write WebP, and AVIF writing depends on the
        // OS version, so these presets must be free to use ImageMagick.
        "image.webp": [Upgrade(revision: 1) { replace(\.backend, from: .imageIO, to: .auto, in: &$0) }],
        "image.webp-lossless": [Upgrade(revision: 1) { replace(\.backend, from: .imageIO, to: .auto, in: &$0) }],
        "image.avif": [Upgrade(revision: 1) { replace(\.backend, from: .imageIO, to: .auto, in: &$0) }],
        // Revision 3: video bitrate follows the output resolution instead of
        // a fixed factory number; GIF uses a sensible size; HEVC may use the
        // software encoder on Macs without a hardware HEVC encoder.
        "video.mp4-smaller": [Upgrade(revision: 3) { replace(\.videoBitrateKbps, from: 2000, to: nil, in: &$0) }],
        "video.mp4-high-quality": [Upgrade(revision: 3) { replace(\.videoBitrateKbps, from: 9000, to: nil, in: &$0) }],
        "video.mp4-1080p": [Upgrade(revision: 3) { replace(\.videoBitrateKbps, from: 6000, to: nil, in: &$0) }],
        "video.mp4-720p": [Upgrade(revision: 3) { replace(\.videoBitrateKbps, from: 2500, to: nil, in: &$0) }],
        "video.hevc-smaller": [Upgrade(revision: 3) { replace(\.videoBitrateKbps, from: 1500, to: nil, in: &$0) }],
        "video.hevc-hardware": [Upgrade(revision: 3) {
            replace(\.hardwareAcceleration, from: .forceAppleHardware, to: .auto, in: &$0)
        }],
        "image.jpeg-web": [Upgrade(revision: 3) {
            replace(\.resolution, from: .original, to: .custom(width: 2048, height: 2048), in: &$0)
        }],
        "video.animated-gif": [Upgrade(revision: 3) {
            replace(\.resolution, from: .custom(width: 640, height: 360), to: .custom(width: 480, height: 480), in: &$0)
        }],
        // Revision 4: the default MP4 preset uses High quality, so calling it
        // "Balanced" (the Medium level) contradicted its own setting.
        "video.mp4-balanced": [
            Upgrade(revision: 3) { replace(\.videoBitrateKbps, from: 4500, to: nil, in: &$0) },
            Upgrade(revision: 4) { replace(\.name, from: "MP4 (H.264 - Balanced)", to: "MP4 (H.264)", in: &$0) },
        ],
    ]

    /// Revision 3 renames: one naming convention for every built-in
    /// (`<Target> – <Variant>`, `<Source> → <Target>`). Applied only when the
    /// stored name is still the old factory name.
    private static let revision3Renames: [String: @Sendable (inout ConversionPreset) -> Void] = [
        "audio.aac-256": { replace(\.menuName, from: "AAC", to: "M4A – AAC", in: &$0) },
        "audio.alac": { replace(\.menuName, from: "ALAC", to: "M4A – Apple Lossless", in: &$0) },
        "audio.fit-5mb": { replace(\.menuName, from: "Audio ≤ 5 MB", to: "M4A – Fit in 5 MB", in: &$0) },
        "audio.mp3-128": { replace(\.menuName, from: "MP3 (128k)", to: "MP3 – 128 kbps", in: &$0) },
        "audio.mp3-192": { replace(\.menuName, from: "MP3 (192k)", to: "MP3 – 192 kbps", in: &$0) },
        "audio.mp3-320": { replace(\.menuName, from: "MP3", to: "MP3 – 320 kbps", in: &$0) },
        "audio.split-mp3-5min": { replace(\.menuName, from: "Split Audio (5 min)", to: "MP3 – 5-Minute Parts", in: &$0) },
        "audio.wav-44k": { replace(\.menuName, from: "WAV (CD Quality)", to: "WAV – CD Quality", in: &$0) },
        "document.epub-to-pdf": { replace(\.menuName, from: "EPUB to PDF", to: "EPUB → PDF", in: &$0) },
        "document.pdf-split-pages": { replace(\.menuName, from: "Split PDF Pages", to: "Split PDF", in: &$0) },
        "image.gif": { replace(\.menuName, from: "GIF Image", to: "GIF", in: &$0) },
        "image.jpeg-web": { replace(\.menuName, from: "JPEG - Web", to: "JPEG – Web", in: &$0) },
        "image.pdf-to-jpg": { replace(\.menuName, from: "PDF to JPEG", to: "PDF → JPEG", in: &$0) },
        "image.pdf-to-png": { replace(\.menuName, from: "PDF to PNG", to: "PDF → PNG", in: &$0) },
        "image.pdf-to-tiff": { replace(\.menuName, from: "PDF to TIFF", to: "PDF → TIFF", in: &$0) },
        "image.webp-lossless": { replace(\.menuName, from: "WebP Lossless", to: "WebP – Lossless", in: &$0) },
        "video.animated-gif": { replace(\.menuName, from: "GIF", to: "Animated GIF", in: &$0) },
        "video.hevc-smaller": { replace(\.menuName, from: "HEVC - Smaller File", to: "HEVC – Smaller", in: &$0) },
        "video.mp4-1080p": { replace(\.menuName, from: "1080p MP4", to: "MP4 – 1080p", in: &$0) },
        "video.mp4-720p": { replace(\.menuName, from: "720p MP4", to: "MP4 – 720p", in: &$0) },
        "video.mp4-high-quality": { replace(\.menuName, from: "MP4 - High Quality", to: "MP4 – High Quality", in: &$0) },
        "video.mp4-smaller": { replace(\.menuName, from: "MP4 - Smaller File", to: "MP4 – Smaller", in: &$0) },
    ]

    /// Revision 5 renames: long names follow `<Format> (<detail>)`, and the
    /// rewrap-only MOV/MKV → MP4 presets say what they are next to "MP4".
    /// Applied only when the stored name is still the old factory name.
    private static let revision5Renames: [String: @Sendable (inout ConversionPreset) -> Void] = [
        "video.mp4-1080p": { replace(\.name, from: "MP4 Video (1080p Full HD)", to: "MP4 (1080p)", in: &$0) },
        "video.mp4-720p": { replace(\.name, from: "MP4 Video (720p Web / Email)", to: "MP4 (720p)", in: &$0) },
        "video.hevc-hardware": { replace(\.name, from: "HEVC (H.265 Hardware)", to: "HEVC (H.265)", in: &$0) },
        "video.hevc-smaller": { replace(\.name, from: "HEVC Video (Smaller File - H.265)", to: "HEVC (Smaller File)", in: &$0) },
        "video.mkv-to-mp4": {
            replace(\.name, from: "MKV Video to MP4", to: "MKV to MP4 (No Re-encoding When Possible)", in: &$0)
            replace(\.menuName, from: "MKV → MP4", to: "MP4 – Fast", in: &$0)
        },
        "video.mov-to-mp4": {
            replace(\.name, from: "QuickTime MOV to MP4", to: "MOV to MP4 (No Re-encoding When Possible)", in: &$0)
            replace(\.menuName, from: "MOV → MP4", to: "MP4 – Fast", in: &$0)
        },
        "audio.mp3-320": { replace(\.name, from: "MP3 Audio (320 kbps)", to: "MP3 (320 kbps)", in: &$0) },
        "audio.mp3-192": { replace(\.name, from: "MP3 Audio (192 kbps - Balanced)", to: "MP3 (192 kbps)", in: &$0) },
        "audio.mp3-128": { replace(\.name, from: "MP3 Audio (128 kbps - Voice / Small)", to: "MP3 (128 kbps, for Voice)", in: &$0) },
        "audio.aac-256": { replace(\.name, from: "AAC Audio (256 kbps)", to: "M4A (AAC, 256 kbps)", in: &$0) },
        "audio.wav-pcm": { replace(\.name, from: "PCM WAV (Uncompressed)", to: "WAV (Uncompressed)", in: &$0) },
        "audio.wav-44k": { replace(\.name, from: "PCM WAV (CD Quality - 44.1 kHz / 16-bit)", to: "WAV (CD Quality, 44.1 kHz / 16-bit)", in: &$0) },
        "audio.opus-128": { replace(\.name, from: "Opus Audio (128 kbps)", to: "Opus (128 kbps)", in: &$0) },
        "image.pdf-to-png": { replace(\.name, from: "PDF pages to PNG images", to: "PDF Pages to PNG Images", in: &$0) },
        "image.pdf-to-jpg": { replace(\.name, from: "PDF pages to JPEG images", to: "PDF Pages to JPEG Images", in: &$0) },
        "image.pdf-to-tiff": { replace(\.name, from: "PDF pages to TIFF images", to: "PDF Pages to TIFF Images", in: &$0) },
        "document.pdf-compressed": { replace(\.name, from: "PDF Document (Compressed / Small File)", to: "Compressed PDF", in: &$0) },
    ]

    /// Built-ins removed from the factory list, as they last shipped. A stored
    /// copy that still matches is dropped; an edited copy becomes a custom
    /// preset so the user's work is kept.
    public static let retiredFactoryPresets: [String: ConversionPreset] = [
        "audio.m4a": ConversionPreset(
            name: "M4A Audio",
            menuName: "M4A",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "m4a",
            backend: .avFoundation,
            audioCodec: .aac,
            quality: .high,
            audioBitrateKbps: 256,
            isBuiltIn: true
        ),
    ]

    /// True when a stored built-in differs from its factory version in
    /// anything the user can change (settings or inheritance).
    public static func isModifiedFromFactory(_ preset: ConversionPreset) -> Bool {
        guard preset.isBuiltIn, let key = preset.builtInKey, let factory = factoryPresets[key] else { return false }
        return isUserModified(preset, comparedTo: factory)
            || preset.resolvedInheritance != factory.resolvedInheritance
            || preset.videoCodec != factory.videoCodec
            || preset.crf != factory.crf
            || preset.framerate != factory.framerate
            || preset.hardwareAcceleration != factory.hardwareAcceleration
            || preset.preserveMetadata != factory.preserveMetadata
            || preset.sourceFormats != factory.sourceFormats
            || preset.category != factory.category
    }

    /// True when the user changed settings that matter for conversion.
    public static func isUserModified(_ stored: ConversionPreset, comparedTo factory: ConversionPreset) -> Bool {
        stored.name != factory.name
            || stored.menuName != factory.menuName
            || stored.destinationFormat != factory.destinationFormat
            || stored.backend != factory.backend
            || stored.videoCodec != factory.videoCodec
            || stored.audioCodec != factory.audioCodec
            || stored.quality != factory.quality
            || stored.videoBitrateKbps != factory.videoBitrateKbps
            || stored.audioBitrateKbps != factory.audioBitrateKbps
            || stored.audioSampleRate != factory.audioSampleRate
            || stored.audioChannels != factory.audioChannels
            || stored.resolution != factory.resolution
            || stored.outputDirectoryPolicy != factory.outputDirectoryPolicy
            || stored.filenamePattern != factory.filenamePattern
            || stored.overwritePolicy != factory.overwritePolicy
            || stored.processingOptions != factory.processingOptions
    }

    /// Applies every upgrade newer than the stored revision and stamps the
    /// preset with the current revision.
    public static func upgrade(_ stored: ConversionPreset) -> ConversionPreset {
        var preset = stored
        let storedRevision = stored.factoryRevision ?? 0
        guard storedRevision < currentRevision else { return stored }
        if let key = stored.builtInKey {
            for upgrade in upgrades[key, default: []] where upgrade.revision > storedRevision {
                upgrade.apply(&preset)
            }
            if storedRevision < 3, let rename = revision3Renames[key] {
                rename(&preset)
            }
            if storedRevision < 5, let rename = revision5Renames[key] {
                rename(&preset)
            }
            if let factory = factoryPresets[key] {
                applyNewFields(from: factory, to: &preset, storedRevision: storedRevision)
            }
        }
        preset.factoryRevision = currentRevision
        return preset
    }

    private static let factoryPresets: [String: ConversionPreset] = Dictionary(
        BuiltInPresets.makeDefaultPresets().compactMap { preset in preset.builtInKey.map { ($0, preset) } },
        uniquingKeysWith: { first, _ in first }
    )

    /// Fields introduced after a revision are copied from the factory preset,
    /// since stored presets cannot have edited a field that did not exist.
    private static func applyNewFields(from factory: ConversionPreset, to preset: inout ConversionPreset, storedRevision: Int) {
        if storedRevision < 2, preset.sameFormatSuffix == nil {
            // Revision 2 added `sameFormatSuffix`.
            preset.sameFormatSuffix = factory.sameFormatSuffix
        }
        if storedRevision < 3, preset.allowsStreamCopy == nil {
            // Revision 3 added `allowsStreamCopy`.
            preset.allowsStreamCopy = factory.allowsStreamCopy
        }
    }

    static func replace<Value: Equatable>(
        _ keyPath: WritableKeyPath<ConversionPreset, Value>,
        from oldValue: Value,
        to newValue: Value,
        in preset: inout ConversionPreset
    ) {
        if preset[keyPath: keyPath] == oldValue {
            preset[keyPath: keyPath] = newValue
        }
    }
}
