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
            p.factoryRevision = BuiltInPresetUpgrades.currentRevision
            p.inheritance = .inheritAll
            order += 10
            presets.append(p)
        }

        // MARK: - VIDEO PRESETS
        add("video.mp4-balanced", ConversionPreset(
            name: "MP4 (H.264)",
            menuName: "MP4",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            crf: 22,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "converted"
        ))

        add("video.mp4-smaller", ConversionPreset(
            name: "MP4 (Smaller File)",
            menuName: "MP4 – Smaller",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .low,
            crf: 28,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "small"
        ))

        add("video.mp4-high-quality", ConversionPreset(
            name: "MP4 (High Quality)",
            menuName: "MP4 – High Quality",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .veryHigh,
            crf: 18,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "hq"
        ))

        add("video.mp4-1080p", ConversionPreset(
            name: "MP4 (1080p)",
            menuName: "MP4 – 1080p",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            crf: 20,
            resolution: .hd1080p,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "1080p"
        ))

        add("video.mp4-720p", ConversionPreset(
            name: "MP4 (720p)",
            menuName: "MP4 – 720p",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .medium,
            crf: 24,
            resolution: .hd720p,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "720p"
        ))

        add("video.hevc-hardware", ConversionPreset(
            name: "HEVC (H.265)",
            menuName: "HEVC",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .hevc,
            audioCodec: .aac,
            quality: .high,
            crf: 24,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "hevc"
        ))

        add("video.hevc-smaller", ConversionPreset(
            name: "HEVC (Smaller File)",
            menuName: "HEVC – Smaller",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .hevc,
            audioCodec: .aac,
            quality: .low,
            crf: 28,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "hevc-small"
        ))

        add("video.av1", ConversionPreset(
            name: "AV1 Video",
            menuName: "AV1",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .av1,
            audioCodec: .aac,
            quality: .high,
            crf: 26,
            hardwareAcceleration: .auto,
            isBuiltIn: true,
            sameFormatSuffix: "av1"
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
            isBuiltIn: true,
            sameFormatSuffix: "converted"
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
            isBuiltIn: true,
            sameFormatSuffix: "prores"
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
            isBuiltIn: true,
            sameFormatSuffix: "converted"
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
            isBuiltIn: true,
            sameFormatSuffix: "converted"
        ))

        add("video.animated-gif", ConversionPreset(
            name: "Animated GIF",
            menuName: "Animated GIF",
            category: .video,
            sourceFormats: ["video", "image"],
            destinationFormat: "gif",
            backend: .auto,
            resolution: .custom(width: 480, height: 480),
            framerate: 15,
            isBuiltIn: true
        ))

        add("video.mkv-to-mp4", ConversionPreset(
            name: "MKV to MP4 (No Re-encoding When Possible)",
            menuName: "MP4 – Fast",
            category: .video,
            sourceFormats: ["mkv"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            crf: 22,
            isBuiltIn: true,
            allowsStreamCopy: true
        ))

        add("video.mov-to-mp4", ConversionPreset(
            name: "MOV to MP4 (No Re-encoding When Possible)",
            menuName: "MP4 – Fast",
            category: .video,
            sourceFormats: ["mov"],
            destinationFormat: "mp4",
            backend: .avFoundation,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            isBuiltIn: true,
            allowsStreamCopy: true
        ))
        add("video.fit-10mb", ConversionPreset(
            name: "MP4 Sized for Chat Apps (Up to 10 MB)",
            menuName: "MP4 – Fit in 10 MB",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .medium,
            processingOptions: ConversionProcessingOptions(videoTargetFileSizeBytes: 10_000_000),
            isBuiltIn: true,
            sameFormatSuffix: "10mb"
        ))
        add("video.fit-25mb", ConversionPreset(
            name: "MP4 Sized for Email (Up to 25 MB)",
            menuName: "MP4 – Fit in 25 MB",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .medium,
            processingOptions: ConversionProcessingOptions(videoTargetFileSizeBytes: 25_000_000),
            isBuiltIn: true,
            sameFormatSuffix: "25mb"
        ))
        add("video.fit-50mb", ConversionPreset(
            name: "MP4 Sized for Large Uploads (Up to 50 MB)",
            menuName: "MP4 – Fit in 50 MB",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .medium,
            processingOptions: ConversionProcessingOptions(videoTargetFileSizeBytes: 50_000_000),
            isBuiltIn: true,
            sameFormatSuffix: "50mb"
        ))

        // MARK: - AUDIO PRESETS
        add("audio.mp3-320", ConversionPreset(
            name: "MP3 (320 kbps)",
            menuName: "MP3 – 320 kbps",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "mp3",
            backend: .auto,
            audioCodec: .mp3,
            quality: .high,
            audioBitrateKbps: 320,
            isBuiltIn: true
        ))

        add("audio.mp3-192", ConversionPreset(
            name: "MP3 (192 kbps)",
            menuName: "MP3 – 192 kbps",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "mp3",
            backend: .auto,
            audioCodec: .mp3,
            quality: .medium,
            audioBitrateKbps: 192,
            isBuiltIn: true,
            sameFormatSuffix: "192k"
        ))

        add("audio.mp3-128", ConversionPreset(
            name: "MP3 (128 kbps, for Voice)",
            menuName: "MP3 – 128 kbps",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "mp3",
            backend: .auto,
            audioCodec: .mp3,
            quality: .low,
            audioBitrateKbps: 128,
            isBuiltIn: true,
            sameFormatSuffix: "128k"
        ))

        add("audio.aac-256", ConversionPreset(
            name: "M4A (AAC, 256 kbps)",
            menuName: "M4A – AAC",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "m4a",
            backend: .avFoundation,
            audioCodec: .aac,
            quality: .high,
            audioBitrateKbps: 256,
            isBuiltIn: true,
            sameFormatSuffix: "aac"
        ))

        add("audio.alac", ConversionPreset(
            name: "Apple Lossless (ALAC)",
            menuName: "M4A – Apple Lossless",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "m4a",
            backend: .avFoundation,
            audioCodec: .alac,
            quality: .lossless,
            isBuiltIn: true,
            sameFormatSuffix: "alac"
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
            name: "WAV (Uncompressed)",
            menuName: "WAV",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "wav",
            backend: .avFoundation,
            audioCodec: .wav,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("audio.wav-44k", ConversionPreset(
            name: "WAV (CD Quality, 44.1 kHz / 16-bit)",
            menuName: "WAV – CD Quality",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "wav",
            backend: .auto,
            audioCodec: .wav,
            quality: .lossless,
            audioSampleRate: 44100,
            audioChannels: 2,
            isBuiltIn: true,
            sameFormatSuffix: "44k"
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
            name: "Opus (128 kbps)",
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
            isBuiltIn: true,
            sameFormatSuffix: "converted"
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
            isBuiltIn: true,
            sameFormatSuffix: "converted"
        ))

        add("audio.split-mp3-5min", ConversionPreset(
            name: "Split Audio into 5-Minute MP3 Files",
            menuName: "MP3 – 5-Minute Parts",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            quality: .high,
            audioBitrateKbps: 192,
            processingOptions: ConversionProcessingOptions(audioSplitDurationSeconds: 5 * 60),
            isBuiltIn: true
        ))

        add("audio.fit-5mb", ConversionPreset(
            name: "Audio Sized for Sharing (Up to 5 MB)",
            menuName: "M4A – Fit in 5 MB",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "m4a",
            backend: .ffmpeg,
            audioCodec: .aac,
            quality: .medium,
            processingOptions: ConversionProcessingOptions(audioTargetFileSizeBytes: 5_000_000),
            isBuiltIn: true,
            sameFormatSuffix: "5mb"
        ))

        add("audio.wav-to-mp3", ConversionPreset(
            name: "WAV Audio to MP3",
            menuName: "WAV → MP3",
            category: .audio,
            sourceFormats: ["wav"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            quality: .high,
            audioBitrateKbps: 320,
            isBuiltIn: true
        ))

        add("audio.flac-to-mp3", ConversionPreset(
            name: "FLAC Audio to MP3",
            menuName: "FLAC → MP3",
            category: .audio,
            sourceFormats: ["flac"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            quality: .high,
            audioBitrateKbps: 320,
            isBuiltIn: true
        ))

        add("audio.m4a-to-mp3", ConversionPreset(
            name: "M4A Audio to MP3",
            menuName: "M4A → MP3",
            category: .audio,
            sourceFormats: ["m4a"],
            destinationFormat: "mp3",
            backend: .ffmpeg,
            audioCodec: .mp3,
            quality: .high,
            audioBitrateKbps: 320,
            isBuiltIn: true
        ))

        add("audio.mp3-to-m4a", ConversionPreset(
            name: "MP3 Audio to M4A",
            menuName: "MP3 → M4A",
            category: .audio,
            sourceFormats: ["mp3"],
            destinationFormat: "m4a",
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

        add("image.jpeg-web", ConversionPreset(
            name: "JPEG Image (Web Optimized)",
            menuName: "JPEG – Web",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .medium,
            resolution: .custom(width: 2048, height: 2048),
            isBuiltIn: true,
            sameFormatSuffix: "web"
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
            backend: .auto,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.webp-lossless", ConversionPreset(
            name: "WebP Image (Lossless)",
            menuName: "WebP – Lossless",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "webp",
            backend: .auto,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.avif", ConversionPreset(
            name: "AVIF Image",
            menuName: "AVIF",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "avif",
            backend: .auto,
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

        add("image.ico", ConversionPreset(
            name: "Windows Icon (ICO)",
            menuName: "ICO",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "ico",
            backend: .auto,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.gif", ConversionPreset(
            name: "GIF Image",
            menuName: "GIF",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "gif",
            backend: .imageIO,
            quality: .medium,
            isBuiltIn: true
        ))

        // Specialized format conversions that require external backends
        add("image.svg-to-png", ConversionPreset(
            name: "SVG Artwork to PNG",
            menuName: "SVG → PNG",
            category: .image,
            sourceFormats: ["svg"],
            destinationFormat: "png",
            backend: .imageMagick,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.psd-to-png", ConversionPreset(
            name: "Photoshop Document to PNG",
            menuName: "PSD → PNG",
            category: .image,
            sourceFormats: ["psd"],
            destinationFormat: "png",
            backend: .imageMagick,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.pdf-to-png", ConversionPreset(
            name: "PDF Pages to PNG Images",
            menuName: "PDF → PNG",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "png",
            backend: .pdfKit,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.pdf-to-jpg", ConversionPreset(
            name: "PDF Pages to JPEG Images",
            menuName: "PDF → JPEG",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "jpg",
            backend: .pdfKit,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.pdf-to-tiff", ConversionPreset(
            name: "PDF Pages to TIFF Images",
            menuName: "PDF → TIFF",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "tiff",
            backend: .pdfKit,
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

        add("document.pdf-compressed", ConversionPreset(
            name: "Compressed PDF",
            menuName: "Compress PDF",
            category: .document,
            sourceFormats: ["pdf", "document"],
            destinationFormat: "pdf",
            backend: .auto,
            quality: .low,
            isBuiltIn: true,
            sameFormatSuffix: "compressed"
        ))

        add("document.pdf-split-pages", ConversionPreset(
            name: "Split PDF into Individual Pages",
            menuName: "Split PDF",
            category: .document,
            sourceFormats: ["pdf"],
            destinationFormat: "pdf",
            backend: .pdfKit,
            processingOptions: ConversionProcessingOptions(splitPDFIntoPages: true),
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

        add("document.epub-to-pdf", ConversionPreset(
            name: "EPUB eBook to PDF",
            menuName: "EPUB → PDF",
            category: .document,
            sourceFormats: ["epub"],
            destinationFormat: "pdf",
            backend: .calibre,
            quality: .high,
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

        add("document.odt", ConversionPreset(
            name: "OpenDocument Text (ODT)",
            menuName: "ODT",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "odt",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.ods", ConversionPreset(
            name: "OpenDocument Spreadsheet (ODS)",
            menuName: "ODS",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "ods",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.odp", ConversionPreset(
            name: "OpenDocument Presentation (ODP)",
            menuName: "ODP",
            category: .document,
            sourceFormats: ["document"],
            destinationFormat: "odp",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.docx-to-pdf", ConversionPreset(
            name: "Word Document to PDF",
            menuName: "DOCX → PDF",
            category: .document,
            sourceFormats: ["docx"],
            destinationFormat: "pdf",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.xlsx-to-pdf", ConversionPreset(
            name: "Excel Spreadsheet to PDF",
            menuName: "XLSX → PDF",
            category: .document,
            sourceFormats: ["xlsx"],
            destinationFormat: "pdf",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.pptx-to-pdf", ConversionPreset(
            name: "PowerPoint Presentation to PDF",
            menuName: "PPTX → PDF",
            category: .document,
            sourceFormats: ["pptx"],
            destinationFormat: "pdf",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.docx-to-odt", ConversionPreset(
            name: "Word Document to OpenDocument Text",
            menuName: "DOCX → ODT",
            category: .document,
            sourceFormats: ["docx"],
            destinationFormat: "odt",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.xlsx-to-csv", ConversionPreset(
            name: "Excel Spreadsheet to CSV",
            menuName: "XLSX → CSV",
            category: .document,
            sourceFormats: ["xlsx"],
            destinationFormat: "csv",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        add("document.csv-to-xlsx", ConversionPreset(
            name: "CSV to Excel Spreadsheet",
            menuName: "CSV → XLSX",
            category: .document,
            sourceFormats: ["csv"],
            destinationFormat: "xlsx",
            backend: .libreOffice,
            quality: .high,
            isBuiltIn: true
        ))

        return presets
    }
}
