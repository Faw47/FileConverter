import Foundation

public struct FinderMenuSnapshot: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let fileName = "finder-menu-snapshot.json"
    public static let maximumFileSize = 1_048_576
    public static let maximumFormatCount = 512
    public static let maximumPresetCount = 1_000

    public let protocolVersion: Int
    public let edition: ProductEdition
    public let generatedAt: Date
    public let formats: [FinderInputFormatRecord]
    public let presets: [FinderPresetRecord]

    public init(
        protocolVersion: Int = FinderMenuSnapshot.currentProtocolVersion,
        edition: ProductEdition,
        generatedAt: Date = Date(),
        formats: [FinderInputFormatRecord],
        presets: [FinderPresetRecord]
    ) {
        self.protocolVersion = protocolVersion
        self.edition = edition
        self.generatedAt = generatedAt
        self.formats = formats
        self.presets = presets
    }

    public func validate(expectedEdition: ProductEdition) throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw FinderMenuSnapshotError.unsupportedProtocolVersion(protocolVersion)
        }
        guard edition == expectedEdition else {
            throw FinderMenuSnapshotError.wrongEdition
        }
        guard formats.count <= Self.maximumFormatCount,
              Set(formats.map(\.id)).count == formats.count,
              formats.allSatisfy({
                  !$0.id.isEmpty
                      && $0.id.count <= 128
                      && !$0.extensions.isEmpty
                      && $0.extensions.count <= 32
                      && $0.extensions.allSatisfy { !$0.isEmpty && $0.count <= 32 }
                      && $0.utTypeIdentifiers.count <= 32
                      && $0.utTypeIdentifiers.allSatisfy { !$0.isEmpty && $0.count <= 256 }
              }) else {
            throw FinderMenuSnapshotError.invalidFormatRecord
        }
        let extensions = formats.flatMap(\.extensions).map { $0.lowercased() }
        let typeIdentifiers = formats.flatMap(\.utTypeIdentifiers).map { $0.lowercased() }
        guard Set(extensions).count == extensions.count,
              Set(typeIdentifiers).count == typeIdentifiers.count else {
            throw FinderMenuSnapshotError.duplicateFormatAlias
        }
        let knownFormatIDs = Set(formats.map(\.id))
        guard presets.count <= Self.maximumPresetCount,
              Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({
                  !$0.title.isEmpty
                      && $0.title.count <= 256
                      && !$0.sectionIdentifier.isEmpty
                      && $0.sectionIdentifier.count <= 128
                      && !$0.sectionTitle.isEmpty
                      && $0.sectionTitle.count <= 128
                      && !$0.compatibleFormatIDs.isEmpty
                      && $0.compatibleFormatIDs.count <= Self.maximumFormatCount
                      && $0.compatibleFormatIDs.allSatisfy(knownFormatIDs.contains)
              }) else {
            throw FinderMenuSnapshotError.invalidPresetRecord
        }
    }
}

public struct FinderInputFormatRecord: Codable, Equatable, Sendable {
    public let id: String
    public let extensions: [String]
    public let utTypeIdentifiers: [String]

    public init(id: String, extensions: [String], utTypeIdentifiers: [String]) {
        self.id = id
        self.extensions = extensions
        self.utTypeIdentifiers = utTypeIdentifiers
    }
}

public struct FinderPresetRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let sectionIdentifier: String
    public let sectionTitle: String
    public let sectionOrder: Int
    public let sortOrder: Int
    public let compatibleFormatIDs: [String]

    public init(
        id: UUID,
        title: String,
        sectionIdentifier: String,
        sectionTitle: String,
        sectionOrder: Int,
        sortOrder: Int,
        compatibleFormatIDs: [String]
    ) {
        self.id = id
        self.title = title
        self.sectionIdentifier = sectionIdentifier
        self.sectionTitle = sectionTitle
        self.sectionOrder = sectionOrder
        self.sortOrder = sortOrder
        self.compatibleFormatIDs = compatibleFormatIDs
    }
}

public enum FinderMenuSnapshotError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
    case wrongEdition
    case invalidFormatRecord
    case duplicateFormatAlias
    case invalidPresetRecord
    case snapshotTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let version):
            return "Unsupported Finder menu snapshot version \(version)."
        case .wrongEdition:
            return "The Finder menu snapshot belongs to a different File Converter edition."
        case .invalidFormatRecord:
            return "The Finder menu snapshot contains an invalid format."
        case .duplicateFormatAlias:
            return "The Finder menu snapshot contains a duplicate format alias."
        case .invalidPresetRecord:
            return "The Finder menu snapshot contains an invalid preset."
        case .snapshotTooLarge:
            return "The Finder menu snapshot exceeds its size limit."
        }
    }
}
