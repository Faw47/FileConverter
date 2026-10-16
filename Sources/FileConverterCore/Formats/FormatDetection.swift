import Foundation
import UniformTypeIdentifiers

public struct FormatDetectionResult: Sendable {
    public let format: FormatDefinition?
    public let detectedUTType: UTType?
    public let confidence: Confidence
    public let exists: Bool
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isZeroByte: Bool
    public let isReadable: Bool

    public init(
        format: FormatDefinition?,
        detectedUTType: UTType?,
        confidence: Confidence,
        exists: Bool,
        isDirectory: Bool,
        isPackage: Bool = false,
        isZeroByte: Bool,
        isReadable: Bool
    ) {
        self.format = format
        self.detectedUTType = detectedUTType
        self.confidence = confidence
        self.exists = exists
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isZeroByte = isZeroByte
        self.isReadable = isReadable
    }

    public enum Confidence: Sendable {
        case exactMagicBytes
        case utType
        case fileExtension
        case none
    }
}

/// Least-recently-used cache of detection results. Holds more than the
/// largest folder drop (10,000 files) so a whole batch stays cached; when
/// full, it drops the least recently used quarter at once.
final class DetectionSnapshotStorage: @unchecked Sendable {
    private struct Entry {
        var snapshot: DetectionSnapshot
        var lastUse: UInt64
    }

    let capacity: Int
    private let lock = NSLock()
    private var cache: [URL: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 20_000) {
        self.capacity = capacity
    }

    var count: Int { lock.withLock { cache.count } }

    func clear() {
        lock.withLock { cache.removeAll() }
    }

    func get(for url: URL) -> DetectionSnapshot? {
        lock.withLock {
            guard let cached = cache[url], cached.snapshot.isValid else { return nil }
            clock += 1
            cache[url]?.lastUse = clock
            return cached.snapshot
        }
    }

    func set(_ snapshot: DetectionSnapshot, for url: URL) {
        lock.withLock {
            if cache[url] == nil, cache.count >= capacity {
                let evict = max(1, capacity / 4)
                let oldest = cache.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(evict)
                for (key, _) in oldest { cache.removeValue(forKey: key) }
            }
            clock += 1
            cache[url] = Entry(snapshot: snapshot, lastUse: clock)
        }
    }
}

public enum FormatDetector {
    private static let storage = DetectionSnapshotStorage()

    public static func clearCache() {
        storage.clear()
    }

    public static func snapshot(for url: URL) -> DetectionSnapshot {
        if let cached = storage.get(for: url) {
            return cached
        }

        let signpostID = AppSignpost.detection.makeSignpostID()
        let state = AppSignpost.detection.beginInterval("FormatDetection", id: signpostID)
        let fp = SourceFingerprint(url: url)
        let res = detectDirect(url: url)
        AppSignpost.detection.endInterval("FormatDetection", state)

        let snap = DetectionSnapshot(fingerprint: fp, result: res)
        storage.set(snap, for: url)
        return snap
    }

    public static func detect(url: URL) -> FormatDetectionResult {
        return snapshot(for: url).result
    }

