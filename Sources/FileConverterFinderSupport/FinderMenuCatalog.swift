import FileConverterContracts
import Foundation
import UniformTypeIdentifiers

public struct FinderMenuEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// Listed under "More" in its section.
    public let isSecondary: Bool
    /// Accepts every selected file (no "(3 of 5 files)").
    public let coversSelection: Bool

    public init(id: UUID, title: String, isSecondary: Bool = false, coversSelection: Bool = true) {
        self.id = id
        self.title = title
        self.isSecondary = isSecondary
        self.coversSelection = coversSelection
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
    private var lastSnapshotModificationDate: Date?

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

    public func ensureFresh() {
        if !hasUsableSnapshot {
            reload()
            return
        }
        guard let (url, _) = try? snapshotLocation(),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return
        }
        let shouldReload = lock.withLock {
            if let last = lastSnapshotModificationDate {
                return date > last
            }
            return true
        }
        if shouldReload {
            reload()
        }
    }

    public func reload() {
        do {
            let (url, edition) = try snapshotLocation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
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
                lastSnapshotModificationDate = values.contentModificationDate
            }
        } catch {
            lock.withLock { cachedErrorDescription = error.localizedDescription }
        }
    }

    /// Host-facing diagnostic for mixed known/unknown selections. The menu
    /// stays fail-closed (no unsupported file is enqueued), but callers can
    /// surface this string as a disabled menu item instead of silent emptiness.
    public func diagnostic(for urls: [URL]) -> String? {
        guard !urls.isEmpty else { return "No files selected." }
        if urls.count > ConversionRequestLimits.finderSelectionLimit {
            return "Up to \(ConversionRequestLimits.finderSelectionLimit.formatted()) files at a time."
        }
        guard let snapshot = lock.withLock({ snapshot }) else {
            return "Open File Converter once to finish Finder integration setup."
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
        var unknown: [String] = []
        for url in urls {
            if classify(url: url, formatsByExtension: formatsByExtension, formatsByUTType: formatsByUTType) == nil {
                unknown.append(url.lastPathComponent)
            }
        }
        guard !unknown.isEmpty else { return nil }
        if unknown.count == urls.count {
            return "No compatible formats for \(unknown.count == 1 ? unknown[0] : "\(unknown.count) files")."
        }
        return "Some selected items are unsupported (\(unknown.prefix(3).joined(separator: ", "))\(unknown.count > 3 ? "…" : "")). These items cannot be converted together."
    }

    /// Menu sections for a selection. Presets that accept every selected
    /// file are offered; when none does, presets that accept some of the
    /// files are offered with "(3 of 5 files)" and convert only those.
    public func sections(for urls: [URL]) -> [FinderMenuSection] {
        guard !urls.isEmpty,
              urls.count <= ConversionRequestLimits.finderSelectionLimit,
              let snapshot = lock.withLock({ snapshot }) else {
            return []
        }
        let classifiedIDs = classifiedFormatIDs(for: urls, snapshot: snapshot)
        let known = classifiedIDs.compactMap { $0 }
        guard !known.isEmpty else { return [] }

        let categoryByFormat = Dictionary(
            snapshot.formats.map { ($0.id, $0.category) },
            uniquingKeysWith: { first, _ in first }
        )
        let allVideo = known.allSatisfy { categoryByFormat[$0] == "video" }

        func coverage(_ preset: FinderPresetRecord) -> Int {
            let compatible = Set(preset.compatibleFormatIDs)
            return classifiedIDs.filter { $0.map(compatible.contains) ?? false }.count
        }
        let full = snapshot.presets.filter { coverage($0) == urls.count }
        let candidates: [(preset: FinderPresetRecord, covered: Int)] = full.isEmpty
            ? snapshot.presets.map { ($0, coverage($0)) }.filter { $0.covered > 0 }
            : full.map { ($0, urls.count) }

        struct SectionKey: Hashable {
            let id: String
            let title: String
            let order: Int
        }
        let grouped = Dictionary(grouping: candidates) { candidate -> SectionKey in
            if allVideo && candidate.preset.sectionIdentifier == "audio" {
                // Audio presets on a video selection pull the soundtrack out.
                return SectionKey(id: "extract-audio", title: "Extract Audio", order: candidate.preset.sectionOrder + 1_000)
            }
            return SectionKey(id: candidate.preset.sectionIdentifier, title: candidate.preset.sectionTitle, order: candidate.preset.sectionOrder)
        }

        return grouped.map { key, members -> FinderMenuSection in
            let sorted = members.sorted { lhs, rhs in
                lhs.preset.sortOrder == rhs.preset.sortOrder
                    ? lhs.preset.id.uuidString < rhs.preset.id.uuidString
                    : lhs.preset.sortOrder < rhs.preset.sortOrder
            }
            var titleCounts: [String: Int] = [:]
            for member in sorted { titleCounts[member.preset.title, default: 0] += 1 }
            var occurrences: [String: Int] = [:]
            let entries = sorted.map { member -> FinderMenuEntry in
                let occurrence = occurrences[member.preset.title, default: 0] + 1
                occurrences[member.preset.title] = occurrence
                var title = member.preset.title
                if (titleCounts[title] ?? 0) > 1 && occurrence > 1 {
                    title += " (\(occurrence))"
                }
                if member.covered < urls.count {
                    title += " (\(member.covered) of \(urls.count) files)"
                }
                return FinderMenuEntry(
                    id: member.preset.id,
                    title: title,
                    isSecondary: member.preset.isSecondary ?? false,
                    coversSelection: member.covered == urls.count
                )
            }
            return FinderMenuSection(id: key.id, title: key.title, order: key.order, entries: entries)
        }.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }
    }

    /// Up to `limit` presets used recently that accept every selected file,
    /// newest first, for the top of the menu.
    public func recentEntries(for urls: [URL], limit: Int = 3) -> [FinderMenuEntry] {
        guard let recent = lock.withLock({ snapshot?.recentPresetIDs }), !recent.isEmpty else { return [] }
        let offered = Dictionary(
            sections(for: urls).flatMap(\.entries).filter(\.coversSelection).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Array(recent.compactMap { offered[$0] }.prefix(limit))
    }

    /// The selected files a preset accepts, in selection order.
    public func compatibleURLs(for presetID: UUID, among urls: [URL]) -> [URL] {
        guard let snapshot = lock.withLock({ snapshot }),
              let preset = snapshot.presets.first(where: { $0.id == presetID }) else { return [] }
        let compatible = Set(preset.compatibleFormatIDs)
        let classified = classifiedFormatIDs(for: urls, snapshot: snapshot)
        return zip(urls, classified).compactMap { url, formatID in
            formatID.map(compatible.contains) == true ? url : nil
        }
    }

    private func classifiedFormatIDs(for urls: [URL], snapshot: FinderMenuSnapshot) -> [String?] {
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
        return urls.map { url in
            classify(url: url, formatsByExtension: formatsByExtension, formatsByUTType: formatsByUTType)
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
