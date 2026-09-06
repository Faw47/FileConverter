import FileConverterContracts
import Foundation
import UniformTypeIdentifiers

public struct FinderMenuEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct FinderMenuSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let order: Int
    public let entries: [FinderMenuEntry]

    public init(id: String, title: String, order: Int, entries: [FinderMenuEntry]) {
        self.id = id
        self.title = title
        self.order = order
        self.entries = entries
    }
}

public final class FinderMenuCatalog: @unchecked Sendable {
    public static let shared = FinderMenuCatalog()

    private let lock = NSLock()
    private let snapshotURLOverride: URL?
    private let expectedEditionOverride: ProductEdition?
    private var snapshot: FinderMenuSnapshot?
    private var cachedErrorDescription: String?

    public init(snapshotURL: URL? = nil, expectedEdition: ProductEdition? = nil) {
        self.snapshotURLOverride = snapshotURL
        self.expectedEditionOverride = expectedEdition
        reload()
    }

    public var hasUsableSnapshot: Bool {
        lock.withLock { snapshot != nil }
    }

    public var lastErrorDescription: String? {
        lock.withLock { cachedErrorDescription }
    }

    public func reload() {
        do {
            let (url, edition) = try snapshotLocation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize <= FinderMenuSnapshot.maximumFileSize else {
                throw FinderMenuSnapshotError.snapshotTooLarge
            }
            let data = try Data(contentsOf: url)
            guard data.count <= FinderMenuSnapshot.maximumFileSize else {
                throw FinderMenuSnapshotError.snapshotTooLarge
            }
            let decoded = try JSONDecoder().decode(FinderMenuSnapshot.self, from: data)
            try decoded.validate(expectedEdition: edition)
            lock.withLock {
                snapshot = decoded
                cachedErrorDescription = nil
            }
        } catch {
            lock.withLock { cachedErrorDescription = error.localizedDescription }
        }
    }

    public func sections(for urls: [URL]) -> [FinderMenuSection] {
        guard !urls.isEmpty,
              urls.count <= ConversionRequestLimits.production.maximumSourceCount,
              let snapshot = lock.withLock({ snapshot }) else {
            return []
        }

        let formatsByExtension = Dictionary(
            snapshot.formats.flatMap { format in
                format.extensions.map { ($0.lowercased(), format.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let formatsByUTType = Dictionary(
            snapshot.formats.flatMap { format in
                format.utTypeIdentifiers.map { ($0.lowercased(), format.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var selectedFormatIDs: [String] = []
        for url in urls {
            guard let formatID = classify(
                url: url,
                formatsByExtension: formatsByExtension,
                formatsByUTType: formatsByUTType
            ) else {
                return []
            }
            selectedFormatIDs.append(formatID)
        }

        let matchingPresets = snapshot.presets.filter { preset in
            let compatible = Set(preset.compatibleFormatIDs)
            return selectedFormatIDs.allSatisfy(compatible.contains)
        }
        let grouped = Dictionary(grouping: matchingPresets, by: \.sectionIdentifier)

        return grouped.compactMap { identifier, presets in
            guard let first = presets.first else { return nil }
            let entries = presets
                .sorted { lhs, rhs in
                    lhs.sortOrder == rhs.sortOrder ? lhs.id.uuidString < rhs.id.uuidString : lhs.sortOrder < rhs.sortOrder
                }
                .map { FinderMenuEntry(id: $0.id, title: $0.title) }
            return FinderMenuSection(
                id: identifier,
                title: first.sectionTitle,
                order: first.sectionOrder,
                entries: entries
            )
        }.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }
    }

    private func classify(
        url: URL,
        formatsByExtension: [String: String],
        formatsByUTType: [String: String]
    ) -> String? {
        guard !url.hasDirectoryPath else { return nil }

        let ext = url.pathExtension.lowercased()
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let formatID = formatsByUTType[contentType.identifier.lowercased()] {
            return formatID
        }
        if let formatID = formatsByExtension[ext] {
            return formatID
        }
        if let inferredType = UTType(filenameExtension: ext) {
            return formatsByUTType[inferredType.identifier.lowercased()]
        }
        return nil
    }

    private func snapshotLocation() throws -> (URL, ProductEdition) {
        if let snapshotURLOverride, let expectedEditionOverride {
            return (snapshotURLOverride, expectedEditionOverride)
        }

        let configuration = try IPCConfiguration.current()
        guard let container = configuration.sharedContainerURL() else {
            throw FinderSupportError.appGroupUnavailable(configuration.appGroupID)
        }
        return (
            container
                .appendingPathComponent("FileConverter", isDirectory: true)
                .appendingPathComponent(FinderMenuSnapshot.fileName),
            configuration.edition
        )
    }
}

public enum FinderSupportError: Error, LocalizedError, Sendable {
    case appGroupUnavailable(String)
    case hostSetupRequired
    case requestTooLarge

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "The shared container \(identifier) is unavailable."
        case .hostSetupRequired:
            return "Open File Converter once to finish Finder integration setup."
        case .requestTooLarge:
            return "The Finder conversion request is too large."
        }
    }
}