    public static func detectDirect(url: URL) -> FormatDetectionResult {
        let ext = url.pathExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let fallbackFormat = FormatRegistry.shared.format(forExtension: ext) ?? FormatRegistry.shared.format(forID: ext)
        let fallbackUTType = UTType(filenameExtension: ext)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if exists && isDir.boolValue {
            let utType = fallbackUTType ?? UTType(filenameExtension: ext)
            let isPackage = utType?.conforms(to: .package) == true || ["pages", "numbers", "key", "keynote"].contains(ext)
            if isPackage {
                return FormatDetectionResult(
                    format: fallbackFormat,
                    detectedUTType: utType,
                    confidence: fallbackFormat != nil ? .fileExtension : .none,
                    exists: true,
                    isDirectory: true,
                    isPackage: true,
                    isZeroByte: false,
                    isReadable: true
                )
            }
            return FormatDetectionResult(
                format: nil,
                detectedUTType: UTType.folder,
                confidence: .utType,
                exists: true,
                isDirectory: true,
                isPackage: false,
                isZeroByte: false,
                isReadable: true
            )
        }

        var headerData = Data()
        var isReadable = false
        if exists {
            do {
                let fileHandle = try FileHandle(forReadingFrom: url)
                headerData = (try fileHandle.read(upToCount: 4096)) ?? Data()
                try? fileHandle.close()
                isReadable = true
            } catch {
                isReadable = false
            }
        }

        var isZeroByte = false
        if exists, isReadable,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? NSNumber {
            isZeroByte = fileSize.int64Value == 0
        }

        // Prefer bytes and the filesystem content type over a misleading suffix.
        // A file named `photo.mp4` containing a PNG must be offered as a PNG.
        if exists, isReadable {
            if let magicFormat = detectFromMagicBytes(headerData, fileExtension: ext) {
                // QuickTime audio and movie files share the same container
                // signature. When a .qta suffix disambiguates that container,
                // retain the audio type instead of treating it as video.
                let resolvedFormat: FormatDefinition
                if magicFormat.id == "mov", fallbackFormat?.id == "qta" {
                    resolvedFormat = fallbackFormat ?? magicFormat
                } else if magicFormat.id == "mp4", (ext == "heic" || ext == "heif") {
                    resolvedFormat = FormatRegistry.shared.format(forID: "heic") ?? magicFormat
                } else if magicFormat.id == "mkv", ext == "webm" {
                    resolvedFormat = FormatRegistry.shared.format(forID: "webm") ?? magicFormat
                } else {
                    resolvedFormat = magicFormat
                }
                let utType = resolvedFormat.utTypes.first ?? UTType(filenameExtension: resolvedFormat.primaryExtension)
                return FormatDetectionResult(
                    format: resolvedFormat,
                    detectedUTType: utType,
                    confidence: .exactMagicBytes,
                    exists: true,
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
                    exists: true,
                    isDirectory: false,
                    isZeroByte: isZeroByte,
                    isReadable: isReadable
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
                exists: exists,
                isDirectory: false,
                isZeroByte: isZeroByte,
                isReadable: isReadable
            )
        }

        return FormatDetectionResult(
            format: nil,
            detectedUTType: fallbackUTType,
            confidence: .none,
            exists: exists,
            isDirectory: false,
            isZeroByte: isZeroByte,
            isReadable: isReadable
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

        // TIFF: II*\0 (49 49 2A 00) or MM\0* (4D 4D 00 2A)
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return FormatRegistry.shared.format(forID: "tiff")
        }

        // BMP: 42 4D ('BM')
        if bytes.starts(with: [0x42, 0x4D]) {
            return FormatRegistry.shared.format(forID: "bmp")
        }

        // PDF: 25 50 44 46 ('%PDF')
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return FormatRegistry.shared.format(forID: "pdf")
        }

        // Matroska / WebM: 1A 45 DF A3
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            if fileExtension == "webm" || data.range(of: Data("webm".utf8)) != nil {
                return FormatRegistry.shared.format(forID: "webm")
            }
            return FormatRegistry.shared.format(forID: "mkv")
        }

