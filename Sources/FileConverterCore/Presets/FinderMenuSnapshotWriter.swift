import FileConverterContracts
import Foundation

public enum FinderMenuSnapshotWriter {
    public static func makeSnapshot(
        presets: [ConversionPreset],
        resolver: BackendResolver,
        edition: ProductEdition,
        generatedAt: Date = Date()
    ) -> FinderMenuSnapshot {
        let formats = FormatRegistry.shared.allFormats().sorted { $0.id < $1.id }
        let formatRecords = formats.map { format in
            FinderInputFormatRecord(
                id: format.id,
                extensions: Array(Set([format.primaryExtension] + format.extensions)).sorted(),
                utTypeIdentifiers: Array(Set(format.utTypeIdentifiers)).sorted(),
                category: format.category.rawValue
            )
        }

        // Per format, the presets worth offering (no identity conversions,
        // no generic duplicate of a format-specific recipe).
        let enabled = presets.filter(\.isEnabled)
        var visibleFormatIDsByPreset: [UUID: [String]] = [:]
        for format in formats {
            let candidates = enabled.filter {
                presetAccepts(format: format, preset: $0) && resolver.canResolve(preset: $0, sourceFormat: format)
            }
            for preset in PresetVisibility.visible(candidates, for: format) {
                visibleFormatIDsByPreset[preset.id, default: []].append(format.id)
            }
        }

        let presetRecords = enabled.compactMap { preset -> FinderPresetRecord? in
            let compatibleFormatIDs = visibleFormatIDsByPreset[preset.id] ?? []
            guard !compatibleFormatIDs.isEmpty else { return nil }

            return FinderPresetRecord(
                id: preset.id,
                title: preset.menuName,
                sectionIdentifier: preset.category.rawValue,
                sectionTitle: preset.category.displayName,
                sectionOrder: preset.category.sortOrder,
                sortOrder: preset.sortOrder,
                compatibleFormatIDs: compatibleFormatIDs
            )
        }.sorted { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder ? lhs.id.uuidString < rhs.id.uuidString : lhs.sortOrder < rhs.sortOrder
        }

        return FinderMenuSnapshot(
            edition: edition,
            generatedAt: generatedAt,
            formats: formatRecords,
            presets: presetRecords
        )
    }

    public static func write(presets: [ConversionPreset], resolver: BackendResolver) throws {
        let configuration = try IPCConfiguration.current()
        guard let container = configuration.sharedContainerURL() else {
            throw PresetStoreError.appGroupContainerUnavailable(configuration.appGroupID)
        }

        let snapshot = makeSnapshot(
            presets: presets,
            resolver: resolver,
            edition: configuration.edition
        )
        let directory = container.appendingPathComponent("FileConverter", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try snapshot.validate(expectedEdition: configuration.edition)
        let data = try encoder.encode(snapshot)
        guard data.count <= FinderMenuSnapshot.maximumFileSize else {
            throw FinderMenuSnapshotError.snapshotTooLarge
        }
        let destination = directory.appendingPathComponent(FinderMenuSnapshot.fileName)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
    }

    private static func presetAccepts(format: FormatDefinition, preset: ConversionPreset) -> Bool {
        let registry = FormatRegistry.shared
        return preset.sourceFormats.contains(where: { registry.matchesSourceSpecifier($0, format: format) })
    }
}
