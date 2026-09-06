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

        add("video.mp4-1080p", ConversionPreset(
            name: "MP4 Video (1080p Full HD)",
            menuName: "1080p MP4",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            videoBitrateKbps: 6000,
            crf: 20,
            resolution: .hd1080p,
            hardwareAcceleration: .auto,
            isBuiltIn: true
        ))

        add("video.mp4-720p", ConversionPreset(
            name: "MP4 Video (720p Web / Email)",
            menuName: "720p MP4",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .medium,
            videoBitrateKbps: 2500,
            crf: 24,
            resolution: .hd720p,
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

        add("video.hevc-smaller", ConversionPreset(
            name: "HEVC Video (Smaller File - H.265)",
            menuName: "HEVC - Smaller File",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            backend: .auto,
            videoCodec: .hevc,
            audioCodec: .aac,
            quality: .low,
            videoBitrateKbps: 1500,
            crf: 28,
            hardwareAcceleration: .auto,
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
            audioCodec: .aac,
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

        add("video.mkv-to-mp4", ConversionPreset(
            name: "MKV Video to MP4",
            menuName: "MKV → MP4",
            category: .video,
            sourceFormats: ["mkv"],
            destinationFormat: "mp4",
            backend: .ffmpeg,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
            crf: 22,
            isBuiltIn: true
        ))

        add("video.mov-to-mp4", ConversionPreset(
            name: "QuickTime MOV to MP4",
            menuName: "MOV → MP4",
            category: .video,
            sourceFormats: ["mov"],
            destinationFormat: "mp4",
            backend: .avFoundation,
            videoCodec: .h264,
            audioCodec: .aac,
            quality: .high,
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

        add("audio.mp3-192", ConversionPreset(
            name: "MP3 Audio (192 kbps - Balanced)",
            menuName: "MP3 (192k)",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "mp3",
            backend: .auto,
            audioCodec: .mp3,
            quality: .medium,
            audioBitrateKbps: 192,
            isBuiltIn: true
        ))

        add("audio.mp3-128", ConversionPreset(
            name: "MP3 Audio (128 kbps - Voice / Small)",
            menuName: "MP3 (128k)",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "mp3",
            backend: .auto,
            audioCodec: .mp3,
            quality: .low,
            audioBitrateKbps: 128,
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

        add("audio.wav-44k", ConversionPreset(
            name: "PCM WAV (CD Quality - 44.1 kHz / 16-bit)",
            menuName: "WAV (CD Quality)",
            category: .audio,
            sourceFormats: ["audio", "video"],
            destinationFormat: "wav",
            backend: .auto,
            audioCodec: .wav,
            quality: .lossless,
            audioSampleRate: 44100,
            audioChannels: 2,
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

        add("audio.split-mp3-5min", ConversionPreset(
            name: "Split Audio into 5-Minute MP3 Files",
            menuName: "Split Audio (5 min)",
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
            menuName: "Audio ≤ 5 MB",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "m4a",
            backend: .ffmpeg,
            audioCodec: .aac,
            quality: .medium,
            processingOptions: ConversionProcessingOptions(audioTargetFileSizeBytes: 5_000_000),
            isBuiltIn: true
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
            menuName: "JPEG - Web",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .medium,
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

        add("image.webp-lossless", ConversionPreset(
            name: "WebP Image (Lossless)",
            menuName: "WebP Lossless",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "webp",
            backend: .imageIO,
            quality: .lossless,
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
            menuName: "GIF Image",
            category: .image,
            sourceFormats: ["image"],
            destinationFormat: "gif",
            backend: .imageIO,
            quality: .medium,
            isBuiltIn: true
        ))

        // Explicit source-to-destination recipes make the most common photo
        // conversions discoverable. The broad image presets above remain
        // useful for batch work, while these labels answer the user's exact
        // question in Finder (for example, “HEIC → PNG”).
        add("image.heic-to-jpeg", ConversionPreset(
            name: "HEIC Photo to JPEG",
            menuName: "HEIC → JPEG",
            category: .image,
            sourceFormats: ["heic"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.heic-to-png", ConversionPreset(
            name: "HEIC Photo to PNG",
            menuName: "HEIC → PNG",
            category: .image,
            sourceFormats: ["heic"],
            destinationFormat: "png",
            backend: .imageIO,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.heic-to-webp", ConversionPreset(
            name: "HEIC Photo to WebP",
            menuName: "HEIC → WebP",
            category: .image,
            sourceFormats: ["heic"],
            destinationFormat: "webp",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.jpeg-to-heic", ConversionPreset(
            name: "JPEG Photo to HEIC",
            menuName: "JPEG → HEIC",
            category: .image,
            sourceFormats: ["jpeg"],
            destinationFormat: "heic",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.png-to-jpeg", ConversionPreset(
            name: "PNG Image to JPEG",
            menuName: "PNG → JPEG",
            category: .image,
            sourceFormats: ["png"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.png-to-heic", ConversionPreset(
            name: "PNG Image to HEIC",
            menuName: "PNG → HEIC",
            category: .image,
            sourceFormats: ["png"],
            destinationFormat: "heic",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.webp-to-jpeg", ConversionPreset(
            name: "WebP Image to JPEG",
            menuName: "WebP → JPEG",
            category: .image,
            sourceFormats: ["webp"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.tiff-to-jpeg", ConversionPreset(
            name: "TIFF Image to JPEG",
            menuName: "TIFF → JPEG",
            category: .image,
            sourceFormats: ["tiff"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.raw-to-jpeg", ConversionPreset(
            name: "Camera RAW to JPEG",
            menuName: "RAW → JPEG",
            category: .image,
            sourceFormats: ["raw"],
            destinationFormat: "jpg",
            backend: .imageIO,
            quality: .high,
            isBuiltIn: true
        ))

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
            name: "PDF pages to PNG images",
            menuName: "PDF to PNG",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "png",
            backend: .pdfKit,
            quality: .lossless,
            isBuiltIn: true
        ))

        add("image.pdf-to-jpg", ConversionPreset(
            name: "PDF pages to JPEG images",
            menuName: "PDF to JPEG",
            category: .image,
            sourceFormats: ["pdf"],
            destinationFormat: "jpg",
            backend: .pdfKit,
            quality: .high,
            isBuiltIn: true
        ))

        add("image.pdf-to-tiff", ConversionPreset(
            name: "PDF pages to TIFF images",
            menuName: "PDF to TIFF",
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
            name: "PDF Document (Compressed / Small File)",
            menuName: "Compress PDF",
            category: .document,
            sourceFormats: ["pdf", "document"],
            destinationFormat: "pdf",
            backend: .ghostscript,
            quality: .low,
            isBuiltIn: true
        ))

        add("document.pdf-split-pages", ConversionPreset(
            name: "Split PDF into Individual Pages",
            menuName: "Split PDF Pages",
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
            menuName: "EPUB to PDF",
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
