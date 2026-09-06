import Foundation
import FileConverterContracts

public enum PresetStoreError: Error, LocalizedError {
    case appGroupContainerUnavailable(String)
    case readOnlyExtension
    case invalidPresetDocument
    case invalidPreset(reason: String)

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "The preset App Group container is unavailable: \(identifier)"
        case .readOnlyExtension:
            return "Finder extensions cannot modify presets."
        case .invalidPresetDocument:
            return "The preset export is not a supported File Converter document."
        case .invalidPreset(let reason):
            return "The preset export contains an invalid preset: \(reason)"
        }
    }
}

private struct PresetStoreDocument: Codable {
    let schemaVersion: Int
    let presets: [ConversionPreset]

    init(schemaVersion: Int = 2, presets: [ConversionPreset]) {
        self.schemaVersion = schemaVersion
        self.presets = presets
    }
}

public final class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()

    public static let presetsFileName = "presets.json"

    private var cachedPresets: [ConversionPreset] = []
    private var cachedErrorDescription: String?
    private var hasLoadedPresetsSuccessfully = false
    private var lastSaveSucceededValue = true
    private let lock = NSLock()
    private let storageURLOverride: URL?
    private let postsDarwinNotifications: Bool

    public init(storageURL: URL? = nil, postsDarwinNotifications: Bool = true) {
        self.storageURLOverride = storageURL
        self.postsDarwinNotifications = postsDarwinNotifications
        loadPresets()
    }

    public var presets: [ConversionPreset] {
        lock.withLock { cachedPresets }
    }

    public var enabledPresets: [ConversionPreset] {
        lock.withLock { cachedPresets.filter(\.isEnabled) }
    }

    public var lastErrorDescription: String? {
        lock.withLock { cachedErrorDescription }
    }

    public var lastSaveSucceeded: Bool {
        lock.withLock { lastSaveSucceededValue }
    }

    public func preset(forID id: UUID) -> ConversionPreset? {
        lock.withLock { cachedPresets.first { $0.id == id } }
    }

    public func loadPresets() {
        do {
            let fileURL = try storageFileURL()
            let loaded: [ConversionPreset]
            let needsSave: Bool

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let decoded = try decodePresets(data)
                // Migrate legacy built-ins before validating the collection. Older
                // versions did not persist a stable built-in key and could contain
                // stale matching rules. `mergeBuiltIns` restores those factory
                // rules, while validation below still rejects malformed custom
                // presets and invalid post-migration data.
                loaded = mergeBuiltIns(into: decoded).sorted(by: presetSort)
                try validatePresetCollection(loaded)
                needsSave = loaded != decoded || (try? JSONDecoder().decode(PresetStoreDocument.self, from: data)) == nil
            } else {
                loaded = BuiltInPresets.makeDefaultPresets()
                needsSave = true
            }

            lock.withLock {
                cachedPresets = loaded
                cachedErrorDescription = nil
                hasLoadedPresetsSuccessfully = true
            }

            if needsSave, !isExtensionProcess {
                try persist(loaded)
            }
        } catch {
            lock.withLock { hasLoadedPresetsSuccessfully = false }
            record(error)
        }
    }

    public func savePresets(_ newPresets: [ConversionPreset]) {
        let sorted = newPresets.sorted(by: presetSort)
        persistAndNotify(sorted)
    }

    @discardableResult
    public func publishFinderMenuSnapshot() -> Bool {
        guard lock.withLock({ hasLoadedPresetsSuccessfully }) else { return false }
        do {
            try FinderMenuSnapshotWriter.write(presets: presets, resolver: .shared)
            lock.withLock { cachedErrorDescription = nil }
            postNotification()
            return true
        } catch {
            record(error)
            return false
        }
    }

    public func addPreset(_ preset: ConversionPreset) {
        var customPreset = preset
        customPreset.builtInKey = nil
        customPreset.isBuiltIn = false

        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = cachedPresets
            result.append(customPreset)
            return result.sorted(by: presetSort)
        }
        persistAndNotify(updated)
    }

    public func updatePreset(_ preset: ConversionPreset) {
        var normalized = preset
        if normalized.isBuiltIn, let key = normalized.builtInKey {
            normalized.builtInKey = key
        } else {
            normalized.builtInKey = nil
            normalized.isBuiltIn = false
        }
        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = cachedPresets
            if let index = result.firstIndex(where: { $0.id == normalized.id }) {
                result[index] = normalized
            } else {
                result.append(normalized)
            }
            return result.sorted(by: presetSort)
        }
        persistAndNotify(updated)
    }

    public func deletePreset(withID id: UUID) {
        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = cachedPresets
            if let index = result.firstIndex(where: { $0.id == id }) {
                if result[index].isBuiltIn {
                    result[index].isEnabled = false
                } else {
                    result.remove(at: index)
                }
            }
            return result
        }
        persistAndNotify(updated)
    }

    public func restoreBuiltIn(withID id: UUID) {
        guard let stored = preset(forID: id), stored.isBuiltIn,
              let key = stored.builtInKey,
              let factory = BuiltInPresets.makeDefaultPresets().first(where: { $0.builtInKey == key }) else { return }
        var restored = factory
        restored.isEnabled = true
        restored.sortOrder = stored.sortOrder
        updatePreset(restored)
    }

    public func duplicatePreset(withID id: UUID) -> ConversionPreset? {
        let duplicated = lock.withLock { () -> ConversionPreset? in
            guard let original = cachedPresets.first(where: { $0.id == id }) else {
                return nil
            }

            var copy = original
            copy.id = UUID()
            copy.builtInKey = nil
            copy.name = "\(original.name) (Copy)"
            copy.menuName = "\(original.menuName) (Copy)"
            copy.isBuiltIn = false
            copy.sortOrder = original.sortOrder + 1
            return copy
        }

        if duplicated != nil {
            let updated = lock.withLock { () -> [ConversionPreset] in
                var result = cachedPresets
                if let duplicated {
                    result.append(duplicated)
                }
                return result.sorted(by: presetSort)
            }
            persistAndNotify(updated)
        }
        return duplicated
    }

    public func resetToDefaults() {
        savePresets(BuiltInPresets.makeDefaultPresets())
    }

    public func exportPresetsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PresetStoreDocument(presets: presets))
    }

    public func importPresetsJSON(_ data: Data, overwrite: Bool = false) throws {
        let decoded = try decodePresets(data)
        try validatePresetCollection(decoded)
        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = overwrite
                ? cachedPresets.filter(\.isBuiltIn)
                : cachedPresets
            for var item in decoded {
                if item.isBuiltIn, let key = item.builtInKey,
                   let existingIndex = result.firstIndex(where: { $0.isBuiltIn && $0.builtInKey == key }) {
                    // Keep the factory identity stable while accepting the user's full edited state.
                    item.id = result[existingIndex].id
                    item.builtInKey = key
                    result[existingIndex] = item
                } else if let index = result.firstIndex(where: { $0.id == item.id }) {
                    result[index] = item
                } else {
                    item.isBuiltIn = false
                    item.builtInKey = nil
                    result.append(item)
                }
            }
            return mergeBuiltIns(into: result).sorted(by: presetSort)
        }
        guard !updated.isEmpty else { throw PresetStoreError.invalidPresetDocument }
        try persistAndNotifyThrowing(updated)
    }

    private func mergeBuiltIns(into storedPresets: [ConversionPreset]) -> [ConversionPreset] {
        var merged = storedPresets

        for defaultPreset in BuiltInPresets.makeDefaultPresets() {
            let matchIndex = merged.firstIndex { stored in
                guard stored.isBuiltIn else { return false }
                if let key = stored.builtInKey {
                    return key == defaultPreset.builtInKey
                }
                return stored.name == defaultPreset.name
                    && stored.category == defaultPreset.category
                    && stored.destinationFormat == defaultPreset.destinationFormat
            }

            guard let matchIndex else {
                merged.append(defaultPreset)
                continue
            }

            let stored = merged[matchIndex]
            var updated = stored
            // Legacy entries without an identity are migrated to the factory UUID/key,
            // but all user-edited fields are retained.
            updated.id = defaultPreset.id
            updated.builtInKey = defaultPreset.builtInKey
            updated.isBuiltIn = true
            // Matching rules are part of the built-in identity; do not let
            // malformed legacy entries hide a factory preset from Finder.
            updated.sourceFormats = defaultPreset.sourceFormats
            merged[matchIndex] = updated
        }

        return merged
    }

    private var isExtensionProcess: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    private func storageFileURL() throws -> URL {
        if let storageURLOverride {
            return storageURLOverride
        }

        if let configuration = try? IPCConfiguration.current() {
            guard let container = configuration.sharedContainerURL() else {
                throw PresetStoreError.appGroupContainerUnavailable(configuration.appGroupID)
            }
            return container
                .appendingPathComponent("FileConverter", isDirectory: true)
                .appendingPathComponent(Self.presetsFileName)
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent(Self.presetsFileName)
    }

    private func persistAndNotify(_ presets: [ConversionPreset]) {
        do {
            try persistAndNotifyThrowing(presets)
        } catch {
            lock.withLock { lastSaveSucceededValue = false }
            record(error)
        }
    }

    private func persistAndNotifyThrowing(_ presets: [ConversionPreset]) throws {
        guard !isExtensionProcess else {
            throw PresetStoreError.readOnlyExtension
        }
        try validatePresetCollection(presets)
        try persist(presets)
        // The durable file is the source of truth. Update memory only after
        // the atomic write has completed, so a failed save cannot claim success.
        lock.withLock {
            cachedPresets = presets
            cachedErrorDescription = nil
            hasLoadedPresetsSuccessfully = true
            lastSaveSucceededValue = true
        }

        if isIPCConfigured {
            do {
                try FinderMenuSnapshotWriter.write(presets: presets, resolver: .shared)
            } catch {
                // A preset save remains successful even when the extension
                // snapshot is temporarily unavailable. Surface the sync issue.
                record(error)
            }
        }
        postNotification()
    }

    private func persist(_ presets: [ConversionPreset]) throws {
        let fileURL = try storageFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateBackups(for: fileURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(PresetStoreDocument(presets: presets)).write(to: fileURL, options: .atomic)
    }

    private func decodePresets(_ data: Data) throws -> [ConversionPreset] {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(PresetStoreDocument.self, from: data) {
            guard document.schemaVersion == 2 else {
                throw PresetStoreError.invalidPresetDocument
            }
            return document.presets
        }
        if let legacy = try? decoder.decode([ConversionPreset].self, from: data) {
            return legacy
        }
        throw PresetStoreError.invalidPresetDocument
    }

    private func validatePresetCollection(_ presets: [ConversionPreset]) throws {
        guard !presets.isEmpty else {
            throw PresetStoreError.invalidPresetDocument
        }

        var identifiers = Set<UUID>()
        var builtInKeys = Set<String>()
        let knownBuiltInKeys = Set(BuiltInPresets.makeDefaultPresets().compactMap(\.builtInKey))

        for preset in presets {
            guard identifiers.insert(preset.id).inserted else {
                throw PresetStoreError.invalidPreset(reason: "Duplicate preset identifier.")
            }
            if let error = PresetValidator.validationErrors(for: preset).first {
                throw PresetStoreError.invalidPreset(reason: error)
            }
            if preset.isBuiltIn {
                guard let key = preset.builtInKey,
                      knownBuiltInKeys.contains(key),
                      builtInKeys.insert(key).inserted else {
                    throw PresetStoreError.invalidPreset(reason: "Unknown or duplicate built-in preset identity.")
                }
            } else if preset.builtInKey != nil {
                throw PresetStoreError.invalidPreset(reason: "Custom presets cannot claim a built-in identity.")
            }
        }
    }

    private func rotateBackups(for fileURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let directory = fileURL.deletingLastPathComponent()
        for index in stride(from: 4, through: 1, by: -1) {
            let oldURL = directory.appendingPathComponent("presets.backup.\(index).json")
            let newURL = directory.appendingPathComponent("presets.backup.\(index + 1).json")
            try? fm.removeItem(at: newURL)
            try? fm.moveItem(at: oldURL, to: newURL)
        }
        let firstBackup = directory.appendingPathComponent("presets.backup.1.json")
        try? fm.removeItem(at: firstBackup)
        try? fm.copyItem(at: fileURL, to: firstBackup)
    }

    private func record(_ error: Error) {
        lock.withLock { cachedErrorDescription = error.localizedDescription }
        AppLogger.presets.error("Preset persistence failed: \(error.localizedDescription, privacy: .public)")
    }

    private func postNotification() {
        guard postsDarwinNotifications, let configuration = try? IPCConfiguration.current() else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(configuration.finderMenuSnapshotNotificationName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    private var isIPCConfigured: Bool {
        (try? IPCConfiguration.current()) != nil
    }

    private func presetSort(_ lhs: ConversionPreset, _ rhs: ConversionPreset) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.sortOrder < rhs.sortOrder
    }
}
