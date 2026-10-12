import Foundation
import UniformTypeIdentifiers

public struct FormatDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let primaryExtension: String
    public let extensions: [String]
    public let utTypeIdentifiers: [String]
    public let category: FormatCategory
    public let supportedInput: Bool
    public let supportedOutput: Bool
    public let nativeDecoderAvailable: Bool
    public let nativeEncoderAvailable: Bool
    public let ffmpegDecoderAvailable: Bool
    public let ffmpegEncoderAvailable: Bool
    public let imageMagickSupported: Bool
    public let ghostscriptSupported: Bool
    public let libreOfficeSupported: Bool
    public let supportsAlpha: Bool
    public let supportsAnimation: Bool
    public let supportsHDR: Bool
    public let mimeType: String?

    public init(
        id: String,
        name: String,
        primaryExtension: String,
        extensions: [String] = [],
        utTypeIdentifiers: [String] = [],
        category: FormatCategory,
        supportedInput: Bool = true,
        supportedOutput: Bool = true,
        nativeDecoderAvailable: Bool = false,
        nativeEncoderAvailable: Bool = false,
        ffmpegDecoderAvailable: Bool = false,
        ffmpegEncoderAvailable: Bool = false,
        imageMagickSupported: Bool = false,
        ghostscriptSupported: Bool = false,
        libreOfficeSupported: Bool = false,
        supportsAlpha: Bool = false,
        supportsAnimation: Bool = false,
        supportsHDR: Bool = false,
        mimeType: String? = nil
    ) {
        self.id = id.lowercased()
        self.name = name
        self.primaryExtension = primaryExtension.lowercased()
        var allExts = Set([primaryExtension.lowercased()])
        for ext in extensions {
            allExts.insert(ext.lowercased())
        }
        self.extensions = Array(allExts).sorted()
        self.utTypeIdentifiers = utTypeIdentifiers
        self.category = category
        self.supportedInput = supportedInput
        self.supportedOutput = supportedOutput
        self.nativeDecoderAvailable = nativeDecoderAvailable
        self.nativeEncoderAvailable = nativeEncoderAvailable
        self.ffmpegDecoderAvailable = ffmpegDecoderAvailable
        self.ffmpegEncoderAvailable = ffmpegEncoderAvailable
        self.imageMagickSupported = imageMagickSupported
        self.ghostscriptSupported = ghostscriptSupported
        self.libreOfficeSupported = libreOfficeSupported
        self.supportsAlpha = supportsAlpha
        self.supportsAnimation = supportsAnimation
        self.supportsHDR = supportsHDR
        self.mimeType = mimeType
    }

    public var utTypes: [UTType] {
        utTypeIdentifiers.compactMap { UTType($0) }
    }

    public func matchesExtension(_ ext: String) -> Bool {
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return extensions.contains(cleanExt)
    }

    public func matchesUTType(_ utType: UTType) -> Bool {
        for identifier in utTypeIdentifiers {
            if let declaredType = UTType(identifier), utType.conforms(to: declaredType) {
                return true
            }
        }
        return false
    }
}
