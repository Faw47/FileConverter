import Foundation
import ImageIO

/// What this Mac's ImageIO can actually read and write. Format definitions
/// declare intent; these sets are the runtime truth (for example, macOS reads
/// WebP but cannot write it, and AVIF writing depends on the OS version).
public enum NativeImageCodecs {
    public static let encodableTypeIdentifiers: Set<String> = {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(identifiers.map { $0.lowercased() })
    }()

    public static let decodableTypeIdentifiers: Set<String> = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return Set(identifiers.map { $0.lowercased() })
    }()

    public static func canEncode(_ format: FormatDefinition) -> Bool {
        format.utTypeIdentifiers.contains { encodableTypeIdentifiers.contains($0.lowercased()) }
    }

    public static func canEncode(typeIdentifier: String) -> Bool {
        encodableTypeIdentifiers.contains(typeIdentifier.lowercased())
    }
}
