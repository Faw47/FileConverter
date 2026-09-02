import Foundation

public enum BuiltInPresets {
    public static func makeDefaultPresets() -> [ConversionPreset] {
        var presets: [ConversionPreset] = []
        var order = 0

        func add(_ key: String, _ preset: ConversionPreset) {
            var p = preset
            p.id = BuiltInPresetIdentity.id(for: key)
            p.builtInKey = key
            p.sortOrder = order
            order += 10
            presets.append(p)
        }

        // MARK: - VIDEO PRESETS
        add("video.mp4-balanced", ConversionPreset(
            name: "MP4 (H.264 - Balanced)",
            menuName: "MP4",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            videoBitrateKbps: 4500,
            crf: 22,
            hardwareAcceleration: .auto,
            isBuiltIn: true
        ))

        add("video.mp4-smaller", ConversionPreset(
            name: "MP4 (Smaller File)",
            menuName: "MP4 - Smaller File",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .low,
            videoBitrateKbps: 2000,
            crf: 28,
            hardwareAcceleration: .auto,
            isBuiltIn: true
        ))

        add("video.mp4-high-quality", ConversionPreset(
            name: "MP4 (High Quality)",
            menuName: "MP4 - High Quality",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .veryHigh,
            videoBitrateKbps: 9000,
            crf: 18,
            hardwareAcceleration: .auto,
            isBuiltIn: true
        ))

        add("video.hevc-hardware", ConversionPreset(
            name: "HEVC (H.265 Hardware)",
            menuName: "HEVC",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .hevc,
            audioCodec: .aac,
            quality: .high,
            crf: 24,
            hardwareAcceleration: .forceAppleHardware,
            isBuiltIn: true
        ))

        add("video.av1", ConversionPreset(
            name: "AV1 Video",
            menuName: "AV1",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .av1,
            audioCodec: .opus,
            quality: .high,
            crf: 26,
            hardwareAcceleration: .auto,
            isBuiltIn: true
        ))

        add("video.quicktime-mov", ConversionPreset(
            name: "QuickTime MOV",
            menuName: "MOV",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mov",
            backend: .auto,
            videoCodec: .auto,
            audioCodec: .aac,
            quality: .high,
            isBuiltIn: true
        ))

        add("video.prores-editing", ConversionPreset(
            name: "Apple ProRes (Editing)",
            menuName: "ProRes",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mov",
            backend: .avFoundation,
            videoCodec: .proRes,
            audioCodec: .alac,
            quality: .lossless,
            hardwareAcceleration: .forceAppleHardware,
            isBuiltIn: true
        ))

        add("video.webm-vp9-opus", ConversionPreset(
            name: "WebM (VP9 + Opus)",
            menuName: "WebM",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "webm",
            backend: .ffmpeg,
            videoCodec: .vp9,
            audioCodec: .opus,
            quality: .high,
            crf: 30,
            isBuiltIn: true
        ))

        add("video.matroska", ConversionPreset(
            name: "Matroska MKV",
            menuName: "MKV",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mkv",
            backend: .ffmpeg,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            isBuiltIn: true
        ))

        add("video.animated-gif", ConversionPreset(
            name: "Animated GIF",
            menuName: "GIF",
            category: .video,
            sourceFormats: ["video", "image"],
            destinationFormat: "gif",
            backend: .auto,
            resolution: .custom(width: 640, height: 360),
            framerate: 15,
            isBuiltIn: true
        ))

        // MARK: - AUDIO PRESETS
        add("audio.mp3-320", ConversionPreset(
            name: "MP3 Audio (320 kbps)",
            menuName: "MP3",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "mp3",
            backend: .auto,
            audioCodec: .mp3,
            quality: .high,
            audioBitrateKbps: 320,
            isBuiltIn: true
        ))

        add("audio.aac-256", ConversionPreset(
            name: "AAC Audio (256 kbps)",
            menuName: "AAC",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "m4a",
            backend: .avFoundation,
            audioCodec: .aac,
            quality: .high,
            audioBitrateKbps: 256,
            isBuiltIn: true
        ))

        add("audio.m4a", ConversionPreset(
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
        ))

        add("audio.alac", ConversionPreset(
            name: "Apple Lossless (ALAC)",
            menuName: "ALAC",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "m4a",
            backend: .avFoundation,
            audioCodec: .alac,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("audio.flac", ConversionPreset(
            name: "FLAC Lossless Audio",
            menuName: "FLAC",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "flac",
            backend: .auto,
            audioCodec: .flac,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("audio.wav-pcm", ConversionPreset(
            name: "PCM WAV (Uncompressed)",
            menuName: "WAV",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "wav",
            backend: .avFoundation,
            audioCodec: .wav,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("audio.aiff", ConversionPreset(
            name: "AIFF Audio",
            menuName: "AIFF",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "aiff",
            backend: .avFoundation,
            audioCodec: .aiff,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("audio.opus-128", ConversionPreset(
            name: "Opus Audio (128 kbps)",
            menuName: "Opus",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "opus",
            backend: .ffmpeg,
            audioCodec: .opus,
            quality: .high,
            audioBitrateKbps: 128,
            isBuiltIn: true
        ))

        add("audio.ogg-vorbis", ConversionPreset(
            name: "Ogg Vorbis Audio",
            menuName: "OGG",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "ogg",
            backend: .ffmpeg,
            audioCodec: .auto,
            quality: .high,
            audioBitrateKbps: 192,
            isBuiltIn: true
        ))

        add("audio.quicktime-qta", ConversionPreset(
            name: "QuickTime Audio (QTA)",
            menuName: "QTA",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "qta",
            backend: .avFoundation,
            audioCodec: .aac,
            quality: .high,
            audioBitrateKbps: 256,
            isBuiltIn: true
        ))

        // MARK: - IMAGE PRESETS
        add("image.jpeg", ConversionPreset(
            name: "JPEG Image",
            menuName: "JPEG",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.png", ConversionPreset(
            name: "PNG Image (Lossless)",
            menuName: "PNG",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "png",
            backend: .imageIO,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.heic", ConversionPreset(
            name: "HEIC Image",
            menuName: "HEIC",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "heic",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.webp", ConversionPreset(
            name: "WebP Image",
            menuName: "WebP",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "webp",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.avif", ConversionPreset(
            name: "AVIF Image",
            menuName: "AVIF",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "avif",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.tiff", ConversionPreset(
            name: "TIFF Image",
            menuName: "TIFF",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "tiff",
            backend: .imageIO,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.bmp", ConversionPreset(
            name: "BMP Image",
            menuName: "BMP",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "bmp",
            backend: .imageIO,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.icns", ConversionPreset(
            name: "Apple ICNS Icon",
            menuName: "ICNS",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "icns",
            backend: .imageIO,
            quality: .lossless,
            isBuiltIn: true
        ))

        // MARK: - DOCUMENT PRESETS
        add("document.pdf", ConversionPreset(
            name: "PDF Document",
            menuName: "PDF",
            category: .document,
            sourceFormats: ["document", "image"],
            destinationFormat: "pdf",
            backend: .auto,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.docx", ConversionPreset(
            name: "Microsoft Word (DOCX)",
            menuName: "DOCX",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "docx",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.txt", ConversionPreset(
            name: "Plain Text (TXT)",
            menuName: "TXT",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "txt",
            backend: .auto,
            isBuiltIn: true
        ))

        add("document.rtf", ConversionPreset(
            name: "Rich Text Format (RTF)",
            menuName: "RTF",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "rtf",
            backend: .auto,
            isBuiltIn: true
        ))

        add("document.html", ConversionPreset(
            name: "HTML Web Document",
            menuName: "HTML",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "html",
            backend: .libreOffice,
            isBuiltIn: true
        ))

        add("document.epub", ConversionPreset(
            name: "EPUB eBook",
            menuName: "EPUB",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "epub",
            backend: .libreOffice,
            isBuiltIn: true
        ))

        add("document.xlsx", ConversionPreset(
            name: "Microsoft Excel (XLSX)",
            menuName: "XLSX",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "xlsx",
            backend: .libreOffice,
            isBuiltIn: true
        ))

        add("document.csv", ConversionPreset(
            name: "Comma Separated Values (CSV)",
            menuName: "CSV",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "csv",
            backend: .libreOffice,
            isBuiltIn: true
        ))

        add("document.pptx", ConversionPreset(
            name: "Microsoft PowerPoint (PPTX)",
            menuName: "PPTX",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "pptx",
            backend: .libreOffice,
            isBuiltIn: true
        ))

        return presets
    }
}
