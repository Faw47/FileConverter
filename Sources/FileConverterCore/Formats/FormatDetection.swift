import Foundation
import UniformTypeIdentifiers

public struct FormatDetectionResult: Sendable {
    public let format: FormatDefinition?
    public let detectedUTType: UTType?
    public let confidence: Confidence
    public let isDirectory: Bool
    public let isZeroByte: Bool
    public let isReadable: Bool

    public enum Confidence: Sendable {
        case exactMagicBytes
        case utType
        case fileExtension
        case none
    }
}

public enum FormatDetector {
    public static func detect(url: URL) -> FormatDetectionResult {
        let ext = url.pathExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let fallbackFormat = FormatRegistry.shared.format(forExtension: ext) ?? FormatRegistry.shared.format(forID: ext)
        let fallbackUTType = UTType(filenameExtension: ext)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if exists && isDir.boolValue {
            return FormatDetectionResult(
                format: nil,
                detectedUTType: UTType.folder,
                confidence: .utType,
                isDirectory: true,
                isZeroByte: false,
                isReadable: true
            )
        }

        var isZeroByte = false
        if exists {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            isZeroByte = (fileSize == 0)
        }

        // Prefer bytes and the filesystem content type over a misleading suffix.
        // A file named `photo.mp4` containing a PNG must be offered as a PNG.
        if exists, let fileHandle = try? FileHandle(forReadingFrom: url) {
            let headerData = (try? fileHandle.read(upToCount: 512)) ?? Data()
            try? fileHandle.close()

            if let magicFormat = detectFromMagicBytes(headerData, fileExtension: ext) {
                // QuickTime audio and movie files share the same container
                // signature. When a .qta suffix disambiguates that container,
                // retain the audio type instead of treating it as video.
                let resolvedFormat: FormatDefinition
                if magicFormat.id == "mov", fallbackFormat?.id == "qta" {
                    resolvedFormat = fallbackFormat ?? magicFormat
                } else if magicFormat.id == "mp4", (ext == "heic" || ext == "heif") {
                    resolvedFormat = FormatRegistry.shared.format(forID: "heic") ?? magicFormat
                } else {
                    resolvedFormat = magicFormat
                }
                let utType = resolvedFormat.utTypes.first ?? UTType(filenameExtension: resolvedFormat.primaryExtension)
                return FormatDetectionResult(
                    format: resolvedFormat,
                    detectedUTType: utType,
                    confidence: .exactMagicBytes,
                    isDirectory: false,
                    isZeroByte: isZeroByte,
                    isReadable: true
                )
            }
        }

        // Try URL resource values (content type key).
        if exists,
           let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = resourceValues.contentType {
            if let format = FormatRegistry.shared.format(forUTType: contentType) {
                return FormatDetectionResult(
                    format: format,
                    detectedUTType: contentType,
                    confidence: .utType,
                    isDirectory: false,
                    isZeroByte: isZeroByte,
                    isReadable: true
                )
            }
        }

        // For a zero-byte file there is no content to sniff. Keep extension
        // inference available for naming/UI, while compatibility validation
        // rejects the unusable input explicitly.
        if let format = fallbackFormat {
            return FormatDetectionResult(
                format: format,
                detectedUTType: fallbackUTType ?? format.utTypes.first,
                confidence: .fileExtension,
                isDirectory: false,
                isZeroByte: isZeroByte,
                isReadable: exists
            )
        }

        return FormatDetectionResult(
            format: nil,
            detectedUTType: fallbackUTType,
            confidence: .none,
            isDirectory: false,
            isZeroByte: isZeroByte,
            isReadable: exists
        )
    }

    private static func detectFromMagicBytes(_ data: Data, fileExtension: String? = nil) -> FormatDefinition? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)

        // PNG: 89 50 4E 47
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return FormatRegistry.shared.format(forID: "png")
        }

        // JPEG: FF D8 FF
        if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return FormatRegistry.shared.format(forID: "jpeg")
        }

        // GIF: 47 49 46 38 ('GIF8')
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return FormatRegistry.shared.format(forID: "gif")
        }

        // PDF: 25 50 44 46 ('%PDF')
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return FormatRegistry.shared.format(forID: "pdf")
        }

        // Matroska / WebM: 1A 45 DF A3
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            // Further inspection if needed, default to mkv or webm
            return FormatRegistry.shared.format(forID: "mkv")
        }

        // RIFF (WAV, AVI, WEBP): 52 49 46 46
        if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            let subType = String(decoding: data[8..<12], as: UTF8.self)
            if subType == "WAVE" { return FormatRegistry.shared.format(forID: "wav") }
            if subType == "AVI " { return FormatRegistry.shared.format(forID: "avi") }
            if subType == "WEBP" { return FormatRegistry.shared.format(forID: "webp") }
        }

        // MP4 / MOV / QTA / M4A / HEIC / AVIF ftyp box at offset 4
        if bytes.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let boxLength: Int
            if bytes.count >= 4 {
                let declared = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
                if declared >= 8 && declared <= bytes.count {
                    boxLength = declared
                } else {
                    boxLength = bytes.count
                }
            } else {
                boxLength = bytes.count
            }

            let majorBrand = String(decoding: bytes[8..<12], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var brands: [String] = [majorBrand]
            var offset = 16
            while offset + 4 <= boxLength {
                let brand = String(decoding: bytes[offset..<offset+4], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                brands.append(brand)
                offset += 4
            }

            let heicBrands: Set<String> = [
                "heic", "heix", "hevc", "hevx", "heim", "heis", "miaf", "mihb", "mif1", "msf1", "heif", "hevm", "hevs"
            ]
            let lowerBrands = brands.map { $0.lowercased() }

            if lowerBrands.contains(where: { brand in
                heicBrands.contains(brand) || brand.starts(with: "heic") || brand.starts(with: "mif1") || brand.starts(with: "msf1")
            }) {
                return FormatRegistry.shared.format(forID: "heic")
            }

            if lowerBrands.contains(where: { $0.starts(with: "qta") }) {
                return FormatRegistry.shared.format(forID: "qta")
            }
            if lowerBrands.contains(where: { $0.starts(with: "m4a") }) {
                return FormatRegistry.shared.format(forID: "m4a")
            }
            if lowerBrands.contains(where: { $0.starts(with: "avif") || $0.starts(with: "avis") }) {
                return FormatRegistry.shared.format(forID: "avif")
            }
            if lowerBrands.contains(where: { $0.starts(with: "qt") || $0.starts(with: "moov") }) {
                return FormatRegistry.shared.format(forID: "mov")
            }

            let cleanExt = fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if cleanExt == "heic" || cleanExt == "heif" {
                return FormatRegistry.shared.format(forID: "heic")
            }

            return FormatRegistry.shared.format(forID: "mp4")
        }

        // MP3 ID3: 49 44 33
        if bytes.starts(with: [0x49, 0x44, 0x33]) {
            return FormatRegistry.shared.format(forID: "mp3")
        }

        // FLAC: 66 4C 61 43 ('fLaC')
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return FormatRegistry.shared.format(forID: "flac")
        }

        // OGG: 4F 67 67 53 ('OggS')
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            return FormatRegistry.shared.format(forID: "ogg")
        }

        return nil
    }
}