        // RIFF (WAV, AVI, WEBP): 52 49 46 46
        if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            let subType = String(decoding: data[8..<12], as: UTF8.self)
            if subType == "WAVE" { return FormatRegistry.shared.format(forID: "wav") }
            if subType == "AVI " { return FormatRegistry.shared.format(forID: "avi") }
            if subType == "WEBP" { return FormatRegistry.shared.format(forID: "webp") }
        }

        // MP4 / MOV / QTA / M4A / HEIC / AVIF ftyp box at offset 4.
        // Bounds are parsed safely: a truncated or overstated box length never
        // reads past the available bytes, and unknown brands return unknown
        // rather than defaulting to MP4.
        if bytes.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let declared = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            // A complete ftyp box contains size, type, major brand, and
            // minor version. Do not infer a container from a partial header or
            // from brands that happen to be present in a truncated read.
            guard declared >= 16, declared <= bytes.count else { return nil }
            let boxLength = declared
            let majorBrand = String(decoding: bytes[8..<12], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var brands: [String] = [majorBrand]
            var offset = 16
            while offset + 4 <= min(boxLength, bytes.count) {
                let brand = String(decoding: bytes[offset..<offset+4], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                brands.append(brand)
                offset += 4
            }

            let lowerBrands = brands.map { $0.lowercased() }

            // AVIF must win over generic HEIC-compatible brands: AVIF files
            // commonly list `mif1` as a compatible brand.
            if lowerBrands.contains(where: { $0.starts(with: "avif") || $0.starts(with: "avis") }) {
                return FormatRegistry.shared.format(forID: "avif")
            }

            let heicEvidenceBrands: Set<String> = [
                "heic", "heix", "hevc", "hevx", "heim", "heis", "miaf", "mihb", "heif", "hevm", "hevs"
            ]

            if lowerBrands.contains(where: { brand in
                heicEvidenceBrands.contains(brand) || brand.starts(with: "heic")
            }) {
                // An AVIF major/compatible brand was already handled above.
                // Generic `mif1`/`msf1` brands are not enough to distinguish
                // HEIC from other ISO-BMFF image containers.
                return FormatRegistry.shared.format(forID: "heic")
            }

            if lowerBrands.contains(where: { $0.starts(with: "qta") }) {
                return FormatRegistry.shared.format(forID: "qta")
            }
            if lowerBrands.contains(where: { $0.starts(with: "m4a") }) {
                return FormatRegistry.shared.format(forID: "m4a")
            }
            if lowerBrands.contains(where: { $0.starts(with: "qt") || $0.starts(with: "moov") }) {
                return FormatRegistry.shared.format(forID: "mov")
            }

            let cleanExt = fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if cleanExt == "heic" || cleanExt == "heif" {
                return FormatRegistry.shared.format(forID: "heic")
            }
            if cleanExt == "avif" {
                // Content brands were inconclusive but the suffix is explicit.
                // Leave content classification unknown so extension fallback wins.
                return nil
            }

            // Known MP4-family brands only. Unknown ftyp containers return
            // unknown instead of an unsafe MP4 guess.
            let mp4Brands: Set<String> = [
                "isom", "iso2", "iso3", "iso4", "iso5", "iso6",
                "mp41", "mp42", "avc1", "dash", "mmp4", "m4v ", "m4v"
            ]
            if lowerBrands.contains(where: { mp4Brands.contains($0) || $0.starts(with: "mp4") }) {
                return FormatRegistry.shared.format(forID: "mp4")
            }

            return nil
        }

        // MP3 ID3: 49 44 33, or a plausible MPEG audio frame header.
        if bytes.starts(with: [0x49, 0x44, 0x33]) {
            return FormatRegistry.shared.format(forID: "mp3")
        }
        if bytes.count >= 4,
           bytes[0] == 0xFF,
           (bytes[1] & 0xE0) == 0xE0,
           isPlausibleMP3FrameHeader(bytes) {
            return FormatRegistry.shared.format(forID: "mp3")
        }

        // FLAC: 66 4C 61 43 ('fLaC')
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return FormatRegistry.shared.format(forID: "flac")
        }

        // OGG: 4F 67 67 53 ('OggS') — distinguish Opus vs Vorbis via codec headers.
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            if data.range(of: Data("OpusHead".utf8)) != nil {
                return FormatRegistry.shared.format(forID: "opus")
            }
            if data.range(of: Data("vorbis".utf8)) != nil {
                return FormatRegistry.shared.format(forID: "ogg")
            }
            // Theora and other Ogg codecs are intentionally unknown here;
            // the container signature alone is not enough to choose an audio
            // format.
            return nil
        }

        return nil
    }

    private static func isPlausibleMP3FrameHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }

        let version = (bytes[1] >> 3) & 0x03
        let layer = (bytes[1] >> 1) & 0x03
        let bitrateIndex = (bytes[2] >> 4) & 0x0F
        let sampleRateIndex = (bytes[2] >> 2) & 0x03

        // MPEG version 01 is reserved, layer 00 is reserved, bitrate index
        // 0000 is free-form and 1111 is invalid for this lightweight sniff,
        // and sample-rate index 11 is reserved.
        guard version != 0x01,
              layer != 0x00,
              bitrateIndex != 0x00,
              bitrateIndex != 0x0F,
              sampleRateIndex != 0x03 else {
            return false
        }

        return true
    }
}
