import Foundation
import UniformTypeIdentifiers

public enum FormatRegistrationError: Error, Equatable, Sendable {
    case duplicateID(String)
    case duplicateExtension(alias: String, existingFormatID: String)
    case duplicateUTType(alias: String, existingFormatID: String)
}

public final class FormatRegistry: @unchecked Sendable {
    public static let shared = FormatRegistry()

    private var formatsByID: [String: FormatDefinition] = [:]
    private var formatsByExtension: [String: FormatDefinition] = [:]
    private var formatsByUTTypeIdentifier: [String: FormatDefinition] = [:]

    private let lock = NSLock()

    public init() {
        registerBuiltInFormats()
    }

    public func registerFormat(_ format: FormatDefinition) throws {
        lock.lock()
        defer { lock.unlock() }

        guard formatsByID[format.id] == nil else {
            throw FormatRegistrationError.duplicateID(format.id)
        }

        let extensions = Set(([format.primaryExtension] + format.extensions).map { $0.lowercased() })
        for ext in extensions {
            if let existing = formatsByExtension[ext] {
                throw FormatRegistrationError.duplicateExtension(alias: ext, existingFormatID: existing.id)
            }
        }

        let utTypeIdentifiers = Set(format.utTypeIdentifiers.map { $0.lowercased() })
        for identifier in utTypeIdentifiers {
            if let existing = formatsByUTTypeIdentifier[identifier] {
                throw FormatRegistrationError.duplicateUTType(alias: identifier, existingFormatID: existing.id)
            }
        }

        formatsByID[format.id] = format
        for ext in extensions {
            formatsByExtension[ext] = format
        }
        for identifier in utTypeIdentifiers {
            formatsByUTTypeIdentifier[identifier] = format
        }
    }

    public func format(forID id: String) -> FormatDefinition? {
        lock.lock()
        defer { lock.unlock() }
        let cleanID = id.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if let direct = formatsByID[cleanID] {
            return direct
        }
        return formatsByExtension[cleanID]
    }

    public func format(forExtension ext: String) -> FormatDefinition? {
        lock.lock()
        defer { lock.unlock() }
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return formatsByExtension[cleanExt]
    }

    public func format(forUTType utType: UTType) -> FormatDefinition? {
        lock.lock()
        defer { lock.unlock() }

        if let direct = formatsByUTTypeIdentifier[utType.identifier.lowercased()] {
            return direct
        }

        // Search conformance
        for (_, format) in formatsByID {
            if format.matchesUTType(utType) {
                return format
            }
        }
        return nil
    }

    public func format(forURL url: URL) -> FormatDefinition? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let fmt = format(forExtension: ext) {
            return fmt
        }

        if let utType = UTType(filenameExtension: ext) {
            return format(forUTType: utType)
        }

