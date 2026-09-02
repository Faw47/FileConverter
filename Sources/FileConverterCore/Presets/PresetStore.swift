import Foundation
import FileConverterContracts

public enum PresetStoreError: Error, LocalizedError {
    case appGroupContainerUnavailable(String)
    case readOnlyExtension

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "The preset App Group container is unavailable: \(identifier)"
        case .readOnlyExtension:
            return "Finder extensions cannot modify presets."
        }
    }
}

public final class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()

    public static let presetsFileName = "presets.json"

    private var cachedPresets: [ConversionPreset] = []
    private var cachedErrorDescription: String?
    private var hasLoadedPresetsSuccessfully = false
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
                let decoded = try JSONDecoder().decode([ConversionPreset].self, from: data)
                loaded = mergeBuiltIns(into: decoded).sorted(by: presetSort)
                needsSave = loaded != decoded
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
        lock.withLock { cachedPresets = sorted }
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
            cachedPresets.append(customPreset)
            cachedPresets.sort(by: presetSort)
            return cachedPresets
        }
        persistAndNotify(updated)
    }

    public func updatePreset(_ preset: ConversionPreset) {
        let updated = lock.withLock { () -> [ConversionPreset] in
            if let index = cachedPresets.firstIndex(where: { $0.id == preset.id }) {
                cachedPresets[index] = preset
            } else {
                cachedPresets.append(preset)
            }
            cachedPresets.sort(by: presetSort)
            return cachedPresets
        }
        persistAndNotify(updated)
    }

    public func deletePreset(withID id: UUID) {
        let updated = lock.withLock { () -> [ConversionPreset] in
            cachedPresets.removeAll { $0.id == id }
            return cachedPresets
        }
        persistAndNotify(updated)
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
            cachedPresets.append(copy)
            cachedPresets.sort(by: presetSort)
            return copy
        }

        if duplicated != nil {
            persistAndNotify(presets)
        }
        return duplicated
    }

    public func resetToDefaults() {
        savePresets(BuiltInPresets.makeDefaultPresets())
    }

    public func exportPresetsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(presets)
    }

    public func importPresetsJSON(_ data: Data, overwrite: Bool = false) throws {
        let decoded = try JSONDecoder().decode([ConversionPreset].self, from: data)
        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = overwrite ? [] : cachedPresets
            for item in decoded {
                if let index = result.firstIndex(where: { $0.id == item.id }) {
                    result[index] = item
                } else {
                    result.append(item)
                }
            }
            cachedPresets = result.sorted(by: presetSort)
            return cachedPresets
        }
        persistAndNotify(updated)
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
            var updated = defaultPreset
            updated.isEnabled = stored.isEnabled
            updated.sortOrder = stored.sortOrder
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
            guard !isExtensionProcess else {
                throw PresetStoreError.readOnlyExtension
            }
            try persist(presets)
            if isIPCConfigured {
                try FinderMenuSnapshotWriter.write(presets: presets, resolver: .shared)
            }
            lock.withLock {
                cachedErrorDescription = nil
                hasLoadedPresetsSuccessfully = true
            }
            postNotification()
        } catch {
            record(error)
        }
    }

    private func persist(_ presets: [ConversionPreset]) throws {
        let fileURL = try storageFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL, options: .atomic)
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