        return nil
    }

    public func allFormats() -> [FormatDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return Array(formatsByID.values)
    }

    public func formats(for category: FormatCategory) -> [FormatDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return formatsByID.values.filter { $0.category == category }
    }

    // MARK: - Built-In Formats Initialization

    private func registerBuiltInFormats() {
        // MARK: Video Formats
        register([
            FormatDefinition(
                id: "mp4",
                name: "MPEG-4 Video",
                primaryExtension: "mp4",
                extensions: ["mp4", "m4v"],
                utTypeIdentifiers: [UTType.mpeg4Movie.identifier, "public.mpeg-4", "com.apple.m4v-video"],
                category: .video,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                supportsHDR: true,
                mimeType: "video/mp4"
            ),
            FormatDefinition(
                id: "mov",
                name: "QuickTime Movie",
                primaryExtension: "mov",
                extensions: ["mov", "qt"],
                utTypeIdentifiers: [UTType.quickTimeMovie.identifier, "com.apple.quicktime-movie"],
                category: .video,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                supportsAlpha: true,
                supportsHDR: true,
                mimeType: "video/quicktime"
            ),
            FormatDefinition(
                id: "mkv",
                name: "Matroska Video",
                primaryExtension: "mkv",
                extensions: ["mkv"],
                utTypeIdentifiers: ["org.matroska.mkv", "public.matroska"],
                category: .video,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: false,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                supportsHDR: true,
                mimeType: "video/x-matroska"
            ),
            FormatDefinition(
                id: "webm",
                name: "WebM Video",
                primaryExtension: "webm",
                extensions: ["webm"],
                utTypeIdentifiers: ["org.webmproject.webm", "public.webm"],
                category: .video,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: false,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                supportsAlpha: true,
                mimeType: "video/webm"
            ),
            FormatDefinition(
                id: "avi",
                name: "Audio Video Interleave",
                primaryExtension: "avi",
                extensions: ["avi"],
                utTypeIdentifiers: [UTType.avi.identifier, "public.avi"],
                category: .video,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: false,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "video/x-msvideo"
            ),
            FormatDefinition(
                id: "mpg",
                name: "MPEG-1/2 Video",
                primaryExtension: "mpg",
                extensions: ["mpg", "mpeg", "m2v", "ts", "mts", "m2ts"],
                utTypeIdentifiers: [UTType.mpeg.identifier, "public.mpeg", "public.mpeg-2-transport-stream"],
                category: .video,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: false,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "video/mpeg"
            ),
            FormatDefinition(
                id: "flv",
                name: "Flash Video",
                primaryExtension: "flv",
                extensions: ["flv"],
                utTypeIdentifiers: ["com.adobe.flash.video"],
                category: .video,
                supportedInput: true,
                supportedOutput: false,
                ffmpegDecoderAvailable: true,
                mimeType: "video/x-flv"
            ),
            FormatDefinition(
                id: "wmv",
                name: "Windows Media Video",
                primaryExtension: "wmv",
                extensions: ["wmv", "asf"],
                utTypeIdentifiers: ["com.microsoft.windows-media-wmv"],
                category: .video,
                supportedInput: true,
                supportedOutput: false,
                ffmpegDecoderAvailable: true,
                mimeType: "video/x-ms-wmv"
            )
        ])

        // MARK: Audio Formats
        register([
            FormatDefinition(
                id: "mp3",
                name: "MP3 Audio",
                primaryExtension: "mp3",
                extensions: ["mp3"],
                utTypeIdentifiers: [UTType.mp3.identifier, "public.mp3"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/mpeg"
            ),
            FormatDefinition(
                id: "aac",
                name: "Advanced Audio Coding",
                primaryExtension: "aac",
                extensions: ["aac"],
                utTypeIdentifiers: ["public.aac-audio"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/aac"
            ),
            FormatDefinition(
                id: "m4a",
                name: "MPEG-4 Audio",
                primaryExtension: "m4a",
                extensions: ["m4a", "m4b"],
                utTypeIdentifiers: [UTType.mpeg4Audio.identifier, "public.m4a-audio"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/mp4"
            ),
            FormatDefinition(
                id: "flac",
                name: "Free Lossless Audio Codec",
                primaryExtension: "flac",
                extensions: ["flac"],
                utTypeIdentifiers: ["org.xiph.flac", "public.flac"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/flac"
            ),
            FormatDefinition(
                id: "wav",
                name: "Waveform Audio File Format",
                primaryExtension: "wav",
                extensions: ["wav", "wave"],
                utTypeIdentifiers: [UTType.wav.identifier, "com.microsoft.waveform-audio"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/wav"
            ),
            FormatDefinition(
                id: "aiff",
                name: "Audio Interchange File Format",
                primaryExtension: "aiff",
                extensions: ["aiff", "aif"],
                utTypeIdentifiers: [UTType.aiff.identifier, "public.aiff-audio"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/aiff"
            ),
            FormatDefinition(
                id: "opus",
                name: "Opus Interactive Audio",
                primaryExtension: "opus",
                extensions: ["opus"],
                utTypeIdentifiers: ["org.xiph.opus"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: false,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/opus"
            ),
            FormatDefinition(
                id: "ogg",
                name: "Ogg Vorbis Audio",
                primaryExtension: "ogg",
                extensions: ["ogg", "oga"],
                utTypeIdentifiers: ["org.xiph.ogg", "public.ogg-audio"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: false,
                nativeEncoderAvailable: false,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/ogg"
            ),
            FormatDefinition(
                id: "wma",
                name: "Windows Media Audio",
                primaryExtension: "wma",
                extensions: ["wma"],
                utTypeIdentifiers: ["com.microsoft.windows-media-wma"],
                category: .audio,
                supportedInput: true,
                supportedOutput: false,
                ffmpegDecoderAvailable: true,
                mimeType: "audio/x-ms-wma"
            ),
            FormatDefinition(
                id: "qta",
                name: "QuickTime Audio",
                primaryExtension: "qta",
                extensions: ["qta"],
                utTypeIdentifiers: ["com.apple.quicktime-audio"],
                category: .audio,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                mimeType: "audio/x-quicktime"
            )
        ])

        // MARK: Image Formats
        register([
            FormatDefinition(
                id: "png",
                name: "Portable Network Graphics",
                primaryExtension: "png",
                extensions: ["png"],
                utTypeIdentifiers: [UTType.png.identifier, "public.png"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                mimeType: "image/png"
            ),
            FormatDefinition(
                id: "jpeg",
                name: "JPEG Image",
                primaryExtension: "jpg",
                extensions: ["jpg", "jpeg", "jpe"],
                utTypeIdentifiers: [UTType.jpeg.identifier, "public.jpeg"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                mimeType: "image/jpeg"
            ),
            FormatDefinition(
                id: "heic",
                name: "High Efficiency Image Container",
                primaryExtension: "heic",
                extensions: ["heic", "heif"],
                utTypeIdentifiers: [UTType.heic.identifier, "public.heic", "public.heif"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                supportsHDR: true,
                mimeType: "image/heic"
            ),
            FormatDefinition(
                id: "webp",
                name: "WebP Image",
                primaryExtension: "webp",
                extensions: ["webp"],
                utTypeIdentifiers: [UTType.webP.identifier, "org.webmproject.webp"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                supportsAnimation: true,
                mimeType: "image/webp"
            ),
            FormatDefinition(
                id: "avif",
                name: "AV1 Image File Format",
                primaryExtension: "avif",
                extensions: ["avif"],
                utTypeIdentifiers: ["public.avif", "org.aomedia.avif"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                supportsHDR: true,
                mimeType: "image/avif"
            ),
            FormatDefinition(
                id: "tiff",
                name: "Tagged Image File Format",
                primaryExtension: "tiff",
                extensions: ["tiff", "tif"],
                utTypeIdentifiers: [UTType.tiff.identifier, "public.tiff"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                mimeType: "image/tiff"
            ),
            FormatDefinition(
                id: "gif",
                name: "Graphics Interchange Format",
                primaryExtension: "gif",
                extensions: ["gif"],
                utTypeIdentifiers: [UTType.gif.identifier, "com.compuserve.gif"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ffmpegDecoderAvailable: true,
                ffmpegEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                supportsAnimation: true,
                mimeType: "image/gif"
            ),
            FormatDefinition(
                id: "bmp",
                name: "Windows Bitmap",
                primaryExtension: "bmp",
                extensions: ["bmp", "dib"],
                utTypeIdentifiers: [UTType.bmp.identifier, "com.microsoft.bmp"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                mimeType: "image/bmp"
            ),
            FormatDefinition(
                id: "svg",
                name: "Scalable Vector Graphics",
                primaryExtension: "svg",
                extensions: ["svg"],
                utTypeIdentifiers: [UTType.svg.identifier, "public.svg-image"],
                category: .image,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true,
                mimeType: "image/svg+xml"
            ),
            FormatDefinition(
                id: "raw",
                name: "Digital Camera RAW",
                primaryExtension: "dng",
                extensions: ["dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "pef"],
                utTypeIdentifiers: [UTType.rawImage.identifier, "public.camera-raw-image"],
                category: .image,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                imageMagickSupported: true,
                supportsHDR: true
            ),
            FormatDefinition(
                id: "psd",
                name: "Adobe Photoshop Document",
                primaryExtension: "psd",
                extensions: ["psd"],
                utTypeIdentifiers: ["com.adobe.photoshop-image"],
                category: .image,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true
            ),
            FormatDefinition(
                id: "icns",
                name: "Apple Icon Image",
                primaryExtension: "icns",
                extensions: ["icns"],
                utTypeIdentifiers: [UTType.icns.identifier, "com.apple.icns"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                supportsAlpha: true
            ),
            FormatDefinition(
                id: "ico",
                name: "Windows Icon",
                primaryExtension: "ico",
                extensions: ["ico"],
                utTypeIdentifiers: [UTType.ico.identifier, "com.microsoft.ico"],
                category: .image,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                imageMagickSupported: true,
                supportsAlpha: true
            )
        ])

        // MARK: Document Formats
        register([
            FormatDefinition(
                id: "pdf",
                name: "Portable Document Format",
                primaryExtension: "pdf",
                extensions: ["pdf"],
                utTypeIdentifiers: [UTType.pdf.identifier, "com.adobe.pdf"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                ghostscriptSupported: true,
                libreOfficeSupported: true,
                mimeType: "application/pdf"
            ),
            FormatDefinition(
                id: "docx",
                name: "Microsoft Word OpenXML",
                primaryExtension: "docx",
                extensions: ["docx"],
                utTypeIdentifiers: ["org.openxmlformats.wordprocessingml.document"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                libreOfficeSupported: true,
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            ),
            FormatDefinition(
                id: "doc",
                name: "Microsoft Word Binary",
                primaryExtension: "doc",
                extensions: ["doc"],
                utTypeIdentifiers: ["com.microsoft.word.doc"],
                category: .document,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                libreOfficeSupported: true,
                mimeType: "application/msword"
            ),
            FormatDefinition(
                id: "odt",
                name: "OpenDocument Text",
                primaryExtension: "odt",
                extensions: ["odt"],
                utTypeIdentifiers: ["org.oasis-open.opendocument.text"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                libreOfficeSupported: true,
                mimeType: "application/vnd.oasis.opendocument.text"
            ),
            FormatDefinition(
                id: "rtf",
                name: "Rich Text Format",
                primaryExtension: "rtf",
                extensions: ["rtf", "rtfd"],
                utTypeIdentifiers: [UTType.rtf.identifier, "public.rtf"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                libreOfficeSupported: true,
                mimeType: "application/rtf"
            ),
            FormatDefinition(
                id: "txt",
                name: "Plain Text Document",
                primaryExtension: "txt",
                extensions: ["txt", "text"],
                utTypeIdentifiers: [UTType.plainText.identifier, "public.plain-text"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                libreOfficeSupported: true,
                mimeType: "text/plain"
            ),
            FormatDefinition(
                id: "html",
                name: "HTML Web Document",
                primaryExtension: "html",
                extensions: ["html", "htm"],
                utTypeIdentifiers: [UTType.html.identifier, "public.html"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                libreOfficeSupported: true,
                mimeType: "text/html"
            ),
            FormatDefinition(
                id: "epub",
                name: "Electronic Publication",
                primaryExtension: "epub",
                extensions: ["epub"],
                utTypeIdentifiers: [UTType.epub.identifier, "org.idpf.epub-container"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                libreOfficeSupported: true,
                mimeType: "application/epub+zip"
            ),
            FormatDefinition(
                id: "xlsx",
                name: "Microsoft Excel Spreadsheet",
                primaryExtension: "xlsx",
                extensions: ["xlsx"],
                utTypeIdentifiers: ["org.openxmlformats.spreadsheetml.sheet"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                libreOfficeSupported: true,
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            ),
            FormatDefinition(
                id: "xls",
                name: "Microsoft Excel Binary",
                primaryExtension: "xls",
                extensions: ["xls"],
                utTypeIdentifiers: ["com.microsoft.excel.xls"],
                category: .document,
                supportedInput: true,
                supportedOutput: false,
                libreOfficeSupported: true,
                mimeType: "application/vnd.ms-excel"
            ),
            FormatDefinition(
                id: "csv",
                name: "Comma Separated Values",
                primaryExtension: "csv",
                extensions: ["csv"],
                utTypeIdentifiers: ["public.comma-separated-values-text", "text/csv"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                nativeDecoderAvailable: true,
                nativeEncoderAvailable: true,
                libreOfficeSupported: true,
                mimeType: "text/csv"
            ),
            FormatDefinition(
                id: "pptx",
                name: "Microsoft PowerPoint Presentation",
                primaryExtension: "pptx",
                extensions: ["pptx"],
                utTypeIdentifiers: ["org.openxmlformats.presentationml.presentation"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                libreOfficeSupported: true,
                mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            ),
            FormatDefinition(
                id: "ppt",
                name: "Microsoft PowerPoint Binary",
                primaryExtension: "ppt",
                extensions: ["ppt"],
                utTypeIdentifiers: ["com.microsoft.powerpoint.ppt"],
                category: .document,
                supportedInput: true,
                supportedOutput: false,
                libreOfficeSupported: true,
                mimeType: "application/vnd.ms-powerpoint"
            ),
            FormatDefinition(
                id: "ods",
                name: "OpenDocument Spreadsheet",
                primaryExtension: "ods",
                extensions: ["ods"],
                utTypeIdentifiers: ["org.oasis-open.opendocument.spreadsheet"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                libreOfficeSupported: true,
                mimeType: "application/vnd.oasis.opendocument.spreadsheet"
            ),
            FormatDefinition(
                id: "odp",
                name: "OpenDocument Presentation",
                primaryExtension: "odp",
                extensions: ["odp"],
                utTypeIdentifiers: ["org.oasis-open.opendocument.presentation"],
                category: .document,
                supportedInput: true,
                supportedOutput: true,
                libreOfficeSupported: true,
                mimeType: "application/vnd.oasis.opendocument.presentation"
            ),
            FormatDefinition(
                id: "pages",
                name: "Apple Pages Document",
                primaryExtension: "pages",
                extensions: ["pages"],
                utTypeIdentifiers: ["com.apple.iwork.pages.sffpages", "com.apple.pages.pages"],
                category: .document,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                mimeType: "application/x-iwork-pages-sffpages"
            ),
            FormatDefinition(
                id: "numbers",
                name: "Apple Numbers Spreadsheet",
                primaryExtension: "numbers",
                extensions: ["numbers"],
                utTypeIdentifiers: ["com.apple.iwork.numbers.sffnumbers", "com.apple.numbers.numbers"],
                category: .document,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                mimeType: "application/x-iwork-numbers-sffnumbers"
            ),
            FormatDefinition(
                id: "key",
                name: "Apple Keynote Presentation",
                primaryExtension: "key",
                extensions: ["key", "keynote"],
                utTypeIdentifiers: ["com.apple.iwork.keynote.sffkey", "com.apple.keynote.key"],
                category: .document,
                supportedInput: true,
                supportedOutput: false,
                nativeDecoderAvailable: true,
                mimeType: "application/x-iwork-keynote-sffkey"
            )
        ])
    }

    private func register(_ list: [FormatDefinition]) {
        for item in list {
            do {
                try registerFormat(item)
            } catch {
                preconditionFailure("Invalid built-in format registration for \(item.id): \(error)")
            }
        }
    }
}
